# Сборка и запуск QuickPad (пошагово, для Windows-ПК)

Исходники — папка `quickpad` (скачайте её целиком из рабочей области).
Ниже — что установить и какие команды выполнить. Всё бесплатное.

---

## Шаг 0. Что скачать

| Инструмент | Зачем | Где взять |
|---|---|---|
| Flutter SDK 3.50.1 stable | сама сборка | https://docs.flutter.dev/get-started/install/windows (кнопка Download → zip) |
| Visual Studio 2022 Community | сборка **Windows**-приложения (хост) | https://visualstudio.microsoft.com/ru/vs/community/ |
| Android Studio | сборка **APK** (нужен только его Android SDK) | https://developer.android.com/studio |
| Git для Windows | нужен Flutter | https://git-scm.com/download/win |

> Если нужен только Windows-хост без APK — Android Studio можно не ставить.

---

## Шаг 1. Flutter SDK

1. Распакуйте скачанный zip в `C:\flutter` (важно: путь **без пробелов и кириллицы**,
   НЕ в `C:\Program Files`).
2. Добавьте `C:\flutter\bin` в PATH:
   `Win` → «Переменные среды» → «Изменить системные переменные среды» →
   «Переменные среды» → `Path` → «Создать» → `C:\flutter\bin` → ОК.
3. Откройте **новое** окно PowerShell и проверьте:

```powershell
flutter --version   # должно показать Flutter 3.50.1
```

## Шаг 2. Visual Studio 2022 (для Windows-хоста)

При установке отметьте рабочую нагрузку
**«Разработка классических приложений на C++»** (Desktop development with C++).
Больше ничего не нужно. После установки — перезапустите PowerShell.

## Шаг 3. Android Studio (для APK)

1. Установите Android Studio со стандартными настройками
   (она поставит Android SDK в `C:\Users\<вы>\AppData\Local\Android\Sdk`).
2. Открывать проект в ней не обязательно — нужен только SDK.
3. В PowerShell выполните и везде ответьте `y`:

```powershell
flutter doctor --android-licenses
```

## Шаг 4. Проверка готовности

```powershell
flutter doctor -v
```

Нужны зелёные галочки у: **Flutter**, **Windows version**, **Android toolchain**,
**Visual Studio**. На остальное (Chrome, Android Studio) можно не обращать внимания.

## Шаг 5. Сборка

```powershell
cd C:\путь\к\quickpad

flutter pub get

# Windows-приложение (хост и/или клиент):
flutter build windows --release
#  → готово: build\windows\x64\runner\Release\
#    (вся папка — дистрибутив; внутри quickpad.exe, запускать её)

# Android-клиент:
flutter build apk --release
#  → готово: build\app\outputs\flutter-apk\app-release.apk
```

Первая сборка долгая (10–20 минут: Gradle качает зависимости). Дальше — минуты.

> Примечание: release-APK подписан отладочным ключом — для личной сети это нормально.
> Для «боевого» релиза позже добавим свой ключ подписи.

## Шаг 6. Запуск и подключение

1. **Хост:** на главном Windows-ПК запустите `quickpad.exe` → «Это устройство — хост» →
   введите имя. Windows спросит доступ к сети в брандмауэре — **разрешите для частных сетей**.
   Внизу будет адрес вида `192.168.1.50:47650`.
2. **Телефоны:** скопируйте `app-release.apk` на Android (USB/мессенджер/почта),
   откройте файл → разрешите установку → запустите → «Подключиться к хосту» →
   имя → кнопка **«Найти»** (хост найдётся сам) или введите адрес вручную.
3. Телефон и ПК должны быть в **одной Wi-Fi сети** (без «изоляции клиентов» на роутере).

---

## Если что-то пошло не так

| Симптом | Что делать |
|---|---|
| `flutter` не распознаётся | новое окно PowerShell; проверить PATH (`C:\flutter\bin`) |
| `flutter doctor` ругается на Visual Studio | не хватает нагрузки C++ — доставить через Visual Studio Installer → «Изменить» |
| `flutter doctor` ругается на Android licenses | `flutter doctor --android-licenses`, везде `y` |
| Клиент не находит хост | проверить, что оба в одной Wi-Fi; ввести IP вручную; на хосте разрешить порт 47650 в брандмауэре |
| Ошибки Gradle при сборке APK | `flutter clean`, затем снова `flutter build apk --release`; проверить ≥8 ГБ RAM |
| Хочу пересоздать иконки | `dart run flutter_launcher_icons` (иконка: `assets/icon.png`) |

## Быстрая проверка без устройств

`flutter test` — 21 юнит-тест (протокол, аудит, эскалация, голосовые команды).
`flutter analyze` — статический анализ (0 ошибок).
