# KiDu Day 9 — Android Signing Audit

## Huidige status
- Buildscript type: KTS
- Is er een release signingConfig gedefinieerd? NEE
- Is release buildType gekoppeld aan signingConfig release? NEE
- Wordt key.properties ingelezen? NEE
- Wordt debug signing nog gebruikt voor release? JA

## Bevindingen
- `android/app/build.gradle.kts` bevat een release buildType zonder signingConfig.
- TODO(production)-comment in regel 38: "Configure a dedicated release signingConfig with your production keystore."
- Geen `signingConfigs`-block aanwezig in de android-configuratie.
- `key.properties` staat in `android/.gitignore` maar wordt nergens in de buildscripts ingelezen.
- Geen keystore- of storeFile-referentie in de codebase.

## Risico-inschatting
HIGH — Zonder signingConfig gebruikt de release build de debug keystore; Play Store uploads zijn daarmee niet reproduceerbaar en app-updates kunnen falen bij keystore-wijziging.

## Minimale volgende stap
- Upload keystore aanmaken met `keytool` en veilig opslaan.
- `key.properties` lokaal aanmaken met storeFile-, storePassword-, keyAlias- en keyPassword-velden.
- In `build.gradle.kts`: `signingConfigs` block toevoegen, `key.properties` inlezen, en release buildType koppelen aan `signingConfig release`.
