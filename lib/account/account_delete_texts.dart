/// Static Dutch copy for the (not yet functional) account-deletion flow.
///
/// Fase 2 scope: this file only holds text and a small pure helper to pick
/// the right text for a given household state. It performs no Firestore or
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
    'Dit huishouden is al read-only.\n\n'
    'Als jij als laatste gebruiker je account verwijdert, kan het '
    'read-only huishouden definitief worden verwijderd.\n\n'
    'Maak eerst een CSV- of PDF-export als je de administratie wilt '
    'bewaren.';

const String accountDeleteIntroSolo =
    'Als je je account verwijdert, verlies je toegang tot KiDu.\n\n'
    'Er is geen gekoppelde co-parent die toegang moet houden tot gedeelde '
    'administratie.';

/// Returns the explanation text for [state]. `activeSolo` and `noHousehold`
/// intentionally share the same (no co-parent claim) copy.
String accountDeleteIntroFor(AccountDeleteHouseholdState state) {
  switch (state) {
    case AccountDeleteHouseholdState.activeWithCoParent:
      return accountDeleteIntroActiveWithCoParent;
    case AccountDeleteHouseholdState.readOnly:
      return accountDeleteIntroReadOnly;
    case AccountDeleteHouseholdState.activeSolo:
    case AccountDeleteHouseholdState.noHousehold:
      return accountDeleteIntroSolo;
  }
}

const String accountDeleteExportAdvice =
    'Wil je je administratie bewaren? Exporteer eerst je gegevens via '
    'Logboek.';

const String accountDeleteExportButtonLabel = 'Open Logboek';

const String accountDeletePreparationBody =
    'Definitieve verwijdering wordt in een volgende stap toegevoegd. Deze '
    'knop wordt pas actief zodra de veilige verwijderflow is gebouwd — er '
    'gebeurt hier nu nog niets.';

const String accountDeletePreparationButtonLabel = 'Nog niet beschikbaar';
