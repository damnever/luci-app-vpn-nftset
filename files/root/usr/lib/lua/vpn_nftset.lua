local M = {}

local function ipv4(address)
    local parts = {}
    for part in address:gmatch("[^.]+") do
        if not part:match("^%d+$") or #part > 3 or tonumber(part) > 255 then
            return nil
        end
        parts[#parts + 1] = tonumber(part)
    end
    if #parts ~= 4 or address:find("..", 1, true) or address:sub(1, 1) == "." or address:sub(-1) == "." then
        return nil
    end
    return parts
end

local function ipv6(address)
    if not address:match("^[%x:%.]+$") then return nil end
    if address:find(".", 1, true) then
        local head, tail = address:match("^(.*:)([^:]+)$")
        local v4 = tail and ipv4(tail)
        if not v4 then return nil end
        address = head .. string.format("%x:%x", v4[1] * 256 + v4[2], v4[3] * 256 + v4[4])
    end
    local left, right = address:match("^(.-)::(.-)$")
    if left and right:find("::", 1, true) then return nil end
    if not left and (address:sub(1, 1) == ":" or address:sub(-1) == ":") then return nil end
    local function groups(value)
        local result = {}
        if value == "" then return result end
        if value:sub(1, 1) == ":" or value:sub(-1) == ":" then return nil end
        for group in value:gmatch("[^:]+") do
            if #group > 4 or not group:match("^%x+$") then return nil end
            result[#result + 1] = tonumber(group, 16)
        end
        return result
    end
    local first = groups(left or address)
    local last = groups(right or "")
    if not first or not last then return nil end
    if left then
        if #first + #last >= 8 then return nil end
        for _ = 1, 8 - #first - #last do first[#first + 1] = 0 end
        for _, group in ipairs(last) do first[#first + 1] = group end
    elseif #first ~= 8 then
        return nil
    end
    return first
end

local function format_ipv6(groups)
    local best_start, best_length, run_start, run_length = nil, 0, nil, 0
    for i = 1, 9 do
        if groups[i] == 0 then
            run_start = run_start or i
            run_length = run_length + 1
        else
            if run_length > best_length and run_length >= 2 then
                best_start, best_length = run_start, run_length
            end
            run_start, run_length = nil, 0
        end
    end
    local first, last = {}, {}
    for i, group in ipairs(groups) do
        if not best_start or i < best_start then
            first[#first + 1] = string.format("%x", group)
        elseif i >= best_start + best_length then
            last[#last + 1] = string.format("%x", group)
        end
    end
    if best_start then return table.concat(first, ":") .. "::" .. table.concat(last, ":") end
    return table.concat(first, ":")
end

local function parse_address(value, allow_prefix)
    local address, prefix = value:match("^([^/]+)/(%d+)$")
    if not address then
        if value:find("/", 1, true) then return nil end
        address = value
    elseif not allow_prefix then
        return nil
    end
    local version = address:find(":", 1, true) and 6 or 4
    local groups = version == 4 and ipv4(address) or ipv6(address)
    if not groups then return nil end
    local width, limit = version == 4 and 8 or 16, version == 4 and 32 or 128
    if prefix then
        prefix = tonumber(prefix)
        if prefix > limit then return nil end
        local remaining = prefix
        for i, group in ipairs(groups) do
            local bits = math.min(width, math.max(remaining, 0))
            local step = 2 ^ (width - bits)
            groups[i] = math.floor(group / step) * step
            remaining = remaining - width
        end
    end
    local normalized = version == 4 and table.concat(groups, ".") or format_ipv6(groups)
    if prefix then normalized = normalized .. "/" .. prefix end
    return normalized, version
end

function M.normalize_domain(value)
    if type(value) ~= "string" then return nil, "Domain must be text" end
    local domain = value:match("^%s*(.-)%s*$"):lower():gsub("%.$", "")
    if #domain > 253 or not domain:find(".", 1, true) or domain:find("..", 1, true) then
        return nil, "Enter a complete domain such as example.com"
    end
    if not domain:match("^[a-z0-9][a-z0-9%.%-]*[a-z0-9]$") then
        return nil, "Use a domain without a URL, path, or wildcard"
    end
    for label in domain:gmatch("[^.]+") do
        if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then
            return nil, "Invalid domain label"
        end
    end
    if domain:match("%.%d+$") then return nil, "Enter a domain, not an IP address" end
    return domain
end

function M.normalize_dns(value)
    if type(value) ~= "string" then return nil, "DNS server must be text" end
    value = value:match("^%s*(.-)%s*$")
    local address, port = value:match("^([^#]+)#(%d+)$")
    if not address then address = value end
    local normalized = parse_address(address, false)
    if not normalized then
        local host = address:lower():gsub("%.$", "")
        if host:find(".", 1, true) then
            normalized = M.normalize_domain(host)
        elseif #host <= 63 and host:match("^[a-z0-9][a-z0-9%-]*[a-z0-9]$") and host:match("[a-z]") then
            normalized = host
        elseif #host == 1 and host:match("^[a-z]$") then
            normalized = host
        end
    end
    if not normalized then return nil, "Use an IP address or hostname DNS server, optionally followed by #port" end
    if port then
        port = tonumber(port)
        if port < 1 or port > 65535 then return nil, "DNS port must be between 1 and 65535" end
        normalized = normalized .. "#" .. port
    end
    return normalized
end

function M.valid_name(value)
    return type(value) == "string" and #value <= 48 and value:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

function M.parse_custom(value)
    if type(value) ~= "string" then return nil, "Domain must be text" end
    local domain, dns = value:match("^([^/]+)/([^/]+)$")
    if not domain then
        if value:find("/", 1, true) then return nil, "Use domain or domain/DNS-server" end
        domain = value
    end
    local normalized, err = M.normalize_domain(domain)
    if not normalized then return nil, err end
    if dns then
        dns, err = M.normalize_dns(dns)
        if not dns then return nil, err end
    end
    return {domain = normalized, dns = dns}
end

function M.parse_domains(text, kind)
    if kind ~= "plain" and kind ~= "gfw" then return nil, "Unknown domain list format" end
    if type(text) ~= "string" or text:lower():find("<!doctype", 1, true) or text:lower():find("<html", 1, true) then
        return nil, "Response is not a domain list"
    end
    local domains, seen, skipped = {}, {}, 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:match("^%s*(.-)%s*$")
        local comment = line:match("^#") or (kind == "gfw" and (line:match("^!") or line:match("^%[")))
        if line ~= "" and not comment then
            local candidate = line
            if kind == "gfw" then
                if line:match("^@@") or line:find("$", 1, true) then
                    candidate = nil
                else
                    candidate = candidate:gsub("^|+", ""):gsub("|+$", "")
                    candidate = candidate:gsub("^https?://", ""):gsub("^%*%.", ""):gsub("^%.", "")
                    candidate = candidate:gsub("%%2[Ff].*$", ""):gsub("[/%^%?#].*$", ""):gsub(":%d+$", "")
                end
            end
            local domain = candidate and M.normalize_domain(candidate)
            if not domain and kind == "plain" then
                -- Older generators left wildcard patterns in cached rules. nftset
                -- cannot match them; retain valid domains without widening scope.
                if candidate:find("*", 1, true) and M.normalize_domain(candidate:gsub("%*", "a")) then
                    skipped = skipped + 1
                else
                    return nil, "Invalid domain: " .. line
                end
            end
            if domain and not seen[domain] then
                seen[domain] = true
                domains[#domains + 1] = domain
            end
        end
    end
    if #domains == 0 then return nil, "Domain list is empty or invalid" end
    table.sort(domains)
    return domains, nil, skipped
end

function M.parse_cidrs(text)
    if type(text) ~= "string" then return nil, "IP list must be text" end
    local result, seen = {v4 = {}, v6 = {}, count = 0}, {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") then
            local normalized, version = parse_address(line, true)
            if not normalized then return nil, "Invalid IP address or CIDR: " .. line end
            if not seen[normalized] then
                seen[normalized] = true
                local addresses = result[version == 4 and "v4" or "v6"]
                addresses[#addresses + 1] = normalized
                result.count = result.count + 1
            end
        end
    end
    if result.count == 0 then return nil, "IP list is empty" end
    table.sort(result.v4)
    table.sort(result.v6)
    return result
end

function M.generate_telegram(text, name, nft_table)
    if not M.valid_name(name) or not M.valid_name(nft_table) then return nil, "Invalid NFTset or table name" end
    local cidrs, err = M.parse_cidrs(text)
    if not cidrs then return nil, err end
    local lines = {}
    for _, version in ipairs({"v4", "v6"}) do
        local target = "inet " .. nft_table .. " " .. name .. "_telegram_" .. version
        lines[#lines + 1] = "flush set " .. target
        if #cidrs[version] > 0 then
            lines[#lines + 1] = "add element " .. target .. " { " .. table.concat(cidrs[version], ", ") .. " }"
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

function M.generate_custom(custom_text, dns_text, nftsets)
    if type(nftsets) ~= "string" or nftsets == "" then return nil, "NFTset is required" end
    for target in nftsets:gmatch("[^,]+") do
        local nft_table, name = target:match("^[46]#inet#([A-Za-z_][A-Za-z0-9_]*)#([A-Za-z_][A-Za-z0-9_]*)$")
        if not nft_table or not name or #name > 64 then return nil, "Invalid NFTset target" end
    end
    if nftsets:sub(1, 1) == "," or nftsets:sub(-1) == "," or nftsets:find(",,", 1, true) then
        return nil, "Invalid NFTset target"
    end
    local servers, seen = {}, {}
    for line in (dns_text .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("%S") then
            local server, err = M.normalize_dns(line)
            if not server then return nil, err end
            if not seen[server] then servers[#servers + 1] = server; seen[server] = true end
        end
    end
    local entries, domains = {}, {}
    for line in (custom_text .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("%S") then
            local entry, err = M.parse_custom(line)
            if not entry then return nil, err end
            if not entries[entry.domain] then domains[#domains + 1] = entry.domain end
            entries[entry.domain] = entry
        end
    end
    table.sort(domains)
    local lines = {}
    for _, domain in ipairs(domains) do
        local entry = entries[domain]
        for _, server in ipairs(entry.dns and {entry.dns} or servers) do
            lines[#lines + 1] = "server=/" .. domain .. "/" .. server
        end
        lines[#lines + 1] = "nftset=/" .. domain .. "/" .. nftsets
    end
    return table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

function M.catalog(custom_entries, sources, options, cache_dir, runtime_dir)
    options = options or {}
    local check_domain
    if options.check_domain then
        local err
        check_domain, err = M.normalize_domain(options.check_domain)
        if not check_domain then return nil, err end
    end
    local entries, custom_domains, source_info = {}, {}, {}
    for _, value in ipairs(custom_entries or {}) do
        local custom = M.parse_custom(value)
        if custom then
            entries[custom.domain] = {domain = custom.domain, dns = custom.dns, custom = true, sources = {}}
            custom_domains[custom.domain] = true
        end
    end
    for _, source in ipairs(sources or {}) do
        if type(source.id) ~= "string" or #source.id ~= 32 or not source.id:match("^[a-f0-9]+$") then
            return nil, "Invalid source identifier"
        end
        local content = read_file(cache_dir .. "/" .. source.id .. ".domains")
        local domains = content and M.parse_domains(content, "plain") or nil
        local status = read_file(runtime_dir .. "/" .. source.id .. ".status")
        status = status and status:match("^%s*(.-)%s*$") or (domains and "cached" or "not_downloaded")
        local info = {
            id = source.id, url = source.url, kind = source.kind,
            count = domains and #domains or 0, cached = domains ~= nil, status = status,
            last_success = tonumber(read_file(cache_dir .. "/" .. source.id .. ".success") or "")
        }
        source_info[#source_info + 1] = info
        for _, domain in ipairs(domains or {}) do
            local entry = entries[domain]
            if not entry then
                entry = {domain = domain, custom = false, sources = {}}
                entries[domain] = entry
            end
            entry.sources[#entry.sources + 1] = {id = source.id, url = source.url, kind = source.kind}
        end
    end
    local all, counts = {}, {custom = 0, downloaded = 0, total = 0}
    local query = tostring(options.query or ""):lower():match("^%s*(.-)%s*$")
    for domain, entry in pairs(entries) do
        counts.total = counts.total + 1
        if entry.custom then counts.custom = counts.custom + 1 end
        if #entry.sources > 0 then counts.downloaded = counts.downloaded + 1 end
        local parent = domain:match("^[^.]+%.(.+)$")
        while parent do
            if custom_domains[parent] then entry.covered_by = parent; break end
            parent = parent:match("^[^.]+%.(.+)$")
        end
        local included = options.scope ~= "custom" or entry.custom
        if options.scope == "downloaded" then included = #entry.sources > 0 end
        if options.source and options.source ~= "" then
            local matches = false
            for _, source in ipairs(entry.sources) do
                if source.id == options.source then matches = true; break end
            end
            included = included and matches
        end
        if included and domain:find(query, 1, true) then all[#all + 1] = entry end
    end
    table.sort(all, function(a, b) return a.domain < b.domain end)
    local page_size = tonumber(options.page_size) or 50
    if page_size ~= page_size then page_size = 50 end
    page_size = math.min(200, math.max(10, math.floor(page_size)))
    local pages = math.max(1, math.ceil(#all / page_size))
    local page = tonumber(options.page) or 1
    if page ~= page then page = 1 end
    page = math.min(pages, math.max(1, math.floor(page)))
    local rows = {}
    for i = (page - 1) * page_size + 1, math.min(#all, page * page_size) do rows[#rows + 1] = all[i] end
    local result = {rows = rows, total = #all, page = page, pages = pages, page_size = page_size, counts = counts, sources = source_info}
    if check_domain then
        local exact = entries[check_domain]
        local overlap = {exact = exact ~= nil and #exact.sources > 0, subdomains = 0}
        local parent = check_domain:match("^[^.]+%.(.+)$")
        while parent do
            if entries[parent] and #entries[parent].sources > 0 then overlap.parent = parent; break end
            parent = parent:match("^[^.]+%.(.+)$")
        end
        local suffix = "." .. check_domain
        for domain, entry in pairs(entries) do
            if #entry.sources > 0 and domain:sub(-#suffix) == suffix then
                overlap.subdomains = overlap.subdomains + 1
            end
        end
        result.overlap = overlap
    end
    return result
end

return M
