# Contract preparation in the isolated Tid preview

HR Documentation and Employment Contract are separate portal panels. Contracts move from draft to `signing_ready`, with an immutable content/employee/employer preview snapshot. This is an internal preparation state: it neither sends email nor exposes the contract to the employee. A prepared contract can return to draft; pending or completed signature requests cannot.

The service-only `hr_contract_draft_action` RPC checks the active admin and organization, locks the row, requires the last observed `updated_at`, and audits each mutation. Only drafts can be deleted. Recipient fields from request bodies are ignored. The signing overview shows active shared-register employees; an admin identity must match a unique active registry entry. Names, phone and email are read-only. Current registry contacts are intentionally distinguished from the frozen PDF snapshot; refresh or return to draft/reprepare after changing contract details.

`start_signing` remains explicitly unavailable. The old lock-and-email action is rejected rather than sending an ambiguous notification. No simulated success, provider session or signed status is created. The signing method is BankID; additional signing methods are not implemented. Tests and code changes apply only to the test branch/project. Existing locked contracts remain downloadable.

## BankID investigation, 15 October 2026

Official Signicat documentation confirms Norwegian BankID PKI supports multiple signers on one document collection. Sign API v2 uses `PKISIGNING` with `NBID`; the final PAdES must be retrieved after all signatures are complete. Email address alone is not BankID identity verification: the documented subject validation uses the national identification number. Such identifiers must stay server-side and out of general HR responses and logs.

Sources:
- https://developer.signicat.com/identity-methods/nbid/integration-guide/sign-nbid/
- https://developer.signicat.com/docs/electronic-signing/sign-api-v2/integration-guide/
- https://developer.signicat.com/apis/electronic-signing/sign-api-v2/

Remaining activation work requires the customer's Signicat account/API access and enabled Norwegian BankID service. Before live activation: connect server-side credentials through company Integrations, create one immutable PDF with an admin and employee signer, bind and validate both identities, reserve requests idempotently, deliver each recipient's unique signing URL via configured email, verify provider completion server-side, and archive the final PDF/evidence only after both signatures. Test retries, partial email delivery, refusal, expiry and callbacks in sandbox. Never mark a contract signed from a browser redirect. Preview email suppression remains enabled.

## Verification

- `node ../augustum-transport/tests/hr-contract-ui.cjs`: separate panels, edit/save, prepare/return/delete, concurrency token, immutable recipient UI, no premature employee visibility, disabled delivery, attribute escaping.
- `tests/hr-contract-drafts.sql`: transactional rollback fixtures for lifecycle, concurrent/stale changes, organization/admin boundaries, trusted recipient snapshots, audit, provider-state restrictions and RPC grants.
- Portal TypeScript check and existing daily-control tests.
- No real contract or notification was sent; authenticated end-to-end browser/provider signing remains unverified.

## Sandbox integration, 20 October 2026

The portal now exposes platform-admin-only `hr-signing` actions in the operator workspace. `lib/signicat-contracts.ts` owns provider requests and reads the encrypted sandbox client pair; credentials never enter the Tid/browser response. The new `contract-signing` Edge Function only accepts the existing signed, nonce-protected Tid bridge with an admin claim and the operator company. It resolves the actor again and enforces active administrator membership. Browser bearer tokens alone cannot submit provider state.

`hr_signing_acquire` locks the contract, snapshots recipients from the registry, requires two different BankID test NINs and explicit test confirmation, and reserves one request per contract. An expiring exclusive lease prevents concurrent sending/status operations. NINs stay in the service-only request row and are stripped from all browser responses. The original PDF has a TEST watermark and is archived before upload. Its content cannot be edited once reserved.

Sign API v2 creates one serial-signing collection and two NBID PKISIGNING sessions with NIN subject validation. Optional email invitations are requested through Signicat only when the administrator checks the explicit email option. No invitations are sent during deployment or verification. Generic preview email suppression remains in force elsewhere. Notification acceptance does not prove delivery; the UI says invitations are requested. Each returned session is checked against the exact reference, identity, document and signing setup. A lost session-create response is recovered by unique references; POST is never repeated automatically. Ambiguous/partial creation requires reconciliation or explicit cancellation.

The UI provides individual sandbox links and manual status refresh. It does not treat redirect parameters as evidence of a signature. Only two provider-confirmed SIGNED sessions plus the matching collection output with exactly two PADES signatures permit final document download and private archival. `hr_contracts.status=signed` is set only after archive success. HR downloads for these contracts serve archived bytes, never a regenerated unsigned PDF. Users can cancel sandbox sessions; signed requests cannot be downgraded via the normal UI.

Limitations: platform operator sandbox only; production and tenant onboarding disabled. Test identities must be obtained from BankID's test service. Live BankID user interaction and provider email delivery require user testing. No callback subscription yet: status is refreshed explicitly. PDFs larger than 1.3 MB exceed the current bridge limit and remain pending with an error; signatures are not falsely marked complete. Unknown upstream create results remain protected against duplicate sends. Two existing test identities must be distinct from each other; the UI requires users to confirm they are test identities.

Verification includes `tests/hr-signicat-sandbox.sql` rollback fixtures, portal Signicat tests, HR UI tests and TypeScript. The earlier preparation-only restriction above is superseded for the operator portal sandbox; direct legacy `hr.start_signing` remains disabled.
