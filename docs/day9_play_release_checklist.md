# KiDu Day 9 — Google Play Release Checklist (MVP)

## 1) Release gate (moet groen vóór elke release candidate)
- flutter analyze groen
- flutter test groen
- handmatige regressiematrix (verwijs naar day8_regression_matrix.md) volledig PASS
- geen open P0/P1 bugs

## 2) Android signing
- upload keystore aangemaakt en veilig opgeslagen
- key.properties lokaal en NIET in git
- release build gebruikt signingConfig release (geen debug signing)
- recovery/backup van keystore + wachtwoorden geregeld

## 3) Versioning discipline
- pubspec version verhoogd per release candidate
- git tag op release commit (bijv. v0.1.0-rc1)
- changelog/PR summary bijgewerkt

## 4) Privacy & compliance (Play Console)
- Data safety formulier ingevuld op basis van echte app-data
- privacy policy URL beschikbaar
- app access/credentials niet vereist of correct gedocumenteerd
- doelgroep/content rating ingevuld

## 5) Build & distributie
- release AAB build succesvol
- interne testtrack upload succesvol
- install/update test op minimaal 2 Android devices geslaagd

## 6) Observability & support baseline
- user-facing foutmeldingen begrijpelijk (geen ruwe Firebase errors)
- basis support-kanaal/feedback route bepaald (e-mail of formulier)
- crashvrije kritieke flows: setup/join/switch/expense/note

## 7) Day 9 exit-criteria
- checklist punten 1 t/m 3 afgerond
- minimaal 1 interne testbuild in Play Console
- go/no-go notitie vastgelegd in PR beschrijving
