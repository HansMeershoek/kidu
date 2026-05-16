import 'package:flutter_test/flutter_test.dart';
import 'package:kidu/split/parent_split.dart';

void main() {
  const uid0 = 'a';
  const uid1 = 'b';
  const uids = <String>[uid0, uid1];

  group('fairShareCentsFor', () {
    test('0 bps: participant0 gets 0, participant1 gets full amount', () {
      final snap = ParentSplitSnapshot.tryCreate(
        participantUids: uids,
        share0Bps: 0,
      )!;
      expect(snap.fairShareCentsFor(uid0, 12345), 0);
      expect(snap.fairShareCentsFor(uid1, 12345), 12345);
    });

    test('10000 bps: participant0 gets full amount, participant1 gets 0', () {
      final snap = ParentSplitSnapshot.tryCreate(
        participantUids: uids,
        share0Bps: 10000,
      )!;
      expect(snap.fairShareCentsFor(uid0, 9999), 9999);
      expect(snap.fairShareCentsFor(uid1, 9999), 0);
    });

    test('5000 bps regression: floor to first, remainder to second', () {
      final snap = ParentSplitSnapshot.tryCreate(
        participantUids: uids,
        share0Bps: 5000,
      )!;
      expect(snap.fairShareCentsFor(uid0, 101), 50);
      expect(snap.fairShareCentsFor(uid1, 101), 51);
    });
  });

  group('ParentSplitSnapshot.tryCreate', () {
    test('accepts 0 and 10000 bps', () {
      expect(
        ParentSplitSnapshot.tryCreate(participantUids: uids, share0Bps: 0),
        isNotNull,
      );
      expect(
        ParentSplitSnapshot.tryCreate(participantUids: uids, share0Bps: 10000),
        isNotNull,
      );
    });

    test('rejects out-of-range bps', () {
      expect(
        ParentSplitSnapshot.tryCreate(participantUids: uids, share0Bps: -1),
        isNull,
      );
      expect(
        ParentSplitSnapshot.tryCreate(participantUids: uids, share0Bps: 10001),
        isNull,
      );
    });
  });

  group('isValidHouseholdShareBps', () {
    test('accepts 0 and full bps', () {
      expect(isValidHouseholdShareBps(0), true);
      expect(isValidHouseholdShareBps(kBpsFull), true);
    });

    test('accepts typical interior shares', () {
      expect(isValidHouseholdShareBps(100), true);
      expect(isValidHouseholdShareBps(9900), true);
      expect(isValidHouseholdShareBps(5000), true);
    });

    test('rejects out of range', () {
      expect(isValidHouseholdShareBps(-1), false);
      expect(isValidHouseholdShareBps(10001), false);
    });
  });

  group('HouseholdSplitDefaults structural validity', () {
    test('allows share0Bps at 0 and 10000', () {
      const d0 = HouseholdSplitDefaults(
        share0Uid: uid0,
        share1Uid: uid1,
        share0Bps: 0,
      );
      const dFull = HouseholdSplitDefaults(
        share0Uid: uid0,
        share1Uid: uid1,
        share0Bps: kBpsFull,
      );
      expect(d0.isStructurallyValid(), true);
      expect(dFull.isStructurallyValid(), true);
    });

    test('rejects invalid uids despite valid share0Bps', () {
      expect(
        const HouseholdSplitDefaults(
          share0Uid: uid0,
          share1Uid: uid1,
          share0Bps: 5000,
        ).isStructurallyValid(),
        true,
      );
      expect(
        const HouseholdSplitDefaults(
          share0Uid: '',
          share1Uid: uid1,
          share0Bps: 5000,
        ).isStructurallyValid(),
        false,
      );
    });
  });

  group('tryReadFromExpense', () {
    test('parses 0 bps snapshot', () {
      final snap = ParentSplitSnapshot.tryReadFromExpense({
        'parentSplitParticipantUids': <String>[uid0, uid1],
        'parentSplit0ShareBps': 0,
      });
      expect(snap, isNotNull);
      expect(snap!.share0Bps, 0);
    });
  });
}
