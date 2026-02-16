# KiDu Day 9 — Release Build Evidence

## Build resultaat
- App version: `0.1.0+2`
- Build type: Android App Bundle (release)
- Output bestand: `build/app/outputs/bundle/release/app-release.aab`
- Bestandsgrootte: `45,481,903 bytes` (ongeveer 43.4 MB)
- Build status: SUCCESS
- Build datum/tijd (lokaal): `2026-02-16 22:23:28`

## Signing verificatie
- Release variant config: `release`
- Keystore: `android/app/kidu-upload-keystore.jks`
- Alias: `kidu_upload`
- Conclusie: release build is gesigned met upload keystore (niet debug)

## SHA-256
`350d456254c23ed78ddfce860d9708d4b123d8078dc65bcb1a1a11d549139ab1`

## Veiligheidscheck
- `android/key.properties` staat in ignore
- `android/app/kidu-upload-keystore.jks` staat in ignore
- Geen secrets in git-geschiedenis toegevoegd in deze stap
