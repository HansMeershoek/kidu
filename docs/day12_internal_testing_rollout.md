# KiDu Day 12 — Play Internal Testing Rollout

## Doel

Na een geslaagde build en signing (Day 11) is het doel van Day 12 om de eerste interne distributie via de Google Play Console uit te voeren. De app wordt beschikbaar gemaakt voor een beperkte groep interne testers via het Internal testing-track, zodat installatie en basisfunctionaliteit kunnen worden gevalideerd vóór bredere distributie.

## Invoer (reeds bekend)

- **Branch:** feat/day12
- **Laatste baseline commit:** aa10ae3
- **App version:** 0.1.0+2
- **AAB pad:** build/app/outputs/bundle/release/app-release.aab
- **AAB SHA-256:** DD41B972EF39170BA0185002726F33D002C53CF8EF20746C463B108072C5BCB2
- **Release signing alias:** kidu_upload

## Pre-flight gate (moet groen)

- [ ] `flutter analyze` — geen issues
- [ ] `flutter test` — alle tests slagen
- [ ] Release AAB aanwezig op bovenstaand pad
- [ ] `signingReport` toont release=upload keystore (kidu_upload)
- [ ] Working tree clean (`git status`)

## Play Console stappen (exacte volgorde)

1. App openen in Play Console
2. **Testing** > **Internal testing**
3. **Create new release**
4. AAB uploaden (drag & drop of bestand kiezen)
5. Release name invullen: `0.1.0+2 - Internal test Day 12`
6. Release notes invullen:
   - **NL:** `Interne testversie Day 12. Installeer en test de basisfunctionaliteit. Feedback graag via [kanaal].`
   - **EN:** `Internal test Day 12. Install and verify core functionality. Please share feedback via [channel].`
7. **Save**
8. **Review release** — controleer versie, signing, permissies
9. **Start rollout to Internal testing**
10. Controleer dat status op "Available to testers" staat

## Tester distributie

- [ ] E-mailadressen toegevoegd aan de testerlijst in Play Console
- [ ] Opt-in link gedeeld met testers
- [ ] Testinstructie verstuurd

**Voorbeeldbericht aan testers:**

> Hoi,
>
> KiDu v0.1.0 is beschikbaar voor interne test. Installeer via de link: [opt-in link]
>
> Wat te testen:
> - App opent zonder crash
> - Basisnavigatie werkt
> - [Specifieke flows die je wilt valideren]
>
> Geef feedback via [e-mail/Slack/issue-tracker]. Bedankt!

## Bewijslog (in te vullen)

| Stap | Resultaat (PASS/FAIL) | Tijd (lokale tijd) | Bewijs (screenshot/beschrijving) |
|------|------------------------|---------------------|----------------------------------|
| Pre-flight gate | PASS | 2026-02-17 17:14; build 2026-02-19 18:05 | flutter analyze: No issues; flutter test: passed (2 skipped); AAB aanwezig; signingReport release alias kidu_upload; git status clean. Release AAB rebuilt 2026-02-19, release-built today. AAB SHA-256: DD41B972EF39170BA0185002726F33D002C53CF8EF20746C463B108072C5BCB2. Release AAB rebuilt after UI/login polish + atomic users/$uid write in join transaction + no dashboard flash + last activity indicator. |
| AAB upload | PASS | 2026-02-17 [VUL_IN] | AAB geüpload & verwerkt in Internal testing release (bundle 2 / 0.1.0) |
| Release aangemaakt | PASS | 2026-02-17 [VUL_IN] | Release notes opgeslagen (nl-NL + en-US) |
| Rollout gestart | FAIL (BLOCKED) | 2026-02-17 [VUL_IN] | Account verification in progress: "There are issues with your account…" |
| Tester toegevoegd | | | |
| Installatie bevestigd | | | |

## Bekende risico's + mitigatie

- **Verkeerde Google-account** — Controleer rechtsboven in Play Console dat je op het juiste account/organisatie zit vóór upload.
- **Oude build-cache** — Voer `flutter clean` en rebuild uit als de geüploade AAB niet overeenkomt met de verwachte versie.
- **Rollout niet gestart** — Na "Save" moet expliciet "Start rollout" worden geklikt; anders blijft de release in concept.
- **Testers niet geaccepteerd** — Testers moeten de opt-in link openen en accepteren; anders zien ze de app niet in de Play Store.
- **Versieconflict** — Als een tester al een hogere versie heeft (bijv. via sideload), kan update falen; gebruik een schone testomgeving.

## Exit-criteria Day 12

- [ ] Internal release live in Play Console
- [ ] Minimaal 1 tester kan de app installeren
- [ ] Install/update bevestigd door tester
- [ ] Geen P0/P1 blocker gerapporteerd
- [ ] Go/No-go notitie klaar voor PR naar main
