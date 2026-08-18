import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kidu/main.dart';
import 'package:kidu/ui/kidu_styles.dart';
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
    final cs = theme.colorScheme;
    expect(cs.surface, const Color(0xFF24211E));
    expect(cs.surfaceContainerLowest, const Color(0xFF161412));
    expect(cs.surfaceContainerLow, const Color(0xFF2B2825));
    expect(cs.surfaceContainer, const Color(0xFF322F2C));
    expect(cs.surfaceContainerHigh, const Color(0xFF3A3734));
    expect(cs.surfaceContainerHighest, const Color(0xFF3F3C39));
    expect(cs.primaryContainer, const Color(0xFF004D65));
  });

  test('buildKiduTheme keeps generated light surface containers', () {
    final cs = buildKiduTheme().colorScheme;
    expect(cs.surfaceContainerLowest, isNot(const Color(0xFF161412)));
    expect(cs.surfaceContainerLow, isNot(const Color(0xFF2B2825)));
    expect(cs.surfaceContainer, isNot(const Color(0xFF322F2C)));
    expect(cs.surfaceContainerHigh, isNot(const Color(0xFF3A3734)));
    expect(cs.surfaceContainerHighest, isNot(const Color(0xFF3F3C39)));
  });

  testWidgets('dark KiDu primary action uses dedicated fill', (tester) async {
    late ButtonStyle dialogStyle;
    late ButtonStyle formStyle;
    await tester.pumpWidget(
      Theme(
        data: buildKiduDarkTheme(),
        child: Builder(
          builder: (context) {
            dialogStyle = kiduDialogPrimaryButtonStyle(context);
            formStyle = kiduFormPrimaryButtonStyle(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    const darkBg = Color(0xFF3B6476);
    const darkFg = Color(0xFFD4ECF5);
    expect(dialogStyle.backgroundColor!.resolve({}), darkBg);
    expect(dialogStyle.foregroundColor!.resolve({}), darkFg);
    expect(formStyle.backgroundColor!.resolve({}), darkBg);
    expect(formStyle.foregroundColor!.resolve({}), darkFg);
  });

  testWidgets('light KiDu primary action keeps tonal secondaryContainer', (
    tester,
  ) async {
    late ButtonStyle dialogStyle;
    late ColorScheme cs;
    await tester.pumpWidget(
      Theme(
        data: buildKiduTheme(),
        child: Builder(
          builder: (context) {
            cs = Theme.of(context).colorScheme;
            dialogStyle = kiduDialogPrimaryButtonStyle(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final expectedBg = Color.alphaBlend(
      cs.onSecondaryContainer.withValues(alpha: 0.10),
      cs.secondaryContainer,
    );
    expect(dialogStyle.backgroundColor!.resolve({}), expectedBg);
    expect(dialogStyle.foregroundColor!.resolve({}), cs.onSecondaryContainer);
    expect(
      dialogStyle.backgroundColor!.resolve({}),
      isNot(const Color(0xFF3B6476)),
    );
    expect(
      dialogStyle.foregroundColor!.resolve({}),
      isNot(const Color(0xFFD4ECF5)),
    );
  });

  test('dark ColorScheme.error stays generated from seed', () {
    const seed = Color(0xFF2F3E46);
    final dark = buildKiduDarkTheme().colorScheme;
    final generated = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    expect(dark.error, generated.error);
    expect(dark.error, const Color(0xFFFFB4AB));
    expect(dark.onError, generated.onError);
    expect(dark.errorContainer, generated.errorContainer);
    expect(dark.onErrorContainer, generated.onErrorContainer);
  });

  test('light ColorScheme.error stays generated from seed', () {
    const seed = Color(0xFF2F3E46);
    final light = buildKiduTheme().colorScheme;
    final generated = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    );
    expect(light.error, generated.error);
    expect(light.error, const Color(0xFFBA1A1A));
    expect(light.onError, generated.onError);
    expect(light.errorContainer, generated.errorContainer);
    expect(light.onErrorContainer, generated.onErrorContainer);
  });

  testWidgets('destructive foreground is stronger in dark only', (
    tester,
  ) async {
    late Color lightDialog;
    late Color lightIcon;
    late Color lightSheet;
    late Color darkDialog;
    late Color darkIcon;
    late Color darkSheet;
    late Color lightError;
    late Color darkError;
    late double lightDialogAlpha;
    late double darkDialogAlpha;

    await tester.pumpWidget(
      Theme(
        data: buildKiduTheme(),
        child: Builder(
          builder: (context) {
            lightError = Theme.of(context).colorScheme.error;
            lightDialog = kiduDestructiveForeground(context, 0.85);
            lightIcon = kiduDestructiveForeground(context, 0.78);
            lightSheet = kiduDestructiveForeground(context, 0.70);
            lightDialogAlpha = kiduDestructiveAlpha(context, 0.85);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(lightDialog, lightError.withValues(alpha: 0.85));
    expect(lightIcon, lightError.withValues(alpha: 0.78));
    expect(lightSheet, lightError.withValues(alpha: 0.70));
    expect(lightDialogAlpha, 0.85);

    await tester.pumpWidget(
      Theme(
        data: buildKiduDarkTheme(),
        child: Builder(
          builder: (context) {
            darkError = Theme.of(context).colorScheme.error;
            darkDialog = kiduDestructiveForeground(context, 0.85);
            darkIcon = kiduDestructiveForeground(context, 0.78);
            darkSheet = kiduDestructiveForeground(context, 0.70);
            darkDialogAlpha = kiduDestructiveAlpha(context, 0.85);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(darkDialogAlpha, 1.0);
    expect(darkError, const Color(0xFFFFB4AB));
    expect(kiduDestructiveDarkForeground, const Color(0xFFD87878));
    expect(darkDialog, kiduDestructiveDarkForeground);
    expect(darkDialog, isNot(darkError));
    expect(
      darkIcon,
      kiduDestructiveDarkForeground.withValues(
        alpha: 0.78 + kiduDestructiveDarkAlphaLift,
      ),
    );
    expect(
      darkSheet,
      kiduDestructiveDarkForeground.withValues(
        alpha: 0.70 + kiduDestructiveDarkAlphaLift,
      ),
    );
  });

  testWidgets('content-list card color is dark-only', (tester) async {
    late Color? darkFill;
    late Color? lightFill;
    await tester.pumpWidget(
      Theme(
        data: buildKiduDarkTheme(),
        child: Builder(
          builder: (context) {
            darkFill = kiduContentListCardColor(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpWidget(
      Theme(
        data: buildKiduTheme(),
        child: Builder(
          builder: (context) {
            lightFill = kiduContentListCardColor(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(darkFill, const Color(0xFF282522));
    expect(lightFill, isNull);
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
