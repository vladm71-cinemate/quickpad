import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/settings.dart';
import '../net/discovery.dart';
import '../state/app_state.dart';
import '../state/settings_controller.dart';

/// Настройки (ТЗ, раздел 6, таблицы 6.1–6.11).
/// Локальные — на этом устройстве; хостовые — «управляется хостом»,
/// редактируются только на хосте, на клиентах — только просмотр.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

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

    Widget header(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(title,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        children: [
          // ---------- Подключение к хосту (только клиент) ----------
          if (!app.isHost) ...[
            header('Подключение к хосту'),
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

          // ---------- 6.1 Общие ----------
          header('6.1 Общие'),
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

          // ---------- 6.2 Уведомления ----------
          header('6.2 Уведомления'),
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

          // ---------- 6.3 Голосовой ввод ----------
          header('6.3 Голосовой ввод'),
          flag('sttEnabled', 'Диктовка в текст', 'онлайн-распознавание (нужен интернет)'),
          flag('recordEnabled', 'Запись голоса (аудиовложение)'),
          flag('hybridEnabled', 'Гибридный режим (аудио + расшифровка)'),
          flag('autoTranscribe', 'Автоматическая расшифровка аудио'),
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

          // ---------- 6.4 Аудио и хранение (хост) ----------
          header('6.4 Аудио и хранение'),
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

          // ---------- 6.5 «Требует внимания» и напоминания (хост) ----------
          header('6.5 «Требует внимания» и напоминания'),
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

          // ---------- 6.6 Заявки и отображение ----------
          header('6.6 Заявки и отображение'),
          flag('showPinnedTop', 'Закреплённые — вверху списка'),
          flag('showColors', 'Цветовые метки'),
          flag('showPriority', 'Приоритет'),
          flag('showContactInList', 'Контакт в списке'),
          flag('showPresence', 'Индикатор присутствия'),
          flag('highlightOverdue', 'Подсветка просроченных'),
          flag('myByDefault', '«Мои заявки» по умолчанию'),
          flag('realtime', 'Автообновление списка в реальном времени'),

          // ---------- 6.7 Контакты ----------
          header('6.7 Контакты'),
          flag('showContacts', 'Библиотека адресов'),
          flag('callFromCard', 'Звонок из карточки заявки'),
          flag('contactLinkEnabled', 'Связь контакта с заявкой'),

          // ---------- 6.8 Синхронизация и оффлайн ----------
          header('6.8 Синхронизация и оффлайн'),
          flag('offlineMode', 'Оффлайн-режим (локальный кэш)'),
          flag('autoSync', 'Автосинхронизация при возврате сети'),
          flag('showConnIndicator', 'Индикатор онлайн/оффлайн'),
          flag('conflictNotify', 'Уведомление о конфликте синхронизации'),

          // ---------- 6.9 Резервное копирование (хост) ----------
          header('6.9 Резервное копирование'),
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

          // ---------- 6.10 Пользователи и устройство ----------
          header('6.10 Пользователи и устройство'),
          flag('userBinding', 'Привязка пользователя к устройству'),
          flag('showOnlineUsers', 'Показывать список онлайн-пользователей'),
          flag('allowUserSwitch', 'Разрешить смену пользователя на устройстве'),

          // ---------- 6.11 Виджет и быстрые действия ----------
          header('6.11 Виджет и быстрые действия (Android)'),
          flag('widgetEnabled', 'Виджет «Быстрая заметка»'),
          flag('quickLine', 'Быстрое создание в одну строку'),
          flag('voiceButton', 'Голосовая кнопка на главном экране'),

          const SizedBox(height: 24),
          ListTile(
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
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
