# Validation (2026-10-18)

- Actual Lua 5.1.5, 5.2.4, 5.3.6 and 5.4.8 interpreters each pass **92,819
  checks**, including 2,172 deterministic randomized fault-injection steps.
- Capacity cases cover 1, 2, 32, 64 and 128 slots; delayed removal reserves one
  victim per demand and requires exact absence before reuse.
- Real lua-cjson roundtrips pass with Lua 5.1, 5.3 and 5.4, including a sparse
  slot map and 14-digit integer tokens. The test-only JSON module was not
  available for Lua 5.2; its actual core/trace tests passed independently.
- AArch64/musl: the same 92,819-check policy suite passed under QEMU user mode
  using an interpreter cross-built with OpenWrt GCC 14.4.0. Interpreter source
  was official Lua 5.1.5, SHA-256
  `2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333`,
  verified against https://www.lua.org/ftp/. This is emulated architecture/libc
  compatibility for pure policy code, not target-hardware/firmware validation.
- The runnable synthetic delayed-retirement backend passes.
- Snapshot restoration preserves budgets and pending tokens. Malformed clock,
  ownership, phases and reservations are rejected by schema validation.

These are policy/serialization tests. There is no NSS firmware backend, live
router integration, deployed writer, conntrack event source, measured network
benefit or game-performance validation. Receipt correctness and durable
snapshot/action-outbox persistence remain explicit adapter obligations.

The original Athena project and deployed router are read-only. Tests operate
on synthetic opaque identities and an asynchronous in-memory backend only.

Local real-kernel pipeline: **164 checks passed** across two dummy WANs. Exact
CAKE budgets gated candidate admission; actual flower rules were created and
removed through fenced-run, with delayed absence, full controller restart from
a durable JSON snapshot/outbox, stale receipts and a partial-write timeout.
The unrelated rule and static CAKE roots remained unchanged; all rules skip_hw.
