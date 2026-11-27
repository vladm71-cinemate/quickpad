import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/timefmt.dart';
import '../models/chat_message.dart';
import '../models/user.dart';
import '../state/app_state.dart';
import 'chat_screen.dart';

/// Локальный мессенджер: список пользователей с последним сообщением
/// и счётчиком непрочитанных. Выбор пользователя → экран переписки.
class ChatListScreen extends StatelessWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppState app = context.watch<AppState>();
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

    return Scaffold(
      appBar: AppBar(title: const Text('Сообщения')),
      body: peers.isEmpty
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
                          fontWeight:
                              unread > 0 ? FontWeight.bold : FontWeight.normal)),
                  subtitle: Text(
                    '${last != null && last.fromId == app.currentUser?.id ? 'Вы: ' : ''}$preview · ${last != null ? formatRelative(last.createdAt) : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: unread > 0
                      ? CircleAvatar(
                          radius: 12,
                          backgroundColor: Theme.of(context).colorScheme.primary,
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
}
