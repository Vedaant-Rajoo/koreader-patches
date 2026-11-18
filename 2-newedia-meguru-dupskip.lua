-- SPDX-License-Identifier: AGPL-3.0-or-later
-- HTTP conventions adapted from Craftwork2720/meguru, meguru/net.lua (1.8.7).

local function install()
    local Feed = require("meguru/feed")
    if Feed._newedia_dupskip then return end
    assert(type(Feed.collect) == "function" and type(Feed.neighbor) == "function")

    local Net = require("meguru/net")
    local http = require("socket.http")
    local url = require("socket.url")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local json = assert(Net.jsonDecoder())
    local collect, neighbor = Feed.collect, Feed.neighbor
    local metadata = setmetatable({}, { __mode = "k" })
    local cache

    local function chapterId(key)
        if type(key) ~= "string" then return end
        key = key:gsub(":metadata$", "")
        local remote = key:match(":remote$") ~= nil
        key = key:gsub(":remote$", "")
        local id = key:match("^%d+$") and tonumber(key)
        if id and id <= 2147483647 then return tostring(id), remote end
    end

    local function endpoint(plan)
        if not (plan and plan.driver and plan.driver.kind == "suwayomi")
            or type(plan.url) ~= "string" or plan.url:find("[%c\\]") then return end
        local parsed = url.parse(plan.url)
        if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https")
            or not parsed.host or parsed.userinfo or parsed.user or parsed.password
            or parsed.fragment or parsed.params then return end
        local prefix, id = (parsed.path or ""):match(
            "^(.-)/api/opds/v1%.2/series/(%d+)/chapters/?$")
        id = tonumber(id)
        if not id or id > 2147483647 then return end
        return url.build({ scheme = parsed.scheme, host = parsed.host,
            port = parsed.port, path = prefix .. "/api/graphql" }), id
    end

    local function fetch(api, manga_id, opts)
        local body = json.encode({
            query = "query($mangaId:Int!){chapters(condition:{mangaId:$mangaId})"
                .. "{nodes{id chapterNumber scanlator}}}",
            variables = { mangaId = manga_id },
        })
        local chunks = {}
        local old_block, old_total = socketutil.block_timeout, socketutil.total_timeout
        local ok, status, code = pcall(function()
            socketutil:set_timeout(2, 4)
            local sink, size = socketutil.table_sink(chunks), 0
            return http.request({
                url = api,
                method = "POST",
                -- A redirect must never carry the OPDS account to another origin.
                redirect = false,
                user = opts.username ~= "" and opts.username or nil,
                password = opts.password or "",
                headers = {
                    ["Accept"] = "application/json",
                    ["Accept-Encoding"] = "identity",
                    ["Content-Type"] = "application/json",
                    ["Content-Length"] = tostring(#body),
                },
                source = ltn12.source.string(body),
                sink = function(chunk, err)
                    size = size + (chunk and #chunk or 0)
                    if size > 1024 * 1024 then return nil, "metadata too large" end
                    return sink(chunk, err)
                end,
            })
        end)
        if old_block and old_total then
            socketutil:set_timeout(old_block, old_total)
        else
            socketutil:reset_timeout()
        end
        if not ok or not status or code ~= 200 then return end
        local decoded = json.decode(table.concat(chunks))
        if type(decoded) ~= "table" or decoded.errors ~= nil
            or type(decoded.data) ~= "table"
            or type(decoded.data.chapters) ~= "table"
            or type(decoded.data.chapters.nodes) ~= "table" then return end
        local nodes, by_id, count = decoded.data.chapters.nodes, {}, 0
        for index, node in pairs(nodes) do
            if type(index) ~= "number" or index < 1 or index % 1 ~= 0
                or type(node) ~= "table" or type(node.id) ~= "number"
                or node.id < 0 or node.id > 2147483647 or node.id % 1 ~= 0
                or by_id[tostring(node.id)] then return end
            local number = node.chapterNumber
            -- Unknown numbers are individual stops, including negative sentinels.
            if type(number) ~= "number" or number ~= number
                or number < 0 or number == math.huge then number = nil end
            by_id[tostring(node.id)] = {
                number = number,
                scanlator = type(node.scanlator) == "string"
                    and node.scanlator:match("%S") and node.scanlator or nil,
            }
            count = count + 1
        end
        if count ~= #nodes then return end
        return by_id
    end

    local function enrich(items, walker, plan)
        if type(items) ~= "table" or #items == 0 or not walker.complete then return end
        local api, manga_id = endpoint(plan)
        if not api then return end
        local ids, keys = {}, {}
        for i, item in ipairs(items) do
            local id, remote = chapterId(item.item_key)
            -- Progress conflicts are not alternate scanlator releases.
            if not id or remote then return end
            ids[i], keys[i] = id, item.item_key
        end
        local opts = plan.walker_opts or {}
        local signature, now = table.concat(keys, "\n"), os.time()
        if not cache or cache.api ~= api or cache.manga_id ~= manga_id
            or cache.username ~= opts.username or cache.password ~= opts.password
            or cache.signature ~= signature or now >= cache.expires
            or now < cache.created then
            local ok, nodes = pcall(fetch, api, manga_id, opts)
            -- One private slot bounds memory; failures also avoid repeated delays.
            cache = { api = api, manga_id = manga_id, username = opts.username,
                password = opts.password, signature = signature, created = now,
                expires = now + 60, nodes = ok and nodes or nil }
        end
        local nodes = cache.nodes
        if not nodes then return end
        -- A partial answer must not let us skip past a release we cannot identify.
        for _, id in ipairs(ids) do
            if not nodes[id] then return end
        end
        for i, item in ipairs(items) do metadata[item] = nodes[ids[i]] end
    end

    local function selectNeighbor(sequence, key, which)
        local index
        for i, item in ipairs(sequence or {}) do
            if not metadata[item] then return neighbor(sequence, key, which) end
            if not index and item.item_key == key then index = i end
        end
        if not index then return neighbor(sequence, key, which) end
        local current = metadata[sequence[index]]
        local step = which == "previous" and -1 or 1
        local next_index = index + step
        -- shortcut: Numbers lack volume context; use volume metadata when available.
        while current.number ~= nil and sequence[next_index]
            and metadata[sequence[next_index]].number == current.number do
            next_index = next_index + step
        end
        local nearest = sequence[next_index]
        if not nearest then return nil end
        local target = metadata[nearest].number
        if target == nil or not current.scanlator then return nearest end
        while sequence[next_index] and metadata[sequence[next_index]].number == target do
            local item = sequence[next_index]
            if metadata[item].scanlator == current.scanlator then return item end
            next_index = next_index + step
        end
        return nearest
    end

    local function pack(...)
        return { n = select("#", ...), ... }
    end
    local function wrappedCollect(...)
        -- Keep the original error and return contract, including trailing nils.
        local result = pack(collect(...))
        pcall(enrich, result[1], ...)
        return unpack(result, 1, result.n)
    end

    -- No module mutation until every dependency and both wrappers are ready.
    Feed.collect, Feed.neighbor = wrappedCollect, selectNeighbor
    Feed._newedia_dupskip = true
end

require("userpatch").registerPatchPluginFunc("meguru", function()
    local ok = pcall(install)
    if not ok then
        -- Exception text can contain credentials, so only report a fixed message.
        require("logger").warn("Meguru duplicate skip: installation failed; keeping original navigation")
    end
end)
