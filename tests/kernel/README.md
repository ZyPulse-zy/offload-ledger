# Isolated real-kernel pipeline

This test composes three independently published components:

- cake-snapshot `a2bdad1296f217542b99aa12fa5e4524e0c051ed`
- fenced-run `8cea5cd1a05898cd8131b9633af296385b4323fb`
- this offload-ledger checkout

It creates two dummy WAN devices and finite root CAKE queues in a **new network
namespace**. The CAKE reader's exact rates gate a test-only per-device candidate
budget (an 8 Mbit candidate cannot enter a 7 Mbit WAN). The Lua controller plans
rules; Python durably stores its JSON snapshot and returned action outbox before
executing bounded `tc` commands. Flower software rules encode generation and
port identity for actual readback. Every rule uses `skip_hw`.

Scenarios cover delayed withdrawal with exactly one reserved victim, complete
controller process exit and JSON checkpoint/outbox restoration, exact absence
before slot reuse, stale-generation receipts, source loss, a command timeout
after a real partial kernel write, preserved lifetime recovery history, and an
unrelated rule which must remain unchanged. No packets are generated.

The pipeline also runs `test_crash.py`. It SIGKILLs the **complete Python
adapter process**, not just its Lua policy subprocess, at seven barriers:
after durable intent but before a write, after actual CREATE, after the CREATE
receipt but before its checkpoint, after actual DELETE, and before recovery
against three conflicting-rule cases. The fence confirms descendant cleanup
before another transaction starts. A fresh worker restores only the disk
journal, reads actual rules under the same writer fence, and either confirms
the exact effect or executes the missing write. It never blindly replays an
add/delete. Conflicts on either device, and a matching token with a different
rule action, retain both the pending journal and the existing kernel rule.

These are process-crash tests, not power-loss/storage durability or controller
crashes during an in-flight kernel syscall. The test adapter owns one private
slot, starts with a known empty pool, and has no arbitrary hardware discovery.

With built native component paths, Lua 5.1 and lua-cjson:

```sh
OFFLOAD_LAB_PARENT_NETNS="$(readlink /proc/self/ns/net)" unshare -Urn \
  python3 tests/kernel/test_pipeline.py /absolute/fenced-run \
  /absolute/cake-snapshot /usr/bin/lua5.1
```

The script refuses root/kernel writes unless the namespace differs from the
supplied parent. CI uses root to create a private network namespace on runners
which restrict unprivileged user mappings; it does not change that policy.

This is a controlled **test adapter**, not an NSS or production hardware backend.
It starts from a private empty rule pool and owned journal, does not transmit
traffic, and makes no hardware/firmware, throughput or game-quality claim.
