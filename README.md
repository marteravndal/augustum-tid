# Augustum Tid – isolert testversjon

Dette er en **testgren**, ikke en produksjonsoppgradering. Den viderefører Apart Tid fra commit `3038059f1b83592b55514067e1a49dbecf55adc3`, med Augustum-profilering og sperrer mot eksisterende produksjonsdatabaser.

## Klar i denne grenen

- Oppdatert ansatt- og administrasjonsgrensesnitt, mobil/PWA, stemplingslogg, ukesluttkontroll, lønnsoversikt, fraværsoppfølging, kontrollassistent, HR, HMS og kursbevis.
- «Augustum Tid» som produktnavn og «Augustum AS» som selskapsnavn.
- Egne lagringsnøkler og cache, ingen deling av nettleserøkter med Apart eller gammel Augustum Tid.
- Frontend uten produksjonsadresse eller produksjonsnøkkel. Bygget avviser de fire eksisterende transport-/tidsdatabasene.
- Alle Resend-kall stoppes i en egen testtransport. Ingen invitasjoner eller virksomhetsvarsler sendes fra denne grenen.
- Bare offentlige frontendfiler publiseres; SQL, tester og serverkode følger ikke med nettstedet.

## Ikke ferdigstilt / blokkert

Testdatabasen er ikke opprettet. Innlogging, ende-til-ende-test, felles ansatte/innlogging fra transportportalen og overføring av timer til dagsoppgjør er derfor **ikke ferdige**. Ikke presenter dette som en fungerende integrasjon.

Supabase-tilkoblingens `get_cost` returnerte `UNAVAILABLE` 14. oktober 2026. Ingen database, abonnement, eksisterende data eller produksjonsmiljø er endret.

## Lokal kontroll

```sh
npm ci --ignore-scripts
npm test
npm run build
```

Uten konfigurasjon er innlogging deaktivert. Et nytt, isolert testprosjekt konfigureres med `TID_TEST_PROJECT_REF` og `TID_TEST_PUBLISHABLE_KEY` ved bygging. Disse er offentlige frontendverdier; hemmelige nøkler hører aldri hjemme i frontend eller Git.

## Database og videre integrasjon

Se [docs/transport-integration.md](docs/transport-integration.md). Migrasjonsrekken følger en fersk database fra Apart-utgangspunktet og må **ikke** kjøres samlet mot den eksisterende Augustum Tid-databasen eller transportportalen. Databasedifferansen må gjennomgås separat før en senere produksjonsoppgradering.

Apart-spesifikke lønnstillegg, 12-timers automatisk utstempling og krav om posisjon på et fast arbeidssted er foreløpig bevart som eksisterende oppførsel i testkoden. De er ikke godkjente transportinnstillinger og må gjøres konfigurerbare før pilotdrift. Avsenderadresser og arbeidssteder må også hentes fra selskapets innstillinger.

Ingen ansatte, timelister, personopplysninger eller dokumenter er kopiert fra Apart eller Augustum.
