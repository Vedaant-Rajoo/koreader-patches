-- SPDX-License-Identifier: AGPL-3.0-or-later
-- HTTP conventions adapted from Craftwork2720/meguru, meguru/net.lua (1.8.7).

local function install()
    local Feed = require("meguru/feed")
    if Feed._newedia_dupskip then return end
    assert(type(Feed.collect) == "function" and type(Feed.neighbor) == "function")

    local Net = require("meguru/net")
    local Reader = require("meguru/ui/reader")
    local NetworkMgr = require("ui/network/manager")
    assert(type(Reader.install) == "function")
    local http = require("socket.http")
    local url = require("socket.url")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local Utf8Proc = require("ffi/utf8proc")
    local json = assert(Net.jsonDecoder())
    local collect, neighbor, installReader = Feed.collect, Feed.neighbor, Reader.install
    local metadata = setmetatable({}, { __mode = "k" })
    local cache

    local function scanlatorKey(name)
        if type(name) ~= "string" or name:find("\0", 1, true) then return end
        -- Validate before calling the NUL-terminated native Unicode normalizer.
        local _, valid = Utf8Proc.count(name)
        if not valid then return end
        name = Utf8Proc.lowercase(name):gsub("%s+", " "):match("^%s*(.-)%s*$")
        return name ~= "" and name or nil
    end

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

    local function request(api, opts, query, variables)
        local body = json.encode({ query = query, variables = variables })
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
                    if size > 1024 * 1024 then return nil, "response too large" end
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
            or type(decoded.data) ~= "table" then return end
        return decoded.data
    end

    local function fetch(api, manga_id, opts)
        local data = request(api, opts,
            "query($mangaId:Int!){chapters(condition:{mangaId:$mangaId})"
                .. "{nodes{id chapterNumber scanlator}}}", { mangaId = manga_id })
        if not data or type(data.chapters) ~= "table"
            or type(data.chapters.nodes) ~= "table" then return end
        local nodes, by_id, count = data.chapters.nodes, {}, 0
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
                scanlator = scanlatorKey(node.scanlator),
            }
            count = count + 1
        end
        if count ~= #nodes then return end
        return by_id
    end

    local function enrich(items, walker, plan, refresh)
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
        if refresh or not cache or cache.api ~= api or cache.manga_id ~= manga_id
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

    local function markDuplicates(desc)
        if not NetworkMgr:isConnected() then return end
        local plan = Feed.planForMarker(desc, { max_pages = Feed.TAP_PAGES, timeout = "resume" })
        local api = endpoint(plan)
        if not api then return end
        local walker = Feed.walker(plan.url, plan.walker_opts)
        while walker:step() do end
        if not walker.complete then return end
        local items = collect(walker, plan)
        -- Writes must not use chapter numbers from the navigation cache.
        enrich(items, walker, plan, true)
        local sequence = Feed.ordered(items, { title_order = plan.driver.orderFromTitles })
        local index
        for i, item in ipairs(sequence) do
            if not metadata[item] then return end
            if item.item_key == desc.item_key then index = i end
        end
        if not index then return end
        local number = metadata[sequence[index]].number
        if number == nil then return true end
        local first, last = index, index
        while sequence[first - 1] and metadata[sequence[first - 1]].number == number do
            first = first - 1
        end
        while sequence[last + 1] and metadata[sequence[last + 1]].number == number do
            last = last + 1
        end
        if first == last then return true end
        local ids, pending = {}, {}
        for i = first, last do
            local id = chapterId(sequence[i].item_key)
            id = tonumber(id)
            ids[#ids + 1], pending[id] = id, true
        end
        local data = request(api, plan.walker_opts or {},
            "mutation($ids:[Int!]!){updateChapters(input:{ids:$ids,patch:{isRead:true}})"
                .. "{chapters{id isRead}}}", { ids = ids })
        local chapters = data and data.updateChapters and data.updateChapters.chapters
        if type(chapters) ~= "table" then return end
        for _, chapter in pairs(chapters) do
            if type(chapter) ~= "table" or not pending[chapter.id]
                or chapter.isRead ~= true then return end
            pending[chapter.id] = nil
        end
        return next(pending) == nil
    end

    local function hookCompletion(plugin)
        local ui = plugin and plugin.ui
        local doc, status = ui and ui.document, ui and ui.status
        if not (doc and doc.provider == "meguru" and type(doc.desc) == "table"
            and doc.desc.server_kind == "suwayomi" and status
            and type(status.onEndOfBook) == "function")
            or status._newedia_dupread then return end
        local onEndOfBook, completed = status.onEndOfBook, false
        status.onEndOfBook = function(self, ...)
            if not completed and ui.document == doc then
                local ok, marked = pcall(markDuplicates, doc.desc)
                completed = ok and marked == true
                if not completed then
                    require("logger").warn("Meguru duplicate read: sync not confirmed; finish again to retry")
                end
            end
            return onEndOfBook(self, ...)
        end
        status._newedia_dupread = true
    end

    local function wrappedInstall(...)
        local result = pack(installReader(...))
        pcall(hookCompletion, ...)
        return unpack(result, 1, result.n)
    end

    -- No module mutation until every dependency and wrapper is ready.
    Feed.collect, Feed.neighbor = wrappedCollect, selectNeighbor
    Reader.install = wrappedInstall
    Feed._newedia_dupskip = true
end

require("userpatch").registerPatchPluginFunc("meguru", function()
    local ok = pcall(install)
    if not ok then
        -- Exception text can contain credentials, so only report a fixed message.
        require("logger").warn("Meguru duplicate skip: installation failed; keeping original navigation")
    end
end)
