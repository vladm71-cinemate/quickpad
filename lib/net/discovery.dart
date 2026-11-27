import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/constants.dart';

/// Найденный в сети хост.
class DiscoveredHost {
  DiscoveredHost({required this.address, required this.name, required this.port});

  final String address;
  final String name;
  final int port;

  @override
  String toString() => '$name ($address:$port)';
}

/// Автопоиск хоста в локальной сети (ТЗ, раздел 2): UDP broadcast.
///
/// Хост запускает [HostAnnouncer], клиент — [discoverHosts].
/// Если автопоиск не сработал (VLAN, запрет broadcast) — адрес вводится вручную.
class HostAnnouncer {
  HostAnnouncer({required this.hostName, this.port = kHostPort});

  final String hostName;
  final int port;
  RawDatagramSocket? _socket;

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kDiscoveryPort,
        reuseAddress: true, reusePort: true);
    _socket!.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read) return;
      final Datagram? dg = _socket!.receive();
      if (dg == null) return;
      final String msg = utf8.decode(dg.data, allowMalformed: true).trim();
      if (msg == kDiscoveryRequest) {
        final String reply = '$kDiscoveryResponsePrefix$hostName:$port';
        _socket!.send(utf8.encode(reply), dg.address, dg.port);
      }
    });
  }

  void stop() {
    _socket?.close();
    _socket = null;
  }
}

/// Поиск хостов: рассылает broadcast и собирает ответы [timeout].
Future<List<DiscoveredHost>> discoverHosts({
  Duration timeout = const Duration(seconds: 3),
}) async {
  final List<DiscoveredHost> found = [];
  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    socket.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read) return;
      final Datagram? dg = socket!.receive();
      if (dg == null) return;
      final String msg = utf8.decode(dg.data, allowMalformed: true).trim();
      if (msg.startsWith(kDiscoveryResponsePrefix)) {
        final String rest = msg.substring(kDiscoveryResponsePrefix.length);
        final int sep = rest.lastIndexOf(':');
        if (sep > 0) {
          final String name = rest.substring(0, sep);
          final int port = int.tryParse(rest.substring(sep + 1)) ?? kHostPort;
          final DiscoveredHost h =
              DiscoveredHost(address: dg.address.address, name: name, port: port);
          if (!found.any((e) => e.address == h.address && e.port == h.port)) found.add(h);
        }
      }
    });
    socket.send(utf8.encode(kDiscoveryRequest), InternetAddress('255.255.255.255'), kDiscoveryPort);
    // Небольшая пауза и повтор — на случай потери пакета.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    socket.send(utf8.encode(kDiscoveryRequest), InternetAddress('255.255.255.255'), kDiscoveryPort);
    await Future<void>.delayed(timeout);
  } catch (_) {
    // Нет сети / broadcast запрещён — вернём что нашли (пусто).
  } finally {
    socket?.close();
  }
  return found;
}
