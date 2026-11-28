import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/settings.dart';
import '../net/discovery.dart';
import '../services/tray_service.dart';
import '../state/app_state.dart';
import '../state/settings_controller.dart';

/// Настройки (ТЗ, раздел 6, таблицы 6.1–6.11).
/// Локальные — на этом устройстве; хостовые — «управляется хостом»,
/// редактируются только на хосте, на клиентах — только просмотр.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// Проверка распознавания речи: какой движок доступен, скачана ли
  /// автономная модель, какая ошибка была последней. Для диагностики.
  /// Проверка распознавания речи: пошаговая диагностика — разрешение,
  /// файлы модели, движок, микрофон (реальный поток 2 секунды).
  Future<void> _checkStt(BuildContext context, AppState app) async {
    final List<String> lines = <String>[];
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setDlg) {
          if (lines.isEmpty) {
            // Запускаем проверку один раз при открытии диалога.
            () async {
              void add(String s) {
                lines.add(s);
                if (ctx.mounted) setDlg(() {});
              }

              // 1) Разрешение на микрофон.
              final PermissionStatus mic = await Permission.microphone.status;
              add(mic.isGranted
                  ? '✅ Разрешение на микрофон: есть'
                  : '❌ Разрешение на микрофон: НЕТ ($mic)');
              if (!mic.isGranted) {
                final PermissionStatus req = await Permission.microphone.request();
                add(req.isGranted
                    ? '✅ Разрешение выдано после запроса'
                    : '❌ Разрешение не выдано — включите в настройках телефона');
              }

              // 2) Файлы автономной модели.
              final Map<String, int> files = await app.stt.offline.modelFilesInfo();
              final bool modelOk =
                  files.values.every((int size) => size > 0);
              if (modelOk) {
                final int total = files.values.fold(0, (a, b) => a + b);
                add('✅ Автономная модель: скачана '
                    '(${(total / 1048576).toStringAsFixed(1)} МБ)');
              } else {
                add('❌ Автономная модель: НЕ скачана или повреждена');
                for (final MapEntry<String, int> e in files.entries) {
                  if (e.value == 0) add('   · нет файла ${e.key}');
                }
              }

              // 3) Движок распознавания.
              final bool ok = await app.stt.init();
              add(ok
                  ? (app.stt.usingOffline
                      ? '✅ Движок: встроенный автономный (офлайн)'
                      : '✅ Движок: системный распознаватель')
                  : '❌ Движок не запустился: ${app.stt.lastError}');

              // 4) Микрофонный поток (реальные 2 секунды).
              add('⏳ Тест микрофона: слушаем 2 секунды…');
              final int bytes = await app.stt.offline.micTest(seconds: 2);
              lines.removeLast();
              add(bytes > 0
                  ? '✅ Микрофон: передаёт звук (${(bytes / 1024).toStringAsFixed(0)} КБ за 2 с)'
                  : '❌ Микрофон: ТИШИНА — 0 байт. Закройте другие '
                      'приложения с микрофоном и проверьте разрешение.');

              if (!modelOk) {
                add('\nРешение: нажмите «Диктовка» в заявке — приложение '
                    'предложит скачать модель (~23 МБ, один раз).');
              }
            }();
          }
          return AlertDialog(
            title: const Text('Проверка распознавания'),
            content: SingleChildScrollView(
              child: Text(lines.isEmpty ? '⏳ Проверяем…' : lines.join('\n')),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Закрыть')),
            ],
          );
        },
      ),
    );
  }

  /// Очистка кэша: временные файлы, кэш картинок, на хосте — ещё и
  /// файлы без заявок. Показывает, сколько места освободится/освобождено.
  Future<void> _cacheCleanup(BuildContext context, AppState app) async {
    String fmt(int b) => b >= 1048576
        ? '${(b / 1048576).toStringAsFixed(1)} МБ'
        : '${(b / 1024).toStringAsFixed(0)} КБ';
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setDlg) {
          return FutureBuilder<({int tempBytes, int orphanBytes, int orphanCount})>(
            future: app.cacheStats(),
            builder: (BuildContext ctx, snapshot) {
              final s = snapshot.data;
              final int total =
                  s == null ? 0 : s.tempBytes + s.orphanBytes;
              return AlertDialog(
                title: const Text('Очистка кэша'),
                content: s == null
                    ? const SizedBox(
                        height: 60,
                        child: Center(child: CircularProgressIndicator()))
                    : Text('Временные файлы: ${fmt(s.tempBytes)}\n'
                        '${app.isHost ? 'Файлы без заявок на хосте: ${s.orphanCount} шт · ${fmt(s.orphanBytes)}\n' : ''}'
                        'Плюс кэш просмотренных фото (в памяти).\n\n'
                        'Заявки, вложения и настройки не затрагиваются.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Отмена')),
                  FilledButton.icon(
                    icon: const Icon(Icons.cleaning_services),
                    label: Text(s == null || total == 0
                        ? 'Очистить'
                        : 'Очистить ${fmt(total)}'),
                    onPressed: s == null
                        ? null
                        : () async {
                            final r = await app.clearCache();
                            // Сбрасываем и кэш картинок Flutter (просмотренные фото).
                            PaintingBinding.instance.imageCache.clear();
                            PaintingBinding.instance.imageCache
                                .clearLiveImages();
                            if (ctx.mounted) {
                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text('Кэш очищен: '
                                          '${r.files} файлов, ${fmt(r.bytes)}')));
                            }
                          },
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// Подтверждение полной очистки журнала аудита на хосте.
  Future<void> _confirmClearAudit(BuildContext context, AppState app) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Очистить журнал?'),
        content: Text('Записей: ${app.audit.length}. История изменений всех '
            'заявок будет удалена на хосте и на всех устройствах. '
            'Сами заявки останутся.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Очистить')),
        ],
      ),
    );
    if (ok != true) return;
    await app.clearAudit();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Журнал очищен')));
    }
  }

  /// Редактор шаблонов заявки: список фраз, добавление/правка/удаление.
  Future<void> _editTemplates(
      BuildContext context, SettingsController sc) async {
    final List<String> list = List<String>.from(sc.templates);
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setDlg) {
          Future<void> editOne([int? idx]) async {
            final TextEditingController ctl = TextEditingController(
                text: idx != null ? list[idx] : '');
            final String? v = await showDialog<String>(
              context: ctx,
              builder: (BuildContext d) => AlertDialog(
                title: Text(idx == null ? 'Новый шаблон' : 'Изменить шаблон'),
                content: TextField(
                  controller: ctl,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                      hintText: 'Текст заготовки…',
                      border: OutlineInputBorder()),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(d),
                      child: const Text('Отмена')),
                  FilledButton(
                      onPressed: () => Navigator.pop(d, ctl.text.trim()),
                      child: const Text('Сохранить')),
                ],
              ),
            );
            if (v == null || v.isEmpty) return;
            setDlg(() {
              if (idx == null) {
                list.add(v);
              } else {
                list[idx] = v;
              }
            });
            await sc.setTemplates(list);
          }

          return AlertDialog(
            title: const Text('Шаблоны заявок'),
            content: SizedBox(
              width: 420,
              height: 360,
              child: list.isEmpty
                  ? const Center(
                      child: Text('Пока пусто. Добавьте частые формулировки — '
                          'они появятся в редакторе заявки кнопкой «Шаблон».'))
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (BuildContext ctx, int i) => ListTile(
                        dense: true,
                        title: Text(list[i],
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        onTap: () => editOne(i),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            setDlg(() => list.removeAt(i));
                            await sc.setTemplates(list);
                          },
                        ),
                      ),
                    ),
            ),
            actions: [
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Добавить'),
                onPressed: () => editOne(),
              ),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Готово')),
            ],
          );
        },
      ),
    );
  }

  /// Ручной ввод адреса хоста (клиент).
  Future<void> _editHostAddress(BuildContext context, AppState app) async {
    final TextEditingController ctl = TextEditingController(text: app.hostAddress);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Адрес хоста'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: '192.168.1.50'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('Подключиться')),
        ],
      ),
    );
    if (ok == true && ctl.text.trim().isNotEmpty) {
      await app.connectToHost(ctl.text);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Подключение запущено в фоне')));
      }
    }
  }

  /// Автопоиск хоста по Wi-Fi (UDP broadcast) с выбором из найденных.
  Future<void> _discoverHosts(BuildContext context, AppState app) async {
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Flexible(child: Text('Поиск хоста в сети…')),
          ],
        ),
      ),
    ));
    final List<DiscoveredHost> hosts = await app.findHosts();
    if (!context.mounted) return;
    Navigator.of(context).pop(); // закрыть индикатор поиска
    if (hosts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Хост не найден. Проверьте, что хост запущен, или введите адрес вручную.')));
      return;
    }
    final String? chosen = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: const Text('Найденные хосты'),
        children: hosts
            .map((h) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, h.address),
                  child: Text('${h.name} (${h.address}:${h.port})'),
                ))
            .toList(),
      ),
    );
    if (chosen != null) {
      await app.connectToHost(chosen);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Подключение запущено в фоне')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final SettingsController sc = context.watch<SettingsController>();
    final AppState app = context.watch<AppState>();
    final LocalSettings s = sc.settings;
    final HostSettings hs = app.hs;

    Widget flag(String key, String title, [String? subtitle]) => SwitchListTile(
          title: Text(title),
          subtitle: subtitle != null ? Text(subtitle) : null,
          value: s.toJson()[key] ?? false,
          onChanged: (bool v) => sc.setFlag(key, v),
        );

    Widget hostFlag(String title, bool value, void Function(bool) set, [String? subtitle]) {
      return SwitchListTile(
        title: Text(title),
        subtitle: Text(subtitle != null
            ? '$subtitle · управляется хостом'
            : 'управляется хостом'),
        value: value,
        onChanged: app.isHost
            ? (bool v) {
                set(v);
                app.saveHostSettings(hs);
              }
            : null,
      );
    }

    /// Сворачиваемая категория настроек: заголовок с иконкой раскрывает
    /// карточку. Список длинный, поэтому свёрнуто всё, кроме подключения.
    Widget section({
      required IconData icon,
      required String title,
      required List<Widget> children,
      bool initiallyExpanded = false,
    }) =>
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          clipBehavior: Clip.antiAlias,
          elevation: 0.5,
          child: ExpansionTile(
            leading: Icon(icon),
            title: Text(title,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            initiallyExpanded: initiallyExpanded,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            children: children,
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // ---------- Подключение к хосту (только клиент) ----------
          if (!app.isHost)
            section(
              icon: Icons.dns_outlined,
              title: 'Подключение к хосту',
              initiallyExpanded: true,
              children: [
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('Адрес хоста'),
                  subtitle: Text(app.hostAddress.isEmpty
                      ? 'не задан'
                      : '${app.hostAddress}:${app.hostPort}'),
                  trailing: Text(app.connectionLabel),
                  onTap: () => _editHostAddress(context, app),
                ),
                ListTile(
                  leading: const Icon(Icons.wifi_find),
                  title: const Text('Найти хост в сети'),
                  subtitle: const Text('автопоиск по Wi-Fi'),
                  onTap: () => _discoverHosts(context, app),
                ),
              ],
            ),

          // ---------- Общие ----------
          section(
            icon: Icons.tune,
            title: 'Общие',
            children: [
              SwitchListTile(
                title: const Text('Тёмная тема'),
                value: s.darkTheme,
                onChanged: (bool v) => sc.setDarkTheme(v),
              ),
              flag('notifSound', 'Звук уведомлений'),
              flag('vibration', 'Вибрация (Android)'),
              flag('showDaySummary', 'Показывать сводку дня'),
              ListTile(
                title: const Text('Язык интерфейса'),
                trailing: DropdownButton<String>(
                  value: s.language,
                  items: const [
                    DropdownMenuItem(value: 'ru', child: Text('Русский')),
                    DropdownMenuItem(value: 'en', child: Text('English')),
                  ],
                  onChanged: (String? v) {
                    if (v != null) sc.setLanguage(v);
                  },
                ),
              ),
            ],
          ),

          // ---------- Уведомления ----------
          section(
            icon: Icons.notifications_outlined,
            title: 'Уведомления',
            children: [
              flag('notifNew', 'Новые заявки'),
              flag('notifChanges', 'Изменения заявок (уведомлять о каждой правке)'),
              flag('notifReminders', 'Напоминания'),
              flag('notifEscalation', '«Требует внимания» (нет реакции на заявку)'),
              flag('notifChat', 'Личные сообщения'),
              flag('soundNew', 'Звук для новых заявок'),
              flag('soundReminder', 'Звук для напоминаний и «Требует внимания»'),
              flag('dnd', 'Не беспокоить'),
              flag('workHoursEnabled', 'Рабочие часы для уведомлений'),
              if (s.workHoursEnabled)
                ListTile(
                  title: const Text('Интервал рабочих часов'),
                  trailing: Text('${s.workStart}:00–${s.workEnd}:00'),
                  onTap: () async {
                    final TimeOfDay? from = await showTimePicker(
                        context: context, initialTime: TimeOfDay(hour: s.workStart, minute: 0));
                    if (from == null || !context.mounted) return;
                    final TimeOfDay? to = await showTimePicker(
                        context: context, initialTime: TimeOfDay(hour: s.workEnd, minute: 0));
                    if (to == null) return;
                    sc.setWorkHours(from.hour, to.hour);
                  },
                ),
              flag('quietHoursEnabled', 'Тихие часы',
                  'в это время уведомления приходят без звука'),
              if (s.quietHoursEnabled)
                ListTile(
                  title: const Text('Тихие часы'),
                  trailing: Text('${s.quietStart}:00–${s.quietEnd}:00'),
                  onTap: () async {
                    final TimeOfDay? from = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay(hour: s.quietStart, minute: 0));
                    if (from == null || !context.mounted) return;
                    final TimeOfDay? to = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay(hour: s.quietEnd, minute: 0));
                    if (to == null) return;
                    sc.setQuietHours(from.hour, to.hour);
                  },
                ),
            ],
          ),

          // ---------- Голосовой ввод ----------
          section(
            icon: Icons.mic_none,
            title: 'Голосовой ввод',
            children: [
              flag('sttEnabled', 'Диктовка в текст', 'онлайн-распознавание (нужен интернет)'),
              flag('recordEnabled', 'Запись голоса (аудиовложение)'),
              flag('hybridEnabled', 'Гибридный режим (аудио + расшифровка)'),
              flag('autoTranscribe', 'Автоматическая расшифровка аудио'),
              flag('numbersToDigits', 'Числа цифрами',
                  '«тридцать килограмм» → «30 килограмм», телефоны — слитно: 89001234567'),
              flag('voiceCommandsEnabled', 'Голосовые команды'),
              ListTile(
                title: const Text('Язык распознавания'),
                trailing: DropdownButton<String>(
                  value: s.sttLocale,
                  items: const [
                    DropdownMenuItem(value: 'ru-RU', child: Text('Русский')),
                    DropdownMenuItem(value: 'en-US', child: Text('English')),
                  ],
                  onChanged: (String? v) {
                    if (v != null) sc.setSttLocale(v);
                  },
                ),
              ),
              // Диагностика распознавания: видно, какой движок доступен,
              // скачана ли автономная модель и какая была последняя ошибка.
              ListTile(
                leading: const Icon(Icons.mic_external_on_outlined),
                title: const Text('Проверка распознавания'),
                subtitle: const Text('состояние движка, модели и последняя ошибка'),
                trailing: TextButton(
                  child: const Text('Проверить'),
                  onPressed: () => _checkStt(context, app),
                ),
              ),
            ],
          ),

          // ---------- Аудио и хранение ----------
          section(
            icon: Icons.library_music_outlined,
            title: 'Аудио и хранение',
            children: [
              if (Platform.isAndroid)
                ListTile(
                  title: const Text('Усиление громкости голосовых'),
                  subtitle: Text(s.volumeBoostDb == 0
                      ? 'выкл. — стандартная громкость'
                      : '+${s.volumeBoostDb} дБ к стандартной громкости'),
                  trailing: SizedBox(
                    width: 170,
                    child: Slider(
                      value: s.volumeBoostDb.toDouble(),
                      min: 0,
                      max: 10,
                      divisions: 10,
                      label: s.volumeBoostDb == 0 ? '0' : '+${s.volumeBoostDb} дБ',
                      onChanged: (double v) => sc.setVolumeBoost(v.round()),
                    ),
                  ),
                ),
              hostFlag('Хранить аудиофайлы', hs.storeAudio, (bool v) => hs.storeAudio = v),
              hostFlag('Автоочистка аудио при «Выполнена»', hs.cleanupOnDone,
                  (bool v) => hs.cleanupOnDone = v),
              hostFlag('Автоочистка при «Отклонена/Отложена»', hs.cleanupOnRejected,
                  (bool v) => hs.cleanupOnRejected = v),
              hostFlag('Хранить журнал аудита', hs.auditEnabled, (bool v) => hs.auditEnabled = v),
              ListTile(
                title: const Text('Срок хранения аудио, дней'),
                subtitle: const Text('0 — не ограничен · управляется хостом'),
                trailing: SizedBox(
                  width: 90,
                  child: TextFormField(
                    initialValue: '${hs.audioKeepDays}',
                    enabled: app.isHost,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    onFieldSubmitted: (String v) {
                      hs.audioKeepDays = int.tryParse(v) ?? hs.audioKeepDays;
                      app.saveHostSettings(hs);
                    },
                  ),
                ),
              ),
              ListTile(
                title: const Text('Срок хранения сообщений, дней'),
                subtitle: const Text('0 — хранить всегда · управляется хостом'),
                trailing: SizedBox(
                  width: 90,
                  child: TextFormField(
                    initialValue: '${hs.chatKeepDays}',
                    enabled: app.isHost,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    onFieldSubmitted: (String v) {
                      hs.chatKeepDays = int.tryParse(v) ?? hs.chatKeepDays;
                      app.saveHostSettings(hs);
                    },
                  ),
                ),
              ),
            ],
          ),

          // ---------- «Требует внимания» и напоминания (хост) ----------
          section(
            icon: Icons.alarm,
            title: '«Требует внимания» и напоминания',
            children: [
              hostFlag('Отмечать «Требует внимания»', hs.escalationEnabled,
                  (bool v) => hs.escalationEnabled = v),
              ListTile(
                title: const Text('Нет реакции, минут'),
                subtitle: const Text('по умолчанию 30 · управляется хостом'),
                trailing: SizedBox(
                  width: 90,
                  child: TextFormField(
                    initialValue: '${hs.escalationMinutes}',
                    enabled: app.isHost,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    onFieldSubmitted: (String v) {
                      final int? n = int.tryParse(v);
                      if (n != null && n > 0) {
                        hs.escalationMinutes = n;
                        app.saveHostSettings(hs);
                      }
                    },
                  ),
                ),
              ),
              hostFlag('Отмечать заявку «Новая»', hs.escalateNew, (bool v) => hs.escalateNew = v),
              hostFlag('Отмечать при просрочке «В работе»', hs.escalateInProgress,
                  (bool v) => hs.escalateInProgress = v),
              hostFlag('Напоминания по времени', hs.remindersEnabled,
                  (bool v) => hs.remindersEnabled = v),
              hostFlag('Повторяющиеся напоминания', hs.recurringRemindersEnabled,
                  (bool v) => hs.recurringRemindersEnabled = v, 'по умолчанию выключены'),
              hostFlag('Только в рабочие часы', hs.escalationWorkHoursOnly,
                  (bool v) => hs.escalationWorkHoursOnly = v),
            ],
          ),

          // ---------- Заявки и отображение ----------
          section(
            icon: Icons.view_list_outlined,
            title: 'Заявки и отображение',
            children: [
              flag('showPinnedTop', 'Закреплённые — вверху списка'),
              flag('showColors', 'Цветовые метки'),
              flag('showPriority', 'Приоритет'),
              flag('showContactInList', 'Контакт в списке'),
              flag('showPresence', 'Индикатор присутствия'),
              flag('highlightOverdue', 'Подсветка просроченных'),
              flag('myByDefault', '«Мои заявки» по умолчанию'),
              flag('realtime', 'Автообновление списка в реальном времени'),
            ],
          ),

          // ---------- Контакты ----------
          section(
            icon: Icons.contacts_outlined,
            title: 'Контакты',
            children: [
              flag('showContacts', 'Библиотека адресов'),
              flag('callFromCard', 'Звонок из карточки заявки'),
              flag('contactLinkEnabled', 'Связь контакта с заявкой'),
            ],
          ),

          // ---------- Синхронизация и оффлайн ----------
          section(
            icon: Icons.sync,
            title: 'Синхронизация и оффлайн',
            children: [
              flag('offlineMode', 'Оффлайн-режим (локальный кэш)'),
              flag('autoSync', 'Автосинхронизация при возврате сети'),
              flag('showConnIndicator', 'Индикатор онлайн/оффлайн'),
              flag('conflictNotify', 'Уведомление о конфликте синхронизации'),
            ],
          ),

          // ---------- Фон и уведомления (Android) ----------
          section(
            icon: Icons.battery_saver,
            title: 'Фон и уведомления (телефон)',
            children: [
              SwitchListTile(
                title: const Text('Держать связь в фоне'),
                subtitle: const Text(
                    'Уведомления приходят, даже когда приложение закрыто. '
                    'В шторке будет тихое постоянное уведомление.'),
                value: app.ls.bgKeepAlive,
                onChanged: (bool v) {
                  unawaited(sc.setFlag('bgKeepAlive', v));
                  unawaited(app.background.setEnabled(v));
                },
              ),
              ListTile(
                leading: const Icon(Icons.battery_saver),
                title: const Text('Разрешить работу в фоне'),
                subtitle: const Text(
                    'Открывает системную настройку: исключить приложение из '
                    'экономии заряда — иначе Android может рвать связь.'),
                trailing: const Icon(Icons.open_in_new),
                onTap: () async {
                  await app.background.requestIgnoreBatteryOptimizations();
                },
              ),
            ],
          ),

          // ---------- Windows: трей и автозапуск (ПК-хост) ----------
          if (!kIsWeb && Platform.isWindows)
            section(
              icon: Icons.desktop_windows_outlined,
              title: 'Компьютер (Windows)',
              children: [
                flag('trayEnabled', 'Сворачивать в трей при закрытии',
                    'Крестик прячет окно — хост продолжает работать, телефоны '
                    'не теряют связь. Значок — рядом с часами.'),
                SwitchListTile(
                  title: const Text('Запускать вместе с Windows'),
                  subtitle: const Text(
                      'Приложение стартует само при включении компьютера '
                      'и сразу сворачивается в трей.'),
                  value: app.ls.autoStartWindows,
                  onChanged: (bool v) {
                    unawaited(sc.setFlag('autoStartWindows', v));
                    unawaited(TrayService.instance.setAutoStart(v));
                  },
                ),
              ],
            ),

          // ---------- Резервное копирование (хост) ----------
          section(
            icon: Icons.backup_outlined,
            title: 'Резервное копирование',
            children: [
              hostFlag('Автосохранение базы', hs.backupAuto, (bool v) => hs.backupAuto = v),
              hostFlag('Резервная копия при изменениях', hs.backupOnChanges,
                  (bool v) => hs.backupOnChanges = v, 'иначе — раз в час'),
              hostFlag('Ротация копий', hs.backupRotation, (bool v) => hs.backupRotation = v),
              ListTile(
                title: const Text('Хранить копий'),
                subtitle: const Text('по умолчанию 5 · управляется хостом'),
                trailing: SizedBox(
                  width: 90,
                  child: TextFormField(
                    initialValue: '${hs.backupKeep}',
                    enabled: app.isHost,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    onFieldSubmitted: (String v) {
                      final int? n = int.tryParse(v);
                      if (n != null && n > 0) {
                        hs.backupKeep = n;
                        app.saveHostSettings(hs);
                      }
                    },
                  ),
                ),
              ),
              hostFlag('Журнал в экспорт', hs.backupIncludeAudit,
                  (bool v) => hs.backupIncludeAudit = v),
              if (app.isHost) ...[
                ListTile(
                  leading: const Icon(Icons.save_outlined),
                  title: const Text('Создать копию сейчас'),
                  onTap: () async {
                    final f = await app.backupNow();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(f != null ? 'Копия создана: ${f.path}' : 'Ошибка копии')));
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.upload_file),
                  title: const Text('Экспорт в файл…'),
                  onTap: () async {
                    final String? path = await FilePicker.platform.saveFile(
                      dialogTitle: 'Экспорт резервной копии',
                      fileName: 'quickpad_backup.json',
                    );
                    if (path == null) return;
                    final f = await app.exportBackup(path);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(f != null ? 'Экспортировано: $path' : 'Ошибка экспорта')));
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.restore),
                  title: const Text('Восстановить из файла…'),
                  onTap: () async {
                    final FilePickerResult? r =
                        await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
                    final String? path = r?.files.single.path;
                    if (path == null) return;
                    final String? err = await app.importBackup(path);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(err ?? 'Восстановлено. Клиенты получат данные при синхронизации.')));
                    }
                  },
                ),
              ] else
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('Резервное копирование выполняется на хосте'),
                ),
            ],
          ),

          // ---------- Пользователи и устройство ----------
          section(
            icon: Icons.people_outline,
            title: 'Пользователи и устройство',
            children: [
              flag('userBinding', 'Привязка пользователя к устройству'),
              flag('showOnlineUsers', 'Показывать список онлайн-пользователей'),
              flag('allowUserSwitch', 'Разрешить смену пользователя на устройстве'),
              if (app.isHost) ...[
                const ListTile(
                  title: Text('Роли пользователей'),
                  subtitle: Text(
                      'руководитель видит все заявки и статистику, работник — свои'),
                ),
                for (final u in app.users)
                  SwitchListTile(
                    title: Text(u.name),
                    subtitle: Text(u.isManager ? 'Руководитель' : 'Работник'),
                    value: u.isManager,
                    onChanged: (bool v) =>
                        app.setUserRole(u, v ? 'manager' : 'worker'),
                  ),
              ],
            ],
          ),

          // ---------- Виджет и быстрые действия ----------
          section(
            icon: Icons.widgets_outlined,
            title: 'Виджет и быстрые действия (Android)',
            children: [
              flag('widgetEnabled', 'Виджет «Быстрая заметка»'),
              flag('quickLine', 'Быстрое создание в одну строку'),
              flag('voiceButton', 'Голосовая кнопка на главном экране'),
            ],
          ),

          // ---------- Отчёты ----------
          section(
            icon: Icons.bar_chart,
            title: 'Отчёты и статистика',
            children: [
              flag('statsEnabled', 'Экран статистики',
                  'сводка за день/неделю/месяц — кнопка в меню списка заявок'),
            ],
          ),

          // ---------- Шаблоны заявок ----------
          section(
            icon: Icons.notes,
            title: 'Шаблоны заявок',
            children: [
              ListTile(
                leading: const Icon(Icons.notes),
                title: const Text('Заготовки текста заявки'),
                subtitle: Text(sc.templates.isEmpty
                    ? 'например: «Закупить материалы для…» — вставляются '
                        'одним нажатием в редакторе заявки'
                    : 'шаблонов: ${sc.templates.length}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _editTemplates(context, sc),
              ),
            ],
          ),

          // ---------- Хранилище: очистка кэша и журнала ----------
          section(
            icon: Icons.cleaning_services_outlined,
            title: 'Хранилище',
            children: [
              ListTile(
                leading: const Icon(Icons.cleaning_services_outlined),
                title: const Text('Очистка кэша'),
                subtitle: Text(app.isHost
                    ? 'временные файлы, кэш фото и файлы без заявок на хосте'
                    : 'временные файлы и кэш фото на устройстве'),
                onTap: () => _cacheCleanup(context, app),
              ),
              if (app.isHost)
                ListTile(
                  leading: const Icon(Icons.history_toggle_off),
                  title: const Text('Очистить журнал'),
                  subtitle: const Text(
                      'история изменений удалится на хосте и на всех устройствах'),
                  onTap: () => _confirmClearAudit(context, app),
                ),
            ],
          ),

          const SizedBox(height: 12),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            elevation: 0.5,
            child: ListTile(
              leading: const Icon(Icons.replay_circle_filled_outlined),
              title: const Text('Изменить роль устройства / хост'),
              subtitle: const Text('повторить первоначальную настройку'),
              onTap: () async {
                await app.resetConfiguration();
                if (context.mounted) {
                  Navigator.of(context).pushNamedAndRemoveUntil('/', (_) => false);
                }
              },
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
