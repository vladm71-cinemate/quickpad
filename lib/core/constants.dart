/// Общие константы приложения «Быстрый блокнот заявок».
library;

/// Название приложения.
const String kAppName = 'Быстрый блокнот заявок';

/// Версия протокола обмена хост ↔ клиент.
const int kProtocolVersion = 1;

/// Порт HTTP/WebSocket-сервера хоста.
const int kHostPort = 47650;

/// UDP-порт автопоиска хоста в локальной сети.
const int kDiscoveryPort = 47651;

/// Магическая строка запроса автопоиска.
const String kDiscoveryRequest = 'QUICKPAD_DISCOVER_V1';

/// Префикс ответа хоста: `QUICKPAD_HOST_V1:<имя хоста>:<порт>`.
const String kDiscoveryResponsePrefix = 'QUICKPAD_HOST_V1:';

/// Интервал ping клиента → хост (присутствие).
const Duration kPingInterval = Duration(seconds: 15);

/// Таймаут, после которого хост считает пользователя оффлайн.
const Duration kPresenceTimeout = Duration(seconds: 40);

/// Период проверки напоминаний и эскалации на хосте.
const Duration kSchedulerTick = Duration(seconds: 20);

/// Мягкий лимит закреплённых заявок (предупреждение, без блокировки).
const int kPinSoftLimit = 20;

/// Сколько записей журнала аудита отдаётся клиенту в снапшоте (последние).
const int kAuditSnapshotLimit = 1000;

/// Базовая палитра цветовых меток (8 цветов) + произвольный HEX + «нет метки».
const List<int> kLabelPalette = [
  0xFFE53935, // красный
  0xFFFB8C00, // оранжевый
  0xFFFDD835, // жёлтый
  0xFF43A047, // зелёный
  0xFF1E88E5, // синий
  0xFF8E24AA, // фиолетовый
  0xFF00897B, // бирюзовый
  0xFF757575, // серый
];

/// Расширение аудиофайлов вложений.
const String kAudioExt = '.m4a';
