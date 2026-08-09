import '../split/parent_split.dart';

/// Immutable household balance derived from expenses, settlements and
/// confirmed payments. Pure data — no UI copy, names, or Firestore types.
class HouseholdBalanceResult {
  const HouseholdBalanceResult({
    required this.totalExpenseCents,
    required this.paidByViewerCents,
    required this.paidByOtherCents,
    required this.fairShareViewerCents,
    required this.fairShareOtherCents,
    required this.expenseBalanceCents,
    required this.confirmedPaidByViewerCents,
    required this.confirmedPaidToViewerCents,
    required this.settlementPaidByViewerCents,
    required this.settlementPaidToViewerCents,
    required this.balanceCents,
  });

  final int totalExpenseCents;
  final int paidByViewerCents;
  final int paidByOtherCents;
  final int fairShareViewerCents;
  final int fairShareOtherCents;

  /// Expense-only balance: paidByViewer − fairShareViewer.
  /// Sign: >0 co-parent owes viewer; <0 viewer owes co-parent.
  final int expenseBalanceCents;

  final int confirmedPaidByViewerCents;
  final int confirmedPaidToViewerCents;
  final int settlementPaidByViewerCents;
  final int settlementPaidToViewerCents;

  /// Full balance including settlements and confirmed payments.
  /// Sign: >0 co-parent pays viewer; <0 viewer pays co-parent; 0 in balans.
  final int balanceCents;
}

/// Pure household balance computation.
///
/// Reproduces the former dashboard inline formula exactly:
/// - legacy (no/invalid snapshot, or viewer not a participant): aggregate
///   50/50 with half-floor and odd-cent remainder to the lower payer;
/// - snapshot expenses: per-expense (myPaid − myFairShare);
/// - settlements: +settlementPaidByViewer − settlementPaidToViewer;
/// - confirmed payments: +confirmedPaidByViewer − confirmedPaidToViewer.
///
/// Pending payments are intentionally excluded.
HouseholdBalanceResult computeHouseholdBalance({
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
  var snapshotFairShareViewerCents = 0;

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
      snapshotFairShareViewerCents += myShare;
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

  final fairShareViewerCents = legacyExpectedMy + snapshotFairShareViewerCents;
  final paidByOtherCents = totalExpenseCents - paidByViewerCents;
  final fairShareOtherCents = totalExpenseCents - fairShareViewerCents;
  final expenseBalanceCents =
      (legacyMyPaidCents - legacyExpectedMy) + snapshotBalanceCents;

  final balanceCents =
      expenseBalanceCents +
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
    balanceCents: balanceCents,
  );
}
