include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-vpn-nftset
PKG_VERSION:=2.0.1
PKG_RELEASE:=1

PKG_LICENSE:=GPLv3
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Xiaochao Dong <the.xcdong@gmail.com>

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-vpn-nftset
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=LuCI Support for NFTables based VPN Routing Rules
	PKGARCH:=all
	DEPENDS:=+dnsmasq-full +coreutils-base64 +wget +ca-bundle +ca-certificates +libustream-mbedtls
endef

define Package/luci-app-vpn-nftset/description
	LuCI Support for NFTables Based VPN Routing Rules.
endef

define Build/Prepare
	$(foreach po,$(wildcard ${CURDIR}/files/luci/i18n/*.po), \
		po2lmo $(po) $(PKG_BUILD_DIR)/$(patsubst %.po,%.lmo,$(notdir $(po)));)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-vpn-nftset/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	if [ -f /etc/uci-defaults/luci-vpn-nftset ]; then
		( . /etc/uci-defaults/luci-vpn-nftset ) && \
		rm -f /etc/uci-defaults/luci-vpn-nftset
	fi
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
fi
exit 0
endef

define Package/luci-app-vpn-nftset/conffiles
/etc/config/vpn-nftset
endef


define Package/luci-app-vpn-nftset/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/vpn-nftset.*.lmo $(1)/usr/lib/lua/luci/i18n/
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/luci/controller/*.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) ./files/luci/model/cbi/*.lua $(1)/usr/lib/lua/luci/model/cbi/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/root/etc/config/vpn-nftset $(1)/etc/config/vpn-nftset
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/root/etc/init.d/vpn-nftset $(1)/etc/init.d/vpn-nftset
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/root/etc/hotplug.d/iface/99-vpn-nftset $(1)/etc/hotplug.d/iface/99-vpn-nftset
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/root/etc/uci-defaults/luci-vpn-nftset $(1)/etc/uci-defaults/luci-vpn-nftset
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/root/usr/bin/vpn-nftset-rulegenerator $(1)/usr/bin/vpn-nftset-rulegenerator
endef

$(eval $(call BuildPackage,luci-app-vpn-nftset))
