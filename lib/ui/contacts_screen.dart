import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/ids.dart';
import '../models/contact.dart';
import '../state/app_state.dart';

/// Библиотека адресов (ТЗ 4.7): общая для всех пользователей,
/// добавление/редактирование/удаление, звонок из карточки.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  String _query = '';

  Future<void> _editDialog({Contact? existing}) async {
    final TextEditingController name = TextEditingController(text: existing?.name ?? '');
    final TextEditingController phone = TextEditingController(text: existing?.phone ?? '');
    final TextEditingController comment = TextEditingController(text: existing?.comment ?? '');
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(existing == null ? 'Новый контакт' : 'Контакт'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Имя *')),
            TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Телефон')),
            TextField(
                controller: comment,
                decoration: const InputDecoration(labelText: 'Комментарий')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (name.text.trim().isEmpty) return;
    final AppState app = context.read<AppState>();
    await app.saveContact(Contact(
      id: existing?.id ?? newId(),
      name: name.text.trim(),
      phone: phone.text.trim(),
      comment: comment.text.trim(),
    ));
  }

  Future<void> _delete(Contact c) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Удалить контакт?'),
        content: Text('«${c.name}» будет удалён из общей библиотеки. Связи с заявками отвяжутся.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<AppState>().deleteContact(c);
    }
  }

  Future<void> _call(Contact c) async {
    if (c.phone.isEmpty) return;
    final Uri uri = Uri.parse('tel:${c.phone}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Позвонить: ${c.phone}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppState app = context.watch<AppState>();
    final String q = _query.toLowerCase();
    final List<Contact> list = app.contacts
        .where((c) =>
            q.isEmpty ||
            c.name.toLowerCase().contains(q) ||
            c.phone.contains(q) ||
            c.comment.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return Scaffold(
      appBar: AppBar(title: const Text('Контакты')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Поиск контакта',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (String v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? const Center(child: Text('Контактов нет'))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (BuildContext ctx, int i) {
                      final Contact c = list[i];
                      return ListTile(
                        leading: CircleAvatar(child: Text(c.name.isEmpty ? '?' : c.name[0])),
                        title: Text(c.name),
                        subtitle: Text([c.phone, c.comment].where((s) => s.isNotEmpty).join(' · ')),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (c.phone.isNotEmpty && app.ls.callFromCard)
                              IconButton(icon: const Icon(Icons.call), onPressed: () => _call(c)),
                            IconButton(
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => _editDialog(existing: c)),
                            IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _delete(c)),
                          ],
                        ),
                        onTap: () => _editDialog(existing: c),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editDialog(),
        child: const Icon(Icons.person_add),
      ),
    );
  }
}
