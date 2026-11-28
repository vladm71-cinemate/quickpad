/// Протокол обмена хост ↔ клиент поверх WebSocket (JSON-сообщения).
///
/// Клиент → хост: hello, ping, note_create, note_patch, pin_set, pins_order,
/// contact_upsert, contact_delete, request_snapshot.
/// Хост → клиент: welcome, snapshot, note_upsert, users, presence, pin_upsert,
/// pin_remove, contact_upsert, contact_delete, host_settings, notify, pong.
library;

import '../models/note.dart';

class MsgType {
  // клиент → хост
  static const String hello = 'hello';
  static const String ping = 'ping';
  static const String noteCreate = 'note_create';
  static const String notePatch = 'note_patch';
  static const String pinSet = 'pin_set';
  static const String pinsOrder = 'pins_order';
  static const String contactUpsert = 'contact_upsert';
  static const String contactDelete = 'contact_delete';
  static const String requestSnapshot = 'request_snapshot';
  static const String chatSend = 'chat_send';
  static const String chatRead = 'chat_read';
  static const String chatDelete = 'chat_delete';
  static const String chatClear = 'chat_clear';

  // хост → клиент
  static const String welcome = 'welcome';
  static const String snapshot = 'snapshot';
  static const String noteUpsert = 'note_upsert';
  static const String users = 'users';
  static const String presence = 'presence';
  static const String pinUpsert = 'pin_upsert';
  static const String pinRemove = 'pin_remove';
  static const String contactDeleted = 'contact_deleted';
  static const String hostSettings = 'host_settings';
  static const String notify = 'notify';
  static const String chatMessage = 'chat_message';
  static const String chatDeleted = 'chat_deleted';
  static const String chatCleared = 'chat_cleared';
  static const String auditCleared = 'audit_cleared';
  static const String pong = 'pong';
}

/// Конструкторы исходящих сообщений клиента.
class ClientMsg {
  static Map<String, dynamic> hello({
    required String userId,
    required String userName,
    required String deviceId,
    required String deviceName,
    required String platform,
    required int protocolVersion,
  }) =>
      {
        'type': MsgType.hello,
        'userId': userId,
        'userName': userName,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'platform': platform,
        'protocol': protocolVersion,
      };

  static Map<String, dynamic> ping() =>
      {'type': MsgType.ping, 't': DateTime.now().toUtc().toIso8601String()};

  static Map<String, dynamic> noteCreate(Note note) =>
      {'type': MsgType.noteCreate, 'note': note.toJson()};

  /// patch: {поле: json-значение}, baseVersion — версия, на основе которой правили.
  static Map<String, dynamic> notePatch(String noteId, Map<String, dynamic> patch, int baseVersion) => {
        'type': MsgType.notePatch,
        'noteId': noteId,
        'patch': patch,
        'baseVersion': baseVersion,
        'clientTime': DateTime.now().toUtc().toIso8601String(),
      };

  static Map<String, dynamic> pinSet(String noteId, bool pinned) =>
      {'type': MsgType.pinSet, 'noteId': noteId, 'pinned': pinned};

  static Map<String, dynamic> pinsOrder(List<String> orderedNoteIds) =>
      {'type': MsgType.pinsOrder, 'noteIds': orderedNoteIds};

  static Map<String, dynamic> contactUpsert(Map<String, dynamic> contactJson) =>
      {'type': MsgType.contactUpsert, 'contact': contactJson};

  static Map<String, dynamic> contactDelete(String contactId) =>
      {'type': MsgType.contactDelete, 'contactId': contactId};

  static Map<String, dynamic> requestSnapshot() => {'type': MsgType.requestSnapshot};

  /// Личное сообщение пользователю [toId] (текст и/или голосовое).
  static Map<String, dynamic> chatSend(Map<String, dynamic> messageJson) =>
      {'type': MsgType.chatSend, 'message': messageJson};

  /// Отметить прочитанными сообщения от пользователя [fromId].
  static Map<String, dynamic> chatRead(String fromId) =>
      {'type': MsgType.chatRead, 'fromId': fromId};

  /// Удалить одно сообщение.
  static Map<String, dynamic> chatDelete(String messageId) =>
      {'type': MsgType.chatDelete, 'messageId': messageId};

  /// Очистить всю переписку с пользователем [peerId].
  static Map<String, dynamic> chatClear(String peerId) =>
      {'type': MsgType.chatClear, 'peerId': peerId};
}
