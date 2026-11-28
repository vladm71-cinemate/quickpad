import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/note.dart';
import '../state/app_state.dart';

/// Сводка за период: сколько заявок создано, выполнено, просрочено;
/// раскладка по исполнителям. Включается/выключается в настройках
/// (переключатель «Экран статистики»).
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  int _periodIdx = 1; // 0 — сегодня, 1 — неделя, 2 — месяц

  DateTime _from() {
    final DateTime now = DateTime.now();
    switch (_periodIdx) {
      case 0:
        return DateTime(now.year, now.month, now.day);
      case 1:
        return now.subtract(const Duration(days: 7));
      default:
        return now.subtract(const Duration(days: 30));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppState app = context.watch<AppState>();
    final DateTime from = _periodIdx == 0 ? _from() : _from();
    final DateTime fromUtc = from.toUtc();
    final List<Note> all = app.notes.toList();

    final List<Note> created =
        all.where((n) => !n.createdAt.isBefore(fromUtc)).toList();
    final List<Note> done = created.where((n) => n.status.isFinal).toList();
    final int overdue = created
        .where((n) =>
            !n.status.isFinal &&
            n.deadline != null &&
            n.deadline!.isBefore(DateTime.now().toUtc()))
        .length;

    // По исполнителям: назначено за период / выполнено.
    final Map<String, List<Note>> byAssignee = {};
    for (final Note n in created) {
      final String key = n.assigneeId ?? '';
      byAssignee.putIfAbsent(key, () => []).add(n);
    }
    final List<MapEntry<String, List<Note>>> rows = byAssignee.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    return Scaffold(
      appBar: AppBar(title: const Text('Статистика')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Сегодня')),
              ButtonSegment(value: 1, label: Text('7 дней')),
              ButtonSegment(value: 2, label: Text('30 дней')),
            ],
            selected: {_periodIdx},
            onSelectionChanged: (Set<int> s) =>
                setState(() => _periodIdx = s.first),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _card(context, 'Создано', '${created.length}', Colors.blue),
              _card(context, 'Выполнено', '${done.length}', Colors.green),
              _card(context, 'Просрочено', '$overdue',
                  overdue > 0 ? Colors.red : Colors.grey),
            ],
          ),
          const SizedBox(height: 16),
          Text('По исполнителям',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (rows.isEmpty) const Text('За период заявок нет'),
          for (final MapEntry<String, List<Note>> e in rows)
            Card(
              child: ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(e.key.isEmpty ? 'Без исполнителя' : app.userName(e.key)),
                trailing: Text(
                  '${e.value.where((n) => n.status.isFinal).length} из ${e.value.length} выполнено',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          const SizedBox(height: 16),
          Text('По статусам', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final NoteStatus s in NoteStatus.values)
                Chip(
                  label: Text(
                      '${s.label}: ${created.where((n) => n.status == s).length}'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, String title, String value, Color color) =>
      Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
            child: Column(
              children: [
                Text(value,
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(color: color, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(title, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      );
}
