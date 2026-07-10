/// Small, dependency-free helpers for reading the household read-only status.
///
/// Fase 1 scope: this file only *reads* `isReadOnly` (and its metadata
/// fields) from already-loaded Firestore data. It intentionally does not
/// write anything — setting a household to read-only is not part of this
/// phase.
library;

import 'package:cloud_firestore/cloud_firestore.dart';

/// Reads `isReadOnly` from a household document map.
///
/// A missing/null/non-bool value is treated as `false`, so households that
/// predate this field behave exactly as before.
bool isHouseholdDataReadOnly(Map<String, dynamic>? householdData) {
  final value = householdData?['isReadOnly'];
  return value == true;
}

/// Convenience wrapper around [isHouseholdDataReadOnly] for a household
/// document snapshot (handles the "no snapshot yet" / "doc doesn't exist"
/// cases the same way: not read-only).
bool isHouseholdSnapshotReadOnly(
  DocumentSnapshot<Map<String, dynamic>>? snapshot,
) {
  if (snapshot == null || !snapshot.exists) return false;
  return isHouseholdDataReadOnly(snapshot.data());
}

/// Optional metadata captured alongside `isReadOnly`. Fase 1 does not write
/// these fields yet, but reads them defensively so the UI already behaves
/// correctly once a future phase starts setting them.
class HouseholdReadOnlyStatus {
  const HouseholdReadOnlyStatus({
    required this.isReadOnly,
    this.readOnlyAt,
    this.readOnlyReason,
    this.readOnlyBy,
  });

  final bool isReadOnly;
  final Timestamp? readOnlyAt;
  final String? readOnlyReason;
  final String? readOnlyBy;

  static const HouseholdReadOnlyStatus notReadOnly = HouseholdReadOnlyStatus(
    isReadOnly: false,
  );

  factory HouseholdReadOnlyStatus.fromHouseholdData(
    Map<String, dynamic>? householdData,
  ) {
    if (householdData == null) return notReadOnly;
    final isReadOnly = isHouseholdDataReadOnly(householdData);
    if (!isReadOnly) return notReadOnly;
    return HouseholdReadOnlyStatus(
      isReadOnly: true,
      readOnlyAt: householdData['readOnlyAt'] is Timestamp
          ? householdData['readOnlyAt'] as Timestamp
          : null,
      readOnlyReason: (householdData['readOnlyReason'] as String?)?.trim(),
      readOnlyBy: (householdData['readOnlyBy'] as String?)?.trim(),
    );
  }
}
