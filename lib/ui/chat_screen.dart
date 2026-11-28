import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/timefmt.dart';
import '../models/chat_message.dart';
import '../models/note.dart';
import '../services/audio_service.dart';
import '../state/app_state.dart';

/// Аргументы экрана переписки.
class ChatArgs {
  const ChatArgs({required this.peerId, this.findText});

  final String peerId;

  /// Если задано — открыть чат сразу с поиском по этому тексту
  /// (из глобального поиска по всем чатам).
  final String? findText;
}

/// Переписка с одним пользователем: пузыри сообщений, текст и голосовые.
/// Как в Telegram/WhatsApp: мои — справа, собеседника — слева; ✓ — отправлено,
/// ✓✓ — прочитано; Enter отправляет (Shift+Enter — новая строка), долгое
/// нажатие — ответить/скопировать/удалить; поиск по переписке — лупа вверху.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.args});

  final ChatArgs args;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textCtl = TextEditingController();
  final TextEditingController _searchCtl = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  final Map<String, GlobalKey> _keys = <String, GlobalKey>{};
  bool _recording = false;
  DateTime? _recStarted;
  String? _playingId;
  ChatMessage? _replyTo;

  // Поиск по переписке
  bool _searching = false;
  String _query = '';
  List<ChatMessage> _matches = <ChatMessage>[];
  int _matchIdx = 0;

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    // Открыли переписку — всё входящее в ней прочитано.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().markChatRead(widget.args.peerId);
      final String? find = widget.args.findText;
      if (find != null && find.isNotEmpty) {
        _openSearch(initial: find);
      }
    });
  }

  @override
  void dispose() {
    _textCtl.dispose();
    _searchCtl.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _sendText() async {
    final String text = _textCtl.text.trim();
    if (text.isEmpty) return;
    _textCtl.clear();
    final String? replyId = _replyTo?.id;
    if (_replyTo != null) setState(() => _replyTo = null);
    await context
        .read<AppState>()
        .sendChatMessage(widget.args.peerId, text: text, replyToId: replyId);
    _scrollDown();
  }

  Future<void> _toggleRecord() async {
    final AppState app = context.read<AppState>();
    if (_recording) {
      final RecordedAudio? rec = await app.audio.stopRecording();
      setState(() => _recording = false);
      if (rec == null) return;
      final AudioAttachment? att = await app.attachAudio(rec);
      if (att == null) {
        _toast('Не удалось передать аудио на хост');
        return;
      }
      await app.sendChatMessage(widget.args.peerId,
          audio: att, replyToId: _replyTo?.id);
      if (_replyTo != null) setState(() => _replyTo = null);
      _scrollDown();
    } else {
      final bool ok = await app.audio.startRecording();
      if (!ok) {
        _toast('Нет доступа к микрофону');
        return;
      }
      setState(() {
        _recording = true;
        _recStarted = DateTime.now();
      });
    }
  }

  /// Долгое нажатие на сообщение: ответить / скопировать / удалить (своё).
  Future<void> _messageMenu(ChatMessage m, bool mine) async {
    final String? action = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Ответить'),
              onTap: () => Navigator.pop(ctx, 'reply'),
            ),
            if (m.text.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Скопировать текст'),
                onTap: () => Navigator.pop(ctx, 'copy'),
              ),
            if (mine)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Удалить у всех',
                    style: TextStyle(color: Colors.red)),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'reply':
        setState(() => _replyTo = m);
        _inputFocus.requestFocus();
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        _toast('Текст скопирован');
        break;
      case 'delete':
        await _deleteMessage(m);
        break;
    }
  }

  Future<void> _deleteMessage(ChatMessage m) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Удалить сообщение?'),
        content: const Text('Сообщение будет удалено у вас и у собеседника.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<AppState>().deleteChatMessage(m);
    }
  }

  Future<void> _clearChat() async {
    final AppState app = context.read<AppState>();
    final String peerName = app.userName(widget.args.peerId);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Очистить переписку?'),
        content: Text(
            'Все сообщения с $peerName будут удалены у вас и у собеседника.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await app.clearChat(widget.args.peerId);
    }
  }

  Future<void> _play(ChatMessage m) async {
    final AppState app = context.read<AppState>();
    if (_playingId == m.id) {
      await app.audio.stopPlay();
      setState(() => _playingId = null);
      return;
    }
    final String loc = app.audioLocation(m.audioFileName!);
    if (app.isHost) {
      await app.audio.playLocal(loc);
    } else {
      await app.audio.play(loc);
    }
    app.audio.onComplete(() {
      if (mounted) setState(() => _playingId = null);
    });
    setState(() => _playingId = m.id);
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- Поиск по переписке ----------

  void _openSearch({String initial = ''}) {
    setState(() {
      _searching = true;
      _query = initial;
      _searchCtl.text = initial;
    });
    _refreshMatches(jump: true);
  }

  void _closeSearch() {
    setState(() {
      _searching = false;
      _query = '';
      _searchCtl.clear();
      _matches = <ChatMessage>[];
    });
  }

  void _refreshMatches({bool jump = false}) {
    final List<ChatMessage> chat =
        context.read<AppState>().chatWith(widget.args.peerId);
    final String q = _query.trim().toLowerCase();
    setState(() {
      _matches = q.isEmpty
          ? <ChatMessage>[]
          : chat.where((m) => m.text.toLowerCase().contains(q)).toList();
      _matchIdx = _matches.isEmpty ? 0 : _matches.length - 1;
    });
    if (jump) _jumpToMatch(0);
  }

  /// Переход к следующему/предыдущему результату (delta ±1).
  void _jumpToMatch(int delta) {
    if (_matches.isEmpty) return;
    setState(() {
      _matchIdx = (_matchIdx + delta) % _matches.length;
      if (_matchIdx < 0) _matchIdx += _matches.length;
    });
    final BuildContext? ctx = _keys[_matches[_matchIdx].id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 250), alignment: 0.35);
    }
  }

  GlobalKey _keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final AppState app = context.watch<AppState>();
    final String peerName = app.userName(widget.args.peerId);
    final List<ChatMessage> chat = app.chatWith(widget.args.peerId);
    final String? me = app.currentUser?.id;

    // Если при открытой переписке пришло новое непрочитанное — сразу читаем.
    if (app.unreadFrom(widget.args.peerId) > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) app.markChatRead(widget.args.peerId);
      });
    }

    return Scaffold(
      appBar: _searching ? _searchAppBar() : _normalAppBar(peerName),
      body: Column(
        children: [
          Expanded(
            child: chat.isEmpty
                ? Center(
                    child: Text('Напишите первое сообщение для $peerName',
                        style: Theme.of(context).textTheme.bodyMedium))
                : ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    // Чаты небольшие (лимит истории), строим целиком — так
                    // поиск может прокрутить к любому сообщению сразу.
                    children: [
                      for (final ChatMessage m in chat)
                        KeyedSubtree(
                          key: _keyFor(m.id),
                          child: _bubble(app, chat, m, m.fromId == me),
                        ),
                    ],
                  ),
          ),
          // Плашка «Ответ на …» над полем ввода.
          if (_replyTo != null) _replyBar(app),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    // На ПК: Enter отправляет, Shift+Enter — новая строка
                    // (как в Telegram/WhatsApp Desktop). На телефоне Enter
                    // остаётся переносом строки, отправка — кнопкой.
                    child: Focus(
                      onKeyEvent: (FocusNode node, KeyEvent event) {
                        if (!_isDesktop) return KeyEventResult.ignored;
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.enter &&
                            !HardwareKeyboard.instance.isShiftPressed) {
                          _sendText();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: _textCtl,
                        focusNode: _inputFocus,
                        minLines: 1,
                        maxLines: 4,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText:
                              _recording ? 'Идёт запись…' : 'Сообщение…',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Микрофон: голосовое сообщение (удерживать не нужно — нажал,
                  // говоришь, нажал ещё раз для отправки).
                  IconButton.filledTonal(
                    icon: Icon(_recording ? Icons.stop : Icons.mic,
                        color: _recording ? Colors.red : null),
                    tooltip: _recording
                        ? 'Стоп и отправить (${DateTime.now().difference(_recStarted ?? DateTime.now()).inSeconds} c)'
                        : 'Голосовое сообщение',
                    onPressed: _toggleRecord,
                  ),
                  // Отправка — как в Telegram/WhatsApp.
                  IconButton.filled(
                    icon: const Icon(Icons.send_rounded),
                    tooltip: 'Отправить',
                    onPressed: _sendText,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _normalAppBar(String peerName) => AppBar(
        title: Text(peerName),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Поиск по переписке',
            onPressed: _openSearch,
          ),
          PopupMenuButton<String>(
            onSelected: (String v) {
              if (v == 'clear') _clearChat();
            },
            itemBuilder: (BuildContext ctx) => const [
              PopupMenuItem<String>(
                value: 'clear',
                child: ListTile(
                  leading: Icon(Icons.delete_sweep_outlined),
                  title: Text('Очистить переписку'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      );

  PreferredSizeWidget _searchAppBar() => AppBar(
        title: TextField(
          controller: _searchCtl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Поиск по переписке…',
            border: InputBorder.none,
          ),
          onChanged: (String v) {
            _query = v;
            _refreshMatches(jump: true);
          },
        ),
        actions: [
          Center(
            child: Text(
              _matches.isEmpty ? '0' : '${_matchIdx + 1}/${_matches.length}',
              style: const TextStyle(fontFeatures: []),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up),
            tooltip: 'Выше',
            onPressed: () => _jumpToMatch(-1),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            tooltip: 'Ниже',
            onPressed: () => _jumpToMatch(1),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Закрыть поиск',
            onPressed: _closeSearch,
          ),
        ],
      );

  /// Плашка «в ответ на …» над полем ввода.
  Widget _replyBar(AppState app) {
    final ChatMessage m = _replyTo!;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.reply),
        title: Text('Ответ: ${app.userName(m.fromId)}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(
          m.hasAudio ? '🎤 Голосовое' : m.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(() => _replyTo = null),
        ),
      ),
    );
  }

  /// Цитата внутри пузыря (если это ответ на другое сообщение).
  Widget? _quoteBlock(AppState app, List<ChatMessage> chat, ChatMessage m) {
    final String? rid = m.replyToId;
    if (rid == null) return null;
    ChatMessage? orig;
    for (final ChatMessage c in chat) {
      if (c.id == rid) {
        orig = c;
        break;
      }
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.5),
        border: Border(left: BorderSide(color: cs.primary, width: 3)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(app.userName(orig?.fromId ?? ''),
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: cs.primary)),
          Text(
            orig == null
                ? 'сообщение удалено'
                : (orig.hasAudio ? '🎤 Голосовое' : orig.text),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _bubble(AppState app, List<ChatMessage> chat, ChatMessage m, bool mine) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color bg = mine ? cs.primaryContainer : cs.surfaceContainerHighest;
    final Widget? quote = _quoteBlock(app, chat, m);
    final bool isMatch =
        _query.trim().isNotEmpty &&
        m.text.toLowerCase().contains(_query.trim().toLowerCase());
    final bool isCurrent =
        isMatch && _matches.isNotEmpty && _matches[_matchIdx].id == m.id;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        // Долгое нажатие — меню: ответить / скопировать / удалить.
        onLongPress: () => _messageMenu(m, mine),
        child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: bg,
          border: isMatch
              ? Border.all(
                  color: cs.primary.withValues(alpha: isCurrent ? 1.0 : 0.4),
                  width: isCurrent ? 2 : 1)
              : null,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(mine ? 14 : 4),
            bottomRight: Radius.circular(mine ? 4 : 14),
          ),
        ),
        child: SelectionContainer.disabled(
          // В пузыре выделение отключено: долгое нажатие на сообщение
          // открывает меню (ответить / скопировать / удалить).
          child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (quote != null) quote,
            if (m.text.isNotEmpty) Text(m.text),
            if (m.hasAudio)
              InkWell(
                onTap: () => _play(m),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                        _playingId == m.id
                            ? Icons.stop_circle
                            : Icons.play_circle,
                        size: 32),
                    const SizedBox(width: 6),
                    Text('Голосовое · ${m.audioDurationSec ?? 0} c'),
                  ],
                ),
              ),
            const SizedBox(height: 2),
            Text(
              '${formatTime(m.createdAt)}${mine ? (m.readAt != null ? ' ✓✓' : ' ✓') : ''}',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          ),
        ),
        ),
      ),
    );
  }
}
