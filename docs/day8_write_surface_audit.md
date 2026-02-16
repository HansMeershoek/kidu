# KiDu Day 8 — Firestore Write Surface Audit

## Methode
- `firestore.rules` volledig gelezen voor rule-condities per collectie.
- Alle Dart-bestanden gescand op Firestore write-operaties via grep: `.set(`, `.update(`, `.add(`, `.delete(`, `runTransaction`, `WriteBatch`.
- Enige bestand met writes: `lib/main.dart`. Geen batch writes; wel 3 transaction-blokken.
- Per write: code-locatie, pad, payload en app-guards handmatig geïnventariseerd en vergeleken met rules.

## Write inventory

### W-01 Profile name setup
- **Flow**: Profile name setup (eerste keer / naam wijzigen)
- **Code-locatie**: `lib/main.dart` 254–257
- **Operatie**: set (merge)
- **Pad-patroon**: `users/{userId}`
- **Payload velden**: `profileName`
- **App-side guards**: `currentUser != null`; naam lengte ≥ 2
- **Rules match**: `users` update: `request.auth.uid == userId`, `userWriteValidKeys`, `userNoPrivilegeKeys`, profileName ≤ 40
- **Risico**: LOW
- **Opmerking**: Aligned.

---

### W-02 ensureUserDoc (sync user metadata)
- **Flow**: Dashboard init — sync Firebase Auth → Firestore user doc
- **Code-locatie**: `lib/main.dart` 1174
- **Operatie**: set (merge)
- **Pad-patroon**: `users/{userId}`
- **Payload velden**: `displayName`, `email`, `photoUrl`, `updatedAt`, optioneel `createdAt`
- **App-side guards**: Impliciet via Dashboard (auth-gate)
- **Rules match**: `users` create of update: auth.uid match, `userWriteValidKeys`, `userHouseholdIdSafe`, `userNoPrivilegeKeys`
- **Risico**: LOW
- **Opmerking**: Aligned.

---

### W-03 ensureUserDoc role migration (members)
- **Flow**: Dashboard init — mini-migratie voor bestaande member docs
- **Code-locatie**: `lib/main.dart` 1177–1185
- **Operatie**: set (merge)
- **Pad-patroon**: `households/{householdId}/members/{memberId}`
- **Payload velden**: `role` (alleen)
- **App-side guards**: Alleen wanneer `existingHouseholdId` niet leeg
- **Rules match**: `members` allow update: **false**. Create vereist `keys().hasOnly(['role','joinedAt'])` — app stuurt alleen `role`
- **Risico**: HIGH
- **Opmerking**: Members update is expliciet verboden in rules. Create zou ook falen (geen `joinedAt`). Fout wordt gevangen en gelogd; migratie faalt stil.

---

### W-04 Start setup (transaction)
- **Flow**: Start setup — nieuw household aanmaken
- **Code-locatie**: `lib/main.dart` 1214–1256 (transaction), writes op 1230, 1238, 1243
- **Operatie**: transaction (3× set)
- **Pad-patronen**:
  - `households/{householdId}` (create)
  - `households/{householdId}/members/{memberId}` (create)
  - `users/{userId}` (update merge)
- **Payload velden**:
  - Household: `createdAt`, `createdBy`, `name`, `isConnected`
  - Member: `role`, `joinedAt`
  - User: `householdId`, `setupCompletedAt`
- **App-side guards**: `uid != null`; `existingHouseholdId` leeg (anders early return)
- **Rules match**: Household create (hasOnly, createdBy, isConnected false); members create (role, joinedAt); users update (valid keys)
- **Risico**: LOW
- **Opmerking**: Aligned.

---

### W-05 Invite create
- **Flow**: Invite code genereren
- **Code-locatie**: `lib/main.dart` 1318–1328 (transaction), write op 1323
- **Operatie**: transaction set (create)
- **Pad-patroon**: `invites/{code}`
- **Payload velden**: `householdId`, `createdBy`, `usedBy` (null), `createdAt`
- **App-side guards**: `uid != null`; `membersSnap.size < 2` (household niet vol)
- **Rules match**: create: `hasOnly`, `createdBy == auth.uid`, `usedBy == null`, `isHouseholdMember(householdId)`
- **Risico**: LOW
- **Opmerking**: Aligned.

---

### W-06 Expense create
- **Flow**: Nieuwe uitgave toevoegen
- **Code-locatie**: `lib/main.dart` 985–993
- **Operatie**: add
- **Pad-patroon**: `households/{householdId}/expenses/{expenseId}`
- **Payload velden**: `amountCents`, `currency`, `title`, `createdAt`, `createdBy`
- **App-side guards**: `uid != null`; FAB disabled wanneer `!canAddExpenses` (d.w.z. `otherUid == null` → alleen in household)
- **Rules match**: create: `isHouseholdMember`, `createdBy == auth.uid`, `hasOnly`, amountCents > 0, currency EUR, title 1–80
- **Risico**: LOW
- **Opmerking**: Aligned. App blokkeert expense-create wanneer geen andere member (E-02 flow).

---

### W-07 Expense create met private note
- **Flow**: Uitgave toevoegen met notitie in één flow
- **Code-locatie**: `lib/main.dart` 996–1003
- **Operatie**: set (na add van expense)
- **Pad-patroon**: `households/{householdId}/expenses/{expenseId}/privateNotes/{uid}`
- **Payload velden**: `note`, `updatedAt`
- **App-side guards**: Zelfde als W-06; note alleen na succesvolle expense create
- **Rules match**: privateNotes create: `uid == auth.uid`, `isHouseholdMember`, expense exists, `expense.createdBy == auth.uid`, `hasOnly`, note ≤ 180, `updatedAt == request.time`
- **Risico**: LOW
- **Opmerking**: Aligned. Expense net aangemaakt met `createdBy == uid`.

---

### W-08 Private note add/edit
- **Flow**: Notitie toevoegen of wijzigen op bestaande expense
- **Code-locatie**: `lib/main.dart` 691–695
- **Operatie**: set (create of update)
- **Pad-patroon**: `households/{householdId}/expenses/{expenseId}/privateNotes/{uid}`
- **Payload velden**: `note`, `updatedAt`
- **App-side guards**: `_noteWriteInFlight`; dialog result; auth implicit via context
- **Rules match**: create/update: `uid == auth.uid`, `isHouseholdMember`, expense exists, `expense.createdBy == auth.uid`, `hasOnly`, note ≤ 180, `updatedAt == request.time`
- **Risico**: LOW
- **Opmerking**: Aligned. `serverTimestamp()` matcht `request.time` in rules.

---

### W-09 Private note delete
- **Flow**: Notitie verwijderen
- **Code-locatie**: `lib/main.dart` 689–690
- **Operatie**: delete
- **Pad-patroon**: `households/{householdId}/expenses/{expenseId}/privateNotes/{uid}`
- **Payload velden**: —
- **App-side guards**: Zelfde als W-08
- **Rules match**: delete: `uid == auth.uid`, `isHouseholdMember`, expense exists, `expense.createdBy == auth.uid`
- **Risico**: LOW
- **Opmerking**: Aligned.

---

### W-10 Join household (transaction)
- **Flow**: Join household met invite code
- **Code-locatie**: `lib/main.dart` 2370–2399 (transaction), writes op 2386, 2391
- **Operatie**: transaction (2× set met merge)
- **Pad-patronen**:
  - `households/{householdId}/members/{memberId}` (create via merge)
  - `invites/{code}` (update)
- **Payload velden**:
  - Member: `role`, `joinedAt`
  - Invite: `usedBy`, `usedAt`
- **App-side guards**: `uid != null`; code niet leeg; invite exists, usedBy null; targetHouseholdId geldig; niet al in dat household; bij bestaand household: alleen 1 member (zichzelf) en geen expenses
- **Rules match**: members create (keys, role); invites update (usedBy, usedAt, affectedKeys, usedAt == request.time)
- **Risico**: LOW
- **Opmerking**: Aligned. Member create via merge; invite update conformeert aan rules.

---

### W-11 Join household user update
- **Flow**: User doc bijwerken na join
- **Code-locatie**: `lib/main.dart` 2401–2405
- **Operatie**: set (merge)
- **Pad-patroon**: `users/{userId}`
- **Payload velden**: `householdId`, `updatedAt`
- **App-side guards**: Na succesvolle transaction
- **Rules match**: users update: auth.uid, `userWriteValidKeys`, `userHouseholdIdSafe`
- **Risico**: LOW
- **Opmerking**: Aligned.

---

### Uitgeschakelde writes (geen actieve writes)
- **Members delete** (regel 2411): Uitgecommentarieerd; rules staan `delete` toe voor `memberId == auth.uid`. TODO: re-enable na rules alignment.
- **Household isConnected update** (regel 2416): Uitgecommentarieerd; rules staan update toe met `affectedKeys.hasOnly(['isConnected'])` en `isConnected == true`. TODO: re-enable.

---

## Top risico's (max 5)

1. **W-03 Members role migration**: App probeert `members` te updaten; rules `allow update: if false`. Create zou ook falen (geen `joinedAt`). Stille failure in production.
2. **Uitgeschakelde household isConnected update**: Na join wordt `isConnected` niet gezet; UI/flow kan inconsistent zijn met bedoeling.
3. **Uitgeschakelde members delete bij switch**: Bij household-wissel wordt oude member niet verwijderd; mogelijk orphaned member docs.
4. **privateNotes rule `expense.createdBy == auth.uid`**: Alleen expense-creator mag notes. Als UI ooit notes toont aan andere members, is dat read-only; write blijft correct afgeschermd.
5. **Invite create collision**: Bij code-collision wordt `StateError` gegooid en opnieuw geprobeerd (max 6×). Geen structureel risico; edge-case bij extreme collision.

---

## Conclusie

De meeste Firestore writes zijn aligned met `firestore.rules`. Het belangrijkste risico is **W-03** (members role migration): de app probeert een update op `members` die door de rules wordt geweigerd; de fout wordt afgevangen en genegeerd. Verder zijn twee flows gedeeltelijk uitgeschakeld (members delete bij switch, household `isConnected` update) vanwege eerdere permission-denied; de rules lijken deze nu wel toe te staan, maar zijn nog niet opnieuw geactiveerd. Voor de actieve flows (setup, invite, join, expense, notes) is de alignment goed.
