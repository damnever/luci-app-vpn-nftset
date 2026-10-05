local rules = require("vpn_nftset")
local uci = luci.model.uci.cursor()
local m = Map("vpn-nftset", translate("VPN NFTset"))
m.template = "vpn-nftset/map"
m.vpn_groups = {
    {id = "domains", title = translate("Domains"), options = {}},
    {id = "routing", title = translate("Routing & DNS"), options = {}},
    {id = "subscriptions", title = translate("Subscriptions"), options = {}},
    {id = "advanced", title = translate("Advanced"), options = {}}
}

local general = m:section(TypedSection, "general")
general.anonymous = true
local dns = m:section(TypedSection, "dnsmasq_nftset")
dns.anonymous = true

local function option(group, section, class, name, title, description)
    local field = section:option(class, name, title, description)
    field.index = #section.children
    table.insert(m.vpn_groups[group].options, field)
    return field
end

local o = general:option(Flag, "enabled", translate("Enable VPN rules"))
o.index = #general.children
o.rmempty = false
m.vpn_enabled = o

o = option(2, general, Value, "interface", translate("VPN interface"))
o:value("_nil_", translate("Only populate NFTsets"))
uci:foreach("network", "interface", function(section)
    local name = section[".name"]
    local ifname = section.device or section.ifname or name
    o:value(ifname, string.format("%s (%s)", name, section.proto or ifname))
end)
o.default = "_nil_"
o.rmempty = false

o = option(2, dns, DynamicList, "dns_servers", translate("DNS servers"),
    translate("IP address or hostname, optionally followed by #port. Leave empty to use your normal DNS."))
o.placeholder = "127.0.0.1#5300"
function o.validate(self, value)
    local values = type(value) == "table" and value or {value}
    local normalized = {}
    for _, server in ipairs(values) do
        if server:match("%S") then
            local result, err = rules.normalize_dns(server)
            if not result then return nil, translate(err) end
            normalized[#normalized + 1] = result
        end
    end
    return normalized
end

o = option(2, general, DynamicList, "ip_addresses", translate("Manual IP addresses"),
    translate("IPv4, IPv6 or CIDR ranges. These are kept independently of subscriptions."))
o.placeholder = translate("8.8.8.8 or 91.108.56.0/22")
function o.validate(self, value)
    local values = type(value) == "table" and value or {value}
    local present = {}
    for _, address in ipairs(values) do if address:match("%S") then present[#present + 1] = address end end
    if #present == 0 then return {} end
    local parsed = rules.parse_cidrs(table.concat(present, "\n"))
    if not parsed then return nil, translate("Enter valid IPv4, IPv6 or CIDR ranges.") end
    local addresses = {}
    for _, address in ipairs(parsed.v4) do addresses[#addresses + 1] = address end
    for _, address in ipairs(parsed.v6) do addresses[#addresses + 1] = address end
    return addresses
end

o = option(1, dns, TextValue, "domains", translate("Custom domains"))
o.template = "vpn-nftset/domains"
o.rows = 8
function o.cfgvalue(self, section)
    if self.tag_error[section] then return self:formvalue(section) end
    local value = self.map:get(section, "domains") or {}
    return type(value) == "table" and table.concat(value, "\n") or value
end
function o.validate(self, value)
    local entries, seen, line = {}, {}, 0
    for entry in (value .. "\n"):gmatch("([^\n]*)\n") do
        line = line + 1
        entry = entry:match("^%s*(.-)%s*$")
        if entry ~= "" then
            local parsed, err = rules.parse_custom(entry)
            if not parsed then
                return nil, translatef("Invalid custom domain on line %d: %s", line, translate(err))
            end
            local normalized = parsed.domain .. (parsed.dns and "/" .. parsed.dns or "")
            if not seen[normalized] then
                seen[normalized] = true
                entries[#entries + 1] = normalized
            end
        end
    end
    return table.concat(entries, "\n")
end
function o.write(self, section, value)
    local entries = {}
    for entry in value:gmatch("[^\n]+") do entries[#entries + 1] = entry end
    return self.map:set(section, "domains", entries)
end

o = option(3, dns, Flag, "auto_update", translate("Automatic updates"),
    translate("Updates at startup and daily at 04:04. Failed downloads keep the last working list."))
o.default = "1"
o.rmempty = false

o = option(3, general, Flag, "telegram_enabled", translate("Telegram IP subscription"),
    translate("Uses Telegram's official IP ranges, with a bundled fallback for the first run."))
o.default = "1"
o.rmempty = false

local function source_urls(name, title, description)
    local field = option(3, dns, DynamicList, name, title, description)
    field.placeholder = "https://example.com/list.txt"
    function field.validate(self, value)
        local values = type(value) == "table" and value or {value}
        local present = {}
        for _, url in ipairs(values) do
            url = url:match("^%s*(.-)%s*$")
            if url ~= "" then
                if not url:match("^https?://[^%s]+$") then
                    return nil, translate("Enter an HTTP or HTTPS URL without spaces.")
                end
                present[#present + 1] = url
            end
        end
        return present
    end
    return field
end
source_urls("gfwlist_urls", translate("GFWList sources"), translate("Base64-encoded GFWList subscriptions."))
source_urls("domainslist_urls", translate("Domain list sources"), translate("One domain per line."))

o = option(4, general, Value, "nftset_name", translate("NFTset name"),
    translate("IPv4 and IPv6 sets use the suffixes _v4 and _v6."))
o.rmempty = false
function o.validate(self, value)
    if not rules.valid_name(value) then
        return nil, translate("Use letters, digits and underscores; start with a letter or underscore (48 characters maximum).")
    end
    return value
end

function m.on_after_commit(self)
    local session = require("luci.dispatcher").context.authsession
    if not session then return end
    local access = require("luci.util").ubus("session", "access", {
        ubus_rpc_session = session, scope = "uci", object = "vpn-nftset", ["function"] = "write"
    })
    if type(access) ~= "table" or access.access ~= true then return end
    luci.sys.call("/etc/init.d/vpn-nftset delayed_reload")
end

return m
