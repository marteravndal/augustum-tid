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
