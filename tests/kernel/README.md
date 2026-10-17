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
