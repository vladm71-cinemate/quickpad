import 'package:flutter/material.dart';

import '../services/stt_service.dart';

/// Показать понятное сообщение о причине недоступности диктовки.
/// При запрещённом навсегда разрешении — диалог с кнопкой «Открыть настройки».
Future<void> showSttError(BuildContext context, SttService stt) async {
  if (!context.mounted) return;
  switch (stt.lastError) {
    case 'permission':
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Нет разрешения на микрофон. При следующей попытке '
              'нажмите «Разрешить» в системном диалоге.')));
      break;
    case 'permission_permanent':
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('Микрофон запрещён'),
          content: const Text('Доступ к микрофону запрещён в настройках Android. '
              'Откройте настройки приложения и разрешите микрофон.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                stt.openSystemSettings();
              },
              child: const Text('Открыть настройки'),
            ),
          ],
        ),
      );
      break;
    case 'no_recognizer':
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          duration: Duration(seconds: 6),
          content: Text('На телефоне нет службы распознавания речи. '
              'В редакторе заявки кнопка «Диктовка» сама предложит один раз '
              'скачать встроенное распознавание (~23 МБ) — дальше оно работает '
              'без интернета и без Google.')));
      break;
    default:
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(stt.lastError.startsWith('error:')
              ? 'Ошибка распознавания: ${stt.lastError.substring(7)}'
              : 'Распознавание недоступно. Проверьте микрофон и интернет.')));
  }
}
