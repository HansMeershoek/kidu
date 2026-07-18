/// Account-deletion info page, plus the real delete flow.
///
/// This screen explains what happens to the account/household, then offers
/// the real delete flow (confirmation → KiDu Google-explanation → Google
/// re-auth → Firestore write → Auth delete → success) for all four
/// household states, implemented further down in this file and in
/// `account_delete_controller.dart`.
///
/// For `readOnly`, deleting the account is the *last* remaining member of
/// an already read-only household leaving for good: the flow calls the
/// Fase 4 `deleteReadOnlyHouseholdAndAccount` Cloud Function, which
/// validates everything server-side and then deletes the household tree,
/// its invites, the caller's user-doc, and the caller's Auth account. This
/// page/file never performs that cleanup itself — see
/// `account_delete_controller.dart` and `functions/src/index.ts`.
library;

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../read_only/read_only_widgets.dart';
import '../ui/kidu_styles.dart';
import 'account_delete_controller.dart';
import 'account_delete_texts.dart';

/// Explains the account-deletion flow, and offers the real delete flow for
/// all four household states (see `AccountDeleteHouseholdState`).
///
/// Callers pass in state they already have available (Fase 1's
/// `isReadOnly`, whether a co-parent/second member is linked, and whether a
/// household exists at all) — this page does not fetch that part itself.
class AccountDeleteInfoPage extends StatelessWidget {
  const AccountDeleteInfoPage({
    super.key,
    required this.hasHousehold,
    required this.isReadOnly,
    required this.hasCoParent,
    required this.householdId,
    required this.onAccountDeleted,
    this.logboekPageBuilder,
  });

  /// Whether the current user has a linked household at all.
  final bool hasHousehold;

  /// Fase 1 household-level read-only flag.
  final bool isReadOnly;

  /// Whether a co-parent (second member) is currently linked.
  final bool hasCoParent;

  /// Only read when the resolved state is `activeWithCoParent`,
  /// `activeSolo`, or `readOnly`: the real delete flow needs it for the
  /// eligibility check and the Firestore batch. The uid itself always
  /// comes from `FirebaseAuth.instance.currentUser` at the time of the
  /// actual delete attempt, not from a value passed in here.
  final String householdId;

  /// The app's existing sign-out flow (see `_SettingsPage.signOut` in
  /// `main.dart`), reused as-is. Only invoked from the success page, and
  /// only after the user taps "Terug naar inloggen" — never automatically.
  final Future<void> Function(BuildContext context) onAccountDeleted;

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
                  if (hasHousehold &&
                      state != AccountDeleteHouseholdState.activeSolo) ...[
                    const SizedBox(height: 16),
                    _ExportAdviceSection(
                      onOpenLogboek: logboekPageBuilder == null
                          ? null
                          : () => _openLogboek(context),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (state == AccountDeleteHouseholdState.activeWithCoParent)
                    _DeleteAvailableSection(
                      mode: AccountDeleteFlowMode.activeWithCoParent,
                      householdId: householdId,
                      onAccountDeleted: onAccountDeleted,
                    )
                  else if (state == AccountDeleteHouseholdState.noHousehold)
                    _DeleteAvailableSection(
                      mode: AccountDeleteFlowMode.noHousehold,
                      onAccountDeleted: onAccountDeleted,
                    )
                  else if (state == AccountDeleteHouseholdState.activeSolo)
                    _DeleteAvailableSection(
                      mode: AccountDeleteFlowMode.activeSolo,
                      householdId: householdId,
                      onAccountDeleted: onAccountDeleted,
                    )
                  else if (state == AccountDeleteHouseholdState.readOnly)
                    _DeleteAvailableSection(
                      mode: AccountDeleteFlowMode.readOnly,
                      householdId: householdId,
                      onAccountDeleted: onAccountDeleted,
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

/// Shown for all four household states. Opens the confirmation page — no
/// Firestore/Auth call happens from this widget itself.
class _DeleteAvailableSection extends StatelessWidget {
  const _DeleteAvailableSection({
    required this.mode,
    required this.onAccountDeleted,
    this.householdId,
  });

  final AccountDeleteFlowMode mode;
  final String? householdId;
  final Future<void> Function(BuildContext context) onAccountDeleted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _InfoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            accountDeleteStartSectionBodyFor(mode),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.80),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => _AccountDeleteConfirmPage(
                    mode: mode,
                    householdId: householdId,
                    onAccountDeleted: onAccountDeleted,
                  ),
                ),
              );
            },
            child: const Text(accountDeleteStartButtonLabel),
          ),
        ],
      ),
    );
  }
}

/// Non-snackbar inline error surface shared by the confirmation and Google
/// re-auth-explanation pages below.
class _InlineErrorText extends StatelessWidget {
  const _InlineErrorText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: scheme.onErrorContainer),
      ),
    );
  }
}

/// Fase 3/3b confirmation screen: exact "VERWIJDEREN" keyword, then drives the
/// full safe sequence (eligibility → KiDu Google-explanation page → Google
/// re-auth there → Firestore write → Auth delete). No Google call happens
/// in this page itself. See `account_delete_controller.dart` for the
/// individual steps.
class _AccountDeleteConfirmPage extends StatefulWidget {
  const _AccountDeleteConfirmPage({
    required this.mode,
    required this.onAccountDeleted,
    this.householdId,
  });

  final AccountDeleteFlowMode mode;
  final String? householdId;
  final Future<void> Function(BuildContext context) onAccountDeleted;

  @override
  State<_AccountDeleteConfirmPage> createState() =>
      _AccountDeleteConfirmPageState();
}

class _AccountDeleteConfirmPageState extends State<_AccountDeleteConfirmPage> {
  final TextEditingController _typedController = TextEditingController();
  bool _busy = false;
  // Once true, the destructive Firestore step already ran (household batch
  // or standalone user-doc minimization) — a retry must skip eligibility and
  // must not repeat that write, and only retries `deleteAuthAccount()`. Not
  // used for `AccountDeleteFlowMode.readOnly` — see
  // `_readOnlyCleanupAttempted` below.
  bool _firestoreStepDone = false;
  // Fase 4: readOnly runs a single idempotent server-side callable
  // (`deleteReadOnlyHouseholdAndAccount`) that covers both the Firestore
  // cleanup and the Auth delete. Once true, a retry must skip the
  // client-side `checkReadOnlyEligibility` pre-check — server-side state
  // may already have changed by a previous partial attempt — and go
  // straight back to Google re-auth + retrying the same callable.
  bool _readOnlyCleanupAttempted = false;
  String? _errorText;

  @override
  void dispose() {
    _typedController.dispose();
    super.dispose();
  }

  bool get _keywordMatches =>
      _typedController.text.trim() == accountDeleteConfirmKeyword;

  String _eligibilityFailureMessage(AccountDeleteEligibilityFailure failure) {
    switch (failure) {
      case AccountDeleteEligibilityFailure.householdReadOnly:
        return accountDeleteErrorHouseholdReadOnly;
      case AccountDeleteEligibilityFailure.noCoParent:
        return accountDeleteErrorNoCoParent;
      case AccountDeleteEligibilityFailure.householdMismatch:
      case AccountDeleteEligibilityFailure.householdMissing:
      case AccountDeleteEligibilityFailure.notMember:
      case AccountDeleteEligibilityFailure.unknown:
        return accountDeleteErrorNotEligible;
    }
  }

  String _noHouseholdEligibilityFailureMessage(
    NoHouseholdEligibilityFailure failure,
  ) {
    switch (failure) {
      case NoHouseholdEligibilityFailure.householdLinked:
        return accountDeleteErrorHouseholdLinked;
      case NoHouseholdEligibilityFailure.unknown:
        return accountDeleteErrorNotEligible;
    }
  }

  String _activeSoloEligibilityFailureMessage(
    ActiveSoloEligibilityFailure failure,
  ) {
    switch (failure) {
      case ActiveSoloEligibilityFailure.householdReadOnly:
        return accountDeleteErrorHouseholdReadOnly;
      case ActiveSoloEligibilityFailure.hasCoParent:
        return accountDeleteErrorHasCoParent;
      case ActiveSoloEligibilityFailure.householdMismatch:
      case ActiveSoloEligibilityFailure.householdMissing:
      case ActiveSoloEligibilityFailure.notMember:
      case ActiveSoloEligibilityFailure.unknown:
        return accountDeleteErrorNotEligible;
    }
  }

  String _readOnlyEligibilityFailureMessage(
    ReadOnlyEligibilityFailure failure,
  ) {
    switch (failure) {
      case ReadOnlyEligibilityFailure.notReadOnly:
        return accountDeleteErrorHouseholdNotReadOnly;
      case ReadOnlyEligibilityFailure.householdMismatch:
      case ReadOnlyEligibilityFailure.householdMissing:
      case ReadOnlyEligibilityFailure.notMember:
      case ReadOnlyEligibilityFailure.unknown:
        return accountDeleteErrorNotEligible;
    }
  }

  Future<void> _onDeletePressed() async {
    if (_busy || !_keywordMatches) return;

    setState(() {
      _busy = true;
      _errorText = null;
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        setState(() => _errorText = accountDeleteErrorNotSignedIn);
        return;
      }

      // Captured before the first async gap below so the Google-confirm
      // push does not use `context` directly across that gap.
      final navigator = Navigator.of(context);

      if (widget.mode == AccountDeleteFlowMode.readOnly) {
        // Fase 4: quick client-side pre-check only — the real, authoritative
        // validation happens server-side in the callable. Skipped on retry:
        // by then the server may already have (partially) minimized this
        // account, which would make this pre-check fail even though the
        // idempotent callable itself would succeed if tried again.
        if (!_readOnlyCleanupAttempted) {
          final householdId = widget.householdId?.trim() ?? '';
          if (householdId.isEmpty) {
            setState(() => _errorText = accountDeleteErrorNotEligible);
            return;
          }
          final readOnlyEligibility =
              await AccountDeleteController.checkReadOnlyEligibility(
            householdId: householdId,
            uid: user.uid,
          );
          if (!mounted) return;
          if (!readOnlyEligibility.isEligible) {
            setState(
              () => _errorText = _readOnlyEligibilityFailureMessage(
                readOnlyEligibility.failure!,
              ),
            );
            return;
          }
        }
      } else if (!_firestoreStepDone) {
        switch (widget.mode) {
          case AccountDeleteFlowMode.activeWithCoParent:
            final householdId = widget.householdId?.trim() ?? '';
            if (householdId.isEmpty) {
              setState(() => _errorText = accountDeleteErrorNotEligible);
              return;
            }
            final eligibility = await AccountDeleteController.checkEligibility(
              householdId: householdId,
              uid: user.uid,
            );
            if (!mounted) return;
            if (!eligibility.isEligible) {
              setState(
                () => _errorText = _eligibilityFailureMessage(
                  eligibility.failure!,
                ),
              );
              return;
            }
          case AccountDeleteFlowMode.noHousehold:
            final eligibility =
                await AccountDeleteController.checkNoHouseholdEligibility(
              uid: user.uid,
            );
            if (!mounted) return;
            if (!eligibility.isEligible) {
              setState(
                () => _errorText = _noHouseholdEligibilityFailureMessage(
                  eligibility.failure!,
                ),
              );
              return;
            }
          case AccountDeleteFlowMode.activeSolo:
            final householdId = widget.householdId?.trim() ?? '';
            if (householdId.isEmpty) {
              setState(() => _errorText = accountDeleteErrorNotEligible);
              return;
            }
            final soloEligibility =
                await AccountDeleteController.checkActiveSoloEligibility(
              householdId: householdId,
              uid: user.uid,
            );
            if (!mounted) return;
            if (!soloEligibility.isEligible) {
              setState(
                () => _errorText = _activeSoloEligibilityFailureMessage(
                  soloEligibility.failure!,
                ),
              );
              return;
            }
          case AccountDeleteFlowMode.readOnly:
            break; // Handled above, before Google re-auth.
        }
      }

      // No Google call here: on Android, even the "lightweight" API can
      // pop the account bottom sheet immediately, before KiDu has had a
      // chance to explain anything. Always go to the explanation page
      // first — the actual Google re-auth only happens there, after the
      // user explicitly taps "Bevestigen met Google".
      setState(() => _busy = false);
      if (!mounted) return;
      final reauthed = await navigator.push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => _AccountDeleteGoogleConfirmPage(user: user),
        ),
      );
      if (!mounted) return;
      if (reauthed != true) {
        return;
      }
      setState(() => _busy = true);

      if (widget.mode == AccountDeleteFlowMode.readOnly) {
        // Fase 4: flip the flag *before* the call, not after — the
        // callable is idempotent, so a retry must skip the client
        // pre-check above even if this very call throws partway through.
        _readOnlyCleanupAttempted = true;
        await AccountDeleteController.deleteReadOnlyHouseholdAndAccount(
          householdId: widget.householdId!.trim(),
        );
      } else {
        if (!_firestoreStepDone) {
          switch (widget.mode) {
            case AccountDeleteFlowMode.activeWithCoParent:
              await AccountDeleteController.runDeleteBatch(
                householdId: widget.householdId!.trim(),
                uid: user.uid,
              );
            case AccountDeleteFlowMode.noHousehold:
              await AccountDeleteController.minimizeStandaloneUserDoc(
                uid: user.uid,
              );
            case AccountDeleteFlowMode.activeSolo:
              await AccountDeleteController.runActiveSoloDeleteBatch(
                householdId: widget.householdId!.trim(),
                uid: user.uid,
              );
            case AccountDeleteFlowMode.readOnly:
              break; // Handled above: single server-side callable.
          }
          _firestoreStepDone = true;
        }

        await AccountDeleteController.deleteAuthAccount();
      }

      if (!mounted) return;
      await Navigator.of(context).pushAndRemoveUntil<void>(
        MaterialPageRoute<void>(
          builder: (_) => _AccountDeleteSuccessPage(
            mode: widget.mode,
            onAccountDeleted: widget.onAccountDeleted,
          ),
        ),
        (route) => false,
      );
      return;
    } catch (e) {
      final destructiveStepAttempted = widget.mode == AccountDeleteFlowMode.readOnly
          ? _readOnlyCleanupAttempted
          : _firestoreStepDone;
      final fallback = destructiveStepAttempted
          ? accountDeleteErrorAfterFirestoreStepFor(widget.mode)
          : accountDeleteErrorBeforeFirestoreStepFor(widget.mode);
      if (mounted) {
        setState(
          () => _errorText = AccountDeleteController.messageForException(
            e,
            fallback: fallback,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          accountDeleteConfirmTitle,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
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
                  Text(
                    accountDeleteConfirmBody,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.80),
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _typedController,
                    enabled: !_busy,
                    autocorrect: false,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: accountDeleteConfirmInputLabel,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  if (_errorText != null) ...[
                    const SizedBox(height: 12),
                    _InlineErrorText(text: _errorText!),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    style: kiduFormPrimaryButtonStyle(context),
                    onPressed: (_busy || !_keywordMatches)
                        ? null
                        : _onDeletePressed,
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            (widget.mode == AccountDeleteFlowMode.readOnly
                                    ? _readOnlyCleanupAttempted
                                    : _firestoreStepDone)
                                ? accountDeleteConfirmRetryButtonLabel
                                : accountDeleteConfirmButtonLabel,
                          ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    accountDeleteConfirmSafetyNote,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.60),
                      height: 1.35,
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
}

/// Fase 3 explanation step, always shown before any Google call in the
/// delete flow. The Google account chooser/bottom sheet is opened only
/// after the user explicitly taps "Bevestigen met Google" below — never
/// before, and never automatically on entering this page.
class _AccountDeleteGoogleConfirmPage extends StatefulWidget {
  const _AccountDeleteGoogleConfirmPage({required this.user});

  final User user;

  @override
  State<_AccountDeleteGoogleConfirmPage> createState() =>
      _AccountDeleteGoogleConfirmPageState();
}

class _AccountDeleteGoogleConfirmPageState
    extends State<_AccountDeleteGoogleConfirmPage> {
  bool _busy = false;
  String? _errorText;

  String _failureMessage(AccountDeleteReauthFailureReason reason) {
    switch (reason) {
      case AccountDeleteReauthFailureReason.cancelledByUser:
        return accountDeleteErrorGoogleCancelled;
      case AccountDeleteReauthFailureReason.accountMismatch:
        return accountDeleteErrorAccountMismatch;
      case AccountDeleteReauthFailureReason.failed:
        return accountDeleteErrorGoogleFailed;
    }
  }

  Future<void> _onConfirmWithGooglePressed() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errorText = null;
    });

    final result = await AccountDeleteController.performGoogleReauth(
      widget.user,
    );

    if (!mounted) return;
    if (result.success) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _errorText = _failureMessage(result.failureReason!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          accountDeleteGoogleConfirmTitle,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
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
                  Text(
                    accountDeleteGoogleConfirmBody,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.80),
                      height: 1.4,
                    ),
                  ),
                  if (_errorText != null) ...[
                    const SizedBox(height: 16),
                    _InlineErrorText(text: _errorText!),
                  ],
                  const SizedBox(height: 20),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text(
                      accountDeleteGoogleConfirmCancelButtonLabel,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    style: kiduFormPrimaryButtonStyle(context),
                    onPressed: _busy ? null : _onConfirmWithGooglePressed,
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text(accountDeleteGoogleConfirmButtonLabel),
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

/// Fase 3/3b success page, shown after both the Firestore write and the Auth
/// delete have succeeded. `onAccountDeleted` (the app's existing sign-out
/// flow) is only invoked once the user taps the button below.
class _AccountDeleteSuccessPage extends StatelessWidget {
  const _AccountDeleteSuccessPage({
    required this.mode,
    required this.onAccountDeleted,
  });

  final AccountDeleteFlowMode mode;
  final Future<void> Function(BuildContext context) onAccountDeleted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          automaticallyImplyLeading: false,
          title: Text(
            accountDeleteSuccessTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
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
                    Text(
                      accountDeleteSuccessBodyFor(mode),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.80),
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      style: kiduFormPrimaryButtonStyle(context),
                      onPressed: () =>
                          unawaited(onAccountDeleted(context)),
                      child: const Text(accountDeleteSuccessButtonLabel),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
