import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/timefmt.dart';
import '../models/chat_message.dart';
import '../models/user.dart';
import '../state/app_state.dart';
import 'chat_screen.dart';

/// Локальный мессенджер: список пользователей с последним сообщением
/// и счётчиком непрочитанных. Поиск сверху ищет сразу ПО ВСЕМ чатам
/// (по имени собеседника и по тексту сообщений) — как в Telegram/WhatsApp.
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final TextEditingController _searchCtl = TextEditingController();
  bool _searching = false;
  String _query = '';

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppState app = context.watch<AppState>();
    final String q = _query.trim().toLowerCase();
    final List<AppUser> peers = app.chatPeers
      ..sort((a, b) {
        // Сначала те, с кем есть переписка (свежая — выше), потом по имени.
        final List<ChatMessage> ca = app.chatWith(a.id);
        final List<ChatMessage> cb = app.chatWith(b.id);
        final DateTime? la = ca.isEmpty ? null : ca.last.createdAt;
        final DateTime? lb = cb.isEmpty ? null : cb.last.createdAt;
        if (la != null && lb != null) return lb.compareTo(la);
        if (la != null) return -1;
        if (lb != null) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    // Поиск по всем чатам: совпадение в имени собеседника или в тексте
    // сообщений (все сообщения, где участвую я).
    final List<ChatMessage> found = q.isEmpty
        ? <ChatMessage>[]
        : (List<ChatMessage>.from(app.messages)
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt)))
            .where((ChatMessage m) => m.text.toLowerCase().contains(q))
            .toList();
    final List<AppUser> foundPeers = q.isEmpty
        ? <AppUser>[]
        : peers
            .where((AppUser u) => u.name.toLowerCase().contains(q))
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchCtl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Поиск по всем чатам…',
                  border: InputBorder.none,
                ),
                onChanged: (String v) => setState(() => _query = v),
              )
            : const Text('Сообщения'),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            tooltip: _searching ? 'Закрыть поиск' : 'Поиск по всем чатам',
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) {
                _query = '';
                _searchCtl.clear();
              }
            }),
          ),
        ],
      ),
      body: _searching && q.isNotEmpty
          ? _searchResults(app, foundPeers, found)
          : peers.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Пока нет других пользователей.\nКогда коллеги подключатся к хосту, '
                      'здесь появятся их имена — выберите человека и напишите ему.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: peers.length,
                  itemBuilder: (BuildContext ctx, int i) {
                    final AppUser u = peers[i];
                    final List<ChatMessage> chat = app.chatWith(u.id);
                    final ChatMessage? last = chat.isEmpty ? null : chat.last;
                    final int unread = app.unreadFrom(u.id);
                    final String preview = last == null
                        ? (u.online ? 'в сети' : 'не в сети')
                        : (last.hasAudio
                            ? '🎤 Голосовое (${last.audioDurationSec ?? 0} c)'
                            : last.text);
                    return ListTile(
                      leading: CircleAvatar(
                        child: Icon(Icons.person,
                            color: u.online ? Colors.green : null),
                      ),
                      title: Text(u.name,
                          style: TextStyle(
                              fontWeight: unread > 0
                                  ? FontWeight.bold
                                  : FontWeight.normal)),
                      subtitle: Text(
                        '${last != null && last.fromId == app.currentUser?.id ? 'Вы: ' : ''}$preview · ${last != null ? formatRelative(last.createdAt) : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: unread > 0
                          ? CircleAvatar(
                              radius: 12,
                              backgroundColor:
                                  Theme.of(context).colorScheme.primary,
                              child: Text('$unread',
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12)),
                            )
                          : null,
                      onTap: () => Navigator.of(context).pushNamed('/chat',
                          arguments: ChatArgs(peerId: u.id)),
                    );
                  },
                ),
    );
  }

  /// Результаты поиска: люди по имени + сообщения по тексту.
  Widget _searchResults(
      AppState app, List<AppUser> foundPeers, List<ChatMessage> found) {
    if (foundPeers.isEmpty && found.isEmpty) {
      return const Center(child: Text('Ничего не найдено'));
    }
    final String q = _query.trim();
    return ListView(
      children: [
        if (foundPeers.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Люди', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final AppUser u in foundPeers)
            ListTile(
              leading: CircleAvatar(
                child:
                    Icon(Icons.person, color: u.online ? Colors.green : null),
              ),
              title: Text(u.name),
              subtitle: Text(u.online ? 'в сети' : 'не в сети'),
              onTap: () => Navigator.of(context)
                  .pushNamed('/chat', arguments: ChatArgs(peerId: u.id)),
            ),
        ],
        if (found.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child:
                Text('Сообщения', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final ChatMessage m in found.take(50))
            ListTile(
              dense: true,
              leading: const Icon(Icons.chat_bubble_outline),
              title: Text(
                  app.userName(m.fromId == app.currentUser?.id
                      ? m.toId
                      : m.fromId),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              subtitle: _highlight(m.text, q),
              trailing: Text(formatRelative(m.createdAt),
                  style: Theme.of(context).textTheme.labelSmall),
              // Открываем чат сразу с поиском этого текста.
              onTap: () {
                final String peerId =
                    m.fromId == app.currentUser?.id ? m.toId : m.fromId;
                Navigator.of(context).pushNamed('/chat',
                    arguments: ChatArgs(peerId: peerId, findText: q));
              },
            ),
        ],
      ],
    );
  }

  /// Текст сообщения с подсветкой совпадения.
  Widget _highlight(String text, String query) {
    final String lower = text.toLowerCase();
    final String q = query.toLowerCase();
    final int pos = lower.indexOf(q);
    if (pos < 0) {
      return Text(text, maxLines: 2, overflow: TextOverflow.ellipsis);
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    // Text.rich (а не голый RichText) — участвует в глобальном выделении.
    return Text.rich(
      TextSpan(
        style: Theme.of(context).textTheme.bodyMedium,
        children: [
          TextSpan(text: text.substring(0, pos)),
          TextSpan(
            text: text.substring(pos, pos + q.length),
            style: TextStyle(
                backgroundColor: cs.primaryContainer,
                color: cs.onPrimaryContainer,
                fontWeight: FontWeight.bold),
          ),
          TextSpan(text: text.substring(pos + q.length)),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
