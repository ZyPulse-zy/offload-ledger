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

The original Athena project and deployed router are read-only. Policy tests use synthetic opaque identities and an asynchronous in-memory
backend. The separate controlled kernel tests below use private namespaces.

Local real-kernel pipeline: **164 checks passed** across two dummy WANs. Exact
CAKE budgets gated candidate admission; actual flower rules were created and
removed through fenced-run, with delayed absence, full controller restart from
a durable JSON snapshot/outbox, stale receipts and a partial-write timeout.
The unrelated rule and static CAKE roots remained unchanged; all rules skip_hw.

Process-crash extension: **65 additional checks passed**, with **7 real SIGKILL
cuts** of the complete Python adapter. These cover durable CREATE intent,
completed CREATE, uncheckpointed CREATE receipt, completed DELETE, conflicts
on either WAN, and a matching token with a different rule action. Fresh workers
restore from disk and reconcile exact readback under the same inherited fence.
No blind add/delete replay occurred; conflicting rules and journals survived.
This does not establish power-loss durability or crashes during kernel syscalls.

## Installed OpenWrt package validation (2026-10-18)

The independent ipq60xx SDK built real Lua 5.1.5-r11, liblua and
offload-ledger 0.1.0-r1 APKs using GCC 14.4.0/musl. Lua recipe and all patches
were taken from official OpenWrt commit
814759483bbcfecd7b2741838e897693b07433f4; the Lua 5.1.5 source archive SHA-256
is 2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333.
After extracting those packages into a fresh user/mount/network namespace and
chroot, actual qemu-aarch64 execution reproduced the old versioned-path load
failure and passed default `require` plus all 92,819 policy checks at the fixed
path. No LUA_PATH/LUA_CPATH override was used. Generic `LUA_DIR` installation
also matched the packaged source byte for byte. The public CI separately pins
the official OpenWrt 25.12.0 GCC 14.3.0 SDK and records its own result.

Initial partial recipe downloads failed during network timeouts; an incomplete
recipe build failed on a missing readline header. These were retained as
failures, and the final build started clean after all 24 official recipe files
were available and the Lua archive checksum was verified. No host or router
package installation, firmware boot or NSS hardware test took place.
