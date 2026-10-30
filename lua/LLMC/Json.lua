-- LLM Commander :: tiny JSON encoder + chunked log writer.
-- Written for the FA engine's Lua 5.0: no '#', no '%', no varargs, no string.gmatch.

local function Esc(s)
    s = string.gsub(s, '\\', '\\\\')
    s = string.gsub(s, '"', '\\"')
    s = string.gsub(s, '%c', ' ')
    s = string.gsub(s, '|', '/')      -- '|' is the log field separator
    return '"' .. s .. '"'
end

local function Enc(v, out, depth)
    local t = type(v)
    if t == 'nil' then
        table.insert(out, 'null')
    elseif t == 'boolean' then
        if v then table.insert(out, 'true') else table.insert(out, 'false') end
    elseif t == 'number' then
        if v ~= v or v > 1e15 or v < -1e15 then
            table.insert(out, '0')
        elseif math.floor(v) == v then
            table.insert(out, string.format('%d', v))
        else
            table.insert(out, string.format('%.1f', v))
        end
    elseif t == 'string' then
        table.insert(out, Esc(v))
    elseif t == 'table' then
        if depth > 6 then table.insert(out, 'null') return end
        local count, maxi, isArr = 0, 0, true
        for k, _ in pairs(v) do
            count = count + 1
            if type(k) ~= 'number' then isArr = false
            elseif k > maxi then maxi = k end
        end
        if isArr and maxi ~= count then isArr = false end
        if count == 0 then
            table.insert(out, '[]')
        elseif isArr then
            table.insert(out, '[')
            for i = 1, maxi do
                if i > 1 then table.insert(out, ',') end
                Enc(v[i], out, depth + 1)
            end
            table.insert(out, ']')
        else
            table.insert(out, '{')
            local first = true
            for k, x in pairs(v) do
                if not first then table.insert(out, ',') end
                first = false
                table.insert(out, Esc(tostring(k)))
                table.insert(out, ':')
                Enc(x, out, depth + 1)
            end
            table.insert(out, '}')
        end
    else
        table.insert(out, 'null')
    end
end

function Encode(v)
    local out = {}
    Enc(v, out, 0)
    return table.concat(out)
end

-- Writes  LLMC|<tag>|<seq>|<part>|<total>|<payload>  lines to the game log.
-- Long payloads are split so no single log line gets truncated.
local CHUNK = 600
function LogChunks(tag, seq, str)
    local total = math.ceil(string.len(str) / CHUNK)
    if total < 1 then total = 1 end
    for i = 1, total do
        local piece = string.sub(str, (i - 1) * CHUNK + 1, i * CHUNK)
        LOG('LLMC|' .. tag .. '|' .. seq .. '|' .. i .. '|' .. total .. '|' .. piece)
    end
end
