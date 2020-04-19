
module("luci.controller.vpn-ipset", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/vpn-ipset") then
        return
    end

    entry({"admin", "services", "vpn-ipset"}, cbi("vpn-ipset"), _("VPN-IPset"), 99).dependent = true
end
