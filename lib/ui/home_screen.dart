import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants.dart';
import '../core/timefmt.dart';
import '../models/contact.dart';
import '../models/enums.dart';
import '../models/note.dart';
import '../services/voice_commands.dart';
import '../state/app_state.dart';
import 'note_edit_screen.dart';

/// Главный экран (ТЗ 4.2): сводка дня, поиск, фильтры, список заявок,
/// индикатор связи, кнопки «+» и голосовых команд.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _query = '';
  bool _mineOnly = false;
  NoteStatus? _statusFilter;
  Timer? _timer;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    // Обновление «просрочено» и относительного времени раз в 30 секунд.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final AppState app = context.read<AppState>();
      _mineOnly = app.ls.myByDefault;
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // ---------- Голосовые команды (ТЗ 4.1) ----------

  Future<void> _voiceCommand() async {
    final AppState app = context.read<AppState>();
    if (!app.ls.voiceCommandsEnabled) return;
    if (!app.stt.isSupported) {
      _toast('На Windows используйте системную диктовку (Win+H) в поле поиска');
      return;
    }
    if (_listening) {
      await app.stt.stop();
      setState(() => _listening = false);
      return;
    }
    if (!app.stt.isAvailable) {
      _toast('Распознавание речи недоступно. Проверьте микрофон и интернет.');
      return;
    }
    setState(() => _listening = true);
    String lastText = '';
    final bool ok = await app.stt.start(
      localeId: app.ls.sttLocale,
      onResult: (String text, bool isFinal) {
        lastText = text;
        if (isFinal) {
          _listening = false;
          if (mounted) setState(() {});
          _handleCommand(lastText);
        }
      },
    );
    if (!ok && mounted) {
      setState(() => _listening = false);
      _toast('Не удалось запустить распознавание');
    }
    // Страховка: остановить через 8 секунд тишины.
    Timer(const Duration(seconds: 8), () async {
      if (_listening) {
        await app.stt.stop();
        if (mounted) setState(() => _listening = false);
        if (lastText.isNotEmpty) _handleCommand(lastText);
      }
    });
  }

  void _handleCommand(String text) {
    final VoiceIntent intent = VoiceCommands.parse(text);
    switch (intent.type) {
      case VoiceIntentType.newNote:
        Navigator.of(context).pushNamed('/edit', arguments: const NoteEditArgs());
        break;
      case VoiceIntentType.showMine:
        setState(() => _mineOnly = true);
        _toast('Показываю мои заявки');
        break;
      case VoiceIntentType.showAll:
        setState(() => _mineOnly = false);
        _toast('Показываю все заявки');
        break;
      case VoiceIntentType.summary:
        _showSummaryDialog();
        break;
      case VoiceIntentType.callContact:
        _callContactByName(intent.contactQuery ?? '');
        break;
      case VoiceIntentType.setStatus:
      case VoiceIntentType.pin:
      case VoiceIntentType.unpin:
      case VoiceIntentType.remind:
        _toast('Откройте заявку — команда «$text» работает в карточке');
        break;
      case VoiceIntentType.unknown:
        _showVoiceHelp();
        break;
    }
  }

  void _callContactByName(String query) {
    final AppState app = context.read<AppState>();
    final String q = query.toLowerCase();
    final List<Contact> matches = app.contacts
        .where((c) => q.isEmpty || c.name.toLowerCase().contains(q))
        .toList();
    if (matches.isEmpty) {
      _toast('Контакт «$query» не найден');
      return;
    }
    final Contact c = matches.first;
    if (c.phone.isEmpty) {
      _toast('У контакта «${c.name}» нет телефона');
      return;
    }
    if (!app.ls.callFromCard) return;
    unawaited(launchUrl(Uri.parse('tel:${c.phone}')));
  }

  void _showVoiceHelp() {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Голосовые команды'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: VoiceCommands.allDescriptions.map((e) => Text('• $e')).toList(),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Понятно'))],
      ),
    );
  }

  void _showSummaryDialog() {
    final DaySummary s = context.read<AppState>().summary;
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Сводка дня'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Новых: ${s.fresh}'),
            Text('В работе: ${s.inProgress}'),
            Text('Выполнено сегодня: ${s.doneToday}'),
            Text('Просрочено: ${s.overdue}'),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть'))],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final AppState app = context.watch<AppState>();
    final List<Note> notes = app.listNotes(mineOnly: _mineOnly, query: _query, status: _statusFilter);

    return Scaffold(
      appBar: AppBar(
        title: const Text(kAppName),
        actions: [
          if (app.ls.showConnIndicator) _connIndicator(app),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Настройки',
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      drawer: _drawer(app),
      body: Column(
        children: [
          if (app.ls.showDaySummary) _summaryBar(app.summary),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Поиск по тексту, автору, тегам',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (String v) => setState(() => _query = v),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                _chip('Все', !_mineOnly && _statusFilter == null,
                    () => setState(() { _mineOnly = false; _statusFilter = null; })),
                _chip('Мои', _mineOnly, () => setState(() => _mineOnly = true)),
                const SizedBox(width: 8),
                ...NoteStatus.values.map((s) => _chip(
                    s.label, _statusFilter == s, () => setState(() {
                      _statusFilter = _statusFilter == s ? null : s;
                      _mineOnly = false;
                    }))),
              ],
            ),
          ),
          Expanded(
            child: notes.isEmpty
                ? const Center(child: Text('Заявок нет. Нажмите «+», чтобы создать.'))
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: notes.length,
                    itemBuilder: (BuildContext ctx, int i) => _noteCard(app, notes[i]),
                  ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (app.ls.voiceButton && app.ls.voiceCommandsEnabled)
            FloatingActionButton.small(
              heroTag: 'voice',
              onPressed: _voiceCommand,
              tooltip: 'Голосовая команда',
              child: Icon(_listening ? Icons.mic : Icons.mic_none),
            ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'add',
            onPressed: () =>
                Navigator.of(context).pushNamed('/edit', arguments: const NoteEditArgs()),
            icon: const Icon(Icons.add),
            label: const Text('Заявка'),
          ),
        ],
      ),
    );
  }

  Widget _connIndicator(AppState app) {
    final ConnState st = app.connState;
    IconData icon;
    Color color;
    switch (st) {
      case ConnState.online:
        icon = Icons.cloud_done;
        color = Colors.green;
        break;
      case ConnState.syncing:
        icon = Icons.sync;
        color = Colors.orange;
        break;
      case ConnState.offline:
        icon = Icons.cloud_off;
        color = Colors.red;
        break;
    }
    return Tooltip(
      message: app.connectionLabel,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Icon(icon, color: color),
      ),
    );
  }

  Widget _summaryBar(DaySummary s) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _sumItem('Новых', s.fresh, Colors.blue),
            _sumItem('В работе', s.inProgress, Colors.orange),
            _sumItem('Выполнено', s.doneToday, Colors.green),
            _sumItem('Просрочено', s.overdue, Colors.red),
          ],
        ),
      ),
    );
  }

  Widget _sumItem(String label, int value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$value', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }

  Widget _noteCard(AppState app, Note n) {
    final bool pinned = app.isPinned(n.id);
    final bool overdue = app.ls.highlightOverdue && n.isOverdue();
    final Contact? contact = n.contactId == null
        ? null
        : app.contacts.where((c) => c.id == n.contactId).firstOrNull;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: overdue ? Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.35) : null,
      child: InkWell(
        onTap: () => Navigator.of(context).pushNamed('/note', arguments: n.id),
        child: IntrinsicHeight(
          child: Row(
            children: [
              if (app.ls.showColors && n.colorValue != null)
                Container(width: 6, color: Color(n.colorValue!)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _statusChip(n.status),
                          if (app.ls.showPriority && n.priority != null) ...[
                            const SizedBox(width: 6),
                            Icon(
                              n.priority == NotePriority.high
                                  ? Icons.priority_high
                                  : n.priority == NotePriority.low
                                      ? Icons.arrow_downward
                                      : Icons.remove,
                              size: 16,
                              color: n.priority == NotePriority.high ? Colors.red : null,
                            ),
                          ],
                          if (n.escalated) ...[
                            const SizedBox(width: 4),
                            const Icon(Icons.warning_amber, size: 16, color: Colors.red),
                          ],
                          const Spacer(),
                          if (pinned) const Icon(Icons.push_pin, size: 16),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(n.text, maxLines: 3, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 10,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('${app.userName(n.authorId)} · ${formatRelative(n.createdAt)}',
                              style: Theme.of(context).textTheme.bodySmall),
                          if (n.deadline != null)
                            Text('Дедлайн: ${formatDeadline(n.deadline!)}',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: overdue ? Colors.red : null)),
                          if (app.ls.showContactInList && contact != null)
                            Text('☎ ${contact.name}', style: Theme.of(context).textTheme.bodySmall),
                          if (n.audio != null && !n.audio!.deleted)
                            const Icon(Icons.mic, size: 14),
                          if (n.tags.isNotEmpty)
                            Text(n.tags.map((t) => '#$t').join(' '),
                                style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusChip(NoteStatus s) {
    final Color color = switch (s) {
      NoteStatus.fresh => Colors.blue,
      NoteStatus.inProgress => Colors.orange,
      NoteStatus.done => Colors.green,
      NoteStatus.rejected => Colors.red,
      NoteStatus.postponed => Colors.grey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(s.label, style: TextStyle(fontSize: 11, color: color)),
    );
  }

  Drawer _drawer(AppState app) {
    return Drawer(
      child: ListView(
        children: [
          UserAccountsDrawerHeader(
            accountName: Text(app.currentUser?.name ?? 'Без имени'),
            accountEmail: Text(app.connectionLabel),
            currentAccountPicture: const CircleAvatar(child: Icon(Icons.person)),
          ),
          ListTile(
            leading: const Icon(Icons.contacts),
            title: const Text('Контакты'),
            onTap: () {
              Navigator.pop(context);
              Navigator.of(context).pushNamed('/contacts');
            },
          ),
          ListTile(
            leading: const Icon(Icons.group),
            title: const Text('Пользователи'),
            onTap: () {
              Navigator.pop(context);
              Navigator.of(context).pushNamed('/users');
            },
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Журнал изменений'),
            onTap: () {
              Navigator.pop(context);
              Navigator.of(context).pushNamed('/audit');
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Настройки'),
            onTap: () {
              Navigator.pop(context);
              Navigator.of(context).pushNamed('/settings');
            },
          ),
        ],
      ),
    );
  }
}
