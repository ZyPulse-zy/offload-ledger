include $(TOPDIR)/rules.mk

PKG_NAME:=offload-ledger
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=COPYING
PKG_MAINTAINER:=Yuen Su <zypulsecore@gmail.com>

include $(INCLUDE_DIR)/package.mk

define Package/offload-ledger
  SECTION:=libs
  CATEGORY:=Libraries
  SUBMENU:=Lua
  TITLE:=Finite asynchronous offload admission and recovery ledger
  URL:=https://github.com/ZyPulse-zy/offload-ledger
  DEPENDS:=+lua
  PKGARCH:=all
endef

define Package/offload-ledger/description
 Pure Lua policy module with generation-specific retirement and bounded
 recovery across source gaps and checkpoints. No service or hardware backend.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./lua/offload_ledger.lua ./COPYING $(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

define Package/offload-ledger/install
	$(INSTALL_DIR) $(1)/usr/share/lua
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/offload_ledger.lua $(1)/usr/share/lua/
endef

$(eval $(call BuildPackage,offload-ledger))
