/// Fase 3 — account-deletion logic for all four household states
/// (`activeWithCoParent`, `noHousehold`, `activeSolo`, `readOnly`).
///
/// Pure orchestration around Firestore, Firebase Auth and Google Sign-In.
/// Contains no widgets: the confirmation/explanation/success UI in
/// `account_delete_info_page.dart` calls into this file and only reacts to
/// the results. Nothing here runs unless explicitly invoked by that UI —
/// no Firestore/Auth write happens as a side effect of importing this file.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'account_delete_texts.dart';

/// Reasons the activeSolo eligibility check can fail.
enum ActiveSoloEligibilityFailure {
  householdMismatch,
  householdMissing,
  householdReadOnly,
  notMember,
  hasCoParent,
  unknown,
}

/// Result of [AccountDeleteController.checkActiveSoloEligibility].
class ActiveSoloEligibility {
  const ActiveSoloEligibility.eligible() : failure = null;
  const ActiveSoloEligibility.notEligible(ActiveSoloEligibilityFailure this.failure);

  final ActiveSoloEligibilityFailure? failure;

  bool get isEligible => failure == null;
}

/// Reasons the noHousehold eligibility check can fail.
enum NoHouseholdEligibilityFailure { householdLinked, unknown }

/// Result of [AccountDeleteController.checkNoHouseholdEligibility].
class NoHouseholdEligibility {
  const NoHouseholdEligibility.eligible() : failure = null;
  const NoHouseholdEligibility.notEligible(NoHouseholdEligibilityFailure this.failure);

  final NoHouseholdEligibilityFailure? failure;

  bool get isEligible => failure == null;
}

/// Reasons the readOnly eligibility check can fail.
enum ReadOnlyEligibilityFailure {
  householdMismatch,
  householdMissing,
  notReadOnly,
  notMember,
  unknown,
}

/// Result of [AccountDeleteController.checkReadOnlyEligibility].
class ReadOnlyEligibility {
  const ReadOnlyEligibility.eligible() : failure = null;
  const ReadOnlyEligibility.notEligible(ReadOnlyEligibilityFailure this.failure);

  final ReadOnlyEligibilityFailure? failure;

  bool get isEligible => failure == null;
}

/// Reasons the eligibility check vlak vóór destructive work can fail.
enum AccountDeleteEligibilityFailure {
  householdMismatch,
  householdMissing,
  householdReadOnly,
  notMember,
  noCoParent,
  unknown,
}

/// Result of [AccountDeleteController.checkEligibility].
class AccountDeleteEligibility {
  const AccountDeleteEligibility.eligible() : failure = null;
  const AccountDeleteEligibility.notEligible(AccountDeleteEligibilityFailure this.failure);

  final AccountDeleteEligibilityFailure? failure;

  bool get isEligible => failure == null;
}

/// Reasons a Google re-auth attempt (see
/// [AccountDeleteController.performGoogleReauth]) did not succeed.
enum AccountDeleteReauthFailureReason { cancelledByUser, accountMismatch, failed }

/// Result of [AccountDeleteController.performGoogleReauth].
class AccountDeleteReauthResult {
  const AccountDeleteReauthResult.success() : failureReason = null;
  const AccountDeleteReauthResult.failure(
    AccountDeleteReauthFailureReason this.failureReason,
  );

  final AccountDeleteReauthFailureReason? failureReason;

  bool get success => failureReason == null;
}

/// Fase 3 orchestration for deleting an account, for any of the four
/// household states. Every method below is a single, explicit step —
/// callers decide the order (see `account_delete_info_page` for the full
/// safe sequence).
class AccountDeleteController {
  AccountDeleteController._();

  static final GoogleSignIn _googleSignIn = GoogleSignIn.instance;

  /// Confirms — right before re-auth/delete, not earlier — that the caller
  /// is still signed in as a member of an active (non read-only) household
  /// that has at least one other member. Read-only; never writes.
  static Future<AccountDeleteEligibility> checkEligibility({
    required String householdId,
    required String uid,
  }) async {
    final trimmedHouseholdId = householdId.trim();
    if (trimmedHouseholdId.isEmpty) {
      return const AccountDeleteEligibility.notEligible(
        AccountDeleteEligibilityFailure.householdMismatch,
      );
    }

    final firestore = FirebaseFirestore.instance;
    try {
      final userSnap = await firestore.doc('users/$uid').get();
      final userHouseholdId = (userSnap.data()?['householdId'] as String?)
          ?.trim();
      if (userHouseholdId == null || userHouseholdId != trimmedHouseholdId) {
        return const AccountDeleteEligibility.notEligible(
          AccountDeleteEligibilityFailure.householdMismatch,
        );
      }

      final householdSnap = await firestore
          .doc('households/$trimmedHouseholdId')
          .get();
      if (!householdSnap.exists) {
        return const AccountDeleteEligibility.notEligible(
          AccountDeleteEligibilityFailure.householdMissing,
        );
      }
      if (householdSnap.data()?['isReadOnly'] == true) {
        return const AccountDeleteEligibility.notEligible(
          AccountDeleteEligibilityFailure.householdReadOnly,
        );
      }

      final membersSnap = await firestore
          .collection('households/$trimmedHouseholdId/members')
          .get();
      final memberIds = membersSnap.docs.map((doc) => doc.id).toSet();
      if (!memberIds.contains(uid)) {
        return const AccountDeleteEligibility.notEligible(
          AccountDeleteEligibilityFailure.notMember,
        );
      }
      if (memberIds.length < 2) {
        return const AccountDeleteEligibility.notEligible(
          AccountDeleteEligibilityFailure.noCoParent,
        );
      }

      return const AccountDeleteEligibility.eligible();
    } catch (_) {
      return const AccountDeleteEligibility.notEligible(
        AccountDeleteEligibilityFailure.unknown,
      );
    }
  }

  /// Confirms — right before re-auth/delete, not earlier — that the caller
  /// is the sole member of an active (non read-only) household. Read-only;
  /// never writes.
  static Future<ActiveSoloEligibility> checkActiveSoloEligibility({
    required String householdId,
    required String uid,
  }) async {
    final trimmedHouseholdId = householdId.trim();
    if (trimmedHouseholdId.isEmpty) {
      return const ActiveSoloEligibility.notEligible(
        ActiveSoloEligibilityFailure.householdMismatch,
      );
    }

    final firestore = FirebaseFirestore.instance;
    try {
      final userSnap = await firestore.doc('users/$uid').get();
      final userHouseholdId = (userSnap.data()?['householdId'] as String?)
          ?.trim();
      if (userHouseholdId == null || userHouseholdId != trimmedHouseholdId) {
        return const ActiveSoloEligibility.notEligible(
          ActiveSoloEligibilityFailure.householdMismatch,
        );
      }

      final householdSnap = await firestore
          .doc('households/$trimmedHouseholdId')
          .get();
      if (!householdSnap.exists) {
        return const ActiveSoloEligibility.notEligible(
          ActiveSoloEligibilityFailure.householdMissing,
        );
      }
      if (householdSnap.data()?['isReadOnly'] == true) {
        return const ActiveSoloEligibility.notEligible(
          ActiveSoloEligibilityFailure.householdReadOnly,
        );
      }

      final membersSnap = await firestore
          .collection('households/$trimmedHouseholdId/members')
          .get();
      final memberIds = membersSnap.docs.map((doc) => doc.id).toSet();
      if (!memberIds.contains(uid)) {
        return const ActiveSoloEligibility.notEligible(
          ActiveSoloEligibilityFailure.notMember,
        );
      }
      if (memberIds.length > 1) {
        return const ActiveSoloEligibility.notEligible(
          ActiveSoloEligibilityFailure.hasCoParent,
        );
      }

      return const ActiveSoloEligibility.eligible();
    } catch (_) {
      return const ActiveSoloEligibility.notEligible(
        ActiveSoloEligibilityFailure.unknown,
      );
    }
  }

  /// Confirms — right before re-auth/delete, not earlier — that the caller
  /// is signed in but not linked to any household. Read-only; never writes.
  static Future<NoHouseholdEligibility> checkNoHouseholdEligibility({
    required String uid,
  }) async {
    final firestore = FirebaseFirestore.instance;
    try {
      final userSnap = await firestore.doc('users/$uid').get();
      final userHouseholdId =
          (userSnap.data()?['householdId'] as String?)?.trim();
      if (userHouseholdId != null && userHouseholdId.isNotEmpty) {
        return const NoHouseholdEligibility.notEligible(
          NoHouseholdEligibilityFailure.householdLinked,
        );
      }
      return const NoHouseholdEligibility.eligible();
    } catch (_) {
      return const NoHouseholdEligibility.notEligible(
        NoHouseholdEligibilityFailure.unknown,
      );
    }
  }

  /// Confirms — right before re-auth/delete, not earlier — that the caller
  /// is still a member of a household that is currently read-only (Fase
  /// 3d). Read-only; never writes. Deliberately does not require this to be
  /// the last member — Fase 3 never performs a full household cleanup for
  /// read-only households, so any remaining member may delete their own
  /// account/membership independently of others.
  static Future<ReadOnlyEligibility> checkReadOnlyEligibility({
    required String householdId,
    required String uid,
  }) async {
    final trimmedHouseholdId = householdId.trim();
    if (trimmedHouseholdId.isEmpty) {
      return const ReadOnlyEligibility.notEligible(
        ReadOnlyEligibilityFailure.householdMismatch,
      );
    }

    final firestore = FirebaseFirestore.instance;
    try {
      final userSnap = await firestore.doc('users/$uid').get();
      final userHouseholdId = (userSnap.data()?['householdId'] as String?)
          ?.trim();
      if (userHouseholdId == null || userHouseholdId != trimmedHouseholdId) {
        return const ReadOnlyEligibility.notEligible(
          ReadOnlyEligibilityFailure.householdMismatch,
        );
      }

      final householdSnap = await firestore
          .doc('households/$trimmedHouseholdId')
          .get();
      if (!householdSnap.exists) {
        return const ReadOnlyEligibility.notEligible(
          ReadOnlyEligibilityFailure.householdMissing,
        );
      }
      if (householdSnap.data()?['isReadOnly'] != true) {
        return const ReadOnlyEligibility.notEligible(
          ReadOnlyEligibilityFailure.notReadOnly,
        );
      }

      final memberSnap = await firestore
          .doc('households/$trimmedHouseholdId/members/$uid')
          .get();
      if (!memberSnap.exists) {
        return const ReadOnlyEligibility.notEligible(
          ReadOnlyEligibilityFailure.notMember,
        );
      }

      return const ReadOnlyEligibility.eligible();
    } catch (_) {
      return const ReadOnlyEligibility.notEligible(
        ReadOnlyEligibilityFailure.unknown,
      );
    }
  }

  /// Google re-auth for the delete flow — only call this after the user
  /// explicitly taps "Bevestigen met Google" on the KiDu explanation page,
  /// never automatically/beforehand.
  ///
  /// Uses `attemptLightweightAuthentication()` rather than `authenticate()`:
  /// on Android this shows Credential Manager's account bottom sheet
  /// (preferred), whereas `authenticate()` shows the older account-picker
  /// card. Since this is only ever invoked from an explicit button tap, it
  /// is "lightweight" in implementation, not silent in UX — the KiDu
  /// explanation always comes first.
  static Future<AccountDeleteReauthResult> performGoogleReauth(
    User user,
  ) async {
    try {
      final pending = _googleSignIn.attemptLightweightAuthentication(
        reportAllExceptions: true,
      );
      final account = pending == null
          ? null
          : await pending.timeout(const Duration(seconds: 60));
      if (account == null) {
        return const AccountDeleteReauthResult.failure(
          AccountDeleteReauthFailureReason.failed,
        );
      }
      final idToken = account.authentication.idToken;
      if (idToken == null || idToken.trim().isEmpty) {
        return const AccountDeleteReauthResult.failure(
          AccountDeleteReauthFailureReason.failed,
        );
      }
      final credential = GoogleAuthProvider.credential(idToken: idToken);
      await user.reauthenticateWithCredential(credential);
      return const AccountDeleteReauthResult.success();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return const AccountDeleteReauthResult.failure(
          AccountDeleteReauthFailureReason.cancelledByUser,
        );
      }
      return const AccountDeleteReauthResult.failure(
        AccountDeleteReauthFailureReason.failed,
      );
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-mismatch' || e.code == 'invalid-credential') {
        return const AccountDeleteReauthResult.failure(
          AccountDeleteReauthFailureReason.accountMismatch,
        );
      }
      return const AccountDeleteReauthResult.failure(
        AccountDeleteReauthFailureReason.failed,
      );
    } catch (_) {
      return const AccountDeleteReauthResult.failure(
        AccountDeleteReauthFailureReason.failed,
      );
    }
  }

  /// The one and only destructive Firestore write. Must only be called
  /// after a successful [performGoogleReauth] and a passing
  /// [checkEligibility]. Never call this twice for the same delete attempt
  /// — if [deleteAuthAccount] fails afterwards, retry that step only.
  static Future<void> runDeleteBatch({
    required String householdId,
    required String uid,
  }) async {
    final firestore = FirebaseFirestore.instance;
    final batch = firestore.batch();

    batch.update(firestore.doc('households/$householdId'), {
      'isReadOnly': true,
      'readOnlyAt': FieldValue.serverTimestamp(),
      'readOnlyReason': 'memberDeletedAccount',
      'readOnlyBy': uid,
    });
    batch.delete(firestore.doc('households/$householdId/members/$uid'));
    batch.update(firestore.doc('users/$uid'), {
      'email': null,
      'photoUrl': null,
      'displayName': null,
      'profileName': null,
      'householdId': null,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    await batch.commit();
  }

  /// Destructive Firestore batch for the activeSolo delete flow. Must only be
  /// called after a successful [performGoogleReauth] and a passing
  /// [checkActiveSoloEligibility]. Never call twice for the same delete
  /// attempt — if [deleteAuthAccount] fails afterwards, retry that step only.
  static Future<void> runActiveSoloDeleteBatch({
    required String householdId,
    required String uid,
  }) async {
    final firestore = FirebaseFirestore.instance;
    final batch = firestore.batch();

    batch.update(firestore.doc('households/$householdId'), {
      'isReadOnly': true,
      'readOnlyAt': FieldValue.serverTimestamp(),
      'readOnlyReason': 'soloMemberDeletedAccount',
      'readOnlyBy': uid,
    });
    batch.delete(firestore.doc('households/$householdId/members/$uid'));
    batch.update(firestore.doc('users/$uid'), {
      'email': null,
      'photoUrl': null,
      'displayName': null,
      'profileName': null,
      'householdId': null,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    await batch.commit();
  }

  /// Destructive Firestore batch for the readOnly delete flow (Fase 3d).
  /// Must only be called after a successful [performGoogleReauth] and a
  /// passing [checkReadOnlyEligibility]. Never call twice for the same
  /// delete attempt — if [deleteAuthAccount] fails afterwards, retry that
  /// step only.
  ///
  /// Deliberately does NOT touch the household root document or any of its
  /// subcollections: for a household that is already read-only, this is a
  /// self-only account/membership delete, not a full administration
  /// cleanup. That full cleanup is out of scope for Fase 3 (see the file
  /// header of `account_delete_info_page.dart`).
  static Future<void> runReadOnlyDeleteBatch({
    required String householdId,
    required String uid,
  }) async {
    final firestore = FirebaseFirestore.instance;
    final batch = firestore.batch();

    batch.delete(firestore.doc('households/$householdId/members/$uid'));
    batch.update(firestore.doc('users/$uid'), {
      'email': null,
      'photoUrl': null,
      'displayName': null,
      'profileName': null,
      'householdId': null,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    await batch.commit();
  }

  /// Minimizes the standalone user doc for the noHousehold delete flow.
  /// Must only be called after a successful [performGoogleReauth] and a
  /// passing [checkNoHouseholdEligibility]. Never call twice for the same
  /// delete attempt — if [deleteAuthAccount] fails afterwards, retry that
  /// step only.
  static Future<void> minimizeStandaloneUserDoc({required String uid}) async {
    await FirebaseFirestore.instance.doc('users/$uid').update({
      'email': null,
      'photoUrl': null,
      'displayName': null,
      'profileName': null,
      'householdId': null,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Only call after [runDeleteBatch], [runActiveSoloDeleteBatch],
  /// [runReadOnlyDeleteBatch], or [minimizeStandaloneUserDoc] has already
  /// succeeded.
  static Future<void> deleteAuthAccount() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('not-signed-in');
    }
    await user.delete();
  }

  /// Maps a raised exception (Firestore/Auth) to inline, non-snackbar Dutch
  /// copy. Never throws.
  static String messageForException(Object error, {required String fallback}) {
    try {
      if (error is FirebaseAuthException) {
        if (error.code == 'requires-recent-login') {
          return accountDeleteErrorGoogleFailed;
        }
        if (error.code == 'network-request-failed') {
          return accountDeleteErrorNetwork;
        }
      }
      if (error is FirebaseException) {
        final code = error.code;
        if (code == 'permission-denied' || code.endsWith('/permission-denied')) {
          return accountDeleteErrorPermissionDenied;
        }
        if (code == 'unavailable' || code == 'network-request-failed') {
          return accountDeleteErrorNetwork;
        }
      }
    } catch (_) {
      // Mapper must not throw.
    }
    return fallback;
  }
}
