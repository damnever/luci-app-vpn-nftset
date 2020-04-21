dnsmasq-full could be optional, but it is required :D.
You may need to configure the firewall and other things as well.

```
cd openwrt-sdk-*
git clone git@github.com:damnever/luci-app-vpn-ipset.git package/luci-app-vpn-ipset

# Compile po2lmo if not exist.
pushd package/luci-app-vpn-ipset/tools/po2lmo
make && sudo make install
popd

make menuconfig    # Select: LuCI -> 3. Applications
make package/luci-app-vpn-ipset/compile V=99
```

TODO:
- [ ] trancate parsed domains? (e.g. avatars0.githubusercontent.com -> githubusercontent.com).
- [ ] ipv6 support? (ip -6 route & ip6tables)
