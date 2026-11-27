import 'package:flutter_test/flutter_test.dart';
import 'package:quickpad/models/enums.dart';
import 'package:quickpad/services/voice_commands.dart';

void main() {
  group('Голосовые команды', () {
    test('базовый набор', () {
      expect(VoiceCommands.parse('новая заявка').type, VoiceIntentType.newNote);
      expect(VoiceCommands.parse('покажи мои').type, VoiceIntentType.showMine);
      expect(VoiceCommands.parse('покажи все').type, VoiceIntentType.showAll);
      expect(VoiceCommands.parse('сводка').type, VoiceIntentType.summary);
    });

    test('расширенный набор: статус, закрепление, напоминание, звонок', () {
      final VoiceIntent st = VoiceCommands.parse('сменить статус на в работе');
      expect(st.type, VoiceIntentType.setStatus);
      expect(st.status, NoteStatus.inProgress);

      expect(VoiceCommands.parse('закрепить').type, VoiceIntentType.pin);
      expect(VoiceCommands.parse('открепить').type, VoiceIntentType.unpin);

      final VoiceIntent r = VoiceCommands.parse('напомни через 30 минут');
      expect(r.type, VoiceIntentType.remind);
      expect(r.remindIn, const Duration(minutes: 30));

      final VoiceIntent r2 = VoiceCommands.parse('напомни через 2 часа');
      expect(r2.remindIn, const Duration(hours: 2));

      final VoiceIntent call = VoiceCommands.parse('позвонить контакту Иван');
      expect(call.type, VoiceIntentType.callContact);
      expect(call.contactQuery, 'иван');
    });

    test('статусы распознаются все', () {
      expect(VoiceCommands.parse('переведи в статус выполнена').status, NoteStatus.done);
      expect(VoiceCommands.parse('сменить статус на отклонена').status, NoteStatus.rejected);
      expect(VoiceCommands.parse('сменить статус на отложена').status, NoteStatus.postponed);
      expect(VoiceCommands.parse('сменить статус на новая').status, NoteStatus.fresh);
    });

    test('непонятное → unknown с вариантами выбора', () {
      final VoiceIntent i = VoiceCommands.parse('сделай что-нибудь непонятное');
      expect(i.type, VoiceIntentType.unknown);
      expect(i.candidates, isNotEmpty);
    });
  });
}
