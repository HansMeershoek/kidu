import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'parent_split.dart';

/// Reads/writes `households/{householdId}/settings/defaults`.
///
/// `save()` enforces share0Bps in [0..kBpsFull] (via
/// `isValidHouseholdShareBps`) and rejects identical uids client-side
/// so the UI never round-trips an invalid state; Firestore rules
/// enforce the same invariants server-side.
class HouseholdSplitSettingsRepository {
  HouseholdSplitSettingsRepository({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  DocumentReference<Map<String, dynamic>> _docRef(String householdId) =>
      _firestore.doc('households/$householdId/settings/defaults');

  HouseholdSplitDefaults? _parseDefaultsData(Map<String, dynamic>? data) {
    if (data == null) return null;
    final uid0 = data['share0Uid'];
    final uid1 = data['share1Uid'];
    final bps = data['share0Bps'];
    if (uid0 is! String || uid1 is! String || bps is! num) return null;
    final defaults = HouseholdSplitDefaults(
      share0Uid: uid0,
      share1Uid: uid1,
      share0Bps: bps.toInt(),
      updatedBy: data['updatedBy'] as String?,
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
    if (!defaults.isStructurallyValid()) return null;
    return defaults;
  }

  /// Loads a structurally-valid [HouseholdSplitDefaults], or null. A
  /// structurally-valid result may still be stale relative to the
  /// current 2 members; that stale-check is the caller's responsibility
  /// (`buildSnapshotForNewExpense` and the settings page both do it).
  Future<HouseholdSplitDefaults?> load(String householdId) async {
    if (householdId.isEmpty) return null;
    final snap = await _docRef(householdId).get();
    if (!snap.exists) return null;
    return _parseDefaultsData(snap.data());
  }

  /// Server-confirmed defaults stream; cache snapshots are ignored.
  Stream<HouseholdSplitDefaults?> watch(String householdId) {
    if (householdId.isEmpty) return Stream.value(null);
    return _docRef(householdId)
        .snapshots(includeMetadataChanges: true)
        .where((snap) => !snap.metadata.isFromCache)
        .map((snap) {
          if (!snap.exists) return null;
          return _parseDefaultsData(snap.data());
        });
  }

  Future<void> save({
    required String householdId,
    required String share0Uid,
    required String share1Uid,
    required int share0Bps,
  }) async {
    if (householdId.isEmpty) {
      throw ArgumentError('householdId required');
    }
    if (share0Uid.isEmpty || share1Uid.isEmpty) {
      throw ArgumentError('share0Uid and share1Uid must both be non-empty');
    }
    if (share0Uid == share1Uid) {
      throw ArgumentError('share0Uid and share1Uid must differ');
    }
    if (!isValidHouseholdShareBps(share0Bps)) {
      throw ArgumentError(
        'share0Bps ($share0Bps) out of range '
        '[$kHouseholdShareBpsMin..$kHouseholdShareBpsMax]',
      );
    }
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('not signed in');
    }

    await _docRef(householdId).set(<String, dynamic>{
      'share0Uid': share0Uid,
      'share1Uid': share1Uid,
      'share0Bps': share0Bps,
      'updatedBy': uid,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }
}
