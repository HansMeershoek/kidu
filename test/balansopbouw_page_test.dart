import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kidu/balance/household_balance.dart';
import 'package:kidu/main.dart';

HouseholdBalanceResult _balance({
  int totalExpenseCents = 0,
  int paidByViewerCents = 0,
  int paidByOtherCents = 0,
  int fairShareViewerCents = 0,
  int fairShareOtherCents = 0,
  int expenseBalanceCents = 0,
  int confirmedPaidByViewerCents = 0,
  int confirmedPaidToViewerCents = 0,
  int settlementPaidByViewerCents = 0,
  int settlementPaidToViewerCents = 0,
  int? balanceCents,
}) {
  final payment =
      settlementPaidByViewerCents -
      settlementPaidToViewerCents +
      confirmedPaidByViewerCents -
      confirmedPaidToViewerCents;
  return HouseholdBalanceResult(
    totalExpenseCents: totalExpenseCents,
    paidByViewerCents: paidByViewerCents,
    paidByOtherCents: paidByOtherCents,
    fairShareViewerCents: fairShareViewerCents,
    fairShareOtherCents: fairShareOtherCents,
    expenseBalanceCents: expenseBalanceCents,
    confirmedPaidByViewerCents: confirmedPaidByViewerCents,
    confirmedPaidToViewerCents: confirmedPaidToViewerCents,
    settlementPaidByViewerCents: settlementPaidByViewerCents,
    settlementPaidToViewerCents: settlementPaidToViewerCents,
    balanceCents: balanceCents ?? expenseBalanceCents + payment,
  );
}

Widget _host(
  HouseholdBalanceResult balance, {
  String viewerName = 'Bianca',
  String otherName = 'Frits',
  bool hasPending = false,
  Size size = const Size(390, 844),
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildKiduTheme(),
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: TextScaler.linear(textScale),
      ),
      child: BalansopbouwPage(
        balance: balance,
        viewerName: viewerName,
        otherName: otherName,
        hasPending: hasPending,
      ),
    ),
  );
}

Future<void> _expectNoOverflow(WidgetTester tester) async {
  final exceptions = tester.takeException();
  expect(exceptions, isNull);
  expect(find.byType(BalansopbouwPage), findsOneWidget);
}

void main() {
  group('Huidige balans', () {
    testWidgets('positive', (tester) async {
      await tester.pumpWidget(
        _host(_balance(expenseBalanceCents: 10150, balanceCents: 10150)),
      );
      expect(find.text('HUIDIGE BALANS'), findsNothing);
      expect(find.text('Je hebt tegoed van Frits'), findsWidgets);
      expect(find.text('€101,50'), findsWidgets);
      expect(find.text('Jullie zijn in balans'), findsNothing);
    });

    testWidgets('negative', (tester) async {
      await tester.pumpWidget(
        _host(_balance(expenseBalanceCents: -10150, balanceCents: -10150)),
      );
      expect(find.text('Frits heeft tegoed van jou'), findsWidgets);
      expect(find.text('€101,50'), findsWidgets);
    });

    testWidgets('zero', (tester) async {
      await tester.pumpWidget(_host(_balance()));
      expect(find.text('Jullie zijn in balans'), findsOneWidget);
      expect(find.text('€0,00'), findsWidgets);
    });
  });

  group('Pending', () {
    testWidgets('absent → no status line', (tester) async {
      await tester.pumpWidget(
        _host(_balance(balanceCents: 10150, expenseBalanceCents: 10150)),
      );
      expect(
        find.text('Betaling gemeld · telt nog niet mee in de balans'),
        findsNothing,
      );
      expect(find.text('€101,50'), findsWidgets);
    });

    testWidgets('present → status line; balance unchanged', (tester) async {
      await tester.pumpWidget(
        _host(
          _balance(
            expenseBalanceCents: 10150,
            balanceCents: 10150,
            confirmedPaidByViewerCents: 0,
          ),
          hasPending: true,
        ),
      );
      expect(
        find.text('Betaling gemeld · telt nog niet mee in de balans'),
        findsOneWidget,
      );
      expect(find.text('Je hebt tegoed van Frits'), findsWidgets);
      expect(find.text('€101,50'), findsWidgets);
      // Pending must not invent payment directions.
      expect(find.text('Bianca → Frits'), findsOneWidget);
      expect(find.text('€0,00'), findsWidgets);
    });
  });

  group('Uitgaven mapping', () {
    testWidgets('spent and share columns + positive outcome', (tester) async {
      await tester.pumpWidget(
        _host(
          _balance(
            totalExpenseCents: 71100,
            paidByViewerCents: 16900,
            paidByOtherCents: 54200,
            fairShareViewerCents: 27050,
            fairShareOtherCents: 44050,
            expenseBalanceCents: -10150,
            balanceCents: -10150,
          ),
        ),
      );
      expect(find.text('UITGAVEN'), findsOneWidget);
      expect(find.text('AANDEEL'), findsOneWidget);
      expect(find.text('Uitgegeven'), findsNothing);
      expect(find.text('Aandeel'), findsNothing);
      expect(find.text('Bianca'), findsWidgets);
      expect(find.text('Frits'), findsWidgets);
      expect(find.text('€169,00'), findsOneWidget);
      expect(find.text('€542,00'), findsOneWidget);
      expect(find.text('€270,50'), findsOneWidget);
      expect(find.text('€440,50'), findsOneWidget);
      expect(
        find.text('Het aandeel is gebaseerd op de verdeling per uitgave.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Ieders aandeel is gebaseerd op de verdeling van de uitgaven.',
        ),
        findsNothing,
      );
      expect(find.text('Frits heeft tegoed van jou'), findsWidgets);
      expect(find.text('€101,50'), findsWidgets);
    });

    testWidgets('expense outcome negative/positive/zero', (tester) async {
      await tester.pumpWidget(
        _host(_balance(expenseBalanceCents: 4650, balanceCents: 4650)),
      );
      expect(find.text('Je hebt tegoed van Frits'), findsWidgets);
      expect(find.text('€46,50'), findsWidgets);

      await tester.pumpWidget(
        _host(_balance(expenseBalanceCents: -4650, balanceCents: -4650)),
      );
      expect(find.text('Frits heeft tegoed van jou'), findsWidgets);

      await tester.pumpWidget(_host(_balance()));
      expect(find.text('In balans'), findsWidgets);
      expect(find.text('€0,00'), findsWidgets);
    });
  });

  group('Splits', () {
    testWidgets('50/50', (tester) async {
      await tester.pumpWidget(
        _host(
          _balance(
            totalExpenseCents: 10000,
            paidByViewerCents: 10000,
            paidByOtherCents: 0,
            fairShareViewerCents: 5000,
            fairShareOtherCents: 5000,
            expenseBalanceCents: 5000,
            balanceCents: 5000,
          ),
        ),
      );
      expect(find.text('€100,00'), findsOneWidget);
      expect(find.text('€0,00'), findsWidgets);
      expect(find.text('€50,00'), findsWidgets);
      expect(find.text('Je hebt tegoed van Frits'), findsWidgets);
    });

    testWidgets('60/40', (tester) async {
      await tester.pumpWidget(
        _host(
          _balance(
            totalExpenseCents: 10000,
            paidByViewerCents: 10000,
            paidByOtherCents: 0,
            fairShareViewerCents: 6000,
            fairShareOtherCents: 4000,
            expenseBalanceCents: 4000,
            balanceCents: 4000,
          ),
        ),
      );
      expect(find.text('€60,00'), findsOneWidget);
      expect(find.text('€40,00'), findsWidgets);
    });

    testWidgets('40/60', (tester) async {
      await tester.pumpWidget(
        _host(
          _balance(
            totalExpenseCents: 10000,
            paidByViewerCents: 10000,
            paidByOtherCents: 0,
            fairShareViewerCents: 4000,
            fairShareOtherCents: 6000,
            expenseBalanceCents: 6000,
            balanceCents: 6000,
          ),
        ),
      );
      expect(find.text('€40,00'), findsOneWidget);
      expect(find.text('€60,00'), findsWidgets);
    });

    testWidgets('100/0 → In balans €0,00', (tester) async {
      await tester.pumpWidget(
        _host(
          _balance(
            totalExpenseCents: 100000,
            paidByViewerCents: 100000,
            paidByOtherCents: 0,
            fairShareViewerCents: 100000,
            fairShareOtherCents: 0,
            expenseBalanceCents: 0,
            balanceCents: 0,
          ),
          viewerName: 'Frits',
          otherName: 'Bianca',
        ),
      );
      expect(find.text('€1.000,00'), findsNWidgets(2));
      expect(find.text('In balans'), findsWidgets);
      expect(find.text('Jullie zijn in balans'), findsOneWidget);
      expect(find.text('Je hebt tegoed van Bianca'), findsNothing);
      expect(find.text('Bianca heeft tegoed van jou'), findsNothing);
    });

    testWidgets('0/100', (tester) async {
      await tester.pumpWidget(
        _host(
          _balance(
            totalExpenseCents: 100000,
            paidByViewerCents: 100000,
            paidByOtherCents: 0,
            fairShareViewerCents: 0,
            fairShareOtherCents: 100000,
            expenseBalanceCents: 100000,
            balanceCents: 100000,
          ),
        ),
      );
      expect(find.text('€1.000,00'), findsWidgets);
      expect(find.text('€0,00'), findsWidgets);
      expect(find.text('Je hebt tegoed van Frits'), findsWidgets);
    });
  });

  group('Betalingen', () {
    testWidgets('directions combine settlements + confirmed', (tester) async {
      await tester.pumpWidget(
        _host(
          _balance(
            settlementPaidByViewerCents: 5000,
            confirmedPaidByViewerCents: 2500,
            settlementPaidToViewerCents: 1000,
            confirmedPaidToViewerCents: 1000,
            balanceCents: 5500,
          ),
        ),
      );
      expect(find.text('BETALINGEN'), findsOneWidget);
      expect(find.text('Bianca → Frits'), findsOneWidget);
      expect(find.text('Frits → Bianca'), findsOneWidget);
      expect(find.text('€75,00'), findsOneWidget);
      expect(find.text('€20,00'), findsOneWidget);
      expect(find.text('Je hebt tegoed van Frits'), findsWidgets);
      expect(find.text('€55,00'), findsWidgets);
      expect(find.text('Onderling betaald'), findsNothing);
    });

    testWidgets('payment outcome signs', (tester) async {
      await tester.pumpWidget(
        _host(_balance(confirmedPaidByViewerCents: 4000, balanceCents: 4000)),
      );
      expect(find.text('Je hebt tegoed van Frits'), findsWidgets);
      expect(find.text('€40,00'), findsWidgets);

      await tester.pumpWidget(
        _host(_balance(confirmedPaidToViewerCents: 4000, balanceCents: -4000)),
      );
      expect(find.text('Frits heeft tegoed van jou'), findsWidgets);

      await tester.pumpWidget(
        _host(
          _balance(
            confirmedPaidByViewerCents: 2000,
            confirmedPaidToViewerCents: 2000,
            balanceCents: 0,
          ),
        ),
      );
      expect(find.text('In balans'), findsWidgets);
    });

    testWidgets('pending flag does not change payment amounts', (tester) async {
      await tester.pumpWidget(
        _host(
          _balance(
            confirmedPaidByViewerCents: 7500,
            confirmedPaidToViewerCents: 2000,
            balanceCents: 5500,
          ),
          hasPending: true,
        ),
      );
      expect(find.text('€75,00'), findsOneWidget);
      expect(find.text('€20,00'), findsOneWidget);
      expect(find.text('€55,00'), findsWidgets);
    });
  });

  group('Tegengestelde effecten', () {
    testWidgets('expense +100 / payment -40 → balance +60', (tester) async {
      await tester.pumpWidget(
        _host(
          _balance(
            expenseBalanceCents: 10000,
            confirmedPaidToViewerCents: 4000,
            balanceCents: 6000,
          ),
        ),
      );
      // Huidige balans
      expect(find.text('Je hebt tegoed van Frits'), findsWidgets);
      expect(find.text('€60,00'), findsWidgets);
      // Uitgaven-uitkomst +€100
      expect(find.text('€100,00'), findsWidgets);
      // Betalingen-uitkomst −€40 → other has credit
      expect(find.text('Frits heeft tegoed van jou'), findsWidgets);
      expect(find.text('€40,00'), findsWidgets);
    });

    testWidgets('expense -100 / payment +40 → balance -60', (tester) async {
      await tester.pumpWidget(
        _host(
          _balance(
            expenseBalanceCents: -10000,
            confirmedPaidByViewerCents: 4000,
            balanceCents: -6000,
          ),
        ),
      );
      expect(find.text('Frits heeft tegoed van jou'), findsWidgets);
      expect(find.text('€60,00'), findsWidgets);
      expect(find.text('€100,00'), findsWidgets);
      expect(find.text('Je hebt tegoed van Frits'), findsWidgets);
      expect(find.text('€40,00'), findsWidgets);
    });
  });

  group('Scope exclusions', () {
    testWidgets('no opbouw / logboek / actions / jargon', (tester) async {
      await tester.pumpWidget(
        _host(
          _balance(
            expenseBalanceCents: 4650,
            confirmedPaidByViewerCents: 5500,
            balanceCents: 10150,
          ),
          hasPending: true,
        ),
      );
      expect(find.text('OPBOUW'), findsNothing);
      expect(find.text('Onderling betaald'), findsNothing);
      expect(find.text('Uitkomst'), findsNothing);
      expect(find.text('Door uitgaven'), findsNothing);
      expect(find.text('Door betalingen'), findsNothing);
      expect(find.text('Bekijk uitgaven'), findsNothing);
      expect(find.text('Bekijk betalingen'), findsNothing);
      expect(find.textContaining('expenseBalance'), findsNothing);
      expect(find.textContaining('settlement'), findsNothing);
      expect(find.text('Betaling melden'), findsNothing);
      expect(find.text('Klik hier om een betaling te melden'), findsNothing);
      expect(find.byType(Card), findsNWidgets(2));
      expect(find.text('HUIDIGE BALANS'), findsNothing);
    });
  });

  group('Navigatie', () {
    testWidgets('info opens Balansopbouw with data; body stays separate', (
      tester,
    ) async {
      var bodyTaps = 0;
      final balance = _balance(expenseBalanceCents: 10150, balanceCents: 10150);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildKiduTheme(),
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: BalanceCard(
                  balanceCents: balance.balanceCents,
                  otherName: 'Frits',
                  hasIncomingPending: false,
                  hasOutgoingPending: false,
                  formatEur: (c) =>
                      '€${c ~/ 100},${(c % 100).toString().padLeft(2, '0')}',
                  onInfoPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => BalansopbouwPage(
                          balance: balance,
                          viewerName: 'Bianca',
                          otherName: 'Frits',
                        ),
                      ),
                    );
                  },
                  onBodyTap: () => bodyTaps++,
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.byKey(BalanceCard.infoButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('Balansopbouw'), findsOneWidget);
      expect(find.text('HUIDIGE BALANS'), findsNothing);
      expect(find.text('Je hebt tegoed van Frits'), findsWidgets);
      expect(bodyTaps, 0);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(BalansopbouwPage), findsNothing);

      await tester.tap(find.byKey(BalanceCard.bodyKey));
      await tester.pump();
      expect(bodyTaps, 1);
    });
  });

  group('Responsive / a11y', () {
    for (final width in [360.0, 375.0, 390.0]) {
      testWidgets('no overflow at ${width.toInt()}px', (tester) async {
        await tester.pumpWidget(
          _host(
            _balance(
              totalExpenseCents: 71100,
              paidByViewerCents: 16900,
              paidByOtherCents: 54200,
              fairShareViewerCents: 27050,
              fairShareOtherCents: 44050,
              expenseBalanceCents: -10150,
              confirmedPaidByViewerCents: 7500,
              confirmedPaidToViewerCents: 2000,
              balanceCents: -4650,
            ),
            viewerName: 'Bianca-met-een-erg-lange-achternaam',
            otherName: 'Frits-van-de-hele-lange-naam',
            size: Size(width, 844),
          ),
        );
        await _expectNoOverflow(tester);
        expect(find.text('UITGAVEN'), findsOneWidget);
        expect(find.text('AANDEEL'), findsOneWidget);
        expect(find.text('Uitgegeven'), findsNothing);
      });
    }

    testWidgets('long names do not displace amounts', (tester) async {
      await tester.pumpWidget(
        _host(
          _balance(
            totalExpenseCents: 71100,
            paidByViewerCents: 16900,
            paidByOtherCents: 54200,
            fairShareViewerCents: 27050,
            fairShareOtherCents: 44050,
            expenseBalanceCents: -10150,
            balanceCents: -10150,
          ),
          viewerName: 'Bianca-met-een-erg-lange-achternaam-die-past',
          otherName: 'Frits-van-de-hele-lange-naam-die-ook-past',
          size: const Size(360, 844),
        ),
      );
      await _expectNoOverflow(tester);
      expect(find.text('€169,00'), findsOneWidget);
      expect(find.text('€542,00'), findsOneWidget);
      expect(find.text('€270,50'), findsOneWidget);
      expect(find.text('€440,50'), findsOneWidget);
    });

    testWidgets('elevated textScale no overflow', (tester) async {
      await tester.pumpWidget(
        _host(
          _balance(
            expenseBalanceCents: 10150,
            confirmedPaidByViewerCents: 7500,
            balanceCents: 17650,
          ),
          viewerName: 'Bianca Langenaam',
          otherName: 'Frits Langenaam',
          size: const Size(360, 844),
          textScale: 1.3,
        ),
      );
      await _expectNoOverflow(tester);
      expect(find.text('UITGAVEN'), findsOneWidget);
      expect(find.text('AANDEEL'), findsOneWidget);
    });
  });

  group('balanceCreditLine helper', () {
    test('signs and zero variants', () {
      expect(balanceCreditLine(1, 'Frits'), 'Je hebt tegoed van Frits');
      expect(balanceCreditLine(-1, 'Frits'), 'Frits heeft tegoed van jou');
      expect(balanceCreditLine(0, 'Frits'), 'Jullie zijn in balans');
      expect(balanceCreditLine(0, 'Frits', zeroLine: 'In balans'), 'In balans');
    });
  });
}
