# KiDu Day 11 — Internal Test Evidence

## Scope
Bewijs dat de eerste release-gates voor Internal Testing gehaald zijn op `feat/day11`.

## Gate 1 — Quality
- `flutter analyze`: PASS
- `flutter test`: PASS (2 skipped, overige tests geslaagd)
- Working tree na checks: clean

## Gate 2 — Release artifact
- Build command: `flutter build appbundle --release`
- Resultaat: SUCCESS
- Bestand: `build/app/outputs/bundle/release/app-release.aab`
- Grootte: `45,481,903 bytes` (~43.4 MB)
- Build tijd (lokaal): `2026-02-16 22:23:28`
- SHA-256: `350d456254c23ed78ddfce860d9708d4b123d8078dc65bcb1a1a11d549139ab1`

## Gate 3 — Signing
- Variant: `release`
- Config: `release`
- Store: `C:\Users\hnsmrshk\kidu\android\app\kidu-upload-keystore.jks`
- Alias: `kidu_upload`
- SHA1: `00:8C:E2:B1:3D:E7:53:98:82:8C:1E:2C:5A:2D:9E:7E:C1:9E:83:E0`
- SHA-256: `B8:8A:82:B8:23:77:9B:F3:18:DA:5A:4C:29:E7:38:DC:5A:A8:A3:01:60:FC:F1:F5:60:72:A0:B2:69:05:49:35`
- Conclusie: release signing gebruikt upload keystore (niet debug)

## Tussenconclusie Day 11
Gates 1 t/m 3 zijn groen. Volgende stap is handmatige functionele gate + Play Internal Testing upload.
