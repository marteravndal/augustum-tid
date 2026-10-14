# Augustum Tid – portalintegrasjon i test

Status 2026-10-14. Kun testgrener; ingen produksjonsdomener flyttes.

## Kilde og tilgang

Apart-grunnlag: 3038059f1b83592b55514067e1a49dbecf55adc3. Ny database: krllcibcfuzsvjybqaua. Portalgren: test/tid-integration-20261014. Tid-gren: test/apart-foundation-20261014.

Portalen er kilde for selskap, modultilgang, rolle, ansatte og oppdragsgivere. `tid_employee_identity` leser innlogget brukers faktiske e-post på serveren og finner aktiv ansatt i samme selskap. Videre mapping bruker stabile ID-er. Administrator uten ansattprofil får en teknisk administrasjonsprofil som ikke vises i timefordelingen.

Portalen kontrollerer tilgang ved hvert API-kall, signerer innloggingsforespørsler med kort levetid, SHA-256 av innhold og engangsnonce. Tid bekrefter signaturen i en servicebegrenset funksjon. Lokale Auth-identiteter bruker ugyldige skygge-e-postadresser; `generateLink` og `verifyOtp` kjøres på serveren uten e-postutsending. Øktene forblir på serveren og caches i maksimalt to minutter. Endret rolle, aktiv status og ansattliste endrer cache-nøkkelen. Eksisterende aktive Auth-økter brukes aldri som portaltilgang.

Edge-funksjoner har plattformens JWT-port deaktivert fordi portal-session bruker HMAC og de øvrige bruker eksplisitt `auth.getUser(token)` samt aktiv ansatt/organisasjonskontroll. Worker bruker sin egen nøkkel. Ingen funksjon er åpen for uautorisert virksomhetsdata.

## Fordeling og oppgjør

`transport_allocations` lagrer kilde-ID, oppdragsgiver-ID, intervall, kildeversjon, revisjon og godkjenner. Kun administrator kan fordele avsluttet arbeid. Intervaller må ligge innenfor kilden, uten overlapp og innenfor én Oslo-dato. Pauser kan utelates. Fravær importeres ikke som fakturerbart arbeid. Sommertidens tvetydige klokkeslett må avklares manuelt.

Hver Tid-organisasjon får en separat `settlement_company_id`. Oppgjørstjenesten bruker denne ID-en til å isolere testsjåfører, testpriser og oppgjør fra ordinær drift. Portalen validerer oppdragsgiver og ansatt mot riktig selskap før den signerer referansene. E-post, avstemming og øvrige backend-ruter er ikke tilgjengelige fra testadapteren.

Overføring lager kun et nytt utkast. Hvis et oppgjør allerede finnes for kunde/dato, avvises overføringen. Korrigering gjøres manuelt i testoppgjøret; automatisk oppdatering og endringsvarsler er ikke implementert. Backend kontrollerer revisjon og låser per selskap, slik at samtidige importer ikke dupliserer. Manglende sjåførkobling eller prisavtale stopper importen. Fast pris over flere intervaller for samme sjåfør må avklares manuelt.

## Testgjennomgang

1. Åpne portalens `/tid-test` i forhåndsvisningen med vanlig portalinnlogging.
2. Gå til Testoppgjør: registrer testsjåfør og knytt den til en ansatt; legg inn prisavtale for en eksisterende oppdragsgiver.
3. Gå til Fordel timer, velg en passert dato og registrer avsluttede testtimer eller bruk stempling via vaktlisten.
4. Fordel intervaller på oppdragsgivere, godkjenn, og opprett testutkast.
5. Kontroller utkastet. Testposter påvirker ikke ordinært dashboard eller kunderapporter.

## Verifisert

57 grunnlagstester og 15 pris-/integrasjonstester består. Tjenestetester har bekreftet signert innlogging, replay-avvisning, timeopprettelse, fordeling, overlapps-/versjonskontroll og overføring av 10 timer med 30 % overtid til et testutkast på 3 180 kroner. Duplikatlagring avvises, og utkast teller ikke som omsetning. jsdom har startet portalgrensesnittet mot de publiserte testtjenestene uten token i nettleserlagring. Innlogget navigasjon i en ekte nettleser er ikke verifisert.

Sikkerhetsrådgiveren viser tilsiktet RLS uten klientpolicy på fem serverinterne tabeller. Passordlekkasjekontroll er deaktivert i testprosjektet; testidentiteter har tilfeldige servergenererte passord og brukes via portalen. Før ekte passordinnlogging må dette vurderes: https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection

## Før produksjon

Bekreft vaktlistekrav, lønnstillegg/normtid, nattarbeid, varsler, dokumentflyt og regler for korrigert import. Gjennomgå migrasjoner mot eksisterende database separat; grunnmigrasjonene må aldri kjøres samlet mot gammel Augustum Tid eller portalens database. Virksomhets-e-post skal først knyttes til felles Integrasjoner etter eksplisitt test av mottakere/avsender.
