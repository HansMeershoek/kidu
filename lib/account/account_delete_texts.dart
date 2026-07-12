/// Static Dutch copy for the account-deletion flow.
///
/// This file only holds text and small pure helpers to pick the right text
/// for a given household state / flow mode. It performs no Firestore or
/// Auth calls and triggers no writes.
library;

/// The household situations the account-deletion info page distinguishes.
///
/// `activeSolo` covers a household that exists but has no second member
/// yet (waiting for a co-parent to join). It intentionally reuses the same
/// copy as [noHousehold] below, because there is no co-parent whose access
/// needs explaining — but the export advice is still shown for it, since a
/// household (and therefore data) already exists.
enum AccountDeleteHouseholdState { noHousehold, activeSolo, activeWithCoParent, readOnly }

/// Which destructive delete path the confirmation flow executes.
///
/// `readOnly` (Fase 3d): the household is already frozen (read-only) by an
/// earlier account deletion. This mode deletes only the caller's own
/// member-doc and minimizes their own user-doc — it never touches the
/// household root document or its subcollections (that stays for a later
/// Fase 4 server-side cleanup).
enum AccountDeleteFlowMode { activeWithCoParent, noHousehold, activeSolo, readOnly }

/// Picks the right [AccountDeleteHouseholdState] from booleans the caller
/// already has available (Fase 1 read-only state, member count, ...).
///
/// Pure and read-only: does not touch Firestore/Auth itself.
AccountDeleteHouseholdState resolveAccountDeleteHouseholdState({
  required bool hasHousehold,
  required bool isReadOnly,
  required bool hasCoParent,
}) {
  if (!hasHousehold) return AccountDeleteHouseholdState.noHousehold;
  if (isReadOnly) return AccountDeleteHouseholdState.readOnly;
  if (hasCoParent) return AccountDeleteHouseholdState.activeWithCoParent;
  return AccountDeleteHouseholdState.activeSolo;
}

const String accountDeleteTitle = 'Account verwijderen';

const String accountDeleteIntroActiveWithCoParent =
    'Als je je account verwijdert, verlies jij toegang tot KiDu.\n\n'
    'Het gekoppelde huishouden wordt niet verwijderd. Je co-parent behoudt '
    'toegang tot de bestaande administratie, maar het huishouden wordt '
    'read-only.\n\n'
    'Je co-parent kan bestaande gegevens blijven bekijken en exporteren, '
    'maar niets meer toevoegen of wijzigen.\n\n'
    'Maak eerst een CSV- of PDF-export als je de administratie zelf wilt '
    'bewaren.';

const String accountDeleteIntroReadOnly =
    'Dit huishouden is read-only.\n\n'
    'Je behoudt leestoegang tot de administratie zolang je account '
    'bestaat.\n\n'
    'Als je je account verwijdert, verlies je toegang tot KiDu.';

const String accountDeleteIntroNoHousehold =
    'Je account is nog niet gekoppeld aan een huishouden.\n\n'
    'Als je je account verwijdert, verwijderen we je toegang tot KiDu en '
    'wissen we je persoonlijke profielgegevens uit dit account.\n\n'
    'Er is geen huishouden dat read-only hoeft te worden gemaakt.';

const String accountDeleteIntroSolo =
    'Je account is nog niet gekoppeld aan een co-parent.\n\n'
    'Als je je account verwijdert, verlies je toegang tot KiDu. Je '
    'persoonlijke profielgegevens worden uit dit account gewist.';

/// Returns the explanation text for [state].
String accountDeleteIntroFor(AccountDeleteHouseholdState state) {
  switch (state) {
    case AccountDeleteHouseholdState.activeWithCoParent:
      return accountDeleteIntroActiveWithCoParent;
    case AccountDeleteHouseholdState.readOnly:
      return accountDeleteIntroReadOnly;
    case AccountDeleteHouseholdState.noHousehold:
      return accountDeleteIntroNoHousehold;
    case AccountDeleteHouseholdState.activeSolo:
      return accountDeleteIntroSolo;
  }
}

const String accountDeleteExportAdvice =
    'Wil je je administratie bewaren? Exporteer eerst je gegevens via '
    'Logboek.';

const String accountDeleteExportButtonLabel = 'Open Logboek';

// ── Fase 3/3b/3c/3d: reachable for all four household states. ──

const String accountDeleteStartSectionBody =
    'Je kunt je account nu verwijderen. Op het volgende scherm vragen we je '
    'eerst om een expliciete bevestiging.';

const String accountDeleteStartSectionBodyNoHousehold =
    'Je kunt je account nu verwijderen. Op het volgende scherm vragen we je '
    'eerst om een expliciete bevestiging.';

const String accountDeleteStartSectionBodyActiveSolo =
    'Je kunt je account nu verwijderen. Op het volgende scherm vragen we je '
    'eerst om een expliciete bevestiging.';

const String accountDeleteStartSectionBodyReadOnly =
    'Je kunt je account verwijderen. Op het volgende scherm vragen we je '
    'eerst om een expliciete bevestiging.';

String accountDeleteStartSectionBodyFor(AccountDeleteFlowMode mode) {
  switch (mode) {
    case AccountDeleteFlowMode.activeWithCoParent:
      return accountDeleteStartSectionBody;
    case AccountDeleteFlowMode.noHousehold:
      return accountDeleteStartSectionBodyNoHousehold;
    case AccountDeleteFlowMode.activeSolo:
      return accountDeleteStartSectionBodyActiveSolo;
    case AccountDeleteFlowMode.readOnly:
      return accountDeleteStartSectionBodyReadOnly;
  }
}

const String accountDeleteStartButtonLabel = 'Account verwijderen';

const String accountDeleteConfirmTitle = 'Account verwijderen';

const String accountDeleteConfirmBody =
    'Deze actie kan niet ongedaan worden gemaakt. Typ hieronder exact '
    'VERWIJDEREN om te bevestigen.';

const String accountDeleteConfirmInputLabel = 'Typ VERWIJDEREN om te bevestigen';

const String accountDeleteConfirmKeyword = 'VERWIJDEREN';

const String accountDeleteConfirmButtonLabel = 'Account definitief verwijderen';

const String accountDeleteConfirmRetryButtonLabel = 'Verwijdering opnieuw proberen';

const String accountDeleteConfirmSafetyNote =
    'KiDu probeert je account veilig te verwijderen. Als Google opnieuw '
    'bevestiging nodig heeft, leggen we dat eerst uit.';

const String accountDeleteGoogleConfirmTitle = 'Bevestig met Google';

const String accountDeleteGoogleConfirmBody =
    'Google vraagt om bevestiging voordat je account verwijderd mag '
    'worden.\n\n'
    'Kies hetzelfde Google-account waarmee je nu in KiDu bent ingelogd.';

const String accountDeleteGoogleConfirmCancelButtonLabel = 'Annuleren';

const String accountDeleteGoogleConfirmButtonLabel = 'Bevestigen met Google';

const String accountDeleteSuccessTitle = 'Je account is succesvol verwijderd';

const String accountDeleteSuccessBody =
    'Je hebt geen toegang meer tot dit huishouden.\n\n'
    'De overgebleven co-ouder kan het huishouden read-only bekijken en '
    'exporteren.';

const String accountDeleteSuccessBodyNoHousehold =
    'Je KiDu-account is verwijderd.\n\n'
    'Je kunt later opnieuw beginnen door opnieuw in te loggen.';

String accountDeleteSuccessBodyFor(AccountDeleteFlowMode mode) {
  switch (mode) {
    case AccountDeleteFlowMode.activeWithCoParent:
    case AccountDeleteFlowMode.readOnly:
      return accountDeleteSuccessBody;
    case AccountDeleteFlowMode.noHousehold:
    case AccountDeleteFlowMode.activeSolo:
      return accountDeleteSuccessBodyNoHousehold;
  }
}

const String accountDeleteSuccessButtonLabel = 'Terug naar inloggen';

const String accountDeleteErrorNotSignedIn = 'Je bent niet (meer) ingelogd.';

const String accountDeleteErrorNotEligible =
    'Verwijderen is nu niet mogelijk voor dit huishouden.';

const String accountDeleteErrorHouseholdReadOnly =
    'Dit huishouden is al read-only.';

const String accountDeleteErrorNoCoParent =
    'Er is geen co-parent (meer) gekoppeld aan dit huishouden.';

const String accountDeleteErrorGoogleCancelled =
    'Google-aanmelding geannuleerd. Probeer het opnieuw.';

const String accountDeleteErrorGoogleFailed =
    'Bevestigen met Google is niet gelukt. Probeer het opnieuw.';

const String accountDeleteErrorAccountMismatch =
    'Dit is niet hetzelfde Google-account als waarmee je in KiDu bent '
    'ingelogd. Kies het juiste account.';

const String accountDeleteErrorPermissionDenied = 'Je hebt hiervoor geen toegang.';

const String accountDeleteErrorNetwork =
    'Geen verbinding. Probeer het later opnieuw.';

const String accountDeleteErrorBatchFailed =
    'Verwijderen is niet gelukt. Probeer het opnieuw.';

const String accountDeleteErrorAuthDeleteFailedAfterBatch =
    'Je huishouden is al read-only gemaakt, maar je account kon nog niet '
    'volledig worden verwijderd. Probeer het opnieuw.';

const String accountDeleteErrorHouseholdLinked =
    'Je bent inmiddels gekoppeld aan een huishouden. Verwijderen via deze '
    'flow is niet mogelijk.';

const String accountDeleteErrorMinimizeFailed =
    'Verwijderen is niet gelukt. Probeer het opnieuw.';

const String accountDeleteErrorAuthDeleteFailedAfterMinimize =
    'Je profielgegevens zijn al gewist, maar je account kon nog niet '
    'volledig worden verwijderd. Probeer het opnieuw.';

const String accountDeleteErrorHasCoParent =
    'Er is inmiddels een co-parent gekoppeld. Verwijderen via deze flow is '
    'niet mogelijk.';

const String accountDeleteErrorHouseholdNotReadOnly =
    'Dit huishouden is niet meer read-only.';

const String accountDeleteErrorAuthDeleteFailedAfterReadOnlyBatch =
    'Je accountgegevens zijn al verwijderd, maar je account kon nog niet '
    'volledig worden verwijderd. Probeer het opnieuw.';

String accountDeleteErrorBeforeFirestoreStepFor(AccountDeleteFlowMode mode) {
  switch (mode) {
    case AccountDeleteFlowMode.noHousehold:
      return accountDeleteErrorMinimizeFailed;
    case AccountDeleteFlowMode.activeWithCoParent:
    case AccountDeleteFlowMode.activeSolo:
    case AccountDeleteFlowMode.readOnly:
      return accountDeleteErrorBatchFailed;
  }
}

String accountDeleteErrorAfterFirestoreStepFor(AccountDeleteFlowMode mode) {
  switch (mode) {
    case AccountDeleteFlowMode.noHousehold:
      return accountDeleteErrorAuthDeleteFailedAfterMinimize;
    case AccountDeleteFlowMode.activeWithCoParent:
    case AccountDeleteFlowMode.activeSolo:
      return accountDeleteErrorAuthDeleteFailedAfterBatch;
    case AccountDeleteFlowMode.readOnly:
      return accountDeleteErrorAuthDeleteFailedAfterReadOnlyBatch;
  }
}
