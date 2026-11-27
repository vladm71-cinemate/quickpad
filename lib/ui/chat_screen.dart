import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/timefmt.dart';
import '../models/chat_message.dart';
import '../models/note.dart';
import '../services/audio_service.dart';
import '../state/app_state.dart';

/// Аргументы экрана переписки.
class ChatArgs {
  const ChatArgs({required this.peerId});
  final String peerId;
}

/// Переписка с одним пользователем: пузыри сообщений, текст и голосовые.
/// Логика как в Telegram/WhatsApp: мои — справа, собеседника — слева;
/// ✓ — отправлено, ✓✓ — прочитано.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.args});

  final ChatArgs args;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textCtl = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _recording = false;
  DateTime? _recStarted;
  String? _playingId;

  @override
  void initState() {
    super.initState();
    // Открыли переписку — всё входящее в ней прочитано.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().markChatRead(widget.args.peerId);
    });
  }

  @override
  void dispose() {
    _textCtl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _sendText() async {
    final String text = _textCtl.text.trim();
    if (text.isEmpty) return;
    _textCtl.clear();
    await context.read<AppState>().sendChatMessage(widget.args.peerId, text: text);
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
      await app.sendChatMessage(widget.args.peerId, audio: att);
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
      appBar: AppBar(title: Text(peerName)),
      body: Column(
        children: [
          Expanded(
            child: chat.isEmpty
                ? Center(
                    child: Text('Напишите первое сообщение для $peerName',
                        style: Theme.of(context).textTheme.bodyMedium))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: chat.length,
                    itemBuilder: (BuildContext ctx, int i) =>
                        _bubble(app, chat[i], chat[i].fromId == me),
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textCtl,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: _recording ? 'Идёт запись…' : 'Сообщение…',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _sendText(),
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

  Widget _bubble(AppState app, ChatMessage m, bool mine) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color bg = mine ? cs.primaryContainer : cs.surfaceContainerHighest;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(mine ? 14 : 4),
            bottomRight: Radius.circular(mine ? 4 : 14),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
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
    );
  }
}
