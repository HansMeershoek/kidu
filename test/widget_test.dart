import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kidu/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  test('buildKiduTheme is light Material 3', () {
    final theme = buildKiduTheme();
    expect(theme.brightness, Brightness.light);
    expect(theme.useMaterial3, isTrue);
  });

  test('buildKiduDarkTheme is dark Material 3', () {
    final theme = buildKiduDarkTheme();
    expect(theme.brightness, Brightness.dark);
    expect(theme.useMaterial3, isTrue);
  });

  test('parseKiduThemeMode maps stored values and fallbacks', () {
    expect(parseKiduThemeMode(null), ThemeMode.system);
    expect(parseKiduThemeMode('system'), ThemeMode.system);
    expect(parseKiduThemeMode('light'), ThemeMode.light);
    expect(parseKiduThemeMode('dark'), ThemeMode.dark);
    expect(parseKiduThemeMode('unknown'), ThemeMode.system);
  });

  group('theme mode preference', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await applyKiduThemeMode(ThemeMode.system);
    });

    tearDown(() async {
      await applyKiduThemeMode(ThemeMode.system);
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets('applyKiduThemeMode updates state and persists', (
      tester,
    ) async {
      await applyKiduThemeMode(ThemeMode.light);
      expect(kiduThemeMode, ThemeMode.light);

      await applyKiduThemeMode(ThemeMode.dark);
      expect(kiduThemeMode, ThemeMode.dark);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('ui.themeMode'), 'dark');
    });

    testWidgets('Weergave tile shows value and three choices', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: KiduThemeModeSettingsTile())),
      );

      expect(find.text('Weergave'), findsOneWidget);
      expect(find.text('Systeem'), findsOneWidget);

      await tester.tap(find.text('Weergave'));
      await tester.pumpAndSettle();

      expect(find.text('Systeem'), findsWidgets);
      expect(find.text('Licht'), findsOneWidget);
      expect(find.text('Donker'), findsOneWidget);

      await tester.tap(find.text('Donker'));
      await tester.pumpAndSettle();

      expect(kiduThemeMode, ThemeMode.dark);
      expect(find.text('Donker'), findsOneWidget);
      expect(find.text('Licht'), findsNothing);
    });
  });

  testWidgets('LoginPage smoke', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const LoginPage()));

    expect(find.text('Rust in gedeelde kosten'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);
  });

  testWidgets('dark host keeps login card on light theme', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKiduTheme(),
        darkTheme: buildKiduDarkTheme(),
        themeMode: ThemeMode.dark,
        home: const LoginPage(),
      ),
    );

    final scaffoldContext = tester.element(find.byType(Scaffold));
    expect(Theme.of(scaffoldContext).brightness, Brightness.dark);

    final cardContext = tester.element(find.text('Rust in gedeelde kosten'));
    expect(Theme.of(cardContext).brightness, Brightness.light);
  });

  testWidgets('light host keeps login card on light theme', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKiduTheme(),
        darkTheme: buildKiduDarkTheme(),
        themeMode: ThemeMode.light,
        home: const LoginPage(),
      ),
    );

    final scaffoldContext = tester.element(find.byType(Scaffold));
    expect(Theme.of(scaffoldContext).brightness, Brightness.light);

    final cardContext = tester.element(find.text('Rust in gedeelde kosten'));
    expect(Theme.of(cardContext).brightness, Brightness.light);
  });

  testWidgets('contrastAlpha lifts only in dark', (tester) async {
    late double lightValue;
    late double darkValue;

    await tester.pumpWidget(
      Theme(
        data: buildKiduTheme(),
        child: Builder(
          builder: (context) {
            lightValue = contrastAlpha(context, a32, a55);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(lightValue, a32);

    await tester.pumpWidget(
      Theme(
        data: buildKiduDarkTheme(),
        child: Builder(
          builder: (context) {
            darkValue = contrastAlpha(context, a32, a55);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(darkValue, a55);
    expect(darkValue, greaterThan(lightValue));
  });

  testWidgets('slider inactive track alpha is stronger in dark', (
    tester,
  ) async {
    late double lightValue;
    late double darkValue;

    await tester.pumpWidget(
      Theme(
        data: buildKiduTheme(),
        child: Builder(
          builder: (context) {
            lightValue = kiduSliderInactiveTrackAlpha(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(lightValue, 0.12);

    await tester.pumpWidget(
      Theme(
        data: buildKiduDarkTheme(),
        child: Builder(
          builder: (context) {
            darkValue = kiduSliderInactiveTrackAlpha(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(darkValue, isNot(0.12));
    expect(darkValue, greaterThan(lightValue));
  });

  // TODO: enable when pages are decoupled from direct Firebase singleton access or test seams are added.
  testWidgets('ProfileNamePage smoke', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const ProfileNamePage()));

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Opslaan'), findsOneWidget);
  }, skip: true);

  // TODO: enable when pages are decoupled from direct Firebase singleton access or test seams are added.
  testWidgets('SetupPage smoke', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const SetupPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(SetupPage), findsOneWidget);
  }, skip: true);
}
