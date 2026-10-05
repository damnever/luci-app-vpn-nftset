-- Controlled LuCI rendering boundary. Application templates and CBI options are real;
-- the platform's UCI cursor, standard field wrappers, and outer theme are fixtures.
package.path = "files/root/usr/lib/lua/?.lua;" .. package.path
local html = {}
local function write(value) html[#html + 1] = tostring(value or "") end
local function pcdata(value)
    return tostring(value or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&#39;")
end
local translations, current = {}, nil
for line in io.lines("files/luci/i18n/vpn-nftset.zh-cn.po") do
    local key = line:match("^msgid (.+)$")
    local value = line:match("^msgstr (.+)$")
    if key then current = assert(loadstring("return " .. key))() end
    if value and current then translations[current] = assert(loadstring("return " .. value))() end
end
local language = arg[1] or "zh-cn"
local function translate(value) return language == "en" and value or translations[value] or value end
local values = {
    enabled = arg[2] == "disabled" and "0" or "1", interface = "wg0", nftset_name = "VPN_NFTSET_DEFAULT",
    dns_servers = {"8.8.8.8"}, ip_addresses = {"8.8.8.8"}, auto_update = "1", telegram_enabled = "1",
    domains = {"githubusercontent.com", "stackexchange.com", "google.com", "feedly.com", "twitter.com", "golang.org", "apple.com", "forms.gle", "page.link", "fastly.net", "medium.com", "sre.google", "github.blog", "example.com", "specific.example.net/ns#5353"},
    gfwlist_urls = {"https://example.com/gfwlist.txt"}, domainslist_urls = {"https://example.com/domains.txt"}
}
if arg[2] == "empty" then values.domains = {} end
if arg[3] then
    local file = assert(io.open(arg[3], "r"))
    values.domains = {}
    for line in file:lines() do values.domains[#values.domains + 1] = line end
    file:close()
end
local fields = {}
local render
local field_mt = {}
field_mt.__index = field_mt
function field_mt:value(value, label) self.choices[#self.choices + 1] = {value, label} end
function field_mt:cfgvalue() return values[self.option] or self.default end
function field_mt:formvalue() return self.posted end
function field_mt:render(section)
    local cbid = "cbid.vpn-nftset." .. section .. "." .. self.option
    local scope = {self = self, section = section, cbid = cbid}
    if self.template then render(self.template, scope); return end
    render("cbi/valueheader", scope)
    local value = self:cfgvalue(section)
    if self.class == "Flag" then
        write('<input type="hidden" name="cbi.cbe.vpn-nftset.' .. section .. '.' .. self.option .. '" value="1" />')
        write('<input type="checkbox" id="' .. cbid .. '" name="' .. cbid .. '" value="1"' .. (value == "1" and ' checked' or '') .. ' />')
    elseif #self.choices > 0 then
        write('<select id="' .. cbid .. '" name="' .. cbid .. '">')
        for _, choice in ipairs(self.choices) do
            write('<option value="' .. pcdata(choice[1]) .. '"' .. (value == choice[1] and ' selected' or '') .. '>' .. pcdata(choice[2]) .. '</option>')
        end
        write('</select>')
    elseif self.class == "DynamicList" then
        local entries = type(value) == "table" and value or {value}
        for _, entry in ipairs(entries) do
            write('<div class="fixture-dynamic"><input name="' .. cbid .. '" value="' .. pcdata(entry) .. '" /><button type="button" class="btn" aria-label="Remove">×</button></div>')
        end
        write('<div class="fixture-dynamic"><input name="' .. cbid .. '" placeholder="' .. pcdata(self.placeholder) .. '" /><button type="button" class="btn" aria-label="Add">+</button></div>')
    else
        write('<input id="' .. cbid .. '" name="' .. cbid .. '" value="' .. pcdata(value) .. '" />')
    end
    render("cbi/valuefooter", scope)
end

local map_mt, section_mt = {}, {}
map_mt.__index, section_mt.__index = map_mt, section_mt
function map_mt:section(_, kind)
    local section = setmetatable({sectiontype = kind, map = self, children = {}}, section_mt)
    self.children[#self.children + 1] = section
    return section
end
function map_mt:get(_, name) return values[name] end
function map_mt:set(_, name, value) values[name] = value; return true end
function section_mt:cfgsections() return {"cfg-" .. self.sectiontype} end
function section_mt:option(class, name, title, description)
    local field = setmetatable({class = class, option = name, title = title, description = description, section = self, map = self.map, choices = {}, tag_error = {}}, field_mt)
    self.children[#self.children + 1] = field
    fields[name] = field
    return field
end
local cursor = {foreach = function(_, _, _, callback)
    callback({[".name"] = "wg0", ifname = "wg0", proto = "wireguard"})
end}
local reloads = {}
local environment = {
    Map = function(config, title) return setmetatable({config = config, title = title, children = {}, save = true}, map_mt) end,
    TypedSection = "TypedSection", Flag = "Flag", Value = "Value", DynamicList = "DynamicList", TextValue = "TextValue",
    translate = translate, translatef = function(value, ...) return translate(value):format(...) end,
    luci = {model = {uci = {cursor = function() return cursor end}}, sys = {call = function(command) reloads[#reloads + 1] = command; return 0 end}}
}
local source = assert(loadfile("files/luci/model/cbi/vpn-nftset.lua"))
setfenv(source, setmetatable(environment, {__index = _G}))
local map = source()

if arg[1] == "test" then
    local custom = fields.domains
    assert(custom:cfgvalue("fixture"):find("specific.example.net/ns#5353", 1, true))
    local normalized = assert(custom:validate("EXAMPLE.COM.\nexample.com\nspecific.example.net/ns#5353"))
    assert(normalized == "example.com\nspecific.example.net/ns#5353")
    custom:write("fixture", normalized)
    assert(type(values.domains) == "table" and #values.domains == 2)
    local invalid, message = custom:validate("valid.example\nhttps://invalid.example/path")
    assert(invalid == nil and message:find("2", 1, true))
    assert(custom:validate("") == "")
    custom:write("fixture", "")
    assert(type(values.domains) == "table" and #values.domains == 0)
    for _, name in ipairs({"dns_servers", "ip_addresses", "gfwlist_urls", "domainslist_urls"}) do
        local cleared = assert(fields[name]:validate({"", "   "}))
        assert(type(cleared) == "table" and #cleared == 0, "Cannot clear " .. name)
    end
    local dns = assert(fields.dns_servers:validate({"ns#5353", "8.8.8.8"}))
    assert(dns[1] == "ns#5353" and dns[2] == "8.8.8.8")
    assert(fields.nftset_name:validate("bad;name") == nil)
    local dispatcher = {context = {}}
    local access = false
    package.loaded["luci.dispatcher"] = dispatcher
    package.loaded["luci.util"] = {ubus = function(service, method, arguments)
        assert(service == "session" and method == "access")
        assert(arguments.ubus_rpc_session == "fixture-session" and arguments.scope == "uci")
        assert(arguments.object == "vpn-nftset" and arguments["function"] == "write")
        return access
    end}
    map:on_after_commit()
    assert(#reloads == 0, "An unauthenticated callback must not reload the service")
    dispatcher.context.authsession = "fixture-session"
    for _, response in ipairs({false, {}, {access = false}, {access = "true"}}) do
        access = response
        map:on_after_commit()
        assert(#reloads == 0, "A callback without UCI write access must not reload the service")
    end
    access = {access = true}
    map:on_after_commit()
    assert(#reloads == 1, "A callback with UCI write access must reload the service")
    print("CBI domain list roundtrip, validation, clearing and reload permissions passed")
    return
end

local base = {
    write = write, pcdata = pcdata, translate = translate, resource = "/luci-static/resources", token = "fixture-token",
    url = function(...) return "/cgi-bin/luci/" .. table.concat({...}, "/") end,
    ifattr = function(condition, key, value) return condition and ' ' .. key .. '="' .. pcdata(value) .. '"' or '' end,
    firstmap = true, readable = true, writable = arg[2] ~= "readonly"
}
render = function(name, scope)
    if name == "cbi/valueheader" then
        local field = scope.self
        write('<div class="cbi-value' .. (field.error and ' cbi-value-error' or '') .. '"><label class="cbi-value-title" for="' .. scope.cbid .. '">' .. pcdata(field.title) .. '</label><div class="cbi-value-field">')
        return
    elseif name == "cbi/valuefooter" then
        if scope.self.description then write('<div class="cbi-value-description">' .. pcdata(scope.self.description) .. '</div>') end
        if scope.self.error then write('<div class="cbi-value-error">' .. pcdata(scope.self.error[scope.section]) .. '</div>') end
        write('</div></div>')
        return
    end
    local file = assert(io.open("files/luci/view/" .. name .. ".htm", "r"))
    local text = file:read("*a")
    file:close()
    local code, offset = {}, 1
    while true do
        local first, last, body = text:find("<%%(.-)%%>", offset)
        local literal = first and text:sub(offset, first - 1) or text:sub(offset)
        code[#code + 1] = "write(" .. string.format("%q", literal) .. ")"
        if not first then break end
        local prefix = body:sub(1, 1)
        if prefix == "=" then code[#code + 1] = "write(" .. body:sub(2) .. ")"
        elseif prefix == ":" then code[#code + 1] = "write(pcdata(translate(" .. string.format("%q", body:sub(2)) .. ")))"
        elseif prefix == "+" then code[#code + 1] = "include(" .. string.format("%q", body:sub(2)) .. ")"
        else code[#code + 1] = body end
        offset = last + 1
    end
    local env = setmetatable({}, {__index = function(_, key)
        if scope[key] ~= nil then return scope[key] end
        if base[key] ~= nil then return base[key] end
        return _G[key]
    end})
    env.include = function(child) render(child, scope) end
    local fn = assert(loadstring(table.concat(code, "\n"), name))
    setfenv(fn, env)
    fn()
end
if arg[2] == "invalid" then
    map.save = false
    fields.domains.error = {["cfg-dnsmasq_nftset"] = translate("Enter a complete domain such as example.com")}
    fields.domains.tag_error["cfg-dnsmasq_nftset"] = true
    fields.domains.posted = "invalid/path"
end
write('<!doctype html><html lang="' .. language .. '"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>VPN NFTset preview</title><style>body{font-family:system-ui,sans-serif;margin:0;background:#f4f7f7;color:#25363b}main{width:100%;min-width:0;max-width:1200px;margin:0 auto;padding:26px 28px}.fixture-footer{display:flex;justify-content:flex-end;gap:10px;margin-top:22px}.cbi-value{display:flex}.cbi-value-title{width:210px;flex-shrink:0}.cbi-value-field{flex:1}.cbi-value-description{margin-top:8px}.fixture-dynamic{display:flex;gap:6px;margin-bottom:6px}.fixture-dynamic input{padding:8px 10px;min-width:280px}.cbi-value-field>input,.cbi-value-field>select{padding:8px 10px;min-width:280px}.cbi-value-field>input[type=checkbox]{min-width:0;width:18px;height:18px;accent-color:#22756b}.cbi-value-error{color:#984e28}@media(max-width:720px){main{padding:14px 12px}.cbi-value{display:block}.fixture-dynamic input{min-width:0;width:100%}}</style></head><body><main><form action="/save" method="post"><input type="hidden" name="token" value="fixture-token"><input type="hidden" name="cbi.submit" value="1">')
render(map.template, {self = map})
write('<div class="fixture-footer"><button class="btn" type="reset">' .. (language == "en" and "Reset" or "重置") .. '</button><button class="btn" type="submit" name="cbi.apply" value="1">' .. (language == "en" and "Save & Apply" or "保存并应用") .. '</button></div></form></main></body></html>')
io.write(table.concat(html))
