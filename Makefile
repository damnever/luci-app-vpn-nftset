include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-vpn-ipset
PKG_VERSION:=0.0.6
PKG_RELEASE:=1

PKG_LICENSE:=GPLv3
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Xiaochao Dong <dxc.wolf@gmail.com>

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-vpn-ipset
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=LuCI Support for IPset based VPN Routing Rules
	PKGARCH:=all
	DEPENDS:=+dnsmasq-full +coreutils-base64 +wget +ca-bundle +ca-certificates +libustream-openssl
endef

define Package/luci-app-vpn-ipset/description
	LuCI Support for IPset based VPN Routing Rules.
endef

define Build/Prepare
	$(foreach po,$(wildcard ${CURDIR}/files/luci/i18n/*.po), \
		po2lmo $(po) $(PKG_BUILD_DIR)/$(patsubst %.po,%.lmo,$(notdir $(po)));)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-vpn-ipset/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	if [ -f /etc/uci-defaults/luci-vpn-ipset ]; then
		( . /etc/uci-defaults/luci-vpn-ipset ) && \
		rm -f /etc/uci-defaults/luci-vpn-ipset
	fi
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
fi
exit 0
endef

define Package/luci-app-vpn-ipset/conffiles
/etc/config/vpn-ipset
endef


define Package/luci-app-vpn-ipset/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/vpn-ipset.*.lmo $(1)/usr/lib/lua/luci/i18n/
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/luci/controller/*.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) ./files/luci/model/cbi/*.lua $(1)/usr/lib/lua/luci/model/cbi/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/root/etc/config/vpn-ipset $(1)/etc/config/vpn-ipset
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/root/etc/init.d/vpn-ipset $(1)/etc/init.d/vpn-ipset
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/root/etc/uci-defaults/luci-vpn-ipset $(1)/etc/uci-defaults/luci-vpn-ipset
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/root/usr/bin/vpn-ipset-rulegenerator $(1)/usr/bin/vpn-ipset-rulegenerator
endef

$(eval $(call BuildPackage,luci-app-vpn-ipset))
