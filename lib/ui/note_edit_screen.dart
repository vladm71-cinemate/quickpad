import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../core/timefmt.dart';
import '../models/contact.dart';
import '../models/enums.dart';
import '../models/note.dart';
import '../models/user.dart';
import '../services/audio_service.dart';
import '../state/app_state.dart';
import 'stt_helper.dart';

/// Аргументы экрана редактирования.
class NoteEditArgs {
  const NoteEditArgs({this.noteId, this.initialText});

  /// null — создание новой заявки.
  final String? noteId;

  /// Предзаполненный текст (виджет «быстрая заметка», голос).
  final String? initialText;
}

/// Создание/редактирование заявки (ТЗ 4.1–4.3):
/// текст, диктовка, аудиозапись/гибрид, статус, исполнитель, приоритет,
/// дедлайн, напоминание (вкл. повторяющиеся), теги, цветовая метка, контакт.
class NoteEditScreen extends StatefulWidget {
  const NoteEditScreen({super.key, this.args});

  final NoteEditArgs? args;

  @override
  State<NoteEditScreen> createState() => _NoteEditScreenState();
}

class _NoteEditScreenState extends State<NoteEditScreen> {
  final TextEditingController _textCtl = TextEditingController();
  final TextEditingController _tagsCtl = TextEditingController();

  Note? _original;
  NoteStatus _status = NoteStatus.fresh;
  String? _assigneeId;
  NotePriority? _priority;
  DateTime? _deadline;
  Reminder? _reminder;
  int? _colorValue;
  String? _contactId;
  AudioAttachment? _audio;

  bool _dictating = false;
  bool _recording = false;
  bool _playingAudio = false;
  DateTime? _recStarted;
  String _recTranscript = ''; // буфер расшифровки гибридного режима
  bool _saving = false;

  bool get _isNew => _original == null;

  @override
  void initState() {
    super.initState();
    final AppState app = context.read<AppState>();
    final NoteEditArgs? args = widget.args;
    if (args?.noteId != null) {
      final Note? n = app.noteById(args!.noteId!);
      if (n != null) {
        _original = n.copy();
        _textCtl.text = n.text;
        _status = n.status;
        _assigneeId = n.assigneeId;
        _priority = n.priority;
        _deadline = n.deadline;
        _reminder = n.reminder == null
            ? null
            : Reminder(
                at: n.reminder!.at,
                recipients: n.reminder!.recipients,
                repeat: n.reminder!.repeat,
                repeatInterval: n.reminder!.repeatInterval,
                firedAt: n.reminder!.firedAt);
        _colorValue = n.colorValue;
        _contactId = n.contactId;
        _audio = n.audio;
        _tagsCtl.text = n.tags.join(', ');
      }
    } else if (args?.initialText != null) {
      _textCtl.text = args!.initialText!;
    }
  }

  @override
  void dispose() {
    _textCtl.dispose();
    _tagsCtl.dispose();
    super.dispose();
  }

  // ---------- Голос ----------

  Future<void> _toggleDictation() async {
    final AppState app = context.read<AppState>();
    if (_dictating) {
      await app.stt.stop();
      setState(() => _dictating = false);
      return;
    }
    if (!app.stt.isSupported) {
      _toast('На Windows используйте системную диктовку: Win+H в поле текста');
      return;
    }
    // Ленивая инициализация: разрешение на микрофон запросится здесь.
    if (!app.stt.isAvailable && !await app.stt.init()) {
      if (mounted) await showSttError(context, app.stt);
      return;
    }
    setState(() => _dictating = true);
    final bool ok = await app.stt.start(
      localeId: app.ls.sttLocale,
      continuous: true, // не отключается на паузах: перезапускается само
      onResult: (String text, bool isFinal) {
        _textCtl.text = text;
        _textCtl.selection = TextSelection.collapsed(offset: text.length);
      },
    );
    if (!ok && mounted) setState(() => _dictating = false);
  }

  Future<void> _toggleRecording() async {
    final AppState app = context.read<AppState>();
    if (_recording) {
      final RecordedAudio? rec = await app.audio.stopRecording();
      // Остановить параллельную расшифровку (гибридный режим).
      await app.stt.stop();
      setState(() => _recording = false);
      if (rec == null) {
        _toast('Запись не удалась');
        return;
      }
      final AudioAttachment? att = await app.attachAudio(rec);
      if (att == null) {
        _toast('Не удалось передать аудио на хост');
        return;
      }
      // Гибридный режим (ТЗ 4.1): аудио + автоматическая расшифровка в текст.
      // Аудио хранится рядом с заявкой, текст остаётся редактируемым.
      final String transcript = _recTranscript.trim();
      if (transcript.isNotEmpty) {
        att.transcript = transcript;
        if (_textCtl.text.trim().isEmpty) {
          _textCtl.text = transcript; // текст можно править
          _textCtl.selection =
              TextSelection.collapsed(offset: _textCtl.text.length);
        }
      }
      setState(() => _audio = att);
    } else {
      final bool ok = await app.audio.startRecording();
      if (!ok) {
        _toast('Нет доступа к микрофону');
        return;
      }
      setState(() {
        _recording = true;
        _recStarted = DateTime.now();
        _recTranscript = '';
      });
      // Гибридный режим: параллельно с записью распознаём речь в текст.
      // Если микрофон не делится на этом устройстве — останется просто аудио.
      if (app.ls.hybridEnabled && app.ls.autoTranscribe && app.stt.isSupported) {
        if (!app.stt.isAvailable) await app.stt.init();
        if (app.stt.isAvailable && _recording) {
          unawaited(app.stt.start(
            localeId: app.ls.sttLocale,
            continuous: true,
            onResult: (String text, bool isFinal) {
              _recTranscript = text;
              if (_recording && mounted) setState(() {});
            },
          ));
        }
      }
    }
  }

  Future<void> _toggleAudioPlay() async {
    final AppState app = context.read<AppState>();
    if (_playingAudio) {
      await app.audio.stopPlay();
      setState(() => _playingAudio = false);
      return;
    }
    final AudioAttachment? att = _audio;
    if (att == null || att.deleted) return;
    final String loc = app.audioLocation(att.fileName);
    if (app.isHost) {
      await app.audio.playLocal(loc);
    } else {
      await app.audio.play(loc);
    }
    app.audio.onComplete(() {
      if (mounted) setState(() => _playingAudio = false);
    });
    setState(() => _playingAudio = true);
  }

  /// Выбор контакта с поиском по вхождению (как глобальный поиск):
  /// совпадение в любом месте имени/телефона/комментария, ближе к началу — выше.
  Future<void> _pickContact() async {
    final AppState app = context.read<AppState>();
    String q = '';
    final List<Contact> sorted = List<Contact>.from(app.contacts)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    List<Contact> rank() {
      final String query = q.trim().toLowerCase();
      if (query.isEmpty) return sorted;
      final String qd = query.replaceAll(RegExp(r'\D'), '');
      final List<MapEntry<Contact, int>> scored = [];
      for (final Contact c in sorted) {
        final String corpus =
            '${c.name}\n${c.phone}\n${c.comment}'.toLowerCase();
        int pos = corpus.indexOf(query);
        if (pos < 0 && qd.length >= 3) {
          pos = c.phone.replaceAll(RegExp(r'\D'), '').indexOf(qd);
          if (pos >= 0) pos += 1000; // телефон — после имени
        }
        if (pos >= 0) scored.add(MapEntry(c, pos));
      }
      scored.sort((a, b) => a.value.compareTo(b.value));
      return scored.map((e) => e.key).toList();
    }

    final Contact? picked = await showDialog<Contact>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setDlg) => AlertDialog(
          title: const Text('Выбор контакта'),
          content: SizedBox(
            width: 400,
            height: 380,
            child: Column(
              children: [
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Имя или телефон…',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (String v) => setDlg(() => q = v),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Builder(builder: (BuildContext ctx) {
                    final List<Contact> list = rank();
                    if (list.isEmpty) {
                      return const Center(child: Text('Ничего не найдено'));
                    }
                    return ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (BuildContext ctx, int i) {
                        final Contact c = list[i];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.person_outline),
                          title: Text(c.name),
                          subtitle: c.phone.isEmpty ? null : Text(c.phone),
                          onTap: () => Navigator.pop(ctx, c),
                        );
                      },
                    );
                  }),
                ),
              ],
            ),
          ),
          actions: [
            if (_contactId != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, Contact(id: '', name: '')),
                child: const Text('Убрать контакт'),
              ),
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _contactId = picked.id.isEmpty ? null : picked.id);
  }

  /// Выбор исполнителя с поиском по вхождению — как выбор контакта.
  Future<void> _pickAssignee() async {
    final AppState app = context.read<AppState>();
    String q = '';
    final List<AppUser> sorted = List<AppUser>.from(app.users)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    List<AppUser> rank() {
      final String query = q.trim().toLowerCase();
      if (query.isEmpty) return sorted;
      final List<MapEntry<AppUser, int>> scored = [];
      for (final AppUser u in sorted) {
        final int pos = u.name.toLowerCase().indexOf(query);
        if (pos >= 0) scored.add(MapEntry(u, pos));
      }
      scored.sort((a, b) => a.value.compareTo(b.value));
      return scored.map((e) => e.key).toList();
    }

    final AppUser? picked = await showDialog<AppUser>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setDlg) => AlertDialog(
          title: const Text('Выбор исполнителя'),
          content: SizedBox(
            width: 400,
            height: 380,
            child: Column(
              children: [
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Имя…',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (String v) => setDlg(() => q = v),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Builder(builder: (BuildContext ctx) {
                    final List<AppUser> list = rank();
                    if (list.isEmpty) {
                      return const Center(child: Text('Ничего не найдено'));
                    }
                    return ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (BuildContext ctx, int i) {
                        final AppUser u = list[i];
                        return ListTile(
                          dense: true,
                          leading: Icon(Icons.person_outline,
                              color: u.online ? Colors.green : null),
                          title: Text(u.name),
                          subtitle: u.online ? const Text('в сети') : null,
                          onTap: () => Navigator.pop(ctx, u),
                        );
                      },
                    );
                  }),
                ),
              ],
            ),
          ),
          actions: [
            if (_assigneeId != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, AppUser(id: '', name: '')),
                child: const Text('Убрать исполнителя'),
              ),
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _assigneeId = picked.id.isEmpty ? null : picked.id);
  }

  // ---------- Выбор даты/времени ----------

  Future<DateTime?> _pickDateTime(DateTime? initial) async {
    final DateTime now = DateTime.now();
    final DateTime? date = await showDatePicker(
      context: context,
      initialDate: initial ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365 * 2)),
      locale: const Locale('ru'),
    );
    if (date == null || !mounted) return null;
    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial ?? now),
    );
    if (time == null) return DateTime(date.year, date.month, date.day, 23, 59);
    return DateTime(date.year, date.month, date.day, time.hour, time.minute).toUtc();
  }

  Future<void> _editReminder() async {
    final DateTime? at = await _pickDateTime(_reminder?.at);
    if (at == null || !mounted) return;
    ReminderRecipients recipients = _reminder?.recipients ?? ReminderRecipients.all;
    bool repeat = _reminder?.repeat ?? false;
    int repeatHours = _reminder?.repeatInterval?.inHours ?? 1;
    final bool recurringAllowed = context.read<AppState>().hs.recurringRemindersEnabled;

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setDlg) => AlertDialog(
          title: const Text('Напоминание'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Когда: ${formatDateTime(at)}'),
              const SizedBox(height: 8),
              DropdownButtonFormField<ReminderRecipients>(
                initialValue: recipients,
                decoration: const InputDecoration(labelText: 'Кому'),
                items: ReminderRecipients.values
                    .map((r) => DropdownMenuItem(value: r, child: Text(r.label)))
                    .toList(),
                onChanged: (ReminderRecipients? v) =>
                    setDlg(() => recipients = v ?? ReminderRecipients.all),
              ),
              if (recurringAllowed) ...[
                SwitchListTile(
                  title: const Text('Повторяющееся'),
                  value: repeat,
                  onChanged: (bool v) => setDlg(() => repeat = v),
                ),
                if (repeat)
                  DropdownButtonFormField<int>(
                    initialValue: repeatHours,
                    decoration: const InputDecoration(labelText: 'Интервал повтора'),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('каждый час')),
                      DropdownMenuItem(value: 3, child: Text('каждые 3 часа')),
                      DropdownMenuItem(value: 24, child: Text('каждый день')),
                    ],
                    onChanged: (int? v) => setDlg(() => repeatHours = v ?? 1),
                  ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ОК')),
          ],
        ),
      ),
    );
    if (ok == true) {
      setState(() {
        _reminder = Reminder(
          at: at,
          recipients: recipients,
          repeat: repeat && recurringAllowed,
          repeatInterval: repeat ? Duration(hours: repeatHours) : null,
        );
      });
    }
  }

  Future<void> _pickColor() async {
    Color selected = _colorValue != null ? Color(_colorValue!) : Colors.transparent;
    final int? result = await showDialog<int>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setDlg) => AlertDialog(
          title: const Text('Цветовая метка'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    // «Нет метки»
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx, -1),
                      child: CircleAvatar(
                        backgroundColor: Colors.transparent,
                        child: Icon(Icons.block,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                      ),
                    ),
                    ...kLabelPalette.map((int c) => GestureDetector(
                          onTap: () => Navigator.pop(ctx, c),
                          child: CircleAvatar(backgroundColor: Color(c), radius: 18),
                        )),
                  ],
                ),
                const Divider(height: 24),
                const Text('Свой цвет:'),
                ColorPicker(
                  pickerColor: selected,
                  onColorChanged: (Color c) => selected = c,
                  enableAlpha: false,
                  labelTypes: const [ColorLabelType.hex],
                  pickerAreaHeightPercent: 0.5,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, selected.toARGB32()),
              child: const Text('Выбрать'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    setState(() => _colorValue = result == -1 ? null : result);
  }

  // ---------- Сохранение ----------

  Future<void> _save() async {
    final AppState app = context.read<AppState>();
    if (_textCtl.text.trim().isEmpty) {
      _toast('Текст заявки обязателен');
      return;
    }
    setState(() => _saving = true);
    final List<String> tags = _tagsCtl.text
        .split(RegExp(r'[,\s]+'))
        .map((e) => e.trim().replaceAll('#', ''))
        .where((e) => e.isNotEmpty)
        .toList();

    if (_isNew) {
      await app.createNote(
        text: _textCtl.text,
        assigneeId: _assigneeId,
        priority: _priority,
        deadline: _deadline,
        reminder: _reminder,
        tags: tags,
        colorValue: _colorValue,
        contactId: _contactId,
        audioAttachment: _audio,
      );
    } else {
      final Note after = _original!.copy()
        ..text = _textCtl.text.trim()
        ..status = _status
        ..assigneeId = _assigneeId
        ..priority = _priority
        ..deadline = _deadline
        ..reminder = _reminder
        ..tags = tags
        ..colorValue = _colorValue
        ..contactId = _contactId
        ..audio = _audio;
      await app.updateNote(_original!, after);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final AppState app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Новая заявка' : 'Редактирование'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  textStyle: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15),
                ),
                icon: const Icon(Icons.check_circle),
                label: Text(_isNew ? 'Создать' : 'Сохранить'),
                onPressed: _save,
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Дата и время создания проставляются автоматически.
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _isNew
                  ? 'Создаётся: ${formatDateTime(DateTime.now())}'
                  : 'Создана: ${formatDateTime(_original!.createdAt)} · ${app.userName(_original!.authorId)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          TextField(
            controller: _textCtl,
            minLines: 3,
            maxLines: 8,
            autofocus: _isNew && (widget.args?.initialText == null),
            decoration: const InputDecoration(
              labelText: 'Текст заявки *',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (app.ls.sttEnabled)
                ActionChip(
                  avatar: Icon(_dictating ? Icons.mic : Icons.mic_none, size: 18),
                  label: Text(_dictating ? 'Идёт диктовка…' : 'Диктовка'),
                  onPressed: _toggleDictation,
                ),
              if (app.ls.recordEnabled)
                ActionChip(
                  avatar: Icon(_recording ? Icons.stop : Icons.mic,
                      size: 18, color: _recording ? Colors.red : null),
                  label: Text(_recording
                      ? 'Стоп (${DateTime.now().difference(_recStarted ?? DateTime.now()).inSeconds} c)'
                      : 'Запись голоса'),
                  onPressed: _toggleRecording,
                ),
            ],
          ),
          if (_recording && _recTranscript.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Расшифровка: $_recTranscript',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).colorScheme.primary),
              ),
            ),
          if (_audio != null)
            ListTile(
              leading: _audio!.deleted
                  ? const Icon(Icons.audiotrack)
                  : IconButton(
                      icon: Icon(_playingAudio ? Icons.stop : Icons.play_arrow),
                      tooltip: _playingAudio ? 'Стоп' : 'Прослушать',
                      onPressed: _toggleAudioPlay,
                    ),
              title: Text(_audio!.deleted ? 'Аудио удалено автоочисткой' : 'Аудиозапись прикреплена'),
              subtitle: _audio!.deleted ? null : Text('${_audio!.durationSec} c · ${(_audio!.sizeBytes / 1024).toStringAsFixed(0)} КБ'),
              trailing: _audio!.deleted
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Убрать аудио',
                      onPressed: () => setState(() => _audio = null),
                    ),
            ),
          const Divider(height: 24),
          if (!_isNew) ...[
            _section('Статус'),
            Wrap(
              spacing: 8,
              children: NoteStatus.values
                  .map((s) => ChoiceChip(
                      label: Text(s.label),
                      selected: _status == s,
                      onSelected: (_) => setState(() => _status = s)))
                  .toList(),
            ),
            const SizedBox(height: 12),
          ],
          _section('Исполнитель'),
          OutlinedButton.icon(
            icon: const Icon(Icons.person_search),
            label: Text(_assigneeId == null
                ? 'Выбрать исполнителя (с поиском)'
                : app.userName(_assigneeId!)),
            onPressed: _pickAssignee,
          ),
          const SizedBox(height: 12),
          _section('Приоритет'),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Без приоритета'),
                selected: _priority == null,
                onSelected: (_) => setState(() => _priority = null),
              ),
              ...NotePriority.values.map((p) => ChoiceChip(
                  label: Text(p.label),
                  selected: _priority == p,
                  onSelected: (_) => setState(() => _priority = p))),
            ],
          ),
          const SizedBox(height: 12),
          _section('Срок исполнения и напоминание'),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.event),
                  label: Text(_deadline == null ? 'Срок исполнения' : formatDateTime(_deadline!)),
                  onPressed: () async {
                    final DateTime? dt = await _pickDateTime(_deadline);
                    if (dt != null) setState(() => _deadline = dt);
                  },
                ),
              ),
              if (_deadline != null)
                IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() => _deadline = null),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.alarm),
                  label: Text(_reminder == null
                      ? 'Напоминание'
                      : '${formatDateTime(_reminder!.at)} · ${_reminder!.recipients.label}'),
                  onPressed: _editReminder,
                ),
              ),
              if (_reminder != null)
                IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() => _reminder = null),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _section('Теги'),
          TextField(
            controller: _tagsCtl,
            decoration: const InputDecoration(
              hintText: 'срочно, склад',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          _section('Цветовая метка'),
          Row(
            children: [
              GestureDetector(
                onTap: _pickColor,
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor:
                      _colorValue != null ? Color(_colorValue!) : Colors.transparent,
                  child: _colorValue == null ? const Icon(Icons.block) : null,
                ),
              ),
              const SizedBox(width: 12),
              TextButton(onPressed: _pickColor, child: const Text('Выбрать цвет')),
              if (_colorValue != null)
                Text('#${_colorValue!.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}'),
            ],
          ),
          if (app.ls.contactLinkEnabled) ...[
            const SizedBox(height: 12),
            _section('Контакт'),
            Builder(builder: (BuildContext ctx) {
              final Contact? sel = _contactId == null
                  ? null
                  : app.contacts.firstWhereOrNull((c) => c.id == _contactId);
              return OutlinedButton.icon(
                icon: const Icon(Icons.contacts),
                label: Text(sel == null
                    ? 'Выбрать контакт (с поиском)'
                    : '${sel.name}${sel.phone.isEmpty ? '' : ' · ${sel.phone}'}'),
                onPressed: _pickContact,
              );
            }),
          ],
          const SizedBox(height: 24),
          // Крупная заметная кнопка подтверждения (ТЗ: жирная, цветная).
          FilledButton.icon(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
              textStyle:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.check_circle, size: 26),
            label: Text(_isNew ? 'Создать заявку' : 'Сохранить'),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(title, style: Theme.of(context).textTheme.labelLarge),
      );
}
