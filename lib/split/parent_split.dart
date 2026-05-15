// Household parent-split primitives.
//
// - Household default share-bps is v1-constrained to
//   [kHouseholdShareBpsMin..kHouseholdShareBpsMax]. 0 and 10000
//   (everything-on-one-parent) are intentionally disallowed for
//   defaults; enforced here, in the repository, in the settings UI
//   slider, and in firestore.rules for `settings/defaults` and recurring
//   masters.
// - Expense snapshot `parentSplit0ShareBps` on **one-time** expenses
//   may be [0..kBpsFull] so a single expense can be 100/0 or 0/100;
//   see `isValidExpenseSnapshotShareBps` and firestore expense create
//   rules (materialized recurring instances stay 100..9900).
// - The expense snapshot (`parentSplitParticipantUids`,
//   `parentSplit0ShareBps`) is immutable once written and applies to
//   NEW expenses only.
// - Stale / structurally invalid household settings MUST NOT land old
//   bps on a different uid. For a household with EXACTLY 2 current
//   members, `buildSnapshotForNewExpense` falls back to an EXPLICIT
//   neutral 50/50 snapshot for those two members instead of reusing
//   the stale bps. Solo / >2-member households return null; those
//   expenses are written WITHOUT snapshot fields and the dashboard's
//   legacy 50/50 path handles them.

const int kBpsFull = 10000;
const int kHouseholdShareBpsMin = 100;
const int kHouseholdShareBpsMax = 9900;
const int kHouseholdShareBpsNeutral = 5000;
const int kParentSplitParticipantCount = 2;

bool isValidHouseholdShareBps(int bps) =>
    bps >= kHouseholdShareBpsMin && bps <= kHouseholdShareBpsMax;

/// Per-expense snapshot on `expenses/{id}` (one-time creates only
/// may use 0 or 10000; recurring materialized rows stay 100..9900 via
/// rules). Used by [ParentSplitSnapshot.tryCreate] and
/// [ParentSplitSnapshot.tryReadFromExpense].
bool isValidExpenseSnapshotShareBps(int bps) => bps >= 0 && bps <= kBpsFull;

List<String> sortedParticipantUids(String a, String b) {
  final list = <String>[a, b]..sort();
  return List<String>.unmodifiable(list);
}

class HouseholdSplitDefaults {
  final String share0Uid;
  final String share1Uid;
  final int share0Bps;
  final String? updatedBy;
  final DateTime? updatedAt;

  const HouseholdSplitDefaults({
    required this.share0Uid,
    required this.share1Uid,
    required this.share0Bps,
    this.updatedBy,
    this.updatedAt,
  });

  bool isStructurallyValid() {
    if (share0Uid.isEmpty || share1Uid.isEmpty) return false;
    if (share0Uid == share1Uid) return false;
    if (!isValidHouseholdShareBps(share0Bps)) return false;
    return true;
  }

  bool isValidForMembers(Set<String> currentMemberUids) {
    if (!isStructurallyValid()) return false;
    if (currentMemberUids.length != kParentSplitParticipantCount) return false;
    final pair = <String>{share0Uid, share1Uid};
    if (pair.length != kParentSplitParticipantCount) return false;
    return pair.difference(currentMemberUids).isEmpty &&
        currentMemberUids.difference(pair).isEmpty;
  }
}

class ParentSplitSnapshot {
  final List<String> participantUids;
  final int share0Bps;

  ParentSplitSnapshot._({
    required this.participantUids,
    required this.share0Bps,
  });

  int get share1Bps => kBpsFull - share0Bps;

  Map<String, dynamic> toExpenseFields() => <String, dynamic>{
    'parentSplitParticipantUids': participantUids,
    'parentSplit0ShareBps': share0Bps,
  };

  static ParentSplitSnapshot? tryCreate({
    required List<String> participantUids,
    required int share0Bps,
  }) {
    if (participantUids.length != kParentSplitParticipantCount) return null;
    final uid0 = participantUids[0];
    final uid1 = participantUids[1];
    if (uid0.isEmpty || uid1.isEmpty) return null;
    if (uid0 == uid1) return null;
    if (!isValidExpenseSnapshotShareBps(share0Bps)) return null;
    return ParentSplitSnapshot._(
      participantUids: List<String>.unmodifiable(<String>[uid0, uid1]),
      share0Bps: share0Bps,
    );
  }

  /// Parses a snapshot from an expense document. Returns null if any
  /// invariant fails (wrong shape, stranger fields, out-of-range bps).
  /// A null result is the callers' signal to treat the expense as
  /// legacy 50/50.
  static ParentSplitSnapshot? tryReadFromExpense(Map<String, dynamic> data) {
    final raw = data['parentSplitParticipantUids'];
    final bpsRaw = data['parentSplit0ShareBps'];
    if (raw is! List || bpsRaw is! num) return null;
    if (raw.length != kParentSplitParticipantCount) return null;
    for (final e in raw) {
      if (e is! String || e.isEmpty) return null;
    }
    final uid0 = raw[0] as String;
    final uid1 = raw[1] as String;
    if (uid0 == uid1) return null;
    final bps = bpsRaw.toInt();
    return ParentSplitSnapshot.tryCreate(
      participantUids: <String>[uid0, uid1],
      share0Bps: bps,
    );
  }

  /// Fair-share cents for [uid]. Rounding convention: participant[0]
  /// gets `floor(amount * share0Bps / 10000)`, participant[1] gets the
  /// remainder, so the two shares sum to exactly `amountCents`.
  int fairShareCentsFor(String uid, int amountCents) {
    if (amountCents <= 0) return 0;
    final share0 = (amountCents * share0Bps) ~/ kBpsFull;
    if (uid == participantUids[0]) return share0;
    if (uid == participantUids[1]) return amountCents - share0;
    // uid not a participant — defensive neutral split. Should not
    // occur for a 2-member household snapshot.
    return amountCents ~/ 2;
  }
}

/// Builds an immutable snapshot for a NEW expense.
///
/// Contract:
/// - Exactly 2 current members + settings that are structurally valid
///   AND map 1:1 to those two members → snapshot derived from settings
///   (sorted participant uids, share0Bps in [100..9900]).
/// - Exactly 2 current members + settings that are missing,
///   structurally invalid, or stale → EXPLICIT neutral 50/50 snapshot
///   for those two current members. The stale share0Bps is discarded;
///   it is NEVER reapplied to a different uid.
/// - Any other member count (solo, >2) → null. Caller writes the
///   expense WITHOUT snapshot fields and the dashboard's legacy 50/50
///   path handles it.
ParentSplitSnapshot? buildSnapshotForNewExpense({
  required HouseholdSplitDefaults? defaults,
  required Set<String> currentMemberUids,
}) {
  if (currentMemberUids.length != kParentSplitParticipantCount) return null;

  final currentUids = currentMemberUids.toList(growable: false);
  final sortedCurrentUids = sortedParticipantUids(
    currentUids[0],
    currentUids[1],
  );

  if (defaults != null && defaults.isValidForMembers(currentMemberUids)) {
    final sortedUids = sortedParticipantUids(
      defaults.share0Uid,
      defaults.share1Uid,
    );
    final int snapshotShare0Bps = (sortedUids[0] == defaults.share0Uid)
        ? defaults.share0Bps
        : kBpsFull - defaults.share0Bps;
    if (isValidExpenseSnapshotShareBps(snapshotShare0Bps)) {
      return ParentSplitSnapshot._(
        participantUids: sortedUids,
        share0Bps: snapshotShare0Bps,
      );
    }
    // defaults.share0Bps is range-checked upstream; this guard exists
    // only to ensure we never emit an out-of-range snapshot. Fall
    // through to neutral 50/50 below.
  }

  // Missing / structurally invalid / stale settings, with exactly 2
  // current members → EXPLICIT neutral 50/50 snapshot. The old
  // share0Bps (if any) is deliberately discarded; it is never
  // reapplied to a different uid.
  return ParentSplitSnapshot._(
    participantUids: sortedCurrentUids,
    share0Bps: kHouseholdShareBpsNeutral,
  );
}
