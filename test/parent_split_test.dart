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
    test('rejects 0 and 10000', () {
      expect(isValidHouseholdShareBps(0), false);
      expect(isValidHouseholdShareBps(10000), false);
    });

    test('accepts interior range', () {
      expect(isValidHouseholdShareBps(100), true);
      expect(isValidHouseholdShareBps(9900), true);
      expect(isValidHouseholdShareBps(5000), true);
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
