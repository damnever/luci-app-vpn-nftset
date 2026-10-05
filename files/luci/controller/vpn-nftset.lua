module("luci.controller.vpn-nftset", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/vpn-nftset") then return end
    local page = entry({"admin", "services", "vpn-nftset"}, cbi("vpn-nftset"), _("VPN NFTset"), 99)
    page.dependent = true
    page.acl_depends = {"luci-app-vpn-nftset"}
    entry({"admin", "services", "vpn-nftset", "catalog"}, call("action_catalog")).leaf = true
    entry({"admin", "services", "vpn-nftset", "refresh"}, post("action_refresh")).leaf = true
end

local function settings()
    local cursor = require("luci.model.uci").cursor()
    local general, domains = {}, {}
    cursor:foreach("vpn-nftset", "general", function(section) general = section; return false end)
    cursor:foreach("vpn-nftset", "dnsmasq_nftset", function(section) domains = section; return false end)
    local changes = cursor:changes("vpn-nftset") or {}
    return general, domains, next(changes) ~= nil
end

local function enabled(value, default)
    if value == nil then return default end
    return value == "1" or value == "on" or value == "true" or value == "yes" or value == "enabled"
end

local function running()
    local pid = (require("nixio.fs").readfile("/tmp/vpn-nftset/service.lock/pid") or ""):match("^%s*(%d+)%s*$")
    return pid ~= nil and require("luci.sys").call("kill -0 " .. pid .. " 2>/dev/null") == 0
end

local function allowed(level)
    local session = require("luci.dispatcher").context.authsession
    if not session then return false end
    local result = require("luci.util").ubus("session", "access", {
        ubus_rpc_session = session, scope = "uci", object = "vpn-nftset", ["function"] = level
    })
    return type(result) == "table" and result.access == true
end

function action_catalog()
    local http = require("luci.http")
    if not allowed("read") then
        http.status(403, "Forbidden")
        http.write_json({error = "permission_denied"})
        return
    end
    local fs = require("nixio.fs")
    local rules = require("vpn_nftset")
    local general, domains, pending_changes = settings()
    local sources, seen = {}, {}
    for _, subscription in ipairs({{option = "gfwlist_urls", kind = "gfw"}, {option = "domainslist_urls", kind = "plain"}}) do
        local urls = domains[subscription.option] or {}
        if type(urls) == "string" then urls = {urls} end
        for _, url in ipairs(urls) do
            local id = require("luci.sys").exec("printf '%s' " .. require("luci.util").shellquote(url) .. " | md5sum"):match("^([a-f0-9]+)")
            if id and not seen[id] then
                sources[#sources + 1] = {id = id, url = url, kind = subscription.kind}
                seen[id] = true
            end
        end
    end
    local entries = domains.domains or {}
    if type(entries) == "string" then entries = {entries} end
    local check_domain
    if http.formvalue("check") then
        local parsed = rules.parse_custom(http.formvalue("check"))
        if not parsed then
            http.status(400, "Bad Request")
            http.write_json({error = "invalid_domain"})
            return
        end
        check_domain = parsed.domain
    end
    local result, err = rules.catalog(entries, sources, {
        query = http.formvalue("q") or "", scope = http.formvalue("scope") or "downloaded",
        page = http.formvalue("page"), page_size = math.min(tonumber(http.formvalue("page_size")) or 50, 100),
        source = http.formvalue("source"), check_domain = check_domain
    }, "/etc/vpn-nftset", "/tmp/vpn-nftset")
    if not result then
        http.status(400, "Bad Request")
        http.write_json({error = err})
        return
    end
    local telegram_text = fs.readfile("/etc/vpn-nftset/telegram.cidr")
    local telegram = telegram_text and rules.parse_cidrs(telegram_text) or nil
    local cached = telegram ~= nil
    if not telegram then telegram = rules.parse_cidrs(fs.readfile("/usr/share/vpn-nftset/telegram-cidr.txt") or "") end
    result.telegram = {
        enabled = enabled(general.telegram_enabled, true), cached = cached,
        count = telegram and telegram.count or 0,
        status = (fs.readfile("/tmp/vpn-nftset/telegram.status") or (cached and "cached" or "bundled")):match("^%s*(.-)%s*$"),
        last_success = tonumber(fs.readfile("/etc/vpn-nftset/telegram.success") or ""),
        url = "https://core.telegram.org/resources/cidr.txt"
    }
    result.enabled = enabled(general.enabled, false)
    result.auto_update = enabled(domains.auto_update, true)
    result.pending_changes = pending_changes
    result.running = running()
    result.refresh_status = (fs.readfile("/tmp/vpn-nftset/refresh.status") or ""):match("^%s*(.-)%s*$")
    http.header("Cache-Control", "no-store")
    http.write_json(result)
end

function action_refresh()
    local http = require("luci.http")
    if not allowed("write") then
        http.status(403, "Forbidden")
        http.write_json({error = "permission_denied"})
        return
    end
    local general, _, pending_changes = settings()
    if pending_changes then
        http.status(409, "Conflict")
        http.write_json({error = "settings_not_applied"})
        return
    end
    if not enabled(general.enabled, false) then
        http.status(409, "Conflict")
        http.write_json({error = "service_disabled"})
        return
    end
    if running() then
        http.status(409, "Conflict")
        http.write_json({error = "update_running"})
        return
    end
    local result = require("luci.sys").call("/usr/bin/vpn-nftset-update >/tmp/vpn-nftset-refresh.log 2>&1 &")
    if result ~= 0 then
        http.status(500, "Internal Server Error")
        http.write_json({error = "update_start_failed"})
        return
    end
    http.write_json({started = true})
end
