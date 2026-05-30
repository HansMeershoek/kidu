import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_button/sign_in_button.dart';

import 'firebase_options.dart';
import 'formatting/relative_time_nl.dart';
import 'privacy/reopen_lock_gate.dart';
import 'privacy/reopen_lock_service.dart';
import 'split/household_split_settings_page.dart';
import 'split/household_split_settings_repository.dart';
import 'split/parent_split.dart';
import 'ui/kidu_styles.dart';

// ------------------------------------------------------------
// Color/alpha helpers (single-file)
// ------------------------------------------------------------
// Common semantic opacities used across the UI.
const double a06 = 0.06;
const double a32 = 0.32;
const double a40 = 0.40;
const double a45 = 0.45;
const double a50 = 0.50;
const double a55 = 0.55;
const double a58 = 0.58;
const double a60 = 0.60;
const double a62 = 0.62;
const double a68 = 0.68;
const double a70 = 0.70;
const double a80 = 0.80;
const double a84 = 0.84;
const double a85 = 0.85;

/// Product UI limit for expense titles; stays below the Firestore rules cap.
const int _kAddExpenseTitleMaxLength = 60;

/// Grace period na aanmaken: correcties zonder reden en zonder audit
/// (`amountEdits` / `expenseChanges`).
const Duration _expenseAmountCorrectionWindow = Duration(minutes: 15);

/// Whether [createdAt] falls within the post-creation correction window as of [now].
///
/// Returns `false` when [createdAt] is null, in the future relative to [now], or
/// when more than [_expenseAmountCorrectionWindow] has elapsed ([`<=`] at exact 15m).
bool _isWithinExpenseAmountCorrectionWindow(DateTime? createdAt, DateTime now) {
  if (createdAt == null) return false;
  if (createdAt.isAfter(now)) return false;
  return now.difference(createdAt) <= _expenseAmountCorrectionWindow;
}

/// Firestore payload for [`expenseChanges`] audit docs from expense edit saves.
///
/// When [priorSplit]/[nextSplit] are omitted, snapshot keys are omitted (solo
/// household or no uitgaveverdeling snapshot on the expense).
Map<String, dynamic> _expenseChangeWriteMap({
  required String uid,
  required String reason,
  String? changeBatchId,
  required List<String> priorChildIds,
  required List<String> nextChildIds,
  ParentSplitSnapshot? priorSplit,
  ParentSplitSnapshot? nextSplit,
}) {
  assert(
    (priorSplit == null && nextSplit == null) ||
        (priorSplit != null && nextSplit != null),
  );
  final m = <String, dynamic>{
    'editedBy': uid,
    'reason': reason,
    'editedAt': FieldValue.serverTimestamp(),
    'priorChildIds': priorChildIds,
    'childIds': nextChildIds,
  };
  if (changeBatchId != null) {
    m['changeBatchId'] = changeBatchId;
  }
  if (priorSplit != null && nextSplit != null) {
    m['priorSplitParticipantUids'] = List<String>.from(
      priorSplit.participantUids,
    );
    m['priorSplit0ShareBps'] = priorSplit.share0Bps;
    m['splitParticipantUids'] = List<String>.from(nextSplit.participantUids);
    m['split0ShareBps'] = nextSplit.share0Bps;
  }
  return m;
}

// ── Audit read/merge helpers (Logboek Wijzigingen + detailgeschiedenis) ───

List<String> _readAuditStringList(dynamic value) {
  if (value is! List) return const <String>[];
  return value.whereType<String>().toList(growable: false);
}

int? _readAuditNullableInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

DateTime? _readAuditEditedAt(Map<String, dynamic> data) {
  final raw = data['editedAt'];
  if (raw is Timestamp) return raw.toDate().toLocal();
  if (raw is DateTime) return raw.toLocal();
  return null;
}

String? _nonEmptyChangeBatchId(Map<String, dynamic> data) {
  final id = (data['changeBatchId'] as String?)?.trim();
  if (id == null || id.isEmpty) return null;
  return id;
}

bool _auditChildIdsEqual(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  return a.toSet().containsAll(b);
}

bool _auditChildIdsChanged(Map<String, dynamic> expenseChangeData) {
  final prior = _readAuditStringList(expenseChangeData['priorChildIds']);
  final next = _readAuditStringList(expenseChangeData['childIds']);
  return !_auditChildIdsEqual(prior, next);
}

bool _auditSplitChanged(Map<String, dynamic> expenseChangeData) {
  if (!expenseChangeData.containsKey('priorSplitParticipantUids')) {
    return false;
  }
  final priorUids = _readAuditStringList(
    expenseChangeData['priorSplitParticipantUids'],
  );
  final nextUids = _readAuditStringList(
    expenseChangeData['splitParticipantUids'],
  );
  final priorBps = _readAuditNullableInt(
    expenseChangeData['priorSplit0ShareBps'],
  );
  final nextBps = _readAuditNullableInt(expenseChangeData['split0ShareBps']);
  if (priorUids.length != nextUids.length) return true;
  for (var i = 0; i < priorUids.length; i++) {
    if (priorUids[i] != nextUids[i]) return true;
  }
  return priorBps != nextBps;
}

/// Snapshotvelden uit een [`expenseChanges`] auditdoc (detailgeschiedenis).
({
  List<String> auditPriorChildIds,
  List<String> auditChildIds,
  List<String>? auditPriorSplitParticipantUids,
  int? auditPriorSplit0ShareBps,
  List<String>? auditSplitParticipantUids,
  int? auditSplit0ShareBps,
})
_auditSnapshotFieldsFromExpenseChange(Map<String, dynamic> h) {
  return (
    auditPriorChildIds: _readAuditStringList(h['priorChildIds']),
    auditChildIds: _readAuditStringList(h['childIds']),
    auditPriorSplitParticipantUids: h.containsKey('priorSplitParticipantUids')
        ? _readAuditStringList(h['priorSplitParticipantUids'])
        : null,
    auditPriorSplit0ShareBps: _readAuditNullableInt(h['priorSplit0ShareBps']),
    auditSplitParticipantUids: h.containsKey('splitParticipantUids')
        ? _readAuditStringList(h['splitParticipantUids'])
        : null,
    auditSplit0ShareBps: _readAuditNullableInt(h['split0ShareBps']),
  );
}

/// Merged audit registration for one save-actie (Logboek + detailgeschiedenis).
class _AuditRegistration {
  const _AuditRegistration({
    required this.registrationKey,
    required this.editedBy,
    required this.editedAt,
    required this.reason,
    required this.hasAmountChange,
    required this.hasChildrenChange,
    required this.hasSplitChange,
    this.changeBatchId,
    this.fromAmountCents,
    this.toAmountCents,
    this.auditPriorChildIds,
    this.auditChildIds,
    this.auditPriorSplitParticipantUids,
    this.auditPriorSplit0ShareBps,
    this.auditSplitParticipantUids,
    this.auditSplit0ShareBps,
  });

  final String registrationKey;
  final String? changeBatchId;
  final String editedBy;
  final DateTime editedAt;
  final String reason;
  final bool hasAmountChange;
  final bool hasChildrenChange;
  final bool hasSplitChange;
  final int? fromAmountCents;
  final int? toAmountCents;
  final List<String>? auditPriorChildIds;
  final List<String>? auditChildIds;
  final List<String>? auditPriorSplitParticipantUids;
  final int? auditPriorSplit0ShareBps;
  final List<String>? auditSplitParticipantUids;
  final int? auditSplit0ShareBps;
}

String _mergeAuditReason({
  required String amountReason,
  required String expenseChangeReason,
  required String registrationKey,
}) {
  if (amountReason.isNotEmpty) {
    if (expenseChangeReason.isNotEmpty && expenseChangeReason != amountReason) {
      debugPrint(
        'Audit reason mismatch for $registrationKey: '
        'amountEdits vs expenseChanges',
      );
    }
    return amountReason;
  }
  return expenseChangeReason;
}

List<_AuditRegistration> _mergeAuditRegistrations({
  required List<QueryDocumentSnapshot<Map<String, dynamic>>> amountEditDocs,
  required List<QueryDocumentSnapshot<Map<String, dynamic>>> expenseChangeDocs,
}) {
  final amountByBatch = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
  final changeByBatch = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
  final standaloneAmount = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
  final standaloneChange = <QueryDocumentSnapshot<Map<String, dynamic>>>[];

  for (final doc in amountEditDocs) {
    final batchId = _nonEmptyChangeBatchId(doc.data());
    if (batchId != null) {
      amountByBatch[batchId] = doc;
    } else {
      standaloneAmount.add(doc);
    }
  }

  for (final doc in expenseChangeDocs) {
    final data = doc.data();
    if (!_auditChildIdsChanged(data) && !_auditSplitChanged(data)) {
      continue;
    }
    final batchId = _nonEmptyChangeBatchId(data);
    if (batchId != null) {
      changeByBatch[batchId] = doc;
    } else {
      standaloneChange.add(doc);
    }
  }

  final registrations = <_AuditRegistration>[];

  _AuditRegistration? registrationFromAmountDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc, {
    required bool hasChildrenChange,
    required bool hasSplitChange,
    required String registrationKey,
    String? changeBatchId,
    String expenseChangeReason = '',
    Map<String, dynamic>? expenseChangeData,
  }) {
    final h = doc.data();
    final editedAt = _readAuditEditedAt(h);
    if (editedAt == null) return null;
    final amountReason = (h['reason'] as String?)?.trim() ?? '';
    final snapshot = expenseChangeData != null
        ? _auditSnapshotFieldsFromExpenseChange(expenseChangeData)
        : null;
    return _AuditRegistration(
      registrationKey: registrationKey,
      changeBatchId: changeBatchId,
      editedBy: (h['editedBy'] as String?)?.trim() ?? '',
      editedAt: editedAt,
      reason: _mergeAuditReason(
        amountReason: amountReason,
        expenseChangeReason: expenseChangeReason,
        registrationKey: registrationKey,
      ),
      hasAmountChange: true,
      hasChildrenChange: hasChildrenChange,
      hasSplitChange: hasSplitChange,
      fromAmountCents: (h['fromAmountCents'] as num?)?.toInt(),
      toAmountCents: (h['toAmountCents'] as num?)?.toInt(),
      auditPriorChildIds: snapshot?.auditPriorChildIds,
      auditChildIds: snapshot?.auditChildIds,
      auditPriorSplitParticipantUids: snapshot?.auditPriorSplitParticipantUids,
      auditPriorSplit0ShareBps: snapshot?.auditPriorSplit0ShareBps,
      auditSplitParticipantUids: snapshot?.auditSplitParticipantUids,
      auditSplit0ShareBps: snapshot?.auditSplit0ShareBps,
    );
  }

  _AuditRegistration? registrationFromExpenseChangeDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc, {
    required String registrationKey,
    String? changeBatchId,
    String amountReason = '',
  }) {
    final h = doc.data();
    final editedAt = _readAuditEditedAt(h);
    if (editedAt == null) return null;
    final hasChildren = _auditChildIdsChanged(h);
    final hasSplit = _auditSplitChanged(h);
    if (!hasChildren && !hasSplit) return null;
    final changeReason = (h['reason'] as String?)?.trim() ?? '';
    final snapshot = _auditSnapshotFieldsFromExpenseChange(h);
    return _AuditRegistration(
      registrationKey: registrationKey,
      changeBatchId: changeBatchId,
      editedBy: (h['editedBy'] as String?)?.trim() ?? '',
      editedAt: editedAt,
      reason: _mergeAuditReason(
        amountReason: amountReason,
        expenseChangeReason: changeReason,
        registrationKey: registrationKey,
      ),
      hasAmountChange: false,
      hasChildrenChange: hasChildren,
      hasSplitChange: hasSplit,
      auditPriorChildIds: snapshot.auditPriorChildIds,
      auditChildIds: snapshot.auditChildIds,
      auditPriorSplitParticipantUids: snapshot.auditPriorSplitParticipantUids,
      auditPriorSplit0ShareBps: snapshot.auditPriorSplit0ShareBps,
      auditSplitParticipantUids: snapshot.auditSplitParticipantUids,
      auditSplit0ShareBps: snapshot.auditSplit0ShareBps,
    );
  }

  final batchIds = <String>{...amountByBatch.keys, ...changeByBatch.keys};
  for (final batchId in batchIds) {
    final amountDoc = amountByBatch[batchId];
    final changeDoc = changeByBatch[batchId];
    if (amountDoc != null && changeDoc != null) {
      final changeData = changeDoc.data();
      final reg = registrationFromAmountDoc(
        amountDoc,
        hasChildrenChange: _auditChildIdsChanged(changeData),
        hasSplitChange: _auditSplitChanged(changeData),
        registrationKey: batchId,
        changeBatchId: batchId,
        expenseChangeReason: (changeData['reason'] as String?)?.trim() ?? '',
        expenseChangeData: changeData,
      );
      if (reg != null) registrations.add(reg);
    } else if (amountDoc != null) {
      final reg = registrationFromAmountDoc(
        amountDoc,
        hasChildrenChange: false,
        hasSplitChange: false,
        registrationKey: batchId,
        changeBatchId: batchId,
      );
      if (reg != null) registrations.add(reg);
    } else if (changeDoc != null) {
      final reg = registrationFromExpenseChangeDoc(
        changeDoc,
        registrationKey: batchId,
        changeBatchId: batchId,
      );
      if (reg != null) registrations.add(reg);
    }
  }

  for (final doc in standaloneAmount) {
    final reg = registrationFromAmountDoc(
      doc,
      hasChildrenChange: false,
      hasSplitChange: false,
      registrationKey: 'amountEdits/${doc.id}',
    );
    if (reg != null) registrations.add(reg);
  }

  for (final doc in standaloneChange) {
    final reg = registrationFromExpenseChangeDoc(
      doc,
      registrationKey: 'expenseChanges/${doc.id}',
    );
    if (reg != null) registrations.add(reg);
  }

  registrations.sort((a, b) => b.editedAt.compareTo(a.editedAt));
  return registrations;
}

String _auditChangeTypeLabel({
  required bool hasAmountChange,
  required bool hasChildrenChange,
  required bool hasSplitChange,
}) {
  if (hasAmountChange && hasChildrenChange && hasSplitChange) {
    return 'Bedrag, kinderen en verdeling gewijzigd';
  }
  if (hasAmountChange && hasChildrenChange) {
    return 'Bedrag en kinderen gewijzigd';
  }
  if (hasAmountChange && hasSplitChange) {
    return 'Bedrag en verdeling gewijzigd';
  }
  if (hasChildrenChange && hasSplitChange) {
    return 'Kinderen en verdeling gewijzigd';
  }
  if (hasAmountChange) return 'Bedrag gewijzigd';
  if (hasChildrenChange) return 'Kinderen gewijzigd';
  if (hasSplitChange) return 'Verdeling gewijzigd';
  return 'Gewijzigd';
}

Map<String, String> _childNameByIdFromChildrenSnap(
  Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
) {
  final map = <String, String>{};
  for (final doc in docs) {
    final name = (doc.data()['name'] as String?)?.trim();
    map[doc.id] = (name != null && name.isNotEmpty) ? name : 'Onbekend kind';
  }
  return map;
}

Future<Map<String, String>> _loadHouseholdChildNameMap(
  String householdId,
) async {
  try {
    final snap = await FirebaseFirestore.instance
        .collection('households/$householdId/children')
        .get();
    return _childNameByIdFromChildrenSnap(snap.docs);
  } catch (_) {
    return const <String, String>{};
  }
}

Set<String> _auditRegistrationChildIds(_AuditRegistration registration) {
  if (!registration.hasChildrenChange) return const {};
  return <String>{
    ...?registration.auditPriorChildIds,
    ...?registration.auditChildIds,
  };
}

bool _auditChildNamesReadyForRegistration(
  _AuditRegistration registration, {
  required Map<String, String> mergedChildNameById,
  required bool householdChildMapLoaded,
}) {
  if (!registration.hasChildrenChange) return true;
  final ids = _auditRegistrationChildIds(registration);
  if (ids.isEmpty) return true;
  if (householdChildMapLoaded) return true;
  return ids.every(mergedChildNameById.containsKey);
}

String _auditChildNamesLine(List<String> ids, Map<String, String> nameById) {
  if (ids.isEmpty) return 'Geen kinderen';
  return ids.map((id) => nameById[id] ?? 'Onbekend kind').join(', ');
}

ParentSplitSnapshot? _auditSplitSnapshotFromRegistration(
  _AuditRegistration registration, {
  required bool prior,
}) {
  final uids = prior
      ? registration.auditPriorSplitParticipantUids
      : registration.auditSplitParticipantUids;
  final bps = prior
      ? registration.auditPriorSplit0ShareBps
      : registration.auditSplit0ShareBps;
  if (uids == null || bps == null) return null;
  return ParentSplitSnapshot.tryCreate(participantUids: uids, share0Bps: bps);
}

String _auditHistoryDetailDateLine(
  _AuditRegistration registration,
  String Function(DateTime?) formatDateTime,
) {
  return formatDateTime(registration.editedAt);
}

String? _auditHistoryAmountValueLine(
  _AuditRegistration registration, {
  required bool usePrefix,
  required String Function(int) formatEur,
}) {
  if (!registration.hasAmountChange) return null;
  final fromC = registration.fromAmountCents ?? 0;
  final toC = registration.toAmountCents ?? 0;
  final core = '${formatEur(fromC)} → ${formatEur(toC)}';
  return usePrefix ? 'Bedrag: $core' : core;
}

String? _auditHistoryChildrenValueLine(
  _AuditRegistration registration, {
  required bool usePrefix,
  required bool childNamesLoaded,
  required Map<String, String>? childNameById,
}) {
  if (!registration.hasChildrenChange) return null;
  if (!childNamesLoaded) {
    return 'Kinderen: laden…';
  }
  final nameById = childNameById!;
  final priorIds = registration.auditPriorChildIds ?? const <String>[];
  final nextIds = registration.auditChildIds ?? const <String>[];
  final core =
      '${_auditChildNamesLine(priorIds, nameById)} → '
      '${_auditChildNamesLine(nextIds, nameById)}';
  return usePrefix ? 'Kinderen: $core' : core;
}

String? _auditHistorySplitValueLine(
  _AuditRegistration registration, {
  required bool usePrefix,
  required String? viewerUid,
}) {
  if (!registration.hasSplitChange) return null;
  final prior = _auditSplitSnapshotFromRegistration(registration, prior: true);
  final next = _auditSplitSnapshotFromRegistration(registration, prior: false);
  if (prior == null || next == null) {
    return usePrefix ? 'Verdeling: Verdeling aangepast' : 'Verdeling aangepast';
  }
  final priorLabel = _formatParentSplitCompact(prior, viewerUid);
  final nextLabel = _formatParentSplitCompact(next, viewerUid);
  final core = '$priorLabel → $nextLabel';
  return usePrefix ? 'Verdeling: $core' : core;
}

int _auditRegistrationChangeTypeCount(_AuditRegistration registration) {
  var n = 0;
  if (registration.hasAmountChange) n++;
  if (registration.hasChildrenChange) n++;
  if (registration.hasSplitChange) n++;
  return n;
}

List<String> _auditHistoryValueLines(
  _AuditRegistration registration, {
  required Map<String, String> mergedChildNameById,
  required bool householdChildMapLoaded,
  required String? viewerUid,
  required String Function(int) formatEur,
}) {
  final usePrefix = _auditRegistrationChangeTypeCount(registration) > 1;
  final lines = <String>[];
  final amountLine = _auditHistoryAmountValueLine(
    registration,
    usePrefix: usePrefix,
    formatEur: formatEur,
  );
  if (amountLine != null) lines.add(amountLine);
  final childrenLine = _auditHistoryChildrenValueLine(
    registration,
    usePrefix: usePrefix,
    childNamesLoaded: _auditChildNamesReadyForRegistration(
      registration,
      mergedChildNameById: mergedChildNameById,
      householdChildMapLoaded: householdChildMapLoaded,
    ),
    childNameById: mergedChildNameById,
  );
  if (childrenLine != null) lines.add(childrenLine);
  final splitLine = _auditHistorySplitValueLine(
    registration,
    usePrefix: usePrefix,
    viewerUid: viewerUid,
  );
  if (splitLine != null) lines.add(splitLine);
  return lines;
}

List<Widget> _buildAuditHistoryRegistrationTiles({
  required BuildContext context,
  required List<_AuditRegistration> registrations,
  required Map<String, String> mergedChildNameById,
  required bool householdChildMapLoaded,
  required String? viewerUid,
  required String Function(int) formatEur,
  required String Function(DateTime?) formatDateTime,
}) {
  final headlineStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
    color: onSurface(context, a68),
    height: 1.35,
    fontWeight: FontWeight.w600,
  );
  final valueTextStyle = Theme.of(
    context,
  ).textTheme.bodySmall?.copyWith(color: onSurface(context, a68), height: 1.35);

  return registrations.map((reg) {
    final typeLabel = _auditChangeTypeLabel(
      hasAmountChange: reg.hasAmountChange,
      hasChildrenChange: reg.hasChildrenChange,
      hasSplitChange: reg.hasSplitChange,
    );
    final valueLines = _auditHistoryValueLines(
      reg,
      mergedChildNameById: mergedChildNameById,
      householdChildMapLoaded: householdChildMapLoaded,
      viewerUid: viewerUid,
      formatEur: formatEur,
    );
    final dateLine = _auditHistoryDetailDateLine(reg, formatDateTime);
    final reason = reg.reason.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(typeLabel, style: headlineStyle),
          ...valueLines.map(
            (line) => Text(
              line,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: valueTextStyle,
            ),
          ),
          Text(dateLine, style: valueTextStyle),
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              reason,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(height: 1.35),
            ),
          ],
        ],
      ),
    );
  }).toList();
}

class _ExpenseAuditHistoryPayload {
  const _ExpenseAuditHistoryPayload({
    required this.registrations,
    required this.mergedChildNameById,
    required this.householdChildMapLoaded,
  });

  final List<_AuditRegistration> registrations;
  final Map<String, String> mergedChildNameById;
  final bool householdChildMapLoaded;
}

Future<_ExpenseAuditHistoryPayload> _loadExpenseAuditHistoryPayload({
  required String householdId,
  required String expenseId,
  Map<String, String>? initialChildNameById,
}) async {
  final amountSnap = await FirebaseFirestore.instance
      .collection('households/$householdId/expenses/$expenseId/amountEdits')
      .orderBy('editedAt', descending: true)
      .get();
  final changeSnap = await FirebaseFirestore.instance
      .collection('households/$householdId/expenses/$expenseId/expenseChanges')
      .orderBy('editedAt', descending: true)
      .get();
  final childMap = await _loadHouseholdChildNameMap(householdId);
  final registrations = _mergeAuditRegistrations(
    amountEditDocs: amountSnap.docs,
    expenseChangeDocs: changeSnap.docs,
  );
  return _ExpenseAuditHistoryPayload(
    registrations: registrations,
    mergedChildNameById: <String, String>{
      ...?initialChildNameById,
      ...childMap,
    },
    householdChildMapLoaded: true,
  );
}

class _ExpenseAuditHistorySheetContent extends StatelessWidget {
  const _ExpenseAuditHistorySheetContent({
    required this.payload,
    required this.viewerUid,
    required this.maxScrollHeight,
  });

  final _ExpenseAuditHistoryPayload payload;
  final String viewerUid;
  final double maxScrollHeight;

  @override
  Widget build(BuildContext context) {
    if (payload.registrations.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          'Nog geen wijzigingen',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: onSurface(context, a60),
            height: 1.35,
          ),
        ),
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxScrollHeight),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _buildAuditHistoryRegistrationTiles(
            context: context,
            registrations: payload.registrations,
            mergedChildNameById: payload.mergedChildNameById,
            householdChildMapLoaded: payload.householdChildMapLoaded,
            viewerUid: viewerUid,
            formatEur: _ExpenseDetailPage._formatEur,
            formatDateTime: _ExpenseDetailPage._formatDateTime,
          ),
        ),
      ),
    );
  }
}

String _expenseDocWijzigLogbookSignature(
  String expenseId,
  Map<String, dynamic> expenseData,
) {
  final title = (expenseData['title'] as String?)?.trim() ?? '(zonder naam)';
  final amountCents = (expenseData['amountCents'] as num?)?.toInt() ?? 0;
  final childIds = _readAuditStringList(expenseData['childIds'])..sort();
  final split = ParentSplitSnapshot.tryReadFromExpense(expenseData);
  final splitSig = split == null
      ? ''
      : '${split.participantUids.join(',')}:${split.share0Bps}';
  return '$expenseId:$amountCents:$title:${childIds.join(',')}:$splitSig';
}

/// Calm green for success overlays (e.g. join/connect confirmation).
const Color _kSuccessGreen = Color(0xFF2E7D32);

/// Lightweight value-object used by the "Voor wie?" feature.
class _ChildItem {
  const _ChildItem({required this.id, required this.name});
  final String id;
  final String name;
}

class _DashboardSecondaryMetadata {
  const _DashboardSecondaryMetadata({
    required this.otherName,
    required this.notesByExpenseId,
  });

  final String otherName;
  final Map<String, String> notesByExpenseId;
}

class _CreatedExpenseResult {
  const _CreatedExpenseResult({
    required this.expenseId,
    this.noteForRowFallback,
    this.successSnackBarMessage,
  });

  final String expenseId;
  final String? noteForRowFallback;
  final String? successSnackBarMessage;
}

class _PendingExpenseRowFallback {
  const _PendingExpenseRowFallback({
    required this.expenseId,
    required this.savedAt,
    this.note,
  });

  final String expenseId;
  final DateTime savedAt;
  final String? note;
}

Color onSurface(BuildContext context, double alpha) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: alpha);

Color outlineV(BuildContext context, double alpha) =>
    Theme.of(context).colorScheme.outlineVariant.withValues(alpha: alpha);

ThemeData buildKiduTheme() {
  // Keep it warm + premium, no purple defaults.
  const appBg = Color(0xFFF7F6F4);
  const seed = Color(0xFF2F3E46); // warm/dark slate

  final cs = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.light,
  ).copyWith(surface: Colors.white, surfaceTint: Colors.transparent);

  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    scaffoldBackgroundColor: appBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: appBg,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Color(0xFF2F3E46),
    ),
  );
}

/// Maps exceptions to user-friendly Dutch messages. Does not throw.
String mapUserFacingError(
  Object e, {
  String fallback = 'Er ging iets mis. Probeer opnieuw.',
}) {
  try {
    if (e is FirebaseException) {
      final code = e.code;
      if (code == 'permission-denied' ||
          (code.endsWith('/permission-denied'))) {
        return 'Je hebt hiervoor geen toegang.';
      }
      if (code == 'unavailable') {
        return 'Geen verbinding met server. Probeer opnieuw.';
      }
      if (code == 'network-request-failed') {
        return 'Netwerkfout. Controleer je verbinding.';
      }
      if (code == 'failed-precondition') {
        return 'Actie kan nu niet worden uitgevoerd.';
      }
    }
    if (e is StateError) {
      final msg = e.message;
      if (msg.trim().isNotEmpty) {
        return msg.trim();
      }
    }
  } catch (_) {
    // Mapper must not throw
  }
  return fallback;
}

/// Typed result for the private note edit dialog. No Firestore in dialog.
sealed class PrivateNoteDialogResult {}

class PrivateNoteDialogCancelled extends PrivateNoteDialogResult {}

class PrivateNoteDialogDelete extends PrivateNoteDialogResult {}

class PrivateNoteDialogSave extends PrivateNoteDialogResult {
  PrivateNoteDialogSave(this.note, {List<String>? sharedWithUids})
    : sharedWithUids = List<String>.unmodifiable(
        sharedWithUids ?? const <String>[],
      );

  final String note;
  final List<String> sharedWithUids;
}

/// Firestore payloads may omit [`sharedWithUids`] entirely (private-only).
List<String> _parsePrivateNoteSharedWithUids(Map<String, dynamic>? data) {
  if (data == null) return const [];
  final raw = data['sharedWithUids'];
  if (raw is! List) return const [];
  return raw
      .whereType<String>()
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
}

class _PrivateNoteShareUiContext {
  const _PrivateNoteShareUiContext({this.coParentUid});

  /// Set only when exactly one other household member exists (single co-parent).
  final String? coParentUid;
}

Future<_PrivateNoteShareUiContext> _resolvePrivateNoteShareUiContext(
  String householdId,
) async {
  final trimmed = householdId.trim();
  if (trimmed.isEmpty) {
    return const _PrivateNoteShareUiContext();
  }
  final uid = FirebaseAuth.instance.currentUser?.uid.trim();
  if (uid == null || uid.isEmpty) {
    return const _PrivateNoteShareUiContext();
  }
  try {
    final snap = await FirebaseFirestore.instance
        .collection('households/$trimmed/members')
        .get();
    final others = snap.docs
        .map((d) => d.id.trim())
        .where((id) => id.isNotEmpty && id != uid)
        .toSet()
        .toList(growable: false);
    if (others.length == 1) {
      return _PrivateNoteShareUiContext(coParentUid: others.single);
    }
    return const _PrivateNoteShareUiContext();
  } catch (_) {
    return const _PrivateNoteShareUiContext();
  }
}

class _PrivateNoteDialogContent extends StatefulWidget {
  const _PrivateNoteDialogContent({
    required this.initialNote,
    required this.hasInitialNote,
    required this.initialSharedWithUids,
    this.coParentUid,
  });

  final String initialNote;
  final bool hasInitialNote;
  final List<String> initialSharedWithUids;
  final String? coParentUid;

  @override
  State<_PrivateNoteDialogContent> createState() =>
      _PrivateNoteDialogContentState();
}

class _PrivateNoteDialogContentState extends State<_PrivateNoteDialogContent> {
  late String _draftNote;
  late bool _shareWithCoParent;
  bool _didPop = false;

  void _safePop(PrivateNoteDialogResult result) {
    if (_didPop) return;
    _didPop = true;
    Navigator.of(context, rootNavigator: false).pop(result);
  }

  @override
  void initState() {
    super.initState();
    _draftNote = widget.initialNote;
    final co = widget.coParentUid?.trim();
    _shareWithCoParent =
        co != null &&
        co.isNotEmpty &&
        widget.initialSharedWithUids.any((id) => id.trim() == co);
  }

  List<String> _resolvedSharedWithUidsForSave() {
    final co = widget.coParentUid?.trim();
    if (!_shareWithCoParent ||
        co == null ||
        co.isEmpty ||
        _draftNote.trim().isEmpty) {
      return const [];
    }
    return [co];
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = (screenW - 80.0).clamp(280.0, 420.0);
    final footerTextButtonStyle = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxH = constraints.maxHeight * 0.85;
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: dialogW,
                maxHeight: maxH,
              ),
              child: SizedBox(
                width: dialogW,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      kiduActionDialogTitle(
                        context,
                        widget.hasInitialNote
                            ? 'Notitie bewerken'
                            : 'Notitie toevoegen',
                      ),
                      const SizedBox(height: 8),
                      Flexible(
                        child: SingleChildScrollView(
                          child: TextFormField(
                            initialValue: widget.initialNote,
                            autofocus: true,
                            maxLength: 180,
                            minLines: 1,
                            maxLines: 8,
                            textCapitalization: TextCapitalization.sentences,
                            textInputAction: TextInputAction.done,
                            buildCounter:
                                (
                                  context, {
                                  required int currentLength,
                                  required bool isFocused,
                                  required int? maxLength,
                                }) => null,
                            decoration: kiduCompactInputDecoration(
                              labelText: 'Notitie',
                            ).copyWith(
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.always,
                              border: const OutlineInputBorder(),
                            ),
                            onChanged: (v) => setState(() {
                              _draftNote = v;
                              if (v.trim().isEmpty) {
                                _shareWithCoParent = false;
                              }
                            }),
                            onFieldSubmitted: (_) =>
                                FocusScope.of(context).unfocus(),
                          ),
                        ),
                      ),
                    if (widget.coParentUid != null &&
                        widget.coParentUid!.trim().isNotEmpty)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Notitie delen',
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                        value:
                            _shareWithCoParent && _draftNote.trim().isNotEmpty,
                        onChanged: _draftNote.trim().isEmpty
                            ? null
                            : (v) => setState(() => _shareWithCoParent = v),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (widget.hasInitialNote)
                          TextButton(
                            style: footerTextButtonStyle.copyWith(
                              foregroundColor: WidgetStatePropertyAll(
                                Theme.of(context).colorScheme.error
                                    .withValues(alpha: 0.85),
                              ),
                            ),
                            onPressed: () =>
                                _safePop(PrivateNoteDialogDelete()),
                            child: const Text('Verwijderen'),
                          ),
                        const Spacer(),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              style: footerTextButtonStyle,
                              onPressed: () =>
                                  _safePop(PrivateNoteDialogCancelled()),
                              child: const Text('Annuleren'),
                            ),
                            FilledButton(
                              style: kiduDialogPrimaryButtonStyle(context),
                              onPressed: () {
                                final note = _draftNote.trim();
                                if (note.isEmpty) {
                                  if (widget.hasInitialNote) {
                                    _safePop(PrivateNoteDialogDelete());
                                  } else {
                                    _safePop(PrivateNoteDialogCancelled());
                                  }
                                } else {
                                  _safePop(
                                    PrivateNoteDialogSave(
                                      note,
                                      sharedWithUids:
                                          _resolvedSharedWithUidsForSave(),
                                    ),
                                  );
                                }
                              },
                              child: const Text('Opslaan'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            );
          },
        ),
      ),
    );
  }
}

// ── Shared expense-list sorting helpers (used by Dashboard and Logboek) ─────

/// Stabiele client-side sorteer-comparator voor expense-docs.
///
/// Zichtbare recency in Dashboard > `Recente uitgaven` en Logboek >
/// `Uitgaven` leunt op het échte aanmaak-/materialisatiemoment:
///
///  * primair:   `materializedAt ?? createdAt` desc — voor gematerialiseerde
///               recurring-instances is dat het serverside materialisatie-
///               moment, voor handmatige expenses valt dit samen met
///               `createdAt` (= echte schrijfmoment), zodat een net vandaag
///               gematerialiseerde maandelijkse post ook echt bovenaan kan
///               komen en niet wegvalt tegen een handmatige post van
///               eerder vandaag op dezelfde due-datum 00:00,
///  * secundair: `createdAt` desc — breekt ties tussen instances die op
///               dezelfde dag zijn gematerialiseerd en bewaart de
///               natuurlijke due-datum-volgorde,
///  * tertiair:  `doc.id` asc — uiterste stabiele tie-break, deterministisch.
///
/// Puur client-side: geen Firestore-query-aanpassing, geen extra orderBy,
/// geen data-model-wijziging. `materializedAt`/`createdAt`-semantiek zelf
/// wordt hier bewust niet gewijzigd.
int _compareExpenseDocsStable(
  QueryDocumentSnapshot<Map<String, dynamic>> a,
  QueryDocumentSnapshot<Map<String, dynamic>> b,
) {
  final da = a.data();
  final db = b.data();

  final aCreatedAt = da['createdAt'];
  final bCreatedAt = db['createdAt'];
  final aCreatedTs = aCreatedAt is Timestamp ? aCreatedAt : null;
  final bCreatedTs = bCreatedAt is Timestamp ? bCreatedAt : null;

  final aMat = da['materializedAt'];
  final bMat = db['materializedAt'];
  final aMatTs = aMat is Timestamp ? aMat : null;
  final bMatTs = bMat is Timestamp ? bMat : null;

  final aPrimary = aMatTs ?? aCreatedTs;
  final bPrimary = bMatTs ?? bCreatedTs;
  if (aPrimary != null && bPrimary != null) {
    final primary = bPrimary.compareTo(aPrimary);
    if (primary != 0) return primary;
  } else if (aPrimary != null) {
    return -1;
  } else if (bPrimary != null) {
    return 1;
  }

  if (aCreatedTs != null && bCreatedTs != null) {
    final secondary = bCreatedTs.compareTo(aCreatedTs);
    if (secondary != 0) return secondary;
  } else if (aCreatedTs != null) {
    return -1;
  } else if (bCreatedTs != null) {
    return 1;
  }

  return a.id.compareTo(b.id);
}

Timestamp? _expenseActivityTimestamp(Map<String, dynamic> expenseData) {
  return expenseData['materializedAt'] as Timestamp? ??
      expenseData['createdAt'] as Timestamp?;
}

/// Gematerialiseerde uitgave uit een maandelijkse master (`Maandelijkse uitgaven`).
bool _expenseDocIsMaterializedMonthly(Map<String, dynamic> e) =>
    ((e['recurringExpenseId'] as String?)?.trim().isNotEmpty ?? false);

/// Zelfde icoon als Settings > Huishouden > Maandelijkse uitgaven [Icons.event_repeat_outlined].
Widget? _expenseSubtitleWithOptionalMonthlyIcon(
  BuildContext context, {
  required String actorAndDateLine,
  String? noteTrailing,
  required bool isMaterializedMonthly,
}) {
  final style = Theme.of(
    context,
  ).textTheme.bodySmall?.copyWith(color: onSurface(context, a62), height: 1.35);
  final note = noteTrailing?.trim();
  final hasNote = note != null && note.isNotEmpty;
  final base = actorAndDateLine.trim();

  if (!isMaterializedMonthly) {
    final full = hasNote
        ? (base.isEmpty ? note : '$actorAndDateLine · $note')
        : actorAndDateLine;
    if (full.trim().isEmpty) return null;
    return Text(
      full,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }

  final iconSpan = WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Icon(
      Icons.event_repeat_outlined,
      size: 14,
      color: onSurface(context, a50),
    ),
  );

  if (base.isEmpty && hasNote) {
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: note),
          const TextSpan(text: ' · '),
          iconSpan,
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  return Text.rich(
    TextSpan(
      style: style,
      children: [
        TextSpan(text: actorAndDateLine),
        const TextSpan(text: ' · '),
        iconSpan,
        if (hasNote) TextSpan(text: ' · $note'),
      ],
    ),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
}

// ── Shared private-note helpers (used by Dashboard and Logboek) ──────────────

/// Returns true when there is a live server connection for writing.
Future<bool> _checkCanWriteNow() async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return false;
  try {
    await FirebaseFirestore.instance
        .doc('users/$uid')
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 2));
    return true;
  } catch (_) {
    return false;
  }
}

/// Shows the private-note edit dialog and returns a typed result.
/// Pure UI only – no Firestore.
Future<PrivateNoteDialogResult> _showPrivateNoteDialog(
  BuildContext context, {
  required String initialNote,
  required bool hasInitialNote,
  List<String>? initialSharedWithUids,
  String? coParentUid,
}) async {
  final shareList = initialSharedWithUids ?? const <String>[];
  final result = await showDialog<PrivateNoteDialogResult>(
    context: context,
    useRootNavigator: false,
    useSafeArea: true,
    barrierDismissible: false,
    builder: (dialogContext) => Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                final keyboardVisible =
                    MediaQuery.of(dialogContext).viewInsets.bottom > 0;
                if (keyboardVisible) {
                  FocusManager.instance.primaryFocus?.unfocus();
                  return;
                }
                Navigator.of(dialogContext, rootNavigator: false).pop();
              },
              child: const SizedBox.expand(),
            ),
          ),
          _PrivateNoteDialogContent(
            initialNote: initialNote,
            hasInitialNote: hasInitialNote,
            initialSharedWithUids: shareList,
            coParentUid: coParentUid,
          ),
        ],
      ),
    ),
  );
  return result ?? PrivateNoteDialogCancelled();
}

/// Shared note-management flow used by both Dashboard and Logboek.
///
/// Loads the latest note from Firestore, opens the edit dialog, verifies
/// connectivity before writing, persists to Firestore, and shows snackbars on
/// offline-blocking (before write) or persist errors.
/// Returns the committed [PrivateNoteDialogResult] so callers can bust local
/// caches; returns null on cancel, offline block, or error.
Future<PrivateNoteDialogResult?> _doManagePrivateNote(
  BuildContext context, {
  required String householdId,
  required String expenseId,
  required String uid,
}) async {
  try {
    final snap = await FirebaseFirestore.instance
        .doc('households/$householdId/expenses/$expenseId/privateNotes/$uid')
        .get();
    final initialNote = ((snap.data()?['note'] as String?) ?? '').trim();
    final initialShared = _parsePrivateNoteSharedWithUids(snap.data());
    final shareUi = await _resolvePrivateNoteShareUiContext(householdId);

    if (!context.mounted) return null;
    final result = await _showPrivateNoteDialog(
      context,
      initialNote: initialNote,
      hasInitialNote: initialNote.isNotEmpty,
      initialSharedWithUids: initialShared,
      coParentUid: shareUi.coParentUid,
    );

    if (result is PrivateNoteDialogCancelled) return null;
    if (!context.mounted) return null;

    if (!await _checkCanWriteNow()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                'Je bent offline. Notitie is niet gewijzigd. Verbind met internet en probeer opnieuw.',
              ),
            ),
          );
      }
      return null;
    }

    final ref = FirebaseFirestore.instance.doc(
      'households/$householdId/expenses/$expenseId/privateNotes/$uid',
    );
    if (result is PrivateNoteDialogDelete) {
      await ref.delete();
    } else if (result is PrivateNoteDialogSave) {
      await ref.set({
        'note': result.note,
        'updatedAt': FieldValue.serverTimestamp(),
        if (result.sharedWithUids.isNotEmpty)
          'sharedWithUids': result.sharedWithUids,
      });
    }

    return result;
  } catch (e) {
    debugPrint('Note save error: $e');
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              mapUserFacingError(
                e,
                fallback: 'Opslaan mislukt. Probeer opnieuw.',
              ),
            ),
          ),
        );
    }
    return null;
  }
}

/// Creator-only private note for a recurring master; same dialog/write tone as
/// [_doManagePrivateNote], path under `recurringExpenses/{id}/privateNotes`.
Future<PrivateNoteDialogResult?> _doManageRecurringMasterPrivateNote(
  BuildContext context, {
  required String householdId,
  required String masterId,
  required String uid,
}) async {
  try {
    final snap = await FirebaseFirestore.instance
        .doc(
          'households/$householdId/recurringExpenses/$masterId/privateNotes/$uid',
        )
        .get();
    final initialNote = ((snap.data()?['note'] as String?) ?? '').trim();
    final initialShared = _parsePrivateNoteSharedWithUids(snap.data());
    final shareUi = await _resolvePrivateNoteShareUiContext(householdId);

    if (!context.mounted) return null;
    final result = await _showPrivateNoteDialog(
      context,
      initialNote: initialNote,
      hasInitialNote: initialNote.isNotEmpty,
      initialSharedWithUids: initialShared,
      coParentUid: shareUi.coParentUid,
    );

    if (result is PrivateNoteDialogCancelled) return null;
    if (!context.mounted) return null;

    if (!await _checkCanWriteNow()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                'Je bent offline. Notitie is niet gewijzigd. Verbind met internet en probeer opnieuw.',
              ),
            ),
          );
      }
      return null;
    }

    final ref = FirebaseFirestore.instance.doc(
      'households/$householdId/recurringExpenses/$masterId/privateNotes/$uid',
    );
    if (result is PrivateNoteDialogDelete) {
      await ref.delete();
    } else if (result is PrivateNoteDialogSave) {
      await ref.set({
        'note': result.note,
        'updatedAt': FieldValue.serverTimestamp(),
        if (result.sharedWithUids.isNotEmpty)
          'sharedWithUids': result.sharedWithUids,
      });
    }

    return result;
  } catch (e) {
    debugPrint('Recurring master note save error: $e');
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              mapUserFacingError(
                e,
                fallback: 'Opslaan mislukt. Probeer opnieuw.',
              ),
            ),
          ),
        );
    }
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────

final GoogleSignIn _googleSignIn = GoogleSignIn.instance;

final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

const String _screenshotsBlockedPrefsKey = 'privacy.screenshotsBlocked';
const MethodChannel _privacyPlatformChannel = MethodChannel('kidu/privacy');

bool _screenshotsBlockedPreferenceCache = false;

Future<bool> _loadScreenshotsBlockedPreference() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_screenshotsBlockedPrefsKey) ?? false;
    _screenshotsBlockedPreferenceCache = enabled;
    return enabled;
  } catch (e) {
    debugPrint('Load screenshot privacy preference error: $e');
    return _screenshotsBlockedPreferenceCache;
  }
}

Future<void> _saveScreenshotsBlockedPreference(bool enabled) async {
  _screenshotsBlockedPreferenceCache = enabled;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_screenshotsBlockedPrefsKey, enabled);
  } catch (e) {
    debugPrint('Save screenshot privacy preference error: $e');
  }
}

Future<void> _applyScreenshotsBlockedPreference(bool enabled) async {
  if (!Platform.isAndroid) {
    return;
  }
  try {
    await _privacyPlatformChannel.invokeMethod<void>(
      'setScreenshotsBlocked',
      enabled,
    );
  } on MissingPluginException catch (e) {
    if (kDebugMode) {
      debugPrint('Screenshot privacy channel missing: $e');
    }
  } on PlatformException catch (e) {
    if (kDebugMode) {
      debugPrint('Screenshot privacy platform error: $e');
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('Apply screenshot privacy preference error: $e');
    }
  }
}

Future<void> _restoreScreenshotsBlockedPreference() async {
  try {
    final enabled = await _loadScreenshotsBlockedPreference();
    await _applyScreenshotsBlockedPreference(enabled);
  } on MissingPluginException catch (e) {
    if (kDebugMode) {
      debugPrint('Restore screenshot privacy channel missing: $e');
    }
  } on PlatformException catch (e) {
    if (kDebugMode) {
      debugPrint('Restore screenshot privacy platform error: $e');
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('Restore screenshot privacy preference error: $e');
    }
  }
}

PageRoute<T> _reopenLockNoTransitionRoute<T>(Widget child) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => child,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        child,
  );
}

void _replaceReopenLockRoot(Widget child) {
  final navigator = appNavigatorKey.currentState;
  if (navigator == null || !navigator.mounted) {
    return;
  }

  navigator.pushAndRemoveUntil<void>(
    _reopenLockNoTransitionRoute<void>(child),
    (route) => false,
  );
}

Future<void> _signOutForReopenLock() async {
  try {
    _replaceReopenLockRoot(const _AuthGateWhiteHoldScreen());
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
  } finally {
    _replaceReopenLockRoot(const AuthGate());
  }
}

Future<bool> _hasSignedInUserForReopenLock() async {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser != null) {
    return true;
  }

  try {
    final user = await FirebaseAuth.instance.authStateChanges().first;
    return user != null;
  } catch (_) {
    return FirebaseAuth.instance.currentUser != null;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _restoreScreenshotsBlockedPreference();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _googleSignIn.initialize();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const KiDuApp());
}

class KiDuApp extends StatefulWidget {
  const KiDuApp({super.key});

  @override
  State<KiDuApp> createState() => _KiDuAppState();
}

class _KiDuAppState extends State<KiDuApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Cold-start trigger: eerst de eerste frame laten renderen en daarna
    // via dezelfde centrale runner materialisatie proberen. De runner is
    // zelf defensive op "geen user" / "geen household", dus veilig als
    // auth-restore op dit moment nog niet helemaal klaar mocht zijn.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_RecurringMaterializationRunner.run());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_RecurringMaterializationRunner.run());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KiDu',
      theme: buildKiduTheme(),
      scaffoldMessengerKey: appScaffoldMessengerKey,
      navigatorKey: appNavigatorKey,
      builder: (context, child) => ReopenLockGate(
        shouldLock: _hasSignedInUserForReopenLock,
        onLogout: _signOutForReopenLock,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  static String? _lastUid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        final existingUser = FirebaseAuth.instance.currentUser;
        final shouldStartColdStartHandoff =
            snapshot.connectionState == ConnectionState.waiting &&
            existingUser != null &&
            _lastUid == null &&
            !_PostSignInHandoffController.isActive;
        if (shouldStartColdStartHandoff) {
          _PostSignInHandoffController.startWhiteHold();
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          if (_PostSignInHandoffController.isActive) {
            return _PostSignInHandoffController.loadingWidget;
          }
          return const _AuthGateBrandedLoading();
        }

        final user = snapshot.data;
        final currentUid = user?.uid;
        if (currentUid != _lastUid) {
          debugPrint('AuthGate authState change: uid=$_lastUid -> $currentUid');
          _lastUid = currentUid;
        }
        if (user == null) {
          _PostSignInHandoffController.clear();
          return const LoginPage();
        }

        return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          key: ValueKey('profileNameCheck-${user.uid}'),
          future: FirebaseFirestore.instance.doc('users/${user.uid}').get(),
          builder: (context, userDocSnapshot) {
            final dashboard = DashboardPage(
              key: ValueKey('dashboard-${user.uid}'),
              initialUserSnapshot: userDocSnapshot.data,
              onPreviewReadyChanged:
                  _PostSignInHandoffController.setDashboardReady,
            );

            if (userDocSnapshot.connectionState == ConnectionState.waiting) {
              if (_PostSignInHandoffController.isActive) {
                return _PostSignInHandoffGate(child: dashboard);
              }
              return const _AuthGateBrandedLoading();
            }

            if (userDocSnapshot.hasError) {
              if (_PostSignInHandoffController.isActive) {
                return _PostSignInHandoffGate(child: dashboard);
              }
              return dashboard;
            }

            final data = userDocSnapshot.data?.data();
            final profileName = (data?['profileName'] as String?)?.trim();
            if (profileName == null || profileName.isEmpty) {
              if (_PostSignInHandoffController.isActive) {
                return _PostSignInHandoffGate(child: dashboard);
              }
              return dashboard;
            }

            if (_PostSignInHandoffController.isActive) {
              return _PostSignInHandoffGate(child: dashboard);
            }
            return dashboard;
          },
        );
      },
    );
  }
}

class _PostSignInHandoffController {
  static const Duration minDuration = Duration(milliseconds: 1100);
  static const Duration brandedFadeDuration = Duration(milliseconds: 220);
  static const Duration whiteHoldFadeDuration = Duration(milliseconds: 350);
  static final ValueNotifier<bool> dashboardReady = ValueNotifier(false);
  static DateTime? _startedAt;
  static _PostSignInHandoffVisual _visual = _PostSignInHandoffVisual.branded;

  static bool get isActive => _startedAt != null;

  static void start() {
    _visual = _PostSignInHandoffVisual.branded;
    _startedAt = DateTime.now();
    dashboardReady.value = false;
  }

  static void startWhiteHold() {
    _visual = _PostSignInHandoffVisual.whiteHold;
    _startedAt = DateTime.now();
    dashboardReady.value = false;
  }

  static Duration get remaining {
    final startedAt = _startedAt;
    if (startedAt == null) {
      return Duration.zero;
    }
    if (_visual == _PostSignInHandoffVisual.whiteHold) {
      return Duration.zero;
    }
    final elapsed = DateTime.now().difference(startedAt);
    final remaining = minDuration - elapsed;
    if (remaining.isNegative) {
      return Duration.zero;
    }
    return remaining;
  }

  static void setDashboardReady(bool ready) {
    if (!isActive || dashboardReady.value == ready) {
      return;
    }
    dashboardReady.value = ready;
  }

  static Duration get fadeDuration => switch (_visual) {
    _PostSignInHandoffVisual.branded => brandedFadeDuration,
    _PostSignInHandoffVisual.whiteHold => whiteHoldFadeDuration,
  };

  static Widget get loadingWidget => switch (_visual) {
    _PostSignInHandoffVisual.branded => const _AuthGateBrandedLoading(),
    _PostSignInHandoffVisual.whiteHold => const _AuthGateWhiteHoldScreen(),
  };

  static void clear() {
    _startedAt = null;
    dashboardReady.value = false;
    _visual = _PostSignInHandoffVisual.branded;
  }
}

enum _PostSignInHandoffVisual { branded, whiteHold }

class _PostSignInHandoffGate extends StatefulWidget {
  const _PostSignInHandoffGate({required this.child});

  final Widget child;

  @override
  State<_PostSignInHandoffGate> createState() => _PostSignInHandoffGateState();
}

class _PostSignInHandoffGateState extends State<_PostSignInHandoffGate> {
  Timer? _minTimer;
  bool _minElapsed = false;
  bool _revealed = false;
  late final Duration _fadeDuration;
  late final Widget _loadingWidget;

  @override
  void initState() {
    super.initState();
    _fadeDuration = _PostSignInHandoffController.fadeDuration;
    _loadingWidget = _PostSignInHandoffController.loadingWidget;
    _PostSignInHandoffController.dashboardReady.addListener(_maybeReveal);
    final remaining = _PostSignInHandoffController.remaining;
    if (remaining == Duration.zero) {
      _minElapsed = true;
    } else {
      _minTimer = Timer(remaining, () {
        if (!mounted) {
          return;
        }
        _minElapsed = true;
        _maybeReveal();
      });
    }
    _maybeReveal();
  }

  @override
  void dispose() {
    _minTimer?.cancel();
    _PostSignInHandoffController.dashboardReady.removeListener(_maybeReveal);
    super.dispose();
  }

  void _maybeReveal() {
    if (!mounted ||
        _revealed ||
        !_minElapsed ||
        !_PostSignInHandoffController.dashboardReady.value) {
      return;
    }
    _PostSignInHandoffController.clear();
    setState(() => _revealed = true);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          ignoring: !_revealed,
          child: AnimatedOpacity(
            opacity: _revealed ? 1 : 0,
            duration: _fadeDuration,
            curve: Curves.easeOut,
            child: widget.child,
          ),
        ),
        IgnorePointer(
          ignoring: _revealed,
          child: AnimatedOpacity(
            opacity: _revealed ? 0 : 1,
            duration: _fadeDuration,
            curve: Curves.easeOut,
            child: _loadingWidget,
          ),
        ),
      ],
    );
  }
}

class _AuthGateBrandedLoading extends StatelessWidget {
  const _AuthGateBrandedLoading();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFF7F6F4),
      body: Align(
        alignment: Alignment(0, 0.0),
        child: Image(
          image: AssetImage('assets/images/kidu_icon.png'),
          width: 72,
        ),
      ),
    );
  }
}

class _AuthGateWhiteHoldScreen extends StatelessWidget {
  const _AuthGateWhiteHoldScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(backgroundColor: Colors.white);
  }
}

const String _privacyPolicyFull = '''
KiDu Privacybeleid / Privacy Policy
Laatst bijgewerkt: 2026-02-18

NL — Privacybeleid

1. Wie zijn wij?
KiDu is een app om gedeelde kind-uitgaven tussen co-parents bij te houden.
Ontwikkelaar / contact (privacy): meershoek@gmail.com

2. Welke gegevens verwerken we?
Account (inloggen via Google)
- Google-account gegevens die nodig zijn om in te loggen (bijv. e-mail, naam en profielfoto indien beschikbaar).

App-gegevens die jij invoert
- Huishouden (koppeling tussen co-parents).
- Uitgaven (bedrag, omschrijving, datum, wie heeft betaald).
- Invite codes (voor koppelen).
- Privé notities (alleen zichtbaar voor de gebruiker die ze maakt).

Technische gegevens
- We gebruiken Google Firebase (Auth/Firestore) om de app te laten werken. Deze diensten kunnen technische informatie verwerken die nodig is voor werking en beveiliging van de dienst.

3. Waarvoor gebruiken we deze gegevens?
- Inloggen en accountbeheer.
- Koppelen van co-parents binnen één huishouden.
- Opslaan en tonen van uitgaven, balans en privé notities.
- Beveiliging (toegangscontrole op basis van household-membership).

4. Delen we gegevens met derden?
We verkopen geen gegevens.
We gebruiken Google Firebase als verwerker/dienstverlener om inloggen en opslag mogelijk te maken (Firebase Authentication en Cloud Firestore).

5. Beveiliging
- Communicatie verloopt versleuteld (TLS).
- Toegang tot huishouden-data wordt beperkt via Firestore security rules (alleen members van het huishouden).

6. Bewaartermijn
We bewaren gegevens zolang je het account gebruikt.
Wil je gegevens verwijderen? Mail naar: meershoek@gmail.com
We verwijderen je data zo snel mogelijk en uiterlijk binnen 30 dagen, tenzij we wettelijk langer moeten bewaren.

7. Jouw rechten
Je kunt verzoeken om inzage, correctie of verwijdering via: meershoek@gmail.com

8. Kinderen
KiDu is bedoeld voor (co-)ouders/volwassenen en is niet ontworpen voor gebruik door kinderen.

---

EN — Privacy Policy

1. Who we are
KiDu helps co-parents track shared child-related expenses.
Developer / privacy contact: meershoek@gmail.com

2. Data we process
Account (Google sign-in)
- Google account data needed to sign in (e.g., email, name, profile photo if available).

User-provided app data
- Household connection between co-parents.
- Expenses (amount, description, date, who paid).
- Invite codes (for linking).
- Private notes (only visible to the user who created them).

Technical data
- We use Google Firebase (Auth/Firestore). These services may process technical information required for service operation and security.

3. Why we use data
- Authentication and account management.
- Linking co-parents inside one household.
- Storing and displaying expenses, balance, and private notes.
- Security (access control based on household membership).

4. Sharing
We do not sell data.
We use Google Firebase as a service provider (Firebase Authentication and Cloud Firestore).

5. Security
- Encrypted transport (TLS).
- Access restricted via Firestore security rules (household membership).

6. Retention & deletion
We keep data while your account is active.
To request deletion: meershoek@gmail.com
We aim to delete within 30 days unless legally required to retain longer.

7. Your rights
You can request access, correction, or deletion via: meershoek@gmail.com

8. Children
KiDu is intended for adults (co-parents) and is not designed for children.
''';

class ProfileNamePage extends StatefulWidget {
  const ProfileNamePage({
    super.key,
    this.fromSettings = false,
    this.initialName,
  });

  final bool fromSettings;
  final String? initialName;

  @override
  State<ProfileNamePage> createState() => _ProfileNamePageState();
}

class _ProfileNamePageState extends State<ProfileNamePage> {
  static final RegExp _allowedNameCharacter = RegExp(
    r"[\p{L}\p{M} '\-]",
    unicode: true,
  );
  static final RegExp _allowedName = RegExp(
    r"^[\p{L}\p{M} '\-]+$",
    unicode: true,
  );
  static const String _connectionError = 'Geen verbinding';
  static const Duration _saveTimeout = Duration(seconds: 6);

  final _controller = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  bool _busy = false;
  String? _nameInlineHint;
  late final String _initialNormalizedName;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialName;
    if (initial != null && initial.trim().isNotEmpty) {
      _controller.text = initial.trim();
    }
    _initialNormalizedName = _normalizedName(_controller.text);
  }

  String _normalizedName(String value) {
    return value.trim().replaceAll(RegExp(r' +'), ' ');
  }

  String? _profileNameError(String value) {
    if (value.length > 16) {
      return 'Gebruik maximaal 16 tekens.';
    }
    if (value.contains(RegExp(r'[\r\n]')) || !_allowedName.hasMatch(value)) {
      return "Gebruik alleen letters, spaties, - of '.";
    }
    return null;
  }

  Future<void> _writeProfileNameOnline({
    required String uid,
    required String name,
  }) async {
    final firestore = FirebaseFirestore.instance;
    final userRef = firestore.doc('users/$uid');

    await firestore
        .runTransaction((transaction) async {
          await transaction.get(userRef);
          transaction.set(userRef, {
            'profileName': name,
          }, SetOptions(merge: true));
        })
        .timeout(_saveTimeout);
  }

  Future<void> _save() async {
    if (_busy) {
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }

    final name = _normalizedName(_controller.text);
    if (name.length < 2) {
      return;
    }

    final validationError = _profileNameError(name);
    if (validationError != null) {
      setState(() => _nameInlineHint = validationError);
      return;
    }

    setState(() => _busy = true);
    try {
      final stillUser = FirebaseAuth.instance.currentUser;
      if (stillUser == null) {
        return;
      }

      final uid = stillUser.uid;
      if (!await _checkCanWriteNow()) {
        if (mounted) {
          setState(() => _nameInlineHint = _connectionError);
        }
        return;
      }

      await _writeProfileNameOnline(uid: uid, name: name);

      if (!mounted) {
        return;
      }
      if (widget.fromSettings) {
        Navigator.of(context).pop();
      } else {
        try {
          await _kiduEnsureHouseholdForCurrentUserIfNeeded();
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Household bootstrap after profile name: $e');
          }
        }
        final userSnap = await FirebaseFirestore.instance
            .doc('users/$uid')
            .get();
        if (!mounted) {
          return;
        }
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => DashboardPage(initialUserSnapshot: userSnap),
          ),
        );
      }
    } on TimeoutException catch (e) {
      if (kDebugMode) debugPrint('Save profileName timeout: $e');
      if (mounted) {
        setState(() => _nameInlineHint = _connectionError);
      }
    } on FirebaseException catch (e) {
      if (kDebugMode) debugPrint('Save profileName error: $e');
      final isConnectionError =
          e.code == 'unavailable' ||
          e.code == 'network-request-failed' ||
          e.code == 'deadline-exceeded';
      if (mounted) {
        setState(() {
          _nameInlineHint = isConnectionError
              ? _connectionError
              : mapUserFacingError(
                  e,
                  fallback: 'Opslaan mislukt. Probeer opnieuw.',
                );
        });
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Save profileName error: $e');
      if (mounted) {
        setState(() {
          _nameInlineHint = mapUserFacingError(
            e,
            fallback: 'Opslaan mislukt. Probeer opnieuw.',
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _signOut() async {
    if (_busy) {
      return;
    }

    setState(() => _busy = true);
    try {
      try {
        await FirebaseAuth.instance.signOut();
      } catch (_) {}
      try {
        await _googleSignIn.signOut();
      } catch (_) {}
      if (!mounted) {
        return;
      }
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AuthGate()),
        (route) => false,
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    _nameFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Text(
            'KiDu',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 24),
                const Text('Niet ingelogd'),
                const SizedBox(height: 12),
                SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute(builder: (_) => const AuthGate()),
                        (route) => false,
                      );
                    },
                    child: const Text('Naar login'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return PopScope(
      canPop: widget.fromSettings,
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          centerTitle: true,
          title: Text(
            'KiDu',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
        body: SafeArea(
          child: AnimatedPadding(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                const topPadding = 24.0;
                const bottomPadding = _DashboardPageState._pagePadding;
                final minHeight = max(
                  0.0,
                  constraints.maxHeight - topPadding - bottomPadding,
                );

                return SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.only(
                    left: _DashboardPageState._pagePadding,
                    right: _DashboardPageState._pagePadding,
                    top: topPadding,
                    bottom: bottomPadding,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: minHeight),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: _NameFormCard(
                          title: widget.fromSettings
                              ? 'Naam wijzigen'
                              : 'Welke naam wil je gebruiken?',
                          body: widget.fromSettings
                              ? 'Zichtbaar in jullie gedeelde KiDu-overzicht.'
                              : 'Deze naam is zichtbaar in jullie gedeelde KiDu-overzicht.',
                          controller: _controller,
                          focusNode: _nameFocus,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              _allowedNameCharacter,
                            ),
                            LengthLimitingTextInputFormatter(16),
                          ],
                          errorText: _nameInlineHint,
                          isSaving: _busy,
                          primaryEnabled: widget.fromSettings
                              ? _normalizedName(_controller.text).length >= 2 &&
                                    _normalizedName(_controller.text) !=
                                        _initialNormalizedName
                              : _normalizedName(_controller.text).length >= 2,
                          primaryLabel: 'Opslaan',
                          secondaryLabel: widget.fromSettings
                              ? 'Annuleren'
                              : 'Uitloggen',
                          onPrimaryPressed: _save,
                          onSecondaryPressed: widget.fromSettings
                              ? () => Navigator.of(context).pop()
                              : _signOut,
                          onChanged: (_) {
                            setState(() {
                              final currentError = _profileNameError(
                                _normalizedName(_controller.text),
                              );
                              if (_nameInlineHint != null &&
                                  currentError == null) {
                                _nameInlineHint = null;
                              }
                            });
                          },
                        ),
                      ),
                    ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _NameFormCard extends StatelessWidget {
  /// Caps card width below typical phone content area (~328–358px) so the
  /// constraint is visible on device; outer shell maxWidth alone had no effect.
  static const double shellMaxWidth = 380;

  const _NameFormCard({
    required this.title,
    required this.body,
    required this.controller,
    required this.focusNode,
    required this.inputFormatters,
    required this.errorText,
    required this.isSaving,
    required this.primaryEnabled,
    required this.primaryLabel,
    required this.secondaryLabel,
    required this.onPrimaryPressed,
    required this.onSecondaryPressed,
    required this.onChanged,
  });

  final String title;
  final String body;
  final TextEditingController controller;
  final FocusNode focusNode;
  final List<TextInputFormatter> inputFormatters;
  final String? errorText;
  final bool isSaving;
  final bool primaryEnabled;
  final String primaryLabel;
  final String secondaryLabel;
  final VoidCallback onPrimaryPressed;
  final VoidCallback onSecondaryPressed;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: shellMaxWidth),
      child: KiduCard(
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: onSurface(context, a62),
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            focusNode: focusNode,
            textCapitalization: TextCapitalization.sentences,
            inputFormatters: inputFormatters,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => FocusScope.of(context).unfocus(),
            onChanged: onChanged,
            decoration: kiduCompactInputDecoration(
              labelText: 'Naam',
            ).copyWith(
              floatingLabelBehavior: FloatingLabelBehavior.always,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          if (errorText != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                errorText!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                  height: 1.35,
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              TextButton(
                onPressed: isSaving ? null : onSecondaryPressed,
                child: Text(secondaryLabel),
              ),
              const Spacer(),
              FilledButton(
                style: kiduFormPrimaryButtonStyle(context),
                onPressed: isSaving || !primaryEnabled
                    ? null
                    : onPrimaryPressed,
                child: isSaving
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSecondaryContainer,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            primaryLabel,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      )
                    : Text(primaryLabel),
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }
}

/// Eerste naam binnen [DashboardPage] (settings in AppBar); zelfde save/huishouden-logica als [ProfileNamePage].
class _DashboardOnboardingNameCard extends StatefulWidget {
  const _DashboardOnboardingNameCard();

  @override
  State<_DashboardOnboardingNameCard> createState() =>
      _DashboardOnboardingNameCardState();
}

class _DashboardOnboardingNameCardState
    extends State<_DashboardOnboardingNameCard> {
  static final RegExp _allowedNameCharacter = RegExp(
    r"[\p{L}\p{M} '\-]",
    unicode: true,
  );
  static final RegExp _allowedName = RegExp(
    r"^[\p{L}\p{M} '\-]+$",
    unicode: true,
  );
  static const String _connectionError = 'Geen verbinding';
  static const Duration _saveTimeout = Duration(seconds: 6);

  final _controller = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  bool _busy = false;
  String? _nameInlineHint;

  @override
  void dispose() {
    _nameFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  String _normalizedName(String value) {
    return value.trim().replaceAll(RegExp(r' +'), ' ');
  }

  String? _profileNameError(String value) {
    if (value.length > 16) {
      return 'Gebruik maximaal 16 tekens.';
    }
    if (value.contains(RegExp(r'[\r\n]')) || !_allowedName.hasMatch(value)) {
      return "Gebruik alleen letters, spaties, - of '.";
    }
    return null;
  }

  Future<void> _writeProfileNameOnline({
    required String uid,
    required String name,
  }) async {
    final firestore = FirebaseFirestore.instance;
    final userRef = firestore.doc('users/$uid');

    await firestore
        .runTransaction((transaction) async {
          await transaction.get(userRef);
          transaction.set(userRef, {
            'profileName': name,
          }, SetOptions(merge: true));
        })
        .timeout(_saveTimeout);
  }

  Future<void> _save() async {
    if (_busy) {
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }

    final name = _normalizedName(_controller.text);
    if (name.length < 2) {
      return;
    }

    final validationError = _profileNameError(name);
    if (validationError != null) {
      setState(() => _nameInlineHint = validationError);
      return;
    }

    setState(() => _busy = true);
    try {
      final stillUser = FirebaseAuth.instance.currentUser;
      if (stillUser == null) {
        return;
      }

      final uid = stillUser.uid;
      if (!await _checkCanWriteNow()) {
        if (mounted) {
          setState(() => _nameInlineHint = _connectionError);
        }
        return;
      }

      await _writeProfileNameOnline(uid: uid, name: name);

      if (!mounted) {
        return;
      }

      try {
        await _kiduEnsureHouseholdForCurrentUserIfNeeded();
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Household bootstrap after profile name: $e');
        }
      }
    } on TimeoutException catch (e) {
      if (kDebugMode) debugPrint('Save profileName timeout: $e');
      if (mounted) {
        setState(() => _nameInlineHint = _connectionError);
      }
    } on FirebaseException catch (e) {
      if (kDebugMode) debugPrint('Save profileName error: $e');
      final isConnectionError =
          e.code == 'unavailable' ||
          e.code == 'network-request-failed' ||
          e.code == 'deadline-exceeded';
      if (mounted) {
        setState(() {
          _nameInlineHint = isConnectionError
              ? _connectionError
              : mapUserFacingError(
                  e,
                  fallback: 'Opslaan mislukt. Probeer opnieuw.',
                );
        });
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Save profileName error: $e');
      if (mounted) {
        setState(() {
          _nameInlineHint = mapUserFacingError(
            e,
            fallback: 'Opslaan mislukt. Probeer opnieuw.',
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _signOut() async {
    if (_busy) {
      return;
    }

    setState(() => _busy = true);
    try {
      try {
        await FirebaseAuth.instance.signOut();
      } catch (_) {}
      try {
        await _googleSignIn.signOut();
      } catch (_) {}
      if (!mounted) {
        return;
      }
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AuthGate()),
        (route) => false,
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _NameFormCard(
      title: 'Welke naam wil je gebruiken?',
      body: 'Zo ziet je co-parent jou straks in KiDu.',
      controller: _controller,
      focusNode: _nameFocus,
      inputFormatters: [
        FilteringTextInputFormatter.allow(_allowedNameCharacter),
        LengthLimitingTextInputFormatter(16),
      ],
      errorText: _nameInlineHint,
      isSaving: _busy,
      primaryEnabled: _normalizedName(_controller.text).length >= 2,
      primaryLabel: 'Verder',
      secondaryLabel: 'Uitloggen',
      onPrimaryPressed: _save,
      onSecondaryPressed: _signOut,
      onChanged: (_) {
        setState(() {
          final currentError = _profileNameError(
            _normalizedName(_controller.text),
          );
          if (_nameInlineHint != null && currentError == null) {
            _nameInlineHint = null;
          }
        });
      },
    );
  }
}

class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  static const double _pagePadding = 16;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          'Privacyverklaring',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(_pagePadding),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              child: Text(
                _privacyPolicyFull,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: onSurface(context, a68),
                  height: 1.35,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const String _kLoginNetworkErrorMessage = 'Geen internetverbinding';
const String _kLoginGenericErrorMessage = 'Inloggen niet gelukt';

bool _loginGoogleSignInWasCanceledByUser(Object error) {
  return error is GoogleSignInException &&
      error.code == GoogleSignInExceptionCode.canceled;
}

/// Inline copy for login only: network-style Firebase [FirebaseException] codes.
String _loginInlineMessageForFirebaseCode(String code) {
  if (code == 'network-request-failed' || code == 'unavailable') {
    return _kLoginNetworkErrorMessage;
  }
  return _kLoginGenericErrorMessage;
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  String? _error;
  bool _busy = false;

  Future<void> _signInWithGoogle() async {
    if (_busy) {
      return;
    }

    setState(() {
      _error = null;
      _busy = true;
    });

    try {
      // a) Trigger Google Sign-In flow (google_sign_in 7.x)
      final googleUser = await _googleSignIn.authenticate();

      // b) Obtain auth details
      final googleAuth = googleUser.authentication;
      final idToken = googleAuth.idToken;
      if (idToken == null || idToken.trim().isEmpty) {
        if (mounted) {
          setState(() => _error = _kLoginGenericErrorMessage);
        }
        return;
      }

      // d) Create Firebase credential
      final credential = GoogleAuthProvider.credential(idToken: idToken);

      // e) Sign in to Firebase
      await FirebaseAuth.instance.signInWithCredential(credential);
      _PostSignInHandoffController.start();
      debugPrint(
        'After sign-in currentUser: uid=${FirebaseAuth.instance.currentUser?.uid} '
        'email=${FirebaseAuth.instance.currentUser?.email}',
      );
    } on FirebaseAuthException catch (e) {
      debugPrint('Google sign-in FirebaseAuthException: $e');
      final message = _loginInlineMessageForFirebaseCode(e.code);
      if (mounted) {
        setState(() => _error = message);
      }
    } catch (e) {
      debugPrint('Google sign-in error: $e');
      if (e is PlatformException) {
        debugPrint(
          'PlatformException code=${e.code} message=${e.message} details=${e.details}',
        );
      }
      if (_loginGoogleSignInWasCanceledByUser(e)) {
        if (mounted) {
          setState(() => _error = null);
        }
      } else {
        final message = e is FirebaseException
            ? _loginInlineMessageForFirebaseCode(e.code)
            : _kLoginGenericErrorMessage;
        if (mounted) {
          setState(() => _error = message);
        }
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_PostSignInHandoffController.isActive) {
      return const _AuthGateBrandedLoading();
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.only(top: 34, bottom: 38),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 32,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset('assets/images/kidu_logo.png', width: 180),
                      const SizedBox(height: 32),
                      Text(
                        'Rust in gedeelde kosten',
                        style:
                            Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w500,
                              letterSpacing: -0.2,
                              color: onSurface(context, a85),
                            ) ??
                            TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w500,
                              letterSpacing: -0.2,
                              color: onSurface(context, a85),
                            ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 40),
                      if (_error != null) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.errorContainer,
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).colorScheme.error.withValues(alpha: 0.35),
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      IgnorePointer(
                        ignoring: _busy,
                        child: Opacity(
                          opacity: _busy ? 0.6 : 1.0,
                          child: SizedBox(
                            height: 64,
                            width: double.infinity,
                            child: Transform.scale(
                              scale: 1.08,
                              alignment: Alignment.center,
                              child: SignInButton(
                                Buttons.google,
                                onPressed: _signInWithGoogle,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.lock_outline,
                            size: 16,
                            color: onSurface(context, a60),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Veilig inloggen via Google',
                              style: TextStyle(
                                fontSize: 13,
                                color: onSurface(context, a60),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Creates `households/{id}` + `members/{uid}` and sets `users/{uid}.householdId`
/// when still missing. No-op if [householdId] already exists. Throws on Firestore
/// transaction failure.
Future<void> _kiduEnsureHouseholdForCurrentUserIfNeeded() async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) {
    return;
  }

  final firestore = FirebaseFirestore.instance;
  final userRef = firestore.doc('users/$uid');

  final result = await firestore.runTransaction<Map<String, dynamic>>((
    transaction,
  ) async {
    final userSnap = await transaction.get(userRef);
    final userData = userSnap.data();
    final existingHouseholdId = (userData?['householdId'] as String?)?.trim();

    if (existingHouseholdId != null && existingHouseholdId.isNotEmpty) {
      return {'alreadyExists': true, 'householdId': existingHouseholdId};
    }

    final householdRef = firestore.collection('households').doc();
    transaction.set(householdRef, {
      'createdAt': FieldValue.serverTimestamp(),
      'createdBy': uid,
      'name': 'KiDu Household',
      'isConnected': false,
    });

    final memberRef = householdRef.collection('members').doc(uid);
    transaction.set(memberRef, {
      'role': 'parent',
      'joinedAt': FieldValue.serverTimestamp(),
    });

    transaction.set(userRef, {
      'householdId': householdRef.id,
      'setupCompletedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    return {'alreadyExists': false, 'householdId': householdRef.id};
  });

  final alreadyExists = result['alreadyExists'] == true;
  if (alreadyExists) {
    return;
  }
}

/// Zelfde dialog als Settings → Privacybeleid (inclusief route naar volledige
/// privacyverklaring).
void _showPrivacyPolicyDialog(BuildContext context) {
  final routeContext = context;
  final settingsNavigator = Navigator.of(routeContext);
  showDialog<void>(
    context: routeContext,
    builder: (ctx) => AlertDialog(
      title: const Text('Privacy in KiDu'),
      content: SingleChildScrollView(
        child: Text(
          'KiDu is gebouwd met één uitgangspunt: zo min mogelijk privacy-gevoelige data.\n\n'
          'Wat we wél gebruiken (alleen wat nodig is):\n'
          '• Je gekozen naam (zodat jullie elkaar herkennen)\n'
          '• Je Google-account (voor veilig inloggen)\n'
          '• Jullie gedeelde uitgaven in KiDu\n\n'
          'Wat KiDu níét vraagt of gebruikt:\n'
          '• Geen telefoonnummer\n'
          '• Geen toegang tot je contacten\n'
          '• Geen locatie\n'
          '• Geen agenda, microfoon of camera\n'
          '• Geen push-notificaties of "ping-gedrag"\n\n'
          'Delen met anderen?\n'
          '• Jullie gegevens zijn bedoeld voor jou en je co-parent in jullie huishouden (max. 2 accounts).\n'
          '• We delen geen gegevens voor marketingdoeleinden.\n'
          '• We verkopen je gegevens niet.\n\n'
          'Je houdt de controle:\n'
          '• Je kunt je naam altijd aanpassen.\n'
          '• Je kunt uitloggen wanneer je wilt.',
          style: Theme.of(
            ctx,
          ).textTheme.bodyMedium?.copyWith(color: onSurface(ctx, a68)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            if (!routeContext.mounted) return;
            settingsNavigator.push(
              MaterialPageRoute(builder: (_) => const PrivacyPolicyPage()),
            );
          },
          child: const Text('Volledige privacyverklaring'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Sluiten'),
        ),
      ],
    ),
  );
}

/// Zelfde dialog als Settings → Over KiDu.
void _showAboutKiduDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('KiDu'),
      content: const Text(
        'Rust in gedeelde kosten tussen co-parents.\n'
        'Koppelen, bijhouden, afrekenen — zonder gedoe.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Sluiten'),
        ),
      ],
    ),
  );
}

/// Instellingen als volledig scherm (was bottom sheet).
class _UitgavenverdelingSettingsTile extends StatefulWidget {
  const _UitgavenverdelingSettingsTile({required this.householdId});

  final String householdId;

  @override
  State<_UitgavenverdelingSettingsTile> createState() =>
      _UitgavenverdelingSettingsTileState();
}

class _UitgavenverdelingSettingsTileState
    extends State<_UitgavenverdelingSettingsTile> {
  bool _busy = false;

  Future<void> _onTap() async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (!await _checkCanWriteNow()) {
      if (!context.mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Je bent offline, probeer het later opnieuw.'),
            duration: Duration(seconds: 4),
          ),
        );
      return;
    }
    setState(() => _busy = true);
    try {
      final repo = HouseholdSplitSettingsRepository();
      final members = await loadHouseholdSplitMembers(widget.householdId);
      final defaults = await repo.watch(widget.householdId).first;
      if (!mounted) return;
      await navigator.push<void>(
        PageRouteBuilder<void>(
          pageBuilder: (routeContext, animation, secondaryAnimation) =>
              HouseholdSplitSettingsPage(
                householdId: widget.householdId,
                initialMembers: members,
                initialDefaults: defaults,
              ),
          transitionDuration: const Duration(milliseconds: 180),
          reverseTransitionDuration: const Duration(milliseconds: 180),
          transitionsBuilder:
              (routeContext, animation, secondaryAnimation, child) =>
                  FadeTransition(opacity: animation, child: child),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.standard,
      enabled: !_busy,
      leading: Icon(
        Icons.percent_outlined,
        size: 18,
        color: onSurface(context, a45),
      ),
      title: Text(
        'Uitgavenverdeling',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: onSurface(context, 0.80),
        ),
      ),
      onTap: _busy ? null : _onTap,
    );
  }
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({
    required this.dashboardMounted,
    required this.householdId,
    required this.myUid,
    required this.otherName,
    required this.isCoParentLinked,
    this.myName,
    required this.openPrivacySecuritySheet,
    required this.signOut,
  });

  final bool Function() dashboardMounted;
  final String householdId;
  final String myUid;
  final String? otherName;
  final bool isCoParentLinked;
  final String? myName;
  final void Function(BuildContext rootContext) openPrivacySecuritySheet;
  final Future<void> Function(BuildContext context) signOut;

  @override
  Widget build(BuildContext context) {
    final hasHousehold = householdId.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          'Instellingen',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: _DashboardPageState._pagePadding,
            right: _DashboardPageState._pagePadding,
            top: 24,
            bottom:
                _DashboardPageState._pagePadding +
                MediaQuery.of(context).viewInsets.bottom,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                KiduCard(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Huishouden',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: onSurface(context, a70),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (hasHousehold)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          visualDensity: VisualDensity.standard,
                          leading: Icon(
                            Icons.child_care_outlined,
                            size: 18,
                            color: onSurface(context, a45),
                          ),
                          title: Text(
                            'Kinderen',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: onSurface(context, 0.80)),
                          ),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    _KinderenPage(householdId: householdId),
                              ),
                            );
                          },
                        ),
                      if (hasHousehold)
                        _UitgavenverdelingSettingsTile(
                          householdId: householdId,
                        ),
                      if (hasHousehold)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          visualDensity: VisualDensity.standard,
                          leading: Icon(
                            Icons.event_repeat_outlined,
                            size: 18,
                            color: onSurface(context, a45),
                          ),
                          title: Text(
                            'Maandelijkse uitgaven',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: onSurface(context, 0.80)),
                          ),
                          onTap: () {
                            // Route-lokale fix voor swipe-back jank op deze
                            // ene route. Een PageRouteBuilder negeert het
                            // pageTransitionsTheme, waardoor Android
                            // predictive-back / iOS swipe-back niet de
                            // onderliggende dashboard-opbouw blootleggen.
                            // Dezelfde korte fade speelt bij zowel pijltje
                            // terug als swipe-back, zodat beide paden
                            // visueel (vrijwel) identiek aanvoelen.
                            Navigator.of(context).push<void>(
                              PageRouteBuilder<void>(
                                pageBuilder:
                                    (
                                      routeContext,
                                      animation,
                                      secondaryAnimation,
                                    ) => _TerugkerendeKostenPage(
                                      householdId: householdId,
                                      isCoParentLinked: isCoParentLinked,
                                      otherParentName: otherName,
                                      myParentName: myName,
                                    ),
                                transitionDuration: const Duration(
                                  milliseconds: 180,
                                ),
                                reverseTransitionDuration: const Duration(
                                  milliseconds: 180,
                                ),
                                transitionsBuilder:
                                    (
                                      routeContext,
                                      animation,
                                      secondaryAnimation,
                                      child,
                                    ) => FadeTransition(
                                      opacity: animation,
                                      child: child,
                                    ),
                              ),
                            );
                          },
                        ),
                      if (hasHousehold)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          visualDensity: VisualDensity.standard,
                          leading: Icon(
                            Icons.menu_book_outlined,
                            size: 18,
                            color: onSurface(context, a45),
                          ),
                          title: Text(
                            'Logboek',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: onSurface(context, 0.80)),
                          ),
                          onTap: () {
                            // Zelfde route-lokale fade als bij
                            // _TerugkerendeKostenPage: maskeert swipe-back /
                            // predictive-back jank op deze route en maakt
                            // openen/sluiten visueel consistent met
                            // 'Maandelijkse uitgaven'.
                            Navigator.of(context).push<void>(
                              PageRouteBuilder<void>(
                                pageBuilder:
                                    (
                                      routeContext,
                                      animation,
                                      secondaryAnimation,
                                    ) => _LogboekPage(
                                      householdId: householdId,
                                      uid: myUid,
                                      myName: myName,
                                      otherName: otherName,
                                    ),
                                transitionDuration: const Duration(
                                  milliseconds: 180,
                                ),
                                reverseTransitionDuration: const Duration(
                                  milliseconds: 180,
                                ),
                                transitionsBuilder:
                                    (
                                      routeContext,
                                      animation,
                                      secondaryAnimation,
                                      child,
                                    ) => FadeTransition(
                                      opacity: animation,
                                      child: child,
                                    ),
                              ),
                            );
                          },
                        ),
                      const SizedBox(height: 16),
                      Text(
                        'Privacy',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: onSurface(context, a70),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.standard,
                        leading: Icon(
                          Icons.lock_outline,
                          size: 18,
                          color: onSurface(context, a45),
                        ),
                        title: Text(
                          'Beveiliging en privacy',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: onSurface(context, 0.80)),
                        ),
                        onTap: () {
                          final sheetAnchorContext = context;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!dashboardMounted() ||
                                !sheetAnchorContext.mounted) {
                              return;
                            }
                            openPrivacySecuritySheet(sheetAnchorContext);
                          });
                        },
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Info',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: onSurface(context, a70),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.standard,
                        leading: Icon(
                          Icons.privacy_tip_outlined,
                          size: 18,
                          color: onSurface(context, a45),
                        ),
                        title: Text(
                          'Privacybeleid',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: onSurface(context, 0.80)),
                        ),
                        onTap: () => _showPrivacyPolicyDialog(context),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.standard,
                        leading: Icon(
                          Icons.info_outline,
                          size: 18,
                          color: onSurface(context, a45),
                        ),
                        title: Text(
                          'Over KiDu',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: onSurface(context, 0.80)),
                        ),
                        onTap: () => _showAboutKiduDialog(context),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Account',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: onSurface(context, a70),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.standard,
                        leading: Icon(
                          Icons.edit_outlined,
                          size: 18,
                          color: onSurface(context, a45),
                        ),
                        title: Text(
                          'Naam wijzigen',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: onSurface(context, 0.80)),
                        ),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ProfileNamePage(
                                fromSettings: true,
                                initialName: myName,
                              ),
                            ),
                          );
                        },
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.standard,
                        leading: Icon(
                          Icons.logout,
                          size: 18,
                          color: onSurface(context, a45),
                        ),
                        title: Text(
                          'Uitloggen',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: onSurface(context, 0.80)),
                        ),
                        onTap: () {
                          final settingsContext = context;
                          unawaited(signOut(settingsContext));
                        },
                      ),
                    ],
                  ),
                ),
                if (isCoParentLinked &&
                    (otherName ?? '').trim().isNotEmpty &&
                    (otherName ?? '').trim() != 'Co-parent') ...[
                  const SizedBox(height: 28),
                  Center(
                    child: Text(
                      'Verbonden met ${(otherName ?? '').trim()}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: onSurface(context, a32),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    this.initialUserSnapshot,
    this.onPreviewReadyChanged,
  });

  /// Seeds the user-doc stream from [AuthGate] to skip an extra loading frame.
  final DocumentSnapshot<Map<String, dynamic>>? initialUserSnapshot;
  final ValueChanged<bool>? onPreviewReadyChanged;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  bool _setupBusy = false;
  bool _inviteBusy = false;
  bool _inviteSheetOpening = false;
  bool _screenshotsBlocked = _screenshotsBlockedPreferenceCache;
  bool _reopenLockEnabled = false;
  bool _reopenLockBusy = false;
  final ReopenLockService _reopenLockService = ReopenLockService();
  final ValueNotifier<bool> _addExpenseCheckBusyVN = ValueNotifier(false);
  final ValueNotifier<bool> _freezeExpensesVN = ValueNotifier(false);
  final ValueNotifier<bool> _addExpenseDialogOpenVN = ValueNotifier(false);
  QuerySnapshot<Map<String, dynamic>>? _lastExpensesSnap;
  int _notesRefreshTick = 0;
  bool _noteWriteInFlight = false;
  final Map<String, Future<String?>> _noteFutureCache = {};
  final Map<String, Future<String?>> _peerSharedExpenseNoteFutureCache = {};

  String? _namesCacheKey;
  Future<Map<String, String>>? _namesFuture;
  String? _dashboardSecondaryMetadataCacheKey;
  Future<_DashboardSecondaryMetadata>? _dashboardSecondaryMetadataFuture;
  String? _lastVisibleDashboardSecondaryMetadataScopeKey;
  _DashboardSecondaryMetadata? _lastVisibleDashboardSecondaryMetadata;
  _PendingExpenseRowFallback? _pendingExpenseRowFallback;

  List<_ChildItem> _dashChildren = [];
  bool _dashHasMultipleChildDocs = true;
  String? _dashChildrenHouseholdId;
  String? _dashChildrenSubHouseholdId;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _dashChildrenSubscription;

  String? _settlementsHouseholdId;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _settlementsSubscription;
  int _totalPaidByMe = 0;
  int _totalPaidToMe = 0;

  String? _paymentsHouseholdId;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _paymentsSubscription;
  Map<String, dynamic>? _pendingIncoming;
  String? _pendingIncomingId;
  Map<String, dynamic>? _pendingOutgoing;

  String? _confirmedPaymentsHouseholdId;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _confirmedPaymentsSubscription;
  int _confirmedPaidByMe = 0;
  int _confirmedPaidToMe = 0;
  bool? _lastReportedPreviewReady;

  void _reportPreviewReady(bool ready) {
    if (_lastReportedPreviewReady == ready) {
      return;
    }
    _lastReportedPreviewReady = ready;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      widget.onPreviewReadyChanged?.call(ready);
    });
  }

  Future<String?> _loadMyPrivateNote({
    required String householdId,
    required String expenseId,
    required String uid,
  }) async {
    final snap = await FirebaseFirestore.instance
        .doc('households/$householdId/expenses/$expenseId/privateNotes/$uid')
        .get();
    final data = snap.data();
    final raw = (data?['note'] as String?)?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  /// Creator's privateNotes doc; returns trimmed note only when [viewerUid]
  /// appears in stored `sharedWithUids`. No UI on denied/missing/forbidden-read.
  Future<String?> _loadPeerSharedExpenseNoteForViewer({
    required String householdId,
    required String expenseId,
    required String creatorUid,
    required String viewerUid,
  }) async {
    final slot = creatorUid.trim();
    if (slot.isEmpty) return null;
    try {
      final snap = await FirebaseFirestore.instance
          .doc('households/$householdId/expenses/$expenseId/privateNotes/$slot')
          .get();
      if (!snap.exists) return null;
      final data = snap.data();
      if (!_ExpenseDetailPage._privateNoteIsSharedWithViewer(data, viewerUid)) {
        return null;
      }
      final raw = (data?['note'] as String?)?.trim();
      if (raw == null || raw.isEmpty) return null;
      return raw;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') return null;
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _getNoteFuture(String householdId, String expenseId) {
    return _noteFutureCache.putIfAbsent(
      expenseId,
      () => _loadMyPrivateNote(
        householdId: householdId,
        expenseId: expenseId,
        uid: FirebaseAuth.instance.currentUser!.uid,
      ),
    );
  }

  Future<String?> _getPeerSharedExpenseNoteFuture({
    required String householdId,
    required String expenseId,
    required String creatorUid,
    required String viewerUid,
  }) {
    final cacheKey =
        '$householdId|$expenseId|${_ExpenseDetailPage._privateNotesDocUid(creatorUid)}';
    return _peerSharedExpenseNoteFutureCache.putIfAbsent(
      cacheKey,
      () => _loadPeerSharedExpenseNoteForViewer(
        householdId: householdId,
        expenseId: expenseId,
        creatorUid: creatorUid,
        viewerUid: viewerUid,
      ),
    );
  }

  Future<String> _loadUserDisplayName({
    required String uid,
    required String fallback,
  }) async {
    try {
      final snap = await FirebaseFirestore.instance.doc('users/$uid').get();
      final data = snap.data();
      final profileName = (data?['profileName'] as String?)?.trim();
      final displayName = (data?['displayName'] as String?)?.trim();
      final email = (data?['email'] as String?)?.trim();

      return (profileName != null && profileName.isNotEmpty)
          ? profileName
          : (displayName != null && displayName.isNotEmpty)
          ? displayName
          : (email != null && email.isNotEmpty)
          ? email
          : fallback;
    } catch (e) {
      debugPrint('Fetch user name error (uid=$uid): $e');
      return fallback;
    }
  }

  Future<_DashboardSecondaryMetadata> _fetchDashboardSecondaryMetadata({
    required String householdId,
    required String otherUid,
    required List<String> visibleOwnExpenseIds,
    required List<({String expenseId, String creatorUid})>
    visiblePeerExpensePrivateNoteLookups,
    required String viewerUid,
    required String otherFallback,
  }) async {
    final otherNameFuture = _loadUserDisplayName(
      uid: otherUid,
      fallback: otherFallback,
    );
    final notesFuture = Future.wait(
      visibleOwnExpenseIds.map(
        (expenseId) => _getNoteFuture(
          householdId,
          expenseId,
        ).then((note) => MapEntry(expenseId, note)),
      ),
    );
    final peerNotesFuture = Future.wait(
      visiblePeerExpensePrivateNoteLookups.map(
        (p) => _getPeerSharedExpenseNoteFuture(
          householdId: householdId,
          expenseId: p.expenseId,
          creatorUid: p.creatorUid,
          viewerUid: viewerUid,
        ).then((note) => MapEntry(p.expenseId, note)),
      ),
    );

    final otherName = await otherNameFuture;
    final noteEntries = await notesFuture;
    final peerEntries = await peerNotesFuture;

    final notesByExpenseId = <String, String>{};
    for (final entry in noteEntries) {
      final note = entry.value?.trim();
      if (note != null && note.isNotEmpty) {
        notesByExpenseId[entry.key] = note;
      }
    }
    for (final entry in peerEntries) {
      final note = entry.value?.trim();
      if (note != null && note.isNotEmpty) {
        notesByExpenseId[entry.key] = note;
      }
    }

    return _DashboardSecondaryMetadata(
      otherName: otherName,
      notesByExpenseId: notesByExpenseId,
    );
  }

  Future<_DashboardSecondaryMetadata> _getDashboardSecondaryMetadataFuture({
    required String householdId,
    required String otherUid,
    required List<String> visibleOwnExpenseIds,
    required List<({String expenseId, String creatorUid})>
    visiblePeerExpensePrivateNoteLookups,
    required String viewerUid,
  }) {
    final visibleIdsKey = visibleOwnExpenseIds.join(',');
    final peerKey = visiblePeerExpensePrivateNoteLookups
        .map((p) => '${p.expenseId}:${p.creatorUid}')
        .join('|');
    final key =
        '$householdId|$otherUid|$visibleIdsKey|$peerKey|$viewerUid|$_notesRefreshTick';
    if (_dashboardSecondaryMetadataFuture == null ||
        _dashboardSecondaryMetadataCacheKey != key) {
      _dashboardSecondaryMetadataCacheKey = key;
      _dashboardSecondaryMetadataFuture = _fetchDashboardSecondaryMetadata(
        householdId: householdId,
        otherUid: otherUid,
        visibleOwnExpenseIds: visibleOwnExpenseIds,
        visiblePeerExpensePrivateNoteLookups:
            visiblePeerExpensePrivateNoteLookups,
        viewerUid: viewerUid,
        otherFallback: 'Co-parent',
      );
    }
    return _dashboardSecondaryMetadataFuture!;
  }

  String _formatDashboardExpenseDate(DateTime? dt) {
    if (dt == null) return '';
    const nlMonths = <String>[
      'jan',
      'feb',
      'mrt',
      'apr',
      'mei',
      'jun',
      'jul',
      'aug',
      'sep',
      'okt',
      'nov',
      'dec',
    ];
    return '${dt.day} ${nlMonths[dt.month - 1]}';
  }

  static const double _pagePadding = 16;
  static const double _cardRadius = 18;
  static const double _cardGap = 16;

  void _showSnackBar(String message, {Duration? duration}) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration ?? const Duration(seconds: 4),
      ),
    );
  }

  /// Thin dashboard wrapper around [_doManagePrivateNote].
  /// Guards against concurrent taps and busts the local note-cache on success.
  Future<void> _openEditPrivateNoteDialog({
    required String householdId,
    required String expenseId,
    required String uid,
  }) async {
    if (_noteWriteInFlight) return;
    _noteWriteInFlight = true;
    try {
      final result = await _doManagePrivateNote(
        context,
        householdId: householdId,
        expenseId: expenseId,
        uid: uid,
      );
      if (result != null && mounted) {
        setState(() {
          _notesRefreshTick++;
          _noteFutureCache.clear();
          _peerSharedExpenseNoteFutureCache.clear();
        });
      }
    } finally {
      _noteWriteInFlight = false;
    }
  }

  int? _tryParseEurToCents(String input) {
    final raw = input.trim().replaceAll(' ', '');
    if (raw.isEmpty) {
      return null;
    }
    final normalized = raw.replaceAll(',', '.');
    if (!RegExp(r'^\d+(\.\d{0,2})?$').hasMatch(normalized)) {
      return null;
    }

    final parts = normalized.split('.');
    final euros = int.tryParse(parts[0]) ?? 0;
    var cents = 0;
    if (parts.length == 2 && parts[1].isNotEmpty) {
      final frac = parts[1];
      if (frac.length == 1) {
        cents = int.parse(frac) * 10;
      } else if (frac.length == 2) {
        cents = int.parse(frac);
      } else {
        return null;
      }
    }
    return euros * 100 + cents;
  }

  String _formatEur(int cents) {
    final negative = cents < 0;
    final abs = cents.abs();
    final euros = abs ~/ 100;
    final rem = abs % 100;
    // Dutch thousands separator '.' and decimal separator ','.
    final euroStr = euros.toString();
    final buf = StringBuffer();
    for (var i = 0; i < euroStr.length; i++) {
      if (i > 0 && (euroStr.length - i) % 3 == 0) buf.write('.');
      buf.write(euroStr[i]);
    }
    return '${negative ? '-' : ''}€$buf,${rem.toString().padLeft(2, '0')}';
  }

  String _formatRelativeNl(DateTime dt) => formatRelativeTimeNl(dt);

  Future<Map<String, String>> _fetchUserNames({
    required String myUid,
    required String? otherUid,
    required String myFallback,
    required String otherFallback,
  }) async {
    final result = <String, String>{};

    Future<void> loadOne(String uid, String fallback) async {
      result[uid] = await _loadUserDisplayName(uid: uid, fallback: fallback);
    }

    await loadOne(myUid, myFallback);
    if (otherUid != null && otherUid.trim().isNotEmpty) {
      await loadOne(otherUid, otherFallback);
    }
    return result;
  }

  Future<Map<String, String>> _getNamesFuture({
    required String householdId,
    required String myUid,
    required String? otherUid,
    required String myFallback,
    required String otherFallback,
  }) {
    final key = '$householdId|$myUid|${otherUid ?? ''}';
    if (_namesFuture == null || _namesCacheKey != key) {
      _namesCacheKey = key;
      _namesFuture = _fetchUserNames(
        myUid: myUid,
        otherUid: otherUid,
        myFallback: myFallback,
        otherFallback: otherFallback,
      );
    }
    return _namesFuture!;
  }

  void _startSettlementsSubscription(String householdId, String myUid) {
    if (_settlementsHouseholdId == householdId) return;
    _settlementsSubscription?.cancel();
    _settlementsHouseholdId = householdId;
    _settlementsSubscription = FirebaseFirestore.instance
        .collection('households/$householdId/settlements')
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          var paidByMe = 0;
          var paidToMe = 0;
          for (final doc in snap.docs) {
            final d = doc.data();
            final cents = (d['amountCents'] as num?)?.toInt() ?? 0;
            final debtor = (d['debtorUid'] as String?)?.trim();
            final creditor = (d['creditorUid'] as String?)?.trim();
            if (debtor == myUid) paidByMe += cents;
            if (creditor == myUid) paidToMe += cents;
          }
          setState(() {
            _totalPaidByMe = paidByMe;
            _totalPaidToMe = paidToMe;
          });
        });
  }

  void _startPaymentsSubscription(String householdId, String myUid) {
    if (_paymentsHouseholdId == householdId) return;
    _paymentsSubscription?.cancel();
    _paymentsHouseholdId = householdId;
    _paymentsSubscription = FirebaseFirestore.instance
        .collection('households/$householdId/payments')
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          Map<String, dynamic>? incoming;
          String? incomingId;
          Map<String, dynamic>? outgoing;
          for (final doc in snap.docs) {
            final d = doc.data();
            final to = (d['toUserId'] as String?)?.trim();
            final from = (d['fromUserId'] as String?)?.trim();
            if (to == myUid && incoming == null) {
              incoming = d;
              incomingId = doc.id;
            }
            if (from == myUid && outgoing == null) {
              outgoing = d;
            }
          }
          setState(() {
            _pendingIncoming = incoming;
            _pendingIncomingId = incomingId;
            _pendingOutgoing = outgoing;
          });
        });
  }

  void _startConfirmedPaymentsSubscription(String householdId, String myUid) {
    if (_confirmedPaymentsHouseholdId == householdId) return;
    _confirmedPaymentsSubscription?.cancel();
    _confirmedPaymentsHouseholdId = householdId;
    _confirmedPaymentsSubscription = FirebaseFirestore.instance
        .collection('households/$householdId/payments')
        .where('status', isEqualTo: 'confirmed')
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          var paidByMe = 0;
          var paidToMe = 0;
          for (final doc in snap.docs) {
            final d = doc.data();
            final cents = (d['amountCents'] as num?)?.toInt() ?? 0;
            final from = (d['fromUserId'] as String?)?.trim();
            final to = (d['toUserId'] as String?)?.trim();
            if (from == myUid) paidByMe += cents;
            if (to == myUid) paidToMe += cents;
          }
          setState(() {
            _confirmedPaidByMe = paidByMe;
            _confirmedPaidToMe = paidToMe;
          });
        });
  }

  void _startDashChildrenSubscription(String householdId) {
    if (householdId.isEmpty) return;
    if (_dashChildrenSubHouseholdId == householdId) return;
    _dashChildrenSubscription?.cancel();
    _dashChildrenSubHouseholdId = householdId;
    _dashChildrenSubscription = FirebaseFirestore.instance
        .collection('households/$householdId/children')
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          final kids = _activeChildItemsFromChildDocs(snap.docs);
          setState(() {
            _dashChildren = kids;
            _dashHasMultipleChildDocs = snap.docs.length >= 2;
            _dashChildrenHouseholdId = householdId;
          });
        });
  }

  void _stopDashChildrenSubscription() {
    _dashChildrenSubscription?.cancel();
    _dashChildrenSubscription = null;
    _dashChildrenSubHouseholdId = null;
    if (!mounted) return;
    if (_dashChildren.isEmpty && _dashChildrenHouseholdId == null) {
      return;
    }
    setState(() {
      _dashChildren = [];
      _dashHasMultipleChildDocs = true;
      _dashChildrenHouseholdId = null;
    });
  }

  Future<void> _loadScreenshotBlockingSetting() async {
    final enabled = await _loadScreenshotsBlockedPreference();
    if (!mounted) return;
    setState(() => _screenshotsBlocked = enabled);
  }

  Future<void> _setScreenshotBlockingSetting(bool enabled) async {
    await _saveScreenshotsBlockedPreference(enabled);
    await _applyScreenshotsBlockedPreference(enabled);
  }

  Future<void> _loadReopenLockSetting() async {
    final enabled = await _reopenLockService.loadEnabled();
    if (!mounted) return;
    setState(() => _reopenLockEnabled = enabled);
  }

  Future<ReopenLockAuthResult> _enableReopenLockWithCheck() async {
    final result = await _reopenLockService.authenticate(localizedReason: ' ');
    if (result.isAuthenticated) {
      await _reopenLockService.saveEnabled(true);
    }
    return result;
  }

  Future<void> _setReopenLockEnabled(bool enabled) async {
    await _reopenLockService.saveEnabled(enabled);
  }

  void _openPrivacySecuritySheet(BuildContext rootContext) {
    showModalBottomSheet<void>(
      context: rootContext,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(rootContext).scaffoldBackgroundColor,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            void updateScreenshotsBlocked(bool enabled) {
              setModalState(() => _screenshotsBlocked = enabled);
              unawaited(_setScreenshotBlockingSetting(enabled));
            }

            Future<void> updateReopenLock(bool enabled) async {
              if (_reopenLockBusy) {
                return;
              }

              setModalState(() => _reopenLockBusy = true);
              setState(() => _reopenLockBusy = true);

              if (!enabled) {
                await _setReopenLockEnabled(false);
                if (!mounted) {
                  return;
                }
                if (!context.mounted) {
                  setState(() {
                    _reopenLockEnabled = false;
                    _reopenLockBusy = false;
                  });
                  return;
                }
                setModalState(() {
                  _reopenLockEnabled = false;
                  _reopenLockBusy = false;
                });
                setState(() {
                  _reopenLockEnabled = false;
                  _reopenLockBusy = false;
                });
                return;
              }

              final result = await _enableReopenLockWithCheck();
              if (!mounted) {
                return;
              }

              final shouldEnable = result.isAuthenticated;
              if (!context.mounted) {
                setState(() {
                  _reopenLockEnabled = shouldEnable;
                  _reopenLockBusy = false;
                });
                return;
              }
              setModalState(() {
                _reopenLockEnabled = shouldEnable;
                _reopenLockBusy = false;
              });
              setState(() {
                _reopenLockEnabled = shouldEnable;
                _reopenLockBusy = false;
              });

              if (result.status == ReopenLockAuthStatus.unsupported) {
                _showSnackBar(
                  'Schermvergrendeling is niet beschikbaar op dit apparaat.',
                  duration: const Duration(seconds: 3),
                );
              }
            }

            return SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  left: _pagePadding,
                  right: _pagePadding,
                  top: 8,
                  bottom:
                      _pagePadding + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: KiduCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Privacy en beveiliging',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.4),
                        ),
                        const SizedBox(height: 12),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          visualDensity: VisualDensity.standard,
                          leading: Icon(
                            Icons.screenshot_monitor_outlined,
                            size: 18,
                            color: onSurface(context, a50),
                          ),
                          title: Text(
                            'Screenshots blokkeren',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: onSurface(context, a70)),
                          ),
                          subtitle: Text(
                            'Voorkomt screenshots waar dit door je toestel wordt ondersteund.',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: onSurface(context, a58)),
                          ),
                          trailing: Switch(
                            value: _screenshotsBlocked,
                            onChanged: updateScreenshotsBlocked,
                            thumbColor: WidgetStateProperty.resolveWith((
                              states,
                            ) {
                              if (states.contains(WidgetState.selected)) {
                                return Theme.of(
                                  context,
                                ).colorScheme.onSecondaryContainer;
                              }
                              return null;
                            }),
                            trackColor: WidgetStateProperty.resolveWith((
                              states,
                            ) {
                              if (states.contains(WidgetState.selected)) {
                                return Theme.of(
                                  context,
                                ).colorScheme.secondaryContainer;
                              }
                              return null;
                            }),
                          ),
                          onTap: () =>
                              updateScreenshotsBlocked(!_screenshotsBlocked),
                        ),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          visualDensity: VisualDensity.standard,
                          leading: Icon(
                            Icons.lock_outline,
                            size: 18,
                            color: onSurface(context, a50),
                          ),
                          title: Text(
                            'Vergrendelen bij heropenen',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: onSurface(context, a70)),
                          ),
                          subtitle: Text(
                            'Vraag schermvergrendeling, Face ID of vingerafdruk wanneer je terugkomt in KiDu.',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: onSurface(context, a58)),
                          ),
                          trailing: Switch(
                            value: _reopenLockEnabled,
                            onChanged: _reopenLockBusy
                                ? null
                                : updateReopenLock,
                            thumbColor: WidgetStateProperty.resolveWith((
                              states,
                            ) {
                              if (states.contains(WidgetState.selected)) {
                                return Theme.of(
                                  context,
                                ).colorScheme.onSecondaryContainer;
                              }
                              return null;
                            }),
                            trackColor: WidgetStateProperty.resolveWith((
                              states,
                            ) {
                              if (states.contains(WidgetState.selected)) {
                                return Theme.of(
                                  context,
                                ).colorScheme.secondaryContainer;
                              }
                              return null;
                            }),
                          ),
                          onTap: _reopenLockBusy
                              ? null
                              : () => unawaited(
                                  updateReopenLock(!_reopenLockEnabled),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _openSettingsPage({
    required String householdId,
    required String myUid,
    required String? otherName,
    required bool canInvite,
    required bool isCoParentLinked,
    String? myName,
  }) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _SettingsPage(
          dashboardMounted: () => mounted,
          householdId: householdId,
          myUid: myUid,
          otherName: otherName,
          isCoParentLinked: isCoParentLinked,
          myName: myName,
          openPrivacySecuritySheet: _openPrivacySecuritySheet,
          signOut: _signOut,
        ),
      ),
    );
  }

  /// Active (non-archived, non-deleted) children, sorted by [createdAt].
  static List<_ChildItem> _activeChildItemsFromChildDocs(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final filtered =
        docs
            .where(
              (d) =>
                  d.data()['isArchived'] != true &&
                  d.data()['isDeleted'] != true,
            )
            .toList()
          ..sort((a, b) {
            final aTs = a.data()['createdAt'];
            final bTs = b.data()['createdAt'];
            if (aTs is Timestamp && bTs is Timestamp) {
              return aTs.compareTo(bTs);
            }
            return 0;
          });
    return filtered
        .map(
          (d) => _ChildItem(
            id: d.id,
            name: (d.data()['name'] as String?)?.trim() ?? '?',
          ),
        )
        .toList();
  }

  /// Returns active (non-archived) children for the household, sorted by
  /// creation time. Returns empty list on any error so the dialog still opens.
  Future<List<_ChildItem>> _loadActiveChildren(String householdId) async {
    if (householdId.trim().isEmpty) return [];
    try {
      final snap = await FirebaseFirestore.instance
          .collection('households/$householdId/children')
          .get();
      return _activeChildItemsFromChildDocs(snap.docs);
    } catch (_) {
      return [];
    }
  }

  Future<_CreatedExpenseResult?> _createExpense({
    required String householdId,
    required String title,
    required int amountCents,
    String? note,
    String? coparentNameForPendingMessage,
    List<String>? childIds,
    bool sharePrivateNoteWithCoParent = false,
    ParentSplitSnapshot? parentSplitOverride,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return null;
    }

    try {
      final data = <String, dynamic>{
        'amountCents': amountCents,
        'currency': 'EUR',
        'title': title,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': uid,
        if (childIds != null && childIds.isNotEmpty) 'childIds': childIds,
      };

      // Parent-split snapshot for this NEW expense. Stale / invalid
      // household settings produce an EXPLICIT neutral 50/50 snapshot
      // for the actual 2 members (old bps is never reapplied to a
      // different uid). Solo / >2-member households receive no
      // snapshot and fall through to legacy 50/50 in the dashboard.
      var memberUidsForShare = <String>{};
      try {
        final memberSnap = await FirebaseFirestore.instance
            .collection('households/$householdId/members')
            .get();
        memberUidsForShare = memberSnap.docs.map((d) => d.id).toSet();
        ParentSplitSnapshot? snapshot;
        final o = parentSplitOverride;
        if (o != null &&
            memberUidsForShare.length == kParentSplitParticipantCount &&
            o.participantUids.length == kParentSplitParticipantCount &&
            o.participantUids.toSet().difference(memberUidsForShare).isEmpty) {
          snapshot = ParentSplitSnapshot.tryCreate(
            participantUids: o.participantUids,
            share0Bps: o.share0Bps,
          );
        }
        if (snapshot == null) {
          final defaults = await HouseholdSplitSettingsRepository().load(
            householdId,
          );
          snapshot = buildSnapshotForNewExpense(
            defaults: defaults,
            currentMemberUids: memberUidsForShare,
          );
        }
        if (snapshot != null) {
          data.addAll(snapshot.toExpenseFields());
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Split snapshot skipped (legacy 50/50 fallback): $e');
        }
      }

      final ref = await FirebaseFirestore.instance
          .collection('households/$householdId/expenses')
          .add(data);
      String? noteErrMsg;
      final noteTrimmed = note?.trim();
      if (noteTrimmed != null && noteTrimmed.isNotEmpty) {
        try {
          final noteData = <String, dynamic>{
            'note': noteTrimmed,
            'updatedAt': FieldValue.serverTimestamp(),
          };
          if (sharePrivateNoteWithCoParent) {
            final others = memberUidsForShare
                .where((id) => id != uid)
                .toList(growable: false);
            if (others.length == 1) {
              noteData['sharedWithUids'] = [others.single];
            }
          }
          await ref.collection('privateNotes').doc(uid).set(noteData);
        } catch (noteErr) {
          if (kDebugMode) debugPrint('Private note write error: $noteErr');
          noteErrMsg = mapUserFacingError(
            noteErr,
            fallback: 'notitie niet opgeslagen.',
          );
        }
      }
      final expenseSnap = await ref.get(const GetOptions(source: Source.cache));
      final isPending = expenseSnap.metadata.hasPendingWrites;
      if (isPending) {
        final naam = (coparentNameForPendingMessage?.trim().isNotEmpty ?? false)
            ? coparentNameForPendingMessage!.trim()
            : 'je co-parent';
        _showSnackBar(
          'Uitgave wordt opgeslagen en is pas zichtbaar voor $naam zodra je weer online bent.',
        );
      }
      return _CreatedExpenseResult(
        expenseId: ref.id,
        noteForRowFallback: noteErrMsg == null ? noteTrimmed : null,
        successSnackBarMessage: isPending
            ? null
            : (noteErrMsg != null ? 'Uitgave opgeslagen, $noteErrMsg' : null),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Create expense error: $e');
      rethrow;
    }
  }

  Future<List<String>?> _openAddExpenseChildSelectionDialog({
    required List<_ChildItem> children,
    List<String> initialSelectedChildIds = const [],
  }) async {
    final allChildIds = children.map((c) => c.id).toList(growable: false);
    return showDialog<List<String>>(
      context: context,
      useSafeArea: true,
      barrierDismissible: true,
      builder: (context) {
        var selectedChildIds = initialSelectedChildIds
            .where(allChildIds.contains)
            .toSet();
        return StatefulBuilder(
          builder: (context, setLocalState) {
            final selectedCount = selectedChildIds.length;
            final allSelected = selectedCount == allChildIds.length;
            final cs = Theme.of(context).colorScheme;
            final dialogBackground = cs.surfaceContainerHigh;
            final screenW = MediaQuery.sizeOf(context).width;
            final dialogW = (screenW - 80.0).clamp(280.0, 420.0);
            final modalHeight = min(
              520.0,
              MediaQuery.of(context).size.height - 36,
            );
            void dismissSelectionDialog() => Navigator.of(context).pop();
            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 24,
              ),
              child: SafeArea(
                child: Align(
                  alignment: const Alignment(0, -0.08),
                  child: SizedBox(
                    width: dialogW,
                    child: SizedBox(
                      height: modalHeight,
                      child: Material(
                        color: dialogBackground,
                        elevation: 3,
                        clipBehavior: Clip.antiAlias,
                        borderRadius: BorderRadius.circular(
                          _DashboardPageState._cardRadius,
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              _DashboardPageState._cardRadius,
                            ),
                            border: Border.all(color: outlineV(context, a40)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  0,
                                ),
                                child: Center(
                                  child: Container(
                                    width: 36,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: cs.outlineVariant.withValues(
                                        alpha: 0.85,
                                      ),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  16,
                                  16,
                                  0,
                                ),
                                child: kiduActionDialogTitle(
                                  context,
                                  'Kinderen selecteren',
                                ),
                              ),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    12,
                                    16,
                                    0,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      TextButton(
                                        onPressed: () => setLocalState(() {
                                          selectedChildIds = allSelected
                                              ? <String>{}
                                              : allChildIds.toSet();
                                        }),
                                        style: TextButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                          padding: EdgeInsets.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        child: Text(
                                          allSelected
                                              ? 'Alle deselecteren'
                                              : 'Alle selecteren',
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      SizedBox(
                                        height: 28,
                                        child: Align(
                                          alignment: Alignment.topLeft,
                                          child: Opacity(
                                            opacity: selectedCount == 0 ? 1 : 0,
                                            child: Text(
                                              'Selecteer minimaal 1 kind om verder te gaan',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    color: onSurface(
                                                      context,
                                                      a68,
                                                    ),
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: ListView.separated(
                                          padding: const EdgeInsets.only(
                                            top: 2,
                                            bottom: 4,
                                          ),
                                          itemCount: children.length,
                                          separatorBuilder: (_, _) => Divider(
                                            height: 1,
                                            thickness: 0.4,
                                            color: cs.outlineVariant.withValues(
                                              alpha: 0.45,
                                            ),
                                          ),
                                          itemBuilder: (context, index) {
                                            final child = children[index];
                                            final selected = selectedChildIds
                                                .contains(child.id);
                                            return Material(
                                              type: MaterialType.transparency,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                onTap: () {
                                                  setLocalState(() {
                                                    if (selected) {
                                                      selectedChildIds =
                                                          selectedChildIds
                                                              .where(
                                                                (id) =>
                                                                    id !=
                                                                    child.id,
                                                              )
                                                              .toSet();
                                                    } else {
                                                      selectedChildIds = {
                                                        ...selectedChildIds,
                                                        child.id,
                                                      };
                                                    }
                                                  });
                                                },
                                                child: ListTile(
                                                  dense: true,
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  minLeadingWidth: 32,
                                                  contentPadding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 2,
                                                        vertical: 0,
                                                      ),
                                                  leading: Checkbox(
                                                    value: selected,
                                                    visualDensity:
                                                        VisualDensity.compact,
                                                    activeColor: cs.primary
                                                        .withValues(alpha: a84),
                                                    checkColor: cs.surface,
                                                    side: BorderSide(
                                                      color: cs.outlineVariant
                                                          .withValues(
                                                            alpha: 0.85,
                                                          ),
                                                    ),
                                                    onChanged: (value) {
                                                      setLocalState(() {
                                                        if (value ?? false) {
                                                          selectedChildIds = {
                                                            ...selectedChildIds,
                                                            child.id,
                                                          };
                                                        } else {
                                                          selectedChildIds =
                                                              selectedChildIds
                                                                  .where(
                                                                    (id) =>
                                                                        id !=
                                                                        child
                                                                            .id,
                                                                  )
                                                                  .toSet();
                                                        }
                                                      });
                                                    },
                                                  ),
                                                  title: Text(
                                                    child.name,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodyMedium
                                                        ?.copyWith(
                                                          color: onSurface(
                                                            context,
                                                            a84,
                                                          ),
                                                        ),
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Container(
                                decoration: BoxDecoration(
                                  color: dialogBackground,
                                  border: Border(
                                    top: BorderSide(
                                      color: outlineV(context, a32),
                                    ),
                                  ),
                                ),
                                child: SafeArea(
                                  top: false,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      8,
                                      16,
                                      12,
                                    ),
                                    child: Row(
                                      children: [
                                        TextButton(
                                          onPressed: dismissSelectionDialog,
                                          child: const Text('Annuleren'),
                                        ),
                                        const Spacer(),
                                        FilledButton(
                                          style: kiduDialogPrimaryButtonStyle(
                                            context,
                                          ),
                                          onPressed: selectedCount == 0
                                              ? null
                                              : () => Navigator.of(context).pop(
                                                  children
                                                      .where(
                                                        (child) =>
                                                            selectedChildIds
                                                                .contains(
                                                                  child.id,
                                                                ),
                                                      )
                                                      .map((child) => child.id)
                                                      .toList(),
                                                ),
                                          child: const Text('Opslaan'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openAddExpenseDialog(
    String householdId, {
    String? coparentName,
    List<_ChildItem> children = const [],
  }) async {
    final titleController = TextEditingController();
    final amountController = TextEditingController();
    final noteController = TextEditingController();
    final titleFocusNode = FocusNode();
    final amountFocusNode = FocusNode();
    final allChildIds = children.map((c) => c.id).toList(growable: false);
    var saving = false;
    var didShow = false;
    String? pendingSuccessSnackBarMessage;
    var hasCustomChildSelection = false;
    var customSelectedChildIds = <String>[];
    var titleHasError = false;
    var amountHasError = false;
    _freezeExpensesVN.value = true;

    try {
      final shareUi = await _resolvePrivateNoteShareUiContext(householdId);
      if (!mounted) return;
      final String? coParentUidForShare = shareUi.coParentUid;

      ParentSplitSnapshot? initialPendingSplit;
      try {
        final memberSnap = await FirebaseFirestore.instance
            .collection('households/$householdId/members')
            .get();
        final memberUidsForShare = memberSnap.docs.map((d) => d.id).toSet();
        final defaults = await HouseholdSplitSettingsRepository().load(
          householdId,
        );
        initialPendingSplit = buildSnapshotForNewExpense(
          defaults: defaults,
          currentMemberUids: memberUidsForShare,
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Add expense: initial split load skipped: $e');
        }
      }
      var pendingSplit = initialPendingSplit;

      if (!mounted) return;
      didShow = true;
      var sharePrivateNoteWithCoParent = false;
      await showDialog<void>(
        context: context,
        useSafeArea: true,
        barrierDismissible: false,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setLocalState) {
              final effectiveSelectedChildIds = hasCustomChildSelection
                  ? customSelectedChildIds
                  : allChildIds;
              final screenW = MediaQuery.sizeOf(context).width;
              final dialogContentW = (screenW - 80.0).clamp(280.0, 320.0);
              final textTheme = Theme.of(context).textTheme;
              final subtleErrorHintStyle = Theme.of(context).textTheme.bodySmall
                  ?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.error.withValues(alpha: 0.85),
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  );
              final subtleErrorInputStyle = Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.error.withValues(alpha: 0.88),
                    fontWeight: FontWeight.w400,
                  );
              final metaLabelStyle = textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w400,
                color: onSurface(context, a84),
              );
              final metaValueStyle = textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: onSurface(context, a84),
              );
              final metaActionStyle = TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              );
              final childSelectionSummary =
                  !hasCustomChildSelection ||
                      effectiveSelectedChildIds.length == children.length
                  ? 'Alle kinderen'
                  : '${effectiveSelectedChildIds.length} van ${children.length} geselecteerd';
              return Material(
                color: Colors.transparent,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          final keyboardVisible =
                              MediaQuery.of(context).viewInsets.bottom > 0;
                          if (keyboardVisible) {
                            FocusManager.instance.primaryFocus?.unfocus();
                            return;
                          }
                          if (!context.mounted) return;
                          Navigator.of(context).pop();
                        },
                        child: const SizedBox.expand(),
                      ),
                    ),
                    Align(
                      alignment: const Alignment(0, -0.15),
                      child: SizedBox(
                        width: dialogContentW,
                        child: AlertDialog(
                          insetPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 24,
                          ),
                          title: kiduActionDialogTitle(
                            context,
                            'Nieuwe uitgave',
                          ),
                          content: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight:
                                  MediaQuery.of(context).size.height * 0.55,
                            ),
                            child: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: titleController,
                                    focusNode: titleFocusNode,
                                    autofocus: true,
                                    textCapitalization:
                                        TextCapitalization.sentences,
                                    textInputAction: TextInputAction.next,
                                    maxLength: _kAddExpenseTitleMaxLength,
                                    onTap: () {
                                      if (titleHasError) {
                                        setLocalState(
                                          () => titleHasError = false,
                                        );
                                      }
                                    },
                                    onChanged: (_) {
                                      if (titleHasError) {
                                        setLocalState(
                                          () => titleHasError = false,
                                        );
                                      }
                                    },
                                    buildCounter:
                                        (
                                          context, {
                                          required int currentLength,
                                          required bool isFocused,
                                          required int? maxLength,
                                        }) => null,
                                    decoration: kiduCompactInputDecoration(
                                      labelText: 'Titel',
                                      hintText: titleHasError
                                          ? 'Vul een titel in'
                                          : null,
                                    ).copyWith(
                                      floatingLabelBehavior:
                                          FloatingLabelBehavior.always,
                                      border: const OutlineInputBorder(),
                                      hintStyle: titleHasError
                                          ? subtleErrorHintStyle
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: amountController,
                                    focusNode: amountFocusNode,
                                    style: amountHasError
                                        ? subtleErrorInputStyle
                                        : null,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    onTap: () {
                                      if (amountHasError) {
                                        setLocalState(
                                          () => amountHasError = false,
                                        );
                                      }
                                    },
                                    onChanged: (value) {
                                      final trimmed = value.trim();
                                      final parsed = _tryParseEurToCents(value);
                                      final nextHasError =
                                          trimmed.isNotEmpty &&
                                          (parsed == null || parsed < 0);
                                      if (amountHasError != nextHasError) {
                                        setLocalState(
                                          () => amountHasError = nextHasError,
                                        );
                                      }
                                    },
                                    decoration: kiduCompactInputDecoration(
                                      labelText: 'Bedrag (EUR)',
                                      hintText: amountHasError
                                          ? 'Vul een geldig bedrag in'
                                          : 'Bijv. 12,34',
                                    ).copyWith(
                                      floatingLabelBehavior:
                                          FloatingLabelBehavior.always,
                                      border: const OutlineInputBorder(),
                                      hintStyle: amountHasError
                                          ? subtleErrorHintStyle
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: noteController,
                                    textCapitalization:
                                        TextCapitalization.sentences,
                                    maxLength: 180,
                                    textInputAction: TextInputAction.done,
                                    onChanged: (text) {
                                      if (text.trim().isEmpty &&
                                          sharePrivateNoteWithCoParent) {
                                        setLocalState(
                                          () => sharePrivateNoteWithCoParent =
                                              false,
                                        );
                                      } else {
                                        setLocalState(() {});
                                      }
                                    },
                                    buildCounter:
                                        (
                                          context, {
                                          required int currentLength,
                                          required bool isFocused,
                                          required int? maxLength,
                                        }) => null,
                                    decoration: kiduCompactInputDecoration(
                                      labelText: 'Notitie (optioneel)',
                                    ).copyWith(
                                      floatingLabelBehavior:
                                          FloatingLabelBehavior.always,
                                      border: const OutlineInputBorder(),
                                    ),
                                  ),
                                  if (coParentUidForShare != null) ...[
                                    SwitchListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text(
                                        'Notitie delen',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      value:
                                          sharePrivateNoteWithCoParent &&
                                          noteController.text.trim().isNotEmpty,
                                      onChanged:
                                          noteController.text.trim().isEmpty
                                          ? null
                                          : (v) => setLocalState(
                                              () =>
                                                  sharePrivateNoteWithCoParent =
                                                      v,
                                            ),
                                    ),
                                  ],
                                  // Child selection stays out of the main dialog for
                                  // 2+ children so the form remains compact.
                                  if (children.length > 1) ...[
                                    const SizedBox(height: 12),
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Voor:',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.labelMedium,
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                childSelectionSummary,
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.bodyMedium,
                                              ),
                                            ),
                                            TextButton(
                                              onPressed: saving
                                                  ? null
                                                  : () async {
                                                      FocusManager
                                                          .instance
                                                          .primaryFocus
                                                          ?.unfocus();
                                                      final pickedChildIds =
                                                          await _openAddExpenseChildSelectionDialog(
                                                            children: children,
                                                            initialSelectedChildIds:
                                                                hasCustomChildSelection
                                                                ? customSelectedChildIds
                                                                : allChildIds,
                                                          );
                                                      if (pickedChildIds ==
                                                              null ||
                                                          !context.mounted) {
                                                        return;
                                                      }
                                                      setLocalState(() {
                                                        if (pickedChildIds
                                                                .length ==
                                                            children.length) {
                                                          hasCustomChildSelection =
                                                              false;
                                                          customSelectedChildIds =
                                                              [];
                                                        } else {
                                                          hasCustomChildSelection =
                                                              true;
                                                          customSelectedChildIds =
                                                              pickedChildIds;
                                                        }
                                                      });
                                                    },
                                              style: TextButton.styleFrom(
                                                visualDensity:
                                                    VisualDensity.compact,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                    ),
                                                tapTargetSize:
                                                    MaterialTapTargetSize
                                                        .shrinkWrap,
                                              ),
                                              child: const Text('Selectie'),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ],
                                  if (pendingSplit != null)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 12,
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text.rich(
                                              TextSpan(
                                                children: [
                                                  TextSpan(
                                                    text: 'Verdeling: ',
                                                    style: metaLabelStyle,
                                                  ),
                                                  TextSpan(
                                                    text:
                                                        _formatParentSplitCompact(
                                                          pendingSplit!,
                                                          FirebaseAuth
                                                              .instance
                                                              .currentUser
                                                              ?.uid,
                                                        ),
                                                    style: metaValueStyle,
                                                  ),
                                                ],
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: saving
                                                ? null
                                                : () async {
                                                    FocusManager
                                                        .instance
                                                        .primaryFocus
                                                        ?.unfocus();
                                                    if (!context.mounted) {
                                                      return;
                                                    }
                                                    final ps = pendingSplit;
                                                    if (ps == null) return;
                                                    final members =
                                                        await _loadParentSplitMembers(
                                                          householdId,
                                                        );
                                                    if (members.length !=
                                                            kParentSplitParticipantCount ||
                                                        !context.mounted) {
                                                      return;
                                                    }
                                                    final picked =
                                                        await showDialog<
                                                          ParentSplitSnapshot
                                                        >(
                                                          context: context,
                                                          builder: (_) =>
                                                              _RecurringParentSplitDialog(
                                                                members:
                                                                    members,
                                                                initialSnapshot:
                                                                    ps,
                                                                viewerUid:
                                                                    FirebaseAuth
                                                                        .instance
                                                                        .currentUser
                                                                        ?.uid,
                                                                contextFooterText:
                                                                    'Deze verdeling hoort alleen bij deze uitgave.',
                                                                minShareBps: 0,
                                                                maxShareBps:
                                                                    kBpsFull,
                                                              ),
                                                        );
                                                    if (picked != null &&
                                                        context.mounted) {
                                                      setLocalState(
                                                        () => pendingSplit =
                                                            picked,
                                                      );
                                                    }
                                                  },
                                            style: metaActionStyle,
                                            child: const Text('Wijzigen'),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          actionsPadding: const EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            12,
                          ),
                          actionsAlignment: MainAxisAlignment.spaceBetween,
                          actions: [
                            TextButton(
                              onPressed: saving
                                  ? null
                                  : () => Navigator.of(context).pop(),
                              child: const Text('Annuleren'),
                            ),
                            FilledButton(
                              style: kiduDialogPrimaryButtonStyle(context),
                              onPressed: saving
                                  ? null
                                  : () async {
                                      final title = titleController.text.trim();
                                      final amountCents = _tryParseEurToCents(
                                        amountController.text,
                                      );
                                      final titleInvalid = title.isEmpty;
                                      final amountInvalid =
                                          amountCents == null ||
                                          amountCents <= 0;
                                      if (titleInvalid || amountInvalid) {
                                        setLocalState(() {
                                          titleHasError = titleInvalid;
                                          amountHasError = amountInvalid;
                                        });
                                        if (titleInvalid) {
                                          titleFocusNode.requestFocus();
                                        } else if (amountInvalid) {
                                          amountFocusNode.requestFocus();
                                        }
                                        return;
                                      }
                                      if (effectiveSelectedChildIds.isEmpty) {
                                        _showSnackBar(
                                          'Selecteer minimaal één kind.',
                                        );
                                        return;
                                      }

                                      setLocalState(() => saving = true);
                                      if (!await _checkCanWriteNow()) {
                                        _showSnackBar(
                                          'Je bent offline. Uitgave niet opgeslagen. Verbind met internet en probeer opnieuw.',
                                        );
                                        if (context.mounted) {
                                          setLocalState(() => saving = false);
                                        }
                                        return;
                                      }
                                      try {
                                        final savedAt = DateTime.now();
                                        final createResult =
                                            await _createExpense(
                                              householdId: householdId,
                                              title: title,
                                              amountCents: amountCents,
                                              note:
                                                  noteController.text
                                                      .trim()
                                                      .isEmpty
                                                  ? null
                                                  : noteController.text.trim(),
                                              coparentNameForPendingMessage:
                                                  coparentName,
                                              childIds:
                                                  effectiveSelectedChildIds,
                                              sharePrivateNoteWithCoParent:
                                                  coParentUidForShare != null &&
                                                  sharePrivateNoteWithCoParent &&
                                                  noteController.text
                                                      .trim()
                                                      .isNotEmpty,
                                              parentSplitOverride: pendingSplit,
                                            );
                                        if (mounted && createResult != null) {
                                          setState(() {
                                            _pendingExpenseRowFallback =
                                                _PendingExpenseRowFallback(
                                                  expenseId:
                                                      createResult.expenseId,
                                                  savedAt: savedAt,
                                                  note: createResult
                                                      .noteForRowFallback,
                                                );
                                          });
                                          pendingSuccessSnackBarMessage =
                                              createResult
                                                  .successSnackBarMessage;
                                        }
                                        if (context.mounted) {
                                          Navigator.of(context).pop();
                                        }
                                      } catch (e) {
                                        debugPrint(
                                          'Create expense (dialog) error: $e',
                                        );
                                        _showSnackBar(
                                          mapUserFacingError(
                                            e,
                                            fallback:
                                                'Opslaan mislukt. Probeer opnieuw.',
                                          ),
                                        );
                                      } finally {
                                        if (context.mounted) {
                                          setLocalState(() => saving = false);
                                        }
                                      }
                                    },
                              child: SizedBox(
                                width: 82,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    const Text('Opslaan'),
                                    if (saving)
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSecondaryContainer,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    } finally {
      if (mounted && didShow) {
        // Wait for the dialog pop animation to finish before unfreezing
        // the expenses list, so the dashboard stays stable during the
        // transition.
        await Future<void>.delayed(kThemeAnimationDuration);
      }
      if (mounted) {
        _freezeExpensesVN.value = false;
        if (pendingSuccessSnackBarMessage != null) {
          await WidgetsBinding.instance.endOfFrame;
          if (mounted) {
            _showSnackBar(
              pendingSuccessSnackBarMessage!,
              duration: const Duration(milliseconds: 2200),
            );
          }
        }
      }
      titleController.dispose();
      amountController.dispose();
      noteController.dispose();
      titleFocusNode.dispose();
      amountFocusNode.dispose();
    }
  }

  Future<void> ensureUserDoc() async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) {
        return;
      }
      final uid = currentUser.uid;
      final docRef = FirebaseFirestore.instance.doc('users/$uid');
      final snapshot = await docRef.get();

      final data = {
        'displayName': currentUser.displayName,
        'email': currentUser.email,
        'photoUrl': currentUser.photoURL,
        'updatedAt': FieldValue.serverTimestamp(),
        if (!snapshot.exists) 'createdAt': FieldValue.serverTimestamp(),
      };

      await docRef.set(data, SetOptions(merge: true));
    } catch (e) {
      debugPrint('ensureUserDoc error: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadScreenshotBlockingSetting());
    unawaited(_loadReopenLockSetting());
    ensureUserDoc();
  }

  @override
  void dispose() {
    widget.onPreviewReadyChanged?.call(false);
    _dashChildrenSubscription?.cancel();
    _settlementsSubscription?.cancel();
    _paymentsSubscription?.cancel();
    _confirmedPaymentsSubscription?.cancel();
    _addExpenseCheckBusyVN.dispose();
    _freezeExpensesVN.dispose();
    _addExpenseDialogOpenVN.dispose();
    super.dispose();
  }

  Future<void> _startSetup({bool silent = false}) async {
    if (!silent && _setupBusy) {
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return;
    }

    if (!silent) setState(() => _setupBusy = true);

    try {
      await _kiduEnsureHouseholdForCurrentUserIfNeeded();
    } catch (e) {
      if (kDebugMode) debugPrint('Start setup error: $e');
      if (silent) {
        rethrow;
      } else {
        _showSnackBar(
          mapUserFacingError(e, fallback: 'Setup mislukt. Probeer opnieuw.'),
        );
      }
    } finally {
      if (!silent && mounted) {
        setState(() => _setupBusy = false);
      }
    }
  }

  String _randomInviteCode(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = Random.secure();
    return List.generate(
      length,
      (_) => chars[rnd.nextInt(chars.length)],
    ).join();
  }

  Future<String?> _generateInvite(
    String householdId, {
    bool silent = false,
  }) async {
    if (!silent && _inviteBusy) {
      return null;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return null;
    }

    if (!silent) setState(() => _inviteBusy = true);

    try {
      final firestore = FirebaseFirestore.instance;

      final membersSnap = await firestore
          .collection('households/$householdId/members')
          .limit(2)
          .get();
      if (membersSnap.size >= 2) {
        if (!silent) _showSnackBar('Household is al vol.');
        return null;
      }

      String? createdCode;
      Object? lastError;

      for (var attempt = 0; attempt < 6; attempt++) {
        final code = _randomInviteCode(8);
        final inviteRef = firestore.collection('invites').doc(code);

        try {
          await firestore.runTransaction((transaction) async {
            final snap = await transaction.get(inviteRef);
            if (snap.exists) {
              throw StateError('Invite code collision');
            }
            transaction.set(inviteRef, {
              'householdId': householdId,
              'createdBy': uid,
              'createdAt': FieldValue.serverTimestamp(),
              'usedBy': null,
            });
          });

          createdCode = code;
          break;
        } catch (e) {
          lastError = e;
        }
      }

      if (createdCode == null) {
        if (kDebugMode) debugPrint('Generate invite error: $lastError');
        if (!silent) {
          _showSnackBar('Invite code genereren mislukt. Probeer opnieuw.');
        }
        return null;
      }

      return createdCode;
    } catch (e) {
      if (kDebugMode) debugPrint('Generate invite error: $e');
      if (!silent) {
        _showSnackBar('Invite code genereren mislukt. Probeer opnieuw.');
      }
      return null;
    } finally {
      if (!silent && mounted) {
        setState(() => _inviteBusy = false);
      }
    }
  }

  Future<void> _shareInviteCode(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      _showSnackBar('Geen invite code beschikbaar.');
      return;
    }
    try {
      final text =
          'Koppel met mij in KiDu.\nGebruik deze invite code: $trimmed';
      await Share.share(text);
    } catch (_) {
      _showSnackBar('Delen mislukt. Probeer opnieuw.');
    }
  }

  Future<void> _openInviteSheetFlow(String householdIdStr) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    var started = false;
    var loading = true;
    var waiting = false;
    String? code;
    String? error;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      isDismissible: true,
      enableDrag: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setModalState) {
            if (!started) {
              started = true;
              Future.microtask(() async {
                String effectiveHouseholdId = householdIdStr.trim();
                try {
                  if (effectiveHouseholdId.isEmpty) {
                    await _startSetup(silent: true);
                    if (!sheetContext.mounted) return;
                    for (var i = 0; i < 10; i++) {
                      final userSnap = await FirebaseFirestore.instance
                          .doc('users/$uid')
                          .get();
                      final data = userSnap.data();
                      effectiveHouseholdId =
                          (data?['householdId'] as String?)?.trim() ?? '';
                      if (effectiveHouseholdId.isNotEmpty) break;
                      await Future<void>.delayed(
                        const Duration(milliseconds: 200),
                      );
                      if (!sheetContext.mounted) return;
                    }
                  }

                  if (effectiveHouseholdId.isEmpty) {
                    if (!sheetContext.mounted) return;
                    setModalState(() {
                      loading = false;
                      error = 'Kon geen code maken. Probeer opnieuw.';
                    });
                    return;
                  }

                  final generated = await _generateInvite(
                    effectiveHouseholdId,
                    silent: true,
                  );
                  if (!sheetContext.mounted) return;

                  final c = generated?.trim();
                  if (c == null || c.isEmpty) {
                    setModalState(() {
                      loading = false;
                      error = 'Kon geen code maken. Probeer opnieuw.';
                    });
                    return;
                  }

                  setModalState(() {
                    code = c;
                    loading = false;
                    error = null;
                  });
                } catch (_) {
                  if (!sheetContext.mounted) return;
                  setModalState(() {
                    loading = false;
                    error = 'Kon geen code maken. Probeer opnieuw.';
                  });
                }
              });
            }

            Widget buildInviteCodeContent() {
              if (loading || code != null) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Uitnodigingscode',
                      style: Theme.of(sheetContext).textTheme.titleMedium
                          ?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                    ),
                    const SizedBox(height: 8),
                    KiduCodePill(
                      code: code ?? '',
                      loading: loading,
                      codeFontWeight: FontWeight.w600,
                      onCopy: () async {
                        await Clipboard.setData(ClipboardData(text: code!));
                      },
                    ),
                    const SizedBox(height: 16),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        if (loading) return;
                        _shareInviteCode(code!);
                      },
                      icon: const Icon(Icons.share_outlined, size: 18),
                      label: Text(
                        'Delen',
                        style: Theme.of(sheetContext).textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        if (loading) return;
                        setModalState(() => waiting = true);
                      },
                      icon: const Icon(Icons.check, size: 18),
                      label: Text(
                        'Code gedeeld',
                        style: Theme.of(sheetContext).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                );
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Uitnodigingscode',
                    style: Theme.of(sheetContext).textTheme.titleMedium
                        ?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    error ?? 'Kon geen code maken. Probeer opnieuw.',
                    style: Theme.of(sheetContext).textTheme.bodyMedium
                        ?.copyWith(color: onSurface(sheetContext, a68)),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      setModalState(() {
                        started = false;
                        loading = true;
                        code = null;
                        error = null;
                      });
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(
                      'Opnieuw',
                      style: Theme.of(sheetContext).textTheme.bodyMedium,
                    ),
                  ),
                ],
              );
            }

            Widget buildWaitingContent() {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Wachten op co-parent',
                    style: Theme.of(sheetContext).textTheme.titleMedium
                        ?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Je hebt de code gedeeld.\nZodra je co-parent koppelt, verschijnt het gedeelde overzicht automatisch.',
                    style: Theme.of(sheetContext).textTheme.bodyMedium
                        ?.copyWith(color: onSurface(sheetContext, a68)),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                    },
                    icon: const Icon(Icons.dashboard_outlined, size: 18),
                    label: Text(
                      'Terug naar dashboard',
                      style: Theme.of(sheetContext).textTheme.bodyMedium,
                    ),
                  ),
                ],
              );
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: _pagePadding,
                  right: _pagePadding,
                  top: 8,
                  bottom:
                      _pagePadding +
                      MediaQuery.of(sheetContext).viewInsets.bottom,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: KiduCard(
                    child: waiting
                        ? Stack(
                            children: [
                              IgnorePointer(
                                child: Visibility(
                                  visible: false,
                                  maintainState: true,
                                  maintainAnimation: true,
                                  maintainSize: true,
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: buildInviteCodeContent(),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: double.infinity,
                                child: buildWaitingContent(),
                              ),
                            ],
                          )
                        : buildInviteCodeContent(),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _signOut(BuildContext context) async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // Google was mogelijk al uitgelogd — negeren
    }

    if (!context.mounted) {
      return;
    }
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthGate()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _reportPreviewReady(false);
      // Avoid endless spinner if auth state flips during navigation/sign-out.
      return const AuthGate();
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.doc('users/${user.uid}').snapshots(),
      initialData: widget.initialUserSnapshot,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          _reportPreviewReady(true);
          return Scaffold(
            resizeToAvoidBottomInset: false,
            appBar: AppBar(
              centerTitle: true,
              title: Text(
                'KiDu',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
              actions: [
                IconButton(
                  onPressed: () => _openSettingsPage(
                    householdId: '',
                    myUid: user.uid,
                    otherName: null,
                    canInvite: false,
                    isCoParentLinked: false,
                    myName: null,
                  ),
                  icon: const Icon(Icons.settings_rounded),
                  tooltip: 'Instellingen',
                ),
              ],
            ),
            body: SafeArea(
              child: Center(
                child: Text(
                  'Kon accountgegevens niet laden.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: onSurface(context, a62),
                    height: 1.35,
                  ),
                ),
              ),
            ),
          );
        }
        // Do not treat ConnectionState.waiting as loading when [initialData] is
        // present — Firestore keeps waiting until the first snapshot event.
        if (!snapshot.hasData) {
          _reportPreviewReady(false);
          return Scaffold(
            resizeToAvoidBottomInset: false,
            appBar: AppBar(
              centerTitle: true,
              title: Text(
                'KiDu',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            body: const SafeArea(
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        final data = snapshot.data!.data();
        final myProfileName = (data?['profileName'] as String?)?.trim();

        if (myProfileName == null || myProfileName.isEmpty) {
          _reportPreviewReady(true);
          return Scaffold(
            resizeToAvoidBottomInset: false,
            appBar: AppBar(
              centerTitle: true,
              title: Text(
                'KiDu',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
              actions: [
                IconButton(
                  onPressed: () => _openSettingsPage(
                    householdId: '',
                    myUid: user.uid,
                    otherName: null,
                    canInvite: false,
                    isCoParentLinked: false,
                    myName: null,
                  ),
                  icon: const Icon(Icons.settings_rounded),
                  tooltip: 'Instellingen',
                ),
              ],
            ),
            floatingActionButton: null,
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.of(context).viewInsets.bottom,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: IntrinsicHeight(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            _pagePadding,
                            24,
                            _pagePadding,
                            _pagePadding,
                          ),
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: const _DashboardOnboardingNameCard(),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        }

        final householdId = (data?['householdId'] as String?)?.trim();
        final hasHousehold =
            householdId != null && householdId.trim().isNotEmpty;

        final myFallbackName = myProfileName;

        final householdIdStr = hasHousehold ? householdId.trim() : '';

        if (householdIdStr.isNotEmpty) {
          Future.microtask(
            () => _startDashChildrenSubscription(householdIdStr),
          );
        } else if (_dashChildrenSubHouseholdId != null) {
          Future.microtask(_stopDashChildrenSubscription);
        }
        if (householdIdStr.isNotEmpty) {
          Future.microtask(
            () => _startSettlementsSubscription(householdIdStr, user.uid),
          );
          Future.microtask(
            () => _startPaymentsSubscription(householdIdStr, user.uid),
          );
          Future.microtask(
            () => _startConfirmedPaymentsSubscription(householdIdStr, user.uid),
          );
        }

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>?>(
          stream: hasHousehold
              ? FirebaseFirestore.instance
                    .collection('households/$householdIdStr/members')
                    .limit(2)
                    .snapshots()
              : Stream.value(null),
          builder: (context, membersSnapshot) {
            // Avoid full-screen loading here: while members are resolving, keep
            // the normal dashboard subtree (invite flow) instead of replacing the
            // scaffold with a spinner (jank when household first appears).
            if (hasHousehold && membersSnapshot.hasError) {
              _reportPreviewReady(true);
              return Scaffold(
                resizeToAvoidBottomInset: false,
                appBar: AppBar(
                  centerTitle: true,
                  title: Text(
                    'KiDu',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                body: SafeArea(
                  child: Center(
                    child: Text(
                      'Kon koppeling niet laden.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: onSurface(context, a62),
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              );
            }

            final membersAwaitingFirstSnapshot =
                hasHousehold &&
                !membersSnapshot.hasData &&
                !membersSnapshot.hasError;

            final memberDocs = hasHousehold && membersSnapshot.hasData
                ? membersSnapshot.data!.docs
                : <QueryDocumentSnapshot<Map<String, dynamic>>>[];
            final memberCount = memberDocs.length;

            String? otherUid;
            for (final d in memberDocs) {
              if (d.id != user.uid) {
                otherUid = d.id;
                break;
              }
            }

            final canInvite = membersAwaitingFirstSnapshot || memberCount == 1;
            final canAddExpenses =
                otherUid != null && otherUid.trim().isNotEmpty;
            final showsPendingSoloPreview =
                !canAddExpenses && membersAwaitingFirstSnapshot;
            final showsStableSoloDashboard =
                !canAddExpenses && !membersAwaitingFirstSnapshot;
            final myDashboardName = myProfileName;

            // While the first members snapshot is pending, keep the same ungekoppeld
            // subtree as when docs=1 (avoids a full-screen spinner flash when
            // householdId first appears, e.g. behind the invite bottom sheet).

            if (showsPendingSoloPreview || showsStableSoloDashboard) {
              _reportPreviewReady(showsStableSoloDashboard);
              return Scaffold(
                resizeToAvoidBottomInset: false,
                appBar: AppBar(
                  centerTitle: true,
                  title: Text(
                    'KiDu',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                  actions: [
                    IconButton(
                      onPressed: () => _openSettingsPage(
                        householdId: householdIdStr,
                        myUid: user.uid,
                        otherName: 'Co-parent',
                        canInvite: canInvite,
                        isCoParentLinked: false,
                        myName: myProfileName,
                      ),
                      icon: const Icon(Icons.settings_rounded),
                      tooltip: 'Instellingen',
                    ),
                  ],
                ),
                floatingActionButton: null,
                body: SafeArea(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        padding: EdgeInsets.only(
                          bottom: MediaQuery.of(context).viewInsets.bottom,
                        ),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight,
                          ),
                          child: IntrinsicHeight(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                _pagePadding,
                                24,
                                _pagePadding,
                                _pagePadding,
                              ),
                              child: Stack(
                                children: [
                                  Align(
                                    alignment: Alignment.topCenter,
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 520,
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          KiduCard(
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                Text(
                                                  'Welkom $myDashboardName',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleMedium
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  'Alles staat klaar om samen te beginnen.',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: onSurface(
                                                          context,
                                                          a62,
                                                        ),
                                                        height: 1.35,
                                                      ),
                                                ),
                                                const SizedBox(height: 26),
                                                SizedBox(
                                                  height: 38,
                                                  child: ElevatedButton(
                                                    onPressed:
                                                        (_inviteBusy ||
                                                            _setupBusy)
                                                        ? null
                                                        : () async {
                                                            if (_inviteSheetOpening) {
                                                              return;
                                                            }
                                                            HapticFeedback.selectionClick();
                                                            _inviteSheetOpening =
                                                                true;
                                                            try {
                                                              await _openInviteSheetFlow(
                                                                householdIdStr,
                                                              );
                                                            } finally {
                                                              if (mounted) {
                                                                _inviteSheetOpening =
                                                                    false;
                                                              }
                                                            }
                                                          },
                                                    child: const Text(
                                                      'Uitnodigen',
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                SizedBox(
                                                  height: 38,
                                                  child: OutlinedButton(
                                                    onPressed: () {
                                                      Navigator.of(
                                                        context,
                                                      ).push(
                                                        MaterialPageRoute(
                                                          builder: (_) =>
                                                              const SetupPage(),
                                                        ),
                                                      );
                                                    },
                                                    child: const Text(
                                                      'Code invoeren',
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: Opacity(
                                      opacity: 0.52,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          top: 16,
                                          bottom: 4,
                                        ),
                                        child: Center(
                                          child: DefaultTextStyle(
                                            style:
                                                Theme.of(context)
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: onSurface(
                                                        context,
                                                        a45,
                                                      ),
                                                    ) ??
                                                TextStyle(
                                                  fontSize: 12,
                                                  color: onSurface(
                                                    context,
                                                    a45,
                                                  ),
                                                ),
                                            child: Wrap(
                                              alignment: WrapAlignment.center,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: [
                                                GestureDetector(
                                                  behavior:
                                                      HitTestBehavior.opaque,
                                                  onTap: () =>
                                                      _showAboutKiduDialog(
                                                        context,
                                                      ),
                                                  child: const Text(
                                                    'Over KiDu',
                                                  ),
                                                ),
                                                const Text(' · '),
                                                GestureDetector(
                                                  behavior:
                                                      HitTestBehavior.opaque,
                                                  onTap: () =>
                                                      _showPrivacyPolicyDialog(
                                                        context,
                                                      ),
                                                  child: const Text(
                                                    'Privacybeleid',
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              );
            }

            final namesFuture = _getNamesFuture(
              householdId: householdIdStr,
              myUid: user.uid,
              otherUid: otherUid,
              myFallback: myFallbackName,
              otherFallback: 'Co-parent',
            );

            return FutureBuilder<Map<String, String>>(
              future: namesFuture,
              builder: (context, namesSnapshot) {
                final names = namesSnapshot.data ?? const <String, String>{};
                final myName = myFallbackName;
                final otherName = otherUid == null
                    ? 'Co-parent'
                    : (names[otherUid] ?? 'Co-parent');

                return Scaffold(
                  resizeToAvoidBottomInset: false,
                  appBar: AppBar(
                    centerTitle: true,
                    title: Text(
                      'KiDu',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                    actions: canAddExpenses
                        ? [
                            IconButton(
                              onPressed: () => _openSettingsPage(
                                householdId: householdIdStr,
                                myUid: user.uid,
                                otherName: otherName,
                                canInvite: canInvite,
                                isCoParentLinked: canAddExpenses,
                                myName: myProfileName,
                              ),
                              icon: const Icon(Icons.settings_rounded),
                              tooltip: 'Instellingen',
                            ),
                          ]
                        : [],
                  ),
                  floatingActionButtonLocation:
                      FloatingActionButtonLocation.centerFloat,
                  floatingActionButton: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: SizedBox(
                      width: MediaQuery.of(context).size.width - 48,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          FloatingActionButton.small(
                            heroTag: 'logboek_fab',
                            // Zelfde route-lokale fade als bij
                            // _TerugkerendeKostenPage: maskeert swipe-back /
                            // predictive-back jank op deze route en maakt
                            // openen/sluiten visueel consistent met
                            // 'Maandelijkse uitgaven'.
                            onPressed: () => Navigator.of(context).push<void>(
                              PageRouteBuilder<void>(
                                pageBuilder:
                                    (context, animation, secondaryAnimation) =>
                                        _LogboekPage(
                                          householdId: householdIdStr,
                                          uid: user.uid,
                                          myName: myName,
                                          otherName: otherName,
                                        ),
                                transitionDuration: const Duration(
                                  milliseconds: 180,
                                ),
                                reverseTransitionDuration: const Duration(
                                  milliseconds: 180,
                                ),
                                transitionsBuilder:
                                    (
                                      context,
                                      animation,
                                      secondaryAnimation,
                                      child,
                                    ) => FadeTransition(
                                      opacity: animation,
                                      child: child,
                                    ),
                              ),
                            ),
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                            elevation: 3,
                            tooltip: 'Logboek',
                            child: const Icon(Icons.menu_book, size: 20),
                          ),
                          if (canAddExpenses)
                            ValueListenableBuilder<bool>(
                              valueListenable: _addExpenseDialogOpenVN,
                              builder: (context, dialogOpen, _) {
                                return ValueListenableBuilder<bool>(
                                  valueListenable: _addExpenseCheckBusyVN,
                                  builder: (context, fabBusy, _) {
                                    final bool addExpenseBusy =
                                        dialogOpen ||
                                        fabBusy ||
                                        _setupBusy ||
                                        _inviteBusy;

                                    return FloatingActionButton(
                                      heroTag: 'add_expense_fab',
                                      onPressed: addExpenseBusy
                                          ? null
                                          : () async {
                                              if (_addExpenseCheckBusyVN
                                                      .value ||
                                                  _addExpenseDialogOpenVN
                                                      .value) {
                                                return;
                                              }
                                              // Capture before any awaits so the
                                              // local builder context isn't used
                                              // across async gaps.
                                              final messenger =
                                                  ScaffoldMessenger.of(context);
                                              final nav = Navigator.of(context);
                                              _addExpenseCheckBusyVN.value =
                                                  true;
                                              var didOpenDialog = false;
                                              try {
                                                if (!await _checkCanWriteNow()) {
                                                  _showSnackBar(
                                                    'Je bent offline. Verbind met internet om een uitgave toe te voegen.',
                                                  );
                                                  return;
                                                }
                                                final kids =
                                                    await _loadActiveChildren(
                                                      householdIdStr,
                                                    );
                                                if (kids.isEmpty) {
                                                  if (!mounted) return;
                                                  messenger
                                                      .hideCurrentSnackBar();
                                                  // Flutter negeert de
                                                  // duration op een SnackBar
                                                  // met SnackBarAction zodra
                                                  // MediaQuery.accessibleNavigation
                                                  // actief is; we sluiten
                                                  // dezelfde snackbar daarom
                                                  // gericht via de opgevangen
                                                  // controller na exact 4 s.
                                                  // close() op een reeds
                                                  // gedismiste/vervangen
                                                  // snackbar is een no-op.
                                                  final noChildrenSnackBarController =
                                                      messenger.showSnackBar(
                                                        SnackBar(
                                                          duration:
                                                              const Duration(
                                                                seconds: 5,
                                                              ),
                                                          content: const Text(
                                                            'Voeg eerst een kind toe.',
                                                          ),
                                                          action: SnackBarAction(
                                                            label: 'Kinderen',
                                                            onPressed: () => nav.push(
                                                              MaterialPageRoute<
                                                                void
                                                              >(
                                                                builder: (_) =>
                                                                    _KinderenPage(
                                                                      householdId:
                                                                          householdIdStr,
                                                                    ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      );
                                                  unawaited(
                                                    Future<void>.delayed(
                                                      const Duration(
                                                        seconds: 5,
                                                      ),
                                                      noChildrenSnackBarController
                                                          .close,
                                                    ),
                                                  );
                                                  return;
                                                }
                                                _addExpenseCheckBusyVN.value =
                                                    false;
                                                if (!mounted) return;
                                                _addExpenseDialogOpenVN.value =
                                                    true;
                                                didOpenDialog = true;
                                                await _openAddExpenseDialog(
                                                  householdIdStr,
                                                  coparentName: otherName,
                                                  children: kids,
                                                );
                                              } finally {
                                                if (didOpenDialog) {
                                                  await Future<void>.delayed(
                                                    kThemeAnimationDuration,
                                                  );
                                                }
                                                _addExpenseDialogOpenVN.value =
                                                    false;
                                                _addExpenseCheckBusyVN.value =
                                                    false;
                                              }
                                            },
                                      child: const Icon(Icons.add, size: 24),
                                    );
                                  },
                                );
                              },
                            )
                          else
                            const SizedBox(width: 40, height: 40),
                        ],
                      ),
                    ),
                  ),
                  body: MediaQuery.removeViewInsets(
                    context: context,
                    removeBottom: true,
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          _pagePadding,
                          24,
                          _pagePadding,
                          80,
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return Align(
                              alignment: Alignment.topCenter,
                              child: SizedBox(
                                width: min(constraints.maxWidth, 520.0),
                                child: ValueListenableBuilder<bool>(
                                  valueListenable: _freezeExpensesVN,
                                  builder: (context, frozen, _) {
                                    return StreamBuilder<
                                      QuerySnapshot<Map<String, dynamic>>
                                    >(
                                      stream: FirebaseFirestore.instance
                                          .collection(
                                            'households/$householdIdStr/expenses',
                                          )
                                          .orderBy(
                                            'createdAt',
                                            descending: true,
                                          )
                                          .snapshots(
                                            includeMetadataChanges: true,
                                          ),
                                      builder: (context, expensesSnapshot) {
                                        if (expensesSnapshot.hasData &&
                                            !frozen) {
                                          _lastExpensesSnap =
                                              expensesSnapshot.data!;
                                        }
                                        final effectiveSnap =
                                            _lastExpensesSnap ??
                                            expensesSnapshot.data;
                                        if (expensesSnapshot.hasError &&
                                            effectiveSnap == null) {
                                          _reportPreviewReady(true);
                                          return const Text(
                                            'Kon uitgaven niet laden.',
                                          );
                                        }
                                        if (effectiveSnap == null) {
                                          _reportPreviewReady(false);
                                          return const Center(
                                            child: CircularProgressIndicator(),
                                          );
                                        }

                                        final docs =
                                            List<
                                                QueryDocumentSnapshot<
                                                  Map<String, dynamic>
                                                >
                                              >.of(effectiveSnap.docs)
                                              ..sort(_compareExpenseDocsStable);
                                        final visibleDocs = docs
                                            .take(6)
                                            .toList(growable: false);
                                        final visibleOwnExpenseIds = visibleDocs
                                            .where(
                                              (d) =>
                                                  ((d.data()['createdBy']
                                                          as String?)
                                                      ?.trim()) ==
                                                  user.uid,
                                            )
                                            .map((d) => d.id)
                                            .toList(growable: false);
                                        final visiblePeerExpensePrivateNoteLookups =
                                            visibleDocs
                                                .map((d) {
                                                  final cb =
                                                      (d.data()['createdBy']
                                                              as String?)
                                                          ?.trim() ??
                                                      '';
                                                  return (
                                                    expenseId: d.id,
                                                    creatorUid: cb,
                                                  );
                                                })
                                                .where(
                                                  (p) =>
                                                      p.creatorUid.isNotEmpty &&
                                                      p.creatorUid != user.uid,
                                                )
                                                .toList(growable: false);

                                        var totalCents = 0;
                                        var myPaidCents = 0;
                                        // Split the balance into two
                                        // buckets: legacy (no snapshot)
                                        // keeps the existing half-floor
                                        // with deterministic remainder
                                        // rule; snapshot expenses add
                                        // per-expense
                                        // (myPaid − myFairShare).
                                        var legacyTotalCents = 0;
                                        var legacyMyPaidCents = 0;
                                        var snapshotBalanceCents = 0;
                                        for (final d in docs) {
                                          final e = d.data();
                                          final amountCents =
                                              (e['amountCents'] as num?)
                                                  ?.toInt() ??
                                              0;
                                          totalCents += amountCents;
                                          final createdBy =
                                              (e['createdBy'] as String?)
                                                  ?.trim();
                                          final myPaidForDoc =
                                              (createdBy == user.uid)
                                              ? amountCents
                                              : 0;
                                          if (createdBy == user.uid) {
                                            myPaidCents += amountCents;
                                          }
                                          final snap =
                                              ParentSplitSnapshot.tryReadFromExpense(
                                                e,
                                              );
                                          if (snap == null ||
                                              !snap.participantUids.contains(
                                                user.uid,
                                              )) {
                                            legacyTotalCents += amountCents;
                                            legacyMyPaidCents += myPaidForDoc;
                                          } else {
                                            final myShare = snap
                                                .fairShareCentsFor(
                                                  user.uid,
                                                  amountCents,
                                                );
                                            snapshotBalanceCents +=
                                                (myPaidForDoc - myShare);
                                          }
                                        }
                                        final otherPaidCents =
                                            totalCents - myPaidCents;
                                        final legacyOtherPaidCents =
                                            legacyTotalCents -
                                            legacyMyPaidCents;
                                        final legacyHalfFloor =
                                            legacyTotalCents ~/ 2;
                                        final legacyRemainder =
                                            legacyTotalCents % 2;
                                        final legacyExpectedMy =
                                            legacyHalfFloor +
                                            ((legacyRemainder == 1 &&
                                                    legacyMyPaidCents <
                                                        legacyOtherPaidCents)
                                                ? 1
                                                : 0);
                                        final rawBalanceCents =
                                            (legacyMyPaidCents -
                                                legacyExpectedMy) +
                                            snapshotBalanceCents;
                                        final balanceCents =
                                            rawBalanceCents +
                                            _totalPaidByMe -
                                            _totalPaidToMe +
                                            _confirmedPaidByMe -
                                            _confirmedPaidToMe;

                                        final absBalance = balanceCents.abs();
                                        final pendingInCents =
                                            (_pendingIncoming?['amountCents']
                                                    as num?)
                                                ?.toInt();
                                        final pendingOutCents =
                                            (_pendingOutgoing?['amountCents']
                                                    as num?)
                                                ?.toInt();

                                        String? lastActivityText;
                                        if (docs.isNotEmpty) {
                                          final first = docs.first;
                                          final e = first.data();
                                          final activityAt =
                                              _expenseActivityTimestamp(e);
                                          final timeStr = activityAt == null
                                              ? 'Zojuist'
                                              : _formatRelativeNl(
                                                  activityAt.toDate(),
                                                );
                                          lastActivityText =
                                              'Laatste activiteit · $timeStr';
                                        }

                                        final secondaryMetadataFuture =
                                            _getDashboardSecondaryMetadataFuture(
                                              householdId: householdIdStr,
                                              otherUid: otherUid!,
                                              visibleOwnExpenseIds:
                                                  visibleOwnExpenseIds,
                                              visiblePeerExpensePrivateNoteLookups:
                                                  visiblePeerExpensePrivateNoteLookups,
                                              viewerUid: user.uid,
                                            );

                                        return FutureBuilder<
                                          _DashboardSecondaryMetadata
                                        >(
                                          future: secondaryMetadataFuture,
                                          builder: (context, secondaryMetaSnapshot) {
                                            final secondaryMetadataScopeKey =
                                                '$householdIdStr|$otherUid';
                                            final secondaryMetadata =
                                                secondaryMetaSnapshot.data;
                                            final secondaryMetadataReady =
                                                secondaryMetaSnapshot
                                                        .connectionState ==
                                                    ConnectionState.done &&
                                                secondaryMetadata != null;
                                            if (secondaryMetadataReady) {
                                              _lastVisibleDashboardSecondaryMetadataScopeKey =
                                                  secondaryMetadataScopeKey;
                                              _lastVisibleDashboardSecondaryMetadata =
                                                  secondaryMetadata;
                                            }
                                            final visibleSecondaryMetadata =
                                                secondaryMetadataReady
                                                ? secondaryMetadata
                                                : (_lastVisibleDashboardSecondaryMetadataScopeKey ==
                                                          secondaryMetadataScopeKey
                                                      ? _lastVisibleDashboardSecondaryMetadata
                                                      : null);
                                            _reportPreviewReady(
                                              secondaryMetadataReady,
                                            );
                                            final visibleOtherName =
                                                visibleSecondaryMetadata
                                                    ?.otherName;
                                            final visibleNotes =
                                                visibleSecondaryMetadata
                                                    ?.notesByExpenseId ??
                                                const <String, String>{};
                                            final balanceBreakdownText =
                                                visibleOtherName == null
                                                ? null
                                                : '$myName ${_formatEur(myPaidCents)} • $visibleOtherName ${_formatEur(otherPaidCents)}';

                                            String? visibleStatusText;
                                            if (pendingInCents != null &&
                                                pendingInCents > 0) {
                                              visibleStatusText =
                                                  '${_formatEur(pendingInCents)} ontvangen? Tik om te bevestigen';
                                            } else if (pendingOutCents !=
                                                    null &&
                                                pendingOutCents > 0) {
                                              visibleStatusText =
                                                  '${_formatEur(pendingOutCents)} gemeld · wacht op bevestiging';
                                            } else if (balanceCents > 0 &&
                                                visibleOtherName != null) {
                                              visibleStatusText =
                                                  '$visibleOtherName betaalt jou ${_formatEur(absBalance)}';
                                            } else if (balanceCents < 0 &&
                                                visibleOtherName != null) {
                                              visibleStatusText =
                                                  'Jij betaalt $visibleOtherName ${_formatEur(absBalance)}';
                                            } else if (balanceCents == 0) {
                                              visibleStatusText =
                                                  'Jullie zijn in balans';
                                            }

                                            return Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                if (lastActivityText !=
                                                    null) ...[
                                                  Text(
                                                    lastActivityText,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall
                                                        ?.copyWith(
                                                          color: onSurface(
                                                            context,
                                                            a50,
                                                          ),
                                                        ),
                                                  ),
                                                  const SizedBox(height: 10),
                                                ],
                                                KiduCard(
                                                  padding: EdgeInsets.zero,
                                                  child: Material(
                                                    type: MaterialType
                                                        .transparency,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          _DashboardPageState
                                                              ._cardRadius,
                                                        ),
                                                    child: InkWell(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            _DashboardPageState
                                                                ._cardRadius,
                                                          ),
                                                      highlightColor:
                                                          Theme.of(context)
                                                              .colorScheme
                                                              .primary
                                                              .withValues(
                                                                alpha: 0.10,
                                                              ),
                                                      splashColor:
                                                          Theme.of(context)
                                                              .colorScheme
                                                              .primary
                                                              .withValues(
                                                                alpha: 0.08,
                                                              ),
                                                      onTap: () {
                                                        if (_pendingIncoming !=
                                                                null &&
                                                            _pendingIncomingId !=
                                                                null) {
                                                          final inPayment =
                                                              _pendingIncoming!;
                                                          final inId =
                                                              _pendingIncomingId!;
                                                          final inCents =
                                                              (inPayment['amountCents']
                                                                      as num?)
                                                                  ?.toInt() ??
                                                              0;
                                                          showModalBottomSheet<
                                                            void
                                                          >(
                                                            context: context,
                                                            isScrollControlled:
                                                                true,
                                                            shape: const RoundedRectangleBorder(
                                                              borderRadius:
                                                                  BorderRadius.vertical(
                                                                    top:
                                                                        Radius.circular(
                                                                          20,
                                                                        ),
                                                                  ),
                                                            ),
                                                            builder: (sheetCtx) {
                                                              return SafeArea(
                                                                child: Padding(
                                                                  padding:
                                                                      const EdgeInsets.fromLTRB(
                                                                        24,
                                                                        20,
                                                                        24,
                                                                        28,
                                                                      ),
                                                                  child: Column(
                                                                    mainAxisSize:
                                                                        MainAxisSize
                                                                            .min,
                                                                    crossAxisAlignment:
                                                                        CrossAxisAlignment
                                                                            .stretch,
                                                                    children: [
                                                                      Center(
                                                                        child: Container(
                                                                          width:
                                                                              36,
                                                                          height:
                                                                              4,
                                                                          decoration: BoxDecoration(
                                                                            color: Theme.of(
                                                                              context,
                                                                            ).colorScheme.outlineVariant,
                                                                            borderRadius: BorderRadius.circular(
                                                                              2,
                                                                            ),
                                                                          ),
                                                                        ),
                                                                      ),
                                                                      const SizedBox(
                                                                        height:
                                                                            20,
                                                                      ),
                                                                      Text(
                                                                        'Ontvangst bevestigen',
                                                                        style:
                                                                            Theme.of(
                                                                              context,
                                                                            ).textTheme.titleMedium?.copyWith(
                                                                              fontWeight: FontWeight.w700,
                                                                            ),
                                                                      ),
                                                                      const SizedBox(
                                                                        height:
                                                                            16,
                                                                      ),
                                                                      Text(
                                                                        'Betaling gemeld door $otherName',
                                                                        style:
                                                                            Theme.of(
                                                                              context,
                                                                            ).textTheme.bodyMedium?.copyWith(
                                                                              color: onSurface(
                                                                                context,
                                                                                a84,
                                                                              ),
                                                                              height: 1.4,
                                                                            ),
                                                                      ),
                                                                      const SizedBox(
                                                                        height:
                                                                            4,
                                                                      ),
                                                                      Text(
                                                                        _formatEur(
                                                                          inCents,
                                                                        ),
                                                                        style:
                                                                            Theme.of(
                                                                              context,
                                                                            ).textTheme.titleSmall?.copyWith(
                                                                              fontWeight: FontWeight.w600,
                                                                              color: onSurface(
                                                                                context,
                                                                                a84,
                                                                              ),
                                                                            ),
                                                                      ),
                                                                      const SizedBox(
                                                                        height:
                                                                            20,
                                                                      ),
                                                                      FilledButton(
                                                                        style: kiduDialogPrimaryButtonStyle(
                                                                          sheetCtx,
                                                                        ),
                                                                        onPressed: () {
                                                                          Navigator.of(
                                                                            sheetCtx,
                                                                          ).pop();
                                                                          showDialog<
                                                                                bool
                                                                              >(
                                                                                context: context,
                                                                                builder:
                                                                                    (
                                                                                      dialogCtx,
                                                                                    ) => AlertDialog(
                                                                                      actionsAlignment:
                                                                                          MainAxisAlignment
                                                                                              .spaceBetween,
                                                                                      actionsPadding:
                                                                                          const EdgeInsets
                                                                                              .fromLTRB(
                                                                                            16,
                                                                                            0,
                                                                                            16,
                                                                                            12,
                                                                                          ),
                                                                                      title:
                                                                                          kiduActionDialogTitle(
                                                                                        dialogCtx,
                                                                                        'Ontvangst bevestigen',
                                                                                      ),
                                                                                      content: Text(
                                                                                        'Je bevestigt dat je ${_formatEur(inCents)} van $otherName hebt ontvangen.',
                                                                                      ),
                                                                                      actions: [
                                                                                        TextButton(
                                                                                          onPressed: () =>
                                                                                              Navigator.of(
                                                                                                dialogCtx,
                                                                                              ).pop(
                                                                                                false,
                                                                                              ),
                                                                                          child: const Text(
                                                                                            'Annuleren',
                                                                                          ),
                                                                                        ),
                                                                                        FilledButton(
                                                                                          style: kiduDialogPrimaryButtonStyle(
                                                                                            dialogCtx,
                                                                                          ),
                                                                                          onPressed: () =>
                                                                                              Navigator.of(
                                                                                                dialogCtx,
                                                                                              ).pop(
                                                                                                true,
                                                                                              ),
                                                                                          child: const Text(
                                                                                            'Bevestigen',
                                                                                          ),
                                                                                        ),
                                                                                      ],
                                                                                    ),
                                                                              )
                                                                              .then((
                                                                                confirmed,
                                                                              ) async {
                                                                                if (confirmed ==
                                                                                    true) {
                                                                                  try {
                                                                                    await FirebaseFirestore.instance
                                                                                        .doc(
                                                                                          'households/$householdIdStr/payments/$inId',
                                                                                        )
                                                                                        .update(
                                                                                          {
                                                                                            'status': 'confirmed',
                                                                                            'confirmedAt': FieldValue.serverTimestamp(),
                                                                                            'confirmedBy': user.uid,
                                                                                          },
                                                                                        );
                                                                                  } catch (
                                                                                    e
                                                                                  ) {
                                                                                    if (kDebugMode) {
                                                                                      debugPrint(
                                                                                        'Payment confirm error: $e',
                                                                                      );
                                                                                    }
                                                                                    _showSnackBar(
                                                                                      mapUserFacingError(
                                                                                        e,
                                                                                        fallback: 'Bevestiging kon niet worden opgeslagen.',
                                                                                      ),
                                                                                    );
                                                                                  }
                                                                                }
                                                                              });
                                                                        },
                                                                        child: const Text(
                                                                          'Ontvangst bevestigen',
                                                                        ),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ),
                                                              );
                                                            },
                                                          );
                                                          return;
                                                        }

                                                        if (_pendingOutgoing !=
                                                            null) {
                                                          final outPayment =
                                                              _pendingOutgoing!;
                                                          final outCents =
                                                              (outPayment['amountCents']
                                                                      as num?)
                                                                  ?.toInt() ??
                                                              0;
                                                          showModalBottomSheet<
                                                            void
                                                          >(
                                                            context: context,
                                                            shape: const RoundedRectangleBorder(
                                                              borderRadius:
                                                                  BorderRadius.vertical(
                                                                    top:
                                                                        Radius.circular(
                                                                          20,
                                                                        ),
                                                                  ),
                                                            ),
                                                            builder: (sheetCtx) {
                                                              return SafeArea(
                                                                child: Padding(
                                                                  padding:
                                                                      const EdgeInsets.fromLTRB(
                                                                        24,
                                                                        20,
                                                                        24,
                                                                        28,
                                                                      ),
                                                                  child: Column(
                                                                    mainAxisSize:
                                                                        MainAxisSize
                                                                            .min,
                                                                    crossAxisAlignment:
                                                                        CrossAxisAlignment
                                                                            .stretch,
                                                                    children: [
                                                                      Center(
                                                                        child: Container(
                                                                          width:
                                                                              36,
                                                                          height:
                                                                              4,
                                                                          decoration: BoxDecoration(
                                                                            color: Theme.of(
                                                                              context,
                                                                            ).colorScheme.outlineVariant,
                                                                            borderRadius: BorderRadius.circular(
                                                                              2,
                                                                            ),
                                                                          ),
                                                                        ),
                                                                      ),
                                                                      const SizedBox(
                                                                        height:
                                                                            20,
                                                                      ),
                                                                      Text(
                                                                        'Betaling melden',
                                                                        style:
                                                                            Theme.of(
                                                                              context,
                                                                            ).textTheme.titleMedium?.copyWith(
                                                                              fontWeight: FontWeight.w700,
                                                                            ),
                                                                      ),
                                                                      const SizedBox(
                                                                        height:
                                                                            16,
                                                                      ),
                                                                      Text(
                                                                        'Betaling gemeld',
                                                                        style:
                                                                            Theme.of(
                                                                              context,
                                                                            ).textTheme.bodyMedium?.copyWith(
                                                                              color: onSurface(
                                                                                context,
                                                                                a84,
                                                                              ),
                                                                              height: 1.4,
                                                                            ),
                                                                      ),
                                                                      const SizedBox(
                                                                        height:
                                                                            4,
                                                                      ),
                                                                      Text(
                                                                        '${_formatEur(outCents)} aan $otherName',
                                                                        style:
                                                                            Theme.of(
                                                                              context,
                                                                            ).textTheme.titleSmall?.copyWith(
                                                                              fontWeight: FontWeight.w600,
                                                                              color: onSurface(
                                                                                context,
                                                                                a84,
                                                                              ),
                                                                            ),
                                                                      ),
                                                                      const SizedBox(
                                                                        height:
                                                                            8,
                                                                      ),
                                                                      Text(
                                                                        'Wacht op bevestiging door $otherName',
                                                                        style:
                                                                            Theme.of(
                                                                              context,
                                                                            ).textTheme.bodySmall?.copyWith(
                                                                              color: onSurface(
                                                                                context,
                                                                                a62,
                                                                              ),
                                                                              height: 1.4,
                                                                            ),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ),
                                                              );
                                                            },
                                                          );
                                                          return;
                                                        }

                                                        final amountCtrl =
                                                            TextEditingController(
                                                              text:
                                                                  '${absBalance ~/ 100},${(absBalance % 100).toString().padLeft(2, '0')}',
                                                            );
                                                        int? enteredCents =
                                                            absBalance;
                                                        showModalBottomSheet<
                                                          void
                                                        >(
                                                          context: context,
                                                          isScrollControlled:
                                                              true,
                                                          shape: const RoundedRectangleBorder(
                                                            borderRadius:
                                                                BorderRadius.vertical(
                                                                  top:
                                                                      Radius.circular(
                                                                        20,
                                                                      ),
                                                                ),
                                                          ),
                                                          builder: (sheetCtx) {
                                                            return StatefulBuilder(
                                                              builder: (_, setSheetState) {
                                                                final isValid =
                                                                    enteredCents !=
                                                                        null &&
                                                                    enteredCents! >
                                                                        0;
                                                                final bottomInset =
                                                                    MediaQuery.of(
                                                                          sheetCtx,
                                                                        )
                                                                        .viewInsets
                                                                        .bottom;
                                                                return SafeArea(
                                                                  child: Padding(
                                                                    padding:
                                                                        EdgeInsets.fromLTRB(
                                                                          24,
                                                                          20,
                                                                          24,
                                                                          28 +
                                                                              bottomInset,
                                                                        ),
                                                                    child: Column(
                                                                      mainAxisSize:
                                                                          MainAxisSize
                                                                              .min,
                                                                      crossAxisAlignment:
                                                                          CrossAxisAlignment
                                                                              .stretch,
                                                                      children: [
                                                                        Center(
                                                                          child: Container(
                                                                            width:
                                                                                36,
                                                                            height:
                                                                                4,
                                                                            decoration: BoxDecoration(
                                                                              color: Theme.of(
                                                                                context,
                                                                              ).colorScheme.outlineVariant,
                                                                              borderRadius: BorderRadius.circular(
                                                                                2,
                                                                              ),
                                                                            ),
                                                                          ),
                                                                        ),
                                                                        const SizedBox(
                                                                          height:
                                                                              20,
                                                                        ),
                                                                        Text(
                                                                          balanceCents <
                                                                                  0
                                                                              ? 'Betaling melden'
                                                                              : 'Balans',
                                                                          style:
                                                                              Theme.of(
                                                                                context,
                                                                              ).textTheme.titleMedium?.copyWith(
                                                                                fontWeight: FontWeight.w700,
                                                                              ),
                                                                        ),
                                                                        const SizedBox(
                                                                          height:
                                                                              16,
                                                                        ),
                                                                        if (balanceCents ==
                                                                            0)
                                                                          Text(
                                                                            'Jullie zijn in balans',
                                                                            style:
                                                                                Theme.of(
                                                                                  context,
                                                                                ).textTheme.bodyMedium?.copyWith(
                                                                                  color: onSurface(
                                                                                    context,
                                                                                    a62,
                                                                                  ),
                                                                                  height: 1.4,
                                                                                ),
                                                                          )
                                                                        else if (balanceCents >
                                                                            0) ...[
                                                                          Text(
                                                                            '$otherName is jou nog ${_formatEur(absBalance)} schuldig',
                                                                            style:
                                                                                Theme.of(
                                                                                  context,
                                                                                ).textTheme.bodyMedium?.copyWith(
                                                                                  color: onSurface(
                                                                                    context,
                                                                                    a84,
                                                                                  ),
                                                                                  height: 1.4,
                                                                                ),
                                                                          ),
                                                                          const SizedBox(
                                                                            height:
                                                                                8,
                                                                          ),
                                                                          Text(
                                                                            '$otherName kan een betaling melden vanuit de app.',
                                                                            style:
                                                                                Theme.of(
                                                                                  context,
                                                                                ).textTheme.bodySmall?.copyWith(
                                                                                  color: onSurface(
                                                                                    context,
                                                                                    a62,
                                                                                  ),
                                                                                  height: 1.4,
                                                                                ),
                                                                          ),
                                                                        ] else ...[
                                                                          Text(
                                                                            'Open bedrag: ${_formatEur(absBalance)}',
                                                                            style:
                                                                                Theme.of(
                                                                                  context,
                                                                                ).textTheme.titleSmall?.copyWith(
                                                                                  fontWeight: FontWeight.w600,
                                                                                  color: onSurface(
                                                                                    context,
                                                                                    a84,
                                                                                  ),
                                                                                ),
                                                                          ),
                                                                          const SizedBox(
                                                                            height:
                                                                                4,
                                                                          ),
                                                                          Text(
                                                                            'Jij betaalt $otherName',
                                                                            style:
                                                                                Theme.of(
                                                                                  context,
                                                                                ).textTheme.bodySmall?.copyWith(
                                                                                  color: onSurface(
                                                                                    context,
                                                                                    a62,
                                                                                  ),
                                                                                ),
                                                                          ),
                                                                          const SizedBox(
                                                                            height:
                                                                                16,
                                                                          ),
                                                                          TextField(
                                                                            controller:
                                                                                amountCtrl,
                                                                            keyboardType: const TextInputType.numberWithOptions(
                                                                              decimal: true,
                                                                            ),
                                                                            decoration: kiduCompactInputDecoration(
                                                                              labelText: 'Bedrag',
                                                                              errorText:
                                                                                  amountCtrl.text.trim().isNotEmpty &&
                                                                                      (enteredCents ==
                                                                                              null ||
                                                                                          enteredCents! <=
                                                                                              0)
                                                                                  ? 'Voer een geldig bedrag in'
                                                                                  : null,
                                                                            ).copyWith(
                                                                              floatingLabelBehavior:
                                                                                  FloatingLabelBehavior.always,
                                                                              border: const OutlineInputBorder(),
                                                                              prefixText: '€ ',
                                                                            ),
                                                                            onChanged:
                                                                                (
                                                                                  val,
                                                                                ) {
                                                                                  setSheetState(
                                                                                    () {
                                                                                      enteredCents = _tryParseEurToCents(
                                                                                        val,
                                                                                      );
                                                                                    },
                                                                                  );
                                                                                },
                                                                          ),
                                                                          const SizedBox(
                                                                            height:
                                                                                20,
                                                                          ),
                                                                          FilledButton(
                                                                            style: kiduDialogPrimaryButtonStyle(
                                                                              sheetCtx,
                                                                            ),
                                                                            onPressed:
                                                                                isValid
                                                                                ? () {
                                                                                    final paymentAmountCents = enteredCents!;
                                                                                    Navigator.of(
                                                                                      sheetCtx,
                                                                                    ).pop();
                                                                                    showDialog<
                                                                                          bool
                                                                                        >(
                                                                                          context: context,
                                                                                          builder:
                                                                                              (
                                                                                                dialogCtx,
                                                                                              ) => AlertDialog(
                                                                                                actionsAlignment:
                                                                                                    MainAxisAlignment
                                                                                                        .spaceBetween,
                                                                                                actionsPadding:
                                                                                                    const EdgeInsets
                                                                                                        .fromLTRB(
                                                                                                  16,
                                                                                                  0,
                                                                                                  16,
                                                                                                  12,
                                                                                                ),
                                                                                                title:
                                                                                                    kiduActionDialogTitle(
                                                                                                  dialogCtx,
                                                                                                  'Betaling melden',
                                                                                                ),
                                                                                                content: Text(
                                                                                                  'Je meldt een betaling van ${_formatEur(enteredCents!)} aan $otherName. $otherName moet dit nog bevestigen.',
                                                                                                ),
                                                                                                actions: [
                                                                                                  TextButton(
                                                                                                    onPressed: () =>
                                                                                                        Navigator.of(
                                                                                                          dialogCtx,
                                                                                                        ).pop(
                                                                                                          false,
                                                                                                        ),
                                                                                                    child: const Text(
                                                                                                      'Annuleren',
                                                                                                    ),
                                                                                                  ),
                                                                                                  FilledButton(
                                                                                                    style: kiduDialogPrimaryButtonStyle(
                                                                                                      dialogCtx,
                                                                                                    ),
                                                                                                    onPressed: () =>
                                                                                                        Navigator.of(
                                                                                                          dialogCtx,
                                                                                                        ).pop(
                                                                                                          true,
                                                                                                        ),
                                                                                                    child: const Text(
                                                                                                      'Melden',
                                                                                                    ),
                                                                                                  ),
                                                                                                ],
                                                                                              ),
                                                                                        )
                                                                                        .then(
                                                                                          (
                                                                                            confirmed,
                                                                                          ) async {
                                                                                            if (confirmed ==
                                                                                                true) {
                                                                                              try {
                                                                                                await FirebaseFirestore.instance
                                                                                                    .collection(
                                                                                                      'households/$householdIdStr/payments',
                                                                                                    )
                                                                                                    .add(
                                                                                                      {
                                                                                                        'amountCents': paymentAmountCents,
                                                                                                        'currency': 'EUR',
                                                                                                        'fromUserId': user.uid,
                                                                                                        'toUserId': otherUid!,
                                                                                                        'status': 'pending',
                                                                                                        'createdAt': FieldValue.serverTimestamp(),
                                                                                                        'createdBy': user.uid,
                                                                                                        'confirmedAt': null,
                                                                                                        'confirmedBy': null,
                                                                                                      },
                                                                                                    );
                                                                                              } catch (
                                                                                                e
                                                                                              ) {
                                                                                                if (kDebugMode) {
                                                                                                  debugPrint(
                                                                                                    'Payment write error: $e',
                                                                                                  );
                                                                                                }
                                                                                                _showSnackBar(
                                                                                                  mapUserFacingError(
                                                                                                    e,
                                                                                                    fallback: 'Betaling kon niet worden gemeld.',
                                                                                                  ),
                                                                                                );
                                                                                              }
                                                                                            }
                                                                                          },
                                                                                        );
                                                                                  }
                                                                                : null,
                                                                            child: const Text(
                                                                              'Betaling melden',
                                                                            ),
                                                                          ),
                                                                        ],
                                                                      ],
                                                                    ),
                                                                  ),
                                                                );
                                                              },
                                                            );
                                                          },
                                                        );
                                                      },
                                                      child: Padding(
                                                        padding:
                                                            const EdgeInsets.all(
                                                              16,
                                                            ),
                                                        child: Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .stretch,
                                                          children: [
                                                            Text(
                                                              'Balans',
                                                              style: Theme.of(context)
                                                                  .textTheme
                                                                  .titleMedium
                                                                  ?.copyWith(
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w700,
                                                                  ),
                                                            ),
                                                            // Compact summary: replace three separate rows.
                                                            const SizedBox(
                                                              height: 8,
                                                            ),
                                                            _balanceRow(
                                                              label:
                                                                  'Totaal samen uitgegeven',
                                                              value: _formatEur(
                                                                totalCents,
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              height: 8,
                                                            ),
                                                            Text(
                                                              balanceBreakdownText ??
                                                                  ' ',
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: Theme.of(context)
                                                                  .textTheme
                                                                  .bodySmall
                                                                  ?.copyWith(
                                                                    color:
                                                                        onSurface(
                                                                          context,
                                                                          a62,
                                                                        ),
                                                                    height: 1.3,
                                                                  ),
                                                            ),
                                                            // Tighter section spacing for lower card height.
                                                            const SizedBox(
                                                              height: 8,
                                                            ),
                                                            Divider(
                                                              height: 1,
                                                              color: outlineV(
                                                                context,
                                                                a40,
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              height: 8,
                                                            ),
                                                            Text(
                                                              visibleStatusText ??
                                                                  ' ',
                                                              style: Theme.of(context)
                                                                  .textTheme
                                                                  .bodySmall
                                                                  ?.copyWith(
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w600,
                                                                    color:
                                                                        onSurface(
                                                                          context,
                                                                          a84,
                                                                        ),
                                                                    height: 1.3,
                                                                  ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(
                                                  height: _cardGap,
                                                ),
                                                KiduCard(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 16,
                                                        vertical: 12,
                                                      ),
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .stretch,
                                                    children: [
                                                      Text(
                                                        'Recente uitgaven',
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .titleMedium
                                                            ?.copyWith(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700,
                                                            ),
                                                      ),
                                                      const SizedBox(
                                                        height: 10,
                                                      ),
                                                      docs.isEmpty
                                                          ? Align(
                                                              alignment:
                                                                  Alignment
                                                                      .topLeft,
                                                              child: Text(
                                                                canAddExpenses
                                                                    ? 'Nog geen uitgaven. Voeg er één toe met +.'
                                                                    : 'Nog geen uitgaven.',
                                                                style: Theme.of(context)
                                                                    .textTheme
                                                                    .bodyMedium
                                                                    ?.copyWith(
                                                                      color: onSurface(
                                                                        context,
                                                                        a62,
                                                                      ),
                                                                      height:
                                                                          1.35,
                                                                    ),
                                                              ),
                                                            )
                                                          : ListView.separated(
                                                              shrinkWrap: true,
                                                              padding:
                                                                  EdgeInsets
                                                                      .zero,
                                                              physics:
                                                                  const NeverScrollableScrollPhysics(),
                                                              itemCount:
                                                                  visibleDocs
                                                                      .length,
                                                              separatorBuilder:
                                                                  (
                                                                    context,
                                                                    index,
                                                                  ) => Divider(
                                                                    height: 14,
                                                                    color:
                                                                        outlineV(
                                                                          context,
                                                                          a40,
                                                                        ),
                                                                  ),
                                                              itemBuilder: (context, index) {
                                                                final d =
                                                                    visibleDocs[index];
                                                                final e = d
                                                                    .data();
                                                                final title =
                                                                    (e['title']
                                                                            as String?)
                                                                        ?.trim() ??
                                                                    '(zonder)';
                                                                final amountCents =
                                                                    (e['amountCents']
                                                                            as num?)
                                                                        ?.toInt() ??
                                                                    0;
                                                                final createdBy =
                                                                    (e['createdBy']
                                                                            as String?)
                                                                        ?.trim();

                                                                final who =
                                                                    createdBy ==
                                                                        user.uid
                                                                    ? myName
                                                                    : (otherUid !=
                                                                              null &&
                                                                          createdBy ==
                                                                              otherUid)
                                                                    ? otherName
                                                                    : 'Co-parent';
                                                                final isPending = d
                                                                    .metadata
                                                                    .hasPendingWrites;
                                                                final rowFallback =
                                                                    createdBy ==
                                                                            user.uid &&
                                                                        _pendingExpenseRowFallback?.expenseId ==
                                                                            d.id
                                                                    ? _pendingExpenseRowFallback
                                                                    : null;
                                                                final createdAtRaw =
                                                                    e['createdAt'];
                                                                DateTime?
                                                                createdAtDateTime;
                                                                if (createdAtRaw
                                                                    is Timestamp) {
                                                                  createdAtDateTime =
                                                                      createdAtRaw
                                                                          .toDate()
                                                                          .toLocal();
                                                                } else if (createdAtRaw
                                                                    is DateTime) {
                                                                  createdAtDateTime =
                                                                      createdAtRaw
                                                                          .toLocal();
                                                                }
                                                                createdAtDateTime ??=
                                                                    rowFallback
                                                                        ?.savedAt
                                                                        .toLocal();
                                                                final dateLabel =
                                                                    _formatDashboardExpenseDate(
                                                                      createdAtDateTime,
                                                                    );
                                                                final actorLabel =
                                                                    (createdBy ==
                                                                        user.uid)
                                                                    ? myName
                                                                    : (otherUid !=
                                                                              null &&
                                                                          createdBy ==
                                                                              otherUid)
                                                                    ? visibleOtherName
                                                                    : null;
                                                                final baseSubtitleText =
                                                                    actorLabel ==
                                                                            null ||
                                                                        actorLabel
                                                                            .isEmpty
                                                                    ? dateLabel
                                                                    : dateLabel
                                                                          .isEmpty
                                                                    ? actorLabel
                                                                    : '$actorLabel • $dateLabel';
                                                                final note =
                                                                    visibleNotes[d
                                                                        .id] ??
                                                                    rowFallback
                                                                        ?.note;
                                                                final isMaterializedMonthly =
                                                                    _expenseDocIsMaterializedMonthly(
                                                                      e,
                                                                    );
                                                                final subtitleWidget = _expenseSubtitleWithOptionalMonthlyIcon(
                                                                  context,
                                                                  actorAndDateLine:
                                                                      baseSubtitleText,
                                                                  noteTrailing:
                                                                      (note?.trim().isNotEmpty ??
                                                                          false)
                                                                      ? note!
                                                                            .trim()
                                                                      : null,
                                                                  isMaterializedMonthly:
                                                                      isMaterializedMonthly,
                                                                );
                                                                final expChildIds =
                                                                    (e['childIds']
                                                                            as List?)
                                                                        ?.whereType<
                                                                          String
                                                                        >()
                                                                        .toList() ??
                                                                    const <
                                                                      String
                                                                    >[];

                                                                Future<void>
                                                                openNoteFlow() async {
                                                                  final hasNote =
                                                                      (visibleNotes[d.id] ??
                                                                              '')
                                                                          .isNotEmpty;
                                                                  if (!await _checkCanWriteNow()) {
                                                                    if (mounted) {
                                                                      _showSnackBar(
                                                                        hasNote
                                                                            ? 'Je bent offline. Notitie bewerken kan alleen met internet.'
                                                                            : 'Je bent offline. Notitie toevoegen kan alleen met internet.',
                                                                      );
                                                                    }
                                                                    return;
                                                                  }
                                                                  await _openEditPrivateNoteDialog(
                                                                    householdId:
                                                                        householdIdStr,
                                                                    expenseId:
                                                                        d.id,
                                                                    uid: user
                                                                        .uid,
                                                                  );
                                                                }

                                                                return Material(
                                                                  type: MaterialType
                                                                      .transparency,
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        8,
                                                                      ),
                                                                  child: InkWell(
                                                                    borderRadius:
                                                                        BorderRadius.circular(
                                                                          8,
                                                                        ),
                                                                    highlightColor: Theme.of(context)
                                                                        .colorScheme
                                                                        .primary
                                                                        .withValues(
                                                                          alpha:
                                                                              0.10,
                                                                        ),
                                                                    splashColor: Theme.of(context)
                                                                        .colorScheme
                                                                        .primary
                                                                        .withValues(
                                                                          alpha:
                                                                              0.08,
                                                                        ),
                                                                    onTap: () async {
                                                                      final preloadedChildNames =
                                                                          expChildIds
                                                                              .isEmpty
                                                                          ? const <
                                                                              String
                                                                            >[]
                                                                          : (_dashChildren.isNotEmpty &&
                                                                                expChildIds.every(
                                                                                  (
                                                                                    id,
                                                                                  ) => _dashChildren.any(
                                                                                    (
                                                                                      c,
                                                                                    ) =>
                                                                                        c.id ==
                                                                                        id,
                                                                                  ),
                                                                                ))
                                                                          ? expChildIds
                                                                                .map(
                                                                                  (
                                                                                    id,
                                                                                  ) =>
                                                                                      _dashChildren
                                                                                          .where(
                                                                                            (
                                                                                              c,
                                                                                            ) =>
                                                                                                c.id ==
                                                                                                id,
                                                                                          )
                                                                                          .map(
                                                                                            (
                                                                                              c,
                                                                                            ) => c.name,
                                                                                          )
                                                                                          .firstOrNull ??
                                                                                      'Verwijderd kind',
                                                                                )
                                                                                .toList()
                                                                          : await _ExpenseDetailPage._resolveChildNames(
                                                                              householdIdStr,
                                                                              expChildIds,
                                                                            );
                                                                      if (!context
                                                                          .mounted) {
                                                                        return;
                                                                      }
                                                                      Navigator.of(
                                                                        context,
                                                                      ).push(
                                                                        MaterialPageRoute<
                                                                          void
                                                                        >(
                                                                          builder:
                                                                              (
                                                                                context,
                                                                              ) => _ExpenseDetailPage(
                                                                                householdId: householdIdStr,
                                                                                expenseId: d.id,
                                                                                uid: user.uid,
                                                                                createdByUid:
                                                                                    createdBy ??
                                                                                    '',
                                                                                title: title,
                                                                                amountCents: amountCents,
                                                                                paidByName: who,
                                                                                createdAt: createdAtDateTime,
                                                                                isPending: isPending,
                                                                                onManageNote:
                                                                                    createdBy ==
                                                                                        user.uid
                                                                                    ? openNoteFlow
                                                                                    : null,
                                                                                otherParentName: otherName,
                                                                                parentSplitSnapshot: ParentSplitSnapshot.tryReadFromExpense(
                                                                                  e,
                                                                                ),
                                                                                parentSplitMembers:
                                                                                    <
                                                                                      _ParentSplitMember
                                                                                    >[
                                                                                      _ParentSplitMember(
                                                                                        uid: user.uid,
                                                                                        label: myName,
                                                                                      ),
                                                                                      if (otherUid !=
                                                                                          null)
                                                                                        _ParentSplitMember(
                                                                                          uid: otherUid,
                                                                                          label: otherName,
                                                                                        ),
                                                                                    ],
                                                                                childIds: expChildIds,
                                                                                childNames: preloadedChildNames,
                                                                                showChildContext:
                                                                                    _dashHasMultipleChildDocs,
                                                                              ),
                                                                        ),
                                                                      );
                                                                    },
                                                                    child: ListTile(
                                                                      contentPadding:
                                                                          const EdgeInsets.symmetric(
                                                                            horizontal:
                                                                                5,
                                                                          ),
                                                                      dense:
                                                                          true,
                                                                      visualDensity:
                                                                          VisualDensity
                                                                              .compact,
                                                                      title: Text(
                                                                        title,
                                                                        maxLines:
                                                                            1,
                                                                        overflow:
                                                                            TextOverflow.ellipsis,
                                                                      ),
                                                                      subtitle:
                                                                          subtitleWidget,
                                                                      trailing: Row(
                                                                        mainAxisSize:
                                                                            MainAxisSize.min,
                                                                        children: [
                                                                          if (isPending)
                                                                            Tooltip(
                                                                              message: 'Nog niet gesynchroniseerd',
                                                                              child: Icon(
                                                                                Icons.cloud_off,
                                                                                size: 16,
                                                                                color: onSurface(
                                                                                  context,
                                                                                  a50,
                                                                                ),
                                                                              ),
                                                                            ),
                                                                          if (isPending)
                                                                            const SizedBox(
                                                                              width: 4,
                                                                            ),
                                                                          Text(
                                                                            _formatEur(
                                                                              amountCents,
                                                                            ),
                                                                            style:
                                                                                Theme.of(
                                                                                  context,
                                                                                ).textTheme.bodyMedium?.copyWith(
                                                                                  fontWeight: FontWeight.w600,
                                                                                ),
                                                                          ),
                                                                        ],
                                                                      ),
                                                                    ),
                                                                  ),
                                                                );
                                                              },
                                                            ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            );
                                          },
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

Widget _balanceRow({required String label, required String value}) {
  return Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
      const SizedBox(width: 12),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
    ],
  );
}

/// Actieve kinderen voor [_EditRecurringMasterExpenseDialog] (zelfde semantiek
/// als `_DashboardPageState._loadActiveChildren` / nieuwe-uitgaveflows).
/// Ook gebruikt voor [_EditExpenseAmountDialog] (parity kindselectie / stale ids).
Future<List<_ChildItem>> _loadRecurringMasterEditChildren(
  String householdId,
) async {
  if (householdId.trim().isEmpty) return [];
  try {
    final snap = await FirebaseFirestore.instance
        .collection('households/$householdId/children')
        .get();
    final docs =
        snap.docs
            .where(
              (d) =>
                  d.data()['isArchived'] != true &&
                  d.data()['isDeleted'] != true,
            )
            .toList()
          ..sort((a, b) {
            final aTs = a.data()['createdAt'];
            final bTs = b.data()['createdAt'];
            if (aTs is Timestamp && bTs is Timestamp) {
              return aTs.compareTo(bTs);
            }
            return 0;
          });
    return docs
        .map(
          (d) => _ChildItem(
            id: d.id,
            name: (d.data()['name'] as String?)?.trim() ?? '?',
          ),
        )
        .toList();
  } catch (_) {
    return [];
  }
}

Future<List<String>?> _showExpenseEditChildSelectionDialog(
  BuildContext context, {
  required List<_ChildItem> children,
  List<String> initialSelectedChildIds = const [],
}) async {
  final allChildIds = children.map((c) => c.id).toList(growable: false);
  return showDialog<List<String>>(
    context: context,
    useSafeArea: true,
    barrierDismissible: true,
    builder: (context) {
      var selectedChildIds = initialSelectedChildIds
          .where(allChildIds.contains)
          .toSet();
      return StatefulBuilder(
        builder: (context, setLocalState) {
          final selectedCount = selectedChildIds.length;
          final allSelected = selectedCount == allChildIds.length;
          final cs = Theme.of(context).colorScheme;
          final dialogBackground = cs.surfaceContainerHigh;
          final screenW = MediaQuery.sizeOf(context).width;
          final dialogW = (screenW - 80.0).clamp(280.0, 420.0);
          final modalHeight = min(
            520.0,
            MediaQuery.of(context).size.height - 36,
          );
          void dismissSelectionDialog() => Navigator.of(context).pop();
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 24,
            ),
            child: SafeArea(
              child: Align(
                alignment: const Alignment(0, -0.08),
                child: SizedBox(
                  width: dialogW,
                  child: SizedBox(
                    height: modalHeight,
                    child: Material(
                      color: dialogBackground,
                      elevation: 3,
                      clipBehavior: Clip.antiAlias,
                      borderRadius: BorderRadius.circular(
                        _DashboardPageState._cardRadius,
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            _DashboardPageState._cardRadius,
                          ),
                          border: Border.all(color: outlineV(context, a40)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                              child: Center(
                                child: Container(
                                  width: 36,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: cs.outlineVariant.withValues(
                                      alpha: 0.85,
                                    ),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                              child: kiduActionDialogTitle(
                                context,
                                'Kinderen selecteren',
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  0,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TextButton(
                                      onPressed: () => setLocalState(() {
                                        selectedChildIds = allSelected
                                            ? <String>{}
                                            : allChildIds.toSet();
                                      }),
                                      style: TextButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        padding: EdgeInsets.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      child: Text(
                                        allSelected
                                            ? 'Alle deselecteren'
                                            : 'Alle selecteren',
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    SizedBox(
                                      height: 28,
                                      child: Align(
                                        alignment: Alignment.topLeft,
                                        child: Opacity(
                                          opacity: selectedCount == 0 ? 1 : 0,
                                          child: Text(
                                            'Selecteer minimaal 1 kind om verder te gaan',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  color: onSurface(
                                                    context,
                                                    a68,
                                                  ),
                                                ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: ListView.separated(
                                        padding: const EdgeInsets.only(
                                          top: 2,
                                          bottom: 4,
                                        ),
                                        itemCount: children.length,
                                        separatorBuilder: (_, _) => Divider(
                                          height: 1,
                                          thickness: 0.4,
                                          color: cs.outlineVariant.withValues(
                                            alpha: 0.45,
                                          ),
                                        ),
                                        itemBuilder: (context, index) {
                                          final child = children[index];
                                          final selected = selectedChildIds
                                              .contains(child.id);
                                          return Material(
                                            type: MaterialType.transparency,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              onTap: () {
                                                setLocalState(() {
                                                  if (selected) {
                                                    selectedChildIds =
                                                        selectedChildIds
                                                            .where(
                                                              (id) =>
                                                                  id !=
                                                                  child.id,
                                                            )
                                                            .toSet();
                                                  } else {
                                                    selectedChildIds = {
                                                      ...selectedChildIds,
                                                      child.id,
                                                    };
                                                  }
                                                });
                                              },
                                              child: ListTile(
                                                dense: true,
                                                visualDensity:
                                                    VisualDensity.compact,
                                                minLeadingWidth: 32,
                                                contentPadding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 2,
                                                      vertical: 0,
                                                    ),
                                                leading: Checkbox(
                                                  value: selected,
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  activeColor: cs.primary
                                                      .withValues(alpha: a84),
                                                  checkColor: cs.surface,
                                                  side: BorderSide(
                                                    color: cs.outlineVariant
                                                        .withValues(
                                                          alpha: 0.85,
                                                        ),
                                                  ),
                                                  onChanged: (value) {
                                                    setLocalState(() {
                                                      if (value ?? false) {
                                                        selectedChildIds = {
                                                          ...selectedChildIds,
                                                          child.id,
                                                        };
                                                      } else {
                                                        selectedChildIds =
                                                            selectedChildIds
                                                                .where(
                                                                  (id) =>
                                                                      id !=
                                                                      child.id,
                                                                )
                                                                .toSet();
                                                      }
                                                    });
                                                  },
                                                ),
                                                title: Text(
                                                  child.name,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodyMedium
                                                      ?.copyWith(
                                                        color: onSurface(
                                                          context,
                                                          a84,
                                                        ),
                                                      ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Container(
                              decoration: BoxDecoration(
                                color: dialogBackground,
                                border: Border(
                                  top: BorderSide(
                                    color: outlineV(context, a32),
                                  ),
                                ),
                              ),
                              child: SafeArea(
                                top: false,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    8,
                                    16,
                                    12,
                                  ),
                                  child: Row(
                                    children: [
                                      TextButton(
                                        onPressed: dismissSelectionDialog,
                                        child: const Text('Annuleren'),
                                      ),
                                      const Spacer(),
                                      FilledButton(
                                        style: kiduDialogPrimaryButtonStyle(
                                          context,
                                        ),
                                        onPressed: selectedCount == 0
                                            ? null
                                            : () => Navigator.of(context).pop(
                                                children
                                                    .where(
                                                      (child) =>
                                                          selectedChildIds
                                                              .contains(
                                                                child.id,
                                                              ),
                                                    )
                                                    .map((child) => child.id)
                                                    .toList(),
                                              ),
                                        child: const Text('Opslaan'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

class _ExpenseDetailPage extends StatefulWidget {
  const _ExpenseDetailPage({
    required this.householdId,
    required this.expenseId,
    required this.uid,
    required this.createdByUid,
    required this.title,
    required this.amountCents,
    required this.paidByName,
    required this.createdAt,
    required this.isPending,
    this.onManageNote,
    this.childIds = const [],
    this.childNames,
    this.otherParentName,
    this.parentSplitSnapshot,
    this.parentSplitMembers = const <_ParentSplitMember>[],
    this.initialChildNameById,
    this.showChildContext = true,
  });

  final String householdId;
  final String expenseId;
  final String uid;
  final String createdByUid;
  final String title;
  final int amountCents;
  final String paidByName;
  final DateTime? createdAt;
  final bool isPending;
  final Future<void> Function()? onManageNote;
  final String? otherParentName;
  final ParentSplitSnapshot? parentSplitSnapshot;
  final List<_ParentSplitMember> parentSplitMembers;
  final List<String> childIds;
  // Pre-resolved display names; when non-null the Voor section renders
  // synchronously without a FutureBuilder round-trip.
  final List<String>? childNames;

  /// Household child id → name, seeded from Logboek (Wijzigingsgeschiedenis).
  final Map<String, String>? initialChildNameById;

  /// When false, hide the read-only "Voor" row (single-child households).
  final bool showChildContext;

  /// Resolves child IDs to display names; falls back to "Verwijderd kind".
  static Future<List<String>> _resolveChildNames(
    String householdId,
    List<String> ids,
  ) async {
    if (ids.isEmpty) return [];
    try {
      final snaps = await Future.wait(
        ids.map(
          (id) => FirebaseFirestore.instance
              .doc('households/$householdId/children/$id')
              .get(),
        ),
      );
      return snaps.map((s) {
        final name = (s.data()?['name'] as String?)?.trim();
        return (name != null && name.isNotEmpty) ? name : 'Verwijderd kind';
      }).toList();
    } catch (_) {
      return ids.map((_) => 'Verwijderd kind').toList();
    }
  }

  static String _formatChildNamesInline(List<String> names) =>
      names.join(' · ');

  static String _formatEur(int cents) {
    final negative = cents < 0;
    final abs = cents.abs();
    final euros = abs ~/ 100;
    final rem = abs % 100;
    final euroStr = euros.toString();
    final buf = StringBuffer();
    for (var i = 0; i < euroStr.length; i++) {
      if (i > 0 && (euroStr.length - i) % 3 == 0) buf.write('.');
      buf.write(euroStr[i]);
    }
    return '${negative ? '-' : ''}€$buf,${rem.toString().padLeft(2, '0')}';
  }

  static String _prefillAmountForEdit(int cents) {
    final euros = cents ~/ 100;
    final rem = cents % 100;
    return '$euros,${rem.toString().padLeft(2, '0')}';
  }

  /// Same rules as [DashboardPage._tryParseEurToCents] (single-file).
  static int? _parseEurToCents(String input) {
    final raw = input.trim().replaceAll(' ', '');
    if (raw.isEmpty) {
      return null;
    }
    final normalized = raw.replaceAll(',', '.');
    if (!RegExp(r'^\d+(\.\d{0,2})?$').hasMatch(normalized)) {
      return null;
    }

    final parts = normalized.split('.');
    final euros = int.tryParse(parts[0]) ?? 0;
    var cents = 0;
    if (parts.length == 2 && parts[1].isNotEmpty) {
      final frac = parts[1];
      if (frac.length == 1) {
        cents = int.parse(frac) * 10;
      } else if (frac.length == 2) {
        cents = int.parse(frac);
      } else {
        return null;
      }
    }
    return euros * 100 + cents;
  }

  static String _formatDateTime(DateTime? dt) {
    if (dt == null) return '—';
    const nlMonths = [
      'jan',
      'feb',
      'mrt',
      'apr',
      'mei',
      'jun',
      'jul',
      'aug',
      'sep',
      'okt',
      'nov',
      'dec',
    ];
    return '${dt.day} ${nlMonths[dt.month - 1]} \u2022 ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  /// Note doc id = expense/master `createdBy` (author slot).
  static String _privateNotesDocUid(String createdByUid) => createdByUid.trim();

  static bool _privateNoteIsSharedWithViewer(
    Map<String, dynamic>? data,
    String viewerUid,
  ) {
    if (data == null) return false;
    final raw = data['sharedWithUids'];
    if (raw is! List) return false;
    final v = viewerUid.trim();
    if (v.isEmpty) return false;
    for (final e in raw) {
      if (e is String && e.trim() == v) return true;
    }
    return false;
  }

  @override
  State<_ExpenseDetailPage> createState() => _ExpenseDetailPageState();
}

/// Owns [TextEditingController]s so they are disposed with the route, not
/// immediately after [showDialog] returns (avoids teardown races).
class _EditExpenseAmountDialog extends StatefulWidget {
  const _EditExpenseAmountDialog({
    required this.householdId,
    required this.expenseId,
    required this.currentAmountCents,
    required this.currentTitle,
    required this.currentChildIds,
    required this.childrenFuture,
    this.initialChildren,
    required this.initialParentSplitMembers,
    this.initialExpenseSplit,
    this.initialCreatedAt,
  });

  final String householdId;
  final String expenseId;
  final int currentAmountCents;
  final String currentTitle;
  final List<String> currentChildIds;
  final Future<List<_ChildItem>> childrenFuture;

  /// UI hint only; [_EditExpenseAmountDialogState._submit] uses a fresh server read.
  final DateTime? initialCreatedAt;

  /// Preloaded via [_ExpenseDetailPageState._openEditAmountDialog] zodat de
  /// `Voor:`-rij op frame 1 stabiel is. `null` → [childrenFuture] als fallback.
  final List<_ChildItem>? initialChildren;

  /// Zoals op [_ExpenseDetailPage]: bij precies twee leden synchroon gebruikt;
  /// bij lege lijst wordt `_loadParentSplitMembers` als fallback gestart.
  final List<_ParentSplitMember> initialParentSplitMembers;

  /// Snapshot zoals op het expense-doc bij openen (`tryReadFromExpense`).
  final ParentSplitSnapshot? initialExpenseSplit;

  @override
  State<_EditExpenseAmountDialog> createState() =>
      _EditExpenseAmountDialogState();
}

class _EditExpenseAmountDialogState extends State<_EditExpenseAmountDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _amountController;
  late final TextEditingController _reasonController;
  late final FocusNode _titleFocusNode;
  late final FocusNode _amountFocusNode;
  late final FocusNode _reasonFocusNode;
  late final Future<List<_ChildItem>> _childrenFuture;
  List<_ChildItem>? _syncChildren;
  bool _showReasonField = false;
  bool _amountDraftNeedsAuditReason = false;
  bool _showNoChangesMessage = false;
  bool _titleHasError = false;
  bool _amountHasError = false;
  bool _reasonHasError = false;
  bool _didChangeChildSelection = false;
  bool _hasCustomChildSelection = false;
  List<String> _customSelectedChildIds = const <String>[];
  bool _saving = false;
  ParentSplitSnapshot? _pendingSplit;
  List<_ParentSplitMember> _parentSplitMembers = const <_ParentSplitMember>[];

  /// Baseline uitgaveverdeling toen de dialoog stabiel stond, voor drafts
  /// buiten het correctievenster ([_refreshAuditReasonGate]).
  ParentSplitSnapshot? _splitBaselineForGate;

  void _applyMembersToSplitState(List<_ParentSplitMember> members) {
    if (members.length != kParentSplitParticipantCount) {
      _parentSplitMembers = members;
      _pendingSplit = null;
      return;
    }
    final memberUids = members.map((m) => m.uid).toSet();
    var snapshot = widget.initialExpenseSplit;
    if (snapshot == null ||
        snapshot.participantUids.toSet().difference(memberUids).isNotEmpty) {
      snapshot = _neutralParentSplitForMembers(members);
    }
    _parentSplitMembers = members;
    _pendingSplit = snapshot;
  }

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.currentTitle);
    _amountController = TextEditingController(
      text: _ExpenseDetailPage._prefillAmountForEdit(widget.currentAmountCents),
    );
    _reasonController = TextEditingController();
    _titleFocusNode = FocusNode();
    _amountFocusNode = FocusNode();
    _reasonFocusNode = FocusNode();
    final pre = widget.initialChildren;
    if (pre != null) {
      _syncChildren = List<_ChildItem>.from(pre);
      _childrenFuture = Future<List<_ChildItem>>.value(_syncChildren!);
    } else {
      _syncChildren = null;
      _childrenFuture = widget.childrenFuture;
    }

    final seeded = widget.initialParentSplitMembers;
    if (seeded.length == kParentSplitParticipantCount) {
      _applyMembersToSplitState(seeded);
    } else if (seeded.isEmpty) {
      _loadSplitUiAsync();
    } else {
      _applyMembersToSplitState(seeded);
    }
    _splitBaselineForGate = _pendingSplit;
  }

  bool _draftSplitDirtyForAuditReason() {
    final a = _splitBaselineForGate;
    final b = _pendingSplit;
    if (a == null && b == null) return false;
    if (a == null || b == null) return true;
    return !_expenseSplitsEqual(a, b);
  }

  void _enqueueAuditReasonGateRefresh() {
    scheduleMicrotask(() async {
      await _refreshAuditReasonGate();
    });
  }

  Future<void> _refreshAuditReasonGate() async {
    if (!mounted) return;

    final now = DateTime.now();
    if (_isWithinExpenseAmountCorrectionWindow(widget.initialCreatedAt, now)) {
      if (_showReasonField || _reasonHasError) {
        setState(() {
          _showReasonField = false;
          _reasonHasError = false;
          _amountDraftNeedsAuditReason = false;
          if (_reasonController.text.isNotEmpty) {
            _reasonController.clear();
          }
        });
      }
      return;
    }

    List<_ChildItem> children;
    try {
      children = await _childrenFuture;
    } catch (_) {
      return;
    }
    if (!mounted) return;

    final parsed = _ExpenseDetailPage._parseEurToCents(_amountController.text);
    if (parsed != null && parsed >= 0) {
      _amountDraftNeedsAuditReason = parsed != widget.currentAmountCents;
    }
    final amountAuditedDraft = _amountDraftNeedsAuditReason;
    final effectiveChildIds = _effectiveSelectedChildIds(children);
    final childrenAuditedDraft =
        _didChangeChildSelection &&
        !_sameChildIds(effectiveChildIds, widget.currentChildIds);

    final nextShow =
        amountAuditedDraft ||
        childrenAuditedDraft ||
        _draftSplitDirtyForAuditReason();

    if (!nextShow && _reasonController.text.isNotEmpty) {
      _reasonController.clear();
    }

    final shouldHideErrors = !nextShow;
    if (nextShow != _showReasonField || (shouldHideErrors && _reasonHasError)) {
      setState(() {
        _showReasonField = nextShow;
        if (shouldHideErrors) {
          _reasonHasError = false;
        }
      });
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _amountController.dispose();
    _reasonController.dispose();
    _titleFocusNode.dispose();
    _amountFocusNode.dispose();
    _reasonFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadSplitUiAsync() async {
    try {
      final members = await _loadParentSplitMembers(widget.householdId);
      if (!mounted) return;
      setState(() {
        _applyMembersToSplitState(members);
        _splitBaselineForGate = _pendingSplit;
      });
      _enqueueAuditReasonGateRefresh();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pendingSplit = null;
        _splitBaselineForGate = null;
      });
    }
  }

  ParentSplitSnapshot? _baselineSplitFromFreshExpense(
    Map<String, dynamic>? freshData,
    List<_ParentSplitMember> members,
  ) {
    if (members.length != kParentSplitParticipantCount) return null;
    final fromDoc = ParentSplitSnapshot.tryReadFromExpense(
      freshData ?? const <String, dynamic>{},
    );
    final memberUids = members.map((m) => m.uid).toSet();
    if (fromDoc != null &&
        fromDoc.participantUids.toSet().difference(memberUids).isEmpty) {
      return fromDoc;
    }
    return _neutralParentSplitForMembers(members);
  }

  bool _expenseSplitsEqual(ParentSplitSnapshot a, ParentSplitSnapshot b) {
    if (a.share0Bps != b.share0Bps) return false;
    final au = a.participantUids;
    final bu = b.participantUids;
    if (au.length != bu.length) return false;
    for (var i = 0; i < au.length; i++) {
      if (au[i] != bu[i]) return false;
    }
    return true;
  }

  Future<void> _openParentSplitDialog() async {
    final snapshot = _pendingSplit;
    if (snapshot == null ||
        _parentSplitMembers.length != kParentSplitParticipantCount) {
      return;
    }
    final picked = await showDialog<ParentSplitSnapshot>(
      context: context,
      builder: (_) => _RecurringParentSplitDialog(
        members: _parentSplitMembers,
        initialSnapshot: snapshot,
        viewerUid: FirebaseAuth.instance.currentUser?.uid,
        contextFooterText: 'Deze verdeling hoort alleen bij deze uitgave.',
        minShareBps: 0,
        maxShareBps: kBpsFull,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _pendingSplit = picked;
      _showNoChangesMessage = false;
    });
    _enqueueAuditReasonGateRefresh();
  }

  List<String> _allChildIds(List<_ChildItem> children) =>
      children.map((c) => c.id).toList(growable: false);

  bool _isAllChildrenSelection(
    List<_ChildItem> children,
    List<String> childIds,
  ) {
    final allChildIds = _allChildIds(children);
    return allChildIds.isNotEmpty &&
        childIds.length == allChildIds.length &&
        childIds.toSet().containsAll(allChildIds);
  }

  List<String> _currentKnownChildIds(List<_ChildItem> children) {
    final allChildIds = _allChildIds(children);
    return widget.currentChildIds.where(allChildIds.contains).toList();
  }

  List<String> _effectiveSelectedChildIds(List<_ChildItem> children) {
    final allChildIds = _allChildIds(children);
    if (!_didChangeChildSelection) {
      return _isAllChildrenSelection(children, widget.currentChildIds)
          ? allChildIds
          : _currentKnownChildIds(children);
    }
    return _hasCustomChildSelection ? _customSelectedChildIds : allChildIds;
  }

  List<String> _dialogInitialSelectedChildIds(List<_ChildItem> children) {
    final allChildIds = _allChildIds(children);
    if (_didChangeChildSelection) {
      return _hasCustomChildSelection ? _customSelectedChildIds : allChildIds;
    }
    return _isAllChildrenSelection(children, widget.currentChildIds)
        ? allChildIds
        : _currentKnownChildIds(children);
  }

  bool _sameChildIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    return a.toSet().containsAll(b);
  }

  Future<void> _openChildSelectionDialog(List<_ChildItem> children) async {
    final pickedChildIds = await _showExpenseEditChildSelectionDialog(
      context,
      children: children,
      initialSelectedChildIds: _dialogInitialSelectedChildIds(children),
    );
    if (pickedChildIds == null || !mounted) return;
    setState(() {
      _showNoChangesMessage = false;
      _didChangeChildSelection = true;
      if (pickedChildIds.length == children.length) {
        _hasCustomChildSelection = false;
        _customSelectedChildIds = const <String>[];
      } else {
        _hasCustomChildSelection = true;
        _customSelectedChildIds = pickedChildIds;
      }
    });
    _enqueueAuditReasonGateRefresh();
  }

  bool _expenseReferencesInactiveChildren(List<_ChildItem> activeChildren) {
    if (widget.currentChildIds.isEmpty) return false;
    final activeIds = activeChildren.map((c) => c.id).toSet();
    return widget.currentChildIds.any((id) => !activeIds.contains(id));
  }

  Widget _inactiveChildrenOnExpenseBanner(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Controleer de kinderen',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          'Deze uitgave bevat kinderen die niet meer actief zijn. De kindselectie blijft ongewijzigd zolang je die niet aanpast.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            height: 1.35,
            color: onSurface(context, a70),
          ),
        ),
      ],
    );
  }

  Widget _expenseEditVoorChildrenBlock(
    BuildContext context, {
    required List<_ChildItem> children,
    required bool selectionDataReady,
  }) {
    final showStaleBanner =
        selectionDataReady && _expenseReferencesInactiveChildren(children);
    if (children.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showStaleBanner) ...[
              _inactiveChildrenOnExpenseBanner(context),
              const SizedBox(height: 12),
            ],
            Text(
              'Voeg eerst een kind toe.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _saving
                    ? null
                    : () async {
                        await Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                _KinderenPage(householdId: widget.householdId),
                          ),
                        );
                        if (!mounted) return;
                        setState(() {
                          _syncChildren = null;
                          _childrenFuture = _loadRecurringMasterEditChildren(
                            widget.householdId,
                          );
                        });
                      },
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Kinderen'),
              ),
            ),
          ],
        ),
      );
    }

    final showChildSelectionUi =
        children.length >= 2 || (children.length == 1 && showStaleBanner);
    if (!showChildSelectionUi) {
      return const SizedBox.shrink();
    }

    final effectiveSelectedChildIds = _effectiveSelectedChildIds(children);
    final childSelectionSummary =
        _isAllChildrenSelection(children, effectiveSelectedChildIds)
        ? 'Alle kinderen'
        : '${effectiveSelectedChildIds.length} van ${children.length} geselecteerd';
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showStaleBanner) ...[
            _inactiveChildrenOnExpenseBanner(context),
            const SizedBox(height: 12),
          ],
          Text('Voor:', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  childSelectionSummary,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              TextButton(
                onPressed: _saving || !selectionDataReady
                    ? null
                    : () async {
                        FocusManager.instance.primaryFocus?.unfocus();
                        await _openChildSelectionDialog(children);
                      },
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Selectie'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final title = _titleController.text.trim();
    final reasonTrimmed = _reasonController.text.trim();
    final parsed = _ExpenseDetailPage._parseEurToCents(_amountController.text);
    final children = await _childrenFuture;
    final effectiveSelectedChildIds = _effectiveSelectedChildIds(children);
    if (title.isEmpty) {
      if (mounted) {
        setState(() => _titleHasError = true);
        _titleFocusNode.requestFocus();
      }
      return;
    }
    if (title.length > _kAddExpenseTitleMaxLength) {
      if (mounted) {
        setState(() => _titleHasError = true);
        _titleFocusNode.requestFocus();
      }
      return;
    }
    if (parsed == null || parsed < 0) {
      if (mounted) {
        setState(() => _amountHasError = true);
        _amountFocusNode.requestFocus();
      }
      return;
    }
    if (_didChangeChildSelection && effectiveSelectedChildIds.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecteer minimaal één kind.')),
      );
      return;
    }
    setState(() => _saving = true);
    if (!await _checkCanWriteNow()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Je bent offline, probeer het later opnieuw'),
        ),
      );
      setState(() => _saving = false);
      return;
    }
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      final expRef = FirebaseFirestore.instance.doc(
        'households/${widget.householdId}/expenses/${widget.expenseId}',
      );
      final fresh = await expRef.get(const GetOptions(source: Source.server));
      final currentTitle =
          ((fresh.data()?['title'] as String?) ?? widget.currentTitle).trim();
      final currentChildIds =
          (fresh.data()?['childIds'] as List?)?.whereType<String>().toList() ??
          widget.currentChildIds;
      final fromCents =
          (fresh.data()?['amountCents'] as num?)?.toInt() ??
          widget.currentAmountCents;
      final splitMembers = await _loadParentSplitMembers(widget.householdId);
      final baselineSplit = _baselineSplitFromFreshExpense(
        fresh.data(),
        splitMembers,
      );
      final pendingSplit = _pendingSplit;
      final splitChanged =
          baselineSplit != null &&
          pendingSplit != null &&
          !_expenseSplitsEqual(baselineSplit, pendingSplit);
      final titleChanged = title != currentTitle;
      final amountChanged = parsed != fromCents;
      final childIdsChanged =
          _didChangeChildSelection &&
          !_sameChildIds(effectiveSelectedChildIds, currentChildIds);
      final createdAtRaw = fresh.data()?['createdAt'];
      DateTime? expenseCreatedAt;
      if (createdAtRaw is Timestamp) {
        expenseCreatedAt = createdAtRaw.toDate().toLocal();
      } else if (createdAtRaw is DateTime) {
        expenseCreatedAt = createdAtRaw.toLocal();
      }
      final withinCorrectionWindow = _isWithinExpenseAmountCorrectionWindow(
        expenseCreatedAt,
        DateTime.now(),
      );
      final needsAmountAuditOutside = !withinCorrectionWindow && amountChanged;
      final needsAllocationAuditOutside =
          !withinCorrectionWindow && (childIdsChanged || splitChanged);
      final needsAnyExpenseAuditOutside =
          needsAmountAuditOutside || needsAllocationAuditOutside;

      if (!amountChanged &&
          !titleChanged &&
          !childIdsChanged &&
          !splitChanged) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _showNoChangesMessage = true;
        });
        return;
      }
      if (needsAnyExpenseAuditOutside && reasonTrimmed.isEmpty) {
        if (mounted) {
          setState(() {
            _showReasonField = true;
            _reasonHasError = true;
          });
          _reasonFocusNode.requestFocus();
        }
        setState(() => _saving = false);
        return;
      }

      final updateFields = <String, dynamic>{
        if (amountChanged) 'amountCents': parsed,
        if (titleChanged) 'title': title,
        if (childIdsChanged) 'childIds': effectiveSelectedChildIds,
        if (splitChanged) ...pendingSplit.toExpenseFields(),
      };

      if (withinCorrectionWindow) {
        await expRef.update(updateFields);
      } else {
        final needsAmountEditDoc = amountChanged;
        final needsAllocationEditDoc = childIdsChanged || splitChanged;

        if (!needsAmountEditDoc && !needsAllocationEditDoc) {
          await expRef.update(updateFields);
        } else {
          final batch = FirebaseFirestore.instance.batch();
          String? changeBatchId;
          if (needsAmountEditDoc && needsAllocationEditDoc) {
            changeBatchId = expRef.collection('expenseChanges').doc().id;
          }

          if (needsAmountEditDoc) {
            final editRef = expRef.collection('amountEdits').doc();
            final amountPayload = <String, dynamic>{
              'fromAmountCents': fromCents,
              'toAmountCents': parsed,
              'reason': reasonTrimmed,
              'editedBy': uid,
              'editedAt': FieldValue.serverTimestamp(),
            };
            if (changeBatchId != null) {
              amountPayload['changeBatchId'] = changeBatchId;
            }
            batch.set(editRef, amountPayload);
          }

          if (needsAllocationEditDoc) {
            final changeRef = expRef.collection('expenseChanges').doc();
            final priorChildren = List<String>.from(currentChildIds);
            final nextChildren = childIdsChanged
                ? List<String>.from(effectiveSelectedChildIds)
                : List<String>.from(currentChildIds);

            ParentSplitSnapshot? priorSplit;
            ParentSplitSnapshot? nextSplit;
            if (baselineSplit != null && pendingSplit != null) {
              priorSplit = baselineSplit;
              nextSplit = splitChanged ? pendingSplit : baselineSplit;
            }

            batch.set(
              changeRef,
              _expenseChangeWriteMap(
                uid: uid,
                reason: reasonTrimmed,
                changeBatchId: changeBatchId,
                priorChildIds: priorChildren,
                nextChildIds: nextChildren,
                priorSplit: priorSplit,
                nextSplit: nextSplit,
              ),
            );
          }

          updateFields['hasAuditHistory'] = true;
          batch.update(expRef, updateFields);
          await batch.commit();
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Edit expense amount error: $e');
      }
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            mapUserFacingError(
              e,
              fallback: 'Opslaan mislukt. Probeer opnieuw.',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = (screenW - 80.0).clamp(280.0, 420.0);
    final subtleErrorHintStyle = Theme.of(context).textTheme.bodySmall
        ?.copyWith(
          color: Theme.of(context).colorScheme.error.withValues(alpha: 0.85),
          fontSize: 12,
          fontWeight: FontWeight.w400,
        );
    final subtleErrorInputStyle = Theme.of(context).textTheme.bodyLarge
        ?.copyWith(
          color: Theme.of(context).colorScheme.error.withValues(alpha: 0.88),
          fontWeight: FontWeight.w400,
        );
    final titleTrimmed = _titleController.text.trim();
    final titleErrorHint = titleTrimmed.isEmpty
        ? 'Vul een titel in'
        : 'Titel mag maximaal $_kAddExpenseTitleMaxLength tekens hebben.';
    final textTheme = Theme.of(context).textTheme;
    final splitMetaLabelStyle = textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w400,
      color: onSurface(context, a84),
    );
    final splitMetaValueStyle = textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w500,
      color: onSurface(context, a84),
    );
    final splitMetaActionStyle = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Align(
      alignment: const Alignment(0, -0.15),
      child: SizedBox(
        width: dialogW,
        child: AlertDialog(
          actionsAlignment: MainAxisAlignment.spaceBetween,
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          title: kiduActionDialogTitle(context, 'Uitgave bewerken'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                TextField(
                  controller: _titleController,
                  focusNode: _titleFocusNode,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.next,
                  maxLength: _kAddExpenseTitleMaxLength,
                  onTap: () {
                    if (_titleHasError) {
                      setState(() => _titleHasError = false);
                    }
                  },
                  onChanged: (_) {
                    if (_showNoChangesMessage) {
                      setState(() => _showNoChangesMessage = false);
                    }
                    if (_titleHasError) {
                      setState(() => _titleHasError = false);
                    }
                  },
                  buildCounter:
                      (
                        context, {
                        required int currentLength,
                        required bool isFocused,
                        required int? maxLength,
                      }) => null,
                  decoration: kiduCompactInputDecoration(
                    labelText: 'Titel',
                    hintText: _titleHasError ? titleErrorHint : null,
                  ).copyWith(
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    border: const OutlineInputBorder(),
                    hintStyle: _titleHasError ? subtleErrorHintStyle : null,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _amountController,
                  focusNode: _amountFocusNode,
                  style: _amountHasError ? subtleErrorInputStyle : null,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onTap: () {
                    if (_amountHasError) {
                      setState(() => _amountHasError = false);
                    }
                  },
                  onChanged: (value) {
                    if (_showNoChangesMessage) {
                      setState(() => _showNoChangesMessage = false);
                    }
                    final parsed = _ExpenseDetailPage._parseEurToCents(
                      _amountController.text,
                    );
                    final trimmed = value.trim();
                    final nextAmountHasError =
                        trimmed.isNotEmpty && (parsed == null || parsed < 0);
                    setState(() => _amountHasError = nextAmountHasError);
                    _enqueueAuditReasonGateRefresh();
                  },
                  decoration: kiduCompactInputDecoration(
                    labelText: 'Bedrag (EUR)',
                    hintText: _amountHasError
                        ? 'Vul een geldig bedrag in'
                        : null,
                  ).copyWith(
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    border: const OutlineInputBorder(),
                    hintStyle: _amountHasError ? subtleErrorHintStyle : null,
                  ),
                ),
                if (_showReasonField) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _reasonController,
                    focusNode: _reasonFocusNode,
                    onTap: () {
                      if (_reasonHasError) {
                        setState(() => _reasonHasError = false);
                      }
                    },
                    onChanged: (_) {
                      if (_showNoChangesMessage) {
                        setState(() => _showNoChangesMessage = false);
                      }
                      if (_reasonHasError) {
                        setState(() => _reasonHasError = false);
                      }
                    },
                    decoration: kiduCompactInputDecoration(
                      labelText: 'Reden',
                      hintText: _reasonHasError ? 'Vul een reden in' : null,
                    ).copyWith(
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                      border: const OutlineInputBorder(),
                      hintStyle: _reasonHasError ? subtleErrorHintStyle : null,
                    ),
                  ),
                ],
                if (_syncChildren != null)
                  _expenseEditVoorChildrenBlock(
                    context,
                    children: _syncChildren!,
                    selectionDataReady: true,
                  )
                else
                  FutureBuilder<List<_ChildItem>>(
                    future: _childrenFuture,
                    builder: (context, snap) {
                      final children = snap.data ?? const <_ChildItem>[];
                      return _expenseEditVoorChildrenBlock(
                        context,
                        children: children,
                        selectionDataReady: snap.hasData,
                      );
                    },
                  ),
                if (_pendingSplit != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: 'Verdeling: ',
                                  style: splitMetaLabelStyle,
                                ),
                                TextSpan(
                                  text: _formatParentSplitCompact(
                                    _pendingSplit!,
                                    FirebaseAuth.instance.currentUser?.uid,
                                  ),
                                  style: splitMetaValueStyle,
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: _saving
                              ? null
                              : () async {
                                  FocusManager.instance.primaryFocus?.unfocus();
                                  await _openParentSplitDialog();
                                },
                          style: splitMetaActionStyle,
                          child: const Text('Wijzigen'),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_showNoChangesMessage)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'Er zijn geen wijzigingen.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.error.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('Annuleren'),
            ),
            FilledButton(
              style: kiduDialogPrimaryButtonStyle(context),
              onPressed: _saving ? null : () => _submit(),
              child: SizedBox(
                width: 82,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Text('Opslaan'),
                    if (_saving)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context)
                                .colorScheme
                                .onSecondaryContainer,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Master-editflow voor een recurring uitgave.
///
/// Divergeert bewust van [_EditExpenseAmountDialog]:
///  * géén redenplicht meer — ook niet bij bedragwijziging op de master,
///  * géén recurring `changes`-doc in deze stap,
///  * bewerkbare vervaldag-van-de-maand via een kleine datepicker-UX waarvan
///    alleen de dagcomponent wordt overgenomen.
/// De gewone echte expense-editflow (voor concrete instances) blijft
/// onaangeroerd en houdt zijn redenplicht bij bedragwijziging.
class _EditRecurringMasterExpenseDialog extends StatefulWidget {
  const _EditRecurringMasterExpenseDialog({
    required this.householdId,
    required this.masterId,
    required this.currentAmountCents,
    required this.currentTitle,
    required this.currentChildIds,
    required this.currentDueDayOfMonth,
    required this.currentParentSplitSnapshot,
    required this.parentSplitMembersFuture,
    required this.childrenFuture,
    this.initialChildren,
  });

  final String householdId;
  final String masterId;
  final int currentAmountCents;
  final String currentTitle;
  final List<String> currentChildIds;

  /// Huidige terugkerende vervaldag van de maand; bron voor de dialog-UX en
  /// referentie voor change-detectie bij save.
  final int currentDueDayOfMonth;

  final ParentSplitSnapshot? currentParentSplitSnapshot;
  final Future<List<_ParentSplitMember>> parentSplitMembersFuture;
  final Future<List<_ChildItem>> childrenFuture;

  /// Preloaded vóór `showDialog`; `null` → [childrenFuture] (o.a. refresh na
  /// `Kinderen`-navigatie).
  final List<_ChildItem>? initialChildren;

  @override
  State<_EditRecurringMasterExpenseDialog> createState() =>
      _EditRecurringMasterExpenseDialogState();
}

class _EditRecurringMasterExpenseDialogState
    extends State<_EditRecurringMasterExpenseDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _amountController;
  late final FocusNode _titleFocusNode;
  late final FocusNode _amountFocusNode;
  late Future<List<_ChildItem>> _childrenFuture;
  List<_ChildItem>? _syncChildren;
  bool _showNoChangesMessage = false;
  bool _titleHasError = false;
  bool _amountHasError = false;
  bool _didChangeChildSelection = false;
  bool _hasCustomChildSelection = false;
  List<String> _customSelectedChildIds = const <String>[];
  late int _selectedDueDay;
  bool _loadingParentSplit = true;
  List<_ParentSplitMember> _parentSplitMembers = const [];
  ParentSplitSnapshot? _parentSplitSnapshot;
  bool _didChangeParentSplit = false;

  /// Volledige datum zoals de gebruiker die in deze dialog-sessie heeft
  /// gekozen. `null` zolang de picker niet is geopend of de gebruiker
  /// geannuleerd heeft. Leidend voor zowel `dueDayOfMonth` als
  /// `materializeFromDate` bij save: de gekozen datum is letterlijk de
  /// eerstvolgende concrete datum waarop deze master weer valt.
  DateTime? _pickedDueDate;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.currentTitle);
    _amountController = TextEditingController(
      text: _ExpenseDetailPage._prefillAmountForEdit(widget.currentAmountCents),
    );
    _titleFocusNode = FocusNode();
    _amountFocusNode = FocusNode();
    final pre = widget.initialChildren;
    if (pre != null) {
      _syncChildren = List<_ChildItem>.from(pre);
      _childrenFuture = Future<List<_ChildItem>>.value(_syncChildren!);
    } else {
      _syncChildren = null;
      _childrenFuture = widget.childrenFuture;
    }
    final rawDue = widget.currentDueDayOfMonth;
    _selectedDueDay = rawDue < 1 ? 1 : (rawDue > 31 ? 31 : rawDue);
    _loadParentSplit();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _amountController.dispose();
    _titleFocusNode.dispose();
    _amountFocusNode.dispose();
    super.dispose();
  }

  /// Opent een datepicker die semantisch *de eerstvolgende concrete
  /// vervaldatum* van deze master kiest. De dagcomponent wordt overgenomen
  /// als nieuwe [_selectedDueDay]; de volledige picked-datum wordt
  /// onthouden in [_pickedDueDate] zodat de save-flow materialisatie-floor
  /// en structurele vervaldag samen uit diezelfde bron kan afleiden.
  ///
  /// `firstDate` is het maximum van vandaag en de eerste dag van de eerste
  /// maand vanaf nu waarvan `periodKey` nog niet op een expense voor deze
  /// master staat,
  /// zodat de gebruiker geen datum in een al-gematerialiseerde maand kiest.
  Future<Set<String>> _fetchExistingPeriodKeysForRecurringEdit() async {
    final householdId = widget.householdId.trim();
    final masterId = widget.masterId.trim();
    if (householdId.isEmpty || masterId.isEmpty) {
      return <String>{};
    }
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('households/$householdId/expenses')
          .where('recurringExpenseId', isEqualTo: masterId)
          .get();
      final keys = <String>{};
      for (final doc in snapshot.docs) {
        final pk = doc.data()['periodKey'];
        if (pk is String && pk.isNotEmpty) {
          keys.add(pk);
        }
      }
      return keys;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Recurring edit: existing period keys read failed: $e');
      }
      return <String>{};
    }
  }

  /// Eerste kiesbare dag voor deze edit-flow: niet vóór vandaag en niet in
  /// een maand die al een `periodKey` heeft voor deze master.
  DateTime _firstSelectableDateForRecurringEdit({
    required Set<String> existingPeriodKeys,
    required DateTime today,
  }) {
    var y = today.year;
    var m = today.month;
    for (var i = 0; i < 60; i++) {
      final pk = _formatRecurringPeriodKey(y, m);
      if (!existingPeriodKeys.contains(pk)) {
        final firstOfFreeMonth = DateTime(y, m, 1);
        return today.isAfter(firstOfFreeMonth) ? today : firstOfFreeMonth;
      }
      m += 1;
      if (m > 12) {
        m = 1;
        y += 1;
      }
    }
    return today;
  }

  Future<void> _pickDueDay() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final existingKeys = await _fetchExistingPeriodKeysForRecurringEdit();
    if (!mounted) return;
    final firstDate = _firstSelectableDateForRecurringEdit(
      existingPeriodKeys: existingKeys,
      today: today,
    );

    DateTime initial;
    if (_pickedDueDate != null) {
      final prev = _pickedDueDate!;
      initial = prev.isBefore(firstDate) ? firstDate : prev;
    } else {
      final thisMonthDue = _recurringDueDateFor(
        year: today.year,
        month: today.month,
        startDay: _selectedDueDay,
      );
      if (!thisMonthDue.isBefore(today)) {
        initial = thisMonthDue;
      } else {
        final nextYear = today.month == 12 ? today.year + 1 : today.year;
        final nextMonth = today.month == 12 ? 1 : today.month + 1;
        initial = _recurringDueDateFor(
          year: nextYear,
          month: nextMonth,
          startDay: _selectedDueDay,
        );
      }
      if (initial.isBefore(firstDate)) {
        initial = firstDate;
      }
    }
    final lastDate = DateTime(now.year + 5);
    if (initial.isAfter(lastDate)) {
      initial = lastDate;
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: 'Volgende vervaldatum',
      cancelText: 'Annuleren',
      confirmText: 'Kiezen',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _pickedDueDate = DateTime(picked.year, picked.month, picked.day);
      _selectedDueDay = picked.day;
      _showNoChangesMessage = false;
    });
  }

  Future<void> _loadParentSplit() async {
    try {
      final members = await widget.parentSplitMembersFuture;
      final memberUids = members.map((m) => m.uid).toSet();
      var snapshot = widget.currentParentSplitSnapshot;
      if (snapshot == null ||
          snapshot.participantUids.toSet().difference(memberUids).isNotEmpty) {
        snapshot = _neutralParentSplitForMembers(members);
      }
      if (!mounted) return;
      setState(() {
        _parentSplitMembers = members;
        _parentSplitSnapshot = snapshot;
        _loadingParentSplit = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingParentSplit = false);
    }
  }

  Future<void> _openParentSplitDialog() async {
    final snapshot = _parentSplitSnapshot;
    if (snapshot == null ||
        _parentSplitMembers.length != kParentSplitParticipantCount) {
      return;
    }
    final picked = await showDialog<ParentSplitSnapshot>(
      context: context,
      builder: (_) => _RecurringParentSplitDialog(
        members: _parentSplitMembers,
        initialSnapshot: snapshot,
        viewerUid: FirebaseAuth.instance.currentUser?.uid,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _parentSplitSnapshot = picked;
      _didChangeParentSplit = true;
      _showNoChangesMessage = false;
    });
  }

  List<String> _allChildIds(List<_ChildItem> children) =>
      children.map((c) => c.id).toList(growable: false);

  bool _isAllChildrenSelection(
    List<_ChildItem> children,
    List<String> childIds,
  ) {
    final allChildIds = _allChildIds(children);
    return allChildIds.isNotEmpty &&
        childIds.length == allChildIds.length &&
        childIds.toSet().containsAll(allChildIds);
  }

  List<String> _currentKnownChildIds(List<_ChildItem> children) {
    final allChildIds = _allChildIds(children);
    return widget.currentChildIds.where(allChildIds.contains).toList();
  }

  List<String> _effectiveSelectedChildIds(List<_ChildItem> children) {
    final allChildIds = _allChildIds(children);
    if (!_didChangeChildSelection) {
      return _isAllChildrenSelection(children, widget.currentChildIds)
          ? allChildIds
          : _currentKnownChildIds(children);
    }
    return _hasCustomChildSelection ? _customSelectedChildIds : allChildIds;
  }

  List<String> _dialogInitialSelectedChildIds(List<_ChildItem> children) {
    final allChildIds = _allChildIds(children);
    if (_didChangeChildSelection) {
      return _hasCustomChildSelection ? _customSelectedChildIds : allChildIds;
    }
    return _isAllChildrenSelection(children, widget.currentChildIds)
        ? allChildIds
        : _currentKnownChildIds(children);
  }

  bool _sameChildIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    return a.toSet().containsAll(b);
  }

  Future<void> _openChildSelectionDialog(List<_ChildItem> children) async {
    final pickedChildIds = await _showExpenseEditChildSelectionDialog(
      context,
      children: children,
      initialSelectedChildIds: _dialogInitialSelectedChildIds(children),
    );
    if (pickedChildIds == null || !mounted) return;
    setState(() {
      _showNoChangesMessage = false;
      _didChangeChildSelection = true;
      if (pickedChildIds.length == children.length) {
        _hasCustomChildSelection = false;
        _customSelectedChildIds = const <String>[];
      } else {
        _hasCustomChildSelection = true;
        _customSelectedChildIds = pickedChildIds;
      }
    });
  }

  bool _masterReferencesInactiveChildren(List<_ChildItem> activeChildren) {
    if (widget.currentChildIds.isEmpty) return false;
    final activeIds = activeChildren.map((c) => c.id).toSet();
    return widget.currentChildIds.any((id) => !activeIds.contains(id));
  }

  Widget _inactiveChildrenOnMasterBanner(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Controleer de kinderen',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          'Deze maandelijkse uitgave bevat kinderen die niet meer actief zijn. De kindselectie blijft ongewijzigd zolang je die niet aanpast.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            height: 1.35,
            color: onSurface(context, a70),
          ),
        ),
      ],
    );
  }

  Widget _recurringMasterVoorChildrenSlot(
    BuildContext context, {
    required List<_ChildItem> children,
    required bool waiting,
    required bool selectionDataReady,
    required TextStyle? metaLabelStyle,
    required TextStyle? metaValueStyle,
    required ButtonStyle metaActionStyle,
  }) {
    final showStaleBanner =
        !waiting && _masterReferencesInactiveChildren(children);
    if (children.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showStaleBanner) ...[
              _inactiveChildrenOnMasterBanner(context),
              const SizedBox(height: 12),
            ],
            Text(
              'Voeg eerst een kind toe.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _saving
                    ? null
                    : () async {
                        await Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                _KinderenPage(householdId: widget.householdId),
                          ),
                        );
                        if (!mounted) return;
                        setState(() {
                          _syncChildren = null;
                          _childrenFuture = _loadRecurringMasterEditChildren(
                            widget.householdId,
                          );
                        });
                      },
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Kinderen'),
              ),
            ),
          ],
        ),
      );
    }

    final showChildSelectionUi =
        children.length >= 2 || (children.length == 1 && showStaleBanner);
    if (!showChildSelectionUi) {
      return const SizedBox.shrink();
    }

    final effectiveSelectedChildIds = _effectiveSelectedChildIds(children);
    final childSelectionSummary =
        _isAllChildrenSelection(children, effectiveSelectedChildIds)
        ? 'Alle kinderen'
        : '${effectiveSelectedChildIds.length} van ${children.length} geselecteerd';
    final selectionSection = Row(
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'Voor: ', style: metaLabelStyle),
                TextSpan(text: childSelectionSummary, style: metaValueStyle),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton(
          onPressed: _saving || !selectionDataReady
              ? null
              : () async {
                  FocusManager.instance.primaryFocus?.unfocus();
                  await _openChildSelectionDialog(children);
                },
          style: metaActionStyle,
          child: const Text('Selectie'),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showStaleBanner) ...[
            _inactiveChildrenOnMasterBanner(context),
            const SizedBox(height: 12),
          ],
          selectionSection,
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final title = _titleController.text.trim();
    final parsed = _ExpenseDetailPage._parseEurToCents(_amountController.text);
    final children = await _childrenFuture;
    final effectiveSelectedChildIds = _effectiveSelectedChildIds(children);
    final parentSplitSnapshot = _parentSplitSnapshot;
    if (title.isEmpty) {
      if (mounted) {
        setState(() => _titleHasError = true);
        _titleFocusNode.requestFocus();
      }
      return;
    }
    if (title.length > _kAddExpenseTitleMaxLength) {
      if (mounted) {
        setState(() => _titleHasError = true);
        _titleFocusNode.requestFocus();
      }
      return;
    }
    if (parsed == null || parsed <= 0) {
      // Rules eisen `amountCents > 0` op recurring masters; verlaag de drempel
      // niet stilzwijgend naar 0 zoals bij gewone instance-edits.
      if (mounted) {
        setState(() => _amountHasError = true);
        _amountFocusNode.requestFocus();
      }
      return;
    }
    if (_didChangeChildSelection && effectiveSelectedChildIds.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecteer minimaal één kind.')),
      );
      return;
    }
    if (parentSplitSnapshot == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Uitgavenverdeling kon niet laden.')),
      );
      return;
    }
    setState(() => _saving = true);
    if (!await _checkCanWriteNow()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Je bent offline, probeer het later opnieuw'),
        ),
      );
      setState(() => _saving = false);
      return;
    }
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      final masterRef = FirebaseFirestore.instance.doc(
        'households/${widget.householdId}/recurringExpenses/${widget.masterId}',
      );
      final fresh = await masterRef.get(
        const GetOptions(source: Source.server),
      );
      final freshData = fresh.data();
      final currentTitle =
          ((freshData?['title'] as String?) ?? widget.currentTitle).trim();
      final currentChildIds =
          (freshData?['childIds'] as List?)?.whereType<String>().toList() ??
          widget.currentChildIds;
      final fromCents =
          (freshData?['amountCents'] as num?)?.toInt() ??
          widget.currentAmountCents;
      final titleChanged = title != currentTitle;
      final amountChanged = parsed != fromCents;
      final childIdsChanged =
          _didChangeChildSelection &&
          !_sameChildIds(effectiveSelectedChildIds, currentChildIds);
      final currentParentSplitSnapshot =
          _tryReadRecurringParentSplit(freshData) ??
          widget.currentParentSplitSnapshot;
      final splitChanged =
          _didChangeParentSplit ||
          currentParentSplitSnapshot == null ||
          currentParentSplitSnapshot.share0Bps !=
              parentSplitSnapshot.share0Bps ||
          !_sameChildIds(
            currentParentSplitSnapshot.participantUids,
            parentSplitSnapshot.participantUids,
          );
      // Elke interactie met de due-date-picker telt als schedule-wijziging:
      // de gekozen datum is semantisch de eerstvolgende concrete datum
      // waarop deze master weer moet vallen, dus `dueDayOfMonth` én
      // `materializeFromDate` komen uit diezelfde picked-datum.
      final scheduleChanged = _pickedDueDate != null;
      if (!amountChanged &&
          !titleChanged &&
          !childIdsChanged &&
          !splitChanged &&
          !scheduleChanged) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _showNoChangesMessage = true;
        });
        return;
      }
      // Redenplicht is op de master-editflow bewust weggehaald; ook voor
      // bedragwijzigingen schrijven we in deze stap geen changes-doc.
      final updateMap = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (titleChanged) updateMap['title'] = title;
      if (amountChanged) updateMap['amountCents'] = parsed;
      if (childIdsChanged) updateMap['childIds'] = effectiveSelectedChildIds;
      if (splitChanged) {
        updateMap.addAll(_recurringParentSplitFields(parentSplitSnapshot));
      }
      if (scheduleChanged) {
        // De picked-datum is de eerstvolgende concrete vervaldatum.
        // `dueDayOfMonth` volgt de dagcomponent; `materializeFromDate`
        // wordt de picked-datum zelf om 00:00 lokaal, zodat de runner
        // niet eerder dan die datum kan materialiseren. Bestaande echte
        // expense-instances blijven ongemoeid.
        final picked = _pickedDueDate!;
        final pickedDay0 = DateTime(picked.year, picked.month, picked.day);
        updateMap['dueDayOfMonth'] = picked.day;
        updateMap['materializeFromDate'] = Timestamp.fromDate(pickedDay0);
      }
      await masterRef.update(updateMap);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Edit recurring master error: $e');
      }
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            mapUserFacingError(
              e,
              fallback: 'Opslaan mislukt. Probeer opnieuw.',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogContentW = (screenW - 80.0).clamp(280.0, 320.0);
    final subtleErrorHintStyle = Theme.of(context).textTheme.bodySmall
        ?.copyWith(
          color: Theme.of(context).colorScheme.error.withValues(alpha: 0.85),
          fontSize: 12,
          fontWeight: FontWeight.w400,
        );
    final subtleErrorInputStyle = Theme.of(context).textTheme.bodyLarge
        ?.copyWith(
          color: Theme.of(context).colorScheme.error.withValues(alpha: 0.88),
          fontWeight: FontWeight.w400,
        );
    final titleTrimmed = _titleController.text.trim();
    final titleErrorHint = titleTrimmed.isEmpty
        ? 'Vul een titel in'
        : 'Titel mag maximaal $_kAddExpenseTitleMaxLength tekens hebben.';
    final parentSplitSummary = _parentSplitSnapshot == null
        ? (_loadingParentSplit ? 'Laden…' : 'Niet beschikbaar')
        : _formatParentSplitCompact(
            _parentSplitSnapshot!,
            FirebaseAuth.instance.currentUser?.uid,
          );
    final textTheme = Theme.of(context).textTheme;
    final metaLabelStyle = textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w400,
      color: onSurface(context, a84),
    );
    final metaValueStyle = textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w500,
      color: onSurface(context, a84),
    );
    final metaActionStyle = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      title: kiduActionDialogTitle(context, 'Maandelijkse uitgave bewerken'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: SizedBox(
          width: dialogContentW,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                TextField(
                  controller: _titleController,
                  focusNode: _titleFocusNode,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.next,
                  maxLength: _kAddExpenseTitleMaxLength,
                  onTap: () {
                    if (_titleHasError) {
                      setState(() => _titleHasError = false);
                    }
                  },
                  onChanged: (_) {
                    if (_showNoChangesMessage) {
                      setState(() => _showNoChangesMessage = false);
                    }
                    if (_titleHasError) {
                      setState(() => _titleHasError = false);
                    }
                  },
                  buildCounter:
                      (
                        context, {
                        required int currentLength,
                        required bool isFocused,
                        required int? maxLength,
                      }) => null,
                  decoration: kiduCompactInputDecoration(
                    labelText: 'Titel',
                    hintText: _titleHasError ? titleErrorHint : null,
                  ).copyWith(
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    border: const OutlineInputBorder(),
                    hintStyle: _titleHasError ? subtleErrorHintStyle : null,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _amountController,
                  focusNode: _amountFocusNode,
                  style: _amountHasError ? subtleErrorInputStyle : null,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onTap: () {
                    if (_amountHasError) {
                      setState(() => _amountHasError = false);
                    }
                  },
                  onChanged: (value) {
                    if (_showNoChangesMessage) {
                      setState(() => _showNoChangesMessage = false);
                    }
                    final parsed = _ExpenseDetailPage._parseEurToCents(
                      _amountController.text,
                    );
                    final trimmed = value.trim();
                    final nextAmountHasError =
                        trimmed.isNotEmpty && (parsed == null || parsed < 0);
                    if (nextAmountHasError != _amountHasError) {
                      setState(() {
                        _amountHasError = nextAmountHasError;
                      });
                    }
                  },
                  decoration: kiduCompactInputDecoration(
                    labelText: 'Bedrag (EUR)',
                    hintText: _amountHasError
                        ? 'Vul een geldig bedrag in'
                        : null,
                  ).copyWith(
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    border: const OutlineInputBorder(),
                    hintStyle: _amountHasError ? subtleErrorHintStyle : null,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: 'Vervaldag: ',
                                    style: metaLabelStyle,
                                  ),
                                  TextSpan(
                                    text: 'Op de ${_selectedDueDay}e',
                                    style: metaValueStyle,
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton(
                            onPressed: _saving ? null : _pickDueDay,
                            style: metaActionStyle,
                            child: const Text('Wijzigen'),
                          ),
                        ],
                      ),
                      if (_selectedDueDay > 28)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            'In kortere maanden geldt de laatste dag van de maand.',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: onSurface(context, a55),
                                  height: 1.35,
                                ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_syncChildren != null)
                  _recurringMasterVoorChildrenSlot(
                    context,
                    children: _syncChildren!,
                    waiting: false,
                    selectionDataReady: true,
                    metaLabelStyle: metaLabelStyle,
                    metaValueStyle: metaValueStyle,
                    metaActionStyle: metaActionStyle,
                  )
                else
                  FutureBuilder<List<_ChildItem>>(
                    future: _childrenFuture,
                    builder: (context, snap) {
                      final waiting =
                          snap.connectionState == ConnectionState.waiting &&
                          !snap.hasData;
                      if (waiting) return const SizedBox.shrink();
                      final children = snap.data ?? const <_ChildItem>[];
                      return _recurringMasterVoorChildrenSlot(
                        context,
                        children: children,
                        waiting: false,
                        selectionDataReady: snap.hasData,
                        metaLabelStyle: metaLabelStyle,
                        metaValueStyle: metaValueStyle,
                        metaActionStyle: metaActionStyle,
                      );
                    },
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: 'Verdeling: ',
                                style: metaLabelStyle,
                              ),
                              TextSpan(
                                text: parentSplitSummary,
                                style: metaValueStyle,
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed:
                            (_saving ||
                                _loadingParentSplit ||
                                _parentSplitSnapshot == null)
                            ? null
                            : _openParentSplitDialog,
                        style: metaActionStyle,
                        child: const Text('Wijzigen'),
                      ),
                    ],
                  ),
                ),
                if (_showNoChangesMessage)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'Er zijn geen wijzigingen.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.error.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Annuleren'),
        ),
        FilledButton(
          style: kiduDialogPrimaryButtonStyle(context),
          onPressed: (_saving || _loadingParentSplit) ? null : () => _submit(),
          child: SizedBox(
            width: 82,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Text('Opslaan'),
                if (_saving)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context)
                            .colorScheme
                            .onSecondaryContainer,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ExpenseDetailPageState extends State<_ExpenseDetailPage> {
  bool _noteActionBusy = false;
  bool _isLoadingExpenseHistory = false;
  List<String>? _resolvedChildNamesIds;
  Future<List<String>>? _resolvedChildNamesFuture;
  late final Future<List<_ChildItem>> _expenseEditChildrenFuture;

  @override
  void initState() {
    super.initState();
    _expenseEditChildrenFuture = _loadRecurringMasterEditChildren(
      widget.householdId,
    );
  }

  void _handleBack() {
    Navigator.of(context).pop();
  }

  void _showExpenseSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  bool _sameChildIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  List<String>? _initialChildNamesFor(List<String> currentChildIds) {
    final childNames = widget.childNames;
    if (childNames == null || childNames.length != currentChildIds.length) {
      return null;
    }
    if (!_sameChildIds(currentChildIds, widget.childIds)) {
      return null;
    }
    if (childNames.contains('Verwijderd kind')) {
      return null;
    }
    return childNames;
  }

  Future<List<String>> _childNamesFutureFor(List<String> currentChildIds) {
    if (_resolvedChildNamesIds != null &&
        _resolvedChildNamesFuture != null &&
        _sameChildIds(_resolvedChildNamesIds!, currentChildIds)) {
      return _resolvedChildNamesFuture!;
    }
    _resolvedChildNamesIds = List<String>.from(
      currentChildIds,
      growable: false,
    );
    _resolvedChildNamesFuture = _ExpenseDetailPage._resolveChildNames(
      widget.householdId,
      currentChildIds,
    );
    return _resolvedChildNamesFuture!;
  }

  Widget _buildChangeHistoryButton() {
    const radius = 12.0;
    final borderRadius = BorderRadius.circular(radius);
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Material(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        shape: RoundedRectangleBorder(
          borderRadius: borderRadius,
          side: BorderSide(color: outlineV(context, a32)),
        ),
        child: InkWell(
          borderRadius: borderRadius,
          onTap: _isLoadingExpenseHistory
              ? null
              : _openExpenseAuditHistorySheet,
          child: SizedBox(
            height: 38,
            width: double.infinity,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.history_outlined,
                    size: 17,
                    color: onSurface(context, a60),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    _isLoadingExpenseHistory
                        ? 'Geschiedenis laden…'
                        : 'Wijzigingsgeschiedenis',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: onSurface(context, a60),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openExpenseAuditHistorySheet() async {
    if (_isLoadingExpenseHistory) return;
    setState(() => _isLoadingExpenseHistory = true);
    try {
      final payload = await _loadExpenseAuditHistoryPayload(
        householdId: widget.householdId,
        expenseId: widget.expenseId,
        initialChildNameById: widget.initialChildNameById,
      );
      if (!mounted) return;
      setState(() => _isLoadingExpenseHistory = false);
      if (!mounted) return;
      _presentExpenseAuditHistorySheet(payload);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingExpenseHistory = false);
      _showExpenseSnackBar('Wijzigingsgeschiedenis kan niet worden geladen');
    }
  }

  void _presentExpenseAuditHistorySheet(_ExpenseAuditHistoryPayload payload) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (sheetContext) {
        final maxH = min(480.0, MediaQuery.of(sheetContext).size.height * 0.85);
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 24,
              right: 24,
              top: 8,
              bottom: 24 + MediaQuery.of(sheetContext).viewInsets.bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxH),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Wijzigingsgeschiedenis',
                    style: Theme.of(sheetContext).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  _ExpenseAuditHistorySheetContent(
                    payload: payload,
                    viewerUid: widget.uid,
                    maxScrollHeight: maxH - 72,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildChildTile(List<String> childNames) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          'Voor',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: onSurface(context, a70)),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            _ExpenseDetailPage._formatChildNamesInline(childNames),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ),
    );
  }

  Future<void> _openEditAmountDialog({
    required int currentAmountCents,
    required String currentTitle,
    required List<String> currentChildIds,
    ParentSplitSnapshot? initialExpenseSplit,
    required List<_ParentSplitMember> initialParentSplitMembers,
  }) async {
    if (!await _checkCanWriteNow()) {
      if (mounted) {
        _showExpenseSnackBar('Je bent offline, probeer het later opnieuw');
      }
      return;
    }
    if (!mounted) return;
    List<_ChildItem>? preload;
    try {
      preload = await _expenseEditChildrenFuture;
    } catch (_) {
      preload = null;
    }
    if (!mounted) return;
    await showDialog<bool>(
      context: context,
      useSafeArea: true,
      barrierDismissible: false,
      builder: (context) => Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  final keyboardVisible =
                      MediaQuery.of(context).viewInsets.bottom > 0;
                  if (keyboardVisible) {
                    FocusManager.instance.primaryFocus?.unfocus();
                    return;
                  }
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                },
                child: const SizedBox.expand(),
              ),
            ),
            GestureDetector(
              onTap: () {},
              child: _EditExpenseAmountDialog(
                householdId: widget.householdId,
                expenseId: widget.expenseId,
                currentAmountCents: currentAmountCents,
                currentTitle: currentTitle,
                currentChildIds: currentChildIds,
                childrenFuture: _expenseEditChildrenFuture,
                initialChildren: preload,
                initialParentSplitMembers: initialParentSplitMembers,
                initialExpenseSplit: initialExpenseSplit,
                initialCreatedAt: widget.createdAt,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _expenseEditTonalButtonStream({required bool wrapWithTopPadding}) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .doc('households/${widget.householdId}/expenses/${widget.expenseId}')
          .snapshots(),
      builder: (context, expSnap) {
        final ed = expSnap.data?.data();
        final currentTitle = ((ed?['title'] as String?) ?? widget.title).trim();
        final currentCents =
            (ed?['amountCents'] as num?)?.toInt() ?? widget.amountCents;
        final currentChildIds =
            (ed?['childIds'] as List?)?.whereType<String>().toList() ??
            widget.childIds;
        final button = FilledButton.tonalIcon(
          onPressed: () => _openEditAmountDialog(
            currentAmountCents: currentCents,
            currentTitle: currentTitle.isEmpty ? widget.title : currentTitle,
            currentChildIds: currentChildIds,
            initialExpenseSplit: ParentSplitSnapshot.tryReadFromExpense(
              ed ?? const <String, dynamic>{},
            ),
            initialParentSplitMembers: widget.parentSplitMembers,
          ),
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: Text('Uitgave', style: Theme.of(context).textTheme.bodyMedium),
        );
        if (wrapWithTopPadding) {
          return Padding(
            padding: const EdgeInsets.only(top: 16),
            child: button,
          );
        }
        return button;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          leading: BackButton(onPressed: _handleBack),
          title: Text(
            'Uitgave',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: FirebaseFirestore.instance
                        .doc(
                          'households/${widget.householdId}/expenses/${widget.expenseId}',
                        )
                        .snapshots(),
                    builder: (context, expSnap) {
                      final ed = expSnap.data?.data();
                      final currentTitle =
                          ((ed?['title'] as String?) ?? widget.title).trim();
                      final displayTitle = currentTitle.isEmpty
                          ? widget.title
                          : currentTitle;
                      final currentCents =
                          (ed?['amountCents'] as num?)?.toInt() ??
                          widget.amountCents;
                      final textTheme = Theme.of(context).textTheme;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayTitle,
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _ExpenseDetailPage._formatEur(currentCents),
                            style: textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Betaald door ${widget.paidByName.trim().isEmpty ? 'Co-parent' : widget.paidByName.trim()}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: FirebaseFirestore.instance
                        .doc(
                          'households/${widget.householdId}/expenses/${widget.expenseId}',
                        )
                        .snapshots(),
                    builder: (context, expSnap) {
                      final ed = expSnap.data?.data();
                      final currentChildIds =
                          (ed?['childIds'] as List?)
                              ?.whereType<String>()
                              .toList() ??
                          widget.childIds;
                      final parentSplitSnapshot =
                          ParentSplitSnapshot.tryReadFromExpense(
                            ed ?? const {},
                          ) ??
                          widget.parentSplitSnapshot;
                      final effectiveSplit =
                          parentSplitSnapshot ??
                          _neutralParentSplitForMembers(
                            widget.parentSplitMembers,
                          );
                      final splitLine = effectiveSplit == null
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  _formatParentSplitNamed(
                                    effectiveSplit,
                                    widget.parentSplitMembers,
                                    widget.uid,
                                  ),
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            );
                      final dateLine = Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            _ExpenseDetailPage._formatDateTime(
                              widget.createdAt,
                            ),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: onSurface(context, a58),
                                  height: 1.35,
                                ),
                          ),
                        ),
                      );
                      if (!widget.showChildContext || currentChildIds.isEmpty) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [splitLine, dateLine],
                        );
                      }
                      final initialChildNames = _initialChildNamesFor(
                        currentChildIds,
                      );
                      if (initialChildNames != null) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            splitLine,
                            dateLine,
                            _buildChildTile(initialChildNames),
                          ],
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          splitLine,
                          dateLine,
                          FutureBuilder<List<String>>(
                            future: _childNamesFutureFor(currentChildIds),
                            builder: (context, snap) {
                              if (!snap.hasData) {
                                return const SizedBox.shrink();
                              }
                              return _buildChildTile(snap.data!);
                            },
                          ),
                        ],
                      );
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: widget.isPending
                              ? [
                                  Icon(
                                    Icons.cloud_off,
                                    size: 16,
                                    color: onSurface(context, a60),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Nog niet gesynchroniseerd',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: onSurface(context, a60),
                                          height: 1.35,
                                        ),
                                  ),
                                ]
                              : [
                                  Icon(
                                    Icons.check_circle_outline,
                                    size: 14,
                                    color: onSurface(context, a50),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Gesynchroniseerd',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: onSurface(context, a55),
                                          height: 1.35,
                                        ),
                                  ),
                                ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: FirebaseFirestore.instance
                        .doc(
                          'households/${widget.householdId}/expenses/${widget.expenseId}',
                        )
                        .snapshots(),
                    builder: (context, expSnap) {
                      final expenseData = expSnap.data?.data();
                      final hasAuditHistory =
                          expenseData?['hasAuditHistory'] == true;
                      return StreamBuilder<
                        DocumentSnapshot<Map<String, dynamic>>
                      >(
                        stream: FirebaseFirestore.instance
                            .doc(
                              'households/${widget.householdId}/expenses/${widget.expenseId}/privateNotes/${_ExpenseDetailPage._privateNotesDocUid(widget.createdByUid)}',
                            )
                            .snapshots(),
                        builder: (context, snap) {
                          final isCreator =
                              widget.uid.trim() == widget.createdByUid.trim();
                          if (snap.hasError) {
                            if (!isCreator) {
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (hasAuditHistory)
                                    _buildChangeHistoryButton(),
                                ],
                              );
                            }
                            final currentTitle =
                                ((expenseData?['title'] as String?) ??
                                        widget.title)
                                    .trim();
                            final currentCents =
                                (expenseData?['amountCents'] as num?)
                                    ?.toInt() ??
                                widget.amountCents;
                            final currentChildIds =
                                (expenseData?['childIds'] as List?)
                                    ?.whereType<String>()
                                    .toList() ??
                                widget.childIds;
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  'Kon notitie niet laden.',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: onSurface(context, a55),
                                        height: 1.35,
                                      ),
                                ),
                                if (hasAuditHistory)
                                  _buildChangeHistoryButton(),
                                if (widget.onManageNote != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: FilledButton.tonalIcon(
                                      onPressed: _noteActionBusy
                                          ? null
                                          : () async {
                                              if (_noteActionBusy) return;
                                              setState(
                                                () => _noteActionBusy = true,
                                              );
                                              try {
                                                await widget.onManageNote!();
                                              } finally {
                                                if (mounted) {
                                                  setState(
                                                    () =>
                                                        _noteActionBusy = false,
                                                  );
                                                }
                                              }
                                            },
                                      icon: const Icon(
                                        Icons.note_add_outlined,
                                        size: 18,
                                      ),
                                      label: Text(
                                        'Notitie',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodyMedium,
                                      ),
                                    ),
                                  ),
                                if (isCreator)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: FilledButton.tonalIcon(
                                      onPressed: () => _openEditAmountDialog(
                                        currentAmountCents: currentCents,
                                        currentTitle: currentTitle.isEmpty
                                            ? widget.title
                                            : currentTitle,
                                        currentChildIds: currentChildIds,
                                        initialExpenseSplit:
                                            ParentSplitSnapshot.tryReadFromExpense(
                                              expenseData ??
                                                  const <String, dynamic>{},
                                            ),
                                        initialParentSplitMembers:
                                            widget.parentSplitMembers,
                                      ),
                                      icon: const Icon(
                                        Icons.edit_outlined,
                                        size: 18,
                                      ),
                                      label: Text(
                                        'Uitgave',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodyMedium,
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          }

                          final data = snap.data?.data();
                          final note = (data?['note'] as String?)?.trim() ?? '';
                          final hasNoteLive = note.isNotEmpty;
                          final sharedWithViewer =
                              _ExpenseDetailPage._privateNoteIsSharedWithViewer(
                                data,
                                widget.uid,
                              );
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (isCreator && hasNoteLive)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    'Notitie',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: onSurface(context, a70),
                                        ),
                                  ),
                                  subtitle: Text(note),
                                ),
                              if (!isCreator && sharedWithViewer && hasNoteLive)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    'Gedeelde notitie',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: onSurface(context, a70),
                                        ),
                                  ),
                                  subtitle: Text(note),
                                ),
                              if (hasAuditHistory) _buildChangeHistoryButton(),
                              if (widget.onManageNote != null && isCreator)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      Expanded(
                                        child: FilledButton.tonalIcon(
                                          onPressed: _noteActionBusy
                                              ? null
                                              : () async {
                                                  if (_noteActionBusy) return;
                                                  setState(
                                                    () =>
                                                        _noteActionBusy = true,
                                                  );
                                                  try {
                                                    await widget
                                                        .onManageNote!();
                                                  } finally {
                                                    if (mounted) {
                                                      setState(
                                                        () => _noteActionBusy =
                                                            false,
                                                      );
                                                    }
                                                  }
                                                },
                                          icon: Icon(
                                            hasNoteLive
                                                ? Icons.edit_note
                                                : Icons.note_add_outlined,
                                            size: 18,
                                          ),
                                          label: Text(
                                            hasNoteLive ? 'Notitie' : 'Notitie',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodyMedium,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: _expenseEditTonalButtonStream(
                                          wrapWithTopPadding: false,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              if (isCreator && widget.onManageNote == null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: _expenseEditTonalButtonStream(
                                    wrapWithTopPadding: false,
                                  ),
                                ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PaymentDetailPage extends StatelessWidget {
  const _PaymentDetailPage({
    required this.title,
    required this.amountCents,
    required this.status,
    required this.createdAt,
    this.confirmedAt,
    this.statusExplanation,
  });

  final String title;
  final int amountCents;
  final String status;
  final DateTime? createdAt;
  final DateTime? confirmedAt;
  final String? statusExplanation;

  @override
  Widget build(BuildContext context) {
    final isConfirmed = status == 'confirmed';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          leading: BackButton(onPressed: () => Navigator.of(context).pop()),
          title: Text(
            'Betaling',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _ExpenseDetailPage._formatEur(amountCents),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        title,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Aangemaakt',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: onSurface(context, a70),
                      ),
                    ),
                    subtitle: Text(
                      _ExpenseDetailPage._formatDateTime(createdAt),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Status',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: onSurface(context, a70),
                      ),
                    ),
                    subtitle: isConfirmed
                        ? Row(
                            children: [
                              Icon(
                                Icons.check_circle,
                                size: 16,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              const Text('Bevestigd'),
                            ],
                          )
                        : Row(
                            children: [
                              Icon(
                                Icons.schedule,
                                size: 16,
                                color: onSurface(context, a60),
                              ),
                              const SizedBox(width: 6),
                              const Text('In afwachting'),
                            ],
                          ),
                  ),
                  if (isConfirmed && confirmedAt != null)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Bevestigd op',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: onSurface(context, a70),
                        ),
                      ),
                      subtitle: Text(
                        _ExpenseDetailPage._formatDateTime(confirmedAt),
                      ),
                    ),
                  if (statusExplanation != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      statusExplanation!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: onSurface(context, a55),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Logboek – read-only expense history with child filter
// ────────────────────────────────────────────────────────────────────────────

enum _PeriodFilter { all, custom }

enum _LogboekMode { uitgaven, wijzigingen, betalingen }

class _WijzigRow {
  const _WijzigRow({
    required this.expenseId,
    required this.title,
    required this.fromAmountCents,
    required this.toAmountCents,
    required this.reason,
    required this.editedBy,
    required this.editedAt,
    required this.expenseAmountCents,
    required this.childIds,
    required this.createdBy,
    required this.createdAt,
    required this.parentSplitSnapshot,
    required this.isMaterializedMonthly,
  });

  final String expenseId;
  final String title;
  final int fromAmountCents;
  final int toAmountCents;
  final String reason;
  final String editedBy;
  final DateTime editedAt;
  final int expenseAmountCents;
  final List<String> childIds;
  final String createdBy;
  final DateTime? createdAt;
  final ParentSplitSnapshot? parentSplitSnapshot;
  final bool isMaterializedMonthly;
}

/// Logboek → Wijzigingen row (één registratie/save-actie; export gebruikt [_WijzigRow]).
class _WijzigLogbookRow {
  const _WijzigLogbookRow({
    required this.registrationKey,
    required this.expenseId,
    required this.title,
    required this.editedBy,
    required this.editedAt,
    required this.displayAmountCents,
    required this.hasAmountChange,
    required this.hasChildrenChange,
    required this.hasSplitChange,
    required this.childIds,
    required this.createdBy,
    required this.createdAt,
    required this.parentSplitSnapshot,
    required this.isMaterializedMonthly,
    this.changeBatchId,
    this.fromAmountCents,
    this.toAmountCents,
    this.reason,
  });

  final String registrationKey;
  final String expenseId;
  final String title;
  final String editedBy;
  final DateTime editedAt;
  final int displayAmountCents;
  final bool hasAmountChange;
  final bool hasChildrenChange;
  final bool hasSplitChange;
  final List<String> childIds;
  final String createdBy;
  final DateTime? createdAt;
  final ParentSplitSnapshot? parentSplitSnapshot;
  final bool isMaterializedMonthly;
  final String? changeBatchId;
  final int? fromAmountCents;
  final int? toAmountCents;
  final String? reason;

  /// Huidig parent expense-bedrag op loadtijd (navigatie naar detail).
  int get expenseAmountCents => displayAmountCents;
}

/// Keeps each Logboek [TabBarView] page subtree alive to reduce rebuild work when swiping.
class _LogboekTabKeepAlive extends StatefulWidget {
  const _LogboekTabKeepAlive({required this.builder});

  final Widget Function(BuildContext context) builder;

  @override
  State<_LogboekTabKeepAlive> createState() => _LogboekTabKeepAliveState();
}

class _LogboekTabKeepAliveState extends State<_LogboekTabKeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.builder(context);
  }
}

class _LogboekPage extends StatefulWidget {
  const _LogboekPage({
    required this.householdId,
    required this.uid,
    this.myName,
    this.otherName,
  });

  final String householdId;
  final String uid;
  final String? myName;
  final String? otherName;

  @override
  State<_LogboekPage> createState() => _LogboekPageState();
}

class _LogboekPageState extends State<_LogboekPage>
    with SingleTickerProviderStateMixin {
  static const int _logboekVisibleRowCount = 9;
  static const double _logboekListRowExtent = 64;
  static const double _logboekListSeparatorExtent = 14;
  static const double _wijzigingTrailingWidth = 154;
  static const double _wijzigingIconSlotWidth = 20;
  static const double _wijzigingIconSlotGap = 4;
  static const double _wijzigingIconToAmountGap = 14;
  static const double _wijzigingAmountColumnWidth = 72;
  List<_ChildItem> _children = [];
  Map<String, String> _childNameById = const {};
  bool _childrenLoaded = false;
  bool _hasMultipleHouseholdChildDocs = true;
  List<({String uid, String name})> _parentItems = [];
  bool _parentsLoaded = false;
  String? _filterChildId; // null = alle kinderen, anders één kind
  String? _filterParentUid; // null = allebei ouders (geen createdBy-filter)
  _PeriodFilter _periodFilter = _PeriodFilter.all;
  DateTime? _filterStart;
  DateTime? _filterEnd;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _expensesStream;
  String? _paymentFilterParentUid; // null = beide ouders

  /// null = beide ouders; otherwise filter amount edits by [editedBy] uid.
  String? _wijzigFilterEditedByUid;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _paymentsStream;
  late final TabController _modeTabController;
  bool _isOffline = false;

  /// Memo for [FutureBuilder] in [_buildWijzigingenList].
  String? _wijzigLogbookRowsLoadKey;
  Future<List<_WijzigLogbookRow>>? _wijzigLogbookRowsFuture;
  String? _wijzigWarmPreloadKey;

  double get _logboekListCardHeight =>
      (_logboekVisibleRowCount * _logboekListRowExtent) +
      ((_logboekVisibleRowCount - 1) * _logboekListSeparatorExtent) +
      (12 * 2);

  String _wijzigExpenseDocsSignature(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> expenseDocs,
  ) {
    final parts = expenseDocs
        .map((d) => _expenseDocWijzigLogbookSignature(d.id, d.data()))
        .toList()
      ..sort();
    return parts.join('|');
  }

  void _maybeWarmPreloadWijzigLogbookRows(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> expenseDocs,
  ) {
    if (expenseDocs.isEmpty) return;
    final sig = _wijzigExpenseDocsSignature(expenseDocs);
    final preloadKey =
        '${_periodFilter}_${_filterStart}_${_filterEnd}_${_wijzigFilterEditedByUid}_$sig';
    if (_wijzigWarmPreloadKey == preloadKey) return;
    _wijzigWarmPreloadKey = preloadKey;
    _wijzigLogbookRowsFutureFor(expenseDocs, sig);
  }

  Future<List<_WijzigLogbookRow>> _wijzigLogbookRowsFutureFor(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> expenseDocs,
    String expenseDocsSig,
  ) {
    final loadKey =
        '${_periodFilter}_${_filterStart}_${_filterEnd}_${_wijzigFilterEditedByUid}_${_wijzigExpenseDocsSignature(expenseDocs)}';
    if (_wijzigLogbookRowsLoadKey != loadKey) {
      _wijzigLogbookRowsLoadKey = loadKey;
      _wijzigLogbookRowsFuture = _loadWijzigLogbookRows(expenseDocs);
    }
    return _wijzigLogbookRowsFuture!;
  }

  String _formatWijzigingDate(DateTime dt) {
    const nlMonths = <String>[
      'jan',
      'feb',
      'mrt',
      'apr',
      'mei',
      'jun',
      'jul',
      'aug',
      'sep',
      'okt',
      'nov',
      'dec',
    ];
    return '${dt.day} ${nlMonths[dt.month - 1]}';
  }

  Widget _wijzigingTrailingIconSlot(BuildContext context, IconData? icon) {
    final iconColor = onSurface(context, a70);
    return SizedBox(
      width: _wijzigingIconSlotWidth,
      height: _wijzigingIconSlotWidth,
      child: icon == null
          ? const SizedBox.shrink()
          : Icon(icon, size: _wijzigingIconSlotWidth, color: iconColor),
    );
  }

  Widget _buildWijzigingTrailing(BuildContext context, _WijzigLogbookRow row) {
    final baseStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final iconBlockWidth =
        _wijzigingIconSlotWidth * 3 + _wijzigingIconSlotGap * 2;

    return SizedBox(
      width: _wijzigingTrailingWidth,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: iconBlockWidth,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _wijzigingTrailingIconSlot(
                  context,
                  row.hasChildrenChange ? Icons.child_care_outlined : null,
                ),
                const SizedBox(width: _wijzigingIconSlotGap),
                _wijzigingTrailingIconSlot(
                  context,
                  row.hasSplitChange ? Icons.percent_outlined : null,
                ),
                const SizedBox(width: _wijzigingIconSlotGap),
                _wijzigingTrailingIconSlot(
                  context,
                  row.hasAmountChange ? Icons.payments_outlined : null,
                ),
              ],
            ),
          ),
          const SizedBox(width: _wijzigingIconToAmountGap),
          SizedBox(
            width: _wijzigingAmountColumnWidth,
            child: Text(
              _fmtEur(row.displayAmountCents),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.fade,
              textAlign: TextAlign.right,
              style: baseStyle,
            ),
          ),
        ],
      ),
    );
  }

  Query<Map<String, dynamic>> _basePeriodQuery() {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection(
      'households/${widget.householdId}/expenses',
    );
    if (_periodFilter != _PeriodFilter.all &&
        _filterStart != null &&
        _filterEnd != null) {
      q = q
          .where(
            'createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(_filterStart!),
          )
          .where('createdAt', isLessThan: Timestamp.fromDate(_filterEnd!));
    }
    return q;
  }

  void _rebuildExpensesStream() {
    Query<Map<String, dynamic>> q = _basePeriodQuery();

    if (_filterParentUid != null) {
      q = q.where('createdBy', isEqualTo: _filterParentUid);
    }
    if (_filterChildId != null) {
      q = q.where('childIds', arrayContains: _filterChildId);
    }

    q = q.orderBy('createdAt', descending: true);
    _expensesStream = q.snapshots();
  }

  void _rebuildPaymentsStream() {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection(
      'households/${widget.householdId}/payments',
    );
    if (_periodFilter != _PeriodFilter.all &&
        _filterStart != null &&
        _filterEnd != null) {
      q = q
          .where(
            'createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(_filterStart!),
          )
          .where('createdAt', isLessThan: Timestamp.fromDate(_filterEnd!));
    }
    q = q.orderBy('createdAt', descending: true);
    _paymentsStream = q.snapshots();
  }

  bool get _uitgavenFiltersActive {
    if (_periodFilter != _PeriodFilter.all) return true;
    if (_filterParentUid != null) return true;
    if (_filterChildId != null) return true;
    return false;
  }

  bool _logboekFilterIconActiveFor(_LogboekMode mode) {
    if (mode == _LogboekMode.uitgaven) {
      return _uitgavenFiltersActive;
    }
    if (mode == _LogboekMode.betalingen) {
      if (_paymentFilterParentUid != null) return true;
      return _periodFilter != _PeriodFilter.all;
    }
    if (_wijzigFilterEditedByUid != null) return true;
    return _periodFilter != _PeriodFilter.all;
  }

  _LogboekMode _activeLogboekModeFromTabController() {
    final i = _modeTabController.index.clamp(0, _LogboekMode.values.length - 1);
    return _LogboekMode.values[i];
  }

  @override
  void initState() {
    super.initState();
    _modeTabController = TabController(length: 3, vsync: this);
    _rebuildExpensesStream();
    _rebuildPaymentsStream();
    unawaited(_loadChildren());
    unawaited(_loadParents());
    _checkOffline();
  }

  @override
  void dispose() {
    _modeTabController.dispose();
    super.dispose();
  }

  Future<void> _checkOffline() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance
          .doc('users/$uid')
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      if (mounted) setState(() => _isOffline = true);
    }
  }

  Future<void> _loadChildren() async {
    try {
      final childrenSnap = await FirebaseFirestore.instance
          .collection('households/${widget.householdId}/children')
          .get();

      final docs = childrenSnap.docs.toList()
        ..sort((a, b) {
          final aTs = a.data()['createdAt'];
          final bTs = b.data()['createdAt'];
          if (aTs is Timestamp && bTs is Timestamp) {
            return aTs.compareTo(bTs);
          }
          return 0;
        });

      final childNameById = _childNameByIdFromChildrenSnap(childrenSnap.docs);

      final children = <_ChildItem>[];
      for (final d in docs) {
        final data = d.data();
        final isArchived = data['isArchived'] == true;
        final isDeleted = data['isDeleted'] == true;
        if (!isArchived && !isDeleted) {
          children.add(_ChildItem(id: d.id, name: childNameById[d.id] ?? '?'));
        }
      }

      if (mounted) {
        setState(() {
          _children = children;
          _childNameById = childNameById;
          _childrenLoaded = true;
          _hasMultipleHouseholdChildDocs = childrenSnap.docs.length >= 2;
          if (_filterChildId != null &&
              !_children.any((c) => c.id == _filterChildId)) {
            _filterChildId = null;
            _rebuildExpensesStream();
          }
        });
      }

      unawaited(
        _loadArchivedChildrenUsedInExpenses(
          docs: docs,
          childNameById: childNameById,
          hasMultipleHouseholdChildDocs: childrenSnap.docs.length >= 2,
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _childrenLoaded = true);
    }
  }

  Future<void> _loadArchivedChildrenUsedInExpenses({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    required Map<String, String> childNameById,
    required bool hasMultipleHouseholdChildDocs,
  }) async {
    try {
      final expensesSnap = await FirebaseFirestore.instance
          .collection('households/${widget.householdId}/expenses')
          .get();

      final childIdsWithExpense = <String>{};
      for (final d in expensesSnap.docs) {
        final ids =
            (d.data()['childIds'] as List?)?.whereType<String>() ??
            const <String>[];
        childIdsWithExpense.addAll(ids);
      }

      final children = <_ChildItem>[];
      for (final d in docs) {
        final data = d.data();
        final isArchived = data['isArchived'] == true;
        final isDeleted = data['isDeleted'] == true;
        final active = !isArchived && !isDeleted;
        final hasExpense = childIdsWithExpense.contains(d.id);
        if (active || ((isArchived || isDeleted) && hasExpense)) {
          children.add(_ChildItem(id: d.id, name: childNameById[d.id] ?? '?'));
        }
      }

      if (!mounted) return;
      setState(() {
        _children = children;
        _childNameById = childNameById;
        _childrenLoaded = true;
        _hasMultipleHouseholdChildDocs = hasMultipleHouseholdChildDocs;
        if (_filterChildId != null &&
            !_children.any((c) => c.id == _filterChildId)) {
          _filterChildId = null;
          _rebuildExpensesStream();
        }
      });
    } catch (_) {
      // Active children already loaded; archived filter entries stay deferred.
    }
  }

  Future<void> _loadParents() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('households/${widget.householdId}/members')
          .limit(2)
          .get();
      final uids = snap.docs.map((d) => d.id).toList();
      // Current user first, then others.
      final sorted = [
        if (uids.contains(widget.uid)) widget.uid,
        ...uids.where((id) => id != widget.uid),
      ];
      final items = [
        for (final uid in sorted)
          (
            uid: uid,
            name: uid == widget.uid
                ? (widget.myName ?? 'Jij')
                : (widget.otherName ?? 'Co-parent'),
          ),
      ];
      if (mounted) {
        setState(() {
          _parentItems = items;
          _parentsLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _parentsLoaded = true);
    }
  }

  void _showUitgavenFilterSheet() {
    final pageContext = context;
    final now = DateTime.now();

    Future<void> pickCustomPeriod(StateSetter setModalState) async {
      final initialRange =
          (_periodFilter == _PeriodFilter.custom &&
              _filterStart != null &&
              _filterEnd != null)
          ? DateTimeRange(
              start: _filterStart!,
              end: _filterEnd!.subtract(const Duration(days: 1)),
            )
          : DateTimeRange(
              start: now.subtract(const Duration(days: 29)),
              end: now,
            );
      final range = await showDateRangePicker(
        context: pageContext,
        initialDateRange: initialRange,
        firstDate: DateTime(2020),
        lastDate: DateTime(now.year, now.month, now.day),
      );
      if (range == null || !mounted) return;
      setState(() {
        _periodFilter = _PeriodFilter.custom;
        _filterStart = DateTime(
          range.start.year,
          range.start.month,
          range.start.day,
        );
        _filterEnd = DateTime(
          range.end.year,
          range.end.month,
          range.end.day + 1,
        );
        _rebuildExpensesStream();
        _rebuildPaymentsStream();
      });
      setModalState(() {});
    }

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (sheetContext) {
        final maxH = min(480.0, MediaQuery.of(sheetContext).size.height * 0.65);
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              bottom: 16 + MediaQuery.of(sheetContext).viewInsets.bottom,
            ),
            child: StatefulBuilder(
              builder: (context, setModalState) {
                return ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxH),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                'Filters',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            if (_filterParentUid != null ||
                                _filterChildId != null ||
                                _periodFilter != _PeriodFilter.all)
                              TextButton(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 0,
                                  ),
                                  minimumSize: Size.zero,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _filterParentUid = null;
                                    _filterChildId = null;
                                    _periodFilter = _PeriodFilter.all;
                                    _filterStart = null;
                                    _filterEnd = null;
                                    _rebuildExpensesStream();
                                    _rebuildPaymentsStream();
                                  });
                                  setModalState(() {});
                                },
                                child: const Text('Filters wissen'),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_parentsLoaded && _parentItems.isNotEmpty) ...[
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Ouder',
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(color: onSurface(context, a60)),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilterChip(
                                label: const Text('Beide'),
                                labelStyle: Theme.of(
                                  context,
                                ).textTheme.bodySmall,
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                selected: _filterParentUid == null,
                                showCheckmark: false,
                                onSelected: (_) {
                                  setState(() {
                                    _filterParentUid = null;
                                    _rebuildExpensesStream();
                                  });
                                  setModalState(() {});
                                },
                              ),
                              for (final p in _parentItems)
                                FilterChip(
                                  label: Text(
                                    p.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  labelStyle: Theme.of(
                                    context,
                                  ).textTheme.bodySmall,
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  selected: _filterParentUid == p.uid,
                                  showCheckmark: false,
                                  onSelected: (v) {
                                    setState(() {
                                      _filterParentUid = v ? p.uid : null;
                                      _rebuildExpensesStream();
                                    });
                                    setModalState(() {});
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (_childrenLoaded && _children.length > 1) ...[
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Kind',
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(color: onSurface(context, a60)),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilterChip(
                                label: const Text('Alle'),
                                labelStyle: Theme.of(
                                  context,
                                ).textTheme.bodySmall,
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                selected: _filterChildId == null,
                                showCheckmark: false,
                                onSelected: (_) {
                                  setState(() {
                                    _filterChildId = null;
                                    _rebuildExpensesStream();
                                  });
                                  setModalState(() {});
                                },
                              ),
                              for (final c in _children)
                                FilterChip(
                                  label: Text(
                                    c.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  labelStyle: Theme.of(
                                    context,
                                  ).textTheme.bodySmall,
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  selected: _filterChildId == c.id,
                                  showCheckmark: false,
                                  onSelected: (v) {
                                    setState(() {
                                      _filterChildId = v ? c.id : null;
                                      _rebuildExpensesStream();
                                    });
                                    setModalState(() {});
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Periode',
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(color: onSurface(context, a60)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(_expenseExportPeriodLabel()),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => pickCustomPeriod(setModalState),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  void _showPaymentFilterSheet() {
    final pageContext = context;
    final now = DateTime.now();

    Future<void> pickCustomPeriod(StateSetter setModalState) async {
      final initialRange =
          (_periodFilter == _PeriodFilter.custom &&
              _filterStart != null &&
              _filterEnd != null)
          ? DateTimeRange(
              start: _filterStart!,
              end: _filterEnd!.subtract(const Duration(days: 1)),
            )
          : DateTimeRange(
              start: now.subtract(const Duration(days: 29)),
              end: now,
            );
      final range = await showDateRangePicker(
        context: pageContext,
        initialDateRange: initialRange,
        firstDate: DateTime(2020),
        lastDate: DateTime(now.year, now.month, now.day),
      );
      if (range == null || !mounted) return;
      setState(() {
        _periodFilter = _PeriodFilter.custom;
        _filterStart = DateTime(
          range.start.year,
          range.start.month,
          range.start.day,
        );
        _filterEnd = DateTime(
          range.end.year,
          range.end.month,
          range.end.day + 1,
        );
        _rebuildExpensesStream();
        _rebuildPaymentsStream();
      });
      setModalState(() {});
    }

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (sheetContext) {
        final maxH = min(480.0, MediaQuery.of(sheetContext).size.height * 0.65);
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              bottom: 16 + MediaQuery.of(sheetContext).viewInsets.bottom,
            ),
            child: StatefulBuilder(
              builder: (context, setModalState) {
                return ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxH),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                'Filter',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            if (_paymentFilterParentUid != null ||
                                _periodFilter != _PeriodFilter.all)
                              TextButton(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 0,
                                  ),
                                  minimumSize: Size.zero,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _paymentFilterParentUid = null;
                                    _periodFilter = _PeriodFilter.all;
                                    _filterStart = null;
                                    _filterEnd = null;
                                    _rebuildExpensesStream();
                                    _rebuildPaymentsStream();
                                  });
                                  setModalState(() {});
                                },
                                child: const Text('Filters wissen'),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_parentsLoaded && _parentItems.isNotEmpty) ...[
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Ouder',
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(color: onSurface(context, a60)),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilterChip(
                                label: const Text('Beide'),
                                labelStyle: Theme.of(
                                  context,
                                ).textTheme.bodySmall,
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                selected: _paymentFilterParentUid == null,
                                showCheckmark: false,
                                onSelected: (_) {
                                  setState(() {
                                    _paymentFilterParentUid = null;
                                  });
                                  setModalState(() {});
                                },
                              ),
                              for (final p in _parentItems)
                                FilterChip(
                                  label: Text(
                                    p.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  labelStyle: Theme.of(
                                    context,
                                  ).textTheme.bodySmall,
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  selected: _paymentFilterParentUid == p.uid,
                                  showCheckmark: false,
                                  onSelected: (v) {
                                    setState(() {
                                      _paymentFilterParentUid = v
                                          ? p.uid
                                          : null;
                                    });
                                    setModalState(() {});
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Periode',
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(color: onSurface(context, a60)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(_expenseExportPeriodLabel()),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => pickCustomPeriod(setModalState),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  void _showWijzigingenFilterSheet() {
    final pageContext = context;
    final now = DateTime.now();

    Future<void> pickCustomPeriod(StateSetter setModalState) async {
      final initialRange =
          (_periodFilter == _PeriodFilter.custom &&
              _filterStart != null &&
              _filterEnd != null)
          ? DateTimeRange(
              start: _filterStart!,
              end: _filterEnd!.subtract(const Duration(days: 1)),
            )
          : DateTimeRange(
              start: now.subtract(const Duration(days: 29)),
              end: now,
            );
      final range = await showDateRangePicker(
        context: pageContext,
        initialDateRange: initialRange,
        firstDate: DateTime(2020),
        lastDate: DateTime(now.year, now.month, now.day),
      );
      if (range == null || !mounted) return;
      setState(() {
        _periodFilter = _PeriodFilter.custom;
        _filterStart = DateTime(
          range.start.year,
          range.start.month,
          range.start.day,
        );
        _filterEnd = DateTime(
          range.end.year,
          range.end.month,
          range.end.day + 1,
        );
        _rebuildExpensesStream();
        _rebuildPaymentsStream();
      });
      setModalState(() {});
    }

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (sheetContext) {
        final maxH = min(480.0, MediaQuery.of(sheetContext).size.height * 0.65);
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              bottom: 16 + MediaQuery.of(sheetContext).viewInsets.bottom,
            ),
            child: StatefulBuilder(
              builder: (context, setModalState) {
                return ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxH),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                'Filter',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            if (_wijzigFilterEditedByUid != null ||
                                _periodFilter != _PeriodFilter.all)
                              TextButton(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 0,
                                  ),
                                  minimumSize: Size.zero,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _wijzigFilterEditedByUid = null;
                                    _periodFilter = _PeriodFilter.all;
                                    _filterStart = null;
                                    _filterEnd = null;
                                    _rebuildExpensesStream();
                                    _rebuildPaymentsStream();
                                  });
                                  setModalState(() {});
                                },
                                child: const Text('Filters wissen'),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_parentsLoaded && _parentItems.isNotEmpty) ...[
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Ouder',
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(color: onSurface(context, a60)),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilterChip(
                                label: const Text('Beide'),
                                labelStyle: Theme.of(
                                  context,
                                ).textTheme.bodySmall,
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                selected: _wijzigFilterEditedByUid == null,
                                showCheckmark: false,
                                onSelected: (_) {
                                  setState(() {
                                    _wijzigFilterEditedByUid = null;
                                  });
                                  setModalState(() {});
                                },
                              ),
                              for (final p in _parentItems)
                                FilterChip(
                                  label: Text(
                                    p.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  labelStyle: Theme.of(
                                    context,
                                  ).textTheme.bodySmall,
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  selected: _wijzigFilterEditedByUid == p.uid,
                                  showCheckmark: false,
                                  onSelected: (v) {
                                    setState(() {
                                      _wijzigFilterEditedByUid = v
                                          ? p.uid
                                          : null;
                                    });
                                    setModalState(() {});
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Periode',
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(color: onSurface(context, a60)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(_expenseExportPeriodLabel()),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => pickCustomPeriod(setModalState),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  static String _fmtDateWithYear(DateTime? dt) {
    if (dt == null) return '—';
    const mo = [
      'jan',
      'feb',
      'mrt',
      'apr',
      'mei',
      'jun',
      'jul',
      'aug',
      'sep',
      'okt',
      'nov',
      'dec',
    ];
    return '${dt.day} ${mo[dt.month - 1]} ${dt.year}';
  }

  /// Alleen voor Logboek > Uitgaven CSV-export (`dd-MM-yyyy`).
  static String _fmtExpenseCsvDate(DateTime? dt) {
    if (dt == null) return '—';
    String two(int n) => n.toString().padLeft(2, '0');
    // CSV heeft geen celtype; deze onzichtbare markering voorkomt dat
    // spreadsheets sommige datums automatisch als datum en andere als tekst zien.
    const textMarker = '\u200C';
    return '$textMarker${two(dt.day)}-${two(dt.month)}-${dt.year}';
  }

  static String _fmtEur(int cents) {
    final negative = cents < 0;
    final abs = cents.abs();
    final euros = abs ~/ 100;
    final rem = abs % 100;
    final euroStr = euros.toString();
    final buf = StringBuffer();
    for (var i = 0; i < euroStr.length; i++) {
      if (i > 0 && (euroStr.length - i) % 3 == 0) buf.write('.');
      buf.write(euroStr[i]);
    }
    return '${negative ? '-' : ''}€$buf,${rem.toString().padLeft(2, '0')}';
  }

  static String _fmtDate(DateTime? dt) {
    if (dt == null) return '—';
    const mo = [
      'jan',
      'feb',
      'mrt',
      'apr',
      'mei',
      'jun',
      'jul',
      'aug',
      'sep',
      'okt',
      'nov',
      'dec',
    ];
    return '${dt.day} ${mo[dt.month - 1]}';
  }

  String _expenseExportParentLabel() {
    if (_filterParentUid == null) return 'Beide';
    for (final parent in _parentItems) {
      if (parent.uid == _filterParentUid) return parent.name;
    }
    return 'Beide';
  }

  String _expenseExportChildLabel() {
    if (_filterChildId == null) return 'Alle';
    for (final child in _children) {
      if (child.id == _filterChildId) return child.name;
    }
    return 'Alle';
  }

  String _expenseExportPeriodLabel({String whenAllTime = 'Geen filter'}) {
    if (_periodFilter == _PeriodFilter.custom &&
        _filterStart != null &&
        _filterEnd != null) {
      final inclusiveEnd = _filterEnd!.subtract(const Duration(days: 1));
      if (_filterStart!.year == inclusiveEnd.year &&
          _filterStart!.month == inclusiveEnd.month &&
          _filterStart!.day == inclusiveEnd.day) {
        return _fmtDateWithYear(_filterStart);
      }
      return '${_fmtDateWithYear(_filterStart)} t/m ${_fmtDateWithYear(inclusiveEnd)}';
    }
    return whenAllTime;
  }

  List<({String label, String value})> _expenseExportSummaryRows() => [
    (label: 'Ouder', value: _expenseExportParentLabel()),
    if ((_childrenLoaded && _children.length > 1) || _filterChildId != null)
      (label: 'Kind', value: _expenseExportChildLabel()),
    (
      label: 'Periode',
      value: _expenseExportPeriodLabel(whenAllTime: 'Alle uitgaven'),
    ),
  ];

  String _paymentExportParentLabelFor(String? filterParentUid) {
    if (filterParentUid == null) return 'Beide';
    for (final parent in _parentItems) {
      if (parent.uid == filterParentUid) return parent.name;
    }
    return 'Beide';
  }

  String _paymentExportTotalLabelFor(String? filterParentUid) {
    if (filterParentUid == null) return 'Totaal betaald';
    return 'Totaal betaald door ${_paymentExportParentLabelFor(filterParentUid)}';
  }

  List<({String label, String value})> _paymentExportSummaryRows() => [
    (
      label: 'Ouder',
      value: _paymentExportParentLabelFor(_paymentFilterParentUid),
    ),
    (
      label: 'Periode',
      value: _expenseExportPeriodLabel(whenAllTime: 'Alle betalingen'),
    ),
  ];

  String _wijzigExportParentLabel() =>
      _paymentExportParentLabelFor(_wijzigFilterEditedByUid);

  List<({String label, String value})> _wijzigExportSummaryRows() => [
    (label: 'Ouder', value: _wijzigExportParentLabel()),
    (
      label: 'Periode',
      value: _expenseExportPeriodLabel(whenAllTime: 'Alle wijzigingen'),
    ),
  ];

  static String _csvEscape(String value) => '"${value.replaceAll('"', '""')}"';

  static String _csvLine(List<String> values) =>
      values.map(_csvEscape).join(';');

  static String _fmtCsvAmount(int cents) {
    final negative = cents < 0;
    final abs = cents.abs();
    final euros = abs ~/ 100;
    final rem = abs % 100;
    return '${negative ? '-' : ''}$euros,${rem.toString().padLeft(2, '0')}';
  }

  Query<Map<String, dynamic>> _buildFrozenExpenseExportQuery({
    required String? filterChildId,
    required String? filterParentUid,
    required _PeriodFilter periodFilter,
    required DateTime? filterStart,
    required DateTime? filterEnd,
  }) {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection(
      'households/${widget.householdId}/expenses',
    );
    if (periodFilter != _PeriodFilter.all &&
        filterStart != null &&
        filterEnd != null) {
      q = q
          .where(
            'createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(filterStart),
          )
          .where('createdAt', isLessThan: Timestamp.fromDate(filterEnd));
    }
    if (filterParentUid != null) {
      q = q.where('createdBy', isEqualTo: filterParentUid);
    }
    if (filterChildId != null) {
      q = q.where('childIds', arrayContains: filterChildId);
    }
    return q.orderBy('createdAt', descending: true);
  }

  Query<Map<String, dynamic>> _buildFrozenPaymentExportQuery({
    required _PeriodFilter periodFilter,
    required DateTime? filterStart,
    required DateTime? filterEnd,
  }) {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection(
      'households/${widget.householdId}/payments',
    );
    if (periodFilter != _PeriodFilter.all &&
        filterStart != null &&
        filterEnd != null) {
      q = q
          .where(
            'createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(filterStart),
          )
          .where('createdAt', isLessThan: Timestamp.fromDate(filterEnd));
    }
    return q.orderBy('createdAt', descending: true);
  }

  String _expenseExportPaidByName(
    String createdBy,
    Map<String, String> parentNamesByUid,
  ) {
    final direct = parentNamesByUid[createdBy]?.trim();
    if (direct != null && direct.isNotEmpty && direct != 'Jij') return direct;
    if (createdBy == widget.uid) {
      final mine = widget.myName?.trim();
      if (mine != null && mine.isNotEmpty) return mine;
      return 'Ouder 1';
    }
    final other = widget.otherName?.trim();
    if (other != null && other.isNotEmpty) return other;
    return 'Ouder 2';
  }

  List<String> _expenseExportChildNames(
    List<String> childIds,
    Map<String, String> childNamesById,
  ) {
    return childIds
        .map((id) => childNamesById[id] ?? 'Verwijderd kind')
        .toList();
  }

  String _expenseExportParentNameFor(String uid, int index) {
    final trimmedUid = uid.trim();
    if (trimmedUid.isNotEmpty) {
      for (final parent in _parentItems) {
        if (parent.uid == trimmedUid) {
          final name = parent.name.trim();
          if (name.isNotEmpty && name != 'Jij') return name;
        }
      }
      if (trimmedUid == widget.uid) {
        final mine = widget.myName?.trim();
        if (mine != null && mine.isNotEmpty) return mine;
      } else {
        final other = widget.otherName?.trim();
        if (other != null && other.isNotEmpty) return other;
      }
    }
    return 'Ouder ${index + 1}';
  }

  static String _fmtCsvPercentBps(int bps) =>
      (bps / 100).toStringAsFixed(2).replaceAll('.', ',');

  static int? _expenseExportShareBpsFor(
    ParentSplitSnapshot snapshot,
    String uid,
  ) {
    if (uid == snapshot.participantUids[0]) return snapshot.share0Bps;
    if (uid == snapshot.participantUids[1]) return snapshot.share1Bps;
    return null;
  }

  String _expenseExportFilename() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'uitgaven-export-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.csv';
  }

  String _expenseExportPdfFilename() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'uitgaven-export-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.pdf';
  }

  String _paymentExportFilename() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'betalingen-export-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.csv';
  }

  String _paymentExportPdfFilename() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'betalingen-export-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.pdf';
  }

  String _wijzigingenExportFilename(String extension) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'wijzigingen-export-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.$extension';
  }

  String _paymentPartyName(String uid) {
    final trimmedUid = uid.trim();
    for (final parent in _parentItems) {
      if (parent.uid == trimmedUid) {
        final name = parent.name.trim();
        if (name.isNotEmpty) return name;
      }
    }
    if (trimmedUid == widget.uid) {
      final mine = widget.myName?.trim();
      if (mine != null && mine.isNotEmpty) return mine;
      return 'Jij';
    }
    final other = widget.otherName?.trim();
    if (other != null && other.isNotEmpty) return other;
    return 'Co-parent';
  }

  bool _matchesPaymentParentFilter(
    Map<String, dynamic> paymentData,
    String? filterParentUid,
  ) {
    if (filterParentUid == null) return true;
    return (paymentData['fromUserId'] as String?)?.trim() == filterParentUid;
  }

  String _wijzigEditedByName(String uid) {
    final trimmedUid = uid.trim();
    for (final parent in _parentItems) {
      if (parent.uid == trimmedUid) {
        final name = parent.name.trim();
        if (name.isNotEmpty) return name;
      }
    }
    if (trimmedUid == widget.uid) {
      final mine = widget.myName?.trim();
      if (mine != null && mine.isNotEmpty) return mine;
      return 'Jij';
    }
    final other = widget.otherName?.trim();
    if (other != null && other.isNotEmpty) return other;
    return 'Co-parent';
  }

  Future<
    List<
      ({
        DateTime? createdAt,
        String expenseType,
        String title,
        String paidByUserId,
        String paidByName,
        int totalAmountCents,
        int childAmountCents,
        int childCount,
        bool hasMultipleChildren,
        String divisionLabel,
        String selectedChildLabel,
        String allChildrenLabel,
        int displayCents,
        String childrenLabel,
        ParentSplitSnapshot? parentSplitSnapshot,
      })
    >
  >
  _loadExpenseExportRows() async {
    final filterChildId = _filterChildId;
    final filterParentUid = _filterParentUid;
    final periodFilter = _periodFilter;
    final filterStart = _filterStart;
    final filterEnd = _filterEnd;
    final childNamesById = <String, String>{
      for (final child in _children) child.id: child.name,
    };
    final parentNamesByUid = <String, String>{
      for (final parent in _parentItems) parent.uid: parent.name,
    };

    final query = _buildFrozenExpenseExportQuery(
      filterChildId: filterChildId,
      filterParentUid: filterParentUid,
      periodFilter: periodFilter,
      filterStart: filterStart,
      filterEnd: filterEnd,
    );
    final snap = await query.get();
    return snap.docs
        .map((doc) {
          final data = doc.data();
          final title = (data['title'] as String?)?.trim() ?? '(zonder naam)';
          final amountCents = (data['amountCents'] as num?)?.toInt() ?? 0;
          final childIds =
              (data['childIds'] as List?)?.whereType<String>().toList() ??
              const <String>[];
          final expenseType =
              ((data['recurringExpenseId'] as String?)?.trim().isNotEmpty ??
                  false)
              ? 'Maandelijks'
              : 'Handmatig';
          final createdBy = (data['createdBy'] as String?)?.trim() ?? '';
          final createdAtRaw = data['createdAt'];
          DateTime? createdAt;
          if (createdAtRaw is Timestamp) {
            createdAt = createdAtRaw.toDate().toLocal();
          } else if (createdAtRaw is DateTime) {
            createdAt = createdAtRaw.toLocal();
          }

          final totalAmountCents = amountCents;
          final childCount = childIds.isNotEmpty ? childIds.length : 1;
          final childAmountCents = filterChildId != null
              ? (amountCents / childCount).round()
              : amountCents;
          final paidByName = _expenseExportPaidByName(
            createdBy,
            parentNamesByUid,
          );
          final childNames = _expenseExportChildNames(childIds, childNamesById);
          final divisionLabel = childIds.isNotEmpty ? '1/$childCount' : '';
          final selectedChildLabel = filterChildId == null
              ? ''
              : (childNamesById[filterChildId] ?? 'Verwijderd kind');
          final allChildrenLabel = childNames.join(' | ');
          final parentSplitSnapshot = ParentSplitSnapshot.tryReadFromExpense(
            data,
          );

          return (
            createdAt: createdAt,
            expenseType: expenseType,
            title: title,
            paidByUserId: createdBy,
            paidByName: paidByName,
            totalAmountCents: totalAmountCents,
            childAmountCents: childAmountCents,
            childCount: childCount,
            hasMultipleChildren: childIds.length > 1,
            divisionLabel: divisionLabel,
            selectedChildLabel: selectedChildLabel,
            allChildrenLabel: allChildrenLabel,
            displayCents: childAmountCents,
            childrenLabel: allChildrenLabel,
            parentSplitSnapshot: parentSplitSnapshot,
          );
        })
        .toList(growable: false);
  }

  Future<void> _exportExpensesCsv() async {
    final messenger = ScaffoldMessenger.of(context);
    final frozenFilterChildId = _filterChildId;
    final hasSelectedChild = frozenFilterChildId != null;

    try {
      final rows = await _loadExpenseExportRows();
      if (rows.isEmpty) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(content: Text('Geen uitgaven voor deze selectie.')),
        );
        return;
      }

      final showChildCount = rows.any((row) => row.hasMultipleChildren);

      final parentOrder = <String>[];
      void addParentUid(String uid) {
        final trimmed = uid.trim();
        if (trimmed.isEmpty || parentOrder.contains(trimmed)) return;
        if (parentOrder.length < kParentSplitParticipantCount) {
          parentOrder.add(trimmed);
        }
      }

      for (final parent in _parentItems) {
        addParentUid(parent.uid);
      }
      for (final row in rows) {
        final snapshot = row.parentSplitSnapshot;
        if (snapshot == null) continue;
        for (final uid in snapshot.participantUids) {
          addParentUid(uid);
        }
      }
      while (parentOrder.length < kParentSplitParticipantCount) {
        parentOrder.add('');
      }

      final parentColumns = [
        for (var i = 0; i < kParentSplitParticipantCount; i++)
          (
            uid: parentOrder[i],
            name: _expenseExportParentNameFor(parentOrder[i], i),
          ),
      ];
      final selectedChildLabel = rows
          .map((row) => row.selectedChildLabel.trim())
          .firstWhere((label) => label.isNotEmpty, orElse: () => 'kind');
      final selectedChildAmountHeader = 'Bedrag voor $selectedChildLabel (EUR)';

      String divisionLabelFor(
        ParentSplitSnapshot? snapshot,
        List<({String uid, String name})> parentColumns,
      ) {
        if (snapshot == null) return 'Niet vastgelegd';
        final bpsValues = [
          for (final parent in parentColumns)
            _expenseExportShareBpsFor(snapshot, parent.uid),
        ];
        if (bpsValues.any((bps) => bps == null)) {
          return 'Niet vastgelegd';
        }
        return '${_fmtCsvPercentBps(bpsValues[0]!)}% / '
            '${_fmtCsvPercentBps(bpsValues[1]!)}%';
      }

      List<String> parentSplitCellsFor(
        ParentSplitSnapshot? snapshot,
        int baseAmountCents,
        List<({String uid, String name})> parentColumns,
      ) {
        if (snapshot == null) return const ['', '', '', ''];
        final cells = <String>[];
        for (final parent in parentColumns) {
          final bps = _expenseExportShareBpsFor(snapshot, parent.uid);
          if (bps == null) {
            cells
              ..add('')
              ..add('');
            continue;
          }
          cells
            ..add('${_fmtCsvPercentBps(bps)}%')
            ..add(
              _fmtCsvAmount(
                snapshot.fairShareCentsFor(parent.uid, baseAmountCents),
              ),
            );
        }
        return cells;
      }

      final header = <String>[
        'Datum',
        'Uitgavetype',
        'Titel',
        'Betaald door',
        'Volledige uitgave (EUR)',
        'Kinderen',
        if (showChildCount)
          hasSelectedChild ? 'Aantal kinderen in uitgave' : 'Aantal kinderen',
        if (hasSelectedChild) selectedChildAmountHeader,
        'Uitgavenverdeling',
        '${parentColumns[0].name} %',
        '${parentColumns[0].name} aandeel (EUR)',
        '${parentColumns[1].name} %',
        '${parentColumns[1].name} aandeel (EUR)',
      ];
      final csv = StringBuffer()..writeln(_csvLine(header));

      for (final row in rows) {
        final baseAmountCents = hasSelectedChild
            ? row.childAmountCents
            : row.totalAmountCents;
        final values = <String>[
          _fmtExpenseCsvDate(row.createdAt),
          row.expenseType,
          row.title,
          row.paidByName,
          _fmtCsvAmount(row.totalAmountCents),
          hasSelectedChild ? row.selectedChildLabel : row.allChildrenLabel,
          if (showChildCount) row.childCount.toString(),
          if (hasSelectedChild) _fmtCsvAmount(row.childAmountCents),
          divisionLabelFor(row.parentSplitSnapshot, parentColumns),
          ...parentSplitCellsFor(
            row.parentSplitSnapshot,
            baseAmountCents,
            parentColumns,
          ),
        ];
        csv.writeln(_csvLine(values));
      }

      final tempDir = await Directory.systemTemp.createTemp('kidu-export-');
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}${_expenseExportFilename()}',
      );
      await file.writeAsString(csv.toString(), flush: true);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Uitgaven export',
        text: 'Uitgaven uit Logboek',
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            mapUserFacingError(
              e,
              fallback: 'Exporteren lukt niet. Probeer opnieuw.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _exportExpensesPdf() async {
    final messenger = ScaffoldMessenger.of(context);
    final frozenFilterChildId = _filterChildId;
    final frozenFilterParentUid = _filterParentUid;
    final frozenPeriodFilter = _periodFilter;
    final frozenFilterStart = _filterStart;
    final frozenFilterEnd = _filterEnd;

    try {
      final rows = await _loadExpenseExportRows();
      if (rows.isEmpty) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(content: Text('Geen uitgaven voor deze selectie.')),
        );
        return;
      }

      String pdfExportedAtLabel(DateTime dt) {
        final hh = dt.hour.toString().padLeft(2, '0');
        final mm = dt.minute.toString().padLeft(2, '0');
        return '${_fmtDateWithYear(dt)} - $hh:$mm';
      }

      int pdfChildCount(String allChildrenLabel) {
        final trimmed = allChildrenLabel.trim();
        if (trimmed.isEmpty) return 0;
        return trimmed.split(' | ').length;
      }

      String pdfParentLabel() {
        if (frozenFilterParentUid == null) return 'Beide';
        for (final parent in _parentItems) {
          if (parent.uid == frozenFilterParentUid) return parent.name;
        }
        return 'Beide';
      }

      String pdfPeriodValue(DateTime start, DateTime end) {
        final startLabel = _fmtDateWithYear(start);
        final endLabel = _fmtDateWithYear(end);
        return startLabel == endLabel
            ? startLabel
            : '$startLabel t/m $endLabel';
      }

      ({String label, String value}) pdfPeriodSummaryRow() {
        if (frozenPeriodFilter != _PeriodFilter.all &&
            frozenFilterStart != null &&
            frozenFilterEnd != null) {
          final inclusiveEnd = frozenFilterEnd.subtract(
            const Duration(days: 1),
          );
          return (
            label: 'Periode',
            value: pdfPeriodValue(frozenFilterStart, inclusiveEnd),
          );
        }

        final exportedDates = rows
            .map((row) => row.createdAt)
            .whereType<DateTime>()
            .toList(growable: false);
        if (exportedDates.isEmpty) {
          return (label: 'Volledige periode', value: '-');
        }

        exportedDates.sort();
        return (
          label: 'Volledige periode',
          value: pdfPeriodValue(exportedDates.first, exportedDates.last),
        );
      }

      pw.MemoryImage? logoImage;
      try {
        final logoBytes = await rootBundle.load('assets/images/kidu_icon.png');
        logoImage = pw.MemoryImage(logoBytes.buffer.asUint8List());
      } catch (_) {
        logoImage = null;
      }

      final doc = pw.Document();
      final exportedAt = pdfExportedAtLabel(DateTime.now());
      final hasSelectedChild = frozenFilterChildId != null;
      final selectedChildLabel = rows
          .map((row) => row.selectedChildLabel.trim())
          .firstWhere((label) => label.isNotEmpty, orElse: () => '');
      final selectedChildAmountHeader = selectedChildLabel.isNotEmpty
          ? 'Bedrag voor $selectedChildLabel'
          : 'Bedrag voor kind';
      final fullExpensesTotalCents = rows.fold<int>(
        0,
        (totalCents, row) => totalCents + row.totalAmountCents,
      );
      final selectedChildTotalCents = rows.fold<int>(
        0,
        (totalCents, row) => totalCents + row.childAmountCents,
      );
      final expenseTotalRows =
          <({String label, int amountCents, bool emphasize})>[
            (
              label: 'Totaal volledige uitgaven',
              amountCents: fullExpensesTotalCents,
              emphasize: true,
            ),
            if (hasSelectedChild)
              (
                label: selectedChildLabel.isNotEmpty
                    ? 'Totaal voor $selectedChildLabel'
                    : 'Totaal voor kind',
                amountCents: selectedChildTotalCents,
                emphasize: false,
              ),
            if (frozenFilterParentUid == null)
              for (final parent in _parentItems)
                (
                  label: 'Totaal uitgaven door ${parent.name}',
                  amountCents: rows
                      .where((row) => row.paidByUserId == parent.uid)
                      .fold<int>(
                        0,
                        (totalCents, row) => totalCents + row.totalAmountCents,
                      ),
                  emphasize: false,
                ),
          ];
      final summaryRows = [
        (label: 'Tab', value: 'Uitgaven'),
        (label: 'Ouder', value: pdfParentLabel()),
        if (hasSelectedChild)
          (
            label: 'Kind',
            value: selectedChildLabel.isNotEmpty ? selectedChildLabel : 'Kind',
          ),
        pdfPeriodSummaryRow(),
      ];
      final pdfHeaders = hasSelectedChild
          ? [
              'Datum',
              'Titel',
              'Betaald door',
              'Volledige uitgave',
              'Aantal kinderen',
              selectedChildAmountHeader,
            ]
          : ['Datum', 'Titel', 'Betaald door', 'Volledige uitgave', 'Kinderen'];
      final pdfData = rows
          .map(
            (row) => hasSelectedChild
                ? [
                    _fmtDateWithYear(row.createdAt),
                    row.title,
                    row.paidByName,
                    _fmtCsvAmount(row.totalAmountCents),
                    pdfChildCount(row.allChildrenLabel).toString(),
                    _fmtCsvAmount(row.childAmountCents),
                  ]
                : [
                    _fmtDateWithYear(row.createdAt),
                    row.title,
                    row.paidByName,
                    _fmtCsvAmount(row.totalAmountCents),
                    row.allChildrenLabel,
                  ],
          )
          .toList(growable: false);

      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (context) => [
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                if (logoImage != null) ...[
                  pw.Container(
                    width: 24,
                    height: 24,
                    margin: const pw.EdgeInsets.only(right: 10),
                    child: pw.Image(logoImage),
                  ),
                ],
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'KiDu',
                      style: pw.TextStyle(
                        fontSize: 10,
                        color: PdfColors.grey700,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Uitgaven',
                      style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 10),
            pw.Text(
              'Exportdatum: $exportedAt',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 14),
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      for (final row in summaryRows)
                        pw.Container(
                          width: 235,
                          padding: const pw.EdgeInsets.all(8),
                          decoration: pw.BoxDecoration(
                            color: PdfColors.white,
                            border: pw.Border.all(color: PdfColors.grey300),
                            borderRadius: pw.BorderRadius.circular(4),
                          ),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text(
                                row.label,
                                style: pw.TextStyle(
                                  fontSize: 9,
                                  color: PdfColors.grey700,
                                  fontWeight: pw.FontWeight.bold,
                                ),
                              ),
                              pw.SizedBox(height: 3),
                              pw.Text(
                                row.value,
                                style: const pw.TextStyle(fontSize: 10),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 16),
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(
                fontSize: 9.5,
                fontWeight: pw.FontWeight.bold,
              ),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.grey200,
              ),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellAlignment: pw.Alignment.centerLeft,
              cellAlignments: hasSelectedChild
                  ? {
                      3: pw.Alignment.centerRight,
                      4: pw.Alignment.centerRight,
                      5: pw.Alignment.centerRight,
                    }
                  : {3: pw.Alignment.centerRight},
              columnWidths: hasSelectedChild
                  ? {
                      0: const pw.FixedColumnWidth(64),
                      1: const pw.FlexColumnWidth(2.0),
                      2: const pw.FlexColumnWidth(1.5),
                      3: const pw.FixedColumnWidth(76),
                      4: const pw.FixedColumnWidth(56),
                      5: const pw.FixedColumnWidth(86),
                    }
                  : {
                      0: const pw.FixedColumnWidth(64),
                      1: const pw.FlexColumnWidth(2.1),
                      2: const pw.FlexColumnWidth(1.5),
                      3: const pw.FixedColumnWidth(86),
                      4: const pw.FlexColumnWidth(1.7),
                    },
              headers: pdfHeaders,
              data: pdfData,
            ),
            pw.SizedBox(height: 12),
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Container(
                width: 280,
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  color: PdfColors.grey100,
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: pw.BorderRadius.circular(4),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < expenseTotalRows.length; i++) ...[
                      if (i > 0) pw.SizedBox(height: 8),
                      pw.Row(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Expanded(
                            child: pw.Text(
                              expenseTotalRows[i].label,
                              style: pw.TextStyle(
                                fontSize: 10,
                                fontWeight: expenseTotalRows[i].emphasize
                                    ? pw.FontWeight.bold
                                    : pw.FontWeight.normal,
                              ),
                            ),
                          ),
                          pw.SizedBox(width: 12),
                          pw.Text(
                            _fmtCsvAmount(expenseTotalRows[i].amountCents),
                            style: pw.TextStyle(
                              fontSize: 10,
                              fontWeight: expenseTotalRows[i].emphasize
                                  ? pw.FontWeight.bold
                                  : pw.FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );

      final tempDir = await Directory.systemTemp.createTemp('kidu-export-');
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}${_expenseExportPdfFilename()}',
      );
      await file.writeAsBytes(await doc.save(), flush: true);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Uitgaven export',
        text: 'Uitgaven uit Logboek',
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            mapUserFacingError(
              e,
              fallback: 'Exporteren lukt niet. Probeer opnieuw.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _exportPaymentsCsv() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final rows = await _loadPaymentExportRows();
      if (rows.isEmpty) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(content: Text('Geen betalingen voor deze selectie.')),
        );
        return;
      }

      final csv = StringBuffer()
        ..writeln(
          _csvLine(const [
            'Datum',
            'Bedrag',
            'Betaald door',
            'Ontvangen door',
            'Status',
          ]),
        );

      for (final row in rows) {
        csv.writeln(
          _csvLine([
            _fmtDateWithYear(row.createdAt),
            _fmtCsvAmount(row.amountCents),
            row.fromName,
            row.toName,
            row.statusLabel,
          ]),
        );
      }

      final tempDir = await Directory.systemTemp.createTemp('kidu-export-');
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}${_paymentExportFilename()}',
      );
      await file.writeAsString(csv.toString(), flush: true);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Betalingen export',
        text: 'Betalingen uit Logboek',
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            mapUserFacingError(
              e,
              fallback: 'Exporteren lukt niet. Probeer opnieuw.',
            ),
          ),
        ),
      );
    }
  }

  Future<
    List<
      ({
        DateTime? createdAt,
        int amountCents,
        String fromUserId,
        String fromName,
        String toName,
        String statusLabel,
      })
    >
  >
  _loadPaymentExportRows() async {
    final paymentFilterParentUid = _paymentFilterParentUid;
    final periodFilter = _periodFilter;
    final filterStart = _filterStart;
    final filterEnd = _filterEnd;

    final query = _buildFrozenPaymentExportQuery(
      periodFilter: periodFilter,
      filterStart: filterStart,
      filterEnd: filterEnd,
    );
    final snap = await query.get();
    final allDocs = snap.docs;
    final docs = allDocs
        .where(
          (d) => _matchesPaymentParentFilter(d.data(), paymentFilterParentUid),
        )
        .toList(growable: false);

    return docs
        .map((doc) {
          final data = doc.data();
          final amountCents = (data['amountCents'] as num?)?.toInt() ?? 0;
          final fromUserId = (data['fromUserId'] as String?)?.trim() ?? '';
          final toUserId = (data['toUserId'] as String?)?.trim() ?? '';
          final status = (data['status'] as String?)?.trim() ?? '';
          final createdAtRaw = data['createdAt'];
          DateTime? createdAt;
          if (createdAtRaw is Timestamp) {
            createdAt = createdAtRaw.toDate().toLocal();
          } else if (createdAtRaw is DateTime) {
            createdAt = createdAtRaw.toLocal();
          }
          return (
            createdAt: createdAt,
            amountCents: amountCents,
            fromUserId: fromUserId,
            fromName: _paymentPartyName(fromUserId),
            toName: _paymentPartyName(toUserId),
            statusLabel: status == 'confirmed' ? 'Bevestigd' : 'In afwachting',
          );
        })
        .toList(growable: false);
  }

  Future<void> _exportPaymentsPdf() async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      final paymentFilterParentUid = _paymentFilterParentUid;
      final periodFilter = _periodFilter;
      final filterStart = _filterStart;
      final filterEnd = _filterEnd;
      final rows = await _loadPaymentExportRows();
      if (rows.isEmpty) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(content: Text('Geen betalingen voor deze selectie.')),
        );
        return;
      }

      String pdfExportedAtLabel(DateTime dt) {
        final hh = dt.hour.toString().padLeft(2, '0');
        final mm = dt.minute.toString().padLeft(2, '0');
        return '${_fmtDateWithYear(dt)} - $hh:$mm';
      }

      String pdfPeriodValue(DateTime start, DateTime end) {
        final startLabel = _fmtDateWithYear(start);
        final endLabel = _fmtDateWithYear(end);
        return startLabel == endLabel
            ? startLabel
            : '$startLabel t/m $endLabel';
      }

      ({String label, String value}) pdfPeriodSummaryRow() {
        if (periodFilter == _PeriodFilter.custom &&
            filterStart != null &&
            filterEnd != null) {
          final inclusiveEnd = filterEnd.subtract(const Duration(days: 1));
          return (
            label: 'Periode',
            value: pdfPeriodValue(filterStart, inclusiveEnd),
          );
        }

        final exportedDates = rows
            .map((row) => row.createdAt)
            .whereType<DateTime>()
            .toList(growable: false);
        if (exportedDates.isEmpty) {
          return (label: 'Volledige periode', value: '-');
        }

        exportedDates.sort();
        return (
          label: 'Volledige periode',
          value: pdfPeriodValue(exportedDates.first, exportedDates.last),
        );
      }

      pw.MemoryImage? logoImage;
      try {
        final logoBytes = await rootBundle.load('assets/images/kidu_icon.png');
        logoImage = pw.MemoryImage(logoBytes.buffer.asUint8List());
      } catch (_) {
        logoImage = null;
      }

      final doc = pw.Document();
      final exportedAt = pdfExportedAtLabel(DateTime.now());
      final totalPaidCents = rows.fold<int>(
        0,
        (total, row) => total + row.amountCents,
      );
      final paymentTotalRows = paymentFilterParentUid == null
          ? <({String label, int amountCents, bool emphasize})>[
              (
                label: 'Totaal betaald',
                amountCents: totalPaidCents,
                emphasize: true,
              ),
              for (final parent in _parentItems)
                (
                  label: 'Totaal betaald door ${parent.name}',
                  amountCents: rows
                      .where((row) => row.fromUserId == parent.uid)
                      .fold<int>(0, (total, row) => total + row.amountCents),
                  emphasize: false,
                ),
            ]
          : <({String label, int amountCents, bool emphasize})>[
              (
                label: _paymentExportTotalLabelFor(paymentFilterParentUid),
                amountCents: totalPaidCents,
                emphasize: true,
              ),
            ];
      final summaryRows = [
        (label: 'Tab', value: 'Betalingen'),
        (
          label: 'Ouder',
          value: _paymentExportParentLabelFor(paymentFilterParentUid),
        ),
        pdfPeriodSummaryRow(),
      ];

      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (context) => [
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                if (logoImage != null) ...[
                  pw.Container(
                    width: 24,
                    height: 24,
                    margin: const pw.EdgeInsets.only(right: 10),
                    child: pw.Image(logoImage),
                  ),
                ],
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'KiDu',
                      style: pw.TextStyle(
                        fontSize: 10,
                        color: PdfColors.grey700,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Betalingen',
                      style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 10),
            pw.Text(
              'Exportdatum: $exportedAt',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 14),
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      for (final row in summaryRows)
                        pw.Container(
                          width: 235,
                          padding: const pw.EdgeInsets.all(8),
                          decoration: pw.BoxDecoration(
                            color: PdfColors.white,
                            border: pw.Border.all(color: PdfColors.grey300),
                            borderRadius: pw.BorderRadius.circular(4),
                          ),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text(
                                row.label,
                                style: pw.TextStyle(
                                  fontSize: 9,
                                  color: PdfColors.grey700,
                                  fontWeight: pw.FontWeight.bold,
                                ),
                              ),
                              pw.SizedBox(height: 3),
                              pw.Text(
                                row.value,
                                style: const pw.TextStyle(fontSize: 10),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 16),
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(
                fontSize: 9.5,
                fontWeight: pw.FontWeight.bold,
              ),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.grey200,
              ),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellAlignment: pw.Alignment.centerLeft,
              cellAlignments: {1: pw.Alignment.centerRight},
              columnWidths: {
                0: const pw.FixedColumnWidth(64),
                1: const pw.FixedColumnWidth(64),
                2: const pw.FixedColumnWidth(92),
                3: const pw.FixedColumnWidth(92),
                4: const pw.FlexColumnWidth(1.2),
              },
              headers: const [
                'Datum',
                'Bedrag',
                'Betaald door',
                'Ontvangen door',
                'Status',
              ],
              data: rows
                  .map(
                    (row) => [
                      _fmtDateWithYear(row.createdAt),
                      _fmtCsvAmount(row.amountCents),
                      row.fromName,
                      row.toName,
                      row.statusLabel,
                    ],
                  )
                  .toList(growable: false),
            ),
            pw.SizedBox(height: 12),
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Container(
                width: 240,
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  color: PdfColors.grey100,
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: pw.BorderRadius.circular(4),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < paymentTotalRows.length; i++) ...[
                      pw.Row(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Expanded(
                            child: pw.Text(
                              paymentTotalRows[i].label,
                              style: pw.TextStyle(
                                fontSize: paymentTotalRows[i].emphasize
                                    ? 10
                                    : 9,
                                fontWeight: paymentTotalRows[i].emphasize
                                    ? pw.FontWeight.bold
                                    : pw.FontWeight.normal,
                              ),
                            ),
                          ),
                          pw.SizedBox(width: 12),
                          pw.Text(
                            _fmtCsvAmount(paymentTotalRows[i].amountCents),
                            style: pw.TextStyle(
                              fontSize: paymentTotalRows[i].emphasize ? 10 : 9,
                              fontWeight: paymentTotalRows[i].emphasize
                                  ? pw.FontWeight.bold
                                  : pw.FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                      if (i != paymentTotalRows.length - 1)
                        pw.SizedBox(height: 6),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );

      final tempDir = await Directory.systemTemp.createTemp('kidu-export-');
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}${_paymentExportPdfFilename()}',
      );
      await file.writeAsBytes(await doc.save(), flush: true);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Betalingen export',
        text: 'Betalingen uit Logboek',
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            mapUserFacingError(
              e,
              fallback: 'Exporteren lukt niet. Probeer opnieuw.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _exportWijzigingenCsv() async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      final rows = await _loadWijzigingenExportRows();
      if (rows.isEmpty) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(content: Text('Geen wijzigingen voor deze selectie.')),
        );
        return;
      }

      final csv = StringBuffer()
        ..writeln(
          _csvLine(const [
            'Datum wijziging',
            'Titel',
            'Van',
            'Naar',
            'Reden',
            'Gewijzigd door',
          ]),
        );

      for (final row in rows) {
        csv.writeln(
          _csvLine([
            _ExpenseDetailPage._formatDateTime(row.editedAt),
            row.title,
            _fmtCsvAmount(row.fromAmountCents),
            _fmtCsvAmount(row.toAmountCents),
            row.reason,
            _wijzigEditedByName(row.editedBy),
          ]),
        );
      }

      final tempDir = await Directory.systemTemp.createTemp('kidu-export-');
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}${_wijzigingenExportFilename('csv')}',
      );
      await file.writeAsString(csv.toString(), flush: true);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Wijzigingen export',
        text: 'Wijzigingen uit Logboek',
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            mapUserFacingError(
              e,
              fallback: 'Exporteren lukt niet. Probeer opnieuw.',
            ),
          ),
        ),
      );
    }
  }

  Future<List<_WijzigRow>> _loadWijzigingenExportRows() async {
    final periodFilter = _periodFilter;
    final filterStart = _filterStart;
    final filterEnd = _filterEnd;
    final editedByUid = _wijzigFilterEditedByUid;

    final snap = await FirebaseFirestore.instance
        .collection('households/${widget.householdId}/expenses')
        .get();
    return _loadWijzigRows(
      snap.docs,
      periodFilter: periodFilter,
      filterStart: filterStart,
      filterEnd: filterEnd,
      editedByUid: editedByUid,
    );
  }

  Future<void> _exportWijzigingenPdf() async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      final rows = await _loadWijzigingenExportRows();
      if (rows.isEmpty) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(content: Text('Geen wijzigingen voor deze selectie.')),
        );
        return;
      }

      String pdfExportedAtLabel(DateTime dt) {
        final hh = dt.hour.toString().padLeft(2, '0');
        final mm = dt.minute.toString().padLeft(2, '0');
        return '${_fmtDateWithYear(dt)} - $hh:$mm';
      }

      String pdfPeriodValue(DateTime start, DateTime end) {
        final startLabel = _fmtDateWithYear(start);
        final endLabel = _fmtDateWithYear(end);
        return startLabel == endLabel
            ? startLabel
            : '$startLabel t/m $endLabel';
      }

      ({String label, String value}) pdfPeriodSummaryRow() {
        if (_periodFilter == _PeriodFilter.custom &&
            _filterStart != null &&
            _filterEnd != null) {
          final inclusiveEnd = _filterEnd!.subtract(const Duration(days: 1));
          return (
            label: 'Periode',
            value: pdfPeriodValue(_filterStart!, inclusiveEnd),
          );
        }

        final exportedDates = rows
            .map((row) => row.editedAt)
            .toList(growable: false);
        if (exportedDates.isEmpty) {
          return (label: 'Volledige periode', value: '-');
        }

        exportedDates.sort();
        return (
          label: 'Volledige periode',
          value: pdfPeriodValue(exportedDates.first, exportedDates.last),
        );
      }

      pw.MemoryImage? logoImage;
      try {
        final logoBytes = await rootBundle.load('assets/images/kidu_icon.png');
        logoImage = pw.MemoryImage(logoBytes.buffer.asUint8List());
      } catch (_) {
        logoImage = null;
      }

      final doc = pw.Document();
      final exportedAt = pdfExportedAtLabel(DateTime.now());
      final summaryRows = [
        (label: 'Tab', value: 'Wijzigingen'),
        (label: 'Ouder', value: _wijzigExportParentLabel()),
        pdfPeriodSummaryRow(),
      ];

      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (context) => [
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                if (logoImage != null) ...[
                  pw.Container(
                    width: 24,
                    height: 24,
                    margin: const pw.EdgeInsets.only(right: 10),
                    child: pw.Image(logoImage),
                  ),
                ],
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'KiDu',
                      style: pw.TextStyle(
                        fontSize: 10,
                        color: PdfColors.grey700,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Wijzigingen',
                      style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 10),
            pw.Text(
              'Exportdatum: $exportedAt',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 14),
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      for (final row in summaryRows)
                        pw.Container(
                          width: 235,
                          padding: const pw.EdgeInsets.all(8),
                          decoration: pw.BoxDecoration(
                            color: PdfColors.white,
                            border: pw.Border.all(color: PdfColors.grey300),
                            borderRadius: pw.BorderRadius.circular(4),
                          ),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text(
                                row.label,
                                style: pw.TextStyle(
                                  fontSize: 9,
                                  color: PdfColors.grey700,
                                  fontWeight: pw.FontWeight.bold,
                                ),
                              ),
                              pw.SizedBox(height: 3),
                              pw.Text(
                                row.value,
                                style: const pw.TextStyle(fontSize: 10),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 16),
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(
                fontSize: 9.5,
                fontWeight: pw.FontWeight.bold,
              ),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.grey200,
              ),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellAlignment: pw.Alignment.centerLeft,
              cellAlignments: {
                2: pw.Alignment.centerRight,
                3: pw.Alignment.centerRight,
              },
              columnWidths: {
                0: const pw.FixedColumnWidth(74),
                1: const pw.FlexColumnWidth(1.8),
                2: const pw.FixedColumnWidth(58),
                3: const pw.FixedColumnWidth(58),
                4: const pw.FlexColumnWidth(1.7),
                5: const pw.FixedColumnWidth(78),
              },
              headers: const [
                'Datum wijziging',
                'Titel',
                'Van',
                'Naar',
                'Reden',
                'Gewijzigd door',
              ],
              data: rows
                  .map(
                    (row) => [
                      _ExpenseDetailPage._formatDateTime(
                        row.editedAt,
                      ).replaceAll(' • ', ' - '),
                      row.title,
                      _fmtCsvAmount(row.fromAmountCents),
                      _fmtCsvAmount(row.toAmountCents),
                      row.reason,
                      _wijzigEditedByName(row.editedBy),
                    ],
                  )
                  .toList(growable: false),
            ),
          ],
        ),
      );

      final tempDir = await Directory.systemTemp.createTemp('kidu-export-');
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}${_wijzigingenExportFilename('pdf')}',
      );
      await file.writeAsBytes(await doc.save(), flush: true);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Wijzigingen export',
        text: 'Wijzigingen uit Logboek',
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            mapUserFacingError(
              e,
              fallback: 'Exporteren lukt niet. Probeer opnieuw.',
            ),
          ),
        ),
      );
    }
  }

  Widget _buildExportSummaryRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: onSurface(context, a60)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: onSurface(context, a84),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showExpenseExportConfirmSheet() {
    final summaryRows = _expenseExportSummaryRows();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 8,
            bottom: 24 + MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Exporteer uitgaven',
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 20),
              for (final row in summaryRows)
                _buildExportSummaryRow(row.label, row.value),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        Navigator.of(sheetContext).pop();
                        await _exportExpensesPdf();
                      },
                      child: const Text('Export PDF'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        Navigator.of(sheetContext).pop();
                        await _exportExpensesCsv();
                      },
                      child: const Text('Export CSV'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPaymentExportConfirmSheet() {
    final summaryRows = _paymentExportSummaryRows();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 8,
            bottom: 24 + MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Exporteer betalingen',
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 20),
              for (final row in summaryRows)
                _buildExportSummaryRow(row.label, row.value),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        Navigator.of(sheetContext).pop();
                        await _exportPaymentsPdf();
                      },
                      child: const Text('Export PDF'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        Navigator.of(sheetContext).pop();
                        await _exportPaymentsCsv();
                      },
                      child: const Text('Export CSV'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showWijzigingenExportConfirmSheet() {
    final summaryRows = _wijzigExportSummaryRows();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 8,
            bottom: 24 + MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Exporteer wijzigingen',
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 20),
              for (final row in summaryRows)
                _buildExportSummaryRow(row.label, row.value),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        Navigator.of(sheetContext).pop();
                        await _exportWijzigingenPdf();
                      },
                      child: const Text('Export PDF'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        Navigator.of(sheetContext).pop();
                        await _exportWijzigingenCsv();
                      },
                      child: const Text('Export CSV'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<List<_WijzigLogbookRow>> _loadWijzigLogbookRows(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> expenseDocs, {
    _PeriodFilter? periodFilter,
    DateTime? filterStart,
    DateTime? filterEnd,
    String? editedByUid,
  }) async {
    final effectivePeriodFilter = periodFilter ?? _periodFilter;
    final effectiveFilterStart = filterStart ?? _filterStart;
    final effectiveFilterEnd = filterEnd ?? _filterEnd;
    final effectiveEditedByUid = editedByUid ?? _wijzigFilterEditedByUid;
    final rows = <_WijzigLogbookRow>[];

    await Future.wait(
      expenseDocs.map((d) async {
        final e = d.data();
        final title = (e['title'] as String?)?.trim() ?? '(zonder naam)';
        final displayAmountCents = (e['amountCents'] as num?)?.toInt() ?? 0;
        final childIds = _readAuditStringList(e['childIds']);
        final createdBy = (e['createdBy'] as String?)?.trim() ?? '';
        final createdAtRaw = e['createdAt'];
        DateTime? createdAt;
        if (createdAtRaw is Timestamp) {
          createdAt = createdAtRaw.toDate().toLocal();
        } else if (createdAtRaw is DateTime) {
          createdAt = createdAtRaw.toLocal();
        }
        final parentSplitSnapshot = ParentSplitSnapshot.tryReadFromExpense(e);
        final isMaterializedMonthly = _expenseDocIsMaterializedMonthly(e);

        final amountSnap = await FirebaseFirestore.instance
            .collection(
              'households/${widget.householdId}/expenses/${d.id}/amountEdits',
            )
            .get();
        final changeSnap = await FirebaseFirestore.instance
            .collection(
              'households/${widget.householdId}/expenses/${d.id}/expenseChanges',
            )
            .get();

        final registrations = _mergeAuditRegistrations(
          amountEditDocs: amountSnap.docs,
          expenseChangeDocs: changeSnap.docs,
        );

        for (final reg in registrations) {
          if (effectivePeriodFilter != _PeriodFilter.all &&
              effectiveFilterStart != null &&
              effectiveFilterEnd != null) {
            final ed = reg.editedAt;
            if (ed.isBefore(effectiveFilterStart) ||
                !ed.isBefore(effectiveFilterEnd)) {
              continue;
            }
          }
          rows.add(
            _WijzigLogbookRow(
              registrationKey: reg.registrationKey,
              expenseId: d.id,
              title: title,
              editedBy: reg.editedBy,
              editedAt: reg.editedAt,
              displayAmountCents: displayAmountCents,
              hasAmountChange: reg.hasAmountChange,
              hasChildrenChange: reg.hasChildrenChange,
              hasSplitChange: reg.hasSplitChange,
              childIds: childIds,
              createdBy: createdBy,
              createdAt: createdAt,
              parentSplitSnapshot: parentSplitSnapshot,
              isMaterializedMonthly: isMaterializedMonthly,
              changeBatchId: reg.changeBatchId,
              fromAmountCents: reg.fromAmountCents,
              toAmountCents: reg.toAmountCents,
              reason: reg.reason.isEmpty ? null : reg.reason,
            ),
          );
        }
      }),
    );

    rows.sort((a, b) => b.editedAt.compareTo(a.editedAt));
    if (effectiveEditedByUid != null) {
      rows.removeWhere((r) => r.editedBy != effectiveEditedByUid);
    }
    return rows;
  }

  /// Export-only: amountEdits per expense (legacy amount-only).
  Future<List<_WijzigRow>> _loadWijzigRows(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> expenseDocs, {
    _PeriodFilter? periodFilter,
    DateTime? filterStart,
    DateTime? filterEnd,
    String? editedByUid,
  }) async {
    final effectivePeriodFilter = periodFilter ?? _periodFilter;
    final effectiveFilterStart = filterStart ?? _filterStart;
    final effectiveFilterEnd = filterEnd ?? _filterEnd;
    final effectiveEditedByUid = editedByUid ?? _wijzigFilterEditedByUid;
    final rows = <_WijzigRow>[];
    await Future.wait(
      expenseDocs.map((d) async {
        final e = d.data();
        final title = (e['title'] as String?)?.trim() ?? '(zonder naam)';
        final amountCents = (e['amountCents'] as num?)?.toInt() ?? 0;
        final childIds =
            (e['childIds'] as List?)?.whereType<String>().toList() ??
            const <String>[];
        final createdBy = (e['createdBy'] as String?)?.trim() ?? '';
        final createdAtRaw = e['createdAt'];
        DateTime? createdAt;
        if (createdAtRaw is Timestamp) {
          createdAt = createdAtRaw.toDate().toLocal();
        } else if (createdAtRaw is DateTime) {
          createdAt = createdAtRaw.toLocal();
        }
        final sub = await FirebaseFirestore.instance
            .collection(
              'households/${widget.householdId}/expenses/${d.id}/amountEdits',
            )
            .get();
        for (final ed in sub.docs) {
          final h = ed.data();
          final fromC = (h['fromAmountCents'] as num?)?.toInt() ?? 0;
          final toC = (h['toAmountCents'] as num?)?.toInt() ?? 0;
          final reason = (h['reason'] as String?)?.trim() ?? '';
          final editedBy = (h['editedBy'] as String?)?.trim() ?? '';
          final editedAtRaw = h['editedAt'];
          DateTime? editedAtDt;
          if (editedAtRaw is Timestamp) {
            editedAtDt = editedAtRaw.toDate().toLocal();
          } else if (editedAtRaw is DateTime) {
            editedAtDt = editedAtRaw.toLocal();
          }
          if (editedAtDt == null) continue;
          if (effectivePeriodFilter != _PeriodFilter.all &&
              effectiveFilterStart != null &&
              effectiveFilterEnd != null) {
            final ed = editedAtDt;
            if (ed.isBefore(effectiveFilterStart) ||
                !ed.isBefore(effectiveFilterEnd)) {
              continue;
            }
          }
          rows.add(
            _WijzigRow(
              expenseId: d.id,
              title: title,
              fromAmountCents: fromC,
              toAmountCents: toC,
              reason: reason,
              editedBy: editedBy,
              editedAt: editedAtDt,
              expenseAmountCents: amountCents,
              childIds: childIds,
              createdBy: createdBy,
              createdAt: createdAt,
              parentSplitSnapshot: ParentSplitSnapshot.tryReadFromExpense(e),
              isMaterializedMonthly: _expenseDocIsMaterializedMonthly(e),
            ),
          );
        }
      }),
    );
    rows.sort((a, b) => b.editedAt.compareTo(a.editedAt));
    if (effectiveEditedByUid != null) {
      rows.removeWhere((r) => r.editedBy != effectiveEditedByUid);
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final logboekContent = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_isOffline)
                Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Text(
                    'Offline — je ziet de laatst geladen gegevens.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: onSurface(context, a62),
                    ),
                  ),
                ),
              Expanded(
                child: TabBarView(
                  controller: _modeTabController,
                  children: [
                    _LogboekTabKeepAlive(
                      builder: (context) => Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: SizedBox(
                            width: double.infinity,
                            height: _logboekListCardHeight,
                            child: KiduCard(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              child: _buildExpenseList(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                    _LogboekTabKeepAlive(
                      builder: (context) => Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: SizedBox(
                            width: double.infinity,
                            height: _logboekListCardHeight,
                            child: KiduCard(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              child: _buildWijzigingenList(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                    _LogboekTabKeepAlive(
                      builder: (context) => Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: SizedBox(
                            width: double.infinity,
                            height: _logboekListCardHeight,
                            child: KiduCard(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              child: _buildPaymentList(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
    final appBar = AppBar(
      centerTitle: true,
      leading: BackButton(onPressed: () => Navigator.of(context).pop()),
      title: Text(
        'Logboek',
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
      actions: [
        AnimatedBuilder(
          animation: _modeTabController,
          builder: (context, _) {
            final activeMode = _activeLogboekModeFromTabController();
            final filterIconActive = _logboekFilterIconActiveFor(activeMode);
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(
                    filterIconActive
                        ? Icons.filter_alt
                        : Icons.filter_list_outlined,
                  ),
                  color: filterIconActive
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  onPressed: () {
                    if (activeMode == _LogboekMode.uitgaven) {
                      _showUitgavenFilterSheet();
                      return;
                    }
                    if (activeMode == _LogboekMode.betalingen) {
                      _showPaymentFilterSheet();
                      return;
                    }
                    _showWijzigingenFilterSheet();
                  },
                  tooltip: 'Filter',
                ),
                if (activeMode == _LogboekMode.uitgaven ||
                    activeMode == _LogboekMode.betalingen ||
                    activeMode == _LogboekMode.wijzigingen)
                  IconButton(
                    icon: const Icon(Icons.file_download_outlined),
                    onPressed: () {
                      if (activeMode == _LogboekMode.betalingen) {
                        _showPaymentExportConfirmSheet();
                        return;
                      }
                      if (activeMode == _LogboekMode.wijzigingen) {
                        _showWijzigingenExportConfirmSheet();
                        return;
                      }
                      _showExpenseExportConfirmSheet();
                    },
                    tooltip: 'Exporteer selectie',
                  ),
              ],
            );
          },
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(kTextTabBarHeight + 6),
        child: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: TabBar(
            controller: _modeTabController,
            tabs: const [
              Tab(text: 'Uitgaven'),
              Tab(text: 'Wijzigingen'),
              Tab(text: 'Betalingen'),
            ],
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            indicatorSize: TabBarIndicatorSize.label,
            dividerHeight: 0,
            labelPadding: const EdgeInsets.symmetric(horizontal: 16),
          ),
        ),
      ),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: appBar,
        body: logboekContent,
      ),
    );
  }

  /// Gedeelde lege-state voor Logboek-tablijsten: vult de [KiduCard]-ruimte en centreert.
  Widget _logboekListEmptyMessage(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }

  Widget _buildWijzigingenList(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('households/${widget.householdId}/expenses')
          .snapshots(),
      builder: (context, expSnap) {
        if (expSnap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(mapUserFacingError(expSnap.error!)),
            ),
          );
        }
        if (!expSnap.hasData) {
          return const SizedBox.shrink();
        }
        final docs = expSnap.data!.docs;
        final sig = docs
            .map((d) => _expenseDocWijzigLogbookSignature(d.id, d.data()))
            .join('|');
        return FutureBuilder<List<_WijzigLogbookRow>>(
          key: ValueKey(
            '${_periodFilter}_${_filterStart}_${_filterEnd}_${_wijzigFilterEditedByUid}_$sig',
          ),
          future: _wijzigLogbookRowsFutureFor(docs, sig),
          builder: (context, futSnap) {
            if (futSnap.connectionState == ConnectionState.waiting &&
                !futSnap.hasData) {
              return const SizedBox.shrink();
            }
            if (futSnap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(mapUserFacingError(futSnap.error!)),
                ),
              );
            }
            final rows = futSnap.data ?? const <_WijzigLogbookRow>[];
            if (rows.isEmpty) {
              return _logboekListEmptyMessage('Geen wijzigingen gevonden');
            }
            return ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: rows.length,
              separatorBuilder: (context, _) => Divider(
                height: _logboekListSeparatorExtent,
                color: outlineV(context, a40),
              ),
              itemBuilder: (context, i) {
                final row = rows[i];
                final whoLabel = _wijzigEditedByName(row.editedBy);
                final paidByName = _paymentPartyName(row.createdBy);
                final wijzigSubtitle = _expenseSubtitleWithOptionalMonthlyIcon(
                  context,
                  actorAndDateLine:
                      '$whoLabel · ${_formatWijzigingDate(row.editedAt)}',
                  noteTrailing: null,
                  isMaterializedMonthly: row.isMaterializedMonthly,
                );
                return SizedBox(
                  height: _logboekListRowExtent,
                  child: Material(
                    type: MaterialType.transparency,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      highlightColor: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.10),
                      splashColor: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.08),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => _ExpenseDetailPage(
                            householdId: widget.householdId,
                            expenseId: row.expenseId,
                            uid: widget.uid,
                            createdByUid: row.createdBy,
                            title: row.title,
                            amountCents: row.expenseAmountCents,
                            paidByName: paidByName,
                            createdAt: row.createdAt,
                            isPending: false,
                            onManageNote: row.createdBy == widget.uid
                                ? () => _doManagePrivateNote(
                                    context,
                                    householdId: widget.householdId,
                                    expenseId: row.expenseId,
                                    uid: widget.uid,
                                  )
                                : null,
                            otherParentName: widget.otherName,
                            parentSplitSnapshot: row.parentSplitSnapshot,
                            parentSplitMembers: _parentItems
                                .map(
                                  (p) => _ParentSplitMember(
                                    uid: p.uid,
                                    label: p.name,
                                  ),
                                )
                                .toList(growable: false),
                            initialChildNameById: _childrenLoaded
                                ? _childNameById
                                : null,
                            childIds: row.childIds,
                            childNames: row.childIds
                                .map(
                                  (id) =>
                                      _children
                                          .where((c) => c.id == id)
                                          .map((c) => c.name)
                                          .firstOrNull ??
                                      'Verwijderd kind',
                                )
                                .toList(),
                            showChildContext: _hasMultipleHouseholdChildDocs,
                          ),
                        ),
                      ),
                      child: ListTile(
                        key: ValueKey(row.registrationKey),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 5,
                        ),
                        dense: true,
                        minTileHeight: _logboekListRowExtent,
                        minVerticalPadding: 0,
                        visualDensity: VisualDensity.compact,
                        title: Text(
                          row.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: wijzigSubtitle,
                        trailing: _buildWijzigingTrailing(context, row),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildExpenseList(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _expensesStream,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(mapUserFacingError(snap.error!)),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        _maybeWarmPreloadWijzigLogbookRows(snap.data!.docs);
        final docs = List<QueryDocumentSnapshot<Map<String, dynamic>>>.of(
          snap.data!.docs,
        )..sort(_compareExpenseDocsStable);
        if (docs.isEmpty) {
          return _logboekListEmptyMessage('Geen uitgaven gevonden');
        }
        return ListView.separated(
          padding: EdgeInsets.zero,
          itemCount: docs.length,
          separatorBuilder: (context, _) => Divider(
            height: _logboekListSeparatorExtent,
            color: outlineV(context, a40),
          ),
          itemBuilder: (context, i) {
            final d = docs[i];
            final e = d.data();
            final title = (e['title'] as String?)?.trim() ?? '(zonder naam)';
            final amountCents = (e['amountCents'] as num?)?.toInt() ?? 0;
            final createdAtRaw = e['createdAt'];
            DateTime? createdAt;
            if (createdAtRaw is Timestamp) {
              createdAt = createdAtRaw.toDate().toLocal();
            } else if (createdAtRaw is DateTime) {
              createdAt = createdAtRaw.toLocal();
            }
            final childIds =
                (e['childIds'] as List?)?.whereType<String>().toList() ??
                const <String>[];
            final createdBy = (e['createdBy'] as String?)?.trim() ?? '';
            final paidByName = createdBy == widget.uid
                ? (widget.myName ?? 'Jij')
                : (widget.otherName ?? 'Co-parent');
            final nKids = childIds.length;
            final isFiltered = _filterChildId != null && nKids > 0;
            final displayCents = isFiltered
                ? (amountCents / nKids).round()
                : amountCents;
            final dateStr = _fmtDate(createdAt);
            final actorAndDateLine = '$paidByName · $dateStr';
            final isMaterializedMonthly = _expenseDocIsMaterializedMonthly(e);
            final subtitleWidget = _expenseSubtitleWithOptionalMonthlyIcon(
              context,
              actorAndDateLine: actorAndDateLine,
              noteTrailing: null,
              isMaterializedMonthly: isMaterializedMonthly,
            );
            return SizedBox(
              height: _logboekListRowExtent,
              child: Material(
                type: MaterialType.transparency,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  highlightColor: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.10),
                  splashColor: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.08),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _ExpenseDetailPage(
                        householdId: widget.householdId,
                        expenseId: d.id,
                        uid: widget.uid,
                        createdByUid: createdBy,
                        title: title,
                        amountCents: amountCents,
                        paidByName: paidByName,
                        createdAt: createdAt,
                        isPending: false,
                        onManageNote: createdBy == widget.uid
                            ? () => _doManagePrivateNote(
                                context,
                                householdId: widget.householdId,
                                expenseId: d.id,
                                uid: widget.uid,
                              )
                            : null,
                        otherParentName: widget.otherName,
                        parentSplitSnapshot:
                            ParentSplitSnapshot.tryReadFromExpense(e),
                        parentSplitMembers: _parentItems
                            .map(
                              (p) =>
                                  _ParentSplitMember(uid: p.uid, label: p.name),
                            )
                            .toList(growable: false),
                        childIds: childIds,
                        childNames: childIds
                            .map(
                              (id) =>
                                  _children
                                      .where((c) => c.id == id)
                                      .map((c) => c.name)
                                      .firstOrNull ??
                                  'Verwijderd kind',
                            )
                            .toList(),
                        initialChildNameById: _childrenLoaded
                            ? _childNameById
                            : null,
                        showChildContext: _hasMultipleHouseholdChildDocs,
                      ),
                    ),
                  ),
                  child: ListTile(
                    key: ValueKey(d.id),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 5),
                    dense: true,
                    minTileHeight: _logboekListRowExtent,
                    minVerticalPadding: 0,
                    visualDensity: VisualDensity.compact,
                    title: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: subtitleWidget,
                    trailing: Text(
                      _fmtEur(displayCents),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPaymentList(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _paymentsStream,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(mapUserFacingError(snap.error!)),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final allDocs = snap.data!.docs;
        if (allDocs.isEmpty) {
          return _logboekListEmptyMessage('Geen betalingen gevonden');
        }

        final docs = allDocs
            .where(
              (d) => _matchesPaymentParentFilter(
                d.data(),
                _paymentFilterParentUid,
              ),
            )
            .toList(growable: false);

        if (docs.isEmpty) {
          return _logboekListEmptyMessage('Geen betalingen gevonden');
        }
        return ListView.separated(
          padding: EdgeInsets.zero,
          itemCount: docs.length,
          separatorBuilder: (context, _) => Divider(
            height: _logboekListSeparatorExtent,
            color: outlineV(context, a40),
          ),
          itemBuilder: (context, i) {
            final d = docs[i];
            final p = d.data();
            final amountCents = (p['amountCents'] as num?)?.toInt() ?? 0;
            final fromUserId = (p['fromUserId'] as String?)?.trim() ?? '';
            final toUserId = (p['toUserId'] as String?)?.trim() ?? '';
            final status = (p['status'] as String?)?.trim() ?? '';
            final createdAtRaw = p['createdAt'];
            DateTime? createdAt;
            if (createdAtRaw is Timestamp) {
              createdAt = createdAtRaw.toDate().toLocal();
            } else if (createdAtRaw is DateTime) {
              createdAt = createdAtRaw.toLocal();
            }

            final bool isSender = fromUserId == widget.uid;
            final fromName = _paymentPartyName(fromUserId);
            final toName = _paymentPartyName(toUserId);
            final String rowTitle = 'Aan $toName';
            final String statusStr = status == 'confirmed'
                ? 'Bevestigd'
                : 'In afwachting';
            final String dateStr = _fmtDate(createdAt);
            final String subtitleStr = '$dateStr · $statusStr';
            final bool isPending = status != 'confirmed';

            final confirmedAtRaw = p['confirmedAt'];
            DateTime? confirmedAt;
            if (confirmedAtRaw is Timestamp) {
              confirmedAt = confirmedAtRaw.toDate().toLocal();
            } else if (confirmedAtRaw is DateTime) {
              confirmedAt = confirmedAtRaw.toLocal();
            }

            final String? statusExplanation = isPending
                ? (isSender
                      ? 'Wacht op bevestiging door $toName'
                      : 'Wacht op jouw bevestiging')
                : null;

            return SizedBox(
              height: _logboekListRowExtent,
              child: Material(
                type: MaterialType.transparency,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  highlightColor: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.10),
                  splashColor: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.08),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _PaymentDetailPage(
                        title: 'Betaald door $fromName',
                        amountCents: amountCents,
                        status: status,
                        createdAt: createdAt,
                        confirmedAt: confirmedAt,
                        statusExplanation: statusExplanation,
                      ),
                    ),
                  ),
                  child: ListTile(
                    key: ValueKey(d.id),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 5),
                    dense: true,
                    minTileHeight: _logboekListRowExtent,
                    minVerticalPadding: 0,
                    visualDensity: VisualDensity.compact,
                    title: Text(
                      rowTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      subtitleStr,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(
                      _fmtEur(amountCents),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Kinderen management screen
// ────────────────────────────────────────────────────────────────────────────

void _showKinderenInfoSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    builder: (sheetContext) {
      final maxH = min(480.0, MediaQuery.of(sheetContext).size.height * 0.85);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Over kinderen',
                    style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Kinderen toevoegen\n\n'
                    'Voeg kinderen toe waarvoor jullie samen uitgaven bijhouden.\n\n'
                    'Archiveren\n\n'
                    'Archiveer een kind als je het niet meer wilt gebruiken voor nieuwe uitgaven. '
                    'Het wordt verborgen bij nieuwe uitgaven. Bestaande uitgaven blijven bewaard '
                    'en zichtbaar in het logboek.\n\n'
                    'Verwijderen\n\n'
                    'Definitief verwijderen kan alleen vanuit het archief. '
                    'Het kind verdwijnt uit Kinders, maar blijft bewaard voor oude uitgaven '
                    'in het logboek.',
                    style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                      color: onSurface(sheetContext, a68),
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _KinderenPage extends StatefulWidget {
  const _KinderenPage({required this.householdId});

  final String householdId;

  @override
  State<_KinderenPage> createState() => _KinderenPageState();
}

class _KinderenPageState extends State<_KinderenPage> {
  bool _busy = false;

  void _snackErr(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(mapUserFacingError(e))));
  }

  void _snackInfo(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _handleBack() => Navigator.of(context).pop();

  Future<void> _addChild({required List<String> activeNormalised}) async {
    // _AddChildDialog owns the TextEditingController; no disposal needed here.
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _AddChildDialog(activeNormalised: activeNormalised),
    );
    if (newName == null || newName.isEmpty) return;
    setState(() => _busy = true);
    try {
      final normNew = newName.trim().toLowerCase();
      final allSnap = await FirebaseFirestore.instance
          .collection('households/${widget.householdId}/children')
          .get();
      final deleted = allSnap.docs.where((d) {
        final data = d.data();
        if (data['isDeleted'] != true) return false;
        final stored = ((data['name'] as String?) ?? '').trim().toLowerCase();
        return stored == normNew;
      }).toList();

      if (deleted.isNotEmpty) {
        await deleted.first.reference.update({
          'isDeleted': false,
          'isArchived': false,
          'deletedAt': FieldValue.delete(),
        });
        _snackInfo('Bestaand kind hersteld.');
        return;
      }

      await FirebaseFirestore.instance
          .collection('households/${widget.householdId}/children')
          .add({
            'name': newName,
            'createdAt': FieldValue.serverTimestamp(),
            'createdBy': FirebaseAuth.instance.currentUser?.uid ?? '',
            'isArchived': false,
            'isDeleted': false,
          });
    } catch (e) {
      _snackErr(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renameChild(
    String docId,
    String currentName, {
    required List<String> activeNormalisedExcludingSelf,
  }) async {
    // _RenameChildDialog owns the TextEditingController; no disposal needed here.
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _RenameChildDialog(
        currentName: currentName,
        activeNormalisedExcludingSelf: activeNormalisedExcludingSelf,
      ),
    );
    if (newName == null || newName.length < 2) return;
    setState(() => _busy = true);
    try {
      await FirebaseFirestore.instance
          .doc('households/${widget.householdId}/children/$docId')
          .update({'name': newName, 'updatedAt': Timestamp.now()});
    } catch (e) {
      _snackErr(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _archiveChild(String docId, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        title: kiduActionDialogTitle(ctx, 'Kind archiveren?'),
        content: Text('$name wordt verborgen bij nieuwe uitgaven.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuleren'),
          ),
          FilledButton(
            style: kiduDialogPrimaryButtonStyle(ctx),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Archiveren'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await FirebaseFirestore.instance
          .doc('households/${widget.householdId}/children/$docId')
          .update({'isArchived': true, 'updatedAt': Timestamp.now()});
    } catch (e) {
      _snackErr(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreChild(String docId) async {
    setState(() => _busy = true);
    try {
      await FirebaseFirestore.instance
          .doc('households/${widget.householdId}/children/$docId')
          .update({'isArchived': false, 'updatedAt': Timestamp.now()});
    } catch (e) {
      _snackErr(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _softDeleteChild(String docId, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        title: kiduActionDialogTitle(ctx, 'Definitief verwijderen?'),
        content: Text(
          '"$name" wordt definitief verwijderd. '
          'Blijft bewaard voor oude uitgaven.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuleren'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error
                  .withValues(alpha: 0.85),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Verwijderen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await FirebaseFirestore.instance
          .doc('households/${widget.householdId}/children/$docId')
          .update({
            'isDeleted': true,
            'deletedAt': Timestamp.now(),
            'updatedAt': Timestamp.now(),
          });
    } catch (e) {
      _snackErr(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('households/${widget.householdId}/children')
            .orderBy('createdAt')
            .snapshots(),
        builder: (context, snap) {
          final appBar = AppBar(
            centerTitle: true,
            leading: BackButton(onPressed: _handleBack),
            title: Text(
              'Kinderen',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
            actions: [
              IconButton(
                tooltip: 'Uitleg over kinderen',
                icon: const Icon(Icons.info_outline, size: 20),
                onPressed: () => _showKinderenInfoSheet(context),
              ),
            ],
          );

          if (snap.hasError) {
            return Scaffold(
              appBar: appBar,
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(mapUserFacingError(snap.error!)),
                ),
              ),
            );
          }
          if (!snap.hasData) {
            return Scaffold(
              appBar: appBar,
              body: const Center(child: CircularProgressIndicator()),
            );
          }

          final allDocs = snap.data!.docs;

          // Active: not archived AND not soft-deleted.
          final active = allDocs
              .where(
                (d) =>
                    d.data()['isArchived'] != true &&
                    d.data()['isDeleted'] != true,
              )
              .toList();

          // Archived: archived but not yet soft-deleted.
          final archived = allDocs
              .where(
                (d) =>
                    d.data()['isArchived'] == true &&
                    d.data()['isDeleted'] != true,
              )
              .toList();

          // Lower-cased active + archived names for duplicate-name validation.
          final activeNormalised = [
            ...active,
            ...archived,
          ].map((d) => ((d.data()['name'] as String?)?.trim() ?? '').toLowerCase()).toList();

          final atMax = active.length >= 7;

          final fab = FloatingActionButton(
            onPressed: _busy
                ? null
                : atMax
                ? () => _snackInfo(
                    'Maximaal 7 actieve kinderen. Archiveer eerst een kind.',
                  )
                : () => _addChild(activeNormalised: activeNormalised),
            tooltip: atMax ? 'Maximaal 7 actieve kinderen' : null,
            backgroundColor: atMax
                ? Theme.of(context).colorScheme.surfaceContainerHighest
                : null,
            foregroundColor: atMax ? onSurface(context, a62) : null,
            child: const Icon(Icons.add),
          );

          // Flat list: active section, then archived section.
          final items = <Widget>[];

          if (active.isNotEmpty) {
            items.add(
              Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 4),
                child: Text(
                  'Actief',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: onSurface(context, a55),
                  ),
                ),
              ),
            );
            for (int i = 0; i < active.length; i++) {
              final d = active[i];
              final name = (d.data()['name'] as String?)?.trim() ?? '?';
              // Active names excluding this child (for rename duplicate check).
              final othersNormalised = active
                  .where((o) => o.id != d.id)
                  .map(
                    (o) => ((o.data()['name'] as String?)?.trim() ?? '')
                        .toLowerCase(),
                  )
                  .toList();
              if (i > 0) {
                items.add(Divider(height: 1, color: outlineV(context, a32)));
              }
              items.add(
                ListTile(
                  title: Text(name),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        style: IconButton.styleFrom(
                          foregroundColor: onSurface(context, a50),
                        ),
                        icon: const Icon(Icons.edit_outlined, size: 22),
                        tooltip: 'Naam wijzigen',
                        onPressed: _busy
                            ? null
                            : () => _renameChild(
                                d.id,
                                name,
                                activeNormalisedExcludingSelf: othersNormalised,
                              ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        style: IconButton.styleFrom(
                          foregroundColor: onSurface(context, a50),
                        ),
                        icon: const Icon(Icons.archive_outlined, size: 22),
                        tooltip: 'Archiveren',
                        onPressed: _busy
                            ? null
                            : () => _archiveChild(d.id, name),
                      ),
                    ],
                  ),
                ),
              );
            }
          }

          if (archived.isNotEmpty) {
            final archiefTop = active.isNotEmpty ? 40.0 : 24.0;
            items.add(
              Padding(
                padding: EdgeInsets.only(top: archiefTop, bottom: 4),
                child: Text(
                  'Archief',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: onSurface(context, a55),
                  ),
                ),
              ),
            );
            for (int i = 0; i < archived.length; i++) {
              final d = archived[i];
              final name = (d.data()['name'] as String?)?.trim() ?? '?';
              if (i > 0) {
                items.add(Divider(height: 1, color: outlineV(context, a32)));
              }
              items.add(
                Opacity(
                  opacity: 0.72,
                  child: ListTile(
                    title: Text(
                      name,
                      style: TextStyle(color: onSurface(context, a62)),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          style: IconButton.styleFrom(
                            foregroundColor: onSurface(context, a50),
                          ),
                          icon: const Icon(Icons.unarchive_outlined, size: 22),
                          tooltip: 'Herstellen',
                          onPressed: _busy ? null : () => _restoreChild(d.id),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          style: IconButton.styleFrom(
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.error.withValues(alpha: 0.78),
                          ),
                          icon: const Icon(Icons.delete_outline, size: 22),
                          tooltip: 'Definitief verwijderen',
                          onPressed: _busy
                              ? null
                              : () => _softDeleteChild(d.id, name),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
          }

          return Scaffold(
            appBar: appBar,
            floatingActionButton: Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 16),
              child: fab,
            ),
            body: items.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Nog geen kinderen. Voeg er een toe met +.'),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    children: items,
                  ),
          );
        },
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Maandelijkse uitgaven – v1 page + add-form shell
//
// Local-only UI shell for the recurring-expenses feature. Reached from
// Instellingen > Huishouden. The page now owns a calm intro/empty-state and
// a CTA that opens [_AddRecurringExpenseDialog]. This step intentionally
// ships NO recurring data model, NO Firestore reads/writes for templates,
// and NO persistence — saving the form is a no-op that closes after local
// client-side validation only.
// ────────────────────────────────────────────────────────────────────────────

const int _kRecurringTitleMaxLength = 60;

void _showMonthlyExpensesInfoSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Over maandelijkse uitgaven',
              style: Theme.of(
                sheetContext,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              'Een maandelijkse uitgave is een afspraak.\n\n'
              'KiDu maakt hiervan elke maand automatisch een gewone uitgave.\n\n'
              'Nieuwe maandelijkse uitgaven starten met de huidige uitgavenverdeling.\n\n'
              'Daarna staat de verdeling vast op deze maandelijkse uitgave.\n\n'
              'Wijzigingen in Instellingen veranderen bestaande maandelijkse uitgaven niet.\n\n'
              'Eerder aangemaakte uitgaven blijven ook onveranderd.',
              style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                color: onSurface(sheetContext, a68),
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Parses a Dutch-style EUR amount (e.g. "12,34" or "12.34") to integer cents.
/// Mirrors the parsing rhythm of the "Nieuwe uitgave" amount field.
/// Local helper for the recurring-expense form; the dashboard keeps its own
/// private equivalent to avoid coupling this flow to dashboard internals.
int? _tryParseRecurringEurToCents(String input) {
  final raw = input.trim().replaceAll(' ', '');
  if (raw.isEmpty) return null;
  final normalized = raw.replaceAll(',', '.');
  if (!RegExp(r'^\d+(\.\d{0,2})?$').hasMatch(normalized)) return null;
  final parts = normalized.split('.');
  final euros = int.tryParse(parts[0]) ?? 0;
  var cents = 0;
  if (parts.length == 2 && parts[1].isNotEmpty) {
    final frac = parts[1];
    if (frac.length == 1) {
      cents = int.parse(frac) * 10;
    } else if (frac.length == 2) {
      cents = int.parse(frac);
    } else {
      return null;
    }
  }
  return euros * 100 + cents;
}

String _formatRecurringStartDateNl(DateTime dt) {
  const months = [
    'januari',
    'februari',
    'maart',
    'april',
    'mei',
    'juni',
    'juli',
    'augustus',
    'september',
    'oktober',
    'november',
    'december',
  ];
  return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
}

/// Compacte NL-datum (`<d MMM>`) voor de recurring lijstregel.
/// Alleen dag + korte maandnaam, bewust zonder jaartal zodat de subtitle
/// rustig blijft. Gebruikt dezelfde maandvolgorde als [_formatRecurringStartDateNl].
String _formatRecurringShortDateNl(DateTime dt) {
  const months = [
    'jan',
    'feb',
    'mrt',
    'apr',
    'mei',
    'jun',
    'jul',
    'aug',
    'sep',
    'okt',
    'nov',
    'dec',
  ];
  return '${dt.day} ${months[dt.month - 1]}';
}

/// Dutch-style EUR formatter mirroring the dashboard's _formatEur rhythm.
/// Kept local to the recurring flow so this step does not depend on
/// _DashboardPageState.
String _formatRecurringEurCents(int cents) {
  final abs = cents.abs();
  final euros = abs ~/ 100;
  final rem = abs % 100;
  final euroStr = euros.toString();
  final buf = StringBuffer();
  for (var i = 0; i < euroStr.length; i++) {
    if (i > 0 && (euroStr.length - i) % 3 == 0) buf.write('.');
    buf.write(euroStr[i]);
  }
  return '€$buf,${rem.toString().padLeft(2, '0')}';
}

/// Human-readable status label for a recurring master. Unknown/missing
/// values fall back to the active label so v1 reads calmly.
String _formatRecurringStatusLabel(String? status) {
  if (status == 'paused') return 'Gepauzeerd';
  return 'Actief';
}

/// Compact, tone-of-voice consistent oudernaam voor recurring weergaves.
///
/// Voor de lijstregel willen we beide ouders op dezelfde manier tonen:
/// altijd de echte naam, dus óók voor de eigen gebruiker (geen `Jij`).
/// Daarom geeft de caller desgewenst `myParentName` mee — dan krijgt de
/// maker zijn/haar eigen echte naam. Zonder `myParentName` valt de helper
/// terug op `Jij` voor eigenaar, wat op detailschermen nog passend is.
String _recurringParentLabel({
  required String createdByUid,
  required String? currentUid,
  required String? otherParentName,
  String? myParentName,
}) {
  final created = createdByUid.trim();
  final me = (currentUid ?? '').trim();
  if (created.isNotEmpty && me.isNotEmpty && created == me) {
    final mine = myParentName?.trim();
    if (mine != null && mine.isNotEmpty) return mine;
    return 'Jij';
  }
  final o = otherParentName?.trim();
  if (o != null && o.isNotEmpty) return o;
  return 'Co-parent';
}

/// Subtiele statuskleur voor de kleine indicator-dot in de recurring
/// lijstregel. Bewust gedempt gekozen zodat `active` niet schreeuwt en
/// `paused` wel herkenbaar opvalt zonder waarschuwingstoon.
Color _recurringStatusDotColor(String? status) {
  if (status == 'paused') return const Color(0xFFB07700); // amber/oranje
  return _kSuccessGreen;
}

const String _kRecurringParentSplitParticipantUidsField =
    'recurringParentSplitParticipantUids';
const String _kRecurringParentSplit0ShareBpsField =
    'recurringParentSplit0ShareBps';

class _ParentSplitMember {
  const _ParentSplitMember({required this.uid, required this.label});

  final String uid;
  final String label;
}

Map<String, dynamic> _recurringParentSplitFields(
  ParentSplitSnapshot snapshot,
) => <String, dynamic>{
  _kRecurringParentSplitParticipantUidsField: snapshot.participantUids,
  _kRecurringParentSplit0ShareBpsField: snapshot.share0Bps,
};

ParentSplitSnapshot? _tryReadRecurringParentSplit(Map<String, dynamic>? data) {
  if (data == null) return null;
  final raw = data[_kRecurringParentSplitParticipantUidsField];
  final bpsRaw = data[_kRecurringParentSplit0ShareBpsField];
  if (raw is! List || bpsRaw is! num) return null;
  return ParentSplitSnapshot.tryCreate(
    participantUids: raw.whereType<String>().toList(growable: false),
    share0Bps: bpsRaw.toInt(),
  );
}

String _formatParentSplitShare(int bps) {
  final pct = bps / 100.0;
  if (pct == pct.roundToDouble()) return '${pct.toStringAsFixed(0)}%';
  return '${pct.toStringAsFixed(1)}%';
}

String _parentSplitMemberLabel(
  List<_ParentSplitMember> members,
  String uid, {
  required String fallbackLabel,
}) {
  for (final member in members) {
    if (member.uid == uid) {
      final label = member.label.trim();
      if (label.isNotEmpty && label != 'Ouder') return label;
    }
  }
  return fallbackLabel;
}

String _parentSplitFallbackLabel({
  required String uid,
  required String? viewerUid,
  required int displayIndex,
  String? myParentName,
  String? otherParentName,
}) {
  final viewer = (viewerUid ?? '').trim();
  if (viewer.isNotEmpty && uid == viewer) {
    final mine = myParentName?.trim();
    if (mine != null && mine.isNotEmpty) return mine;
    return 'Ouder $displayIndex';
  }
  final other = otherParentName?.trim();
  if (other != null && other.isNotEmpty) return other;
  return 'Ouder $displayIndex';
}

({String firstUid, int firstBps, String secondUid, int secondBps})
_viewerFirstParentSplit(ParentSplitSnapshot snapshot, String? viewerUid) {
  final viewer = (viewerUid ?? '').trim();
  final uid0 = snapshot.participantUids[0];
  final uid1 = snapshot.participantUids[1];
  if (viewer == uid1) {
    return (
      firstUid: uid1,
      firstBps: snapshot.share1Bps,
      secondUid: uid0,
      secondBps: snapshot.share0Bps,
    );
  }
  return (
    firstUid: uid0,
    firstBps: snapshot.share0Bps,
    secondUid: uid1,
    secondBps: snapshot.share1Bps,
  );
}

String _formatParentSplitCompact(
  ParentSplitSnapshot snapshot,
  String? viewerUid,
) {
  final ordered = _viewerFirstParentSplit(snapshot, viewerUid);
  return '${_formatParentSplitShare(ordered.firstBps).replaceAll('%', '')}/'
      '${_formatParentSplitShare(ordered.secondBps).replaceAll('%', '')}';
}

String _formatParentSplitNamed(
  ParentSplitSnapshot snapshot,
  List<_ParentSplitMember> members,
  String? viewerUid, {
  String? myParentName,
  String? otherParentName,
}) {
  final ordered = _viewerFirstParentSplit(snapshot, viewerUid);
  final firstLabel = _parentSplitMemberLabel(
    members,
    ordered.firstUid,
    fallbackLabel: _parentSplitFallbackLabel(
      uid: ordered.firstUid,
      viewerUid: viewerUid,
      displayIndex: 1,
      myParentName: myParentName,
      otherParentName: otherParentName,
    ),
  );
  final secondLabel = _parentSplitMemberLabel(
    members,
    ordered.secondUid,
    fallbackLabel: _parentSplitFallbackLabel(
      uid: ordered.secondUid,
      viewerUid: viewerUid,
      displayIndex: 2,
      myParentName: myParentName,
      otherParentName: otherParentName,
    ),
  );
  return '$firstLabel '
      '${_formatParentSplitShare(ordered.firstBps)} · '
      '$secondLabel '
      '${_formatParentSplitShare(ordered.secondBps)}';
}

Future<List<_ParentSplitMember>> _loadParentSplitMembers(
  String householdId,
) async {
  if (householdId.trim().isEmpty) return const <_ParentSplitMember>[];
  final firestore = FirebaseFirestore.instance;
  final memberSnap = await firestore
      .collection('households/$householdId/members')
      .get();
  final memberUids = memberSnap.docs.map((d) => d.id).toList(growable: false)
    ..sort();
  final result = <_ParentSplitMember>[];
  for (final uid in memberUids) {
    String label = 'Ouder';
    try {
      final user = await firestore.doc('users/$uid').get();
      final data = user.data();
      final name = (data?['profileName'] ?? data?['displayName']) as String?;
      if (name != null && name.trim().isNotEmpty) label = name.trim();
    } catch (_) {
      // Keep UI labels calm; technical ids must never surface.
    }
    result.add(_ParentSplitMember(uid: uid, label: label));
  }
  return result;
}

ParentSplitSnapshot? _neutralParentSplitForMembers(
  List<_ParentSplitMember> members,
) {
  if (members.length != kParentSplitParticipantCount) return null;
  final uids = sortedParticipantUids(members[0].uid, members[1].uid);
  return ParentSplitSnapshot.tryCreate(
    participantUids: uids,
    share0Bps: kHouseholdShareBpsNeutral,
  );
}

Future<ParentSplitSnapshot?> _legacyRecurringParentSplitFallback(
  String householdId,
) async {
  final members = await _loadParentSplitMembers(householdId);
  return _neutralParentSplitForMembers(members);
}

class _RecurringParentSplitDialog extends StatefulWidget {
  const _RecurringParentSplitDialog({
    required this.members,
    required this.initialSnapshot,
    required this.viewerUid,
    this.contextFooterText =
        'Deze verdeling hoort alleen bij deze maandelijkse uitgave.',
    this.minShareBps = kHouseholdShareBpsMin,
    this.maxShareBps = kHouseholdShareBpsMax,
  }) : assert(minShareBps >= 0),
       assert(maxShareBps <= kBpsFull),
       assert(minShareBps <= maxShareBps);

  final List<_ParentSplitMember> members;
  final ParentSplitSnapshot initialSnapshot;
  final String? viewerUid;
  final String contextFooterText;

  /// Slider range in bps (defaults 0..kBpsFull unless overridden).
  final int minShareBps;
  final int maxShareBps;

  @override
  State<_RecurringParentSplitDialog> createState() =>
      _RecurringParentSplitDialogState();
}

class _RecurringParentSplitDialogState
    extends State<_RecurringParentSplitDialog> {
  late String _share0Uid;
  late int _share0Bps;

  @override
  void initState() {
    super.initState();
    final ordered = _viewerFirstParentSplit(
      widget.initialSnapshot,
      widget.viewerUid,
    );
    _share0Uid = ordered.firstUid;
    _share0Bps = ordered.firstBps.clamp(widget.minShareBps, widget.maxShareBps);
  }

  _ParentSplitMember get _share0Member =>
      widget.members.firstWhere((m) => m.uid == _share0Uid);

  _ParentSplitMember get _share1Member =>
      widget.members.firstWhere((m) => m.uid != _share0Uid);

  ParentSplitSnapshot? _snapshot() {
    final storedUids = widget.initialSnapshot.participantUids;
    final storedShare0Bps = storedUids[0] == _share0Uid
        ? _share0Bps
        : kBpsFull - _share0Bps;
    return ParentSplitSnapshot.tryCreate(
      participantUids: storedUids,
      share0Bps: storedShare0Bps,
    );
  }

  bool get _hasChanges {
    final ordered = _viewerFirstParentSplit(
      widget.initialSnapshot,
      widget.viewerUid,
    );
    final initialBps = ordered.firstBps.clamp(
      widget.minShareBps,
      widget.maxShareBps,
    );
    return _share0Bps != initialBps;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final shareStyle = Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600);
    final nameStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: onSurface(context, a80),
    );

    return AlertDialog(
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      title: kiduActionDialogTitle(context, 'Uitgavenverdeling'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${_share0Member.label} ', style: nameStyle),
                  TextSpan(
                    text: '${_formatParentSplitShare(_share0Bps)} · ',
                    style: shareStyle,
                  ),
                  TextSpan(text: '${_share1Member.label} ', style: nameStyle),
                  TextSpan(
                    text: _formatParentSplitShare(kBpsFull - _share0Bps),
                    style: shareStyle,
                  ),
                ],
              ),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: cs.primary.withValues(alpha: 0.58),
                inactiveTrackColor: cs.onSurface.withValues(alpha: 0.12),
                thumbColor: cs.primary.withValues(alpha: 0.72),
                overlayColor: cs.primary.withValues(alpha: 0.08),
                trackHeight: 3,
              ),
              child: Slider(
                min: widget.minShareBps.toDouble(),
                max: widget.maxShareBps.toDouble(),
                divisions: (widget.maxShareBps - widget.minShareBps) ~/ 100,
                value: _share0Bps
                    .toDouble()
                    .clamp(
                      widget.minShareBps.toDouble(),
                      widget.maxShareBps.toDouble(),
                    )
                    .toDouble(),
                label: _formatParentSplitShare(_share0Bps),
                onChanged: (value) => setState(() {
                  _share0Bps = value.round().clamp(
                    widget.minShareBps,
                    widget.maxShareBps,
                  );
                }),
              ),
            ),
            Text(
              widget.contextFooterText,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: onSurface(context, a62),
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuleren'),
        ),
        FilledButton(
          style: kiduDialogPrimaryButtonStyle(context),
          onPressed: _hasChanges
              ? () => Navigator.of(context).pop(_snapshot())
              : null,
          child: const Text('Opslaan'),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Pure materialisatie-helper voor Maandelijkse uitgaven
//
// Deze sectie is bewust volledig zuiver: geen Firestore, geen UI, geen
// lifecycle-trigger en geen runner. De helper levert alleen het
// deterministische plan per ontbrekende periode, zodat een latere
// write-laag exact weet welke expense-instances gemaakt moeten worden.
// ────────────────────────────────────────────────────────────────────────────

/// Pure snapshot van een recurring master, losgekoppeld van Firestore-typen.
///
/// Het doel is de berekening triviaal testbaar en zijeffect-vrij te houden;
/// de write-laag vertaalt t.z.t. tussen DocumentSnapshot/Timestamp en dit
/// value object.
// ignore: unused_element
class _RecurringMasterInput {
  const _RecurringMasterInput({
    required this.masterId,
    required this.title,
    required this.amountCents,
    required this.currency,
    required this.childIds,
    required this.startDate,
    required this.dueDayOfMonth,
    required this.materializeFromDate,
    required this.status,
    required this.createdBy,
    required this.parentSplitSnapshot,
  });

  final String masterId;
  final String title;
  final int amountCents;
  final String currency;
  final List<String> childIds;

  /// Oorspronkelijke start/ankerdatum van de master. Blijft behouden als
  /// historisch concept en als create-tijd ankerpunt; is niet langer de
  /// (enige) bron voor de zichtbare vervaldag-semantiek.
  final DateTime startDate;

  /// Terugkerende vervaldag van de maand (1..31). Voor legacy masters
  /// zonder dit veld vult de runner dit op met `startDate.day`.
  final int dueDayOfMonth;

  /// Interne datumgrens waarop de runner mag starten met materialiseren.
  /// Beperkt alleen vanaf welke due-datum er überhaupt gematerialiseerd
  /// mag worden. Bij create op rules-niveau gelijk aan `startDate`; voor
  /// legacy masters zonder het veld vult de runner dit op met `startDate`.
  final DateTime materializeFromDate;

  final String status;
  final String createdBy;

  /// Eigen verdeling van deze monthly master. Wordt bij materialisatie één-op-één
  /// naar de immutable expense-snapshot gekopieerd.
  final ParentSplitSnapshot? parentSplitSnapshot;
}

/// Pure plan-entry voor één ontbrekende periode.
///
/// Bevat alle velden die een latere write-laag nodig heeft om een
/// deterministische expense-instance aan te maken. Er is bewust geen
/// DocumentReference en geen Firestore-Timestamp: de write-laag wrapt dat
/// zelf wanneer die echt gaat schrijven.
// ignore: unused_element
class _RecurringMaterializationPlan {
  const _RecurringMaterializationPlan({
    required this.masterId,
    required this.periodKey,
    required this.dueAt,
    required this.expenseId,
    required this.title,
    required this.amountCents,
    required this.currency,
    required this.childIds,
    required this.recurringExpenseId,
    required this.createdBy,
    required this.createdAt,
  });

  final String masterId;
  final String periodKey;

  /// Lokale maker-datum om 00:00 voor deze periode, al geclamped naar de
  /// laatste dag van de maand als startDate.day daar niet in past.
  final DateTime dueAt;

  /// Deterministische toekomstige expense-id: `rec_<masterId>_<periodKey>`.
  final String expenseId;

  final String title;
  final int amountCents;
  final String currency;
  final List<String> childIds;

  /// Verwijzing naar de master; wordt straks letterlijk meegeschreven in
  /// het expense-instance-document.
  final String recurringExpenseId;

  final String createdBy;

  /// Semantische createdAt voor de latere expense-instance: de due-datum
  /// om 00:00 lokale tijd van de maker — NIET het moment van materialiseren.
  final DateTime createdAt;
}

/// Vormt een periodKey als `YYYY-MM`.
String _formatRecurringPeriodKey(int year, int month) {
  final mm = month.toString().padLeft(2, '0');
  return '$year-$mm';
}

/// Aantal dagen in maand [month] van jaar [year].
/// `DateTime(y, m + 1, 0)` rolt netjes naar de laatste dag van maand m.
int _recurringDaysInMonth(int year, int month) {
  return DateTime(year, month + 1, 0).day;
}

/// Due-datum voor één periode: lokale datum om 00:00, met clamp naar de
/// laatste dag van de maand als [startDay] groter is dan het aantal dagen
/// van die maand (bv. startDay 31 → 28/29 februari).
DateTime _recurringDueDateFor({
  required int year,
  required int month,
  required int startDay,
}) {
  final maxDay = _recurringDaysInMonth(year, month);
  final day = startDay > maxDay ? maxDay : startDay;
  return DateTime(year, month, day);
}

/// Pure display-afleiding: retourneert de eerstvolgende concrete
/// vervaldatum van een recurring master, of `null` als die er
/// semantisch niet is.
///
/// Bewust volledig zijeffect-vrij: geen Firestore, geen writes, geen
/// dependency op de runner. Wordt uitsluitend door de UI gebruikt om
/// lijstregel en detailscherm semantisch correct te renderen.
///
/// Regels:
///  * bij `status != 'active'` → `null` (gepauzeerd toont géén concrete
///    eerstvolgende datum),
///  * `dueDayOfMonth` is leidend; voor legacy masters zonder dit veld
///    valt de helper terug op `startDate.day`,
///  * clamp-regel is identiek aan [_recurringDueDateFor]: als de
///    structurele dag niet bestaat in een maand (bv. 31 in februari)
///    geldt de laatste dag van die maand,
///  * anchor = `max(today, materializeFromDate-floor)` zodat gepauzeerde
///    periodes nooit alsnog als eerstvolgende datum opduiken en de
///    eerstvolgende datum nooit in het verleden ligt,
///  * [existingPeriodKeys] bevat de periodKeys (`YYYY-MM`) waarvoor al
///    een expense-instance bestaat; die periodes worden in de afleiding
///    overgeslagen zodat we niet blijven hangen op vandaag terwijl de
///    periode van vandaag feitelijk al is gematerialiseerd,
///  * iteratie is bounded (max 60 maanden vooruit) als defensieve safety.
DateTime? _recurringNextConcreteDueDate({
  required String? status,
  required int? dueDayOfMonth,
  required DateTime? startDate,
  required DateTime? materializeFromDate,
  required DateTime now,
  Set<String> existingPeriodKeys = const <String>{},
}) {
  if (status != 'active') return null;

  int? effectiveDueDay = dueDayOfMonth;
  if (effectiveDueDay == null && startDate != null) {
    effectiveDueDay = startDate.day;
  }
  if (effectiveDueDay == null) return null;
  if (effectiveDueDay < 1) effectiveDueDay = 1;
  if (effectiveDueDay > 31) effectiveDueDay = 31;

  final today = DateTime(now.year, now.month, now.day);
  final floor = materializeFromDate != null
      ? DateTime(
          materializeFromDate.year,
          materializeFromDate.month,
          materializeFromDate.day,
        )
      : today;
  final anchor = today.isAfter(floor) ? today : floor;

  var year = anchor.year;
  var month = anchor.month;
  for (var i = 0; i < 60; i++) {
    final due = _recurringDueDateFor(
      year: year,
      month: month,
      startDay: effectiveDueDay,
    );
    if (!due.isBefore(anchor)) {
      final periodKey = _formatRecurringPeriodKey(year, month);
      if (!existingPeriodKeys.contains(periodKey)) {
        return due;
      }
    }
    month += 1;
    if (month > 12) {
      month = 1;
      year += 1;
    }
  }
  return null;
}

/// Pure berekening van ontbrekende periodes voor één recurring master.
///
/// Retourneert een chronologische lijst van plan-entries voor elke periode die
///  * op of ná de startmaand ligt,
///  * waarvan de due-datum lokaal reeds is bereikt (`now` op of ná due),
///  * waarvan de due-datum op of ná [_RecurringMasterInput.materializeFromDate]
///    ligt (interne floor voor pause/hervat- en datumwijzigings-semantiek),
///  * én nog niet voorkomt in [existingPeriodKeys].
///
/// Voor `master.status != 'active'` is het resultaat altijd leeg. Backfill
/// van meerdere ontbrekende maanden is expliciet toegestaan, maar nooit
/// onder de floor. Er wordt geen Firestore aangeraakt en er worden geen
/// Timestamps of DocumentReferences geproduceerd.
// ignore: unused_element
List<_RecurringMaterializationPlan> _computeRecurringMaterializationPlan({
  required _RecurringMasterInput master,
  required DateTime now,
  required Set<String> existingPeriodKeys,
}) {
  if (master.status != 'active') {
    return const <_RecurringMaterializationPlan>[];
  }

  // De dag-van-de-maand komt voortaan uit `dueDayOfMonth` (is voor legacy
  // masters door de runner al gevuld met `startDate.day`, en in de helper
  // hier nogmaals geclamped naar een veilig bereik als extra verdediging).
  final rawDueDay = master.dueDayOfMonth;
  final startDay = rawDueDay < 1 ? 1 : (rawDueDay > 31 ? 31 : rawDueDay);
  var year = master.startDate.year;
  var month = master.startDate.month;

  // Floor normaliseren naar lokale 00:00 zodat de vergelijking met de
  // due-datum (eveneens 00:00 lokaal) puur calendrisch is.
  final floor = DateTime(
    master.materializeFromDate.year,
    master.materializeFromDate.month,
    master.materializeFromDate.day,
  );

  final plans = <_RecurringMaterializationPlan>[];

  while (true) {
    final due = _recurringDueDateFor(
      year: year,
      month: month,
      startDay: startDay,
    );
    // "Aan de beurt" = now op of ná due. Zodra due strikt na now ligt,
    // stoppen we; latere maanden zijn per definitie ook nog niet toe.
    if (due.isAfter(now)) break;

    // Periodes onder de floor zijn definitief overgeslagen (pauze-venster
    // of vooruitgeschoven datumwijziging). We gaan door met de volgende
    // maand; stoppen mag niet, want latere maanden kunnen de floor wél
    // passeren.
    if (due.isBefore(floor)) {
      month += 1;
      if (month > 12) {
        month = 1;
        year += 1;
      }
      continue;
    }

    final periodKey = _formatRecurringPeriodKey(year, month);
    if (!existingPeriodKeys.contains(periodKey)) {
      plans.add(
        _RecurringMaterializationPlan(
          masterId: master.masterId,
          periodKey: periodKey,
          dueAt: due,
          expenseId: 'rec_${master.masterId}_$periodKey',
          title: master.title,
          amountCents: master.amountCents,
          currency: master.currency,
          childIds: List<String>.unmodifiable(master.childIds),
          recurringExpenseId: master.masterId,
          createdBy: master.createdBy,
          createdAt: due,
        ),
      );
    }

    month += 1;
    if (month > 12) {
      month = 1;
      year += 1;
    }
  }

  return plans;
}

// ────────────────────────────────────────────────────────────────────────────
// Write-laag voor recurring materialisatie (geïsoleerd, nog niet live)
//
// Bouwt bovenop de pure helper `_computeRecurringMaterializationPlan` en
// voert de feitelijke Firestore-writes uit voor ontbrekende expense-
// instances van één master. Deze stap sluit expliciet niets automatisch
// aan: geen app-lifecycle, geen runner, geen save-flow-trigger. Een latere
// stap koppelt dit aan een trigger.
// ────────────────────────────────────────────────────────────────────────────

/// Resultaat van één materialisatie-run voor één master.
///
/// Bedoeld voor een latere runner/log-laag. De helper zelf gooit geen
/// exceptions omhoog voor per-instance-fouten maar verzamelt ze, zodat één
/// falende periode de rest niet stuk maakt.
// ignore: unused_element
class _RecurringMaterializationResult {
  const _RecurringMaterializationResult({
    required this.createdExpenseIds,
    required this.skippedExpenseIds,
    required this.failedExpenseIds,
    required this.copiedNoteExpenseIds,
    required this.failedNoteCopyExpenseIds,
  });

  /// Expense-ids die daadwerkelijk in deze run zijn aangemaakt.
  final List<String> createdExpenseIds;

  /// Expense-ids die al bestonden en daarom zijn overgeslagen (idempotency).
  final List<String> skippedExpenseIds;

  /// Expense-ids waarvan de expense-create faalde (rules, netwerk, race, …).
  /// De overige entries in dezelfde run zijn wél geprobeerd. Dit veld gaat
  /// bewust niet over note-copy failures; die staan apart in
  /// [failedNoteCopyExpenseIds].
  final List<String> failedExpenseIds;

  /// Expense-ids waarvoor de master-note éénmalig is gekopieerd naar de
  /// nieuwe instance-note.
  final List<String> copiedNoteExpenseIds;

  /// Expense-ids waarvan de expense zelf wél is aangemaakt, maar waarvoor
  /// de master-note-kopie naar de instance-note ook na een korte retry
  /// niet is gelukt. De expense-instance zelf is hiervoor gewoon valide;
  /// een latere runner/log-laag kan hier expliciet op reageren.
  final List<String> failedNoteCopyExpenseIds;
}

/// Materialiseert voor één recurring master de ontbrekende expense-instances.
///
/// Verantwoordelijkheid:
///  * creator-only: alleen als `uid == master.createdBy` gebeurt er iets,
///  * bepaalt bestaande `periodKeys` via een smalle read-query op
///    `expenses where recurringExpenseId == master.masterId`,
///  * gebruikt de pure helper om het plan te maken,
///  * schrijft per plan-entry éérst de expense-instance en daarná (als
///    de master een niet-lege privateNote heeft) éénmalig een kopie van
///    die note naar de instance-note.
///
/// Write-volgorde (bewust niet in één WriteBatch):
///  * de rules voor `expenses/{id}/privateNotes/{uid}` vereisen dat de
///    expense al bestaat (`exists(...)`) én dat de creator overeenkomt;
///    binnen één batch ziet Firestore sibling-writes nog niet, dus
///    een batch met expense + note zou altijd de note-create blokkeren.
///    We schrijven daarom eerst de expense (await), daarna de note.
///
/// Idempotency:
///  * deterministische id `rec_<masterId>_<periodKey>` + create-only write
///    binnen een transactie vormen de harde garantie: bestaat het document
///    al, dan schrijven we niets en tellen we de entry als skipped,
///  * de losse `get()` vóór de transactie is slechts een lichte
///    optimalisatie om een overduidelijk bestaande instance snel over te
///    slaan; de correctheid leunt op de transactie, niet op deze pre-check,
///  * per-entry fouten worden geteld en breken de rest niet,
///  * note-kopie is best-effort met één korte directe retry; blijft de
///    kopie dan nog falen, dan staat de expense-instance gewoon en wordt
///    de id apart bijgehouden in `failedNoteCopyExpenseIds` zodat een
///    latere runner/log-laag er gericht op kan reageren.
///
/// Deze functie wordt in deze stap bewust nog nergens aangeroepen. Een
/// latere trigger/runner-stap bepaalt waar en wanneer dit draait.
// ignore: unused_element
Future<_RecurringMaterializationResult> _materializeRecurringMasterOnce({
  required String householdId,
  required String uid,
  required _RecurringMasterInput master,
  required DateTime now,
}) async {
  const emptyResult = _RecurringMaterializationResult(
    createdExpenseIds: <String>[],
    skippedExpenseIds: <String>[],
    failedExpenseIds: <String>[],
    copiedNoteExpenseIds: <String>[],
    failedNoteCopyExpenseIds: <String>[],
  );

  // Creator-only. Geen co-parent-pad, geen brede master-scan.
  if (uid.isEmpty || householdId.isEmpty || master.masterId.isEmpty) {
    return emptyResult;
  }
  if (uid != master.createdBy) return emptyResult;
  if (master.status != 'active') return emptyResult;

  final firestore = FirebaseFirestore.instance;

  // Bestaande periodKeys voor déze master bepalen. Smal gescoped op
  // `recurringExpenseId`; rules staan members lezen toe maar we schrijven
  // verderop alleen als creator.
  final existingPeriodKeys = <String>{};
  try {
    final existing = await firestore
        .collection('households/$householdId/expenses')
        .where('recurringExpenseId', isEqualTo: master.masterId)
        .get();
    for (final doc in existing.docs) {
      final pk = doc.data()['periodKey'];
      if (pk is String && pk.isNotEmpty) existingPeriodKeys.add(pk);
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('Recurring materialize: read existing failed: $e');
    }
    return emptyResult;
  }

  final plans = _computeRecurringMaterializationPlan(
    master: master,
    now: now,
    existingPeriodKeys: existingPeriodKeys,
  );
  if (plans.isEmpty) return emptyResult;

  // Parent-split snapshot for this materialization run comes from the master
  // itself. It is intentionally not re-read from household settings, so later
  // settings changes never alter existing monthly masters.
  final materializationSnapshot = master.parentSplitSnapshot;

  // Master-note éénmalig inlezen (zelfde snapshot als sharedWithUids);
  // lege/ontbrekende note → geen note-doc kopie.
  String? masterNote;
  List<String> masterSharedWithUids = const [];
  try {
    final noteSnap = await firestore
        .doc(
          'households/$householdId/recurringExpenses/'
          '${master.masterId}/privateNotes/$uid',
        )
        .get();
    final data = noteSnap.data();
    final raw = (data?['note'] as String?)?.trim() ?? '';
    if (raw.isNotEmpty) masterNote = raw;
    masterSharedWithUids = _parsePrivateNoteSharedWithUids(data);
  } catch (e) {
    // Note-bron niet leesbaar → we slaan note-kopie simpelweg over. De
    // expense-creates zelf moeten hier niet op struikelen.
    if (kDebugMode) {
      debugPrint('Recurring materialize: read master note failed: $e');
    }
    masterNote = null;
    masterSharedWithUids = const [];
  }

  final created = <String>[];
  final skipped = <String>[];
  final failed = <String>[];
  final copiedNote = <String>[];
  final failedNoteCopy = <String>[];

  for (final plan in plans) {
    final expenseRef = firestore.doc(
      'households/$householdId/expenses/${plan.expenseId}',
    );

    // Lichte skip-optimalisatie: als we nu al een bestaande instance zien,
    // slaan we de transactie over. De échte correctheid komt van de
    // create-only transactie hieronder, niet van deze pre-check.
    try {
      final pre = await expenseRef.get();
      if (pre.exists) {
        skipped.add(plan.expenseId);
        continue;
      }
    } catch (e) {
      // Pre-check is niet-kritiek: laat de transactie alsnog proberen.
      if (kDebugMode) {
        debugPrint(
          'Recurring materialize: pre-check ${plan.expenseId} failed: $e',
        );
      }
    }

    // Snapshot-velden voor de expense-instance. Volgt exact de create-
    // rules voor recurring-linked expenses (`hasOnly`): title, amountCents,
    // currency, createdAt, createdBy, childIds, recurringExpenseId,
    // periodKey, materializedAt. createdAt wordt bewust op de due-datum
    // gezet, niet op het moment van materialiseren. `materializedAt` legt
    // aanvullend het echte serverside materialisatie-moment vast en dient
    // later als secundaire sorteer-as; `createdAt` blijft onveranderd de
    // semantische due-datum 00:00 lokale maker-tijd.
    final data = <String, dynamic>{
      'amountCents': plan.amountCents,
      'currency': plan.currency,
      'title': plan.title,
      'createdAt': Timestamp.fromDate(plan.createdAt),
      'createdBy': plan.createdBy,
      if (plan.childIds.isNotEmpty) 'childIds': plan.childIds,
      'recurringExpenseId': plan.recurringExpenseId,
      'periodKey': plan.periodKey,
      'materializedAt': FieldValue.serverTimestamp(),
      if (materializationSnapshot != null)
        ...materializationSnapshot.toExpenseFields(),
    };

    // Create-only write via transactie: we schrijven alleen als het
    // document nog niet bestaat. Zo kunnen twee devices / twee triggers
    // niet allebei een instance voor dezelfde (masterId, periodKey)
    // aanmaken; de tweede ziet binnen de transactie `snap.exists` en
    // slaat rustig over. Géén upsert, géén stil overschrijven.
    bool didCreate;
    try {
      didCreate = await firestore.runTransaction<bool>((tx) async {
        final snap = await tx.get(expenseRef);
        if (snap.exists) return false;
        tx.set(expenseRef, data);
        return true;
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          'Recurring materialize: create ${plan.expenseId} failed: '
          '${mapUserFacingError(e, fallback: e.toString())}',
        );
      }
      failed.add(plan.expenseId);
      continue;
    }

    if (!didCreate) {
      skipped.add(plan.expenseId);
      continue;
    }
    created.add(plan.expenseId);

    // Master-note éénmalig kopiëren naar de instance-note. Alleen voor
    // instances die in deze run zelf zijn aangemaakt; daarna staat de
    // kopie los van de master-note (geen sync, geen koppeling).
    //
    // Kleine hardening binnen dezelfde run: we doen maximaal één directe
    // retry met een korte backoff voor de note-kopie. Lukt die dan nog
    // niet, dan wordt de id apart geregistreerd als note-copy failure
    // (los van expense-create failures) en loopt de run gewoon door.
    if (masterNote != null) {
      final noteRef = expenseRef.collection('privateNotes').doc(uid);
      final notePayload = <String, dynamic>{
        'note': masterNote,
        'updatedAt': FieldValue.serverTimestamp(),
        if (masterSharedWithUids.isNotEmpty)
          'sharedWithUids': masterSharedWithUids,
      };

      var noteCopied = false;
      Object? lastNoteError;
      for (var attempt = 1; attempt <= 2; attempt++) {
        try {
          await noteRef.set(notePayload);
          noteCopied = true;
          break;
        } catch (e) {
          lastNoteError = e;
          if (kDebugMode) {
            debugPrint(
              'Recurring materialize: copy note ${plan.expenseId} '
              'attempt $attempt failed: '
              '${mapUserFacingError(e, fallback: e.toString())}',
            );
          }
          if (attempt < 2) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }
      }

      if (noteCopied) {
        copiedNote.add(plan.expenseId);
      } else {
        failedNoteCopy.add(plan.expenseId);
        if (kDebugMode && lastNoteError != null) {
          debugPrint(
            'Recurring materialize: copy note ${plan.expenseId} '
            'gave up after retry.',
          );
        }
      }
    }
  }

  return _RecurringMaterializationResult(
    createdExpenseIds: List<String>.unmodifiable(created),
    skippedExpenseIds: List<String>.unmodifiable(skipped),
    failedExpenseIds: List<String>.unmodifiable(failed),
    copiedNoteExpenseIds: List<String>.unmodifiable(copiedNote),
    failedNoteCopyExpenseIds: List<String>.unmodifiable(failedNoteCopy),
  );
}

// ────────────────────────────────────────────────────────────────────────────
// Centrale recurring-materialisatie-runner
//
// Eén plek die bepaalt wanneer `_materializeRecurringMasterOnce` echt live
// draait. Gekoppeld aan:
//  * cold start (post-frame callback in KiDuApp),
//  * app resume (WidgetsBindingObserver.didChangeAppLifecycleState),
//  * direct na succesvolle save van een nieuwe recurring master met
//    startdatum == vandaag (in _AddRecurringExpenseDialog).
//
// Dedup/serialisatie: zolang een run onderweg is hergebruiken we dezelfde
// Future, en een korte _cooldown voorkomt dat twee triggers vlak na elkaar
// (bv. resume + post-frame, of save + resume) meteen opnieuw werk doen.
// De runner zelf toont geen UI: geen snackbar, geen loading, geen badge.
// ────────────────────────────────────────────────────────────────────────────
class _RecurringMaterializationRunner {
  static Future<void>? _inFlight;
  static DateTime? _lastRunAt;

  /// Kleine dedup-venster voor snel opeenvolgende triggers.
  static const Duration _cooldown = Duration(seconds: 2);

  /// Draait één materialisatie-ronde voor de huidige ingelogde maker.
  /// Meerdere gelijktijdige aanroepen delen dezelfde onderliggende Future.
  static Future<void> run() {
    final existing = _inFlight;
    if (existing != null) return existing;

    final last = _lastRunAt;
    if (last != null && DateTime.now().difference(last) < _cooldown) {
      return Future<void>.value();
    }

    final future = _runOnce();
    _inFlight = future;
    return future.whenComplete(() {
      _inFlight = null;
      _lastRunAt = DateTime.now();
    });
  }

  static Future<void> _runOnce() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final uid = user.uid;
    final firestore = FirebaseFirestore.instance;

    String householdId = '';
    try {
      final userSnap = await firestore.doc('users/$uid').get();
      householdId = ((userSnap.data()?['householdId'] as String?) ?? '').trim();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Recurring runner: read user doc failed: $e');
      }
      return;
    }
    if (householdId.isEmpty) return;

    // Smal gescoped op maker + active. De creator-only en status-check
    // zitten óók hard in `_materializeRecurringMasterOnce`; deze where()
    // voorkomt dat we masters van de co-parent onnodig binnenhalen.
    QuerySnapshot<Map<String, dynamic>> masters;
    try {
      masters = await firestore
          .collection('households/$householdId/recurringExpenses')
          .where('createdBy', isEqualTo: uid)
          .where('status', isEqualTo: 'active')
          .get();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Recurring runner: read masters failed: $e');
      }
      return;
    }

    final now = DateTime.now();

    for (final doc in masters.docs) {
      final data = doc.data();
      final startTs = data['startDate'];
      if (startTs is! Timestamp) continue;
      final rawStart = startTs.toDate();
      final startDate = DateTime(rawStart.year, rawStart.month, rawStart.day);

      // Interne floor voor pause/hervat- en latere datumwijzigings-semantiek.
      // Backward compatibility: legacy masters zonder dit veld (of met een
      // onverwacht type) vallen terug op `startDate`, wat de bestaande
      // gedragscurve exact reproduceert.
      final materializeFromTs = data['materializeFromDate'];
      final DateTime materializeFromDate;
      if (materializeFromTs is Timestamp) {
        final rawFloor = materializeFromTs.toDate();
        materializeFromDate = DateTime(
          rawFloor.year,
          rawFloor.month,
          rawFloor.day,
        );
      } else {
        materializeFromDate = startDate;
      }

      // Nieuwe semantiek voor de dag-van-de-maand: `dueDayOfMonth` is de
      // bron, met fallback naar `startDate.day` voor legacy masters die dit
      // veld nog niet kennen. Out-of-range waarden worden naar een veilig
      // bereik geclamped zodat de pure helper niets hoeft te raden.
      final dueDayRaw = data['dueDayOfMonth'];
      int dueDayOfMonth;
      if (dueDayRaw is int) {
        dueDayOfMonth = dueDayRaw;
      } else if (dueDayRaw is num) {
        dueDayOfMonth = dueDayRaw.toInt();
      } else {
        dueDayOfMonth = startDate.day;
      }
      if (dueDayOfMonth < 1) dueDayOfMonth = 1;
      if (dueDayOfMonth > 31) dueDayOfMonth = 31;

      final title = (data['title'] as String?)?.trim() ?? '';
      final amountCents = (data['amountCents'] as num?)?.toInt() ?? 0;
      final currency = ((data['currency'] as String?) ?? 'EUR').trim();
      final childIdsRaw = data['childIds'];
      final childIds = childIdsRaw is List
          ? childIdsRaw.whereType<String>().toList(growable: false)
          : const <String>[];
      final status = ((data['status'] as String?) ?? '').trim();
      final createdBy = ((data['createdBy'] as String?) ?? '').trim();

      // Tweede verdediging: maker-only en active-only. De where() hierboven
      // dekt dit al, maar we vertrouwen nooit blind op query-resultaten.
      if (createdBy != uid) continue;
      if (status != 'active') continue;

      ParentSplitSnapshot? parentSplitSnapshot = _tryReadRecurringParentSplit(
        data,
      );
      if (parentSplitSnapshot == null) {
        try {
          parentSplitSnapshot = await _legacyRecurringParentSplitFallback(
            householdId,
          );
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Recurring runner: split fallback failed: $e');
          }
        }
      }

      final master = _RecurringMasterInput(
        masterId: doc.id,
        title: title,
        amountCents: amountCents,
        currency: currency,
        childIds: childIds,
        startDate: startDate,
        dueDayOfMonth: dueDayOfMonth,
        materializeFromDate: materializeFromDate,
        status: status,
        createdBy: createdBy,
        parentSplitSnapshot: parentSplitSnapshot,
      );

      try {
        await _materializeRecurringMasterOnce(
          householdId: householdId,
          uid: uid,
          master: master,
          now: now,
        );
      } catch (e) {
        // Per-master fouten mogen de rest van de run niet stuk maken.
        if (kDebugMode) {
          debugPrint('Recurring runner: materialize ${doc.id} failed: $e');
        }
      }
    }
  }
}

class _TerugkerendeKostenPage extends StatefulWidget {
  const _TerugkerendeKostenPage({
    required this.householdId,
    required this.isCoParentLinked,
    this.otherParentName,
    this.myParentName,
  });

  final String householdId;

  /// Zelfde semantiek als dashboard [canAddExpenses]: tweede ouder in het
  /// huishouden is zichtbaar (`otherUid`).
  final bool isCoParentLinked;
  final String? otherParentName;

  /// Echte naam van de huidige gebruiker; gebruikt door de lijstregel om
  /// in plaats van `Jij` dezelfde soort naamweergave als de co-parent te
  /// tonen (transparantie/consistentie).
  final String? myParentName;

  @override
  State<_TerugkerendeKostenPage> createState() =>
      _TerugkerendeKostenPageState();
}

class _TerugkerendeKostenPageState extends State<_TerugkerendeKostenPage> {
  bool _hasMultipleHouseholdChildDocs = true;

  @override
  void initState() {
    super.initState();
    _loadHouseholdChildDocCount();
  }

  Future<void> _loadHouseholdChildDocCount() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('households/${widget.householdId}/children')
          .limit(2)
          .get();
      if (!mounted) return;
      setState(() {
        _hasMultipleHouseholdChildDocs = snap.docs.length >= 2;
      });
    } catch (_) {
      // Safe default: keep showChildContext true.
    }
  }

  Future<void> _openAddRecurringDialog() async {
    // Gelijkgetrokken met de 'Nieuwe uitgave'-flow op het dashboard
    // (regel 4188-4217): zonder actieve kinderen opent de dialog niet,
    // en verschijnt dezelfde tijdelijke snackbar met actie 'Kinderen' die
    // naar _KinderenPage navigeert.
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final householdId = widget.householdId;
    bool hasActiveChildren = false;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('households/$householdId/children')
          .get();
      hasActiveChildren = snap.docs.any(
        (d) => d.data()['isArchived'] != true && d.data()['isDeleted'] != true,
      );
    } catch (_) {
      hasActiveChildren = false;
    }
    if (!mounted) return;
    if (!hasActiveChildren) {
      messenger.hideCurrentSnackBar();
      // Flutter negeert de duration op een SnackBar met SnackBarAction zodra
      // MediaQuery.accessibleNavigation actief is; we sluiten dezelfde
      // snackbar daarom gericht via de opgevangen controller na exact 4 s.
      // close() op een reeds gedismiste/vervangen snackbar is een no-op.
      final noChildrenSnackBarController = messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: const Text('Voeg eerst een kind toe.'),
          action: SnackBarAction(
            label: 'Kinderen',
            onPressed: () => nav.push(
              MaterialPageRoute<void>(
                builder: (_) => _KinderenPage(householdId: householdId),
              ),
            ),
          ),
        ),
      );
      unawaited(
        Future<void>.delayed(
          const Duration(seconds: 5),
          noChildrenSnackBarController.close,
        ),
      );
      return;
    }
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AddRecurringExpenseDialog(householdId: householdId),
    );
    if (!mounted) return;
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    if (!widget.isCoParentLinked) {
      return Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          centerTitle: true,
          title: Text(
            'Maandelijkse uitgaven',
            style: textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
              child: Text(
                'Beschikbaar na koppelen',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      // Voorkom dat deze achtergrondpagina herlayoutet bij keyboard-open
      // (gebeurt wanneer de _AddRecurringExpenseDialog hierboven opent).
      // Zonder dit kan de lijst/card achter de dialog overflowen en een
      // gele/zwarte overflow-strip tonen door de modal heen.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          'Maandelijkse uitgaven',
          style: textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Uitleg over maandelijkse uitgaven',
            icon: const Icon(Icons.info_outline, size: 20),
            onPressed: () => _showMonthlyExpensesInfoSheet(context),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(right: 8, bottom: 16),
        child: FloatingActionButton(
          heroTag: 'add_recurring_fab',
          onPressed: _openAddRecurringDialog,
          child: const Icon(Icons.add, size: 24),
        ),
      ),
      body: SafeArea(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('households/${widget.householdId}/recurringExpenses')
              .orderBy('createdAt', descending: true)
              .snapshots(),
          builder: (context, snap) {
            final docs = snap.data?.docs ?? const [];
            final hasData = snap.hasData;

            if (!hasData) {
              return Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Laden…',
                      style: textTheme.bodySmall?.copyWith(
                        color: onSurface(context, a55),
                      ),
                    ),
                  ],
                ),
              );
            }

            if (docs.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Nog geen maandelijkse uitgaven',
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(
                      color: onSurface(context, a62),
                    ),
                  ),
                ),
              );
            }

            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 96),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: KiduCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: _RecurringMasterList(
                      householdId: widget.householdId,
                      docs: docs,
                      otherParentName: widget.otherParentName,
                      myParentName: widget.myParentName,
                      showChildContext: _hasMultipleHouseholdChildDocs,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Recurring-master list (v1)
//
// Calm, read-only rendering of existing recurring masters. Intentionally
// minimal: title, amount, start-date and status only. Rows are now tappable
// and push to a read-only [_RecurringMasterDetailPage] — no edit/pause
// affordance is rendered here (or on detail) in this step.
// ────────────────────────────────────────────────────────────────────────────

class _RecurringMasterList extends StatelessWidget {
  const _RecurringMasterList({
    required this.householdId,
    required this.docs,
    this.otherParentName,
    this.myParentName,
    this.showChildContext = true,
  });

  final String householdId;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  final String? otherParentName;

  /// Echte naam van de huidige gebruiker, zodat de lijstregel voor een
  /// door 'mij' aangemaakte recurring dezelfde naamweergave toont als
  /// voor de co-parent (geen `Jij`).
  final String? myParentName;
  final bool showChildContext;

  // Ritme afgeleid van Logboek > Uitgaven (_LogboekPageState._logboekListRow*):
  // rij = 64, separator = 14. Vaste viewport voor exact 9 volledige rijen:
  //   9 * 64 + 8 * 14 = 688. Een eventueel 10e item start pas op 702 en valt
  // dus volledig buiten de viewport — geen halve rij onderaan. Bewust 1 rij
  // lager dan daarvoor zodat de floating +-knop rechtsonder visueel vrij
  // staat en niet optisch tegen de laatste rij / card aan zit.
  static const double _rowExtent = 64;
  static const double _separatorExtent = 14;
  static const int _visibleRowCount = 9;
  static const double _cardListHeight =
      (_visibleRowCount * _rowExtent) +
      ((_visibleRowCount - 1) * _separatorExtent);

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return SizedBox(
      height: _cardListHeight,
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: docs.length,
        separatorBuilder: (context, _) =>
            Divider(height: _separatorExtent, color: outlineV(context, a40)),
        itemBuilder: (context, i) => _buildRow(
          context,
          textTheme,
          docs[i],
          otherParentName,
          myParentName,
          showChildContext,
        ),
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    TextTheme textTheme,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    String? otherParentName,
    String? myParentName,
    bool showChildContext,
  ) {
    final data = doc.data();
    final title = (data['title'] as String?)?.trim() ?? '—';
    final amountCents = (data['amountCents'] is int)
        ? data['amountCents'] as int
        : 0;
    final startTs = data['startDate'];
    final startDate = startTs is Timestamp ? startTs.toDate() : null;
    final status = data['status'] as String?;
    final isPaused = status == 'paused';
    final createdBy = ((data['createdBy'] as String?) ?? '').trim();
    final childIds =
        (data['childIds'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    final parentLabel = _recurringParentLabel(
      createdByUid: createdBy,
      currentUid: FirebaseAuth.instance.currentUser?.uid,
      otherParentName: otherParentName,
      myParentName: myParentName,
    );
    // Nieuwe semantiek: actieve masters tonen de eerstvolgende concrete
    // vervaldatum (pure display-afleiding uit `dueDayOfMonth` +
    // `materializeFromDate`, met dezelfde clamp als de runner).
    // Gepauzeerde masters tonen bewust géén dag/datum — alleen oudernaam
    // en het dot-puntje verraadt de pauze-status.
    final dueDayRaw = data['dueDayOfMonth'];
    int? dueDay;
    if (dueDayRaw is int) {
      dueDay = dueDayRaw;
    } else if (dueDayRaw is num) {
      dueDay = dueDayRaw.toInt();
    }
    final matFromTs = data['materializeFromDate'];
    final materializeFromDate = matFromTs is Timestamp
        ? matFromTs.toDate()
        : null;
    // Voor actieve masters is de eerstvolgende concrete vervaldatum
    // afhankelijk van welke periodes al zijn gematerialiseerd. Zonder
    // die context zou `Volgende op …` op de dag van materialisatie nog
    // steeds vandaag tonen terwijl de echte expense-instance van vandaag
    // al bestaat. We wrappen de subtitle daarom in een smalle per-master
    // stream op `expenses where recurringExpenseId == doc.id` en skippen
    // in de helper de al bestaande periodKeys. Gepauzeerde masters
    // tonen alleen de oudernaam (geen datum, geen stream).
    final Widget subtitleWidget = isPaused
        ? Text(
            parentLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: onSurface(context, a68)),
          )
        : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('households/$householdId/expenses')
                .where('recurringExpenseId', isEqualTo: doc.id)
                .snapshots(),
            builder: (context, exSnap) {
              final periodKeys = <String>{};
              if (exSnap.hasData) {
                for (final d in exSnap.data!.docs) {
                  final pk = d.data()['periodKey'];
                  if (pk is String && pk.isNotEmpty) {
                    periodKeys.add(pk);
                  }
                }
              }
              final nextDue = _recurringNextConcreteDueDate(
                status: status,
                dueDayOfMonth: dueDay,
                startDate: startDate,
                materializeFromDate: materializeFromDate,
                now: DateTime.now(),
                existingPeriodKeys: periodKeys,
              );
              final text = nextDue != null
                  ? '$parentLabel · Volgende op ${_formatRecurringShortDateNl(nextDue)}'
                  : parentLabel;
              return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
            },
          );
    final statusDotColor = _recurringStatusDotColor(status);

    final cs = Theme.of(context).colorScheme;

    return SizedBox(
      height: _rowExtent,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          highlightColor: cs.primary.withValues(alpha: 0.10),
          splashColor: cs.primary.withValues(alpha: 0.08),
          onTap: () async {
            final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
            final navigator = Navigator.of(context);
            // Los de kindnamen op vóór navigatie zodat de Voor-regel op het
            // detailscherm direct stabiel renderen (geen late pop-in).
            // Firestore serveert deze doc-gets normaliter uit de offline
            // cache, dus dit kost geen merkbare tap-vertraging.
            final preloadedNames = childIds.isEmpty
                ? const <String>[]
                : await _ExpenseDetailPage._resolveChildNames(
                    householdId,
                    childIds,
                  );
            if (!navigator.mounted) return;
            navigator.push(
              MaterialPageRoute<void>(
                builder: (_) => _RecurringMasterDetailPage(
                  householdId: householdId,
                  masterId: doc.id,
                  uid: uid,
                  createdByUid: createdBy,
                  title: title,
                  amountCents: amountCents,
                  childIds: childIds,
                  startDate: startDate,
                  status: status,
                  preloadedChildNames: preloadedNames,
                  otherParentName: otherParentName,
                  myParentName: myParentName,
                  showChildContext: showChildContext,
                ),
              ),
            );
          },
          // Gepauzeerde rows ogen subtiel minder actief dan actieve rows.
          // In lijn met `Logboek > Wijzigingen` (_buildWijzigingTrailing):
          // we dempen niet meer via een hele-row Opacity, maar via een
          // rustigere tekstkleur op titel, subtitle en bedrag — dezelfde
          // `onSurface(context, a68)`-familie. Tapbaarheid, layout en
          // spacing blijven identiek; alleen de kleurtoon valt rustig weg.
          child: ListTile(
            key: ValueKey(doc.id),
            contentPadding: const EdgeInsets.symmetric(horizontal: 5),
            dense: true,
            minTileHeight: _rowExtent,
            minVerticalPadding: 0,
            visualDensity: VisualDensity.compact,
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: isPaused
                  ? TextStyle(color: onSurface(context, a68))
                  : null,
            ),
            subtitle: subtitleWidget,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Statuspuntje — groen bij actief, amber/oranje bij gepauzeerd.
                // 2× groter dan de eerdere micro-dot voor duidelijke herkenning,
                // met een subtiele ring in de card-border-familie zodat het
                // rustig blijft en niet als badge overkomt.
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusDotColor,
                    border: Border.all(color: outlineV(context, a40), width: 1),
                  ),
                ),
                const SizedBox(width: 10),
                // Vaste breedte houdt het puntje over meerdere rijen onder
                // elkaar uitgelijnd. Iets ruimer gedimensioneerd dan voorheen
                // zodat alledaagse recurring bedragen (€100,00, €124,00,
                // €1.000,00 …) volledig renderen zonder ellipsis; de bredere
                // amount-box schuift het puntje tegelijk iets naar links,
                // wat de trailing cluster rustiger laat lezen.
                SizedBox(
                  width: 88,
                  child: Text(
                    _formatRecurringEurCents(amountCents),
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isPaused ? onSurface(context, a68) : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Recurring-master detail page
//
// Master fields follow Firestore live (zoals [_ExpenseDetailPage]). Creator-only:
// private note, plus [Uitgave bewerken] met dezelfde dialog-UX als een normale
// uitgave (titel/bedrag/kinderen; reden alleen bij bedragwijziging). Geen
// pause/status/start-edit in deze stap.
// ────────────────────────────────────────────────────────────────────────────

class _RecurringMasterDetailPage extends StatefulWidget {
  const _RecurringMasterDetailPage({
    required this.householdId,
    required this.masterId,
    required this.uid,
    required this.createdByUid,
    required this.title,
    required this.amountCents,
    required this.childIds,
    required this.startDate,
    required this.status,
    this.preloadedChildNames,
    this.otherParentName,
    this.myParentName,
    this.showChildContext = true,
  });

  final String householdId;
  final String masterId;
  final String uid;
  final String createdByUid;
  final String title;
  final int amountCents;
  final List<String> childIds;
  final DateTime? startDate;
  final String? status;

  /// When false, hide the read-only "Voor" row (single-child households).
  final bool showChildContext;

  /// Zelfde rol als bij [_ExpenseDetailPage.otherParentName] voor het
  /// wijzigingslabel (`Jij` / co-parent); optioneel zolang er geen route meegeeft.
  final String? otherParentName;

  /// Echte naam van de huidige gebruiker; gebruikt als stabiele fallback voor
  /// de parent-split regel voordat async membernamen binnen zijn.
  final String? myParentName;

  /// Names vooraf opgelost door de lijstrij (analoog aan hoe het dashboard
  /// dit aan [_ExpenseDetailPage] doorgeeft). Als dit niet-null is, tonen
  /// de kindnamen direct op frame 1 zonder zichtbare pop-in.
  final List<String>? preloadedChildNames;

  @override
  State<_RecurringMasterDetailPage> createState() =>
      _RecurringMasterDetailPageState();
}

class _RecurringMasterDetailPageState
    extends State<_RecurringMasterDetailPage> {
  bool _noteActionBusy = false;
  bool _pauseActionBusy = false;
  bool _deleteActionBusy = false;
  late final Future<List<_ParentSplitMember>> _parentSplitMembersFuture;
  late final Future<List<_ChildItem>> _recurringMasterEditChildrenFuture;
  List<String> _memoChildIdsForNames = const [];
  Future<List<String>>? _memoChildNamesFuture;

  // Last-known stable snapshot data for the stream-driven sections of the
  // detail. These are updated on every healthy rebuild while the page is
  // idle, and read-only during a delete. This is the "freeze" that keeps
  // the screen visually calm while we tear down changes / privateNotes /
  // master: the live streams keep firing (and will briefly emit empty or
  // error snapshots as docs disappear), but the builders render from the
  // cache so the user does not see the note section regress to an empty
  // state or the history list collapse under their finger.
  Map<String, dynamic>? _lastMasterData;
  List<QueryDocumentSnapshot<Map<String, dynamic>>>? _lastChangesDocs;
  Map<String, dynamic>? _lastNoteData;
  bool _hasNoteCache = false;

  @override
  void initState() {
    super.initState();
    _parentSplitMembersFuture = _loadParentSplitMembers(widget.householdId);
    _recurringMasterEditChildrenFuture = _loadRecurringMasterEditChildren(
      widget.householdId,
    );
  }

  Future<List<String>> _childNamesFutureFor(List<String> childIds) {
    if (_memoChildNamesFuture != null &&
        _memoChildIdsForNames.length == childIds.length &&
        _memoChildIdsForNames.toSet().containsAll(childIds) &&
        childIds.toSet().containsAll(_memoChildIdsForNames)) {
      return _memoChildNamesFuture!;
    }
    _memoChildIdsForNames = List<String>.from(childIds);
    _memoChildNamesFuture = _ExpenseDetailPage._resolveChildNames(
      widget.householdId,
      _memoChildIdsForNames,
    );
    return _memoChildNamesFuture!;
  }

  void _showRecurringSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showRecurringManageSheet(BuildContext context, String? status) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: theme.colorScheme.surface,
      builder: (sheetContext) {
        final sheetTheme = Theme.of(sheetContext);
        final textTheme = sheetTheme.textTheme;
        final isPaused = status == 'paused';
        final pauseResumeLabel = isPaused ? 'Hervatten' : 'Pauzeren';
        final pauseResumeIcon = isPaused
            ? Icons.play_arrow_outlined
            : Icons.pause_outlined;
        final softError = sheetTheme.colorScheme.error.withValues(alpha: 0.70);

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: !_pauseActionBusy,
                  leading: Icon(
                    pauseResumeIcon,
                    size: 22,
                    color: onSurface(sheetContext, a45),
                  ),
                  title: Text(
                    pauseResumeLabel,
                    style: textTheme.bodyMedium?.copyWith(
                      color: onSurface(sheetContext, a84),
                    ),
                  ),
                  onTap: !_pauseActionBusy
                      ? () {
                          Navigator.of(sheetContext).pop();
                          _onTogglePauseResumePressed(
                            currentStatus: status ?? 'active',
                          );
                        }
                      : null,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: !_deleteActionBusy,
                  leading: Icon(
                    Icons.delete_outline,
                    size: 22,
                    color: softError,
                  ),
                  title: Text(
                    'Verwijderen',
                    style: textTheme.bodyMedium?.copyWith(color: softError),
                  ),
                  onTap: !_deleteActionBusy
                      ? () {
                          Navigator.of(sheetContext).pop();
                          _onDeletePressed();
                        }
                      : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openEditRecurringDialog({
    required int currentAmountCents,
    required String currentTitle,
    required List<String> currentChildIds,
    required int currentDueDayOfMonth,
    required ParentSplitSnapshot? currentParentSplitSnapshot,
  }) async {
    if (!await _checkCanWriteNow()) {
      if (mounted) {
        _showRecurringSnackBar('Je bent offline, probeer het later opnieuw');
      }
      return;
    }
    if (!mounted) return;
    List<_ChildItem>? preload;
    try {
      preload = await _recurringMasterEditChildrenFuture;
    } catch (_) {
      preload = null;
    }
    if (!mounted) return;
    await showDialog<bool>(
      context: context,
      useSafeArea: true,
      barrierDismissible: false,
      builder: (context) => Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  final keyboardVisible =
                      MediaQuery.of(context).viewInsets.bottom > 0;
                  if (keyboardVisible) {
                    FocusManager.instance.primaryFocus?.unfocus();
                    return;
                  }
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                },
                child: const SizedBox.expand(),
              ),
            ),
            GestureDetector(
              onTap: () {},
              child: _EditRecurringMasterExpenseDialog(
                householdId: widget.householdId,
                masterId: widget.masterId,
                currentAmountCents: currentAmountCents,
                currentTitle: currentTitle,
                currentChildIds: currentChildIds,
                currentDueDayOfMonth: currentDueDayOfMonth,
                currentParentSplitSnapshot: currentParentSplitSnapshot,
                parentSplitMembersFuture: _parentSplitMembersFuture,
                childrenFuture: preload != null
                    ? Future<List<_ChildItem>>.value(
                        List<_ChildItem>.from(preload),
                      )
                    : _recurringMasterEditChildrenFuture,
                initialChildren: preload,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Creator-only pauze/hervat op de recurring master.
  ///
  /// Semantiek (v1):
  ///  * `paused`  → status wordt `paused`, `materializeFromDate` blijft staan
  ///  * `active`  → status wordt `active`, `materializeFromDate` =
  ///                `max(vandaag 00:00 lokaal, bestaande floor)` zodat maanden
  ///                tijdens pauze niet alsnog worden ingehaald (geen backfill)
  ///                én een bij bewerken gezette toekomstige floor niet onder
  ///                vandaag wordt getrokken (Firestore: floor ≥ startDate).
  ///
  /// Na een hervatten triggeren we dezelfde centrale runner opnieuw, zodat de
  /// huidige maand direct materialiseert als die due is en nog ontbreekt.
  /// Geen status-history en geen redenplicht in deze stap.
  Future<void> _onTogglePauseResumePressed({
    required String currentStatus,
  }) async {
    if (_pauseActionBusy) return;
    if (!await _checkCanWriteNow()) {
      if (mounted) {
        _showRecurringSnackBar('Je bent offline, probeer het later opnieuw');
      }
      return;
    }
    if (!mounted) return;
    final willPause = currentStatus != 'paused';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: kiduActionDialogTitle(
          ctx,
          willPause
              ? 'Maandelijkse uitgave pauzeren?'
              : 'Maandelijkse uitgave hervatten?',
        ),
        content: Text(
          willPause
              ? 'Zolang deze maandelijkse uitgave gepauzeerd is, maakt KiDu geen nieuwe uitgave aan. Eerder aangemaakte uitgaven blijven staan.'
              : 'Vanaf vandaag maakt KiDu weer elke maand een gewone uitgave aan. Maanden die tijdens de pauze voorbij zijn, worden niet alsnog aangemaakt.',
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuleren'),
          ),
          FilledButton(
            style: kiduDialogPrimaryButtonStyle(ctx),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(willPause ? 'Pauzeren' : 'Hervatten'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _pauseActionBusy = true);
    try {
      final masterRef = FirebaseFirestore.instance.doc(
        'households/${widget.householdId}/recurringExpenses/${widget.masterId}',
      );
      final update = <String, dynamic>{
        'status': willPause ? 'paused' : 'active',
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (!willPause) {
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        DateTime resumeMaterializeFrom = today;
        try {
          final snap = await masterRef.get(
            const GetOptions(source: Source.server),
          );
          final data = snap.data();
          if (data != null) {
            DateTime floorDay;
            final matTs = data['materializeFromDate'];
            final startTs = data['startDate'];
            if (matTs is Timestamp) {
              final raw = matTs.toDate();
              floorDay = DateTime(raw.year, raw.month, raw.day);
            } else if (startTs is Timestamp) {
              final raw = startTs.toDate();
              floorDay = DateTime(raw.year, raw.month, raw.day);
            } else {
              floorDay = today;
            }
            resumeMaterializeFrom = today.isBefore(floorDay) ? floorDay : today;
          }
        } catch (_) {
          resumeMaterializeFrom = today;
        }
        update['materializeFromDate'] = Timestamp.fromDate(
          resumeMaterializeFrom,
        );
      }
      await masterRef.update(update);
      if (!willPause) {
        // Dezelfde centrale runner; geen tweede materialisatie-implementatie.
        unawaited(_RecurringMaterializationRunner.run());
      }
    } catch (e) {
      if (!mounted) return;
      _showRecurringSnackBar(
        mapUserFacingError(e, fallback: 'Opslaan mislukt. Probeer opnieuw.'),
      );
    } finally {
      if (mounted) {
        setState(() => _pauseActionBusy = false);
      }
    }
  }

  /// Creator-only hard delete of the recurring master.
  ///
  /// Semantics (v1):
  ///  * stops only the future monthly materializations
  ///  * already-materialized expenses are intentionally left untouched
  ///  * no soft delete, no reason, no status-history
  ///
  /// Cleanup order matters because the privateNotes and changes rules rely
  /// on `isRecurringMasterCreator` which resolves against the master doc:
  ///   1) delete all `changes` docs
  ///   2) delete all `privateNotes` docs (iterate household members — the
  ///      creator is allowed to clear any uid-slot under this master so no
  ///      co-parent notes are left as orphans)
  ///   3) delete the master doc itself (last)
  Future<void> _onDeletePressed() async {
    if (_deleteActionBusy) return;
    if (!await _checkCanWriteNow()) {
      if (mounted) {
        _showRecurringSnackBar('Je bent offline, probeer het later opnieuw');
      }
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: kiduActionDialogTitle(ctx, 'Maandelijkse uitgave verwijderen?'),
        content: const Text(
          'Toekomstige maandelijkse uitgaven stoppen. '
          'Eerder aangemaakte uitgaven blijven bewaard.',
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuleren'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error
                  .withValues(alpha: 0.85),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Verwijderen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Flip the busy flag before the first Firestore delete. From this point
    // on the stream-driven subsections of build() render from their cached
    // snapshot instead of whatever the live streams emit, so co-parent
    // deletions of changes/privateNotes/master are not visible as jank.
    setState(() => _deleteActionBusy = true);
    final navigator = Navigator.of(context);
    try {
      final firestore = FirebaseFirestore.instance;
      final masterRef = firestore.doc(
        'households/${widget.householdId}/recurringExpenses/${widget.masterId}',
      );

      // 1) changes
      final changesSnap = await masterRef.collection('changes').get();
      for (final d in changesSnap.docs) {
        await d.reference.delete();
      }

      // 2) privateNotes — iterate household members so we also clean up
      // any uid-slots written by co-parents. Delete of a non-existent doc
      // is a safe no-op in Firestore when the rule permits it.
      final membersSnap = await firestore
          .collection('households/${widget.householdId}/members')
          .get();
      for (final m in membersSnap.docs) {
        try {
          await masterRef.collection('privateNotes').doc(m.id).delete();
        } catch (_) {
          // Silently ignore: slot may not exist or a transient perm hiccup
          // on a single slot should not block the master delete. The master
          // delete below is the authoritative failure surface.
        }
      }

      // 3) master (last, so the rules above still resolve)
      await masterRef.delete();

      if (!mounted) return;
      navigator.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleteActionBusy = false);
      _showRecurringSnackBar(
        mapUserFacingError(
          e,
          fallback: 'Verwijderen mislukt. Probeer opnieuw.',
        ),
      );
      return;
    }
    if (mounted) {
      setState(() => _deleteActionBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final isCreator =
        widget.uid.isNotEmpty && widget.uid == widget.createdByUid.trim();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .doc(
            'households/${widget.householdId}/recurringExpenses/${widget.masterId}',
          )
          .snapshots(),
      builder: (context, masterSnap) {
        // While idle, keep refreshing the cache from the live
        // stream. While a delete is in flight we ignore whatever
        // the stream emits (it will go empty when the master doc
        // is removed in step 3) and keep rendering on the last
        // healthy snapshot so the layout does not collapse.
        final liveData = masterSnap.data?.data();
        if (!_deleteActionBusy && liveData != null) {
          _lastMasterData = liveData;
        }
        final data = _deleteActionBusy
            ? (_lastMasterData ?? liveData)
            : (liveData ?? _lastMasterData);
        final title = ((data?['title'] as String?) ?? widget.title).trim();
        final amountCents =
            (data?['amountCents'] as num?)?.toInt() ?? widget.amountCents;
        final childIds =
            (data?['childIds'] as List?)?.whereType<String>().toList() ??
            widget.childIds;
        var startDate = widget.startDate;
        final startRaw = data?['startDate'];
        if (startRaw is Timestamp) {
          startDate = startRaw.toDate();
        }
        final status = (data?['status'] as String?) ?? widget.status;
        // Nieuwe semantiek: de vervaldag is de primaire datumwaarde.
        // `Gestart` volgt de eerste concrete of geplande uitgave; zie expenses-
        // stream in deze build voor de exacte afleiding.
        //
        // Primair lezen we `dueDayOfMonth`; voor legacy masters
        // zonder dit veld vallen we terug op `startDate.day`, zodat
        // deze stap geen regressie oplevert voor bestaande masters.
        final dueDayRaw = data?['dueDayOfMonth'];
        int? dueDay;
        if (dueDayRaw is int) {
          dueDay = dueDayRaw;
        } else if (dueDayRaw is num) {
          dueDay = dueDayRaw.toInt();
        } else {
          dueDay = startDate?.day;
        }
        if (dueDay != null) {
          if (dueDay < 1) dueDay = 1;
          if (dueDay > 31) dueDay = 31;
        }
        final dueDayLabel = dueDay != null ? '${dueDay}e van de maand' : '—';
        final showShortMonthHint = dueDay != null && dueDay > 28;
        final statusLabel = _formatRecurringStatusLabel(status);

        // Eerstvolgende concrete vervaldatum: pure display-afleiding,
        // `null` bij gepauzeerd of onvoldoende data. Gebruikt dezelfde
        // clamp-regel als de runner (29/30/31 → laatste dag in korte
        // maanden) en respecteert `materializeFromDate` als floor.
        // `existingPeriodKeys` wordt hieronder via een smalle stream
        // op de master-gerelateerde expense-instances aangeleverd
        // zodat de rij mee-schuift zodra de huidige periode is
        // gematerialiseerd.
        final matFromRaw = data?['materializeFromDate'];
        final materializeFromDate = matFromRaw is Timestamp
            ? matFromRaw.toDate()
            : null;
        final parentSplitSnapshot = _tryReadRecurringParentSplit(data);

        return Scaffold(
          appBar: AppBar(
            centerTitle: true,
            title: Text(
              'Maandelijkse uitgave',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
            actions: [
              if (isCreator)
                IconButton(
                  tooltip: 'Beheer',
                  iconSize: 20,
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => _showRecurringManageSheet(context, status),
                ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title.isEmpty ? widget.title : title,
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _formatRecurringEurCents(amountCents),
                          style: textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    FutureBuilder<List<_ParentSplitMember>>(
                      future: _parentSplitMembersFuture,
                      builder: (context, splitSnap) {
                        final members =
                            splitSnap.data ?? const <_ParentSplitMember>[];
                        final effectiveSplit =
                            parentSplitSnapshot ??
                            _neutralParentSplitForMembers(members);
                        if (effectiveSplit == null) {
                          return const SizedBox.shrink();
                        }
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _formatParentSplitNamed(
                              effectiveSplit,
                              members,
                              widget.uid,
                              myParentName: widget.myParentName,
                              otherParentName: widget.otherParentName,
                            ),
                            style: textTheme.bodyMedium,
                          ),
                        );
                      },
                    ),
                    if (widget.showChildContext && childIds.isNotEmpty)
                      FutureBuilder<List<String>>(
                        future: _childNamesFutureFor(childIds),
                        initialData:
                            _listsEqualForMemo(childIds, widget.childIds)
                            ? widget.preloadedChildNames
                            : null,
                        builder: (context, snap) {
                          if (!snap.hasData) return const SizedBox.shrink();
                          final names = snap.data!;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              'Voor',
                              style: textTheme.bodySmall?.copyWith(
                                color: onSurface(context, a70),
                              ),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                _ExpenseDetailPage._formatChildNamesInline(
                                  names,
                                ),
                                style: textTheme.bodyMedium,
                              ),
                            ),
                          );
                        },
                      ),
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection(
                            'households/${widget.householdId}/recurringExpenses/${widget.masterId}/changes',
                          )
                          .orderBy('editedAt', descending: true)
                          .snapshots(),
                      builder: (context, histSnap) {
                        // Mirror the master-doc freeze: update the cache
                        // while idle, render the last healthy list while
                        // deleting. Without this the section silently
                        // empties out one doc at a time during cleanup.
                        List<QueryDocumentSnapshot<Map<String, dynamic>>>
                        histDocs;
                        if (_deleteActionBusy) {
                          histDocs =
                              _lastChangesDocs ??
                              (histSnap.hasData && !histSnap.hasError
                                  ? histSnap.data!.docs
                                  : const []);
                        } else {
                          if (histSnap.hasError || !histSnap.hasData) {
                            return const SizedBox.shrink();
                          }
                          histDocs = histSnap.data!.docs;
                          _lastChangesDocs = histDocs;
                        }
                        if (histDocs.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        String editorLabel(String? editedByUid) {
                          final e = editedByUid?.trim() ?? '';
                          if (e.isEmpty) return 'Co-parent';
                          if (e == widget.uid) return 'Jij';
                          final o = widget.otherParentName?.trim();
                          if (o != null && o.isNotEmpty) return o;
                          return 'Co-parent';
                        }

                        return Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Wijzigingsgeschiedenis',
                                style: textTheme.bodySmall?.copyWith(
                                  color: onSurface(context, a70),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 10),
                              ...histDocs.map((doc) {
                                final h = doc.data();
                                final fromC =
                                    (h['fromAmountCents'] as num?)?.toInt() ??
                                    0;
                                final toC =
                                    (h['toAmountCents'] as num?)?.toInt() ?? 0;
                                final reason =
                                    (h['reason'] as String?)?.trim() ?? '';
                                final editedBy = (h['editedBy'] as String?)
                                    ?.trim();
                                final editedAtRaw = h['editedAt'];
                                DateTime? editedAtDt;
                                if (editedAtRaw is Timestamp) {
                                  editedAtDt = editedAtRaw.toDate().toLocal();
                                }
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${_ExpenseDetailPage._formatEur(fromC)} → ${_ExpenseDetailPage._formatEur(toC)} · ${editorLabel(editedBy)} · ${_ExpenseDetailPage._formatDateTime(editedAtDt)}',
                                        style: textTheme.bodySmall?.copyWith(
                                          color: onSurface(context, a68),
                                          height: 1.35,
                                        ),
                                      ),
                                      if (reason.isNotEmpty) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          reason,
                                          style: textTheme.bodyMedium?.copyWith(
                                            height: 1.35,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              }),
                            ],
                          ),
                        );
                      },
                    ),
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection(
                            'households/${widget.householdId}/expenses',
                          )
                          .where(
                            'recurringExpenseId',
                            isEqualTo: widget.masterId,
                          )
                          .snapshots(),
                      builder: (context, exSnap) {
                        final periodKeys = <String>{};
                        if (exSnap.hasData) {
                          for (final d in exSnap.data!.docs) {
                            final pk = d.data()['periodKey'];
                            if (pk is String && pk.isNotEmpty) {
                              periodKeys.add(pk);
                            }
                          }
                        }
                        final nextDue = _recurringNextConcreteDueDate(
                          status: status,
                          dueDayOfMonth: dueDay,
                          startDate: startDate,
                          materializeFromDate: materializeFromDate,
                          now: DateTime.now(),
                          existingPeriodKeys: periodKeys,
                        );
                        DateTime? minCreatedAmongExpenses;
                        if (exSnap.hasData) {
                          for (final doc in exSnap.data!.docs) {
                            final raw = doc.data()['createdAt'];
                            if (raw is Timestamp) {
                              final t = raw.toDate();
                              if (minCreatedAmongExpenses == null ||
                                  t.isBefore(minCreatedAmongExpenses)) {
                                minCreatedAmongExpenses = t;
                              }
                            }
                          }
                        }
                        final String gestartSubtitle;
                        if (exSnap.hasError) {
                          final d = materializeFromDate ?? startDate;
                          gestartSubtitle = d != null
                              ? _formatRecurringStartDateNl(d)
                              : '—';
                        } else if (!exSnap.hasData) {
                          gestartSubtitle = '—';
                        } else {
                          final basis =
                              minCreatedAmongExpenses ??
                              materializeFromDate ??
                              startDate;
                          gestartSubtitle = basis != null
                              ? _formatRecurringStartDateNl(basis)
                              : '—';
                        }
                        final labelMuted = textTheme.bodySmall?.copyWith(
                          color: onSurface(context, a70),
                        );
                        final vervaldagTile = ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('Vervaldag', style: labelMuted),
                          subtitle: Text(dueDayLabel),
                        );
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: vervaldagTile),
                                if (nextDue != null)
                                  Expanded(
                                    child: ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(
                                        'Volgende uitgave',
                                        style: labelMuted,
                                      ),
                                      subtitle: Text(
                                        _formatRecurringStartDateNl(nextDue),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            if (showShortMonthHint)
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 2,
                                  bottom: 4,
                                ),
                                child: Text(
                                  'In kortere maanden geldt de laatste dag van de maand.',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: onSurface(context, a55),
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text('Start', style: labelMuted),
                                    subtitle: Text(gestartSubtitle),
                                  ),
                                ),
                                Expanded(
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text('Status', style: labelMuted),
                                    subtitle: Text(statusLabel),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
                    if (isCreator) ...[
                      const SizedBox(height: 12),
                      StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                        stream: FirebaseFirestore.instance
                            .doc(
                              'households/${widget.householdId}/recurringExpenses/${widget.masterId}/privateNotes/${_ExpenseDetailPage._privateNotesDocUid(widget.createdByUid)}',
                            )
                            .snapshots(),
                        builder: (context, snap) {
                          if (snap.hasError) {
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  'Kon notitie niet laden.',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: onSurface(context, a55),
                                    height: 1.35,
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: FilledButton.tonalIcon(
                                    onPressed: _noteActionBusy
                                        ? null
                                        : () async {
                                            if (_noteActionBusy) return;
                                            setState(
                                              () => _noteActionBusy = true,
                                            );
                                            try {
                                              await _doManageRecurringMasterPrivateNote(
                                                context,
                                                householdId: widget.householdId,
                                                masterId: widget.masterId,
                                                uid: widget.uid,
                                              );
                                            } finally {
                                              if (mounted) {
                                                setState(
                                                  () => _noteActionBusy = false,
                                                );
                                              }
                                            }
                                          },
                                    icon: const Icon(
                                      Icons.note_add_outlined,
                                      size: 18,
                                    ),
                                    label: Text(
                                      'Notitie',
                                      style: textTheme.bodyMedium,
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: FilledButton.tonalIcon(
                                    onPressed: () => _openEditRecurringDialog(
                                      currentAmountCents: amountCents,
                                      currentTitle: title.isEmpty
                                          ? widget.title
                                          : title,
                                      currentChildIds: childIds,
                                      currentDueDayOfMonth:
                                          dueDay ?? (startDate?.day ?? 1),
                                      currentParentSplitSnapshot:
                                          parentSplitSnapshot,
                                    ),
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 18,
                                    ),
                                    label: Text(
                                      'Uitgave',
                                      style: textTheme.bodyMedium,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          }
                          // Freeze the note section on its last healthy
                          // data during delete: the privateNotes doc gets
                          // removed in step 2 and would otherwise flash to
                          // an empty state right under the user's thumb.
                          // We cache both the raw data and the "has-snapshot"
                          // bit so the first frame after delete confirmation
                          // never regresses.
                          if (!_deleteActionBusy && snap.hasData) {
                            _lastNoteData = snap.data?.data();
                            _hasNoteCache = true;
                          }
                          final Map<String, dynamic>? nd = _deleteActionBusy
                              ? (_hasNoteCache
                                    ? _lastNoteData
                                    : snap.data?.data())
                              : snap.data?.data();
                          final note = (nd?['note'] as String?)?.trim() ?? '';
                          final hasNoteLive = note.isNotEmpty;
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (hasNoteLive)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    'Notitie',
                                    style: textTheme.bodySmall?.copyWith(
                                      color: onSurface(context, a70),
                                    ),
                                  ),
                                  subtitle: Text(note),
                                ),
                              Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: FilledButton.tonalIcon(
                                        onPressed: _noteActionBusy
                                            ? null
                                            : () async {
                                                if (_noteActionBusy) return;
                                                setState(
                                                  () => _noteActionBusy = true,
                                                );
                                                try {
                                                  await _doManageRecurringMasterPrivateNote(
                                                    context,
                                                    householdId:
                                                        widget.householdId,
                                                    masterId: widget.masterId,
                                                    uid: widget.uid,
                                                  );
                                                } finally {
                                                  if (mounted) {
                                                    setState(
                                                      () => _noteActionBusy =
                                                          false,
                                                    );
                                                  }
                                                }
                                              },
                                        icon: Icon(
                                          hasNoteLive
                                              ? Icons.edit_note
                                              : Icons.note_add_outlined,
                                          size: 18,
                                        ),
                                        label: Text(
                                          hasNoteLive ? 'Notitie' : 'Notitie',
                                          style: textTheme.bodyMedium,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: FilledButton.tonalIcon(
                                        onPressed: () =>
                                            _openEditRecurringDialog(
                                              currentAmountCents: amountCents,
                                              currentTitle: title.isEmpty
                                                  ? widget.title
                                                  : title,
                                              currentChildIds: childIds,
                                              currentDueDayOfMonth:
                                                  dueDay ??
                                                  (startDate?.day ?? 1),
                                              currentParentSplitSnapshot:
                                                  parentSplitSnapshot,
                                            ),
                                        icon: const Icon(
                                          Icons.edit_outlined,
                                          size: 18,
                                        ),
                                        label: Text(
                                          'Uitgave',
                                          style: textTheme.bodyMedium,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                    if (!isCreator) ...[
                      const SizedBox(height: 12),
                      StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                        stream: FirebaseFirestore.instance
                            .doc(
                              'households/${widget.householdId}/recurringExpenses/${widget.masterId}/privateNotes/${_ExpenseDetailPage._privateNotesDocUid(widget.createdByUid)}',
                            )
                            .snapshots(),
                        builder: (context, noteSnap) {
                          if (noteSnap.hasError) {
                            return const SizedBox.shrink();
                          }
                          final nd = noteSnap.data?.data();
                          final note = (nd?['note'] as String?)?.trim() ?? '';
                          if (!_ExpenseDetailPage._privateNoteIsSharedWithViewer(
                                nd,
                                widget.uid,
                              ) ||
                              note.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              'Gedeelde notitie',
                              style: textTheme.bodySmall?.copyWith(
                                color: onSurface(context, a70),
                              ),
                            ),
                            subtitle: Text(note),
                          );
                        },
                      ),
                      Text(
                        'Alleen de maker kan deze maandelijkse uitgave bewerken of pauzeren.',
                        style: textTheme.bodySmall?.copyWith(
                          color: onSurface(context, a55),
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  bool _listsEqualForMemo(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    return a.toSet().containsAll(b);
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Add-recurring-expense dialog
//
// Top-level StatefulWidget that mirrors the field rhythm and validation feel
// of "Nieuwe uitgave" without reaching into _DashboardPageState. Owns its own
// controllers/focus nodes via initState/dispose so they outlive the dialog's
// dismiss animation. Recurring cadence is fixed to monthly in v1, so no
// frequency chooser is rendered; the start-date slot is kept compact so the
// form stays slim on mobile.
// ────────────────────────────────────────────────────────────────────────────

class _AddRecurringExpenseDialog extends StatefulWidget {
  const _AddRecurringExpenseDialog({required this.householdId});

  final String householdId;

  @override
  State<_AddRecurringExpenseDialog> createState() =>
      _AddRecurringExpenseDialogState();
}

class _AddRecurringExpenseDialogState
    extends State<_AddRecurringExpenseDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _amountController;
  late final TextEditingController _noteController;
  late final FocusNode _titleFocusNode;
  late final FocusNode _amountFocusNode;

  bool _titleHasError = false;
  bool _amountHasError = false;
  bool _childSelectionHasError = false;
  bool _startDateHasError = false;

  bool _loadingChildren = true;
  bool _loadingParentSplit = true;
  List<_ChildItem> _children = const [];
  List<_ParentSplitMember> _parentSplitMembers = const [];
  ParentSplitSnapshot? _parentSplitSnapshot;
  bool _parentSplitHasError = false;
  bool _hasCustomChildSelection = false;
  List<String> _customSelectedChildIds = const [];

  late DateTime _startDate;

  bool _saving = false;
  bool _sharePrivateNoteWithCoParent = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _amountController = TextEditingController();
    _noteController = TextEditingController();
    _titleFocusNode = FocusNode();
    _amountFocusNode = FocusNode();
    final now = DateTime.now();
    _startDate = DateTime(now.year, now.month, now.day);
    _loadChildren();
    _loadParentSplit();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _amountController.dispose();
    _noteController.dispose();
    _titleFocusNode.dispose();
    _amountFocusNode.dispose();
    super.dispose();
  }

  /// Loads active children for the household. Kept local to this flow so the
  /// recurring form does not depend on _DashboardPageState helpers.
  Future<void> _loadChildren() async {
    final householdId = widget.householdId.trim();
    if (householdId.isEmpty) {
      if (mounted) setState(() => _loadingChildren = false);
      return;
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('households/$householdId/children')
          .get();
      final docs =
          snap.docs
              .where(
                (d) =>
                    d.data()['isArchived'] != true &&
                    d.data()['isDeleted'] != true,
              )
              .toList()
            ..sort((a, b) {
              final aTs = a.data()['createdAt'];
              final bTs = b.data()['createdAt'];
              if (aTs is Timestamp && bTs is Timestamp) {
                return aTs.compareTo(bTs);
              }
              return 0;
            });
      if (!mounted) return;
      setState(() {
        _children = docs
            .map(
              (d) => _ChildItem(
                id: d.id,
                name: (d.data()['name'] as String?)?.trim() ?? '?',
              ),
            )
            .toList();
        _loadingChildren = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingChildren = false);
    }
  }

  Future<void> _loadParentSplit() async {
    final householdId = widget.householdId.trim();
    if (householdId.isEmpty) {
      if (mounted) {
        setState(() {
          _loadingParentSplit = false;
          _parentSplitHasError = true;
          _sharePrivateNoteWithCoParent = false;
        });
      }
      return;
    }
    try {
      final members = await _loadParentSplitMembers(householdId);
      final memberUids = members.map((m) => m.uid).toSet();
      final defaults = await HouseholdSplitSettingsRepository().load(
        householdId,
      );
      final snapshot = buildSnapshotForNewExpense(
        defaults: defaults,
        currentMemberUids: memberUids,
      );
      if (!mounted) return;
      final myUid = FirebaseAuth.instance.currentUser?.uid.trim();
      String? singleOtherParentUid;
      if (myUid != null && myUid.isNotEmpty) {
        final others = members
            .map((m) => m.uid.trim())
            .where((id) => id.isNotEmpty && id != myUid)
            .toSet()
            .toList(growable: false);
        if (others.length == 1) singleOtherParentUid = others.single;
      }
      setState(() {
        _parentSplitMembers = members;
        _parentSplitSnapshot = snapshot;
        _parentSplitHasError = snapshot == null;
        _loadingParentSplit = false;
        if (singleOtherParentUid == null && _sharePrivateNoteWithCoParent) {
          _sharePrivateNoteWithCoParent = false;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _parentSplitHasError = true;
        _loadingParentSplit = false;
        _sharePrivateNoteWithCoParent = false;
      });
    }
  }

  /// Sole other household parent for share targeting, else `null` (ambiguous).
  String? _eligibleCoParentUidForPrivateNoteShare() {
    final myUid = FirebaseAuth.instance.currentUser?.uid.trim();
    if (myUid == null || myUid.isEmpty) return null;
    final others = _parentSplitMembers
        .map((m) => m.uid.trim())
        .where((id) => id.isNotEmpty && id != myUid)
        .toSet()
        .toList(growable: false);
    if (others.length != 1) return null;
    return others.single;
  }

  List<String> get _effectiveSelectedChildIds {
    if (_children.isEmpty) return const [];
    if (_hasCustomChildSelection) return _customSelectedChildIds;
    return _children.map((c) => c.id).toList(growable: false);
  }

  String get _childSelectionSummary {
    if (!_hasCustomChildSelection ||
        _customSelectedChildIds.length == _children.length) {
      return 'Alle kinderen';
    }
    return '${_customSelectedChildIds.length} van ${_children.length} geselecteerd';
  }

  Future<void> _pickStartDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // v1 staat geen startdatum in het verleden toe; zowel de picker-grens
    // als de initial-datum worden daarom geclamped naar vandaag.
    final safeInitial = _startDate.isBefore(today) ? today : _startDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: safeInitial,
      firstDate: today,
      lastDate: DateTime(now.year + 5),
      helpText: 'Startdatum',
      cancelText: 'Annuleren',
      confirmText: 'Kiezen',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _startDate = DateTime(picked.year, picked.month, picked.day);
      _startDateHasError = false;
    });
  }

  Future<void> _pickChildren() async {
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (_) => _RecurringChildSelectionDialog(
        children: _children,
        initialSelectedChildIds: _hasCustomChildSelection
            ? _customSelectedChildIds
            : const [],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (picked.length == _children.length) {
        _hasCustomChildSelection = false;
        _customSelectedChildIds = const [];
      } else {
        _hasCustomChildSelection = true;
        _customSelectedChildIds = picked;
      }
      if (picked.isNotEmpty) _childSelectionHasError = false;
    });
  }

  Future<void> _pickParentSplit() async {
    final snapshot = _parentSplitSnapshot;
    if (snapshot == null ||
        _parentSplitMembers.length != kParentSplitParticipantCount) {
      return;
    }
    final picked = await showDialog<ParentSplitSnapshot>(
      context: context,
      builder: (_) => _RecurringParentSplitDialog(
        members: _parentSplitMembers,
        initialSnapshot: snapshot,
        viewerUid: FirebaseAuth.instance.currentUser?.uid,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _parentSplitSnapshot = picked;
      _parentSplitHasError = false;
    });
  }

  Future<void> _onSavePressed() async {
    if (_saving) return;

    final title = _titleController.text.trim();
    final amountCents = _tryParseRecurringEurToCents(_amountController.text);
    final selectedChildIds = _effectiveSelectedChildIds;
    final parentSplitSnapshot = _parentSplitSnapshot;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final titleInvalid = title.isEmpty;
    final amountInvalid = amountCents == null || amountCents <= 0;
    final childSelectionInvalid = selectedChildIds.isEmpty;
    final parentSplitInvalid = parentSplitSnapshot == null;
    // Tweede verdediging: ook als een oude datum via omweg in _startDate
    // belandt mag er geen write plaatsvinden. Vandaag en toekomst blijven ok.
    final startDateInvalid = _startDate.isBefore(today);

    if (titleInvalid ||
        amountInvalid ||
        childSelectionInvalid ||
        parentSplitInvalid ||
        startDateInvalid) {
      setState(() {
        _titleHasError = titleInvalid;
        _amountHasError = amountInvalid;
        _childSelectionHasError = childSelectionInvalid;
        _parentSplitHasError = parentSplitInvalid;
        _startDateHasError = startDateInvalid;
      });
      if (titleInvalid) {
        _titleFocusNode.requestFocus();
      } else if (amountInvalid) {
        _amountFocusNode.requestFocus();
      }
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    final householdId = widget.householdId.trim();
    if (uid == null || householdId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Opslaan mislukt. Probeer opnieuw.')),
      );
      return;
    }

    setState(() => _saving = true);

    // Online-gate: recurring masters mogen bewust geen pending/offline create
    // worden. Hergebruikt hetzelfde patroon als elders in de app, zodat de
    // tone-of-voice voor de gebruiker consistent blijft.
    if (!await _checkCanWriteNow()) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Je bent offline, probeer het later opnieuw'),
        ),
      );
      return;
    }

    final noteTrimmed = _noteController.text.trim();

    try {
      final firestore = FirebaseFirestore.instance;
      final masterRef = firestore
          .collection('households/$householdId/recurringExpenses')
          .doc();
      final batch = firestore.batch();
      batch.set(masterRef, <String, dynamic>{
        'title': title,
        'amountCents': amountCents,
        'currency': 'EUR',
        'childIds': selectedChildIds,
        'startDate': Timestamp.fromDate(_startDate),
        // Terugkerende vervaldag van de maand. Bij create hard gekoppeld aan
        // de dagcomponent van `startDate`; daarmee reproduceert de helper
        // voor nieuwe masters exact het oude gedrag en staat het veld klaar
        // om later los van `startDate` bewerkt te worden.
        'dueDayOfMonth': _startDate.day,
        'cadence': 'monthly',
        'status': 'active',
        // Interne datumgrens voor de latere pause/hervat-runner. Bij create
        // hard gekoppeld aan `startDate`; rules dwingen exacte gelijkheid af.
        // Gedrag van runner en helper blijft in deze stap volledig ongewijzigd.
        'materializeFromDate': Timestamp.fromDate(_startDate),
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': uid,
        'updatedAt': FieldValue.serverTimestamp(),
        ..._recurringParentSplitFields(parentSplitSnapshot),
      });
      if (noteTrimmed.isNotEmpty) {
        final noteRef = masterRef.collection('privateNotes').doc(uid);
        final notePayload = <String, dynamic>{
          'note': noteTrimmed,
          'updatedAt': FieldValue.serverTimestamp(),
        };
        final shareUid = _eligibleCoParentUidForPrivateNoteShare();
        if (_sharePrivateNoteWithCoParent && shareUid != null) {
          notePayload['sharedWithUids'] = [shareUid];
        }
        batch.set(noteRef, notePayload);
      }
      await batch.commit();
      // Harde server-ack: dwing een server-round-trip af op de net
      // aangemaakte master. Als de verbinding tussen precheck en commit
      // is weggevallen, zit de write nog in de lokale pending queue en
      // zal deze read falen — dan behandelen we save expliciet als niet
      // gelukt en laten we de dialog open.
      await masterRef
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 6));
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Geen verbinding met server. Probeer opnieuw.'),
        ),
      );
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final msg = mapUserFacingError(
        e,
        fallback: 'Opslaan mislukt. Probeer opnieuw.',
      );
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      return;
    }

    if (!mounted) return;
    // Als de startdatum vandaag is, moet de periode-van-nu niet pas bij
    // een volgende lifecycle-trigger materialiseren. Dezelfde centrale
    // runner wordt hergebruikt; geen aparte tweede materialisatielogica.
    // Dedup in de runner vangt samenloop met cold-start/resume netjes op.
    if (_startDate.year == today.year &&
        _startDate.month == today.month &&
        _startDate.day == today.day) {
      unawaited(_RecurringMaterializationRunner.run());
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final subtleErrorHintStyle = textTheme.bodySmall?.copyWith(
      color: cs.error.withValues(alpha: 0.85),
      fontSize: 12,
      fontWeight: FontWeight.w400,
    );
    final subtleErrorInputStyle = textTheme.bodyLarge?.copyWith(
      color: cs.error.withValues(alpha: 0.88),
      fontWeight: FontWeight.w400,
    );

    final showChildSelectionRow = !_loadingChildren && _children.length > 1;
    // Geen 'geen kinderen'-tak meer nodig: de recurring add-dialog opent
    // alleen wanneer _openAddRecurringDialog al heeft vastgesteld dat er
    // actieve kinderen zijn (consistent met 'Nieuwe uitgave'-flow).
    final parentSplitSummary = _parentSplitSnapshot == null
        ? (_loadingParentSplit ? 'Laden…' : 'Niet beschikbaar')
        : _formatParentSplitCompact(
            _parentSplitSnapshot!,
            FirebaseAuth.instance.currentUser?.uid,
          );

    // Title-anchored width. Cap sits between the old narrow (420) and the
    // too-wide (480) attempts so "Maandelijkse uitgave" still fits with calm
    // side-margins while the meta-zone doesn't read as uitgesmeerd.
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogContentW = (screenW - 80.0).clamp(280.0, 320.0);

    // Labels stay regular; values pick up a touch more weight for scanability.
    final metaLabelStyle = textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w400,
      color: onSurface(context, a84),
    );
    final metaValueStyle = textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w500,
      color: onSurface(context, a84),
    );
    final metaActionStyle = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      title: kiduActionDialogTitle(context, 'Maandelijkse uitgave'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: SizedBox(
          width: dialogContentW,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                TextField(
                  controller: _titleController,
                  focusNode: _titleFocusNode,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.next,
                  maxLength: _kRecurringTitleMaxLength,
                  onTap: () {
                    if (_titleHasError) {
                      setState(() => _titleHasError = false);
                    }
                  },
                  onChanged: (_) {
                    if (_titleHasError) {
                      setState(() => _titleHasError = false);
                    }
                  },
                  buildCounter:
                      (
                        context, {
                        required int currentLength,
                        required bool isFocused,
                        required int? maxLength,
                      }) => null,
                  decoration: kiduCompactInputDecoration(
                    labelText: 'Titel',
                    hintText: _titleHasError ? 'Vul een titel in' : null,
                  ).copyWith(
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    border: const OutlineInputBorder(),
                    hintStyle: _titleHasError ? subtleErrorHintStyle : null,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _amountController,
                  focusNode: _amountFocusNode,
                  style: _amountHasError ? subtleErrorInputStyle : null,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onTap: () {
                    if (_amountHasError) {
                      setState(() => _amountHasError = false);
                    }
                  },
                  onChanged: (value) {
                    final trimmed = value.trim();
                    final parsed = _tryParseRecurringEurToCents(value);
                    final nextHasError =
                        trimmed.isNotEmpty && (parsed == null || parsed < 0);
                    if (_amountHasError != nextHasError) {
                      setState(() => _amountHasError = nextHasError);
                    }
                  },
                  decoration: kiduCompactInputDecoration(
                    labelText: 'Bedrag (EUR)',
                    hintText: _amountHasError
                        ? 'Vul een geldig bedrag in'
                        : 'Bijv. 12,34',
                  ).copyWith(
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    border: const OutlineInputBorder(),
                    hintStyle: _amountHasError ? subtleErrorHintStyle : null,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _noteController,
                  textCapitalization: TextCapitalization.sentences,
                  maxLength: 180,
                  textInputAction: TextInputAction.next,
                  onChanged: (text) {
                    if (text.trim().isEmpty && _sharePrivateNoteWithCoParent) {
                      setState(() => _sharePrivateNoteWithCoParent = false);
                    } else {
                      setState(() {});
                    }
                  },
                  buildCounter:
                      (
                        context, {
                        required int currentLength,
                        required bool isFocused,
                        required int? maxLength,
                      }) => null,
                  decoration: kiduCompactInputDecoration(
                    labelText: 'Notitie (optioneel)',
                  ).copyWith(
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    border: const OutlineInputBorder(),
                  ),
                ),
                if (!_loadingParentSplit)
                  Builder(
                    builder: (ctx) {
                      final coParent =
                          _eligibleCoParentUidForPrivateNoteShare();
                      if (coParent == null) {
                        return const SizedBox.shrink();
                      }
                      final noteEmpty = _noteController.text.trim().isEmpty;
                      return SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Notitie delen',
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                        value: _sharePrivateNoteWithCoParent && !noteEmpty,
                        onChanged: noteEmpty
                            ? null
                            : (v) => setState(
                                () => _sharePrivateNoteWithCoParent = v,
                              ),
                      );
                    },
                  ),
                const SizedBox(height: 16),
                // Start row — label + value ride together as one text group
                // via Text.rich; Expanded drops all remaining flex space
                // between the group and the right-aligned action.
                Row(
                  children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: 'Start: ', style: metaLabelStyle),
                            TextSpan(
                              text: _formatRecurringStartDateNl(_startDate),
                              style: metaValueStyle?.copyWith(
                                color: _startDateHasError
                                    ? cs.error.withValues(alpha: 0.85)
                                    : metaValueStyle.color,
                              ),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: _pickStartDate,
                      style: metaActionStyle,
                      child: const Text('Wijzigen'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (_loadingChildren)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Text('Voor: ', style: metaLabelStyle),
                        const SizedBox(
                          height: 14,
                          width: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.6),
                        ),
                      ],
                    ),
                  )
                else if (showChildSelectionRow)
                  Row(
                    children: [
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: 'Voor: ', style: metaLabelStyle),
                              TextSpan(
                                text: _childSelectionSummary,
                                style: metaValueStyle?.copyWith(
                                  color: _childSelectionHasError
                                      ? cs.error.withValues(alpha: 0.85)
                                      : metaValueStyle.color,
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: _pickChildren,
                        style: metaActionStyle,
                        child: const Text('Selectie'),
                      ),
                    ],
                  ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: 'Verdeling: ',
                              style: metaLabelStyle,
                            ),
                            TextSpan(
                              text: parentSplitSummary,
                              style: metaValueStyle?.copyWith(
                                color: _parentSplitHasError
                                    ? cs.error.withValues(alpha: 0.85)
                                    : metaValueStyle.color,
                              ),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed:
                          (_loadingParentSplit || _parentSplitSnapshot == null)
                          ? null
                          : _pickParentSplit,
                      style: metaActionStyle,
                      child: const Text('Wijzigen'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Annuleren'),
        ),
        FilledButton(
          style: kiduDialogPrimaryButtonStyle(context),
          onPressed: (_loadingChildren || _loadingParentSplit || _saving)
              ? null
              : _onSavePressed,
          child: _saving
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context)
                            .colorScheme
                            .onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('Opslaan'),
                  ],
                )
              : const Text('Opslaan'),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Recurring child-selection dialog
//
// Local sibling of the dashboard's own child-selection dialog; layout matches
// _openAddExpenseChildSelectionDialog (only _DashboardPageState._cardRadius shared).
// ────────────────────────────────────────────────────────────────────────────

class _RecurringChildSelectionDialog extends StatefulWidget {
  const _RecurringChildSelectionDialog({
    required this.children,
    this.initialSelectedChildIds = const [],
  });

  final List<_ChildItem> children;
  final List<String> initialSelectedChildIds;

  @override
  State<_RecurringChildSelectionDialog> createState() =>
      _RecurringChildSelectionDialogState();
}

class _RecurringChildSelectionDialogState
    extends State<_RecurringChildSelectionDialog> {
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    final allIds = widget.children.map((c) => c.id).toSet();
    final initial = widget.initialSelectedChildIds
        .where(allIds.contains)
        .toSet();
    _selected = initial.isEmpty ? allIds : initial;
  }

  @override
  Widget build(BuildContext context) {
    final allChildIds = widget.children
        .map((c) => c.id)
        .toList(growable: false);
    final allCount = widget.children.length;
    final selectedCount = _selected.length;
    final allSelected = selectedCount == allCount;
    final cs = Theme.of(context).colorScheme;
    final dialogBackground = cs.surfaceContainerHigh;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = (screenW - 80.0).clamp(280.0, 420.0);
    final modalHeight = min(520.0, MediaQuery.of(context).size.height - 36);
    void dismissSelectionDialog() => Navigator.of(context).pop();

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: SafeArea(
        child: Align(
          alignment: const Alignment(0, -0.08),
          child: SizedBox(
            width: dialogW,
            child: SizedBox(
              height: modalHeight,
              child: Material(
                color: dialogBackground,
                elevation: 3,
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(
                  _DashboardPageState._cardRadius,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(
                      _DashboardPageState._cardRadius,
                    ),
                    border: Border.all(color: outlineV(context, a40)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Center(
                          child: Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: cs.outlineVariant.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        child: kiduActionDialogTitle(context, 'Kinderen selecteren'),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TextButton(
                                onPressed: () => setState(() {
                                  _selected = allSelected
                                      ? <String>{}
                                      : allChildIds.toSet();
                                }),
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: Text(
                                  allSelected
                                      ? 'Alle deselecteren'
                                      : 'Alle selecteren',
                                ),
                              ),
                              const SizedBox(height: 6),
                              SizedBox(
                                height: 28,
                                child: Align(
                                  alignment: Alignment.topLeft,
                                  child: Opacity(
                                    opacity: _selected.isEmpty ? 1 : 0,
                                    child: Text(
                                      'Selecteer minimaal 1 kind om verder te gaan',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: onSurface(context, a68),
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: ListView.separated(
                                  padding: const EdgeInsets.only(
                                    top: 2,
                                    bottom: 4,
                                  ),
                                  itemCount: widget.children.length,
                                  separatorBuilder: (_, _) => Divider(
                                    height: 1,
                                    thickness: 0.4,
                                    color: cs.outlineVariant.withValues(
                                      alpha: 0.45,
                                    ),
                                  ),
                                  itemBuilder: (context, index) {
                                    final child = widget.children[index];
                                    final selected = _selected.contains(
                                      child.id,
                                    );
                                    return Material(
                                      type: MaterialType.transparency,
                                      borderRadius: BorderRadius.circular(8),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(8),
                                        onTap: () {
                                          setState(() {
                                            if (selected) {
                                              _selected = _selected
                                                  .where((id) => id != child.id)
                                                  .toSet();
                                            } else {
                                              _selected = {
                                                ..._selected,
                                                child.id,
                                              };
                                            }
                                          });
                                        },
                                        child: ListTile(
                                          dense: true,
                                          visualDensity: VisualDensity.compact,
                                          minLeadingWidth: 32,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                horizontal: 2,
                                                vertical: 0,
                                              ),
                                          leading: Checkbox(
                                            value: selected,
                                            visualDensity:
                                                VisualDensity.compact,
                                            activeColor: cs.primary.withValues(
                                              alpha: a84,
                                            ),
                                            checkColor: cs.surface,
                                            side: BorderSide(
                                              color: cs.outlineVariant
                                                  .withValues(alpha: 0.85),
                                            ),
                                            onChanged: (value) {
                                              setState(() {
                                                if (value ?? false) {
                                                  _selected = {
                                                    ..._selected,
                                                    child.id,
                                                  };
                                                } else {
                                                  _selected = _selected
                                                      .where(
                                                        (id) => id != child.id,
                                                      )
                                                      .toSet();
                                                }
                                              });
                                            },
                                          ),
                                          title: Text(
                                            child.name,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(
                                                  color: onSurface(
                                                    context,
                                                    a84,
                                                  ),
                                                ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: dialogBackground,
                          border: Border(
                            top: BorderSide(color: outlineV(context, a32)),
                          ),
                        ),
                        child: SafeArea(
                          top: false,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                            child: Row(
                              children: [
                                TextButton(
                                  onPressed: dismissSelectionDialog,
                                  child: const Text('Annuleren'),
                                ),
                                const Spacer(),
                                FilledButton(
                                  style: kiduDialogPrimaryButtonStyle(context),
                                  onPressed: _selected.isEmpty
                                      ? null
                                      : () => Navigator.of(
                                          context,
                                        ).pop(_selected.toList()),
                                  child: const Text('Opslaan'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Add-child dialog
//
// Owns its TextEditingController via initState/dispose so the controller is
// always torn down by Flutter's widget lifecycle, never while EditableText is
// still mounted during the dialog's dismiss animation or IME hide.
// ────────────────────────────────────────────────────────────────────────────

class _AddChildDialog extends StatefulWidget {
  const _AddChildDialog({required this.activeNormalised});

  final List<String> activeNormalised;

  @override
  State<_AddChildDialog> createState() => _AddChildDialogState();
}

class _AddChildDialogState extends State<_AddChildDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _controller.text.trim();
    final isDuplicate =
        text.isNotEmpty && widget.activeNormalised.contains(text.toLowerCase());
    final canAdd = text.isNotEmpty && !isDuplicate;

    return AlertDialog(
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      title: kiduActionDialogTitle(context, 'Kind toevoegen'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) {
          if (canAdd) Navigator.of(context).pop(_controller.text.trim());
        },
        decoration: kiduCompactInputDecoration(
          labelText: 'Naam',
          helperText: isDuplicate ? 'Naam bestaat al' : null,
        ).copyWith(
          floatingLabelBehavior: FloatingLabelBehavior.always,
          border: const OutlineInputBorder(),
          helperStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.error.withValues(alpha: 0.85),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuleren'),
        ),
        FilledButton(
          style: kiduDialogPrimaryButtonStyle(context),
          onPressed: canAdd
              ? () => Navigator.of(context).pop(_controller.text.trim())
              : null,
          child: const Text('Toevoegen'),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Rename-child dialog
//
// Owns its TextEditingController so Flutter disposes it as part of the normal
// widget lifecycle — never while EditableText is still mounted during the
// dialog's dismiss animation or IME hide.
// ────────────────────────────────────────────────────────────────────────────

class _RenameChildDialog extends StatefulWidget {
  const _RenameChildDialog({
    required this.currentName,
    required this.activeNormalisedExcludingSelf,
  });

  final String currentName;
  final List<String> activeNormalisedExcludingSelf;

  @override
  State<_RenameChildDialog> createState() => _RenameChildDialogState();
}

class _RenameChildDialogState extends State<_RenameChildDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _controller.text.trim();
    final isSame = text == widget.currentName.trim();
    final isDuplicate =
        text.length >= 2 &&
        !isSame &&
        widget.activeNormalisedExcludingSelf.contains(text.toLowerCase());
    final canSave = text.length >= 2 && !isSame && !isDuplicate;

    return AlertDialog(
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      title: kiduActionDialogTitle(context, 'Naam wijzigen'),
      content: TextField(
        controller: _controller,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) {
          if (canSave) Navigator.of(context).pop(_controller.text.trim());
        },
        decoration: kiduCompactInputDecoration(
          labelText: 'Naam',
          errorText: isDuplicate ? 'Naam bestaat al' : null,
        ).copyWith(
          floatingLabelBehavior: FloatingLabelBehavior.always,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuleren'),
        ),
        FilledButton(
          style: kiduDialogPrimaryButtonStyle(context),
          onPressed: canSave
              ? () => Navigator.of(context).pop(_controller.text.trim())
              : null,
          child: const Text('Opslaan'),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────

class KiduCard extends StatelessWidget {
  const KiduCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.backgroundColor,
    this.borderColor,
    this.elevation = 0.4,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? backgroundColor;
  final Color? borderColor;
  final double elevation;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final surface = backgroundColor ?? cs.surface;
    final effectiveBorderColor = borderColor ?? outlineV(context, a55);

    return Material(
      color: surface,
      elevation: elevation,
      borderRadius: BorderRadius.circular(_DashboardPageState._cardRadius),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_DashboardPageState._cardRadius),
          border: Border.all(color: effectiveBorderColor),
        ),
        padding: padding,
        child: child,
      ),
    );
  }
}

/// Width of eight characters in the same style as [KiduCodePill] code text.
double _kiduCodeEightCharWidth(
  TextTheme textTheme, {
  FontWeight fontWeight = FontWeight.w800,
}) {
  final style = textTheme.titleMedium?.copyWith(
    fontWeight: fontWeight,
    letterSpacing: 1.2,
  );
  final tp = TextPainter(
    text: TextSpan(text: 'XXXXXXXX', style: style),
    textDirection: TextDirection.ltr,
  );
  tp.layout();
  return tp.width;
}

class KiduCodePill extends StatelessWidget {
  const KiduCodePill({
    super.key,
    required this.code,
    required this.onCopy,
    this.loading = false,
    this.codeFontWeight = FontWeight.w800,
  });

  final String code;
  final VoidCallback onCopy;
  final bool loading;
  final FontWeight codeFontWeight;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Color.alphaBlend(cs.primary.withValues(alpha: a06), cs.surface),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: outlineV(context, a45)),
      ),
      child: Row(
        children: [
          Expanded(
            child: loading
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: _kiduCodeEightCharWidth(
                        textTheme,
                        fontWeight: codeFontWeight,
                      ),
                      height: 36,
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: cs.primary,
                          ),
                        ),
                      ),
                    ),
                  )
                : SelectableText(
                    code,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: codeFontWeight,
                      letterSpacing: 1.2,
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 36,
            child: OutlinedButton.icon(
              onPressed: () {
                if (loading) return;
                onCopy();
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Kopieer'),
            ),
          ),
        ],
      ),
    );
  }
}

class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _inviteController = TextEditingController();
  bool _joinBusy = false;
  String? _joinInlineHint;

  Future<void> _showJoinSuccessAndClose() async {
    if (!mounted) return;
    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Join success',
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, a1, a2) => const _JoinSuccessOverlay(),
    );

    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;

    // Close overlay, then close setup page.
    Navigator.of(context, rootNavigator: true).pop();
    Navigator.of(context).pop();
  }

  Future<void> _joinHousehold() async {
    if (_joinBusy) {
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return;
    }

    final code = _inviteController.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _joinInlineHint = 'Vul een invite code in.');
      return;
    }

    setState(() {
      _joinBusy = true;
    });

    try {
      final firestore = FirebaseFirestore.instance;
      final inviteRef = firestore.doc('invites/$code');
      final userRef = firestore.doc('users/$uid');

      final inviteSnap = await inviteRef.get();
      if (!inviteSnap.exists) {
        throw StateError('Invite code ongeldig.');
      }

      final inviteData = inviteSnap.data();
      final usedBy = inviteData?['usedBy'];
      if (usedBy != null) {
        throw StateError('Code al gebruikt.');
      }

      final targetHouseholdId = (inviteData?['householdId'] as String?)?.trim();
      if (targetHouseholdId == null || targetHouseholdId.isEmpty) {
        throw StateError('Invite is ongeldig.');
      }

      final userSnap = await userRef.get();
      final userData = userSnap.data();
      final currentHouseholdId = (userData?['householdId'] as String?)?.trim();

      if (targetHouseholdId == currentHouseholdId) {
        throw StateError('Je zit al in dit household.');
      }

      if (currentHouseholdId != null && currentHouseholdId.isNotEmpty) {
        final membersSnap = await firestore
            .collection('households/$currentHouseholdId/members')
            .limit(2)
            .get();
        final expensesSnap = await firestore
            .collection('households/$currentHouseholdId/expenses')
            .limit(1)
            .get();
        if (membersSnap.docs.length != 1 || membersSnap.docs.first.id != uid) {
          throw StateError(
            'Wisselen kan alleen als je huidige household leeg is.',
          );
        }
        if (expensesSnap.docs.isNotEmpty) {
          throw StateError(
            'Wisselen kan alleen als je huidige household leeg is.',
          );
        }
      }

      await firestore.runTransaction((transaction) async {
        final inviteRecheck = await transaction.get(inviteRef);
        if (!inviteRecheck.exists) {
          throw StateError('Invite code ongeldig.');
        }
        if ((inviteRecheck.data()?['usedBy']) != null) {
          throw StateError('Code al gebruikt.');
        }
        final hId = (inviteRecheck.data()?['householdId'] as String?)?.trim();
        if (hId == null || hId.isEmpty) {
          throw StateError('Invite is ongeldig.');
        }

        transaction.set(userRef, {
          'householdId': hId,
          'displayName': FirebaseAuth.instance.currentUser!.displayName,
          'email': FirebaseAuth.instance.currentUser!.email,
          'photoUrl': FirebaseAuth.instance.currentUser!.photoURL,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        final targetMemberRef = firestore.doc('households/$hId/members/$uid');
        transaction.set(targetMemberRef, {
          'role': 'parent',
          'joinedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        transaction.set(inviteRef, {
          'usedBy': uid,
          'usedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        if (currentHouseholdId != null &&
            currentHouseholdId.isNotEmpty &&
            currentHouseholdId != targetHouseholdId) {
          final oldMemberRef = firestore.doc(
            'households/$currentHouseholdId/members/$uid',
          );
          transaction.delete(oldMemberRef);
        }
      });

      // TODO(re-enable after rules alignment): household isConnected update
      // requires allow update on households; temporarily disabled.
      // await firestore.doc('households/$targetHouseholdId').set(
      //   {'isConnected': true},
      //   SetOptions(merge: true),
      // );

      if (mounted) {
        await _showJoinSuccessAndClose();
      }
    } catch (e) {
      final errStr = e.toString();
      if (errStr.contains('Je zit al in dit household')) {
        if (mounted) {
          setState(() {
            _joinInlineHint =
                'Je hoeft deze code niet zelf in te voeren. Deel \'m met je co-parent.';
          });
        }
      } else {
        if (kDebugMode) debugPrint('Join household error: $e');
        if (mounted) {
          setState(() {
            _joinInlineHint =
                'Koppelen lukt nu niet. Controleer de code en probeer opnieuw.';
          });
        }
      }
    } finally {
      if (mounted) {
        setState(() => _joinBusy = false);
      }
    }
  }

  @override
  void dispose() {
    _inviteController.dispose();
    super.dispose();
  }

  /// Unfocus first (esp. IME) so back-gesture and AppBar back match smoother pops.
  void _popSetupPage([Object? result]) {
    FocusScope.of(context).unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _popSetupPage(result);
      },
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          leading: BackButton(onPressed: _popSetupPage),
          title: Text(
            'Koppelen',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: uid == null
              ? KiduCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Niet ingelogd.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: onSurface(context, a68),
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: _popSetupPage,
                        child: Text(
                          'Terug',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: onSurface(context, a70)),
                        ),
                      ),
                    ],
                  ),
                )
              : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .doc('users/$uid')
                      .snapshots(),
                  builder: (context, snapshot) {
                    final data = snapshot.data?.data();
                    final householdId = (data?['householdId'] as String?)
                        ?.trim();
                    final hasHousehold =
                        householdId != null && householdId.isNotEmpty;

                    if (snapshot.hasError) {
                      return KiduCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Kon status niet laden.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: onSurface(context, a68),
                                    height: 1.35,
                                  ),
                            ),
                            const SizedBox(height: 16),
                            TextButton(
                              onPressed: _popSetupPage,
                              child: Text(
                                'Terug',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: onSurface(context, a70)),
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    if (!snapshot.hasData) {
                      return KiduCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Center(
                              child: Padding(
                                padding: EdgeInsets.symmetric(vertical: 24),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: _popSetupPage,
                              child: Text(
                                'Terug',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: onSurface(context, a70)),
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    return KiduCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Voer een invite-code in om te koppelen aan het household van je co-parent.',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: onSurface(context, a62),
                                  height: 1.35,
                                ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _inviteController,
                            textCapitalization: TextCapitalization.characters,
                            onChanged: (_) =>
                                setState(() => _joinInlineHint = null),
                            decoration: kiduCompactInputDecoration(
                              labelText: 'Koppelcode',
                            ).copyWith(
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.always,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          if (_joinInlineHint != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _joinInlineHint!,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: onSurface(context, a62),
                                    height: 1.35,
                                  ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                          const SizedBox(height: 16),
                          FilledButton.tonalIcon(
                            onPressed: _joinBusy ? null : _joinHousehold,
                            icon: Icon(
                              hasHousehold ? Icons.link : Icons.group_add,
                              size: 18,
                            ),
                            label: Text(
                              _joinBusy
                                  ? 'Bezig...'
                                  : (hasHousehold ? 'Verbinden' : 'Koppelen'),
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextButton(
                            onPressed: _popSetupPage,
                            child: Text(
                              'Terug',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: onSurface(context, a70)),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _JoinSuccessOverlay extends StatelessWidget {
  const _JoinSuccessOverlay();

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: const Center(
          child: Icon(
            Icons.check_circle_rounded,
            size: 96,
            color: _kSuccessGreen,
          ),
        ),
      ),
    );
  }
}
