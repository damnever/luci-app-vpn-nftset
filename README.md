dnsmasq-full could be optional, but it is required :D.
You may need to configure the firewall and other things as well.

Refer to [this old branch](https://github.com/damnever/luci-app-vpn-nftset/tree/iptables) for iptables support.

```
cd openwrt-sdk-*
git clone https://github.com/damnever/luci-app-vpn-nftset.git package/luci-app-vpn-nftset

# Compile po2lmo if not exist.
pushd package/luci-app-vpn-nftset/tools/po2lmo
make && sudo make install
popd

make menuconfig    # Select: LuCI -> 3. Applications
make package/luci-app-vpn-nftset/compile V=99
```

TODO:
- [ ] trancate parsed domains? (e.g. avatars0.githubusercontent.com -> githubusercontent.com).
