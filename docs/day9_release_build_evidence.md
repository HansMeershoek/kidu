# KiDu Day 9 — Release Build Evidence

## Build resultaat
- Build type: Android App Bundle (release)
- Output bestand: `build/app/outputs/bundle/release/app-release.aab`
- Bestandsgrootte: `45,481,902 bytes` (ongeveer 43.4 MB)
- Build status: SUCCESS
- Build datum/tijd (lokaal): `2026-02-16 22:05:41`

## Signing verificatie
- Release variant config: `release`
- Keystore: `android/app/kidu-upload-keystore.jks`
- Alias: `kidu_upload`
- Conclusie: release build is gesigned met upload keystore (niet debug)

## SHA-256
`dadc5c06dfe0388d3efeee8372e13b5b10cab56a4b02c1fbed16a6efd504ef00`

## Veiligheidscheck
- `android/key.properties` staat in ignore
- `android/app/kidu-upload-keystore.jks` staat in ignore
- Geen secrets in git-geschiedenis toegevoegd in deze stap
