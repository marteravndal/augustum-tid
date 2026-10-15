# Augustum Tid – isolert testversjon

Dette er en **testgren**, ikke en produksjonsoppgradering. Den viderefører Apart Tid fra commit `3038059f1b83592b55514067e1a49dbecf55adc3`, med Augustum-profilering og sperrer mot eksisterende produksjonsdatabaser.

## Klar i denne grenen

- Oppdatert ansatt- og administrasjonsgrensesnitt, mobil/PWA, stemplingslogg, ukesluttkontroll, lønnsoversikt, fraværsoppfølging, kontrollassistent, HR, HMS og kursbevis.
- «Augustum Tid» som produktnavn og «Augustum AS» som selskapsnavn.
- Egne lagringsnøkler og cache, ingen deling av nettleserøkter med Apart eller gammel Augustum Tid.
- Frontend uten produksjonsadresse eller produksjonsnøkkel. Bygget avviser de fire eksisterende transport-/tidsdatabasene.
- Alle Resend-kall stoppes i en egen testtransport. Ingen invitasjoner eller virksomhetsvarsler sendes fra denne grenen.
- Bare offentlige frontendfiler publiseres; SQL, tester og serverkode følger ikke med nettstedet.

## Integrert testmiljø

Supabase-prosjektet `krllcibcfuzsvjybqaua` er opprettet av brukeren og koblet til en egen forhåndsvisning av Augustum Transport. Bruk portalens `/tid-test`, ikke produksjonsdomenet tid.augustum.no.

- Innlogging autoriseres i portalen ved hvert kall. En signert engangsforespørsel oppretter en serverintern økt i testdatabasen. Ingen test-token sendes til nettleseren.
- Navn, kontaktopplysninger og aktiv status synkroniseres fra portalens ansattregister ved åpning. Ingen data kopieres fra Apart Tid eller gammel Augustum Tid.
- Godkjente arbeidsintervaller kan fordeles på oppdragsgivere og overføres til et isolert testutkast i oppgjørstjenesten. Eksisterende oppgjør overskrives ikke.
- Testmiljøet har mobilt arbeidssted uten posisjonskrav. Automatisk 12-timers utstempling er ikke planlagt. Vaktlistekravet fra Apart gjelder fortsatt ved ansattes egen stempling.
- Alle virksomhets-e-poster er deaktivert. Innlogging gjennom portalen sender heller ingen kode på e-post.

Produksjonsaktivering, transporttilpassede lønnsregler, nattarbeid og automatisert korrigeringssynkronisering gjenstår. Dette er et testgrunnlag, ikke ferdig lønnsproduksjon.

## Lokal kontroll

```sh
npm ci --ignore-scripts
npm test
npm run build
```

Uten konfigurasjon er innlogging deaktivert. Et nytt, isolert testprosjekt konfigureres med `TID_TEST_PROJECT_REF` og `TID_TEST_PUBLISHABLE_KEY` ved bygging. Disse er offentlige frontendverdier; hemmelige nøkler hører aldri hjemme i frontend eller Git.

## Database og videre integrasjon

Se [docs/transport-integration.md](docs/transport-integration.md). Migrasjonsrekken følger en fersk database fra Apart-utgangspunktet og må **ikke** kjøres samlet mot den eksisterende Augustum Tid-databasen eller transportportalen. Databasedifferansen må gjennomgås separat før en senere produksjonsoppgradering.

Lønnstillegg fra Apart er fortsatt testgrunnlag og skal kontrolleres mot transportvirksomhetens avtaler før pilotdrift. De overstyrer ikke prisavtalene for dagsoppgjør.
