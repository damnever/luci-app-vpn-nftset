package.path = "./files/root/usr/lib/lua/?.lua;" .. package.path
local data = require("vpn_nftset")

local function equal(actual, expected)
    assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end

-- Inputs must stay literal domains and valid DNS endpoints.
equal(data.normalize_domain(" WWW.Example.COM.\r "), "www.example.com")
equal(data.normalize_domain("xn--bcher-kva.example"), "xn--bcher-kva.example")
for _, invalid in ipairs({
    "example",
    "*.example.com",
    "https://example.com",
    "a..example.com",
    "-a.example",
    "1.2.3.4",
    "x.example\nserver=/#/1.2.3.4",
}) do
    assert(not data.normalize_domain(invalid), invalid)
end
equal(data.normalize_dns("008.8.8.8#0053"), "8.8.8.8#53")
equal(data.normalize_dns("2001:0DB8::1#5300"), "2001:db8::1#5300")
equal(data.normalize_dns("DNS.Example.COM.#0053"), "dns.example.com#53")
for _, invalid in ipairs({
    "https://dns.example.com",
    "1.2.3.256",
    "2001:db8::1::",
    "::1#0",
    "8.8.8.8#65536",
    "8.8.8.8/24",
}) do
    assert(not data.normalize_dns(invalid), invalid)
end

-- Unsupported globs are skipped without widening them to a parent domain.
local plain, _, skipped = data.parse_domains(
    "# comment\r\nB.Example.com\na.example.com.\na.example.com\ns3-ap-*.amazonaws.com\n*.example.net\n",
    "plain"
)
equal(table.concat(assert(plain), ","), "a.example.com,b.example.com")
equal(skipped, 2)
for _, invalid in ipairs({
    "",
    "good.example\ninvalid URL",
    "<html>Error</html>",
    "s3-ap-*.amazonaws.com",
    "good.example\ns3-ap-*.amazonaws..com",
}) do
    assert(not data.parse_domains(invalid, "plain"), invalid)
end
local gfw = assert(data.parse_domains(
    [[
[AutoProxy 0.2.9]
! comment
||example.com
@@||excluded.example
|https://avatars.githubusercontent.com/a.png
*.wild.example
||s3-ap-*.amazonaws.com
/regex\.example/
||unsupported.example$script
http://1.2.3.4/foo
]],
    "gfw"
))
equal(table.concat(gfw, ","), "avatars.githubusercontent.com,example.com,wild.example")

-- Per-domain DNS overrides take precedence; an empty list removes all rules.
local nftsets = "4#inet#table#VPN_v4,6#inet#table#VPN_v6"
local rules =
    assert(data.generate_custom("example.com\nwww.example.com/::1#5300\nexample.com/ns#5353\n", "8.8.8.8\n", nftsets))
equal(
    rules,
    "server=/example.com/ns#5353\nnftset=/example.com/"
        .. nftsets
        .. "\nserver=/www.example.com/::1#5300\nnftset=/www.example.com/"
        .. nftsets
        .. "\n"
)
equal(assert(data.generate_custom("", "", nftsets)), "")
assert(not data.generate_custom("example.com", "", "4#inet#table#set\nflush ruleset"))
assert(not data.generate_telegram("1.2.3.4", "bad;name", "table"))
for _, invalid in ipairs({ "", "<html>Error</html>", "1.2.3.4/24\nnot-an-ip", "91.108.56.0/33", "::1/129" }) do
    assert(not data.parse_cidrs(invalid), invalid)
end
print("Domain parsing and rule generation passed")

-- Catalog results use the entire cache, including duplicates and covered children.
local temp = os.tmpname()
os.remove(temp)
assert(os.execute("mkdir -p " .. temp .. "/cache " .. temp .. "/runtime") == 0)
local function write(path, text)
    local file = assert(io.open(path, "wb"))
    assert(file:write(text))
    assert(file:close())
end
local ok, err = pcall(function()
    local id1, id2 = string.rep("a", 32), string.rep("b", 32)
    local domains = { "example.com", "child.example.com", "notexample.com" }
    for i = 1, 8 do
        domains[#domains + 1] = string.format("host%02d.example.net", i)
    end
    write(temp .. "/cache/" .. id1 .. ".domains", table.concat(domains, "\n"))
    write(temp .. "/runtime/" .. id1 .. ".status", "download_failed\n")
    write(temp .. "/cache/" .. id2 .. ".domains", "child.example.com\nother.example\n")
    local sources = {
        { id = id1, url = "https://one.example/list", kind = "plain" },
        { id = id2, url = "https://two.example/list", kind = "gfw" },
    }
    local function catalog(options)
        return assert(
            data.catalog(
                { "example.com/ns#5353", "stable.example" },
                sources,
                options,
                temp .. "/cache",
                temp .. "/runtime"
            )
        )
    end
    local page = catalog({ page_size = 10, page = 2 })
    equal(page.total, 13)
    equal(page.counts.downloaded, 12)
    equal(page.pages, 2)
    equal(#page.rows, 3)
    equal(page.sources[1].status, "download_failed")
    local search = catalog({ query = " CHILD.EXAMPLE " })
    equal(search.total, 1)
    equal(search.rows[1].domain, "child.example.com")
    equal(#search.rows[1].sources, 2)
    equal(search.rows[1].covered_by, "example.com")
    equal(catalog({ source = id2 }).total, 2)
    equal(catalog({ check_domain = "deep.child.example.com" }).overlap.parent, "child.example.com")
    equal(catalog({ check_domain = "notexample.com" }).overlap.parent, nil)
    local overlap = catalog({ query = "absent", check_domain = "EXAMPLE.COM." })
    equal(overlap.total, 0)
    equal(overlap.overlap.exact, true)
    equal(overlap.overlap.subdomains, 1)
    local invalid_page = catalog({ page = 0 / 0, page_size = 0 / 0 })
    equal(invalid_page.page, 1)
    equal(invalid_page.page_size, 50)
    assert(not data.catalog({}, { { id = "../escape" } }, {}, temp .. "/cache", temp .. "/runtime"))
end)
os.execute("rm -rf " .. temp)
assert(ok, err)
print("Cached catalog search, pagination and overlap passed")
