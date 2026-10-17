# offload-ledger

A pure Lua state machine for controllers with a limited pool of asynchronous
hardware/offload rules. It plans admission, priority preemption, leases and
bounded recovery without assuming a command exit or missing observation proves
that an old hardware rule has disappeared.

It contains no NSS ABI, device paths, IP tuple parser, fixed WAN count, routing
changes or hardware I/O. An adapter supplies already-qualified candidates and
validated, generation-specific receipts. Lua 5.1–5.4; no runtime dependencies.
GPL-2.0-only. See [PROVENANCE.md](PROVENANCE.md).

## Why keep a separate ledger?

A transient classification source gap can empty a desired-flow list. Clearing
recovery counters along with that list can give the same conntrack lifecycle a
fresh retry budget after every gap. Here, a flow's spent budget survives source
loss, missing rows, priority changes, hardware slot reuse and checkpoint restore.
Only an explicit, verified lifecycle end permits forgetting it.

Similarly, a waiting high-priority flow reserves one victim slot while removal
is in flight. A delayed absence receipt cannot cause it to evict more victims,
and another low-priority candidate cannot take the promised slot.

## Minimal use

```lua
local M = require('offload_ledger')
local config = {epoch='unique-boot-and-controller-instance', slots=32, records=256}
local ledger = M.new(config)
local actions = ledger:step(1000, true, {
  {id='opaque-zone-ct-id-and-birth-identity', priority=10,
   benefit=120, valid_until=6000}
})
```

Time is integer monotonic milliseconds. `priority` is a logical scheduling
priority (larger wins), **not** a DSCP value or firmware queue ID. `benefit` breaks
priority ties; low-benefit active work is the preferred victim. All candidates
must already satisfy the caller's per-WAN, per-host and QoS budgets. The library
does not estimate bandwidth or identify games from packet size.

Returned actions contain `op`, `slot`, `id`, `epoch`, `sequence`, `priority`,
`valid_until` and `reason`. Slots are 1-based. A backend must bind every operation
to the exact epoch/sequence generation and preserve that identity in receipts.

| API | Contract |
| --- | --- |
| `step(now, fresh, flows)` | Plan CREATE/renew/revoke actions for a dense candidate array. Stale source withdraws once; it never creates/renews. Missing rows cannot erase history. |
| `receipt(now, r)` | Accept `created`, `failed` or `absent`, with exact `slot`, `epoch`, `sequence`. Returns actions and whether the current token matched. A matched receipt need not change phase. |
| `end_lifecycle(now, id)` | Call only after a separately verified conntrack/lifecycle end. Withdraw live ownership; retain its record until exact absence. |
| `snapshot()` | Deep-copy versioned state. Slot keys are canonical strings for JSON object roundtrips, including sparse slots. |
| `M.restore(config, state)` | Validate configuration, capacity, clock, tokens, ownership, phase and reservation relationships. Preserve pending hardware ownership and retry counters. |
| `status()` | Counts of active/creating/retiring slots, reservations, history and exhausted records. |

A failed or unknown initial CREATE consumes one recovery failure when revoked
or proven absent; duplicate receipts cannot charge it twice. Defaults allow an
initial attempt plus two retries, with 1000/3000 ms backoffs. A successful CREATE
does not reset the lifecycle budget. A known active rule withdrawn normally for
source/lease loss does not consume a failure. No slot is free until an exact
`absent` receipt arrives, even after a creation timeout or successful revoke call.

## Adapter obligations

This is policy code, not a hardware backend or a persistence service:

1. Prove lifecycle identity, including birth, zone and boot where applicable.
   Reused numeric CT IDs or a five-tuple alone are insufficient. Never call
   `end_lifecycle` merely because a source sample is missing or stale.
2. Validate receipt provenance and exact hardware rule identity. `created`
   means actual backend creation acknowledgment; `absent` means confirmed rule
   absence/never-created for this exact generation. Missing debug output,
   CREATE ACK, a command timeout or process exit is not an absence receipt.
3. Atomically persist **the resulting snapshot and returned action outbox before
   issuing writes**. Restore both after a crash. The library does not reissue a
   lost returned action; it conservatively retains ownership. An adapter must
   reconcile uncertain commands and make any replay generation-safe. Never
   turn failed journal persistence into permission to write.
4. Fence overlapping writers (for example with `fenced-run` or the platform's
   stronger native transaction protocol). Start on an empty, confirmed rule
   pool, or restore the same owned pool from a trustworthy checkpoint. Do not
   construct an empty ledger over possibly live unknown rules.
5. Feed monotonic time from the same boot as the checkpoint. After a reboot or
   owner change, prove old hardware state is retired before starting a new
   unique epoch. Arbitrary restored state is not proof of device ownership.
6. Continue observing retirement receipts even when no fresh classification
   source is available. A permanently unknown backend remains conservatively
   occupied; the library cannot manufacture firmware confirmation.

CREATE is never retransmitted automatically. A timed-out pending CREATE is
revoked, charged once and remains occupied. Freshness affects admissions, while
validated retirement receipts can release ownership during a source outage.

History is bounded and is not evicted by an LRU or TTL. A full ledger declines
new identities, preserving already-spent budgets. Choose `records` larger than
`slots` if priority demands must wait while other lifecycle histories remain.
Never reclaim history based on age alone. Unused, never-attempted reservations
may be discarded safely.

## Configuration and limits

Defaults: 32 slots, 256 records, 2 retries, `{1000,3000}` ms backoffs, 6000 ms
creation deadline and 6000 ms maximum candidate lease. Configurable limits:
1–4096 slots, slots–65536 records, 0–16 retries (supply matching backoffs),
1–600000 ms deadlines, 1–3600000 ms retry backoffs, priorities 0–255.
Lifecycle IDs and epoch strings use 1–128 printable ASCII bytes.
Integers are capped at 99999999999999 so tokens and times can roundtrip through
Lua double arithmetic and ordinary 14-significant-digit lua-cjson encoding.
The generation space fails closed before exhaustion.

Candidate selection is deterministic. Work is bounded by configured capacities;
worst-case candidate/victim scanning is O(records × slots), so choose router-sized
limits and budget controller CPU time. This library makes no hard timing claim.

## Tests and runnable simulation

```sh
make LUA=lua5.1 test
make LUA=lua5.1 test-json  # test-only dependency: lua-cjson
make LUA=lua5.1 example   # synthetic delayed-removal backend; no network writes
```

Tests cover stale/duplicate/out-of-order receipts, creation deadlines, leases,
source gaps, lifetime retry exhaustion, priority reservations, full history,
checkpoint corruption, JSON sparse-slot/counter roundtrips and deterministic
fault-injection traces against an asynchronous fake backend that forbids
replacement before confirmed absence. See [VALIDATION.md](VALIDATION.md).
They are state-machine evidence, not proof of NSS firmware behavior, target
hardware compatibility, network performance or game latency. No original router
or Athena deployment is modified by this project.

A [real-kernel pipeline test](tests/kernel/README.md) composes this module with
pinned cake-snapshot and fenced-run builds. It validates two-WAN budget input,
actual flower-rule readback and durable outbox recovery inside a private network
namespace. These are software rules with skip_hw, not an NSS backend.

The isolated kernel pipeline also exercises complete adapter SIGKILL recovery
at seven durable-state/write boundaries, with exact rule readback under the
writer fence and conservative conflict handling. See
[the test protocol and limits](tests/kernel/README.md).
