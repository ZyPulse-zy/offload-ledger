LUA ?= lua
PREFIX ?= /usr
DESTDIR ?=
LUA_VERSION ?= 5.1
LUA_DIR ?= $(PREFIX)/share/lua/$(LUA_VERSION)
test:
	$(LUA) tests/test_ledger.lua lua/offload_ledger.lua
test-json:
	$(LUA) tests/test_json.lua lua/offload_ledger.lua
example:
	$(LUA) examples/delayed-retirement.lua lua/offload_ledger.lua
install:
	install -d "$(DESTDIR)$(LUA_DIR)"
	install -m 0644 lua/offload_ledger.lua "$(DESTDIR)$(LUA_DIR)/"
openwrt-package:
	mkdir -p build/openwrt/offload-ledger/lua
	cp packaging/openwrt/Makefile COPYING build/openwrt/offload-ledger/
	cp lua/offload_ledger.lua build/openwrt/offload-ledger/lua/
.PHONY: test test-json example install openwrt-package
