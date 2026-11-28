import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/timefmt.dart';
import '../models/audit_entry.dart';
import '../models/enums.dart';
import '../state/app_state.dart';

/// Журнал изменений (ТЗ 4.4): хранится на хосте, не редактируется.
/// Клиент видит последние записи из снапшота. Фильтр по типу события.
class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  AuditType? _filter;

  @override
  Widget build(BuildContext context) {
    final AppState app = context.watch<AppState>();
    List<AuditEntry> list = app.audit.reversed.toList();
    if (_filter != null) {
      list = list.where((e) => e.type == _filter).toList();
    }
    if (!app.isHost) {
      // На клиенте журнал ограничен снапшотом.
      list = list.take(500).toList();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Журнал изменений')),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: FilterChip(
                    label: const Text('Все'),
                    selected: _filter == null,
                    onSelected: (_) => setState(() => _filter = null),
                  ),
                ),
                ...AuditType.values.map((t) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                      child: FilterChip(
                        label: Text(t.label),
                        selected: _filter == t,
                        onSelected: (_) =>
                            setState(() => _filter = _filter == t ? null : t),
                      ),
                    )),
              ],
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? const Center(child: Text('Журнал пуст'))
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (BuildContext ctx, int i) {
                      final AuditEntry e = list[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(_icon(e.type), size: 18),
                        title: Text(e.describe(app.userName)),
                        subtitle: Text(formatDateTime(e.at)),
                        onTap: e.noteId != null
                            ? () => Navigator.of(context)
                                .pushNamed('/note', arguments: e.noteId)
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  IconData _icon(AuditType t) {
    switch (t) {
      case AuditType.create:
        return Icons.add_circle_outline;
      case AuditType.update:
        return Icons.edit_outlined;
      case AuditType.pin:
        return Icons.push_pin_outlined;
      case AuditType.unpin:
        return Icons.push_pin;
      case AuditType.escalation:
        return Icons.warning_amber;
      case AuditType.reminderFired:
        return Icons.alarm;
      case AuditType.audioDeleted:
        return Icons.mic_off_outlined;
      case AuditType.noteDeleted:
        return Icons.delete_outline;
      case AuditType.contactChange:
        return Icons.contacts_outlined;
      case AuditType.userChange:
        return Icons.person_outline;
      case AuditType.conflict:
        return Icons.sync_problem;
    }
  }
}
