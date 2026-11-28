import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'core/constants.dart';
import 'state/app_state.dart';
import 'state/settings_controller.dart';
import 'ui/audit_screen.dart';
import 'ui/chat_list_screen.dart';
import 'ui/chat_screen.dart';
import 'ui/contacts_screen.dart';
import 'ui/help_screen.dart';
import 'ui/home_screen.dart';
import 'ui/note_detail_screen.dart';
import 'ui/note_edit_screen.dart';
import 'ui/onboarding_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/stats_screen.dart';
import 'ui/users_screen.dart';

/// Корневой виджет: темы (ТЗ 4.13), локаль, навигация.
class QuickPadApp extends StatefulWidget {
  const QuickPadApp({super.key});

  static final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

  @override
  State<QuickPadApp> createState() => _QuickPadAppState();
}

class _QuickPadAppState extends State<QuickPadApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // При уходе в фон обязательно отпускаем микрофон: фоновая служба
      // держит процесс живым, иначе диктовка продолжала бы держать
      // микрофон бесконечно и голосовой ввод на клавиатуре ломался.
      // Android и так глушит микрофон фоновым приложениям — распознавание
      // в фоне всё равно невозможно.
      try {
        final AppState app = context.read<AppState>();
        unawaited(app.stt.stop());
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final SettingsController settings = context.watch<SettingsController>();
    final AppState app = context.watch<AppState>();

    final ColorScheme lightScheme =
        ColorScheme.fromSeed(seedColor: const Color(0xFF1E88E5));
    final ColorScheme darkScheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF1E88E5), brightness: Brightness.dark);

    return MaterialApp(
      title: kAppName,
      navigatorKey: QuickPadApp.navKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: lightScheme, useMaterial3: true),
      darkTheme: ThemeData(colorScheme: darkScheme, useMaterial3: true),
      themeMode: settings.settings.darkTheme ? ThemeMode.dark : ThemeMode.light,
      locale: Locale(settings.settings.language),
      supportedLocales: const [Locale('ru'), Locale('en')],
      // Глобальное выделение: любой текст (заявки, журнал, контакты,
      // настройки) выделяется мышью на ПК и долгим нажатием на телефоне —
      // с кнопкой «Копировать». Пузыри чата исключены
      // (SelectionContainer.disabled): там долгое нажатие открывает меню
      // сообщения (ответить / скопировать / удалить).
      builder: (BuildContext context, Widget? child) =>
          SelectionArea(child: child ?? const SizedBox.shrink()),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      initialRoute: '/',
      onGenerateRoute: (RouteSettings rs) {
        Widget page;
        switch (rs.name) {
          case '/':
            page = app.configured ? const HomeScreen() : const OnboardingScreen();
            break;
          case '/note':
            page = NoteDetailScreen(noteId: rs.arguments as String);
            break;
          case '/edit':
            page = NoteEditScreen(args: rs.arguments as NoteEditArgs?);
            break;
          case '/audit':
            page = const AuditScreen();
            break;
          case '/contacts':
            page = const ContactsScreen();
            break;
          case '/users':
            page = const UsersScreen();
            break;
          case '/chats':
            page = const ChatListScreen();
            break;
          case '/chat':
            page = ChatScreen(args: rs.arguments as ChatArgs);
            break;
          case '/settings':
            page = const SettingsScreen();
            break;
          case '/stats':
            page = const StatsScreen();
            break;
          case '/help':
            page = const HelpScreen();
            break;
          default:
            page = const HomeScreen();
        }
        return MaterialPageRoute<void>(builder: (_) => page, settings: rs);
      },
    );
  }
}
