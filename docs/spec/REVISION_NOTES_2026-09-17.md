# Revision Notes — 2026-09-17

This revision makes TypeSafeSDK **0.4.0** the only supported semantic-client baseline for the greenfield Autonomic implementation and grounds the runtime assumptions against the supplied Pristine **0.4.0** source.

Key changes:

- TypeSafe dependency baseline moved to `~> 0.4.0`; no 0.2/0.3 compatibility support remains.
- Native `TypeSafeSDK.Prepared.fingerprint/1` replaces the adapter-local manifest SHA-256 contract emulation.
- Native TypeSafe strict `response_contract` enforcement replaces local concrete-model checking and rejects unexpected answer IDs.
- Native TypeSafe `max_request_bytes:` replaces approximate whole-request accounting while the independent Autonomic evidence-window budget remains.
- `Autonomic.Typesafe.Bank` is refactored onto `TypeSafeSDK.OTP.Server`, using a dedicated package-owned `Autonomic.Typesafe.Tasks` supervisor and finite `max_in_flight` so network work no longer blocks the bank GenServer.
- The adapter always requires `:unary_cancellation` and `:cancellation_cleanup`; TypeSafe delegates verification to Pristine and the supplied Pristine 0.4 Finch transport advertises both as supported.
- Response provenance uses `TypeSafeSDK.Response.metadata/1` plus answer helpers; TypeSafe 0.4 per-answer telemetry is available directly from the SDK and is not duplicated by Autonomic.
- A future answer type under a required requested sensor key remains an Autonomic fail-closed domain rule because the fixed production bank requires known Noul/Choice/Score families.
- Production client hot-swap support is removed. Tests disable autostart and inject `TypeSafeSDK.Test` clients when supervising the bank.
- Deterministic tests now cover exact request-budget failure, SDK model-contract rejection, bounded OTP responsiveness/overload, required runtime capabilities and semantic outage.
- The live gate remains mandatory and records only non-secret structural provenance.

The five kernel invariants, Linux containment model, effect transaction protocol, durable authority, Homeostat, GenStage backpressure, snapshot/repair design and acceptance philosophy are unchanged.
