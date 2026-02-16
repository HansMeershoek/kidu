# KiDu Day 8 — isConnected & Member Cleanup Audit

## Methode
- Grep op `isConnected`, `member.*delete`, `delete.*member`, `household.*switch` in de volledige repo.
- Handmatige inspectie van `lib/main.dart` en `firestore.rules` op relevante flows.
- Geen codewijzigingen; alleen documentatie.

---

## A) households.isConnected

### Locatie-overzicht (pad + regelnummers)

| Type   | Bestand        | Regels   | Context                                      |
|--------|----------------|----------|----------------------------------------------|
| WRITE  | `lib/main.dart` | 1219–1221 | Create: `transaction.set(householdRef, {..., 'isConnected': false})` |
| WRITE  | `lib/main.dart` | 2401–2406 | Update: uitgecommentarieerd `set({'isConnected': true}, merge)` na join |
| RULES  | `firestore.rules` | 99–101, 104–105 | Create: `isConnected == false`; update: `affectedKeys.hasOnly(['isConnected'])`, `isConnected == true` |
| DOCS   | `docs/day8_write_surface_audit.md` | 59, 63, 166, 173, 182 | Referenties in bestaande audit |

### Reads van isConnected

**Geen reads in app-code gevonden.** De app leest nergens het household-document (`households/{id}`). Alle relevante data komt uit `users`, `households/{id}/members`, `households/{id}/expenses`, `invites` en `privateNotes`. Het veld `isConnected` wordt niet gebruikt voor UI-gating, business-logica of cosmetiek.

### Impactanalyse per locatie

| Locatie | Type | Impact |
|---------|------|--------|
| `lib/main.dart` 1219–1221 | Write (actief) | Create: household wordt aangemaakt met `isConnected: false`. Vereist door rules. |
| `lib/main.dart` 2401–2406 | Write (uitgecommentarieerd) | Update na join: zou `isConnected: true` zetten. Nu niet actief. |
| `firestore.rules` 99–105 | Validatie | Rules eisen `isConnected == false` bij create en `isConnected == true` bij update. |

### Risicobeoordeling

- **isConnected write (create)**: LOW — actief en aligned met rules.
- **isConnected write (update na join)**: LOW — veld wordt nergens gelezen; geen UI/business impact. Alleen semantiek (huidige state van household) blijft onjuist.

### Aanbeveling: KEEP DISABLED

Release kan veilig zonder de update-write. Het veld wordt niet gelezen; er is geen UI-gating of business-logica die ervan afhangt. Re-enable later voor data-consistentie/semantiek indien gewenst.

---

## B) members delete bij switch

### Locatie-overzicht (pad + regelnummers)

| Type   | Bestand        | Regels   | Context                                      |
|--------|----------------|----------|----------------------------------------------|
| DELETE | `lib/main.dart` | 2393–2399 | Uitgecommentarieerd: `oldMemberRef.delete()` bij household-wissel in `_joinHousehold()` |
| RULES  | `firestore.rules` | 116      | `allow delete: if isSignedIn() && request.auth.uid == memberId` |
| DOCS   | `docs/day8_write_surface_audit.md` | 165, 174, 182 | Referenties in bestaande audit |

**Overige delete in codebase**: `lib/main.dart` regel 690 — `privateNotes` delete (actief). Geen andere member-deletes.

### Impactanalyse per locatie

| Locatie | Type | Impact |
|---------|------|--------|
| `lib/main.dart` 2393–2399 | Delete (uitgecommentarieerd) | Bij switch: oude member-doc in `households/{currentHouseholdId}/members/{uid}` wordt niet verwijderd. |
| `firestore.rules` 116 | Regel | Delete toegestaan voor `memberId == auth.uid`. |

### Functioneel vereist of alleen data-hygiëne?

**Functioneel vereist voor correcte werking.** De security rules gebruiken `isHouseholdMember(householdId)` = `exists(households/{householdId}/members/{request.auth.uid})`. Als de member-doc niet wordt verwijderd bij switch:

- De gebruiker heeft `users.householdId` = nieuw household.
- De oude member-doc blijft bestaan in het oude household.
- `isHouseholdMember(oudHouseholdId)` blijft `true` voor die gebruiker.
- De gebruiker behoudt lees- en schrijftoegang tot het oude household (expenses, members, etc.).

Dit is een **security-issue**: een gebruiker die het household heeft verlaten behoudt toegang.

### Mogelijke risico’s als delete uit blijft

| Risico | Ernst | Toelichting |
|--------|-------|-------------|
| Orphan member docs | MEDIUM | Oude household heeft member-doc van gebruiker die niet meer in dat household zit. |
| Security | HIGH | `isHouseholdMember` blijft true; gebruiker kan oude household-data lezen/schrijven. |
| UX-impact | LOW | App toont alleen data van `users.householdId`; gebruiker ziet het oude household niet in de UI, maar heeft wel backend-toegang. |

### Risicobeoordeling: HIGH

### Aanbeveling: RE-ENABLE

Member delete is nodig voor correcte security. Zonder delete behoudt een gebruiker die van household wisselt toegang tot het oude household via de Firestore rules.

---

## Besluitvoorstel (Day 8)

1. **Wat nu doen**: Member delete bij household switch **re-enablen**. De rules staan dit toe (`memberId == auth.uid`). Zonder delete ontstaat een security-issue (toegang tot verlaten household).

2. **Wat later doen**: Household `isConnected` update na join optioneel re-enablen voor data-consistentie. Geen functionele impact; veld wordt niet gelezen.

3. **Waarom dit production-safe is**: Na re-enable van member delete is de security-boundary correct: gebruikers verliezen toegang tot het oude household. De `isConnected` update kan later; die heeft geen impact op security of core flows.
