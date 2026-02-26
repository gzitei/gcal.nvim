local M = {}

function M.url_encode(str)
  str = str:gsub("\n", "\r\n")
  str = str:gsub("([^%w _%%%-%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  str = str:gsub(" ", "+")
  return str
end

function M.url_decode(str)
  str = str:gsub("+", " ")
  str = str:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
  return str
end

function M.parse_query_string(query)
  local params = {}
  for key, value in query:gmatch("([^&=]+)=([^&]*)") do
    params[M.url_decode(key)] = M.url_decode(value)
  end
  return params
end

function M.iso8601_to_timestamp(str)
  if not str then
    return nil
  end
  local year, month, day = str:match("^(%d+)-(%d+)-(%d+)$")
  if year then
    return os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 0, min = 0, sec = 0 }),
      true
  end
  year, month, day, hour, min, sec = str:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not year then
    return nil
  end
  local offset_sign, offset_h, offset_m = str:match("([%+%-])(%d%d):(%d%d)$")
  local tz_offset = 0
  if offset_sign then
    tz_offset = (tonumber(offset_h) * 3600 + tonumber(offset_m) * 60)
    if offset_sign == "+" then
      tz_offset = -tz_offset
    end
  elseif str:match("Z$") then
    tz_offset = 0
  end
  local utc_time = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
  })
  local local_offset = os.time(os.date("*t", 0)) - os.time(os.date("!*t", 0))
  return utc_time + tz_offset + local_offset, false
end

function M.timestamp_to_iso8601(ts)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", ts)
end

function M.format_time(ts, format)
  if format == "12h" then
    return os.date("%I:%M %p", ts)
  end
  return os.date("%H:%M", ts)
end

function M.get_week_bounds(ts, week_start)
  local date = os.date("*t", ts)
  local wday = date.wday
  local start_offset
  if week_start == "monday" then
    start_offset = ((wday - 2) % 7)
  else
    start_offset = wday - 1
  end
  local week_start_ts = os.time({
    year = date.year,
    month = date.month,
    day = date.day - start_offset,
    hour = 0,
    min = 0,
    sec = 0,
  })
  local week_end_ts = week_start_ts + 7 * 24 * 3600 - 1
  return week_start_ts, week_end_ts
end

function M.get_day_dates(week_start_ts)
  local days = {}
  for i = 0, 6 do
    table.insert(days, week_start_ts + i * 24 * 3600)
  end
  return days
end

-- Comprehensive Latin transliteration table.
-- Covers Latin-1 Supplement (U+00C0–U+00FF), Latin Extended-A (U+0100–U+017F),
-- Latin Extended-B (U+0180–U+024F), and Latin Extended Additional (U+1E00–U+1EFF).
-- Multi-char mappings (ae, ss, th, oe, ij, ng) are kept explicit since they
-- cannot be derived from simple base-letter extraction.
local _translit = {
  -- ── Latin-1 Supplement (U+00C0–U+00FF) ─────────────────────────────────────
  -- uppercase
  ["À"]="A",["Á"]="A",["Â"]="A",["Ã"]="A",["Ä"]="A",["Å"]="A",["Æ"]="AE",
  ["Ç"]="C",
  ["È"]="E",["É"]="E",["Ê"]="E",["Ë"]="E",
  ["Ì"]="I",["Í"]="I",["Î"]="I",["Ï"]="I",
  ["Ð"]="D",["Ñ"]="N",
  ["Ò"]="O",["Ó"]="O",["Ô"]="O",["Õ"]="O",["Ö"]="O",["Ø"]="O",
  ["Ù"]="U",["Ú"]="U",["Û"]="U",["Ü"]="U",
  ["Ý"]="Y",["Þ"]="TH",
  -- lowercase
  ["à"]="a",["á"]="a",["â"]="a",["ã"]="a",["ä"]="a",["å"]="a",["æ"]="ae",
  ["ç"]="c",
  ["è"]="e",["é"]="e",["ê"]="e",["ë"]="e",
  ["ì"]="i",["í"]="i",["î"]="i",["ï"]="i",
  ["ð"]="d",["ñ"]="n",
  ["ò"]="o",["ó"]="o",["ô"]="o",["õ"]="o",["ö"]="o",["ø"]="o",
  ["ù"]="u",["ú"]="u",["û"]="u",["ü"]="u",
  ["ý"]="y",["þ"]="th",["ß"]="ss",["ÿ"]="y",

  -- ── Latin Extended-A (U+0100–U+017F) ────────────────────────────────────────
  -- A/a
  ["Ā"]="A",["ā"]="a",["Ă"]="A",["ă"]="a",["Ą"]="A",["ą"]="a",
  -- C/c
  ["Ć"]="C",["ć"]="c",["Ĉ"]="C",["ĉ"]="c",["Ċ"]="C",["ċ"]="c",["Č"]="C",["č"]="c",
  -- D/d
  ["Ď"]="D",["ď"]="d",["Đ"]="D",["đ"]="d",
  -- E/e
  ["Ē"]="E",["ē"]="e",["Ĕ"]="E",["ĕ"]="e",["Ė"]="E",["ė"]="e",
  ["Ę"]="E",["ę"]="e",["Ě"]="E",["ě"]="e",
  -- G/g
  ["Ĝ"]="G",["ĝ"]="g",["Ğ"]="G",["ğ"]="g",["Ġ"]="G",["ġ"]="g",["Ģ"]="G",["ģ"]="g",
  -- H/h
  ["Ĥ"]="H",["ĥ"]="h",["Ħ"]="H",["ħ"]="h",
  -- I/i
  ["Ĩ"]="I",["ĩ"]="i",["Ī"]="I",["ī"]="i",["Ĭ"]="I",["ĭ"]="i",
  ["Į"]="I",["į"]="i",["İ"]="I",["ı"]="i",["Ĳ"]="IJ",["ĳ"]="ij",
  -- J/j
  ["Ĵ"]="J",["ĵ"]="j",
  -- K/k
  ["Ķ"]="K",["ķ"]="k",["ĸ"]="k",
  -- L/l
  ["Ĺ"]="L",["ĺ"]="l",["Ļ"]="L",["ļ"]="l",["Ľ"]="L",["ľ"]="l",
  ["Ŀ"]="L",["ŀ"]="l",["Ł"]="L",["ł"]="l",
  -- N/n
  ["Ń"]="N",["ń"]="n",["Ņ"]="N",["ņ"]="n",["Ň"]="N",["ň"]="n",
  ["ŉ"]="n",["Ŋ"]="NG",["ŋ"]="ng",
  -- O/o
  ["Ō"]="O",["ō"]="o",["Ŏ"]="O",["ŏ"]="o",["Ő"]="O",["ő"]="o",["Œ"]="OE",["œ"]="oe",
  -- R/r
  ["Ŕ"]="R",["ŕ"]="r",["Ŗ"]="R",["ŗ"]="r",["Ř"]="R",["ř"]="r",
  -- S/s
  ["Ś"]="S",["ś"]="s",["Ŝ"]="S",["ŝ"]="s",["Ş"]="S",["ş"]="s",["Š"]="S",["š"]="s",
  -- T/t
  ["Ţ"]="T",["ţ"]="t",["Ť"]="T",["ť"]="t",["Ŧ"]="T",["ŧ"]="t",
  -- U/u
  ["Ũ"]="U",["ũ"]="u",["Ū"]="U",["ū"]="u",["Ŭ"]="U",["ŭ"]="u",
  ["Ů"]="U",["ů"]="u",["Ű"]="U",["ű"]="u",["Ų"]="U",["ų"]="u",
  -- W/w
  ["Ŵ"]="W",["ŵ"]="w",
  -- Y/y
  ["Ŷ"]="Y",["ŷ"]="y",["Ÿ"]="Y",
  -- Z/z
  ["Ź"]="Z",["ź"]="z",["Ż"]="Z",["ż"]="z",["Ž"]="Z",["ž"]="z",

  -- ── Latin Extended-B (U+0180–U+024F) ────────────────────────────────────────
  ["ƀ"]="b",["Ɓ"]="B",["Ƃ"]="b",["ƃ"]="b",
  ["Ƈ"]="C",["ƈ"]="c",
  ["Ɖ"]="D",["Ɗ"]="D",["Ƌ"]="D",["ƌ"]="d",
  ["Ǆ"]="DZ",["ǆ"]="dz",["ǅ"]="Dz",
  ["Ǉ"]="LJ",["ǉ"]="lj",["ǈ"]="Lj",
  ["Ǌ"]="NJ",["ǌ"]="nj",["ǋ"]="Nj",
  ["Ǎ"]="A",["ǎ"]="a",["Ǐ"]="I",["ǐ"]="i",["Ǒ"]="O",["ǒ"]="o",["Ǔ"]="U",["ǔ"]="u",
  ["Ǖ"]="U",["ǖ"]="u",["Ǘ"]="U",["ǘ"]="u",["Ǚ"]="U",["ǚ"]="u",["Ǜ"]="U",["ǜ"]="u",
  ["Ǟ"]="A",["ǟ"]="a",["Ǡ"]="A",["ǡ"]="a",["Ǣ"]="AE",["ǣ"]="ae",
  ["Ǥ"]="G",["ǥ"]="g",["Ǧ"]="G",["ǧ"]="g",["Ǩ"]="K",["ǩ"]="k",
  ["Ǫ"]="O",["ǫ"]="o",["Ǭ"]="O",["ǭ"]="o",
  ["Ǯ"]="Z",["ǯ"]="z",
  ["Ǳ"]="DZ",["ǲ"]="Dz",["ǳ"]="dz",
  ["Ǵ"]="G",["ǵ"]="g",["Ƕ"]="HV",["Ƿ"]="W",
  ["Ǹ"]="N",["ǹ"]="n",["Ǻ"]="A",["ǻ"]="a",["Ǽ"]="AE",["ǽ"]="ae",
  ["Ǿ"]="O",["ǿ"]="o",
  ["Ȁ"]="A",["ȁ"]="a",["Ȃ"]="A",["ȃ"]="a",
  ["Ȅ"]="E",["ȅ"]="e",["Ȇ"]="E",["ȇ"]="e",
  ["Ȉ"]="I",["ȉ"]="i",["Ȋ"]="I",["ȋ"]="i",
  ["Ȍ"]="O",["ȍ"]="o",["Ȏ"]="O",["ȏ"]="o",
  ["Ȑ"]="R",["ȑ"]="r",["Ȓ"]="R",["ȓ"]="r",
  ["Ȕ"]="U",["ȕ"]="u",["Ȗ"]="U",["ȗ"]="u",
  ["Ș"]="S",["ș"]="s",["Ț"]="T",["ț"]="t",
  ["Ȟ"]="H",["ȟ"]="h",
  ["Ȧ"]="A",["ȧ"]="a",["Ȩ"]="E",["ȩ"]="e",["Ȫ"]="O",["ȫ"]="o",
  ["Ȭ"]="O",["ȭ"]="o",["Ȯ"]="O",["ȯ"]="o",["Ȱ"]="O",["ȱ"]="o",
  ["Ȳ"]="Y",["ȳ"]="y",

  -- ── Latin Extended Additional (U+1E00–U+1EFF) ────────────────────────────────
  -- A/a
  ["Ạ"]="A",["ạ"]="a",["Ả"]="A",["ả"]="a",["Ấ"]="A",["ấ"]="a",
  ["Ầ"]="A",["ầ"]="a",["Ẩ"]="A",["ẩ"]="a",["Ẫ"]="A",["ẫ"]="a",["Ậ"]="A",["ậ"]="a",
  ["Ắ"]="A",["ắ"]="a",["Ằ"]="A",["ằ"]="a",["Ẳ"]="A",["ẳ"]="a",["Ẵ"]="A",["ẵ"]="a",["Ặ"]="A",["ặ"]="a",
  -- B/b
  ["Ḃ"]="B",["ḃ"]="b",["Ḅ"]="B",["ḅ"]="b",["Ḇ"]="B",["ḇ"]="b",
  -- C/c
  ["Ḉ"]="C",["ḉ"]="c",
  -- D/d
  ["Ḋ"]="D",["ḋ"]="d",["Ḍ"]="D",["ḍ"]="d",["Ḏ"]="D",["ḏ"]="d",["Ḑ"]="D",["ḑ"]="d",["Ḓ"]="D",["ḓ"]="d",
  -- E/e
  ["Ẹ"]="E",["ẹ"]="e",["Ẻ"]="E",["ẻ"]="e",["Ẽ"]="E",["ẽ"]="e",
  ["Ế"]="E",["ế"]="e",["Ề"]="E",["ề"]="e",["Ể"]="E",["ể"]="e",["Ễ"]="E",["ễ"]="e",["Ệ"]="E",["ệ"]="e",
  -- F/f
  ["Ḟ"]="F",["ḟ"]="f",
  -- G/g
  ["Ḡ"]="G",["ḡ"]="g",
  -- H/h
  ["Ḣ"]="H",["ḣ"]="h",["Ḥ"]="H",["ḥ"]="h",["Ḧ"]="H",["ḧ"]="h",["Ḩ"]="H",["ḩ"]="h",["Ḫ"]="H",["ḫ"]="h",
  -- I/i
  ["Ị"]="I",["ị"]="i",["Ỉ"]="I",["ỉ"]="i",
  -- K/k
  ["Ḱ"]="K",["ḱ"]="k",["Ḳ"]="K",["ḳ"]="k",["Ḵ"]="K",["ḵ"]="k",
  -- L/l
  ["Ḷ"]="L",["ḷ"]="l",["Ḹ"]="L",["ḹ"]="l",["Ḻ"]="L",["ḻ"]="l",["Ḽ"]="L",["ḽ"]="l",
  -- M/m
  ["Ḿ"]="M",["ḿ"]="m",["Ṁ"]="M",["ṁ"]="m",["Ṃ"]="M",["ṃ"]="m",
  -- N/n
  ["Ṅ"]="N",["ṅ"]="n",["Ṇ"]="N",["ṇ"]="n",["Ṉ"]="N",["ṉ"]="n",["Ṋ"]="N",["ṋ"]="n",
  -- O/o
  ["Ọ"]="O",["ọ"]="o",["Ỏ"]="O",["ỏ"]="o",["Ố"]="O",["ố"]="o",
  ["Ồ"]="O",["ồ"]="o",["Ổ"]="O",["ổ"]="o",["Ỗ"]="O",["ỗ"]="o",["Ộ"]="O",["ộ"]="o",
  ["Ớ"]="O",["ớ"]="o",["Ờ"]="O",["ờ"]="o",["Ở"]="O",["ở"]="o",["Ỡ"]="O",["ỡ"]="o",["Ợ"]="O",["ợ"]="o",
  -- P/p
  ["Ṕ"]="P",["ṕ"]="p",["Ṗ"]="P",["ṗ"]="p",
  -- R/r
  ["Ṙ"]="R",["ṙ"]="r",["Ṛ"]="R",["ṛ"]="r",["Ṝ"]="R",["ṝ"]="r",["Ṟ"]="R",["ṟ"]="r",
  -- S/s
  ["Ṡ"]="S",["ṡ"]="s",["Ṣ"]="S",["ṣ"]="s",["Ṥ"]="S",["ṥ"]="s",["Ṧ"]="S",["ṧ"]="s",["Ṩ"]="S",["ṩ"]="s",
  -- T/t
  ["Ṫ"]="T",["ṫ"]="t",["Ṭ"]="T",["ṭ"]="t",["Ṯ"]="T",["ṯ"]="t",["Ṱ"]="T",["ṱ"]="t",
  -- U/u
  ["Ụ"]="U",["ụ"]="u",["Ủ"]="U",["ủ"]="u",["Ứ"]="U",["ứ"]="u",
  ["Ừ"]="U",["ừ"]="u",["Ử"]="U",["ử"]="u",["Ữ"]="U",["ữ"]="u",["Ự"]="U",["ự"]="u",
  -- V/v
  ["Ṽ"]="V",["ṽ"]="v",["Ṿ"]="V",["ṿ"]="v",
  -- W/w
  ["Ẁ"]="W",["ẁ"]="w",["Ẃ"]="W",["ẃ"]="w",["Ẅ"]="W",["ẅ"]="w",["Ẇ"]="W",["ẇ"]="w",["Ẉ"]="W",["ẉ"]="w",
  -- X/x
  ["Ẋ"]="X",["ẋ"]="x",["Ẍ"]="X",["ẍ"]="x",
  -- Y/y
  ["Ẏ"]="Y",["ẏ"]="y",["Ỳ"]="Y",["ỳ"]="y",["Ỵ"]="Y",["ỵ"]="y",["Ỷ"]="Y",["ỷ"]="y",["Ỹ"]="Y",["ỹ"]="y",
  -- Z/z
  ["Ẑ"]="Z",["ẑ"]="z",["Ẓ"]="Z",["ẓ"]="z",["Ẕ"]="Z",["ẕ"]="z",
}

function M.ascii_safe(str)
  if not str then
    return ""
  end
  -- Transliterate known accented characters to ASCII equivalents
  -- Iterate over UTF-8 codepoints by matching multi-byte sequences
  local result = {}
  local i = 1
  local bytes = { str:byte(1, #str) }
  while i <= #bytes do
    local b = bytes[i]
    local char_len
    if b < 0x80 then
      char_len = 1
    elseif b < 0xE0 then
      char_len = 2
    elseif b < 0xF0 then
      char_len = 3
    else
      char_len = 4
    end
    local char = str:sub(i, i + char_len - 1)
    local replacement = _translit[char]
    if replacement then
      table.insert(result, replacement)
    elseif b >= 0x20 and b < 0x7F then
      -- plain ASCII printable
      table.insert(result, char)
    end
    -- non-ASCII chars not in the table are dropped
    i = i + char_len
  end
  return table.concat(result)
end

function M.truncate(str, max_len)
  if not str then
    return ""
  end
  str = M.ascii_safe(str)
  if #str <= max_len then
    return str
  end
  if max_len <= 2 then
    return str:sub(1, max_len)
  end
  local ellipsis = "..."
  return str:sub(1, max_len - #ellipsis) .. ellipsis
end

function M.get_meeting_url(event)
  if event.conferenceData and event.conferenceData.entryPoints then
    for _, ep in ipairs(event.conferenceData.entryPoints) do
      if ep.entryPointType == "video" and ep.uri then
        return ep.uri
      end
    end
  end
  if event.hangoutLink then
    return event.hangoutLink
  end
  if event.htmlLink then
    return event.htmlLink
  end
  return nil
end

--- Convert common Google Calendar HTML to markdown.
--- Handles <br>, <p>, <b>/<strong>, <i>/<em>, <a>, <ul>/<ol>/<li>,
--- entity decoding, and whitespace normalisation.
function M.html_to_markdown(html)
  if not html or html == "" then
    return ""
  end

  local s = html

  -- Normalise line endings
  s = s:gsub("\r\n", "\n"):gsub("\r", "\n")

  -- Block-level elements → newlines (before stripping tags)
  s = s:gsub("<br%s*/?>", "\n")
  s = s:gsub("</p>", "\n\n")
  s = s:gsub("<p[^>]*>", "")

  -- Lists -----------------------------------------------------------------
  -- <ul>/<ol> boundaries → newlines; <li> → markdown bullets
  s = s:gsub("<ul[^>]*>", "\n")
  s = s:gsub("</ul>", "\n")
  s = s:gsub("<ol[^>]*>", "\n")
  s = s:gsub("</ol>", "\n")
  s = s:gsub("<li[^>]*>", "\n- ")
  s = s:gsub("</li>", "")

  -- Inline formatting -----------------------------------------------------
  -- Bold
  s = s:gsub("<b[^>]*>(.-)</b>", "**%1**")
  s = s:gsub("<strong[^>]*>(.-)</strong>", "**%1**")
  -- Italic
  s = s:gsub("<i[^>]*>(.-)</i>", "*%1*")
  s = s:gsub("<em[^>]*>(.-)</em>", "*%1*")

  -- Links: <a href="url">text</a> → [text](url)
  s = s:gsub('<a[^>]-href="([^"]*)"[^>]*>(.-)</a>', "[%2](%1)")
  s = s:gsub("<a[^>]-href='([^']*)'[^>]*>(.-)</a>", "[%2](%1)")

  -- Strip remaining HTML tags
  s = s:gsub("<[^>]+>", "")

  -- Decode HTML entities
  s = s:gsub("&nbsp;", " ")
  s = s:gsub("&amp;", "&")
  s = s:gsub("&lt;", "<")
  s = s:gsub("&gt;", ">")
  s = s:gsub("&quot;", '"')
  s = s:gsub("&#39;", "'")
  s = s:gsub("&#(%d+);", function(n)
    local num = tonumber(n)
    if num and num < 128 then
      return string.char(num)
    end
    return ""
  end)

  -- Whitespace normalisation
  s = s:gsub(" +", " ")        -- collapse runs of spaces
  s = s:gsub("\n +", "\n")     -- trim leading spaces on lines
  s = s:gsub(" +\n", "\n")     -- trim trailing spaces on lines
  s = s:gsub("\n\n\n+", "\n\n") -- max two consecutive newlines
  s = s:match("^%s*(.-)%s*$")  -- trim outer whitespace

  return s
end

function M.ensure_dir(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

function M.read_json(path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local content = vim.fn.readfile(path)
  if not content or #content == 0 then
    return nil
  end
  local ok, data = pcall(vim.json.decode, table.concat(content, "\n"))
  if ok then
    return data
  end
  return nil
end

function M.write_json(path, data)
  M.ensure_dir(path)
  local encoded = vim.json.encode(data)
  vim.fn.writefile({ encoded }, path)
end

return M
