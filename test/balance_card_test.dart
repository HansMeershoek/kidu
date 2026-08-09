import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kidu/main.dart';

String _formatEur(int cents) {
  final abs = cents.abs();
  final euros = abs ~/ 100;
  final rem = abs % 100;
  return '€$euros,${rem.toString().padLeft(2, '0')}';
}

Widget _host(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  group('BalanceCard copy', () {
    testWidgets('positive balance', (tester) async {
      await tester.pumpWidget(
        _host(
          BalanceCard(
            balanceCents: 26829,
            otherName: 'Frits',
            hasIncomingPending: false,
            hasOutgoingPending: false,
            formatEur: _formatEur,
            onInfoPressed: () {},
            onBodyTap: () {},
          ),
        ),
      );

      expect(find.text('Je hebt tegoed van Frits'), findsOneWidget);
      expect(find.text('€268,29'), findsOneWidget);
      expect(find.text('Klik hier om een betaling te melden'), findsOneWidget);
      expect(find.text('Frits betaalt jou'), findsNothing);
      expect(find.textContaining('betaalt jou'), findsNothing);
      expect(find.text('Tik om een betaling te melden'), findsNothing);
      expect(find.text('Totaal samen uitgegeven'), findsNothing);
    });

    testWidgets('negative balance', (tester) async {
      await tester.pumpWidget(
        _host(
          BalanceCard(
            balanceCents: -26829,
            otherName: 'Frits',
            hasIncomingPending: false,
            hasOutgoingPending: false,
            formatEur: _formatEur,
            onInfoPressed: () {},
            onBodyTap: () {},
          ),
        ),
      );

      expect(find.text('Frits heeft tegoed van jou'), findsOneWidget);
      expect(find.text('€268,29'), findsOneWidget);
      expect(find.text('Klik hier om een betaling te melden'), findsOneWidget);
      expect(find.text('Jij betaalt Frits'), findsNothing);
      expect(find.textContaining('Jij betaalt'), findsNothing);
    });

    testWidgets('zero balance', (tester) async {
      await tester.pumpWidget(
        _host(
          BalanceCard(
            balanceCents: 0,
            otherName: 'Frits',
            hasIncomingPending: false,
            hasOutgoingPending: false,
            formatEur: _formatEur,
            onInfoPressed: () {},
            onBodyTap: () {},
          ),
        ),
      );

      expect(find.text('Jullie zijn in balans'), findsOneWidget);
      expect(find.text('€0,00'), findsOneWidget);
      expect(find.text('Klik hier om een betaling te melden'), findsOneWidget);
    });

    testWidgets('outgoing pending', (tester) async {
      await tester.pumpWidget(
        _host(
          BalanceCard(
            balanceCents: -1000,
            otherName: 'Frits',
            hasIncomingPending: false,
            hasOutgoingPending: true,
            formatEur: _formatEur,
            onInfoPressed: () {},
            onBodyTap: () {},
          ),
        ),
      );

      expect(find.text('Betaling gemeld'), findsOneWidget);
      expect(find.text('Wacht op bevestiging'), findsOneWidget);
      expect(find.text('Klik hier om een betaling te melden'), findsNothing);
      expect(
        find.text('Klik hier om de betaling te bevestigen'),
        findsNothing,
      );
    });

    testWidgets('incoming pending', (tester) async {
      await tester.pumpWidget(
        _host(
          BalanceCard(
            balanceCents: 1000,
            otherName: 'Frits',
            hasIncomingPending: true,
            hasOutgoingPending: false,
            formatEur: _formatEur,
            onInfoPressed: () {},
            onBodyTap: () {},
          ),
        ),
      );

      expect(find.text('Er is een betaling gemeld'), findsOneWidget);
      expect(
        find.text('Klik hier om de betaling te bevestigen'),
        findsOneWidget,
      );
      expect(find.text('Bevestig gemelde betaling'), findsNothing);
      expect(find.text('Klik hier om een betaling te melden'), findsNothing);
      expect(find.text('Wacht op bevestiging'), findsNothing);
    });

    testWidgets('old breakdown copy is gone', (tester) async {
      await tester.pumpWidget(
        _host(
          BalanceCard(
            balanceCents: 500,
            otherName: 'Frits',
            hasIncomingPending: false,
            hasOutgoingPending: false,
            formatEur: _formatEur,
            onInfoPressed: () {},
            onBodyTap: () {},
          ),
        ),
      );

      expect(find.text('Totaal samen uitgegeven'), findsNothing);
      expect(find.textContaining('•'), findsNothing);
      expect(
        find.textContaining('ontvangen? Tik om te bevestigen'),
        findsNothing,
      );
      expect(
        find.textContaining('gemeld · wacht op bevestiging'),
        findsNothing,
      );
    });
  });

  group('BalanceCard taps', () {
    testWidgets('info tap does not trigger body tap', (tester) async {
      var infoTaps = 0;
      var bodyTaps = 0;
      await tester.pumpWidget(
        _host(
          BalanceCard(
            balanceCents: 100,
            otherName: 'Frits',
            hasIncomingPending: false,
            hasOutgoingPending: false,
            formatEur: _formatEur,
            onInfoPressed: () => infoTaps++,
            onBodyTap: () => bodyTaps++,
          ),
        ),
      );

      await tester.tap(find.byKey(BalanceCard.infoButtonKey));
      await tester.pump();

      expect(infoTaps, 1);
      expect(bodyTaps, 0);
    });

    testWidgets('body tap keeps payment callback', (tester) async {
      var bodyTaps = 0;
      await tester.pumpWidget(
        _host(
          BalanceCard(
            balanceCents: 100,
            otherName: 'Frits',
            hasIncomingPending: false,
            hasOutgoingPending: false,
            formatEur: _formatEur,
            onInfoPressed: () {},
            onBodyTap: () => bodyTaps++,
          ),
        ),
      );

      await tester.tap(find.byKey(BalanceCard.bodyKey));
      await tester.pump();

      expect(bodyTaps, 1);
    });

    testWidgets('read-only body is not tappable; info still works', (
      tester,
    ) async {
      var infoTaps = 0;
      var bodyTaps = 0;
      await tester.pumpWidget(
        _host(
          BalanceCard(
            balanceCents: 100,
            otherName: 'Frits',
            hasIncomingPending: false,
            hasOutgoingPending: false,
            formatEur: _formatEur,
            showReportHint: false,
            onInfoPressed: () => infoTaps++,
            onBodyTap: null,
          ),
        ),
      );

      expect(find.text('Klik hier om een betaling te melden'), findsNothing);
      expect(
        find.text('Klik hier om de betaling te bevestigen'),
        findsNothing,
      );

      await tester.tap(find.byKey(BalanceCard.bodyKey));
      await tester.pump();
      expect(bodyTaps, 0);

      await tester.tap(find.byKey(BalanceCard.infoButtonKey));
      await tester.pump();
      expect(infoTaps, 1);
    });

    testWidgets('info opens BalansopbouwPage', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BalanceCard(
              balanceCents: 0,
              otherName: 'Frits',
              hasIncomingPending: false,
              hasOutgoingPending: false,
              formatEur: _formatEur,
              onInfoPressed: () {},
              onBodyTap: () {},
            ),
          ),
          routes: {'/balansopbouw': (_) => const BalansopbouwPage()},
        ),
      );

      // Direct page smoke + info icon presence.
      expect(find.byKey(BalanceCard.infoButtonKey), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(home: BalansopbouwPage()));
      expect(find.text('Balansopbouw'), findsOneWidget);
      expect(
        find.text('Hier zie je hoe jullie balans is opgebouwd.'),
        findsOneWidget,
      );
      expect(find.textContaining('€'), findsNothing);
      expect(find.text('Betaling melden'), findsNothing);
    });
  });

  group('pending priority on card copy', () {
    testWidgets('incoming pending wins over outgoing', (tester) async {
      await tester.pumpWidget(
        _host(
          BalanceCard(
            balanceCents: 0,
            otherName: 'Frits',
            hasIncomingPending: true,
            hasOutgoingPending: true,
            formatEur: _formatEur,
            onInfoPressed: () {},
            onBodyTap: () {},
          ),
        ),
      );

      expect(find.text('Er is een betaling gemeld'), findsOneWidget);
      expect(find.text('Betaling gemeld'), findsNothing);
      expect(find.text('Bevestig gemelde betaling'), findsNothing);
    });
  });
}
