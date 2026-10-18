# Installed OpenWrt package regression

`test-package.py` reads three APKs built by a disposable AArch64/musl SDK:
offload-ledger, Lua and liblua. It extracts them into a temporary root, copies
the SDK's musl runtime and a static qemu-aarch64, and starts the actual OpenWrt
interpreter under a fresh user/mount/network namespace and chroot. Neither the
host's Lua modules nor this checkout are visible to that interpreter.

```sh
python3 tests/openwrt/test-package.py \
  --sdk /path/to/disposable-sdk --qemu /usr/bin/qemu-aarch64-static \
  --report openwrt-install.json
```

Linux unprivileged user namespaces, `unshare`, `chroot`, the SDK's apk extractor
and a **static** emulator are required. The script never installs a package or
changes the SDK, host or router. SDK building itself belongs in the independent
directory described in the top-level README.

It first moves the extracted module into the previous versioned directory and
proves that default `require` fails. It restores the package's correct path,
clears inherited Lua loader overrides, checks the interpreter's actual default
path and runs the same complete 92,819-check policy suite via `require`. It also
checks the generic installer's `LUA_DIR` override against the package's module.

The CI pins OpenWrt source 814759483bbcfecd7b2741838e897693b07433f4 for the
complete Lua recipe/patch series and the official OpenWrt 25.12.0 ipq60xx
GCC 14.3.0/musl SDK archive by SHA-256. It builds the real interpreter,
shared library and module packages before running this test. Local SDK evidence
may use another explicitly recorded toolchain; do not conflate those results.

This proves the installed module, default lookup and policy execution on the
tested OpenWrt Lua userspace ABI. It does not boot a firmware image, contact a
router, exercise NSS hardware or establish throughput/latency improvements.
