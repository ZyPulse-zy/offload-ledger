LUA ?= lua
PREFIX ?= /usr
DESTDIR ?=
test:
	$(LUA) tests/test_ledger.lua lua/offload_ledger.lua
test-json:
	$(LUA) tests/test_json.lua lua/offload_ledger.lua
example:
	$(LUA) examples/delayed-retirement.lua lua/offload_ledger.lua
install:
	install -d $(DESTDIR)$(PREFIX)/share/lua/5.1
	install -m 0644 lua/offload_ledger.lua $(DESTDIR)$(PREFIX)/share/lua/5.1/
.PHONY: test test-json example install
