module("luci.controller.vpn-nftset", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/vpn-nftset") then
        return
    end

    entry({ "admin", "services", "vpn-nftset" }, cbi("vpn-nftset"), _("VPN-NFTset"), 99).dependent = true
end
