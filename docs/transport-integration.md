# Integrasjonsgrunnlag for testversjonen

Status 2026-10-14: kildegrunnlag og isolasjon er klargjort. Databasetilkobling og portalintegrasjon gjenstår.

## Valgt retning

Behold Augustum Transport som kilde for selskaper, ansatte, oppdragsgivere og modultilganger. Tid håndterer arbeidsregistreringer, godkjenning og lønnsgrunnlag. Dagsoppgjør beregner fakturerbar inntekt med oppdragsgiverens prisavtale.

Apart Tid forblir et separat produksjonssystem. Kode kan gjenbrukes, virksomhetsdata flyttes ikke.

## Nødvendige koblinger

| Portal | Tidsmodul | Regel |
| --- | --- | --- |
| companies.id | organizations.portal_company_id | Entydig binding verifisert på serveren. |
| employees.id | employees.portal_employee_id | Stabil ID; ikke automatisk sammenslåing etter navn/e-post. |
| employee_customers.id | oppdragsgiver på arbeidsintervall | Flere intervaller/oppdragsgivere per dag. |
| module tid + rolle | tilgang til tidsfunksjoner | Kontrolleres ved hvert kall, også ved inaktivering. |
| Innstillinger → Integrasjoner | e-post og senere leverandører | Bare serveren får lese hemmeligheter. |

Mapping-kolonnene i tabellen over er designbeslutninger, ikke opprettede databasefelt.

## Dagsoppgjør

Eksisterende `prepare_daily_report` aggregerer per ansatt/dag, og `transport_transfer_proposals` har unik kombinasjon rapport/ansatt. Dette er utilstrekkelig ved flere oppdragsgivere.

Lag derfor fordelte intervaller med stabil kilde-ID, ansatt-ID, oppdragsgiver-ID, dato, start/slutt, pauser og godkjent revisjon. Summen må holdes innenfor registrert arbeidstid; overlapp avvises. Arbeid som går over midnatt må få en uttrykkelig datoavgrensning. Fravær gir ikke fakturerbare timer.

Importen skal opprette eller oppdatere et **utkast**. Den skal ikke låse, overskrive et sendt/låst oppgjør eller sende e-post. Samme kilderevisjon skal kunne importeres flere ganger uten dobbeltføring. Endret godkjent tid etter import markeres for kontroll; manuelle tillegg beholdes. Manglende prisavtale må avklares.

Lønnsberegning for den ansatte og overtids-/fakturaberegning per oppdragsgiver er separate. Aparts 40/100-prosentkategorier skal ikke overstyre transportkundens avtale.

## Testmiljø før neste steg

1. Opprett en tom, separat Supabase-testdatabase i den eksisterende organisasjonen etter at kostnaden er avklart. Ikke bruk prosjektet med domenet tid.augustum.no selv om Vercel-navnet inneholder «test».
2. Avklar migrasjonskjeden mot den nye databasen. Ikke kjør grunnskjemaet mot et eksisterende system. Konfigurer worker-adressen som fortsatt er satt til en ugyldig plassholder.
3. Aktiver kun syntetiske testansatte og testoppdragsgivere. Ikke kopier produksjonsbrukere eller hemmeligheter.
4. Tilpass innlogging og mapping til transportportalens autorisasjon; behold egne revisjonsspor.
5. Gjør stemplingsregler, lønnstillegg, normtid og varsler selskapsstyrte. Sjåfører må kunne jobbe på forskjellige arbeidssteder.
6. Test én sjåfør på to oppdragsgivere samme dag, fravær, fastpris, timepris, overtid, nattevakt, korrigering, dobbeltimport, inaktiv ansatt og tilgang mellom selskaper.
7. Publiser først en fungerende testadresse. Aktiver produksjon separat etter gjennomgang.

Testgrenens e-posttransport returnerer «deaktivert» og kontakter ikke Resend. Supabase Auth sine egne innloggingsmeldinger er en egen kanal; ingen autentiseringsmelding er sendt under klargjøringen.
