# LuCI VPN NFTset

Manage domain and IP rules for VPN routing on OpenWrt using dnsmasq and nftables.
Configure the VPN interface and firewall forwarding before use. Requires
`dnsmasq-full` with nftset support; Lua LuCI pages require `luci-compat`, which is
declared as a package dependency.

For iptables support, see the
[old branch](https://github.com/damnever/luci-app-vpn-nftset/tree/iptables).

## Build

With Docker running, build using the OpenWrt 23.05.5 SDK for MediaTek MT7623:

```sh
./scripts/build-docker.sh
```

The script pulls `docker.io/openwrt/sdk:mediatek-mt7623-v23.05.5` and writes the
validated package to `bin/luci-app-vpn-nftset_*_all.ipk`.

Copy the package to the router, then install it with the configured OpenWrt feeds:

```sh
opkg update
opkg install /tmp/luci-app-vpn-nftset_*_all.ipk
```

## Test

With Lua 5.1 or LuaJIT, Python 3, Node.js 18+ and curl installed:

```sh
./tests/run.sh
```

GitHub Actions runs the tests on pushes and pull requests.
