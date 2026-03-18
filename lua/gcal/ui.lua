local config = require('gcal.config')
local api = require('gcal.api')
local colors = require('gcal.colors')
local utils = require('gcal.utils')

local M = {}

local state = {
    buf = nil,
    win = nil,
    current_week_start = nil,
    events = {},
    calendars = {},
    ns = vim.api.nvim_create_namespace('gcal'),
    cursor_ns = vim.api.nvim_create_namespace('gcal_cursor'),
    popup_wins = {}, -- track all open detail popup windows
    all_day_lines = {}, -- built by render(), used by show_event_hover()
    total_slots = 0, -- grid slot count, set by render()
    focused_event_idx = nil, -- index into state.events of the last n/N-navigated event
    events_by_slot = {}, -- "day:slot" -> parsed event; set by render(), used by _place_cursor_on
}

local SLOT_MINUTES = 30
local TIME_COL_WIDTH = 7
local SEP = '|'
local HSEP = '-'
local CROSS = '+'

local function slots_per_day()
    local opts = config.options.view
    return (opts.day_end_hour - opts.day_start_hour) * (60 / SLOT_MINUTES)
end

local function is_valid_win()
    return state.win and vim.api.nvim_win_is_valid(state.win)
end

local function is_valid_buf()
    return state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

local function day_col_width(total_width)
    return math.floor((total_width - TIME_COL_WIDTH - 8) / 7)
end

local function parse_event_times(event)
    if not event.start then
        return nil
    end
    local start_str = event.start.dateTime or event.start.date
    local end_str = event['end']
        and (event['end'].dateTime or event['end'].date)
    local start_ts, is_all_day = utils.iso8601_to_timestamp(start_str)
    local end_ts
    if end_str then
        end_ts = utils.iso8601_to_timestamp(end_str)
    else
        end_ts = start_ts + 3600
    end
    return {
        start_ts = start_ts,
        end_ts = end_ts,
        all_day = is_all_day,
        summary = event.summary or '(No title)',
        calendar_id = event._calendar_id,
        event = event,
    }
end

-- Deduplicate events that appear in more than one calendar (e.g. a meeting
-- shared to both a personal and a work calendar).  Google guarantees that every
-- copy of the same event shares the same `iCalUID`.  When duplicates are found
-- the copy whose `_calendar_id` belongs to the user's primary calendar is kept;
-- if no primary-calendar copy exists the first encountered copy is kept.
local function deduplicate_events(events, calendars)
    -- Build a set of primary calendar IDs.
    local primary_ids = {}
    for _, cal in ipairs(calendars or {}) do
        if cal.primary then
            primary_ids[cal.id] = true
        end
    end

    local seen = {} -- (iCalUID .. "|" .. start_date) -> index in `result`
    local result = {}

    for _, ev in ipairs(events) do
        local uid = ev.iCalUID or ev.id
        if not uid then
            -- No dedup key available — keep as-is.
            table.insert(result, ev)
        else
            -- Include the instance start date so that different occurrences of a
            -- recurring event (which share the same iCalUID) are NOT collapsed.
            -- Only true cross-calendar copies of the exact same instance are deduped.
            local start_date = (
                ev.start and (ev.start.dateTime or ev.start.date)
            ) or ''
            local key = uid .. '|' .. start_date
            local existing_idx = seen[key]
            if not existing_idx then
                -- First time we see this instance.
                table.insert(result, ev)
                seen[key] = #result
            else
                -- Duplicate found.  Swap in the primary-calendar copy if the current
                -- winner is not already from a primary calendar.
                local current_winner = result[existing_idx]
                if
                    not primary_ids[current_winner._calendar_id]
                    and primary_ids[ev._calendar_id]
                then
                    result[existing_idx] = ev
                end
                -- Otherwise discard this copy.
            end
        end
    end

    return result
end

local function filter_confirmed_events(events)
    local confirmed = {}
    for _, ev in ipairs(events or {}) do
        if utils.is_confirmed_for_me(ev) then
            table.insert(confirmed, ev)
        end
    end
    return confirmed
end

local function get_day_index(ts, week_start_ts)
    local diff = os.difftime(ts, week_start_ts)
    return math.floor(diff / 86400)
end

local function get_slot_index(ts)
    local date = os.date('*t', ts)
    local minutes = date.hour * 60 + date.min
    local start_minutes = config.options.view.day_start_hour * 60
    return math.floor((minutes - start_minutes) / SLOT_MINUTES)
end

local function pad_right(str, width)
    local len = #str
    if len >= width then
        return str:sub(1, width)
    end
    return str .. string.rep(' ', width - len)
end

local function build_header_line(week_start_ts, total_width)
    local week_end_ts = week_start_ts + 6 * 86400
    local start_str = os.date('%b %d', week_start_ts)
    local end_str = os.date('%b %d, %Y', week_end_ts)
    local title = '  Week of ' .. start_str .. ' - ' .. end_str
    local suffix = ' [o]pen  [r]efresh '
    local padding = total_width - #title - #suffix
    if padding < 0 then
        padding = 0
    end
    return title .. string.rep(' ', padding) .. suffix
end

local function build_day_header(week_start_ts, col_w)
    local days = utils.get_day_dates(week_start_ts)
    local day_names = { 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun' }
    if config.options.week_start == 'sunday' then
        day_names = { 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat' }
    end
    local line = string.rep(' ', TIME_COL_WIDTH) .. SEP
    for i, d in ipairs(days) do
        local label = day_names[i] .. ' ' .. os.date('%d', d)
        line = line .. pad_right(' ' .. label, col_w) .. SEP
    end
    return line
end

local function build_separator(col_w)
    local line = string.rep(HSEP, TIME_COL_WIDTH) .. CROSS
    for _ = 1, 7 do
        line = line .. string.rep(HSEP, col_w) .. CROSS
    end
    return line
end

local function format_slot_time(slot_idx)
    local start_min = config.options.view.day_start_hour * 60
    local minutes = start_min + slot_idx * SLOT_MINUTES
    local h = math.floor(minutes / 60)
    local m = minutes % 60
    if config.options.time_format == '12h' then
        local suffix = h >= 12 and 'PM' or 'AM'
        local h12 = h % 12
        if h12 == 0 then
            h12 = 12
        end
        return string.format('%2d:%02d%s', h12, m, suffix)
    end
    return string.format(' %02d:%02d', h, m)
end

local function build_grid(events_by_slot, col_w, total_slots, slot_count)
    local lines = {}
    local overlap_hints = {} -- list (per slot) of { byte_start, byte_end, calendar_id }
    for slot = 0, total_slots - 1 do
        local time_label = format_slot_time(slot)
        local line = pad_right(time_label, TIME_COL_WIDTH) .. SEP
        local row_overlaps = {}
        for day = 0, 6 do
            local key = day .. ':' .. slot
            local ev = events_by_slot[key]
            if ev then
                local has_overlap = (slot_count[key] or 1) > 1
                if has_overlap then
                    -- Reserve the last char of the cell for the "+" indicator.
                    -- Normal cell: pad_right(" " .. title, col_w)  → col_w chars
                    -- Overlap cell: pad_right(" " .. title, col_w-1) .. "+"  → col_w chars
                    local title = utils.truncate(ev.summary, col_w - 2)
                    local cell = pad_right(' ' .. title, col_w - 1)
                    local byte_start = #line + #cell
                    line = line .. cell .. '+' .. SEP
                    table.insert(row_overlaps, {
                        byte_start = byte_start,
                        byte_end = byte_start + 1,
                        calendar_id = ev.calendar_id,
                    })
                else
                    local title = utils.truncate(ev.summary, col_w - 2)
                    line = line .. pad_right(' ' .. title, col_w) .. SEP
                end
            else
                line = line .. string.rep(' ', col_w) .. SEP
            end
        end
        table.insert(lines, line)
        table.insert(overlap_hints, row_overlaps)
    end
    return lines, overlap_hints
end

-- Returns a list of { line, highlights, event, min_day, max_day }
-- One entry per unique all-day event group (grouped by summary).
local function build_all_day_lines(all_day_events, week_start_ts, col_w)
    if #all_day_events == 0 then
        return {}
    end

    -- Group by summary so that:
    --   • recurring instances of the same event collapse into one row
    --   • a single multi-day event spanning several days of the week shows the
    --     full span (the API returns end.date as exclusive, so we expand from
    --     start_ts up to but not including end_ts, one day at a time)
    local groups = {}
    local order = {}
    for _, ev in ipairs(all_day_events) do
        local raw = ev.event or {}
        local key = ev.summary -- group by title regardless of calendar / recurrence

        if not groups[key] then
            groups[key] = {
                summary = ev.summary,
                calendar_id = ev.calendar_id,
                days = {},
                created = raw.created or '',
                event = raw,
            }
            table.insert(order, key)
        end

        -- Expand every day this event occupies within the visible week.
        -- end_ts is exclusive (Google convention), so iterate start → end-1day.
        local d_ts = ev.start_ts
        while d_ts < ev.end_ts do
            local day_idx = get_day_index(d_ts, week_start_ts)
            if day_idx >= 0 and day_idx <= 6 then
                groups[key].days[day_idx] = true
            end
            d_ts = d_ts + 86400
        end
    end

    -- Sort by created (lexicographic ISO8601)
    table.sort(order, function(a, b)
        return groups[a].created < groups[b].created
    end)

    local results = {}
    for row_idx, key in ipairs(order) do
        local g = groups[key]

        -- Find contiguous span: min_day..max_day
        local min_day, max_day = 6, 0
        for d, _ in pairs(g.days) do
            if d < min_day then
                min_day = d
            end
            if d > max_day then
                max_day = d
            end
        end

        -- Build the line without a time-column label and without pipe separators.
        -- Start with spaces equal to the time column + separator so event titles
        -- align visually under the day columns in the grid above.
        -- Each day occupies col_w+1 chars (col_w content + 1 for the removed pipe).
        local time_prefix = string.rep(' ', TIME_COL_WIDTH + 1)
        local prefix_width = TIME_COL_WIDTH + 1 + min_day * (col_w + 1)
        local span = max_day - min_day + 1
        local cell_width = span * (col_w + 1)
        local title = utils.truncate(' ' .. g.summary, cell_width - 1)
        local cell = pad_right(title, cell_width)

        -- Left-pad with spaces up to min_day, then the event cell, then spaces to fill
        local day_area_prefix = string.rep(' ', min_day * (col_w + 1))
        local day_area_suffix = string.rep(' ', (6 - max_day) * (col_w + 1))
        local line = time_prefix .. day_area_prefix .. cell .. day_area_suffix

        local span_byte_start = prefix_width
        local span_byte_end = prefix_width + cell_width

        local hl = colors.get_calendar_hl(g.calendar_id)
        table.insert(results, {
            line = line,
            highlights = {
                { 'GcalAllDay', 0, -1 },
                { hl, span_byte_start, span_byte_end },
            },
            event = g.event,
            min_day = min_day,
            max_day = max_day,
        })
    end

    return results
end

local function format_time_until(start_ts, end_ts)
    local now = os.time()
    local function hm(secs)
        secs = math.abs(secs)
        local d = math.floor(secs / 86400)
        local h = math.floor((secs % 86400) / 3600)
        local m = math.floor((secs % 3600) / 60)
        if d > 0 then
            return d .. 'd ' .. h .. 'h'
        elseif h > 0 then
            return h .. 'h ' .. m .. 'm'
        else
            return m .. 'm'
        end
    end
    if now < start_ts then
        return 'Starts in ' .. hm(start_ts - now)
    elseif now < end_ts then
        return 'In progress · ends in ' .. hm(end_ts - now)
    else
        return 'Ended ' .. hm(now - end_ts) .. ' ago'
    end
end

local function get_nvim_notify()
    local ok, n = pcall(require, 'notify')
    if ok and type(n) == 'table' and type(n.notify) == 'function' then
        return n
    end
    return nil
end

local function notify(msg, level, opts)
    local nvim_notify = get_nvim_notify()
    if nvim_notify then
        nvim_notify.notify(msg, level, opts)
    else
        vim.notify(msg, level, opts)
    end
end

local function open_url_from_string(url)
    if not url or url == '' then
        return
    end
    if vim.ui and vim.ui.open then
        vim.ui.open(url)
    else
        local cmd = vim.fn.has('mac') == 1 and 'open' or 'xdg-open'
        vim.fn.jobstart({ cmd, url }, { detach = true })
    end
end

local function inject_url_keymap(opts, url)
    if not url or url == '' then
        return opts
    end
    local prev_on_open = opts.on_open
    opts.on_open = function(win)
        if prev_on_open then
            prev_on_open(win)
        end
        if not vim.api.nvim_win_is_valid(win) then
            return
        end
        local buf = vim.api.nvim_win_get_buf(win)
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        vim.keymap.set(
            'n',
            '<CR>',
            function()
                open_url_from_string(url)
            end,
            {
                buffer = buf,
                silent = true,
                nowait = true,
                desc = 'Open event URL',
            }
        )
    end
    return opts
end

local function is_same_day(ts_a, ts_b)
    return os.date('%Y-%m-%d', ts_a) == os.date('%Y-%m-%d', ts_b)
end

local function append_wrapped_kv(lines, key, value, max_width)
    local prefix = key .. ': '
    local width = math.max(10, max_width - #prefix)
    local text = tostring(value or '')
    local first = true
    local current = ''

    for raw_word in text:gmatch('%S+') do
        local words = {}
        local word = raw_word
        while #word > width do
            table.insert(words, word:sub(1, width))
            word = word:sub(width + 1)
        end
        table.insert(words, word)

        for _, word_part in ipairs(words) do
            local word = word_part
        if current == '' then
            current = word
        elseif #current + 1 + #word <= width then
            current = current .. ' ' .. word
        else
            if first then
                table.insert(lines, prefix .. current)
                first = false
            else
                table.insert(lines, string.rep(' ', #prefix) .. current)
            end
            current = word
        end
        end
    end

    if current == '' then
        table.insert(lines, prefix)
    elseif first then
        table.insert(lines, prefix .. current)
    else
        table.insert(lines, string.rep(' ', #prefix) .. current)
    end
end

local function notify_no_meeting_with_next(next_meeting)
    local no_meeting_msg = 'No meeting in the next 15 minutes.'
    local max_width = #no_meeting_msg
    notify(no_meeting_msg, vim.log.levels.INFO, { title = 'gcal.nvim' })

    local lines = {}
    append_wrapped_kv(
        lines,
        'Next meeting',
        next_meeting.summary or '(No title)',
        max_width
    )
    append_wrapped_kv(
        lines,
        'Date',
        os.date('%a %b %d, %Y', next_meeting.start_ts),
        max_width
    )
    append_wrapped_kv(
        lines,
        'Time',
        utils.format_time(next_meeting.start_ts, config.options.time_format)
            .. ' - '
            .. utils.format_time(next_meeting.end_ts, config.options.time_format),
        max_width
    )

    local url = utils.get_meeting_url(next_meeting.event)
    if url then
        append_wrapped_kv(lines, 'Link', url, max_width)
    else
        append_wrapped_kv(lines, 'Link', '(none)', max_width)
    end

    local msg = table.concat(lines, '\n')
    notify(
        msg,
        vim.log.levels.INFO,
        inject_url_keymap({
            title = 'gcal.nvim',
            timeout = 12000,
            max_width = max_width,
        }, url)
    )
end

local function collect_current_and_upcoming(events, now)
    local ignored_event_types = {
        focusTime = true,
        outOfOffice = true,
        workingLocation = true,
    }

    local in_progress = {}
    local upcoming = nil

    for _, ev in ipairs(events or {}) do
        local p = parse_event_times(ev)
        local event_type = ev and ev.eventType
        local is_meeting = not ignored_event_types[event_type]
        if p and is_meeting and not p.all_day and p.start_ts and p.end_ts then
            if now >= p.start_ts and now < p.end_ts then
                table.insert(in_progress, p)
            elseif p.start_ts > now then
                if not upcoming or p.start_ts < upcoming.start_ts then
                    upcoming = p
                end
            end
        end
    end

    table.sort(in_progress, function(a, b)
        return a.start_ts > b.start_ts
    end)

    return in_progress, upcoming
end

local function wrap_text(text, width)
    local lines = {}
    for paragraph in (text .. '\n'):gmatch('(.-)\n') do
        if paragraph == '' then
            table.insert(lines, '')
        else
            local line = ''
            for word in paragraph:gmatch('%S+') do
                if line == '' then
                    line = word
                elseif #line + 1 + #word <= width then
                    line = line .. ' ' .. word
                else
                    table.insert(lines, line)
                    line = word
                end
            end
            if line ~= '' then
                table.insert(lines, line)
            end
        end
    end
    return lines
end

local function get_col_byte_range(day, col_w)
    local col_start = TIME_COL_WIDTH + 1 + day * (col_w + 1)
    local col_end = col_start + col_w
    return col_start, col_end
end

local function render(events, calendars)
    if not is_valid_buf() then
        return
    end

    state.calendars = calendars or {}
    local deduped_events = deduplicate_events(events or {}, state.calendars)
    state.events = filter_confirmed_events(deduped_events)

    colors.setup_highlights(calendars)

    local total_width
    if is_valid_win() then
        total_width = vim.api.nvim_win_get_width(state.win)
    else
        total_width = vim.o.columns
    end

    local col_w = day_col_width(total_width)
    local total_slots = slots_per_day()
    local week_start_ts = state.current_week_start

    local parsed = {}
    local all_day = {}
    for _, ev in ipairs(state.events) do
        local p = parse_event_times(ev)
        if p then
            if p.all_day then
                table.insert(all_day, p)
            else
                table.insert(parsed, p)
            end
        end
    end

    local events_by_slot = {}
    local slot_event_data = {}
    local slot_count = {} -- key -> number of distinct events overlapping that slot
    for _, ev in ipairs(parsed) do
        local day_idx = get_day_index(ev.start_ts, week_start_ts)
        if day_idx >= 0 and day_idx <= 6 then
            local start_slot = get_slot_index(ev.start_ts)
            local end_slot = get_slot_index(ev.end_ts)
            if end_slot <= start_slot then
                end_slot = start_slot + 1
            end
            for s = math.max(0, start_slot), math.min(total_slots - 1, end_slot - 1) do
                local key = day_idx .. ':' .. s
                if not events_by_slot[key] then
                    events_by_slot[key] = ev
                    slot_event_data[key] = ev
                end
                slot_count[key] = (slot_count[key] or 0) + 1
            end
        end
    end

    local all_day_lines = build_all_day_lines(all_day, week_start_ts, col_w)
    local has_all_day = #all_day_lines > 0

    -- Store in state for hover and cursor highlight
    state.all_day_lines = all_day_lines
    state.events_by_slot = events_by_slot
    state.total_slots = total_slots

    local lines = {}
    table.insert(lines, build_header_line(week_start_ts, total_width)) -- row 0
    table.insert(lines, '') -- row 1
    table.insert(lines, build_day_header(week_start_ts, col_w)) -- row 2
    table.insert(lines, build_separator(col_w)) -- row 3

    local grid_lines, overlap_hints =
        build_grid(events_by_slot, col_w, total_slots, slot_count)
    for _, l in ipairs(grid_lines) do
        table.insert(lines, l)
    end

    -- All-day events at the bottom
    if has_all_day then
        table.insert(lines, build_separator(col_w))
        -- Header row for the all-day section
        local label = 'Day long events'
        local left_pad = math.floor((total_width - #label) / 2)
        local all_day_section_header = string.rep(' ', left_pad)
            .. label
            .. string.rep(' ', total_width - left_pad - #label)
        table.insert(lines, all_day_section_header)
        for _, entry in ipairs(all_day_lines) do
            table.insert(lines, entry.line)
        end
    end

    vim.api.nvim_buf_set_option(state.buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(state.buf, 'modifiable', false)

    vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(state.buf, state.cursor_ns, 0, -1)

    vim.api.nvim_buf_add_highlight(state.buf, state.ns, 'GcalTitle', 0, 0, -1)

    local header_row = 2 -- day-name header row (0-indexed)
    local grid_start_row = 4 -- grid always starts at row 4
    vim.api.nvim_buf_add_highlight(
        state.buf,
        state.ns,
        'GcalHeader',
        header_row,
        0,
        -1
    )

    local now = os.time()
    local today_day = get_day_index(now, week_start_ts)
    local current_slot = get_slot_index(now)

    -- Today column highlights
    if today_day >= 0 and today_day <= 6 then
        local cs, ce = get_col_byte_range(today_day, col_w)
        vim.api.nvim_buf_add_highlight(
            state.buf,
            state.ns,
            'GcalTodayHeader',
            header_row,
            cs,
            ce
        )
        for slot = 0, total_slots - 1 do
            local row = grid_start_row + slot
            if row < vim.api.nvim_buf_line_count(state.buf) then
                local key = today_day .. ':' .. slot
                if not slot_event_data[key] then
                    vim.api.nvim_buf_add_highlight(
                        state.buf,
                        state.ns,
                        'GcalToday',
                        row,
                        cs,
                        ce
                    )
                end
            end
        end
    end

    -- Current time row
    if current_slot >= 0 and current_slot < total_slots then
        local now_row = grid_start_row + current_slot
        if now_row < vim.api.nvim_buf_line_count(state.buf) then
            vim.api.nvim_buf_add_highlight(
                state.buf,
                state.ns,
                'GcalNowLine',
                now_row,
                0,
                -1
            )
        end
    end

    -- Time column + calendar event highlights
    for slot = 0, total_slots - 1 do
        local row = grid_start_row + slot
        if row < vim.api.nvim_buf_line_count(state.buf) then
            vim.api.nvim_buf_add_highlight(
                state.buf,
                state.ns,
                'GcalTimeCol',
                row,
                0,
                TIME_COL_WIDTH
            )
            for day = 0, 6 do
                local key = day .. ':' .. slot
                local ev = slot_event_data[key]
                if ev then
                    local hl = colors.get_calendar_hl(ev.calendar_id)
                    local cs, ce = get_col_byte_range(day, col_w)
                    vim.api.nvim_buf_add_highlight(
                        state.buf,
                        state.ns,
                        hl,
                        row,
                        cs,
                        ce
                    )
                end
            end
            -- Overlap "+" indicators — applied on top so the marker stands out
            local hints = overlap_hints[slot + 1]
            if hints then
                for _, h in ipairs(hints) do
                    local ohl = colors.get_calendar_overlap_hl(h.calendar_id)
                    vim.api.nvim_buf_add_highlight(
                        state.buf,
                        state.ns,
                        ohl,
                        row,
                        h.byte_start,
                        h.byte_end
                    )
                end
            end
        end
    end

    -- All-day section highlights
    if has_all_day then
        local sep_row = grid_start_row + total_slots
        -- sep_row+0 = separator line, sep_row+1 = "Day long events" header
        local section_header_row = sep_row + 1
        vim.api.nvim_buf_add_highlight(
            state.buf,
            state.ns,
            'GcalHeader',
            section_header_row,
            0,
            -1
        )
        -- All-day event rows start at sep_row+2 (after separator + header)
        for entry_idx, entry in ipairs(all_day_lines) do
            local all_day_row = sep_row + 1 + entry_idx
            if all_day_row < vim.api.nvim_buf_line_count(state.buf) then
                for _, hl_spec in ipairs(entry.highlights) do
                    vim.api.nvim_buf_add_highlight(
                        state.buf,
                        state.ns,
                        hl_spec[1],
                        all_day_row,
                        hl_spec[2],
                        hl_spec[3]
                    )
                end
            end
        end
    end

    -- Place cursor at today's column and current time row (only for current week)
    if is_valid_win() and today_day >= 0 and today_day <= 6 then
        local target_slot = math.max(0, math.min(current_slot, total_slots - 1))
        local target_row = grid_start_row + target_slot + 1 -- 1-indexed
        local col_start = TIME_COL_WIDTH + 1 + today_day * (col_w + 1)
        vim.api.nvim_win_set_cursor(state.win, { target_row, col_start })
    end
end

local function fetch_and_render(force)
    local week_end_ts = state.current_week_start + 7 * 86400

    -- Reset focused event when switching weeks so n/N use now as reference
    state.focused_event_idx = nil

    local now_week = utils.get_week_bounds(os.time(), config.options.week_start)
    local next_week_start = now_week + 7 * 86400
    local cache_key, cache_ttl
    if state.current_week_start == now_week then
        cache_key = 'current_week'
        cache_ttl = config.options.poll_interval_seconds or 60
    elseif state.current_week_start == next_week_start then
        cache_key = 'next_week'
        cache_ttl = (config.options.poll_interval_seconds or 60) * 10
    end

    local once
    if cache_key == 'current_week' then
        once = not force -- poller owns refreshes for current week; UI just reads
    end

    api.get_all_events(
        state.current_week_start,
        week_end_ts,
        function(events, calendars)
            render(events, calendars)
        end,
        {
            cache_key = cache_key,
            cache_ttl = cache_ttl,
            force = force,
            once = once,
        }
    )
end

local function open_url(raw_event)
    local url = utils.get_meeting_url(raw_event)
    if not url then
        local title = (raw_event and raw_event.summary) or 'this event'
        notify(
            'No URL for ' .. title,
            vim.log.levels.INFO,
            { title = 'gcal.nvim' }
        )
        return
    end
    if vim.ui.open then
        vim.ui.open(url)
    else
        local cmd = vim.fn.has('mac') == 1 and 'open' or 'xdg-open'
        vim.fn.jobstart({ cmd, url }, { detach = true })
    end
end

local function open_event_url()
    if not is_valid_win() then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local row = cursor[1]
    local col = cursor[2]
    local total_width = vim.api.nvim_win_get_width(state.win)
    local col_w = day_col_width(total_width)

    local grid_start = 4
    local slot = row - grid_start - 1
    if slot < 0 then
        return
    end

    local day = math.floor((col - TIME_COL_WIDTH - 1) / (col_w + 1))
    if day < 0 or day > 6 then
        return
    end

    local matches = {}
    for _, ev in ipairs(state.events) do
        local p = parse_event_times(ev)
        if p and not p.all_day then
            local d = get_day_index(p.start_ts, state.current_week_start)
            local s = get_slot_index(p.start_ts)
            local e = get_slot_index(p.end_ts)
            if e <= s then
                e = s + 1
            end
            if d == day and slot >= s and slot < e then
                table.insert(matches, p)
            end
        end
    end

    if #matches == 0 then
        return
    elseif #matches == 1 then
        open_url(matches[1].event)
    else
        vim.ui.select(matches, {
            prompt = 'Open URL for:',
            format_item = function(p)
                return p.summary or '(No title)'
            end,
        }, function(choice)
            if choice then
                open_url(choice.event)
            end
        end)
    end
end

-- Build and open the event detail popup for a given raw event table.
local function open_event_popup(ev)
    local total_width = vim.api.nvim_win_get_width(state.win)

    local cal_entry = colors.calendar_map[ev._calendar_id]
    local cal_name = cal_entry and cal_entry.summary or ev._calendar_id or ''

    local start_str = ev.start and (ev.start.dateTime or ev.start.date) or ''
    local end_str = ev['end'] and (ev['end'].dateTime or ev['end'].date) or ''
    local start_ts, is_all_day = utils.iso8601_to_timestamp(start_str)
    local end_ts = utils.iso8601_to_timestamp(end_str)
    -- For all-day events the API end date is exclusive (next day)
    local display_end_ts = (is_all_day and end_ts) and (end_ts - 86400)
        or end_ts

    local popup_width =
        math.min(80, math.max(40, math.floor(total_width * 0.45)))
    local content_width = popup_width - 2

    local detail_lines = {}
    table.insert(detail_lines, '# ' .. (ev.summary or '(No title)'))
    table.insert(detail_lines, '')

    if start_ts then
        if is_all_day then
            local date_str = os.date('%a %b %d', start_ts)
            if display_end_ts and display_end_ts > start_ts then
                date_str = date_str
                    .. ' - '
                    .. os.date('%a %b %d', display_end_ts)
            end
            date_str = date_str .. '  (All day)'
            table.insert(detail_lines, '**Date:** ' .. date_str)
        elseif end_ts then
            table.insert(
                detail_lines,
                '**Date:** '
                    .. os.date('%a %b %d', start_ts)
                    .. '  '
                    .. utils.format_time(start_ts, config.options.time_format)
                    .. ' - '
                    .. utils.format_time(end_ts, config.options.time_format)
            )
        end
    end

    if cal_name ~= '' then
        table.insert(detail_lines, '**Calendar:** ' .. cal_name)
    end

    if start_ts and (end_ts or display_end_ts) then
        table.insert(
            detail_lines,
            '**Status:** '
                .. format_time_until(start_ts, display_end_ts or end_ts)
        )
    end

    local url = utils.get_meeting_url(ev)
    if url then
        table.insert(detail_lines, '')
        table.insert(detail_lines, '[Open in browser](' .. url .. ')')
    end

    if ev.location then
        table.insert(detail_lines, '')
        table.insert(detail_lines, '**Location:** ' .. ev.location)
    end

    if ev.description then
        table.insert(detail_lines, '')
        table.insert(detail_lines, '---')
        table.insert(detail_lines, '')
        local md_desc = utils.html_to_markdown(ev.description)
        local wrapped = wrap_text(md_desc, content_width - 1)
        for _, wline in ipairs(wrapped) do
            table.insert(detail_lines, wline)
        end
    end

    table.insert(detail_lines, '')

    local max_w = 20
    for _, l in ipairs(detail_lines) do
        max_w = math.max(max_w, #l + 2)
    end
    max_w = math.min(max_w, 80)

    local detail_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(detail_buf, 0, -1, false, detail_lines)
    vim.api.nvim_buf_set_option(detail_buf, 'filetype', 'markdown')
    vim.api.nvim_buf_set_option(detail_buf, 'modifiable', false)

    local popup_win = vim.api.nvim_open_win(detail_buf, false, {
        relative = 'cursor',
        row = 1,
        col = 1,
        width = max_w,
        height = #detail_lines,
        style = 'minimal',
        border = 'rounded',
        title = ' Event Details ',
        title_pos = 'center',
        focusable = true,
        zindex = 100,
    })

    -- Enable markdown conceals only in this popup window
    vim.api.nvim_win_set_option(popup_win, 'conceallevel', 2)
    vim.api.nvim_win_set_option(popup_win, 'concealcursor', 'nvic')

    -- Track so M.close() can clean it up
    table.insert(state.popup_wins, popup_win)

    local function close_popup()
        if vim.api.nvim_win_is_valid(popup_win) then
            vim.api.nvim_win_close(popup_win, true)
        end
        for i, pw in ipairs(state.popup_wins) do
            if pw == popup_win then
                table.remove(state.popup_wins, i)
                break
            end
        end
    end

    -- Close popup on any cursor movement in the calendar buffer
    local close_au_id
    close_au_id = vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = state.buf,
        once = true,
        callback = function()
            close_popup()
        end,
    })

    -- Keymaps on the popup buffer (active when user focuses into it)
    vim.keymap.set(
        'n',
        'q',
        close_popup,
        { buffer = detail_buf, nowait = true }
    )
    vim.keymap.set(
        'n',
        '<Esc>',
        close_popup,
        { buffer = detail_buf, nowait = true }
    )
    vim.keymap.set(
        'n',
        'K',
        close_popup,
        { buffer = detail_buf, nowait = true }
    )
    vim.keymap.set('n', '<CR>', function()
        close_popup()
        open_url(ev)
    end, {
        buffer = detail_buf,
        nowait = true,
        desc = 'Open event in browser',
    })

    -- Also close when leaving the popup window
    vim.api.nvim_create_autocmd('WinLeave', {
        buffer = detail_buf,
        once = true,
        callback = function()
            vim.schedule(close_popup)
        end,
    })
end

local function show_event_hover()
    if not is_valid_win() then
        return
    end

    -- Close any existing detail popups first (toggle behavior)
    local had_popup = false
    for _, pw in ipairs(state.popup_wins) do
        if vim.api.nvim_win_is_valid(pw) then
            vim.api.nvim_win_close(pw, true)
            had_popup = true
        end
    end
    state.popup_wins = {}
    if had_popup then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local row = cursor[1]
    local col = cursor[2]
    local total_width = vim.api.nvim_win_get_width(state.win)
    local col_w = day_col_width(total_width)

    local grid_start = 4
    local total_slots = state.total_slots or slots_per_day()
    local slot = row - grid_start - 1

    local ev = nil

    -- Check if cursor is in the all-day section (below grid + separator + header)
    -- Layout: separator at grid_start+total_slots+1 (1-indexed),
    -- "Day long events" header at grid_start+total_slots+2,
    -- all-day rows from grid_start+total_slots+3 onward.
    local all_day_section_start = grid_start + total_slots + 2 -- 1-indexed header row
    if row > all_day_section_start and #state.all_day_lines > 0 then
        local ad_row_idx = row - all_day_section_start
        local entry = state.all_day_lines[ad_row_idx]
        if entry and entry.event then
            ev = entry.event
        end
        if not ev then
            return
        end
        open_event_popup(ev)
    elseif slot >= 0 and slot < total_slots then
        local day = math.floor((col - TIME_COL_WIDTH - 1) / (col_w + 1))
        if day >= 0 and day <= 6 then
            -- Collect ALL events overlapping this slot (handles concurrent meetings)
            local matches = {}
            for _, e in ipairs(state.events) do
                local p = parse_event_times(e)
                if p and not p.all_day then
                    local d =
                        get_day_index(p.start_ts, state.current_week_start)
                    local s = get_slot_index(p.start_ts)
                    local e2 = get_slot_index(p.end_ts)
                    if e2 <= s then
                        e2 = s + 1
                    end
                    if d == day and slot >= s and slot < e2 then
                        table.insert(matches, p.event)
                    end
                end
            end
            if #matches == 0 then
                return
            elseif #matches == 1 then
                open_event_popup(matches[1])
            else
                -- Multiple events at this slot — let the user pick
                vim.ui.select(matches, {
                    prompt = 'Select event:',
                    format_item = function(e)
                        return e.summary or '(No title)'
                    end,
                }, function(choice)
                    if choice then
                        open_event_popup(choice)
                    end
                end)
            end
        end
    end
end

local function go_to_today()
    state.current_week_start =
        utils.get_week_bounds(os.time(), config.options.week_start)
    fetch_and_render()
end

-- Returns the start_ts of the timed event under the cursor, or nil.
local function event_ts_under_cursor()
    if not is_valid_win() then
        return nil
    end
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local row = cursor[1]
    local col = cursor[2]
    local total_width = vim.api.nvim_win_get_width(state.win)
    local col_w = day_col_width(total_width)
    local grid_start = 4
    local slot = row - grid_start - 1
    if slot < 0 then
        return nil
    end
    local day = math.floor((col - TIME_COL_WIDTH - 1) / (col_w + 1))
    if day < 0 or day > 6 then
        return nil
    end
    for _, ev in ipairs(state.events) do
        local p = parse_event_times(ev)
        if p and not p.all_day then
            local d = get_day_index(p.start_ts, state.current_week_start)
            local s = get_slot_index(p.start_ts)
            local e = get_slot_index(p.end_ts)
            if e <= s then
                e = s + 1
            end
            if d == day and slot >= s and slot < e then
                return p.start_ts
            end
        end
    end
    return nil
end

-- Sorted list of {ts, idx} for every timed event in the current view (idx = index in state.events).
-- Events with the same start_ts are ordered by their position in state.events.
local function sorted_event_entries()
    local entries = {}
    for i, ev in ipairs(state.events) do
        local p = parse_event_times(ev)
        if p and not p.all_day and p.start_ts then
            table.insert(entries, { ts = p.start_ts, idx = i })
        end
    end
    table.sort(entries, function(a, b)
        if a.ts ~= b.ts then
            return a.ts < b.ts
        end
        return a.idx < b.idx
    end)
    return entries
end

-- Redraws the cursor-event highlight in cursor_ns.
-- Called on CursorMoved inside the calendar window.
local function update_cursor_highlight()
    if not is_valid_buf() then
        return
    end
    vim.api.nvim_buf_clear_namespace(state.buf, state.cursor_ns, 0, -1)

    if not is_valid_win() then
        return
    end
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local row = cursor[1]
    local col = cursor[2]
    local total_width = vim.api.nvim_win_get_width(state.win)
    local col_w = day_col_width(total_width)
    local total_slots = state.total_slots or slots_per_day()
    local grid_start = 4

    local slot = row - grid_start - 1
    if slot < 0 or slot >= total_slots then
        return
    end

    local day = math.floor((col - TIME_COL_WIDTH - 1) / (col_w + 1))
    if day < 0 or day > 6 then
        return
    end

    for _, ev in ipairs(state.events) do
        local p = parse_event_times(ev)
        if p and not p.all_day then
            local d = get_day_index(p.start_ts, state.current_week_start)
            local s = get_slot_index(p.start_ts)
            local e = get_slot_index(p.end_ts)
            if e <= s then
                e = s + 1
            end
            if d == day and slot >= s and slot < e then
                local cs, ce = get_col_byte_range(day, col_w)
                for slot_i = s, e - 1 do
                    if slot_i >= 0 and slot_i < total_slots then
                        local buf_row = grid_start + slot_i -- 0-indexed
                        vim.api.nvim_buf_add_highlight(
                            state.buf,
                            state.cursor_ns,
                            'GcalCursorEvent',
                            buf_row,
                            cs,
                            ce
                        )
                    end
                end
                break
            end
        end
    end
end

-- Jump to the next (dir=1) or previous (dir=-1) timed event, crossing weeks.
local function navigate_event(dir)
    if not is_valid_win() then
        return
    end

    local entries = sorted_event_entries()

    -- Determine the reference entry: the currently focused one, or fall back to
    -- cursor detection, or fall back to a sentinel near now.
    local ref_idx = state.focused_event_idx
    local ref_ts = nil
    if ref_idx then
        local p = parse_event_times(state.events[ref_idx])
        if p then
            ref_ts = p.start_ts
        end
    end
    if not ref_ts then
        ref_ts = event_ts_under_cursor()
    end

    -- Find the position of the reference in entries so we can step past it.
    -- We match by both ts and idx to handle duplicates.
    local ref_entry_pos = nil
    if ref_idx then
        for pos, e in ipairs(entries) do
            if e.idx == ref_idx then
                ref_entry_pos = pos
                break
            end
        end
    elseif ref_ts then
        -- Cursor-detected ts: point at the last entry with that ts (so n goes past all of them)
        for pos, e in ipairs(entries) do
            if e.ts == ref_ts then
                ref_entry_pos = pos -- keep updating to get last one for forward, first for backward
            end
        end
    end

    local target_entry = nil

    if dir == 1 then
        if ref_entry_pos then
            target_entry = entries[ref_entry_pos + 1]
        else
            -- No reference: find first event after now
            local now = os.time() - 1
            for _, e in ipairs(entries) do
                if e.ts > now then
                    target_entry = e
                    break
                end
            end
        end

        if not target_entry then
            local next_week_start = state.current_week_start + 7 * 86400
            local next_week_end = next_week_start + 7 * 86400
            api.get_all_events(
                next_week_start,
                next_week_end,
                function(events, calendars)
                    local first = nil
                    for _, ev in ipairs(events or {}) do
                        local p = parse_event_times(ev)
                        if p and not p.all_day and p.start_ts then
                            if not first or p.start_ts < first.start_ts then
                                first = p
                            end
                        end
                    end
                    if not first then
                        notify(
                            'No more events',
                            vim.log.levels.INFO,
                            { title = 'gcal.nvim' }
                        )
                        return
                    end
                    state.current_week_start = next_week_start
                    render(events, calendars)
                    vim.schedule(function()
                        M._place_cursor_on(first)
                    end)
                end,
                {
                    cache_key = 'next_week',
                    cache_ttl = (config.options.poll_interval_seconds or 60)
                        * 10,
                }
            )
            return
        end
    else
        if ref_entry_pos then
            target_entry = entries[ref_entry_pos - 1]
        else
            -- No reference: find last event before now
            local now = os.time() + 1
            for i = #entries, 1, -1 do
                if entries[i].ts < now then
                    target_entry = entries[i]
                    break
                end
            end
        end

        if not target_entry then
            local prev_week_start = state.current_week_start - 7 * 86400
            local prev_week_end = prev_week_start + 7 * 86400
            api.get_all_events(
                prev_week_start,
                prev_week_end,
                function(events, calendars)
                    local last = nil
                    for _, ev in ipairs(events or {}) do
                        local p = parse_event_times(ev)
                        if p and not p.all_day and p.start_ts then
                            if not last or p.start_ts > last.start_ts then
                                last = p
                            end
                        end
                    end
                    if not last then
                        notify(
                            'No previous events',
                            vim.log.levels.INFO,
                            { title = 'gcal.nvim' }
                        )
                        return
                    end
                    state.current_week_start = prev_week_start
                    render(events, calendars)
                    vim.schedule(function()
                        M._place_cursor_on(last)
                    end)
                end
            )
            return
        end
    end

    local ev = state.events[target_entry.idx]
    if ev then
        local p = parse_event_times(ev)
        if p then
            M._place_cursor_on(p)
        end
    end
end

local function setup_keymaps()
    local opts = { buffer = state.buf, nowait = true, silent = true }

    local km = config.options.keymaps or {}

    local function bind(lhs_list, rhs)
        if not lhs_list then
            return
        end
        if type(lhs_list) ~= 'table' then
            lhs_list = { lhs_list }
        end
        for _, lhs in ipairs(lhs_list) do
            vim.keymap.set('n', lhs, rhs, opts)
        end
    end

    bind(km.close, function()
        M.close()
    end)

    bind(km.prev_week, function()
        state.current_week_start = state.current_week_start - 7 * 86400
        fetch_and_render()
    end)

    bind(km.next_week, function()
        state.current_week_start = state.current_week_start + 7 * 86400
        fetch_and_render()
    end)

    bind(km.today, function()
        go_to_today()
    end)

    bind(km.refresh, function()
        fetch_and_render(true)
    end)

    bind(km.open_url, function()
        open_event_url()
    end)

    bind(km.hover, function()
        show_event_hover()
    end)

    bind(km.next_event, function()
        navigate_event(1)
    end)

    bind(km.prev_event, function()
        navigate_event(-1)
    end)

    bind(km.open_gcal, function()
        local week_start = state.current_week_start
        if not week_start then
            return
        end
        -- Google Calendar week view URL uses the Monday date as anchor
        local date = os.date('%Y-%m-%d', week_start)
        local url = 'https://calendar.google.com/calendar/r/week/'
            .. date:gsub('-', '/')
        if vim.ui.open then
            vim.ui.open(url)
        else
            local cmd = vim.fn.has('mac') == 1 and 'open' or 'xdg-open'
            vim.fn.jobstart({ cmd, url }, { detach = true })
        end
    end)

    -- Highlight the event under cursor whenever it moves
    vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = state.buf,
        callback = update_cursor_highlight,
    })
end

function M.open()
    if is_valid_win() then
        vim.api.nvim_set_current_win(state.win)
        return
    end

    state.current_week_start =
        utils.get_week_bounds(os.time(), config.options.week_start)

    state.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.buf, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_option(state.buf, 'filetype', 'gcal')
    vim.api.nvim_buf_set_name(state.buf, 'gcal://week')

    local view_opts = config.options.view
    local width = math.floor(vim.o.columns * view_opts.width)
    local height = math.floor(vim.o.lines * view_opts.height)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    state.win = vim.api.nvim_open_win(state.buf, true, {
        relative = 'editor',
        width = width,
        height = height,
        row = row,
        col = col,
        style = 'minimal',
        border = 'rounded',
        title = ' Google Calendar ',
        title_pos = 'center',
    })

    vim.api.nvim_win_set_option(state.win, 'cursorline', true)
    vim.api.nvim_win_set_option(state.win, 'wrap', false)

    setup_keymaps()
    fetch_and_render()
end

function M.close()
    -- Close any open event detail popups first
    for _, pw in ipairs(state.popup_wins) do
        if vim.api.nvim_win_is_valid(pw) then
            vim.api.nvim_win_close(pw, true)
        end
    end
    state.popup_wins = {}

    if is_valid_win() then
        vim.api.nvim_win_close(state.win, true)
    end
    state.win = nil
    state.buf = nil
end

function M.refresh()
    if is_valid_buf() then
        fetch_and_render()
    end
end

function M.today()
    state.current_week_start =
        utils.get_week_bounds(os.time(), config.options.week_start)
    if is_valid_buf() then
        fetch_and_render()
    end
end

-- Finds current or next upcoming timed events, prompts if multiple, then opens the URL.
function M.goto_current_meeting()
    local now = os.time()
    local join_window_seconds = 15 * 60

    local week_start = utils.get_week_bounds(now, config.options.week_start)
    local week_end = week_start + 7 * 24 * 3600

    api.get_all_events(
        week_start,
        week_end,
        function(events)
            local in_progress, upcoming =
                collect_current_and_upcoming(events, now)

            local candidates = {}

            if #in_progress > 0 then
                if #in_progress == 1 then
                    open_url(in_progress[1].event)
                    return
                end

                candidates = in_progress
            else
                if upcoming then
                    local diff = upcoming.start_ts - now
                    if diff <= join_window_seconds then
                        open_url(upcoming.event)
                        return
                    end
                    if is_same_day(upcoming.start_ts, now) then
                        notify_no_meeting_with_next(upcoming)
                    else
                        notify(
                            'No meeting in the next 15 minutes.',
                            vim.log.levels.INFO,
                            { title = 'gcal.nvim' }
                        )
                    end
                    return
                end

                notify(
                    'No meeting in the next 15 minutes.',
                    vim.log.levels.INFO,
                    { title = 'gcal.nvim' }
                )
                return
            end

            if #candidates == 0 then
                notify(
                    'No current or upcoming meeting found',
                    vim.log.levels.INFO,
                    { title = 'gcal.nvim' }
                )
                return
            end

            if #candidates == 1 then
                open_url(candidates[1].event)
                return
            end

            vim.ui.select(candidates, {
                prompt = 'Join meeting:',
                format_item = function(p)
                    local time = utils.format_time(
                        p.start_ts,
                        config.options.time_format
                    ) .. ' - ' .. utils.format_time(
                        p.end_ts,
                        config.options.time_format
                    )
                    local status = (now >= p.start_ts and now < p.end_ts)
                            and ' [now]'
                        or ' [next]'
                    return time .. '  ' .. p.summary .. status
                end,
            }, function(choice)
                if choice then
                    open_url(choice.event)
                end
            end)
        end,
        {
            cache_key = 'current_week',
            cache_ttl = config.options.poll_interval_seconds or 60,
            once = true,
        }
    )
end

-- Internal: moves the cursor to the grid cell for the given parsed event.
function M._place_cursor_on(p)
    if not is_valid_win() then
        return
    end
    local total_width = vim.api.nvim_win_get_width(state.win)
    local col_w = day_col_width(total_width)
    local total_slots = slots_per_day()

    local day = get_day_index(p.start_ts, state.current_week_start)
    if day < 0 or day > 6 then
        return
    end

    local start_slot = get_slot_index(p.start_ts)
    local end_slot = get_slot_index(p.end_ts)
    if end_slot <= start_slot then
        end_slot = start_slot + 1
    end

    -- Find the first slot in this event's range that is visually owned by it.
    -- When an earlier event occupies the event's own start slot, the cursor
    -- should jump to the first slot where this event is actually visible.
    local slot = nil
    for s = math.max(0, start_slot), math.min(total_slots - 1, end_slot - 1) do
        local key = day .. ':' .. s
        local owner = state.events_by_slot[key]
        if not owner or owner.event == p.event then
            slot = s
            break
        end
    end
    -- Fallback: clamp start_slot (event is fully hidden behind another — shouldn't normally happen)
    if not slot then
        slot = math.max(0, math.min(start_slot, total_slots - 1))
    end

    local grid_start_row = 4
    local target_row = grid_start_row + slot + 1 -- 1-indexed
    local col_start = TIME_COL_WIDTH + 1 + day * (col_w + 1)
    -- Record which event was explicitly navigated to, so n/N can use it as ref
    -- Find the index of this event in state.events by matching start_ts and raw event identity
    state.focused_event_idx = nil
    for i, ev in ipairs(state.events) do
        local ep = parse_event_times(ev)
        if ep and ep.start_ts == p.start_ts and ev == p.event then
            state.focused_event_idx = i
            break
        end
    end
    vim.api.nvim_win_set_cursor(state.win, { target_row, col_start })
end

return M
