import 'package:flutter_test/flutter_test.dart';
import 'package:kidu/balance/household_balance.dart';
import 'package:kidu/split/parent_split.dart';

const viewer = 'viewer';
const other = 'other';

Map<String, dynamic> _expense({
  required int amountCents,
  required String createdBy,
  ParentSplitSnapshot? split,
}) {
  return <String, dynamic>{
    'amountCents': amountCents,
    'createdBy': createdBy,
    if (split != null) ...split.toExpenseFields(),
  };
}

ParentSplitSnapshot _snap({
  required List<String> uids,
  required int share0Bps,
}) {
  return ParentSplitSnapshot.tryCreate(
    participantUids: uids,
    share0Bps: share0Bps,
  )!;
}

/// Exact copy of the former dashboard inline formula (pre–Stap 2).
/// Used only in tests to prove parity with [computeHouseholdBalance].
({
  int totalExpenseCents,
  int paidByViewerCents,
  int paidByOtherCents,
  int expenseBalanceCents,
  int balanceCents,
})
_referenceInlineBalance({
  required String viewerUid,
  required Iterable<Map<String, dynamic>> expenses,
  required int confirmedPaidByViewerCents,
  required int confirmedPaidToViewerCents,
  required int settlementPaidByViewerCents,
  required int settlementPaidToViewerCents,
}) {
  var totalExpenseCents = 0;
  var paidByViewerCents = 0;
  var legacyTotalCents = 0;
  var legacyMyPaidCents = 0;
  var snapshotBalanceCents = 0;

  for (final e in expenses) {
    final amountCents = (e['amountCents'] as num?)?.toInt() ?? 0;
    final createdBy = (e['createdBy'] as String?)?.trim();
    final myPaidForDoc = (createdBy == viewerUid) ? amountCents : 0;

    totalExpenseCents += amountCents;
    paidByViewerCents += myPaidForDoc;

    final snap = ParentSplitSnapshot.tryReadFromExpense(e);
    if (snap == null || !snap.participantUids.contains(viewerUid)) {
      legacyTotalCents += amountCents;
      legacyMyPaidCents += myPaidForDoc;
    } else {
      final myShare = snap.fairShareCentsFor(viewerUid, amountCents);
      snapshotBalanceCents += (myPaidForDoc - myShare);
    }
  }

  final legacyOtherPaidCents = legacyTotalCents - legacyMyPaidCents;
  final legacyHalfFloor = legacyTotalCents ~/ 2;
  final legacyRemainder = legacyTotalCents % 2;
  final legacyExpectedMy =
      legacyHalfFloor +
      ((legacyRemainder == 1 && legacyMyPaidCents < legacyOtherPaidCents)
          ? 1
          : 0);
  final rawBalanceCents =
      (legacyMyPaidCents - legacyExpectedMy) + snapshotBalanceCents;
  final balanceCents =
      rawBalanceCents +
      settlementPaidByViewerCents -
      settlementPaidToViewerCents +
      confirmedPaidByViewerCents -
      confirmedPaidToViewerCents;

  return (
    totalExpenseCents: totalExpenseCents,
    paidByViewerCents: paidByViewerCents,
    paidByOtherCents: totalExpenseCents - paidByViewerCents,
    expenseBalanceCents: rawBalanceCents,
    balanceCents: balanceCents,
  );
}

void _expectParity(
  HouseholdBalanceResult actual, {
  required String viewerUid,
  required List<Map<String, dynamic>> expenses,
  int confirmedPaidByViewerCents = 0,
  int confirmedPaidToViewerCents = 0,
  int settlementPaidByViewerCents = 0,
  int settlementPaidToViewerCents = 0,
}) {
  final ref = _referenceInlineBalance(
    viewerUid: viewerUid,
    expenses: expenses,
    confirmedPaidByViewerCents: confirmedPaidByViewerCents,
    confirmedPaidToViewerCents: confirmedPaidToViewerCents,
    settlementPaidByViewerCents: settlementPaidByViewerCents,
    settlementPaidToViewerCents: settlementPaidToViewerCents,
  );
  expect(actual.totalExpenseCents, ref.totalExpenseCents);
  expect(actual.paidByViewerCents, ref.paidByViewerCents);
  expect(actual.paidByOtherCents, ref.paidByOtherCents);
  expect(actual.expenseBalanceCents, ref.expenseBalanceCents);
  expect(actual.balanceCents, ref.balanceCents);
}

HouseholdBalanceResult _compute(
  List<Map<String, dynamic>> expenses, {
  int confirmedPaidByViewerCents = 0,
  int confirmedPaidToViewerCents = 0,
  int settlementPaidByViewerCents = 0,
  int settlementPaidToViewerCents = 0,
  String viewerUid = viewer,
}) {
  return computeHouseholdBalance(
    viewerUid: viewerUid,
    expenses: expenses,
    confirmedPaidByViewerCents: confirmedPaidByViewerCents,
    confirmedPaidToViewerCents: confirmedPaidToViewerCents,
    settlementPaidByViewerCents: settlementPaidByViewerCents,
    settlementPaidToViewerCents: settlementPaidToViewerCents,
  );
}

void main() {
  group('basis', () {
    test('geen uitgaven', () {
      final r = _compute(const []);
      expect(r.totalExpenseCents, 0);
      expect(r.paidByViewerCents, 0);
      expect(r.paidByOtherCents, 0);
      expect(r.fairShareViewerCents, 0);
      expect(r.fairShareOtherCents, 0);
      expect(r.expenseBalanceCents, 0);
      expect(r.balanceCents, 0);
      _expectParity(r, viewerUid: viewer, expenses: const []);
    });

    test('één 50/50-uitgave (legacy, viewer betaalt)', () {
      final expenses = [_expense(amountCents: 1000, createdBy: viewer)];
      final r = _compute(expenses);
      expect(r.totalExpenseCents, 1000);
      expect(r.paidByViewerCents, 1000);
      expect(r.paidByOtherCents, 0);
      expect(r.fairShareViewerCents, 500);
      expect(r.fairShareOtherCents, 500);
      expect(r.expenseBalanceCents, 500);
      expect(r.balanceCents, 500);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });

    test('viewer betaalt volledige uitgave', () {
      final expenses = [_expense(amountCents: 2500, createdBy: viewer)];
      final r = _compute(expenses);
      expect(r.paidByViewerCents, 2500);
      expect(r.paidByOtherCents, 0);
      expect(r.expenseBalanceCents, 1250);
      expect(r.balanceCents, 1250);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });

    test('other betaalt volledige uitgave', () {
      final expenses = [_expense(amountCents: 2500, createdBy: other)];
      final r = _compute(expenses);
      expect(r.paidByViewerCents, 0);
      expect(r.paidByOtherCents, 2500);
      // Even total: half-floor, no remainder adjustment
      expect(r.fairShareViewerCents, 1250);
      expect(r.expenseBalanceCents, -1250);
      expect(r.balanceCents, -1250);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });

    test('meerdere uitgaven → balance nul', () {
      final expenses = [
        _expense(amountCents: 1000, createdBy: viewer),
        _expense(amountCents: 1000, createdBy: other),
      ];
      final r = _compute(expenses);
      expect(r.totalExpenseCents, 2000);
      expect(r.paidByViewerCents, 1000);
      expect(r.paidByOtherCents, 1000);
      expect(r.fairShareViewerCents, 1000);
      expect(r.expenseBalanceCents, 0);
      expect(r.balanceCents, 0);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });
  });

  group('legacy rounding', () {
    test('oneven cent: viewer betaalde minder → remainder naar viewer', () {
      // total 101; halfFloor 50; remainder 1; myPaid 0 < otherPaid 101 → expected 51
      final expenses = [_expense(amountCents: 101, createdBy: other)];
      final r = _compute(expenses);
      expect(r.totalExpenseCents, 101);
      expect(r.paidByViewerCents, 0);
      expect(r.paidByOtherCents, 101);
      expect(r.fairShareViewerCents, 51);
      expect(r.fairShareOtherCents, 50);
      expect(r.expenseBalanceCents, -51);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });

    test('oneven cent: viewer betaalde meer → remainder niet naar viewer', () {
      // total 101; halfFloor 50; remainder 1; myPaid 101 > otherPaid 0 → expected 50
      final expenses = [_expense(amountCents: 101, createdBy: viewer)];
      final r = _compute(expenses);
      expect(r.fairShareViewerCents, 50);
      expect(r.fairShareOtherCents, 51);
      expect(r.expenseBalanceCents, 51);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });

    test('viewer minder betaald over meerdere legacy docs', () {
      final expenses = [
        _expense(amountCents: 300, createdBy: other),
        _expense(amountCents: 101, createdBy: other),
      ];
      final r = _compute(expenses);
      // total 401; half 200; rem 1; my 0 < other 401 → expected 201
      expect(r.fairShareViewerCents, 201);
      expect(r.expenseBalanceCents, -201);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });

    test('viewer meer betaald over meerdere legacy docs', () {
      final expenses = [
        _expense(amountCents: 300, createdBy: viewer),
        _expense(amountCents: 101, createdBy: viewer),
      ];
      final r = _compute(expenses);
      // total 401; half 200; rem 1; my 401 > other 0 → expected 200
      expect(r.fairShareViewerCents, 200);
      expect(r.expenseBalanceCents, 201);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });
  });

  group('parent split', () {
    final uidsViewer0 = <String>[viewer, other];
    final uidsViewer1 = <String>[other, viewer];

    test('50/50 snapshot', () {
      final split = _snap(uids: uidsViewer0, share0Bps: 5000);
      final expenses = [
        _expense(amountCents: 1000, createdBy: viewer, split: split),
      ];
      final r = _compute(expenses);
      expect(r.fairShareViewerCents, 500);
      expect(r.fairShareOtherCents, 500);
      expect(r.expenseBalanceCents, 500);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });

    test('60/40 snapshot (viewer participant 0)', () {
      final split = _snap(uids: uidsViewer0, share0Bps: 6000);
      final expenses = [
        _expense(amountCents: 1000, createdBy: viewer, split: split),
      ];
      final r = _compute(expenses);
      expect(r.fairShareViewerCents, 600);
      expect(r.fairShareOtherCents, 400);
      expect(r.expenseBalanceCents, 400); // paid 1000 − share 600
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });

    test('40/60 snapshot (viewer participant 0)', () {
      final split = _snap(uids: uidsViewer0, share0Bps: 4000);
      final expenses = [
        _expense(amountCents: 1000, createdBy: viewer, split: split),
      ];
      final r = _compute(expenses);
      expect(r.fairShareViewerCents, 400);
      expect(r.fairShareOtherCents, 600);
      expect(r.expenseBalanceCents, 600);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });

    test('100/0 snapshot', () {
      final split = _snap(uids: uidsViewer0, share0Bps: 10000);
      final expenses = [
        _expense(amountCents: 1000, createdBy: viewer, split: split),
      ];
      final r = _compute(expenses);
      expect(r.fairShareViewerCents, 1000);
      expect(r.fairShareOtherCents, 0);
      expect(r.expenseBalanceCents, 0);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });

    test('0/100 snapshot', () {
      final split = _snap(uids: uidsViewer0, share0Bps: 0);
      final expenses = [
        _expense(amountCents: 1000, createdBy: viewer, split: split),
      ];
      final r = _compute(expenses);
      expect(r.fairShareViewerCents, 0);
      expect(r.fairShareOtherCents, 1000);
      expect(r.expenseBalanceCents, 1000);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });

    test('viewer als participant 0', () {
      final split = _snap(uids: uidsViewer0, share0Bps: 6000);
      final expenses = [
        _expense(amountCents: 101, createdBy: other, split: split),
      ];
      final r = _compute(expenses);
      // floor(101 * 6000 / 10000) = 60 for participant 0
      expect(r.fairShareViewerCents, 60);
      expect(r.expenseBalanceCents, -60);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });

    test('viewer als participant 1', () {
      final split = _snap(uids: uidsViewer1, share0Bps: 6000);
      final expenses = [
        _expense(amountCents: 101, createdBy: other, split: split),
      ];
      final r = _compute(expenses);
      // participant0 (other) gets 60; viewer (p1) gets 41
      expect(r.fairShareViewerCents, 41);
      expect(r.expenseBalanceCents, -41);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });

    test('ontbrekende snapshot → legacy 50/50', () {
      final expenses = [_expense(amountCents: 101, createdBy: viewer)];
      final r = _compute(expenses);
      expect(r.fairShareViewerCents, 50);
      expect(r.expenseBalanceCents, 51);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });

    test('ongeldige snapshot → legacy 50/50', () {
      final expenses = [
        <String, dynamic>{
          'amountCents': 101,
          'createdBy': viewer,
          'parentSplitParticipantUids': <String>[viewer], // wrong length
          'parentSplit0ShareBps': 5000,
        },
      ];
      final r = _compute(expenses);
      expect(r.fairShareViewerCents, 50);
      expect(r.expenseBalanceCents, 51);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });

    test('viewer niet in participants → legacy path', () {
      final split = _snap(uids: <String>['x', 'y'], share0Bps: 6000);
      final expenses = [
        _expense(amountCents: 1000, createdBy: viewer, split: split),
      ];
      final r = _compute(expenses);
      // Treated as legacy 50/50
      expect(r.fairShareViewerCents, 500);
      expect(r.expenseBalanceCents, 500);
      _expectParity(r, viewerUid: viewer, expenses: expenses);
    });
  });

  group('resultaatvelden', () {
    test('alle expense-velden expliciet', () {
      final split = _snap(uids: <String>[viewer, other], share0Bps: 6000);
      final expenses = [
        _expense(amountCents: 1000, createdBy: viewer, split: split),
        _expense(amountCents: 400, createdBy: other), // legacy
      ];
      final r = _compute(expenses);
      expect(r.totalExpenseCents, 1400);
      expect(r.paidByViewerCents, 1000);
      expect(r.paidByOtherCents, 400);
      // snapshot share 600 + legacy expected: total legacy 400, half 200,
      // rem 0 → 200; but wait legacy is only the second expense.
      // legacy: total 400, myPaid 0, other 400, half 200, rem 0 → expected 200
      expect(r.fairShareViewerCents, 800);
      expect(r.fairShareOtherCents, 600);
      expect(r.expenseBalanceCents, 200); // 1000 - 800
    });
  });

  group('confirmed payments', () {
    test('viewer → other (+confirmedBy)', () {
      final expenses = [_expense(amountCents: 1000, createdBy: viewer)];
      // expense +500; +confirmedBy 200 → 700 (exacte tekenconventie)
      final r = _compute(expenses, confirmedPaidByViewerCents: 200);
      expect(r.expenseBalanceCents, 500);
      expect(r.confirmedPaidByViewerCents, 200);
      expect(r.balanceCents, 700);
      _expectParity(
        r,
        viewerUid: viewer,
        expenses: expenses,
        confirmedPaidByViewerCents: 200,
      );
    });

    test('other → viewer (−confirmedTo, verkleint positieve balans)', () {
      final expenses = [_expense(amountCents: 1000, createdBy: viewer)];
      final r = _compute(expenses, confirmedPaidToViewerCents: 200);
      expect(r.balanceCents, 300);
      _expectParity(
        r,
        viewerUid: viewer,
        expenses: expenses,
        confirmedPaidToViewerCents: 200,
      );
    });

    test('beide richtingen', () {
      final expenses = [_expense(amountCents: 1000, createdBy: viewer)];
      final r = _compute(
        expenses,
        confirmedPaidByViewerCents: 100,
        confirmedPaidToViewerCents: 300,
      );
      expect(r.balanceCents, 500 + 100 - 300);
      _expectParity(
        r,
        viewerUid: viewer,
        expenses: expenses,
        confirmedPaidByViewerCents: 100,
        confirmedPaidToViewerCents: 300,
      );
    });

    test('betaling die balans verkleint (other → viewer)', () {
      final expenses = [_expense(amountCents: 2000, createdBy: viewer)];
      // expense +1000; other pays viewer 400 → 600
      final r = _compute(expenses, confirmedPaidToViewerCents: 400);
      expect(r.balanceCents, 600);
      _expectParity(
        r,
        viewerUid: viewer,
        expenses: expenses,
        confirmedPaidToViewerCents: 400,
      );
    });

    test('betaling die door nul heen gaat', () {
      final expenses = [_expense(amountCents: 1000, createdBy: viewer)];
      // expense +500; other pays viewer 800 → -300
      final r = _compute(expenses, confirmedPaidToViewerCents: 800);
      expect(r.balanceCents, -300);
      _expectParity(
        r,
        viewerUid: viewer,
        expenses: expenses,
        confirmedPaidToViewerCents: 800,
      );
    });
  });

  group('settlements', () {
    test('beide richtingen', () {
      final expenses = [_expense(amountCents: 1000, createdBy: viewer)];
      final r = _compute(
        expenses,
        settlementPaidByViewerCents: 150,
        settlementPaidToViewerCents: 50,
      );
      expect(r.balanceCents, 500 + 150 - 50);
      _expectParity(
        r,
        viewerUid: viewer,
        expenses: expenses,
        settlementPaidByViewerCents: 150,
        settlementPaidToViewerCents: 50,
      );
    });

    test('combinatie met confirmed', () {
      final expenses = [_expense(amountCents: 1000, createdBy: other)];
      // legacy odd: expense -501 (total 1000 even → -500 actually)
      // 1000 even: half 500, rem 0 → expected 500; paid 0 → -500
      final r = _compute(
        expenses,
        settlementPaidByViewerCents: 200,
        settlementPaidToViewerCents: 50,
        confirmedPaidByViewerCents: 100,
        confirmedPaidToViewerCents: 25,
      );
      expect(r.expenseBalanceCents, -500);
      expect(r.balanceCents, -500 + 200 - 50 + 100 - 25);
      _expectParity(
        r,
        viewerUid: viewer,
        expenses: expenses,
        settlementPaidByViewerCents: 200,
        settlementPaidToViewerCents: 50,
        confirmedPaidByViewerCents: 100,
        confirmedPaidToViewerCents: 25,
      );
    });
  });

  group('decompositie', () {
    test(
      'expense + settlementBy - settlementTo + confirmedBy - confirmedTo',
      () {
        final split = _snap(uids: <String>[viewer, other], share0Bps: 4000);
        final expenses = [
          _expense(amountCents: 999, createdBy: viewer, split: split),
          _expense(amountCents: 101, createdBy: other),
        ];
        final r = _compute(
          expenses,
          settlementPaidByViewerCents: 33,
          settlementPaidToViewerCents: 11,
          confirmedPaidByViewerCents: 7,
          confirmedPaidToViewerCents: 19,
        );
        expect(
          r.balanceCents,
          r.expenseBalanceCents +
              r.settlementPaidByViewerCents -
              r.settlementPaidToViewerCents +
              r.confirmedPaidByViewerCents -
              r.confirmedPaidToViewerCents,
        );
        _expectParity(
          r,
          viewerUid: viewer,
          expenses: expenses,
          settlementPaidByViewerCents: 33,
          settlementPaidToViewerCents: 11,
          confirmedPaidByViewerCents: 7,
          confirmedPaidToViewerCents: 19,
        );
      },
    );
  });

  group('parity datasets', () {
    test('gemengde legacy + snapshot + payments', () {
      final datasets = <List<Map<String, dynamic>>>[
        const [],
        [_expense(amountCents: 1, createdBy: viewer)],
        [_expense(amountCents: 1, createdBy: other)],
        [
          _expense(amountCents: 333, createdBy: viewer),
          _expense(amountCents: 667, createdBy: other),
        ],
        [
          _expense(
            amountCents: 12345,
            createdBy: viewer,
            split: _snap(uids: <String>[viewer, other], share0Bps: 7000),
          ),
          _expense(
            amountCents: 99,
            createdBy: other,
            split: _snap(uids: <String>[other, viewer], share0Bps: 2500),
          ),
          _expense(amountCents: 50, createdBy: viewer),
        ],
      ];

      for (final expenses in datasets) {
        for (final confirmedBy in [0, 10, 500]) {
          for (final confirmedTo in [0, 25, 500]) {
            for (final settBy in [0, 40]) {
              for (final settTo in [0, 60]) {
                final r = _compute(
                  expenses,
                  confirmedPaidByViewerCents: confirmedBy,
                  confirmedPaidToViewerCents: confirmedTo,
                  settlementPaidByViewerCents: settBy,
                  settlementPaidToViewerCents: settTo,
                );
                _expectParity(
                  r,
                  viewerUid: viewer,
                  expenses: expenses,
                  confirmedPaidByViewerCents: confirmedBy,
                  confirmedPaidToViewerCents: confirmedTo,
                  settlementPaidByViewerCents: settBy,
                  settlementPaidToViewerCents: settTo,
                );
              }
            }
          }
        }
      }
    });
  });
}
