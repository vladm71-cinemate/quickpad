import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/timefmt.dart';
import '../models/audit_entry.dart';
import '../models/contact.dart';
import '../models/enums.dart';
import '../models/note.dart';
import '../services/voice_commands.dart';
import '../state/app_state.dart';
import 'note_edit_screen.dart';

/// Карточка заявки (ТЗ 4.3): все поля, смена статуса, закрепление,
/// аудио + расшифровка, история изменений из журнала.
/// Голосовые команды в контексте заявки: «сменить статус…», «закрепить»,
/// «напомни через…», «позвонить контакту…».
class NoteDetailScreen extends StatefulWidget {
  const NoteDetailScreen({super.key, required this.noteId});

  final String noteId;

  @override
  State<NoteDetailScreen> createState() => _NoteDetailScreenState();
}

class _NoteDetailScreenState extends State<NoteDetailScreen> {
  bool _playing = false;
  bool _listening = false;

  @override
  void dispose() {
    final AppState app = context.read<AppState>();
    unawaited(app.audio.stopPlay());
    unawaited(app.stt.stop());
    super.dispose();
  }

  Future<void> _voiceCommand(Note note) async {
    final AppState app = context.read<AppState>();
    if (!app.stt.isSupported) {
      _toast('На Windows используйте системную диктовку (Win+H)');
      return;
    }
    if (!app.stt.isAvailable) {
      _toast('Распознавание недоступно');
      return;
    }
    if (_listening) {
      await app.stt.stop();
      setState(() => _listening = false);
      return;
    }
    setState(() => _listening = true);
    String last = '';
    await app.stt.start(
      localeId: app.ls.sttLocale,
      onResult: (String text, bool isFinal) {
        last = text;
        if (isFinal && mounted) {
          setState(() => _listening = false);
          _handleCommand(note, last);
        }
      },
    );
    Timer(const Duration(seconds: 8), () async {
      if (_listening) {
        await app.stt.stop();
        if (mounted) setState(() => _listening = false);
        if (last.isNotEmpty) _handleCommand(note, last);
      }
    });
  }

  Future<void> _handleCommand(Note note, String text) async {
    final AppState app = context.read<AppState>();
    final VoiceIntent intent = VoiceCommands.parse(text);
    switch (intent.type) {
      case VoiceIntentType.setStatus:
        if (intent.status != null) {
          await app.setStatus(note, intent.status!);
          _toast('Статус: ${intent.status!.label}');
        } else if (intent.candidates.isNotEmpty) {
          _chooseStatus(note, intent.candidates);
        }
        break;
      case VoiceIntentType.pin:
        await _togglePin(note);
        break;
      case VoiceIntentType.unpin:
        if (app.isPinned(note.id)) await _togglePin(note);
        break;
      case VoiceIntentType.remind:
        final Duration? d = intent.remindIn;
        if (d != null) {
          final Note after = note.copy()
            ..reminder = Reminder(
                at: DateTime.now().toUtc().add(d), recipients: ReminderRecipients.author);
          await app.updateNote(note, after);
          _toast('Напомню через ${d.inMinutes >= 60 ? '${d.inHours} ч' : '${d.inMinutes} мин'}');
        } else {
          _toast('Скажите, например: «напомни через 30 минут»');
        }
        break;
      case VoiceIntentType.callContact:
        await _call(note);
        break;
      default:
        _toast('Команда не распознана. Доступны: статус, закрепить, напомни, позвонить.');
    }
  }

  void _chooseStatus(Note note, List<String> candidates) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: const Text('Выберите статус'),
        children: NoteStatus.values
            .map((s) => SimpleDialogOption(
                  onPressed: () {
                    Navigator.pop(ctx);
                    context.read<AppState>().setStatus(note, s);
                  },
                  child: Text(s.label),
                ))
            .toList(),
      ),
    );
  }

  Future<void> _togglePin(Note note) async {
    final String? warning = await context.read<AppState>().togglePin(note);
    if (warning != null) _toast(warning);
  }

  Future<void> _call(Note note) async {
    final AppState app = context.read<AppState>();
    final Contact? c = note.contactId == null
        ? null
        : app.contacts.firstWhereOrNull((x) => x.id == note.contactId);
    if (c == null || c.phone.isEmpty) {
      _toast('К заявке не привязан контакт с телефоном');
      return;
    }
    if (!app.ls.callFromCard) {
      _toast('Звонок из карточки отключён в настройках');
      return;
    }
    final Uri uri = Uri.parse('tel:${c.phone}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      _toast('Позвонить: ${c.phone}');
    }
  }

  Future<void> _toggleAudio(Note note) async {
    final AppState app = context.read<AppState>();
    if (_playing) {
      await app.audio.stopPlay();
      setState(() => _playing = false);
      return;
    }
    final String loc = app.audioLocation(note.audio!.fileName);
    if (app.isHost) {
      await app.audio.playLocal(loc);
    } else {
      await app.audio.play(loc);
    }
    app.audio.onComplete(() {
      if (mounted) setState(() => _playing = false);
    });
    setState(() => _playing = true);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final AppState app = context.watch<AppState>();
    final Note? note = app.noteById(widget.noteId);
    if (note == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Заявка')),
        body: const Center(child: Text('Заявка не найдена')),
      );
    }
    final Contact? contact = note.contactId == null
        ? null
        : app.contacts.firstWhereOrNull((c) => c.id == note.contactId);
    final List<AuditEntry> history = app.auditForNote(note.id);
    final bool pinned = app.isPinned(note.id);

    return Scaffold(
      appBar: AppBar(
        title: Text('Заявка · ${note.status.label}'),
        actions: [
          IconButton(
            icon: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
            tooltip: pinned ? 'Открепить' : 'Закрепить',
            onPressed: () => _togglePin(note),
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Редактировать',
            onPressed: () => Navigator.of(context)
                .pushNamed('/edit', arguments: NoteEditArgs(noteId: note.id)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (note.colorValue != null)
            Container(height: 6, color: Color(note.colorValue!)),
          const SizedBox(height: 8),
          SelectableText(note.text, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              Text('Автор: ${app.userName(note.authorId)}'),
              Text('Создана: ${formatDateTime(note.createdAt)}'),
              Text('Изменена: ${formatRelative(note.updatedAt)}'),
              if (note.escalated) const Text('⚠ Эскалирована', style: TextStyle(color: Colors.red)),
            ],
          ),
          const Divider(height: 24),
          _row('Статус', Wrap(
            spacing: 6,
            children: NoteStatus.values
                .map((s) => ChoiceChip(
                    label: Text(s.label),
                    selected: note.status == s,
                    onSelected: (_) => app.setStatus(note, s)))
                .toList(),
          )),
          _row('Исполнитель', Text(note.assigneeId == null ? '—' : app.userName(note.assigneeId!))),
          _row('Приоритет', Text(note.priority?.label ?? '—')),
          _row('Дедлайн', Text(note.deadline == null
              ? '—'
              : '${formatDateTime(note.deadline!)} (${formatDeadline(note.deadline!)})')),
          _row('Напоминание', Text(note.reminder == null
              ? '—'
              : '${formatDateTime(note.reminder!.at)} · ${note.reminder!.recipients.label}'
                  '${note.reminder!.repeat ? ' · повтор' : ''}')),
          _row('Теги', Text(note.tags.isEmpty ? '—' : note.tags.map((t) => '#$t').join(' '))),
          if (contact != null)
            _row('Контакт', Row(
              children: [
                Expanded(child: Text('${contact.name} ${contact.phone}')),
                if (contact.phone.isNotEmpty && app.ls.callFromCard)
                  IconButton(
                    icon: const Icon(Icons.call),
                    tooltip: 'Позвонить',
                    onPressed: () => _call(note),
                  ),
              ],
            )),
          if (note.audio != null) ...[
            const Divider(height: 24),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: IconButton(
                icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
                onPressed: note.audio!.deleted ? null : () => _toggleAudio(note),
              ),
              title: Text(note.audio!.deleted
                  ? 'Аудио удалено автоочисткой'
                  : 'Аудиозапись · ${note.audio!.durationSec} c'),
              subtitle: note.audio!.transcript != null
                  ? Text('Расшифровка: ${note.audio!.transcript}')
                  : null,
            ),
          ],
          const Divider(height: 24),
          Text('История изменений', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          if (history.isEmpty) const Text('Пока пусто'),
          ...history.map((e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(formatDateTime(e.at),
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(width: 8),
                    Expanded(child: Text(e.describe(app.userName))),
                  ],
                ),
              )),
          const SizedBox(height: 80),
        ],
      ),
      floatingActionButton: FloatingActionButton.small(
        heroTag: 'voice_detail',
        tooltip: 'Голосовая команда',
        onPressed: () => _voiceCommand(note),
        child: Icon(_listening ? Icons.mic : Icons.mic_none),
      ),
    );
  }

  Widget _row(String label, Widget value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(child: value),
        ],
      ),
    );
  }
}
