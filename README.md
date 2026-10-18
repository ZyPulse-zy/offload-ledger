# offload-ledger

A pure Lua state machine for scheduling a limited pool of asynchronous hardware
offload rules. It handles admission, priority preemption, leases, retry budgets
and checkpoint recovery. A backend adapter executes the planned actions and
reports rule creation or removal.

Requires Lua 5.1–5.4; no runtime dependencies.

## Installation

```sh
make install PREFIX=/usr LUA_VERSION=5.4
# OpenWrt module path:
make install DESTDIR=/path/to/staging LUA_DIR=/usr/share/lua
```

`LUA_DIR` defaults to `$(PREFIX)/share/lua/$(LUA_VERSION)`. Check
`lua -e 'print(package.path)'` for the interpreter's module search path.

## Example

```lua
local M = require('offload_ledger')
local config = {epoch='unique-boot-and-controller-instance', slots=32, records=256}
local ledger = M.new(config)
local actions = ledger:step(1000, true, {
  {id='flow-lifecycle-id', priority=10, benefit=120, valid_until=6000}
})
```

Time is monotonic integer milliseconds. Higher `priority` wins; `benefit`
breaks ties. Candidates must already satisfy the controller's bandwidth and
QoS budgets. Each action identifies its operation, slot, lifecycle and
`epoch`/`sequence` generation; the backend must retain that identity in receipts.

## API

| Method | Purpose |
| --- | --- |
| `M.new(config)` | Create a ledger |
| `step(now, fresh, flows)` | Plan create, renew or revoke actions from a dense candidate array |
| `receipt(now, r)` | Process `created`, `failed` or `absent` for an exact slot/epoch/sequence; return actions and token-match status |
| `end_lifecycle(now, id)` | Close a verified lifecycle and retire its rules |
| `snapshot()` | Deep-copy versioned state with JSON-compatible slot keys |
| `M.restore(config, state)` | Validate and restore ownership, reservations and retry history |
| `status()` | Report slot, reservation and history counts |

Retry history survives source gaps, priority changes, slot reuse and restores.
A successful creation does not reset the lifecycle's spent budget. Stale source
data withdraws rules without admitting or renewing candidates. A slot remains
occupied until an exact `absent` receipt confirms removal; a timeout or revoke
command's success is insufficient. Creation is never retransmitted automatically.

High-priority candidates reserve a retiring victim's slot. History capacity is
bounded: a full ledger declines new identities rather than discarding retry
history. Records are reclaimed after verified lifecycle completion and rule
absence, not by age.

## Backend integration

- Use lifecycle IDs that distinguish reused connection IDs, including birth,
  zone and boot identity where applicable. Call `end_lifecycle` only after a
  verified lifecycle end.
- Validate receipt provenance and the exact rule generation. Continue processing
  retirement receipts during source outages.
- Atomically persist the resulting snapshot and action outbox before issuing
  writes. Restore both after a crash and reconcile uncertain actions before
  replay; the library does not reissue lost actions.
- Coordinate writers using a shared exclusion protocol. Initialize against a
  confirmed empty rule pool or restore a checkpoint for the same owned pool.
- Use monotonic time from the checkpoint's boot. Retire old hardware state
  before beginning a new epoch after a reboot or ownership change.

## Configuration

Defaults are 32 slots, 256 history records, two retries with 1000/3000 ms
backoffs, a 6000 ms creation deadline and a 6000 ms maximum candidate lease.

Supported limits: 1–4096 slots; slots–65536 records; 0–16 retries with matching
backoffs; 1–600000 ms deadlines; 1–3600000 ms retry backoffs; priorities 0–255.
Lifecycle IDs and epochs accept 1–128 printable ASCII bytes. Integers are capped
at 99999999999999 for Lua/JSON roundtrips. Candidate/victim scanning is
O(records × slots).

## Tests and OpenWrt package

```sh
make LUA=lua5.1 test
make LUA=lua5.1 test-json  # requires lua-cjson
make LUA=lua5.1 example
make openwrt-package
```

Copy `build/openwrt/offload-ledger` into an OpenWrt SDK's `package/` directory,
then run `make package/offload-ledger/compile V=s` in that SDK. The package
depends on `lua` and installs the module in `/usr/share/lua`.

See [VALIDATION.md](VALIDATION.md) for state-machine tests,
[the kernel pipeline](tests/kernel/README.md) for rule readback and crash
recovery tests, and [package tests](tests/openwrt/README.md) for OpenWrt loader
checks. The kernel pipeline uses software rules with `skip_hw`; hardware
behavior requires backend-specific validation.

## License

GPL-2.0-only; see [COPYING](COPYING).
Source history and attribution are in [PROVENANCE.md](PROVENANCE.md).
