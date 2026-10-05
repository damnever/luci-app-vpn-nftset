-- Run the actual controller with controlled session, UCI, HTTP and process adapters.
local result, status, calls, query, files = nil, nil, {}, {}, {}
local read, write, process_result = true, true, 0
local general, changes = {enabled = "1"}, {}
local domains = {domains = {"example.com/ns#5353"}, gfwlist_urls = {"https://example.com/list"}}
local rules = dofile("files/root/usr/lib/lua/vpn_nftset.lua")
local options
package.loaded["luci.model.uci"] = {cursor = function() return {
    foreach = function(_, _, kind, callback) callback(kind == "general" and general or domains) end,
    changes = function() return changes end
} end}
package.loaded["luci.dispatcher"] = {context = {authsession = "fixture-session"}}
package.loaded["luci.http"] = {
    formvalue = function(key) return query[key] end,
    status = function(code) status = code end,
    header = function() end,
    write_json = function(value) result = value end
}
package.loaded["nixio.fs"] = {access = function() return true end, readfile = function(path)
    if files[path] then return files[path] end
    return nil, 2, "No such file or directory"
end}
package.loaded["luci.util"] = {
    shellquote = function(value) return "'" .. value .. "'" end,
    ubus = function(service, method, args)
        assert(service == "session" and method == "access")
        assert(args.ubus_rpc_session == "fixture-session" and args.scope == "uci" and args.object == "vpn-nftset")
        return {access = args["function"] == "read" and read or args["function"] == "write" and write}
    end
}
package.loaded["luci.sys"] = {
    call = function(command) calls[#calls + 1] = command; return process_result end,
    exec = function() return "0123456789abcdef0123456789abcdef  -\n" end
}
package.loaded["vpn_nftset"] = {parse_custom = rules.parse_custom, parse_cidrs = rules.parse_cidrs,
    catalog = function(_, _, value) options = value; return {} end}
_G.nixio = {fs = package.loaded["nixio.fs"]}
local routes = {}
_G.entry = function(path, target) local page = {target = target}; routes[table.concat(path, "/")] = page; return page end
_G.call, _G.cbi = function() return {} end, function() return {} end
_G.post = function() return {post = true} end
_G._ = function(value) return value end
assert(loadfile("files/luci/controller/vpn-nftset.lua"))()
local controller = package.loaded["luci.controller.vpn-nftset"]
controller.index()
assert(routes["admin/services/vpn-nftset/refresh"].target.post == true)
assert(routes["admin/services/vpn-nftset"].acl_depends[1] == "luci-app-vpn-nftset")
local function request(action)
    result, status, calls = nil, nil, {}
    controller[action]()
end

read = false
request("action_catalog")
assert(status == 403 and result.error == "permission_denied" and #calls == 0)
read, write = true, false
request("action_catalog")
assert(status == nil and result.enabled == true and result.telegram.last_success == nil)
request("action_refresh")
assert(status == 403 and result.error == "permission_denied" and #calls == 0)
write, general.enabled = true, "0"
request("action_refresh")
assert(status == 409 and result.error == "service_disabled" and #calls == 0)
general.enabled, changes = "1", {['vpn-nftset'] = {{"set", "general", "enabled", "1"}}}
request("action_refresh")
assert(status == 409 and result.error == "settings_not_applied" and #calls == 0)
request("action_catalog")
assert(result.pending_changes == true)
changes, files["/tmp/vpn-nftset/service.lock/pid"] = {}, "123\n"
request("action_refresh")
assert(status == 409 and result.error == "update_running" and #calls == 1)
files = {}
request("action_refresh")
assert(result.started == true and #calls == 1)
process_result = 1
request("action_refresh")
assert(status == 500 and result.error == "update_start_failed")
process_result, query = 0, {check = "CDN.EXAMPLE.COM.", page_size = "1000"}
request("action_catalog")
assert(options.check_domain == "cdn.example.com" and options.page_size == 100)
query.check = "https://example.com"
request("action_catalog")
assert(status == 400 and result.error == "invalid_domain")
query = {}
files = {['/etc/vpn-nftset/telegram.cidr'] = "<html>invalid</html>",
    ['/usr/share/vpn-nftset/telegram-cidr.txt'] = "91.108.56.0/22\n2001:b28:f23d::/48\n"}
request("action_catalog")
assert(result.telegram.cached == false and result.telegram.count == 2)
print("LuCI controller permissions, refresh states and catalog boundaries passed")
