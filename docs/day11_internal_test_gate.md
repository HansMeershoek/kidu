# KiDu Day 11 — Internal Test Gate

Doel: één strikte gate vóór upload naar Google Play Internal Testing.

## 1) Build & quality gate (moet groen)
- `flutter analyze` = PASS
- `flutter test` = PASS
- Working tree clean vóór release build

## 2) Release artifact gate
- App version in `pubspec.yaml` correct voor deze test-run
- `flutter build appbundle --release` = SUCCESS
- AAB pad: `build/app/outputs/bundle/release/app-release.aab`
- SHA-256 hash vastgelegd in release evidence

## 3) Signing gate
- Release variant gebruikt upload keystore (geen debug)
- `android/key.properties` staat in ignore
- `android/app/*.jks` staat in ignore

## 4) Functionele gate (handmatig, 2 accounts)
- Setup/start household = PASS
- Join met invite code = PASS
- Household switch/security boundary = PASS
- Expense create online = PASS
- Expense create offline geblokkeerd = PASS
- Note add/edit/delete = PASS
- Geen crash/rood scherm

## 5) UX gate (MVP)
- Dashboard zonder regressies
- Expense detail opent via hele rij
- Notitie zichtbaar en beheerbaar op detailpagina
- Geen overflow waarschuwingen in ondersteunde layout (portrait)

## 6) Release hygiene
- Relevante docs bijgewerkt (day9/day11 evidence)
- PR beschrijving bevat korte go/no-go notitie
- Tag-plan klaar voor checkpoint

## Day 11 exit-criteria
Alle secties hierboven op PASS, daarna pas upload naar Play Internal Test.
