/// Fase 2 — account-deletion info page.
///
/// This screen only explains what *will* happen to the account/household in
/// a later phase. It performs no Firestore write, no Auth delete/re-auth,
/// and shows no snackbars — it is purely informational.
library;

import 'package:flutter/material.dart';

import '../read_only/read_only_widgets.dart';
import 'account_delete_texts.dart';

/// Explains the account-deletion flow before it actually exists.
///
/// Callers pass in state they already have available (Fase 1's
/// `isReadOnly`, whether a co-parent/second member is linked, and whether a
/// household exists at all) — this page does not fetch anything itself.
class AccountDeleteInfoPage extends StatelessWidget {
  const AccountDeleteInfoPage({
    super.key,
    required this.hasHousehold,
    required this.isReadOnly,
    required this.hasCoParent,
    this.logboekPageBuilder,
  });

  /// Whether the current user has a linked household at all.
  final bool hasHousehold;

  /// Fase 1 household-level read-only flag.
  final bool isReadOnly;

  /// Whether a co-parent (second member) is currently linked.
  final bool hasCoParent;

  /// Builds the existing Logboek page when the "Open Logboek" button is
  /// tapped. `null` hides the button (e.g. no household to export from).
  final WidgetBuilder? logboekPageBuilder;

  void _openLogboek(BuildContext context) {
    final builder = logboekPageBuilder;
    if (builder == null) return;
    Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: builder));
  }

  @override
  Widget build(BuildContext context) {
    final state = resolveAccountDeleteHouseholdState(
      hasHousehold: hasHousehold,
      isReadOnly: isReadOnly,
      hasCoParent: hasCoParent,
    );

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: ReadOnlyAppBarTitle(
          isReadOnly: isReadOnly,
          title: Text(
            accountDeleteTitle,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _AccountDeleteSection(text: accountDeleteIntroFor(state)),
                  if (hasHousehold) ...[
                    const SizedBox(height: 16),
                    _ExportAdviceSection(
                      onOpenLogboek: logboekPageBuilder == null
                          ? null
                          : () => _openLogboek(context),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const _PreparationSection(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Quiet bordered card, styled independently from `main.dart`'s `KiduCard`
/// on purpose (this file avoids importing `main.dart`).
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.child});

  final Widget child;

  static const double _radius = 16;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(_radius),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.55)),
      ),
      child: child,
    );
  }
}

class _AccountDeleteSection extends StatelessWidget {
  const _AccountDeleteSection({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _InfoCard(
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: scheme.onSurface.withValues(alpha: 0.80),
          height: 1.4,
        ),
      ),
    );
  }
}

class _ExportAdviceSection extends StatelessWidget {
  const _ExportAdviceSection({required this.onOpenLogboek});

  /// `null` hides the "Open Logboek" button (text-only advice).
  final VoidCallback? onOpenLogboek;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _InfoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            accountDeleteExportAdvice,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.80),
              height: 1.4,
            ),
          ),
          if (onOpenLogboek != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onOpenLogboek,
              child: const Text(accountDeleteExportButtonLabel),
            ),
          ],
        ],
      ),
    );
  }
}

class _PreparationSection extends StatelessWidget {
  const _PreparationSection();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _InfoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            accountDeletePreparationBody,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.70),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          // Deliberately disabled: Fase 2 must not perform any real
          // deletion. `onPressed: null` keeps this button visually and
          // functionally inert.
          FilledButton.tonal(
            onPressed: null,
            child: const Text(accountDeletePreparationButtonLabel),
          ),
        ],
      ),
    );
  }
}
