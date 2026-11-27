import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../net/discovery.dart';
import '../state/app_state.dart';

/// Первый запуск (ТЗ 3): выбор роли (хост — только Windows / клиент),
/// имя пользователя, подключение к хосту (автопоиск + ручной ввод).
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;
  DeviceRole _role = DeviceRole.client;
  final TextEditingController _nameCtl = TextEditingController();
  final TextEditingController _addrCtl = TextEditingController();
  bool _searching = false;
  List<DiscoveredHost> _found = [];
  bool _busy = false;
  String _error = '';

  @override
  void dispose() {
    _nameCtl.dispose();
    _addrCtl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _found = [];
    });
    final List<DiscoveredHost> found = await context.read<AppState>().findHosts();
    if (!mounted) return;
    setState(() {
      _searching = false;
      _found = found;
    });
  }

  Future<void> _finish() async {
    final AppState app = context.read<AppState>();
    if (_nameCtl.text.trim().isEmpty) {
      setState(() => _error = 'Введите имя');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    await app.chooseRole(_role);
    await app.signIn(_nameCtl.text);
    if (_role == DeviceRole.host) {
      await app.init(); // перезапуск стека хоста с профилем
    } else {
      final String addr = _addrCtl.text.trim();
      if (addr.isNotEmpty) {
        await app.connectToHost(addr);
      }
      await app.init();
    }
    await app.finishOnboarding();
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  Text('Быстрый блокнот заявок',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text('Обмен заявками в локальной Wi-Fi сети',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 32),
                  Expanded(child: _buildStep()),
                  if (_error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_error,
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                          textAlign: TextAlign.center),
                    ),
                  Row(
                    children: [
                      if (_step > 0)
                        TextButton(
                          onPressed: _busy ? null : () => setState(() => _step--),
                          child: const Text('Назад'),
                        ),
                      const Spacer(),
                      FilledButton(
                        onPressed: _busy ? null : _next,
                        child: _busy
                            ? const SizedBox(
                                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text(_isLastStep ? 'Готово' : 'Далее'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get _isLastStep {
    if (_step == 0) return false;
    if (_step == 1) return _role == DeviceRole.host;
    return true; // шаг 2 — подключение (только клиент)
  }

  bool get _isLast => (_role == DeviceRole.host && _step == 1) || (_role == DeviceRole.client && _step == 2);

  void _next() {
    if (_isLast) {
      _finish();
    } else {
      setState(() => _step++);
      if (_step == 2) _search();
    }
  }

  Widget _buildStep() {
    switch (_step) {
      case 0:
        return Column(
          children: [
            _roleCard(
              icon: Icons.dns,
              title: 'Это устройство — хост',
              subtitle: Platform.isWindows
                  ? 'База данных, журнал и копии хранятся здесь'
                  : 'Хост доступен только на Windows-ПК',
              selected: _role == DeviceRole.host,
              enabled: Platform.isWindows,
              onTap: () => setState(() => _role = DeviceRole.host),
            ),
            const SizedBox(height: 12),
            _roleCard(
              icon: Icons.smartphone,
              title: 'Подключиться к хосту',
              subtitle: 'Клиент: заявки, голос, уведомления',
              selected: _role == DeviceRole.client,
              enabled: true,
              onTap: () => setState(() => _role = DeviceRole.client),
            ),
          ],
        );
      case 1:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ваше имя', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Например: Иван',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _next(),
            ),
            const SizedBox(height: 8),
            const Text('Профиль привяжется к этому устройству. Имя можно сменить позже.'),
          ],
        );
      default:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Хост в сети', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  onPressed: _searching ? null : _search,
                  icon: _searching
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh),
                  tooltip: 'Найти снова',
                ),
              ],
            ),
            if (_found.isEmpty && !_searching)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Хост не найден автоматически. Проверьте, что хост запущен, '
                    'или введите адрес вручную.'),
              ),
            ..._found.map((h) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.dns),
                    title: Text(h.name),
                    subtitle: Text('${h.address}:${h.port}'),
                    onTap: () => setState(() => _addrCtl.text = h.address),
                  ),
                )),
            const SizedBox(height: 12),
            TextField(
              controller: _addrCtl,
              decoration: const InputDecoration(
                labelText: 'Адрес хоста (IP)',
                hintText: '192.168.1.50',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
          ],
        );
    }
  }

  Widget _roleCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Card(
      color: selected ? cs.primaryContainer : null,
      child: ListTile(
        leading: Icon(icon, size: 32),
        title: Text(title),
        subtitle: Text(subtitle),
        enabled: enabled,
        onTap: enabled ? onTap : null,
      ),
    );
  }
}
