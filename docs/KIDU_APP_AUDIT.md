# KiDu — Complete App Audit

**Datum:** 2026-08-10  
**Reconciliatie:** 2026-08-10 (tegenstrijdigheden opnieuw gecontroleerd tegen actuele working tree op `main`)  
**Bron:** actuele codebase op `main` (analyse-only)  
**Scope:** inventarisatie vóór bredere testfase en Google Play  
**Niet gebruikt:** stash `pre-reset-balance-rebuild-backup`

**Reconciliatie-samenvatting (feiten uit repo):**

| Onderwerp | Eerdere drift in audit | Feitelijke conclusie |
|---|---|---|
| Adaptive icons | Checklist-formulering kon als “aanwezig” gelezen worden | ❌ Ontbreken (`mipmap-anydpi-v26` / adaptive XML afwezig; alleen legacy `ic_launcher.png`) |
| Privacy `docs/` vs in-app | Checklist-formulering kon als “synchroon” gelezen worden | ❌ `docs/privacy_policy.md` (2026-02-18) loopt inhoudelijk achter op in-app (2026-07-20) |
| Maandelijkse materialisatie | Audit baseerde zich op stale comment “nog niet live” | ✅ Runner is live (cold start, resume, create/unpause-triggers) |
| Firebase `kidu-dev-*` | Soms als automatische blocker gelezen | FEIT: projectId `kidu-dev-d69fb`. BESLISSING: eigenaar bevestigt of dit de bedoelde omgeving is |

---

## Inhoudsopgave

1. [App-overzicht](#1-app-overzicht)
2. [Complete feature-inventarisatie](#2-complete-feature-inventarisatie)
3. [Gebruikersflows](#3-gebruikersflows)
4. [Financieel model](#4-financieel-model)
5. [Data / Firestore](#5-data--firestore)
6. [Security / Rules](#6-security--rules)
7. [UI / KiDu design system](#7-ui--kidu-design-system)
8. [Terminologie / copy-audit](#8-terminologie--copy-audit)
9. [Empty states](#9-empty-states)
10. [Read-only](#10-read-only)
11. [Error handling / validation](#11-error-handling--validation)
12. [Testinventarisatie](#12-testinventarisatie)
13. [Codebase health](#13-codebase-health)
14. [Safe cleanup opportunities](#14-safe-cleanup-opportunities)
15. [Privacy / release-relevante zaken](#15-privacy--release-relevante-zaken)
16. [Android / Google Play readiness](#16-android--google-play-readiness)
17. [Dependency audit](#17-dependency-audit)
18. [Pre-release risicoanalyse](#18-pre-release-risicoanalyse)
19. [Testplan voor echte gebruikers](#19-testplan-voor-echte-gebruikers)
20. [Google Play checklist](#20-google-play-checklist)
21. [Wat is al echt af?](#21-wat-is-al-echt-af)
22. [Aanbevolen route vanaf huidige staat](#22-aanbevolen-route-vanaf-huidige-staat)

---

## 1. App-overzicht

KiDu is een Flutter-app voor **twee co-ouders** die gedeelde kind-uitgaven bijhouden en onderling verrekenen.

| Vraag | Antwoord uit code |
|---|---|
| Wat is KiDu? | Minimale co-parent administratie: huishouden, kinderen, uitgaven, verdeling, balans, betalingen met bevestiging, logboek/export. |
| Voor wie? | (Co-)ouders / volwassenen (privacybeleid: niet voor kinderen). Exact twee ouders per huishouden in de productflows. |
| Primair probleem | Wie wat betaalde, wat ieders aandeel is, en wie wie nog tegoed heeft — zonder losse spreadsheets. |
| Gebruikerswaarde | Gedeelde waarheid over uitgaven + balans + pending betalingen + audit/export. |
| Kernonderdelen | Auth (Google) → huishouden/invite → dashboard/balans → uitgaven → betalingen → Logboek → instellingen (kinderen, verdeling, maandelijkse masters, privacy, account delete). |

Stack: Flutter + Firebase Auth + Cloud Firestore + Cloud Functions (`europe-west1`). Package: `com.anne.kidu`. Versie: `0.1.0+2`.

---

## 2. Complete feature-inventarisatie

Legenda: ✅ aanwezig · ⚠️ gedeeltelijk / aandachtspunt · ❌ relevant maar niet aanwezig

### 2.1 Authenticatie / account

| Item | Status | Details |
|---|---|---|
| Google sign-in | ✅ | `LoginPage` → `GoogleSignIn` + Firebase credential |
| Profielnaam | ✅ | Verplicht na login; onboarding-card op dashboard of `ProfileNamePage` |
| Uitloggen | ✅ | Settings; ook via reopen-lock |
| Account wisselen | ⚠️ | Geen aparte switch-account UI; wel uitloggen + opnieuw inloggen |
| Account verwijderen | ✅ | Settings → `AccountDeleteInfoPage` + controller; modes: co-parent / solo / geen HH / read-only |
| Firestore-write | ✅ | `users/{uid}` (profileName, householdId, …); delete via CF bij read-only last member |

**Edge-cases:** login network/generic errors; Google cancel stil; re-auth verplicht bij delete (`VERWIJDEREN` keyword).

### 2.2 Huishouden

| Item | Status | Details |
|---|---|---|
| Auto-create solo HH | ✅ | Na naam: `_kiduEnsureHouseholdForCurrentUserIfNeeded` |
| Invite code (8 chars) | ✅ | `invites/{code}`; max 2 members |
| Invite delen | ✅ | `Share.share` |
| Join via SetupPage | ✅ | Transactie: member + `usedBy`; cleanup oud solo HH (CF best-effort) |
| `isConnected` flip | ⚠️ | Client-write uitgecommentarieerd (`TODO(re-enable after rules alignment)`) |
| >2 ouders | ❌ | Productmodel = 2; UI/rules gaan uit van 2 participants |

### 2.3 Co-parent

| Item | Status | Details |
|---|---|---|
| Koppelen via invite | ✅ | Dashboard solo: Uitnodigen / Koppelen |
| Naam tonen | ✅ | `profileName` / fallback `Co-parent` |
| Gelijke rechten | ✅ | Geen admin-rol |

### 2.4 Onboarding

| Item | Status | Details |
|---|---|---|
| Login → naam → HH | ✅ | AuthGate toont altijd Dashboard; naam ontbreekt → onboarding-card |
| Eerste bruikbare state | ✅ | Solo: invite UI; gekoppeld: BalanceCard + recente uitgaven |

### 2.5 Dashboard

| Item | Status | Details |
|---|---|---|
| BalanceCard | ✅ | Status + pending + tap-flows |
| Recente uitgaven | ✅ | Navigatie naar detail |
| FAB Logboek / + | ✅ | `+` alleen als `canMutateHousehold` |
| Laatste activiteit | ✅ | Optionele muted regel |
| Read-only badge/banner | ✅ | Via `ReadOnlyAppBarTitle` / banner |

### 2.6 Balans

| Item | Status | Details |
|---|---|---|
| Berekende balans | ✅ | `computeHouseholdBalance` |
| Statuscopy tegoed | ✅ | `balanceCreditLine` |
| Info → Balansopbouw | ✅ | Altijd (ook read-only) |
| Pending isolatie | ✅ | Pending telt niet mee in `balanceCents` |

### 2.7 Balansopbouw

| Item | Status | Details |
|---|---|---|
| Status + bedrag | ✅ | `BalansopbouwPage` |
| Pending-regel | ✅ | “Betaling gemeld · telt nog niet mee…” |
| UITGAVEN / AANDEEL | ✅ | Betaald vs fair share per ouder + uitgavenconclusie |
| BETALINGEN | ✅ | Beide richtingen (settlements + confirmed) + betalingsconclusie |
| Read-only | ✅ | Puur inzage; geen mutatie-acties |

### 2.8 Uitgaven

| Item | Status | Details |
|---|---|---|
| Nieuwe uitgave | ✅ | Titel, bedrag EUR, kinderen (“Voor wie?”), optionele private notitie, split-snapshot |
| Betaler | ⚠️ | Altijd huidige user (`createdBy`); geen “andere ouder betaalde”-selector |
| Datum | ⚠️ | Geen aparte expense-datum in create UI; `createdAt` server timestamp |
| Wijzigen | ✅ | Creator-only; 15 min silent; daarna reason + audit |
| Hard delete uitgave | ❌ | Rules: `allow delete: if false` |
| Bedrag naar 0 | ⚠️ | Update rules staan `amountCents >= 0` toe |

### 2.9 Uitgavenverdeling

| Item | Status | Details |
|---|---|---|
| HH-default settings | ✅ | `settings/defaults` + `HouseholdSplitSettingsPage` (0–100%) |
| Snapshot op nieuwe uitgave | ✅ | `ParentSplitSnapshot` / `buildSnapshotForNewExpense` |
| Per-uitgave override | ✅ | Bij create/edit (waar UI dat toelaat) |
| Legacy 50/50 | ✅ | Geen/ongeldige snapshot of viewer geen participant |

### 2.10 Maandelijkse / terugkerende uitgaven

| Item | Status | Details |
|---|---|---|
| Masters UI | ✅ | Settings → “Maandelijkse uitgaven” (`_TerugkerendeKostenPage`) |
| Create/edit/pause/delete master | ✅ | Creator-only; private notes; split fields |
| Automatische materialisatie | ✅ | **Live** via `_RecurringMaterializationRunner` |
| Triggers | ✅ | Cold start (post-frame), app resume, na create (start=vandaag), na unpause |
| Scope runner | ⚠️ | Alleen masters van de **huidige user** (`createdBy == uid`); stil (geen snackbar) |
| Server cron | ❌ | Geen Cloud Scheduler / server-side periodieke job — materialisatie is client-triggered |

> **Gebruikersverwachting:** Ja, een normale gebruiker mag denken dat een actieve maandelijkse uitgave automatisch perioden oplevert — **mits de maker de app opent/hervat** (of net heeft opgeslagen met startdatum vandaag). Het is geen server-cron die draait terwijl niemand de app gebruikt.
>
> Let op: een comment bij de write-helper (~18480, “nog niet live / geen runner”) is **verouderd** t.o.v. de actuele wiring in `KiDuApp` + runner.

### 2.11 Betalingen

| Item | Status | Details |
|---|---|---|
| Betaling melden | ✅ | Altijd `fromUserId = viewer` → `toUserId = other`; status `pending` |
| Prefill | ✅ | Alleen bij `balanceCents < 0` → `abs(balance)`; +/0 → leeg |
| Bevestigen | ✅ | Ontvanger; confirm dialog “Ontvangst bevestigen” |
| Wijzigen pending | ✅ | Melder; 15 min silent / daarna reason + revision + amountEdits |
| Annuleren/verwijderen pending | ✅ | Melder; hard-delete + amountEdits; confirm dialog |
| Afwijzen door ontvanger | ❌ | Geen reject-flow; ontvanger kan alleen bevestigen (melder kan verwijderen) |
| Meerdere pendings | ⚠️ | Zie §5-detail hieronder / sectie risico’s — UI soft-block; rules geen hard max |
| Settlements | ⚠️ | Alleen lezen (legacy); rules blokkeren create/update/delete |

#### Meerdere pending payments (feitelijk)

| Vraag | Antwoord uit code |
|---|---|
| Kunnen meerdere pendings in Firestore bestaan? | **Ja** — rules eisen alleen `status==pending` + `fromUserId==auth.uid`; geen “max 1” |
| Per richting? | Ja: A→B en B→A kunnen tegelijk pending zijn |
| Blokkeert UI een tweede outgoing? | **Ja soft:** enige create-path is BalanceCard-melden; bij bestaande outgoing opent body-tap wijzigen/verwijderen i.p.v. nieuw melden |
| Blokkeren rules een tweede? | **Nee** |
| Wat toont BalanceCard? | Max. **één** incoming + **één** outgoing (eerste match in stream) |
| Kunnen betalingen “onzichtbaar” lijken? | Alleen bij race/extra docs buiten de “eerste”: card mist ze; **Logboek → Betalingen** toont wel alle (incl. “In afwachting”) |
| Risico | **Middel/rand** — normale happy path 1 pending per melder; Logboek als vangnet |

### 2.12 Pending-statussen

| Item | Status | Details |
|---|---|---|
| Incoming card | ✅ | “Er is een betaling gemeld” + bevestig-hint |
| Outgoing card | ✅ | “Betaling gemeld” + “Wacht op bevestiging” |
| Prioriteit | ✅ | Incoming wint over outgoing in card-copy |

### 2.13 Logboek

| Item | Status | Details |
|---|---|---|
| Tabs | ✅ | Uitgaven · Wijzigingen · Betalingen |
| Filters | ✅ | Kind / ouder / periode |
| Export CSV/PDF | ✅ | Per actieve tab via `pdf` + `share_plus` |
| Audit merge | ✅ | amountEdits + expenseChanges (+ changeBatchId) |

### 2.14 Instellingen / profiel / privacy

| Item | Status | Details |
|---|---|---|
| Kinderen | ✅ | Add / rename / archive / soft-delete / restore |
| Uitgavenverdeling | ✅ | Slider 0–100% |
| Maandelijkse uitgaven | ✅ | Masters-lijst |
| Logboek | ✅ | Altijd bereikbaar |
| Privacy & beveiliging | ✅ | Screenshot-blok (FLAG_SECURE) + reopen-lock (biometrie/device credential) |
| Privacybeleid in-app | ✅ | `_privacyPolicyFull` (2026-07-20) |
| Over KiDu | ✅ | Settings |
| Naam wijzigen | ✅ | Geblokkeerd in read-only |

### 2.15 Read-only gedrag

| Item | Status | Details |
|---|---|---|
| Flag `households.isReadOnly` | ✅ | UI + rules |
| Inzage + export | ✅ | |
| Mutaties geblokkeerd | ✅ | Client + rules |

Zie sectie 10.

### 2.16 Notificaties / invitations / export / deeplinks

| Item | Status | Details |
|---|---|---|
| Push / FCM | ❌ | Geen Firebase Messaging |
| In-app pending “notification” | ✅ | UI-woord voor pending payment |
| Invitations | ✅ | Invite codes |
| Export | ✅ | Logboek CSV/PDF |
| Deeplinks / App Links | ❌ | Alleen MAIN/LAUNCHER |

### 2.17 Overige

| Item | Status | Details |
|---|---|---|
| Private notes | ✅ | Expense + recurring; optioneel delen met co-parent |
| Cloud Functions | ✅ | Account/HH cleanup callables |
| Offline write-gate | ✅ | `_checkCanWriteNow` (server get users/{uid}) |

---

## 3. Gebruikersflows

### 3.1 Nieuwe gebruiker

1. **Login** — `LoginPage`: Google → Firebase Auth → post-sign-in handoff.
2. **Naam** — Ontbreekt `profileName` → onboarding-card op dashboard; opslaan naar `users/{uid}`.
3. **Huishouden** — Bootstrap solo HH (`isConnected: false`) + `members/{uid}` + `users.householdId`.
4. **Co-parent** — Uitnodigen (code + share) of SetupPage “Koppelen” met code.
5. **Eerste dashboard** — Solo: invite/setup. Gekoppeld: BalanceCard (vaak €0 / “Jullie zijn in balans”) + “Nog geen uitgaven…”.

### 3.2 Nieuwe uitgave

1. FAB `+` (alleen muteerbaar HH).
2. Dialog: titel (max 60), bedrag (EUR→cents, >0), kinderen (≥1), optionele notitie (+ delen), split.
3. Online-check `_checkCanWriteNow`.
4. Write `expenses` (+ optional `privateNotes` + mirror `privateNoteSharedWithUids`).
5. Split-snapshot uit override of HH-defaults; bij falen: legacy pad zonder snapshot.
6. Resultaat: lijst + balans herberekenen via streams.

### 3.3 Uitgave wijzigen

- **Wie:** alleen `createdBy`.
- **Wat:** titel, bedrag, kinderen, split (waar UI/rules dat toestaan).
- **15 min** na create: silent (geen reason/audit).
- **Daarna:** reason verplicht → batch `amountEdits` / `expenseChanges` + `hasAuditHistory`.
- Effect: balans volgt nieuwe bedragen/shares; history zichtbaar in detail + Logboek Wijzigingen.

### 3.4 Betaling melden (actueel)

| Situatie | Prefill | from → to | Confirm | Pending |
|---|---|---|---|---|
| Geen pending + negatieve balans | `abs(balanceCents)` | viewer → other | Dialog “Melden” | Ja |
| Geen pending + positieve balans | Leeg | viewer → other | Idem | Ja |
| Geen pending + nulbalans | Leeg | viewer → other | Idem | Ja |
| Al outgoing pending | Card opent wijzigen/verwijderen | — | — | Blijft |
| Al incoming pending | Card opent bevestigen | — | — | Blijft |

Belangrijk: richting **flipt nooit** met het tekensaldo; de melder is altijd de huidige user.

### 3.5 Outgoing pending

- Card: “Betaling gemeld” / “Wacht op bevestiging”.
- Sheet: Wijzigen / Verwijderen.
- Voorwaarden: `status==pending`, `fromUserId==createdBy==viewer`, stale amount/revision checks.
- Balans verandert **niet** tot confirm.

### 3.6 Incoming pending

- Card: “Er is een betaling gemeld”.
- Sheet → dialog “Ontvangst bevestigen”.
- Geen afwijzen in UI.
- Na confirm: `status=confirmed`, `confirmedAt/By` → telt mee in balans.

### 3.7 Balans (dashboard)

- Copy via `balanceCreditLine`.
- Body-tap: incoming → outgoing → melden (prioriteit).
- Info-knop → Balansopbouw (los van body-tap).
- Read-only: `onBodyTap=null`, `showReportHint=false`; info blijft.

### 3.8 Balansopbouw

1. Huidige balansstatus + bedrag.
2. Optioneel pending-statusregel.
3. Card **UITGAVEN | AANDEEL** per ouder + mute “verdeling per uitgave” + uitgavenconclusie.
4. Card **BETALINGEN** beide richtingen + betalingsconclusie.
5. Read-only pagina (geen writes).

### 3.9 Logboek

- Tabs Uitgaven / Wijzigingen / Betalingen.
- Filters kind/ouder/periode.
- Export icoon → CSV/PDF share.
- Empty: “Geen … gevonden”.

---

## 4. Financieel model

Bron: `lib/balance/household_balance.dart` + `lib/split/parent_split.dart`.

### 4.1 `HouseholdBalanceResult`

| Veld | Betekenis |
|---|---|
| `totalExpenseCents` | Som alle uitgaven |
| `paidByViewerCents` / `paidByOtherCents` | Betaald door viewer vs other (`createdBy`) |
| `fairShareViewerCents` / `fairShareOtherCents` | Verwacht aandeel |
| `expenseBalanceCents` | `paidByViewer − fairShareViewer` (expense-only) |
| `confirmedPaidByViewerCents` / `ToViewer` | Bevestigde payments |
| `settlementPaidByViewerCents` / `ToViewer` | Legacy settlements |
| `balanceCents` | Full balance |

### 4.2 Formule (productie)

```
balanceCents =
  expenseBalanceCents
  + settlementPaidByViewer − settlementPaidToViewer
  + confirmedPaidByViewer − confirmedPaidToViewer
```

Pending payments zijn **bewust uitgesloten**.

### 4.3 Tekenconventie

| `balanceCents` | Betekenis (viewer-perspectief) |
|---|---|
| `> 0` | Je hebt tegoed van co-parent (co-parent “betaalt jou” / is jou iets schuldig) |
| `< 0` | Co-parent heeft tegoed van jou |
| `0` | In balans |

Wanneer verandert de balans? Nieuwe/gewijzigde uitgaven; bevestigde betaling; (legacy) settlements. **Niet** bij melden/wijzigen/verwijderen van pending.

### 4.4 Legacy 50/50

Zonder geldige snapshot (of viewer geen participant):

- `halfFloor = total ~/ 2`
- Odd cent remainder gaat naar de ouder die **minder** heeft betaald in de legacy-groep

### 4.5 ParentSplitSnapshot

- Velden: `parentSplitParticipantUids[2]`, `parentSplit0ShareBps` (0…10000).
- Rounding: participant[0] = `floor(amount * bps / 10000)`; participant[1] = remainder (som exact).
- 100/0 en 0/100 toegestaan.
- Stale HH-settings → expliciet neutraal 50/50 snapshot voor actuele 2 members (oude bps nooit op andere uid).

### 4.6 Wanneer een gemelde betaling WEL telt

Pas na `status: confirmed` door `toUserId`. Dan: `+confirmedPaidByViewer` of `−confirmedPaidToViewer` afhankelijk van richting.

---

## 5. Data / Firestore

| Pad | Belangrijke velden | Wie schrijft | Mutable? |
|---|---|---|---|
| `users/{uid}` | profileName, householdId, email, photoUrl, timestamps | Eigen uid | Update beperkt; delete false |
| `households/{id}` | name, createdBy, isConnected, isReadOnly(+meta) | Members (beperkt) | isConnected→true; isReadOnly false→true |
| `…/members/{uid}` | role, joinedAt | Self create/delete | Update false |
| `…/children/{id}` | name, isArchived, isDeleted, deletedAt | Members | Soft-delete; hard delete false |
| `…/expenses/{id}` | amountCents, title, createdBy, childIds, split snapshot, privateNoteSharedWithUids, hasAuditHistory | Create: any member; update: creator | Hard delete false |
| `…/expenses/…/amountEdits` | from/to cents, reason, editedBy/At, changeBatchId | Creator | Immutable |
| `…/expenses/…/expenseChanges` | children/split audit + reason | Creator | Immutable |
| `…/expenses/…/privateNotes/{uid}` | note, sharedWithUids, updatedAt | Creator slot | |
| `…/payments/{id}` | amountCents, from/to, status, revision, confirmed* | Create: from=self pending; update: confirm of amount+revision; delete: pending melder | |
| `…/payments/…/amountEdits` | history | Melder (met payment update) | Delete alleen met parent delete |
| `…/settlements/{id}` | amountCents, debtorUid, creditorUid | Client: **geen** writes | Read-only legacy |
| `…/recurringExpenses/{id}` | master fields + split + status active/paused | Creator | Delete creator |
| `…/settings/defaults` | share0/1Uid, share0Bps, updatedAt/By | Any member | Delete false |
| `invites/{code}` | householdId, createdBy, usedBy, usedAt | Create member; claim usedBy | |

---

## 6. Security / Rules

Bestand: `firestore.rules`.

### Sterke punten

- Auth verplicht; household membership gate op HH-data.
- Read-only blokkeert writes breed.
- Payments: alleen melder create/edit/delete pending; alleen ontvanger confirm; revision/stale checks.
- Expense update creator-only; private notes sterk beperkt.
- Settlements: geen client writes.
- Privilege-keys (`role`/`isAdmin`) geblokkeerd op users.

### Bevindingen

| Bevinding | Classificatie | Bewijs |
|---|---|---|
| Invite `get` voor elke signed-in user (code-probe mogelijk) | Middel | `match /invites/{code}` allow get if signed in |
| Expense update staat `amountCents >= 0` toe (nulzetten) | Middel | expense update rule |
| Meerdere pendings mogelijk in data; UI soft-blockt tweede outgoing via BalanceCard; Logboek toont alle | Middel | rules geen max; `_startPaymentsSubscription` neemt eerste; Logboek `_buildPaymentList` |
| Geen receiver-reject (by design) | Laag | Geen reject-path in rules/UI |
| Settlements immutable client-side | Geen probleem | create/update/delete false |
| Read-only false→true only | Geen probleem | household update path |
| Users hard-delete false (cleanup via CF) | Geen probleem | Account-delete architectuur |

Geen speculatieve claims buiten rules/code.

---

## 7. UI / KiDu design system

### Theme (`buildKiduTheme`)

- Material 3, light only.
- Seed `#2F3E46` (warm slate); scaffold `#F7F6F4`.
- AppBar: flat, zelfde bg, elevation 0, geen surfaceTint.
- Cards: wit surface, radius **18** (`_cardRadius`), lichte elevation (~0.4) + outline.

### Helpers / components

| Helper | Rol |
|---|---|
| `KiduCard` | Standaard kaart |
| `KiduCodePill` | Invite-code weergave |
| `kiduCompactInputDecoration` | Dense inputs, radius 12 |
| `kiduActionDialogTitle` | Dialog titles |
| `kiduDialogPrimaryButtonStyle` / `kiduFormPrimaryButtonStyle` | Soft filled primary |
| `onSurface` / `outlineV` + alpha-constanten | Muted copy |
| `ReadOnlyBadge` / `ReadOnlyAppBarTitle` / `ReadOnlyExplanationBanner` | Read-only UI |
| `balanceCreditLine` | Gedeelde balanscopy |
| `_formatEur` / detail formatters | `€x,yy` |

### Patronen

- Bottom sheets radius top 20; drag handle.
- Dialogs: Annuleren TextButton + Filled primary.
- Spacing: page padding 16; max content width ~520.
- Icons: outlined Material (info, edit, delete, percent, child_care, event_repeat).

### Referentieschermen (meest consistent)

1. **BalansopbouwPage** — heldere typography/muted/outcomes.
2. **BalanceCard** — compacte KiDu-card taal.
3. **Settings** — KiduCard + muted section headers.
4. **Expense/Payment detail** — Card-constructie gelijk aan Balansopbouw.

---

## 8. Terminologie / copy-audit

| Term | Gebruik | Consistentie |
|---|---|---|
| Balans | Card-titel, Balansopbouw | ✅ |
| tegoed | “Je hebt tegoed van…”, “…heeft tegoed van jou” | ✅ |
| In balans / Jullie zijn in balans | zeroLine-varianten | ✅ bewust (kort vs hero) |
| Betaling melden / gemeld | Card + sheets | ✅ |
| Ontvangst bevestigen | Incoming confirm | ✅ |
| Wacht op bevestiging | Outgoing | ✅ |
| Uitgaven / Aandeel / Verdeling | Balansopbouw + settings | ✅ |
| Co-parent | Fallback-naam + privacy | ✅ |
| Logboek | Settings + FAB | ✅ |
| Wijzigen / Verwijderen / Annuleren | Sheets/dialogs | ✅ |
| Read-only / alleen-lezen | Badge “Read-only”; join-fout “alleen-lezen” | ⚠️ Engels badge vs NL body |
| alleen inzage | Exacte UI-string **niet** gevonden | — |
| Oude “betaalt jou / Jij betaalt” | Bewust weg (tests checken afwezigheid) | ✅ |

**Aandachtspunt:** badge-label `Read-only` (EN) naast NL-uitleg.

**Privacy sync (één conclusie):** `docs/privacy_policy.md` (2026-02-18) **loopt inhoudelijk achter** op in-app `_privacyPolicyFull` (2026-07-20). Zie sectie 15.

---

## 9. Empty states

| Situatie | Wat ziet gebruiker? | Actie? | Compleet? |
|---|---|---|---|
| Geen uitgaven | “Nog geen uitgaven. Voeg er één toe met +.” / RO: zonder + | FAB + | ✅ |
| Nulbalans | “Jullie zijn in balans” + €0,00 + melden-hint | Melden mogelijk | ✅ |
| Leeg Logboek | “Geen … gevonden” | Filters/export | ✅ |
| Geen co-parent | Invite/setup UI | Uitnodigen/koppelen | ✅ |
| Geen HH / bootstrap | Wordt aangemaakt na naam | — | ✅ |
| Geen kinderen | “Nog geen kinderen…” | + | ✅ |
| Geen maandelijkse | “Nog geen maandelijkse uitgaven” | + | ✅ Masters + live materialisatie bij open/resume |
| Nog geen wijzigingen (audit) | “Nog geen wijzigingen” | — | ✅ |
| Loading/error | Streams + snackbars via `mapUserFacingError` | Retry impliciet | ⚠️ Geen uniforme error-screens |

---

## 10. Read-only

Trigger: `households/{id}.isReadOnly == true` (vaak na account-delete van co-parent).

| Oppervlak | Disabled | Nog wel |
|---|---|---|
| Dashboard | FAB +, payment body-tap, mutaties | Bekijken, info→Balansopbouw, Logboek |
| BalanceCard | `onBodyTap=null`, geen report-hint | Info-knop |
| Uitgaven | Geen create/edit writes (rules + UI) | Detail lezen |
| Betalingen | Geen melden/confirm/edit/delete | Historie lezen |
| Balansopbouw | N.v.t. (altijd read) | Volledig |
| Logboek | Geen writes; export wel | Tabs/filters/export |
| Settings | Kinderen/verdeling/maandelijks/naam verborgen of disabled | Logboek, privacybeleid, account delete, uitloggen |

Banner: *“Dit huishouden is beëindigd. Je kunt bestaande gegevens bekijken en exporteren…”*

---

## 11. Error handling / validation

| Domein | Gedrag | UX-risico |
|---|---|---|
| Bedragen | `_tryParseEurToCents`; >0 vereist op create/payment | Lege/ongeldige input → disabled knop / errorText |
| Negatief/nul | Geblokkeerd in UI create; rules amountCents >0 (create) | Update expense ≥0 (nul) mogelijk via rules |
| Verplichte velden | Titel, kinderen, reason na 15 min | ✅ |
| Offline | `_checkCanWriteNow` blokkeert writes | ✅ duidelijke snackbar |
| Firestore failures | `mapUserFacingError` (permission, network, StateError) | ✅ |
| Stale payment | Specifieke NL-messages | ✅ |
| Ontbrekende namen | Fallbacks Ouder / Co-parent | ✅ |
| Confirm dialogs | Melden, bevestigen, verwijderen, account delete | ✅ |
| Login | Network vs generic; cancel stil | ✅ |

Classificatie UX: **geen P0**. Bekende randrisico’s: race op meerdere pendings (Logboek vangnet); client-triggered maandelijkse materialisatie (alleen als maker-app draait).

---

## 12. Testinventarisatie

| Bestand | Type | Dekking |
|---|---|---|
| `test/household_balance_test.dart` | Unit | Legacy rounding, splits 50/60/40/100/0, payments, settlements, parity |
| `test/parent_split_test.dart` | Unit | fairShare, bps validatie, tryRead |
| `test/balance_card_test.dart` | Widget | Copy +/ − /0, pending, taps, read-only, info→Balansopbouw |
| `test/balansopbouw_page_test.dart` | Widget | Status, pending, mapping, splits, betalingen, overflow/a11y |
| `test/widget_test.dart` | Smoke | LoginPage ✅; ProfileNamePage/SetupPage **skip: true** |

### Sterk

- Financieel model + BalanceCard/Balansopbouw copy/regressie goed afgedekt.

### Gaten (prioriteit = echte risico’s)

1. Geen geautomatiseerde payment write/confirm/delete flow-tests (Firebase-gekoppeld).
2. Geen rules-emulator suite in repo.
3. Geen end-to-end invite/join/account-delete tests.
4. Recurring materialisatie: **live in code**, maar weinig/geen geautomatiseerde tests.
5. Skipped smoke pages door Firebase singleton koppeling.

**Aanbeveling:** geen massale test-expansie; wel handmatige matrix (sectie 19) + eventueel later 1–2 targeted payment/revision unit tests zonder Firebase.

---

## 13. Codebase health

| Observatie | Beoordeling |
|---|---|
| `lib/main.dart` ≈ 21k regels | Groot, maar bewust “niet abstraheren zonder noodzaak”; niet automatisch schuld |
| Modules buiten main | balance, split, read_only, account, privacy, ui, formatting — nuttig |
| Duplicate helpers | Gedeelde payment/expense edit dialogs; sommige formatters lokaal |
| TODO | 1: `isConnected` update her-enablen |
| Recurring | Runner + write-laag **live**; stale comment bij write-helper nog “nog niet live” |
| Stale comments | Balansopbouw “empty shell in stap 1”; materialisatie-helper header “nog niet live” |
| CI | `.github/workflows/flutter-ci.yml` aanwezig |

Concrete onderhoudsrisico’s: navigatie/zoeken in één groot bestand; payment UI diep genest in dashboard builder.

---

## 14. Safe cleanup opportunities

| Kandidaat | Waarom | Zekerheid | Risico verwijderen |
|---|---|---|---|
| Comment “empty shell in stap 1” bij Balansopbouw | Verouderd | Hoog | Laag (alleen comment) |
| Comment “nog niet live” bij materialisatie write-helper (~18480) | Verouderd t.o.v. live runner | Hoog | Laag (alleen comment) |
| `_isWithinExpenseAmountCorrectionWindow` alias | Dunne wrapper | Middel | Laag–middel (rename-churn) |
| Day9 signing audit doc claims | Stale t.o.v. Gradle | Middel | Laag (docs) |
| Skipped widget tests | Dead weight | Middel | Laag, of beter: seams toevoegen |

**Geen code verwijderd in deze audit.**

---

## 15. Privacy / release-relevante zaken

### 15.1 Privacybeleid: docs vs in-app (één conclusie)

| Bron | Datum | Status |
|---|---|---|
| In-app `_privacyPolicyFull` (`lib/main.dart`) | 2026-07-20 | ✅ Actuele productwaarheid voor gebruikers in de app |
| `docs/privacy_policy.md` | 2026-02-18 | ❌ **Loopt inhoudelijk achter** — niet synchroon |

| Onderwerp | In-app | `docs/privacy_policy.md` |
|---|---|---|
| Contact `meershoek@gmail.com` | ✅ | ✅ |
| Google sign-in gegevens | ✅ | ✅ |
| Kinderen | ✅ | ❌ ontbreekt |
| Betalingen / verrekeningen | ✅ | ❌ ontbreekt |
| Account deletion in-app + Google re-auth | ✅ | ❌ (alleen e-mail + 30 dagen) |
| Co-parent → read-only voor achterblijver | ✅ | ❌ |
| Cloud Functions / HH-wipe last member | ✅ | ❌ (geen Functions genoemd) |
| Export Logboek CSV/PDF vóór delete | ✅ | ❌ |
| Biometrie / reopen-lock | ❌ ontbreekt | ❌ ontbreekt |
| Screenshot-blok (FLAG_SECURE) | ❌ ontbreekt | ❌ ontbreekt |

**Conclusie:** niet synchroon. Voor Play: hosted policy moet de **in-app** tekst volgen (en bij voorkeur biometrie/screenshot aanvullen). `docs/privacy_policy.md` sync is release-werk, geen blocker voor een 2-account smoke.

### 15.2 Overige privacy/release feiten

| Onderwerp | Feit uit repo |
|---|---|
| Persoonsgegevens | Google account, profileName, HH, kinderen, uitgaven, betalingen, notes, invites |
| Firebase | Auth, Firestore, Functions; projectId `kidu-dev-d69fb` (zie §15.3) |
| Analytics / Crashlytics / Ads | **Niet** aanwezig |
| Logging | `debugPrint` vooral achter `kDebugMode` |
| Third-party | Google Sign-In, Firebase, share sheet, local_auth, pdf |
| Permissions | INTERNET, USE_BIOMETRIC |
| Screenshot block | Native FLAG_SECURE via method channel |
| Reopen lock | `local_auth` + SharedPreferences; fail-open |
| Account deletion | In-app + email contact; co-parent → read-only HH; last member → CF wipe |
| Data retention | Beschreven in in-app policy |

### 15.3 Firebase-omgeving — FEIT vs BESLISSING

**FEIT (uit repository):**

| Item | Waarde |
|---|---|
| `projectId` | `kidu-dev-d69fb` |
| Android options | `DefaultFirebaseOptions.android` in `lib/firebase_options.dart` |
| `google-services.json` | Aanwezig onder `android/app/` (zelfde package `com.anne.kidu`) |
| Functions region | `europe-west1` |
| Flavors / multi-project switch | Geen — één config in de app |

**BESLISSING (niet uit code afleidbaar):**

- Of `kidu-dev-d69fb` bewust de enige/test/productie-omgeving is.
- Of vóór publieke Play-release een apart productieproject nodig is.
- Een naam met `dev` bewijst **niet** automatisch dat de omgeving ongeschikt is voor productie — dat is een eigenaarskeuze.

Voor een 2-account acceptatietest: beide testers moeten **dezelfde** app-build (dus hetzelfde projectId) gebruiken.

---

## 16. Android / Google Play readiness

| Item | Status | Detail |
|---|---|---|
| applicationId | ✅ | `com.anne.kidu` |
| versionName / versionCode | ⚠️ | `0.1.0` / `2` — bump per Play-upload |
| minSdk / targetSdk / compileSdk | ✅ | Flutter defaults 24 / 36 / 36 |
| App label | ✅ | KiDu |
| Launcher icons (legacy mipmap) | ✅ | `ic_launcher.png` in hdpi–xxxhdpi |
| Adaptive icons | ❌ | Ontbreken: geen `mipmap-anydpi-v26`, geen adaptive XML/foreground; `pubspec` heeft alleen `adaptive_icon_background` zonder gegenereerde assets |
| Signing release | ✅ | `signingConfigs.release` + key.properties (gitignored) |
| Minify / ProGuard / R8 | ⚠️ | Uit — geen Play hard-fail |
| Network permission | ✅ | INTERNET |
| Biometric permission | ✅ | USE_BIOMETRIC |
| Firebase config | ⚠️ Controleren (beslissing) | Aanwezig; projectId `kidu-dev-d69fb` — zie §15.3 |
| Flavors | ✅ | Geen (single) |
| Orientation | ✅ | Locked portrait in `main()` via `SystemChrome.setPreferredOrientations` (niet via manifest) |
| Manifest exported | ✅ | Alleen launcher activity |
| Deeplinks | ✅ | Geen (niet nodig) |
| Edge-to-edge | ⚠️ | Standaard Flutter/activity; geen aparte productclaim |

---

## 17. Dependency audit

Bron: `pubspec.yaml` (geen upgrades uitgevoerd).

| Package | Gebruik | Privacy/release | Ongebruikt? |
|---|---|---|---|
| `firebase_core` / `firebase_auth` / `cloud_firestore` | Kern | Ja — Data Safety | Nee |
| `cloud_functions` | Account/HH cleanup | Ja | Nee |
| `google_sign_in` / `sign_in_button` | Login | Ja | Nee |
| `share_plus` | Invite + export | OS share | Nee |
| `pdf` | Logboek export | Lokaal | Nee |
| `shared_preferences` | Privacy prefs / reopen lock | Lokaal | Nee |
| `local_auth` | Reopen lock | Biometrie on-device | Nee |
| `flutter_launcher_icons` | Icon generatie | Dev tooling in deps | ⚠️ beter under dev_dependencies |
| `cupertino_icons` | Icons | Laag | Mogelijk beperkt gebruikt |

Platform: Android primaire release-target; iOS Firebase options aanwezig maar buiten deze audit-focus.

---

## 18. Pre-release risicoanalyse

Definities:

- **P0** — Blokkeert zelfs een interne 2-account test of maakt kerngegevens/berekeningen onbetrouwbaar.
- **P1** — Moet vóór bredere/externe testers worden opgelost of bewust uitgeschakeld/gedocumenteerd.
- **P2** — Bij voorkeur vóór publieke Google Play release.
- **P3** — Veilig na eerste release / post-v1.

Productfilosofie: *niet toevoegen omdat het kan; alleen als het vóór testen of release aantoonbaar waarde of veiligheid toevoegt.*

### P0 — Blocker

| # | Probleem | Impact | Bewijs | Vervolg | Scope |
|---|---|---|---|---|---|
| — | **Geen P0** in actuele code voor interne 2-ouder acceptatietest | — | Balansmodel getest; kernflows aanwezig; signing wired | Sectie 19 uitvoeren | — |

### P1 — vóór bredere/externe testers

| # | Probleem | Impact | Bewijs | Vervolg | Scope |
|---|---|---|---|---|---|
| 1 | Testers moeten maandelijks-gedrag **juist** verwachten | Verkeerde bugrapporten als “werkt niet offline/server” | Runner live, maar client-triggered + creator-only | Brief: open/hervat app van de maker; test scenario 10 | Klein (docs/brief) |
| 2 | Pending UX: geen receiver-reject; card toont max 1 per richting | Verwarring bij “ik wil afwijzen” of zeldzame extra pendings | Geen reject; soft UI-block; Logboek toont alle | Documenteer in testhandleiding (geen feature bouwen) | Klein (docs) |
| 3 | Beide testers op dezelfde Firebase-build/project | Data mist elkaar | Geen flavors; één `kidu-dev-d69fb` | Bevestig zelfde APK/AAB | Klein |

> Privacy-doc sync en adaptive icons zijn **geen P1 voor de 2-account test** (in-app policy + legacy icons volstaan). Wel P2 voor Play.

### P2 — vóór publieke Google Play

| # | Probleem | Impact | Bewijs | Vervolg | Scope |
|---|---|---|---|---|---|
| 1 | `docs/privacy_policy.md` niet synchroon + hosted URL nodig | Store/Data Safety mismatch | §15.1 | Sync docs → in-app; host URL; biometrie/screenshot overwegen | Klein–middel |
| 2 | Adaptive icons ontbreken | Android launcher look | §16 | Genereer adaptive icons | Klein |
| 3 | Firebase-omgeving bewust bevestigen | Verkeerde data/prod-keuze | §15.3 | Eigenaar-beslissing documenteren | Klein |
| 4 | versionCode/Name bump per upload | Store requirement | `0.1.0+2` | Bump bij release candidate | Klein |
| 5 | Meerdere pendings: rules zonder max (race-rand) | Zeldzaam onzichtbaar op card | §2.11 | Alleen fixen als test het raakt; anders post-v1 | Klein–middel |
| 6 | ProGuard/R8 uit | Grotere binary | build.gradle.kts | Optioneel enable + test — geen must | Middel |

### P3 — later / post-v1

- Receiver-reject feature (nu: melder verwijdert).
- Crashlytics / analytics (nu bewust afwezig).
- Pushmeldingen, deeplinks, betaler ≠ creator, aparte expense-datum.
- Grote `main.dart`-refactor zonder noodzaak.
- Massale Firebase UI/E2E-testinfrastructuur.
- `isConnected` client-update / README sync (cosmetisch/legacy).
- Stale comments opruimen.

---

## 19. Testplan voor echte gebruikers

Doel: twee co-ouders (A en B) kunnen dit volgen zonder codekennis.

### Voorbereiding

- [ ] Twee Google-accounts op twee toestellen/emulators.
- [ ] Bevestig dat beide **dezelfde** build gebruiken (projectId `kidu-dev-d69fb` tenzij anders besloten).
- [ ] Beide installeren dezelfde build (`0.1.0+2` of nieuwer).
- [ ] Tester-brief gelezen: geen receiver-reject; maandelijks = open/resume van de maker.

### Scenario 1 — Start & koppelen

1. A logt in met Google, kiest een voornaam, ziet solo-dashboard.
2. A maakt een uitnodigingscode en deelt die.
3. B logt in, kiest voornaam, koppelt met de code.
4. Beide zien elkaars naam op het dashboard en een nulbalans (“Jullie zijn in balans”).

### Scenario 2 — Uitgaven & verdeling 50/50

1. Settings → Uitgavenverdeling op 50/50 (of default laten).
2. A voegt kind(eren) toe.
3. A boekt €10,00 uitgave voor een kind.
4. B boekt €10,00 uitgave.
5. Controles: balans ~0; Balansopbouw toont UITGAVEN/AANDEEL logisch; Logboek toont beide.

### Scenario 3 — 60/40 en 100/0

1. Zet verdeling op 60/40; A boekt €100; check tegoed-richting in Balans + Balansopbouw.
2. Zet verdeling op 100/0; boekt nieuwe uitgave; check fair share (één ouder 100%).
3. Open Balansopbouw info-knop: pending-regel alleen als er pending is.

### Scenario 4 — Betaling melden / pending / bevestigen

1. Zorg dat A negatieve balans heeft (A is iets schuldig).
2. A tikt Balans → prefill ≈ openstaand bedrag → Melden → confirm.
3. A ziet “Wacht op bevestiging”; balans **ongewijzigd**.
4. B ziet “Er is een betaling gemeld” → Ontvangst bevestigen.
5. Beide: balans bijgewerkt; Logboek Betalingen = Bevestigd.

### Scenario 5 — Pending wijzigen / verwijderen

1. Maak opnieuw een pending (niet bevestigen).
2. Melder: Wijzigen bedrag (binnen 15 min zonder reden; daarna mét reden).
3. Melder: Verwijderen → pending weg, balans nog steeds zonder die betaling.
4. Probeer tegelijk bevestigen na wijziging → stale-foutmelding verwacht.

### Scenario 6 — Uitgave wijzigen & Logboek

1. Creator wijzigt bedrag/titel/kinderen.
2. Binnen 15 min: geen reden; daarna wél.
3. Logboek → Wijzigingen toont audit; export CSV/PDF deelt bestand.

### Scenario 7 — Nulbalans & positieve balans melden

1. Breng balans op 0 → melden-veld leeg; melden met handmatig bedrag mag.
2. Bij positieve balans: veld leeg; richting blijft “ik meld betaling aan co-parent”.

### Scenario 8 — Read-only / account

1. A exporteert Logboek.
2. A verwijdert account (co-parent mode) met Google-herbevestiging + `VERWIJDEREN`.
3. B: huishouden read-only; kan bekijken/exporteren, niet meer + of betalen.
4. B verwijdert daarna ook account (read-only pad) — alleen als testdata mag verdwijnen.

### Scenario 9 — App heropenen / privacy

1. Zet reopen-lock aan; verlaat app >60s; heropen → lock UI.
2. Screenshot-blok aan/uit (waar beschikbaar).
3. Airplane mode: write-actie → “Geen verbinding…”; daarna online opnieuw.

### Scenario 10 — Maandelijkse uitgaven (live materialisatie)

1. A maakt een actieve maandelijkse master (bij voorkeur startdatum vandaag of due-dag bereikbaar).
2. A forceert materialisatie door app volledig te sluiten en opnieuw te openen, of even naar achtergrond en terug (resume).
3. Verwacht: bij A verschijnt een echte uitgave-instance (deterministische id `rec_…`) die de balans beïnvloedt.
4. B opent de app: ziet dezelfde gematerialiseerde uitgave in het gedeelde huishouden.
5. Pauzeer master bij A → geen nieuwe toekomstige perioden; bestaande instances blijven.
6. Rapporteer als bug als **geen** instance verschijnt na open/resume van de **maker**, of als balans de instance negeert.

> Materialisatie is client-triggered (geen server-cron). Masters van B materialiseren wanneer **B** de app opent.

---

## 20. Google Play checklist

### Bevestigd uit code/repository

| Item | Status |
|---|---|
| `applicationId` `com.anne.kidu` | ✅ Gereed |
| Versie in pubspec `0.1.0+2` | ✅ Aanwezig (bump vóór upload) |
| Release signingConfig aanwezig | ✅ Gereed |
| Minimale permissions (INTERNET, USE_BIOMETRIC) | ✅ Gereed |
| Geen ads SDK | ✅ Gereed |
| Geen Analytics/Crashlytics SDK | ✅ Gereed (bewuste keuze) |
| In-app privacybeleid aanwezig | ✅ Gereed |
| In-app account deletion flow aanwezig | ✅ Gereed |
| Legacy launcher mipmap icons | ✅ Gereed |
| Portrait lock (Flutter `SystemChrome`) | ✅ Gereed |
| Adaptive icons | ❌ Ontbreken |
| `docs/privacy_policy.md` synchroon met in-app | ❌ Loopt achter (zie §15.1) |
| Firebase project bewust bevestigd als prod/test | ⚠️ Beslissing eigenaar (§15.3) |
| Maandelijkse materialisatie live | ✅ Live (client-triggered; test in scenario 10) |

### Release-checklist (niet uit code afleidbaar)

Markeer als proces/store-werk:

- [ ] Hosted privacy policy URL (publiek; inhoud = in-app + eventueel biometrie/screenshot)
- [ ] Play Console Data Safety form (Auth, persoonlijke info, financial info, account deletion, biometrics on-device, share/export)
- [ ] Content rating questionnaire
- [ ] Target audience / Designed for families (KiDu = volwassenen)
- [ ] Store listing: titel, korte/lange beschrijving, screenshots, feature graphic
- [ ] Support/contact e-mail in listing
- [ ] Internal / closed testing track upload (AAB)
- [ ] Crash-free smoke op release build
- [ ] Signing key / Play App Signing bevestigd
- [ ] versionCode bump per upload
- [ ] Bevestig geen debug/logging van PII in release
- [ ] Review account deletion wording vs co-parent read-only gedrag

---

## 21. Wat is al echt af?

### Productmatig af

- Google login + profielnaam + invite-huishouden (2 ouders).
- Uitgaven met kinderen, private notes, verdelingssnapshots (incl. 0/100).
- Balansmodel + BalanceCard + Balansopbouw.
- Betalingen: melden → pending → bevestigen / wijzigen / verwijderen.
- Maandelijkse masters + **live client-side materialisatie** (open/resume).
- Logboek met filters + CSV/PDF export.
- Read-only huishouden + account delete (incl. Cloud Functions pad).
- Privacy: screenshot-blok + reopen-lock.

### Technisch af

- `computeHouseholdBalance` + parent-split unit tests.
- BalanceCard + Balansopbouw widget regressies.
- Strakke Firestore rules voor payments/expenses/read-only.
- Android release signing wired; lean manifest; portrait lock.

### Klaar voor echte 2-account acceptatietest?

**Ja**, mits: zelfde build voor beide accounts; korte tester-brief (pending UX + maandelijks client-triggered); sectie 19 uitgevoerd.

### Nog vóór die test (Fase A)

1. Zelfde APK/AAB + Firebase-project voor A en B bevestigen.
2. Testers briefen: geen receiver-reject; maandelijks vereist open/resume van de maker.
3. Geen code-wijzigingen nodig alleen voor “nice to have”.

### Nog vóór Google Play (Fase D)

1. Hosted privacy URL + sync `docs/privacy_policy.md` naar in-app.
2. Adaptive icons; version bump; Firebase-omgeving bewust bevestigen.
3. Data Safety + listing assets + AAB smoke.

### Later / post-v1

- Push, deeplinks, receiver-reject, betaler≠creator, aparte expense-date, grote refactor, Crashlytics, massale E2E-tests.

---

## 22. Aanbevolen route vanaf huidige staat

### Fase A — vóór echte gebruikerstoets

Alleen wat nodig is zodat twee echte accounts serieus kunnen testen:

1. Bevestig dat A en B **dezelfde** release/debug-build gebruiken (zelfde `projectId`).
2. Deel een korte tester-brief:
   - Ontvanger kan een betaling **niet** afwijzen; melder kan pending verwijderen.
   - Maandelijkse uitgaven materialiseren wanneer de **maker** de app opent/hervat (geen server-cron).
   - Logboek is de plek om alle betalingen te zien.
3. Geen feature-bouw, geen polish, geen dependency-updates in deze fase.

### Fase B — echte 2-ouder acceptatietest

Volg **sectie 19**. Absoluut uitvoeren:

- Scenario 1 (koppelen)
- Scenario 2–3 (uitgaven + 50/50 + 60/40 + 100/0)
- Scenario 4–5 (betaling melden / pending / bevestigen / wijzigen / verwijderen)
- Scenario 6 (uitgave wijzigen + Logboek)
- Scenario 7 (nul/positieve balans melden)
- Scenario 9 (heropenen / privacy lock) — light
- Scenario 10 (maandelijkse materialisatie) — **verplicht** gezien live runner
- Scenario 8 (read-only / account delete) — alleen als testdata mag verdwijnen

### Fase C — fixes uit praktijktest

Alleen bugs/regressies die in Fase B daadwerkelijk gevonden worden.

Geen “nu we toch bezig zijn”-features.

### Fase D — Google Play releasevoorbereiding

Store/process:

- Privacy URL (inhoud = actuele in-app; sync `docs/privacy_policy.md`)
- Data Safety, content rating, doelgroep (volwassenen)
- Listing, screenshots, feature graphic, support e-mail
- AAB, versionCode bump, signing / Play App Signing
- Adaptive icons genereren
- Firebase-omgeving bewust bevestigen (§15.3)
- Release-build smoke (crash-free kernflows)

Optioneel (niet verplicht voor v1): ProGuard/R8.

### Fase E — eerste publieke release

Minimaal criterium:

- Fase B groen (of bekende issues bewust geaccepteerd/gedocumenteerd)
- Fase D checklist af voor privacy, Data Safety, listing, AAB, signing
- Geen open P0; geen ongedocumenteerde P1 die externe gebruikers raakt
- Account deletion + read-only gedrag klopt met store-tekst

### Later / post-v1

Bewust **niet** nodig om nu te publiceren:

- Pushmeldingen
- Deeplinks
- Receiver reject
- Betaler ≠ creator
- Aparte expense date
- Grote `main.dart`-refactor
- Extra Firebase UI/E2E-testinfrastructuur
- Crashlytics/analytics (tenzij diagnose-probleem optreedt)

---

## Auditmeta

| Item | Waarde |
|---|---|
| Analyse-only | Ja |
| Stash gebruikt | Nee |
| Productiecode gewijzigd | Nee |
| Tests gewijzigd | Nee |
| Dependencies gewijzigd | Nee |
| Enige gewijzigde artifact | `docs/KIDU_APP_AUDIT.md` |
| Reconciliatie | 2026-08-10 — adaptive icons, privacy sync, recurring live, P-matrix, route §22 |
