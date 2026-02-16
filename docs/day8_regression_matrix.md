# KiDu Day 8 — Hardening Regression Matrix

Doel: kritieke flows elke wijziging snel en consistent kunnen checken, vóór merge naar `main`.

## Test-afspraken
- Test op 2 echte accounts (A en B).
- Start met schone app-state (fresh install of uitgelogd).
- Log per case: `PASS` / `FAIL` + korte notitie.
- Bij `FAIL`: geen featurewerk; eerst fix + her-test.

## Cases

### H-01 Start setup (A)
**Stap**
1. Login met account A.
2. Rond profile name setup af.
3. Kies **Start setup**.

**Verwacht**
- Household wordt aangemaakt.
- Invite code zichtbaar.
- Geen permission errors.

---

### H-02 Join household (B met geldige code)
**Stap**
1. Login met account B.
2. Voer invite code van A in.
3. Rond join flow af.

**Verwacht**
- B wordt member van dezelfde household.
- Connected state actief.
- Geen permission errors.

---

### H-03 Join met ongeldige code
**Stap**
1. Login met account B (nog niet gekoppeld in test-run).
2. Voer ongeldige/random code in.

**Verwacht**
- Join mislukt netjes.
- Duidelijke NL foutmelding (user-facing mapped error).
- Geen crash / rood scherm.

---

### H-04 Household context switch (indien meerdere households)
**Stap**
1. Zorg dat account toegang heeft tot >1 household.
2. Wissel household-context.

**Verwacht**
- UI/data ververst correct naar gekozen household.
- Geen permission-denied in normale flow.

---

### E-01 Expense create (connected state)
**Stap**
1. In gekoppelde household: maak expense aan (title + amount).

**Verwacht**
- Expense wordt opgeslagen en verschijnt bovenaan lijst (createdAt desc).
- Subtitle toont correcte maker + datum/tijd.
- Balance card update zichtbaar.

---

### E-02 Expense create geblokkeerd zonder koppeling
**Stap**
1. Gebruik account zonder andere member in household-context.
2. Probeer expense toe te voegen.

**Verwacht**
- Actie wordt geblokkeerd volgens ontwerp.
- Duidelijke feedback; geen stille failure.

---

### N-01 Private note add/edit/delete
**Stap**
1. Open bestaande expense.
2. Voeg note toe, wijzig note, verwijder note.

**Verwacht**
- Alle 3 acties werken zonder lifecycle/assert issues.
- Geen rood scherm.
- Resultaat direct zichtbaar in UI.

---

### X-01 Error mapping basis
**Stap**
1. Trigger (waar mogelijk) netwerkfout/offline of permission scenario.

**Verwacht**
- Bekende fouten tonen nette NL melding via `mapUserFacingError`.
- Geen technische/raw Firebase fouttekst als eindgebruikersmelding.

## Exit-criteria vóór merge naar main
- Alle cases `PASS`.
- `flutter analyze` en `flutter test` groen.
- Geen open regressies op setup/join/switch/expense/note flows.
