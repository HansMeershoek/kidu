import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../formatting/relative_time_nl.dart';
import '../ui/kidu_styles.dart';
import 'household_split_settings_repository.dart';
import 'parent_split.dart';

class HouseholdSplitMember {
  final String uid;
  final String label;
  const HouseholdSplitMember({required this.uid, required this.label});
}

Future<List<HouseholdSplitMember>> loadHouseholdSplitMembers(
  String householdId,
) async {
  final fs = FirebaseFirestore.instance;
  final memberSnap = await fs
      .collection('households/$householdId/members')
      .get();
  final memberUids = memberSnap.docs.map((d) => d.id).toList(growable: false)
    ..sort();
  final result = <HouseholdSplitMember>[];
  for (final uid in memberUids) {
    String label = uid;
    try {
      final u = await fs.doc('users/$uid').get();
      final data = u.data();
      final name = (data?['profileName'] ?? data?['displayName']) as String?;
      if (name != null && name.trim().isNotEmpty) label = name.trim();
    } catch (_) {
      /* ignore */
    }
    result.add(HouseholdSplitMember(uid: uid, label: label));
  }
  return result;
}

/// Settings > Huishouden > Uitgavenverdeling.
///
/// Load-logica spiegelt exact `buildSnapshotForNewExpense`: bij 2
/// actuele members en missende/structureel-ongeldige/stale settings
/// toont de UI neutraal 50/50. Stale bps wordt niet preloaded tegen
/// een andere uid. Slider staat op [kHouseholdShareBpsMin..
/// kHouseholdShareBpsMax] (0..100%).
class HouseholdSplitSettingsPage extends StatefulWidget {
  const HouseholdSplitSettingsPage({
    super.key,
    required this.householdId,
    this.initialMembers,
    this.initialDefaults,
  });

  final String householdId;
  final List<HouseholdSplitMember>? initialMembers;
  final HouseholdSplitDefaults? initialDefaults;

  @override
  State<HouseholdSplitSettingsPage> createState() =>
      _HouseholdSplitSettingsPageState();
}

class _HouseholdSplitSettingsPageState
    extends State<HouseholdSplitSettingsPage> {
  final HouseholdSplitSettingsRepository _repo =
      HouseholdSplitSettingsRepository();

  bool _loading = true;
  String? _loadError;
  List<HouseholdSplitMember> _members = const [];
  String? _selectedShare0Uid;
  int _share0Bps = kHouseholdShareBpsNeutral;
  String? _initialShare0Uid;
  int? _initialShare0Bps;
  String? _updatedBy;
  DateTime? _updatedAt;
  bool _saving = false;
  StreamSubscription<HouseholdSplitDefaults?>? _defaultsSub;

  bool get _isDirty =>
      _selectedShare0Uid != _initialShare0Uid ||
      _share0Bps != _initialShare0Bps;

  @override
  void initState() {
    super.initState();
    final bootstrapMembers = widget.initialMembers;
    if (bootstrapMembers != null) {
      _members = bootstrapMembers;
      _applyDefaultsState(bootstrapMembers, widget.initialDefaults);
      _loading = false;
    } else {
      _init();
    }
    _defaultsSub = _repo.watch(widget.householdId).listen(_onDefaultsFromStream);
  }

  @override
  void dispose() {
    _defaultsSub?.cancel();
    super.dispose();
  }

  void _applyDefaultsState(
    List<HouseholdSplitMember> members,
    HouseholdSplitDefaults? defaults,
  ) {
    final memberSet = members.map((m) => m.uid).toSet();
    final validDefaults =
        (defaults != null && defaults.isValidForMembers(memberSet))
        ? defaults
        : null;

    _updatedBy = validDefaults?.updatedBy;
    _updatedAt = validDefaults?.updatedAt;
    if (validDefaults != null) {
      _selectedShare0Uid = validDefaults.share0Uid;
      _share0Bps = validDefaults.share0Bps;
    } else if (members.length == kParentSplitParticipantCount) {
      _selectedShare0Uid = members.first.uid;
      _share0Bps = kHouseholdShareBpsNeutral;
    } else {
      _selectedShare0Uid = null;
      _share0Bps = kHouseholdShareBpsNeutral;
    }
    _initialShare0Uid = _selectedShare0Uid;
    _initialShare0Bps = _share0Bps;
  }

  void _onDefaultsFromStream(HouseholdSplitDefaults? defaults) {
    if (!mounted || _saving || _isDirty) return;
    setState(() => _applyDefaultsState(_members, defaults));
  }

  Future<void> _init() async {
    try {
      final members = await loadHouseholdSplitMembers(widget.householdId);
      final defaults = await _repo.load(widget.householdId);
      if (!mounted) return;
      setState(() {
        _members = members;
        _applyDefaultsState(members, defaults);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Instellingen konden niet worden geladen.';
      });
    }
  }

  HouseholdSplitMember? _otherMember() {
    final sel = _selectedShare0Uid;
    if (sel == null) return null;
    for (final m in _members) {
      if (m.uid != sel) return m;
    }
    return null;
  }

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

  Future<void> _save() async {
    final share0Uid = _selectedShare0Uid;
    final other = _otherMember();
    if (share0Uid == null || other == null) return;
    if (!isValidHouseholdShareBps(_share0Bps)) return;

    if (share0Uid == _initialShare0Uid && _share0Bps == _initialShare0Bps) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Geen wijzigingen om op te slaan.')),
      );
      return;
    }

    if (!await _checkCanWriteNow()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Geen verbinding. Probeer het later opnieuw.'),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await _repo.save(
        householdId: widget.householdId,
        share0Uid: share0Uid,
        share1Uid: other.uid,
        share0Bps: _share0Bps,
      );
      if (!mounted) return;
      Navigator.of(context).maybePop();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Opslaan mislukt. Probeer opnieuw.')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _formatShare(int bps) {
    final pct = bps / 100.0;
    if (pct == pct.roundToDouble()) return '${pct.toStringAsFixed(0)}%';
    return '${pct.toStringAsFixed(1)}%';
  }

  String _formatLastChangedAgo(DateTime updatedAt) =>
      formatRelativeTimeNl(updatedAt);

  String? _lastChangedText() {
    final updatedBy = _updatedBy;
    final updatedAt = _updatedAt;
    if (updatedBy == null || updatedAt == null) return null;

    for (final member in _members) {
      if (member.uid == updatedBy) {
        return 'Laatste wijziging · ${_formatLastChangedAgo(updatedAt)} · '
            '${member.label}';
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          'Uitgavenverdeling',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _buildBody(context),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (_loading) {
      return ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: const SizedBox.expand(),
      );
    }
    if (_loadError != null) return Center(child: Text(_loadError!));
    if (_members.length != kParentSplitParticipantCount) {
      return const Center(
        child: Text(
          'Koppel eerst met je co-parent om een standaardverdeling in te '
          'stellen.',
          textAlign: TextAlign.center,
        ),
      );
    }

    final share0Uid = _selectedShare0Uid!;
    final other = _otherMember()!;
    final share0Label = _members.firstWhere((m) => m.uid == share0Uid).label;
    final viewerUid = FirebaseAuth.instance.currentUser?.uid;
    HouseholdSplitMember? viewer;
    HouseholdSplitMember? coParent;
    for (final m in _members) {
      if (m.uid == viewerUid) {
        viewer = m;
      } else {
        coParent = m;
      }
    }
    int shareFor(String uid) =>
        uid == share0Uid ? _share0Bps : kBpsFull - _share0Bps;
    final summaryText = viewer == null || coParent == null
        ? '$share0Label: ${_formatShare(_share0Bps)}  ·  '
              '${other.label}: ${_formatShare(kBpsFull - _share0Bps)}'
        : '${viewer.label}: ${_formatShare(shareFor(viewer.uid))}  ·  '
              '${coParent.label}: ${_formatShare(shareFor(coParent.uid))}';
    final firstShareBps = viewer == null || coParent == null
        ? _share0Bps
        : shareFor(viewer.uid);
    final lastChangedText = _lastChangedText();

    return ListView(
      children: <Widget>[
        Text(
          'Dit is de standaardverdeling voor nieuwe uitgaven. Per uitgave '
          'kun je hiervan afwijken.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurface.withValues(alpha: 0.68),
            height: 1.35,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          summaryText,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: colorScheme.primary.withValues(alpha: 0.58),
            inactiveTrackColor: colorScheme.onSurface.withValues(alpha: 0.12),
            thumbColor: colorScheme.primary.withValues(alpha: 0.72),
            overlayColor: colorScheme.primary.withValues(alpha: 0.08),
            trackHeight: 3,
          ),
          child: Slider(
            min: kHouseholdShareBpsMin.toDouble(),
            max: kHouseholdShareBpsMax.toDouble(),
            divisions: (kHouseholdShareBpsMax - kHouseholdShareBpsMin) ~/ 100,
            // `num.clamp(double, double)` on a double returns `num`, not
            // `double`. Slider.value requires `double`, so cast back.
            value: firstShareBps
                .toDouble()
                .clamp(
                  kHouseholdShareBpsMin.toDouble(),
                  kHouseholdShareBpsMax.toDouble(),
                )
                .toDouble(),
            label: _formatShare(firstShareBps),
            onChanged: _saving
                ? null
                : (v) {
                    final rounded = v.round();
                    setState(() {
                      _share0Bps = viewer != null && viewer.uid != share0Uid
                          ? kBpsFull - rounded
                          : rounded;
                    });
                  },
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: _saving
                    ? null
                    : () => Navigator.of(context).maybePop(),
                child: const Text('Annuleren'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                style: kiduFormPrimaryButtonStyle(context),
                onPressed: _saving || !_isDirty ? null : _save,
                child: _saving
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colorScheme.onSecondaryContainer,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text('Opslaan'),
                        ],
                      )
                    : const Text('Opslaan'),
              ),
            ),
          ],
        ),
        if (lastChangedText != null) ...[
          const SizedBox(height: 8),
          Text(
            lastChangedText,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.50),
            ),
          ),
        ],
      ],
    );
  }
}
