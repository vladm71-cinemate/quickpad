import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();

/// Генератор уникальных идентификаторов (UUID v4).
String newId() => _uuid.v4();

/// Короткий идентификатор устройства, генерируется один раз и хранится локально.
String newDeviceId() => _uuid.v4();
