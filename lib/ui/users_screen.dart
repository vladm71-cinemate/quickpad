import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/timefmt.dart';
import '../models/user.dart';
import '../state/app_state.dart';

/// Пользователи (ТЗ 3, 6.10): список с онлайн-статусом и последней активностью
/// (видна всем), смена пользователя на устройстве, удаление профиля — на хосте.
class UsersScreen extends StatelessWidget {
  const UsersScreen({super.key});

  Future<void> _rename(BuildContext context, AppUser me) async {
    final TextEditingController ctl = TextEditingController(text: me.name);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Моё имя'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<AppState>().renameUser(ctl.text);
    }
  }

  Future<void> _delete(BuildContext context, AppUser u) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Удалить профиль?'),
        content: Text('Профиль «${u.name}» будет удалён. Его заявки и записи журнала сохранятся.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<AppState>().deleteUser(u);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppState app = context.watch<AppState>();
    final List<AppUser> list = app.users.toList()
      ..sort((a, b) {
        if (a.online != b.online) return a.online ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final AppUser? me = app.currentUser;

    return Scaffold(
      appBar: AppBar(title: const Text('Пользователи')),
      body: ListView(
        children: [
          if (me != null)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text('${me.name} (это вы)'),
              subtitle: Text(app.isHost ? 'Хост' : app.connectionLabel),
              trailing: IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Изменить имя',
                onPressed: () => _rename(context, me),
              ),
            ),
          const Divider(),
          ...list.where((u) => u.id != me?.id).map((u) => ListTile(
                leading: CircleAvatar(
                  child: app.ls.showPresence
                      ? Icon(Icons.circle,
                          size: 14, color: u.online ? Colors.green : Colors.grey)
                      : Text(u.name.isEmpty ? '?' : u.name[0]),
                ),
                title: Text(u.name),
                subtitle: app.ls.showPresence
                    ? Text(u.online
                        ? 'в сети'
                        : 'был(а): ${u.lastSeen != null ? formatRelative(u.lastSeen!) : '—'}')
                    : null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (app.ls.allowUserSwitch)
                      TextButton(
                        onPressed: () async {
                          await app.switchUser(u);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        child: const Text('Войти'),
                      ),
                    if (app.isHost)
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Удалить профиль',
                        onPressed: () => _delete(context, u),
                      ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}
