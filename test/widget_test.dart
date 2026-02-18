import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kidu/main.dart';

Widget _host(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  testWidgets('LoginPage smoke', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const LoginPage()));

    expect(find.text('Log in met Google om verder te gaan'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);
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
