import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'household_split_settings_repository.dart';
import 'parent_split.dart';

/// Settings > Huishouden > Standaardverdeling.
///
/// Load-logica spiegelt exact `buildSnapshotForNewExpense`: bij 2
/// actuele members en missende/structureel-ongeldige/stale settings
/// toont de UI neutraal 50/50. Stale bps wordt niet preloaded tegen
/// een andere uid. Slider staat strikt op [kHouseholdShareBpsMin..
/// kHouseholdShareBpsMax].
class HouseholdSplitSettingsPage extends StatefulWidget {
  const HouseholdSplitSettingsPage({super.key, required this.householdId});

  final String householdId;

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
  List<_Member> _members = const [];
  String? _selectedShare0Uid;
  int _share0Bps = kHouseholdShareBpsNeutral;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final members = await _loadMembers(widget.householdId);
      final defaults = await _repo.load(widget.householdId);
      final memberSet = members.map((m) => m.uid).toSet();

      // Stale-check mirrored from buildSnapshotForNewExpense. A
      // settings-doc that no longer maps 1:1 to the current 2 members
      // is treated as "no settings" here; we do NOT preload the old
      // bps against a different uid.
      final validDefaults =
          (defaults != null && defaults.isValidForMembers(memberSet))
          ? defaults
          : null;

      setState(() {
        _members = members;
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
        _loading = false;
      });
    } catch (_) {
      setState(() {
        _loading = false;
        _loadError = 'Instellingen konden niet worden geladen.';
      });
    }
  }

  Future<List<_Member>> _loadMembers(String householdId) async {
    final fs = FirebaseFirestore.instance;
    final memberSnap = await fs
        .collection('households/$householdId/members')
        .get();
    final memberUids = memberSnap.docs.map((d) => d.id).toList(growable: false)
      ..sort();
    final result = <_Member>[];
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
      result.add(_Member(uid: uid, label: label));
    }
    return result;
  }

  _Member? _otherMember() {
    final sel = _selectedShare0Uid;
    if (sel == null) return null;
    for (final m in _members) {
      if (m.uid != sel) return m;
    }
    return null;
  }

  Future<void> _save() async {
    final share0Uid = _selectedShare0Uid;
    final other = _otherMember();
    if (share0Uid == null || other == null) return;
    if (!isValidHouseholdShareBps(_share0Bps)) return;

    setState(() => _saving = true);
    try {
      await _repo.save(
        householdId: widget.householdId,
        share0Uid: share0Uid,
        share1Uid: other.uid,
        share0Bps: _share0Bps,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Standaardverdeling opgeslagen.')),
      );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Standaardverdeling')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _buildBody(context),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
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

    return ListView(
      children: <Widget>[
        const Text(
          'Bepaalt hoe NIEUWE uitgaven tussen jullie worden verdeeld. '
          'Bestaande uitgaven veranderen hierdoor niet.',
        ),
        const SizedBox(height: 16),
        Text(
          'Wie draagt welk deel?',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        IgnorePointer(
          ignoring: _saving,
          child: RadioGroup<String>(
            groupValue: share0Uid,
            onChanged: (String? v) {
              if (v == null) return;
              setState(() => _selectedShare0Uid = v);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final m in _members)
                  RadioListTile<String>(
                    value: m.uid,
                    title: Text(m.label),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '$share0Label: ${_formatShare(_share0Bps)}  ·  '
          '${other.label}: ${_formatShare(kBpsFull - _share0Bps)}',
        ),
        Slider(
          min: kHouseholdShareBpsMin.toDouble(),
          max: kHouseholdShareBpsMax.toDouble(),
          divisions: (kHouseholdShareBpsMax - kHouseholdShareBpsMin) ~/ 100,
          // `num.clamp(double, double)` on a double returns `num`, not
          // `double`. Slider.value requires `double`, so cast back.
          value: _share0Bps
              .toDouble()
              .clamp(
                kHouseholdShareBpsMin.toDouble(),
                kHouseholdShareBpsMax.toDouble(),
              )
              .toDouble(),
          label: _formatShare(_share0Bps),
          onChanged: _saving
              ? null
              : (v) {
                  setState(() => _share0Bps = v.round());
                },
        ),
        const SizedBox(height: 8),
        Text(
          'Minimum ${_formatShare(kHouseholdShareBpsMin)} · Maximum '
          '${_formatShare(kHouseholdShareBpsMax)}. 0% en 100% zijn bewust '
          'niet toegestaan als standaard.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Opslaan…' : 'Opslaan'),
        ),
      ],
    );
  }
}

class _Member {
  final String uid;
  final String label;
  const _Member({required this.uid, required this.label});
}
