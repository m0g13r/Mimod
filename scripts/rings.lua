require 'cairo'
require 'cairo_xlib'

collectgarbage("setpause", 100)
collectgarbage("setstepmul", 400)

local floor, pi, max = math.floor, math.pi, math.max
local min = math.min
local two_pi = 2 * pi
local tonumber, tostring = tonumber, tostring
local format = string.format
local insert = table.insert
local concat = table.concat

local CAIRO_STATUS_SUCCESS     = 0
local CAIRO_FONT_SLANT_NORMAL  = 0
local CAIRO_FONT_WEIGHT_NORMAL = 0

local color_defaults = {
    CPU     = 0x268BA0, MEM  = 0x60C9C5,
    TEMP    = 0xA9E2C2, DISK = 0x63EDD0,
    NET_UP  = 0xA9E2C2, NET_DOWN = 0x268BA0,
    TEXT    = 0xEEEEEE, PROGRESS = 0xe0e077,
}
local raw_colors = {
    CPU=color_defaults.CPU, MEM=color_defaults.MEM,
    TEMP=color_defaults.TEMP, DISK=color_defaults.DISK,
    NET_UP=color_defaults.NET_UP, NET_DOWN=color_defaults.NET_DOWN,
    TEXT=color_defaults.TEXT, PROGRESS=color_defaults.PROGRESS,
}
local bg_alpha, fg_alpha = 0.3, 1
local max_history_size = 81
local max_history_size_minus_1 = 80
local angle_0 = -150 * (two_pi / 360) - pi / 2
local angle_f = 150 * (two_pi / 360) - pi / 2
local max_arc = angle_f - angle_0
local home_dir = os.getenv("HOME")
local base_dir = home_dir .. "/.config/conky/Mimod"
local music_cache_file = "/dev/shm/current_song_music_script.txt"
local music_pos_file = "/dev/shm/music_position"
local weather_cache_file = home_dir .. "/.cache/weather.json"
local config_file = base_dir .. "/scripts/config"
local DISK_PTS = { { 56, 443 }, { 137, 443 }, { 56, 523 }, { 137, 523 } }
local WEATHER_ICONS = {["01d"]="",["01n"]="",["02d"]="",["02n"]="",["03d"]="",["03n"]="",["04d"]="",["04n"]="",["09d"]="",["09n"]="",["10d"]="",["10n"]="",["11d"]="",["11n"]="",["13d"]="",["13n"]="",["50d"]="",["50n"]=""}
local PLAYER_ICONS = {["Stopped"]="", ["Playing"]="", ["Paused"]="", ["Unknown"]="", ["None"]=""}

local _frame_now = 0

local state = {
    up = {}, down = {}, nchart = 0, last_update = 0, disk_update_counter = 0,
    disk_paths = {"/dev/null", "/dev/null", "/dev/null", "/dev/null"},
    disk_names = {"N/A", "N/A", "N/A", "N/A"},
    disk_percs = {0, 0, 0, 0}, cpu_temp = 0, cpu_perc = 0, mem_perc = 0, root_perc = 0,
    cached_weather = nil, last_weather_check = 0,
    cached_music = {artist="", title="", status="", position="", pos_raw=0, len_raw=0},
    last_read_tick = 0,
    cached_cover_surf = nil, last_song_id = "", last_cover_fail = 0,
    cover_w = 1, cover_h = 1,
    last_ssid = "", last_ssid_check = 0,
    results_table = {},
    config_cache_content = nil, config_cache_time = 0, config_cache_ttl = 30,
    parse_str_base = nil, last_parse_str = nil,
    bg_surf = nil, bg_w = 0, bg_h = 0,
    iface = nil,
    unit_cache = nil, unit_cache_time = 0,
    last_colors_check = 0,
    last_bg_name = "",
    cpu_unit_cache = nil, cpu_unit_cache_time = 0,
}
for i = 0, max_history_size_minus_1 do state.up[i] = 0.1; state.down[i] = 0.1 end
local rgba_cache = {}

local function _release_surf(s)
    if s then
        cairo_surface_finish(s)
        cairo_surface_destroy(s)
    end
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function read_config_cached(now)
    if state.config_cache_content and (now - state.config_cache_time) < state.config_cache_ttl then
        return state.config_cache_content
    end
    local content = read_file(config_file)
    if content then state.config_cache_content, state.config_cache_time = content, now end
    return content or state.config_cache_content or ""
end

local function get_config_val(key, default, now)
    local content = read_config_cached(now or os.time())
    if content then
        local pattern = key .. '=["\']?([^"\'\n]+)["\']?'
        return content:match(pattern) or default
    end
    return default
end

local function truncate(s, n, suffix)
    suffix = suffix or ".."
    local chars, pos = 0, 1
    while pos <= #s do
        local b = s:byte(pos)
        local c_len = (b >= 240) and 4 or (b >= 224) and 3 or (b >= 192) and 2 or 1
        chars = chars + 1
        if chars > n then return s:sub(1, pos - 1) .. suffix end
        pos = pos + c_len
    end
    return s
end

local function safe_number(v, default)
    local n = tonumber(v)
    return (not n or n ~= n) and (default or 0) or n
end

local function parse_color(s, fallback)
    if not s or s == "" then return fallback end
    local n = tonumber(s:match("^#?(%x+)$"), 16)
    return n or fallback
end

local function load_colors_from_config(now)
    if now - state.last_colors_check < state.config_cache_ttl then return end
    state.last_colors_check = now
    raw_colors.CPU      = parse_color(get_config_val("COLOR_CPU",      "", now), color_defaults.CPU)
    raw_colors.MEM      = parse_color(get_config_val("COLOR_MEM",      "", now), color_defaults.MEM)
    raw_colors.TEMP     = parse_color(get_config_val("COLOR_TEMP",     "", now), color_defaults.TEMP)
    raw_colors.DISK     = parse_color(get_config_val("COLOR_DISK",     "", now), color_defaults.DISK)
    raw_colors.NET_UP   = parse_color(get_config_val("COLOR_NET_UP",   "", now), color_defaults.NET_UP)
    raw_colors.NET_DOWN = parse_color(get_config_val("COLOR_NET_DOWN", "", now), color_defaults.NET_DOWN)
    raw_colors.TEXT     = parse_color(get_config_val("COLOR_TEXT",     "", now), color_defaults.TEXT)
    raw_colors.PROGRESS = parse_color(get_config_val("COLOR_PROGRESS", "", now), color_defaults.PROGRESS)
    rgba_cache = {}
end

local function hex_to_rgba(hex, alpha)
    local key = hex * 1024 + floor(alpha * 1023 + 0.5)
    local c = rgba_cache[key]
    if c then return c[1], c[2], c[3], c[4] end
    local r = (floor(hex / 65536) % 256) / 255.0
    local g = (floor(hex / 256)   % 256) / 255.0
    local b = (          hex       % 256) / 255.0
    c = {r, g, b, alpha}
    rgba_cache[key] = c
    return r, g, b, alpha
end

local function draw_ring(cr, x, y, radius, thickness, val, max_val, color_hex)
    if max_val <= 0 then return end
    val = min(max(val, 0), max_val)
    local r, g, b, a = hex_to_rgba(color_hex, bg_alpha)
    cairo_set_line_width(cr, thickness)
    cairo_arc(cr, x, y, radius, angle_0, angle_f)
    cairo_set_source_rgba(cr, r, g, b, a); cairo_stroke(cr)
    local end_angle = angle_0 + (max_arc * (val / max_val))
    cairo_arc(cr, x, y, radius, angle_0, end_angle)
    cairo_set_source_rgba(cr, r, g, b, fg_alpha); cairo_stroke(cr)
end

local function draw_smooth_curve(cr, data, x, y, l, h, nchart, direction, max_val)
    local _chart, step, mult = (nchart + 1) % max_history_size, l / max_history_size_minus_1, (direction == "down") and 1 or -1
    for i = 0, max_history_size_minus_1 do
        local v = data[_chart] or 0.1
        local px, py = x + step * i, y + (floor((v / max_val) * h) * mult)
        if i == 0 then cairo_move_to(cr, px, py) else cairo_line_to(cr, px, py) end
        _chart = (_chart + 1) % max_history_size
    end
end

local function draw_peaks(cr, data, x, y, l, h, nchart, dir, r, g, b, max_v)
    local tr, tg, tb = hex_to_rgba(raw_colors.TEXT, 1)
    local _c, step, mult, txt_off, last_xp = (nchart + 1) % max_history_size, l / max_history_size_minus_1, (dir == "up") and -1 or 1, (dir == "up") and -4 or 9, -50
    for i = 2, max_history_size_minus_1 do
        local idx = (_c + i) % max_history_size
        local v = data[idx] or 0.1
        if v / max_v > 0.85 then
            local xp = x + step * i
            if xp > last_xp + 40 then
                local py = y + (floor((v / max_v) * h) * mult) + (mult * 6)
                cairo_arc(cr, xp, py, 2.5, 0, two_pi); cairo_set_source_rgba(cr, tr, tg, tb, 0.5); cairo_fill(cr)
                cairo_arc(cr, xp, py, 1.2, 0, two_pi); cairo_set_source_rgba(cr, r, g, b, 1); cairo_fill(cr)
                local s = v >= 1024 and format("%.1fM", v / 1024) or format("%.0fK", v)
                cairo_set_source_rgba(cr, tr, tg, tb, 1); cairo_move_to(cr, xp - 8, py + txt_off); cairo_show_text(cr, s)
                last_xp = xp
            end
        end
    end
end

local function draw_network_chart(cr, up, down, nchart, x, y, l, h)
    local mu, md = 1, 1
    for i = 0, max_history_size_minus_1 do
        if up[i] > mu then mu = up[i] end
        if down[i] > md then md = down[i] end
    end
    local ru, gu, bu = hex_to_rgba(raw_colors.NET_UP, 1); local rd, gd, bd = hex_to_rgba(raw_colors.NET_DOWN, 1)
    cairo_set_line_width(cr, 1.2)
    cairo_select_font_face(cr, "sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, 6)

    local pat_u = cairo_pattern_create_linear(x, y-h, x, y)
    if pat_u then
        cairo_pattern_add_color_stop_rgba(pat_u, 0, ru, gu, bu, 0.3); cairo_pattern_add_color_stop_rgba(pat_u, 1, ru, gu, bu, 0.8)
        cairo_new_path(cr); draw_smooth_curve(cr, up, x, y, l, h, nchart, "up", mu); cairo_line_to(cr, x+l, y); cairo_line_to(cr, x, y)
        cairo_set_source(cr, pat_u); cairo_fill_preserve(cr); cairo_set_source_rgba(cr, ru, gu, bu, 1.0); cairo_stroke(cr)
        cairo_pattern_destroy(pat_u)
    end

    local pat_d = cairo_pattern_create_linear(x, y, x, y+h)
    if pat_d then
        cairo_pattern_add_color_stop_rgba(pat_d, 0, rd, gd, bd, 0.8); cairo_pattern_add_color_stop_rgba(pat_d, 1, rd, gd, bd, 0.3)
        cairo_new_path(cr); draw_smooth_curve(cr, down, x, y, l, h, nchart, "down", md); cairo_line_to(cr, x+l, y); cairo_line_to(cr, x, y)
        cairo_set_source(cr, pat_d); cairo_fill_preserve(cr); cairo_set_source_rgba(cr, rd, gd, bd, 1.0); cairo_stroke(cr)
        cairo_pattern_destroy(pat_d)
    end
    draw_peaks(cr, up, x, y, l, h, nchart, "up", ru, gu, bu, mu); draw_peaks(cr, down, x, y, l, h, nchart, "down", rd, gd, bd, md)
end

function conky_get_music_info(info_type)
    local now = _frame_now > 0 and _frame_now or os.time()
    if now - state.last_read_tick >= 1 then
        state.last_read_tick = now
        local content = read_file(music_cache_file)
        if content and content ~= "" then
            local a, t, s = content:match("([^|]*)|([^|]*)|([^|]*)")
            state.cached_music.artist, state.cached_music.title, state.cached_music.status = a or "", t or "", s or ""
        else state.cached_music.artist, state.cached_music.title, state.cached_music.status = "", "", "None" end
        local p_data = read_file(music_pos_file) or "0:00|0|1"
        local pos, r_pos, r_len = p_data:match("([^|]*)|([^|]*)|([^|]*)")
        state.cached_music.position = pos or "0:00"
        state.cached_music.pos_raw = safe_number(r_pos, 0) / 1000000
        state.cached_music.len_raw = safe_number(r_len, 0) / 1000000
    end
    local m = state.cached_music
    if info_type == "artist" or info_type == "title" then
        local a, t = m.artist, m.title
        if info_type == "artist" then
            if a == "" then return truncate((t ~= "") and t or "¯\\_(•.°)_/¯", 14, "...") end
            return truncate(a, 14)
        else
            if t == "" then return truncate(a, 22) end
            return truncate(t, 22)
        end
    end
    if info_type == "status" then return m.status or "None" end
    if info_type == "position" then
        local s = m.status
        return (s == "None" or s == "" or s == "Stopped") and "" or (m.position or "0:00")
    end
    return ""
end

local function clear_cover()
    _release_surf(state.cached_cover_surf)
    state.cached_cover_surf = nil
    state.last_song_id = ""
end

local function draw_cover(cr, x, y, size, now)
    local m = state.cached_music
    if m.status == "None" or m.status == "" or m.status == "Stopped" then
        if state.cached_cover_surf or state.last_song_id ~= "" then clear_cover() end
        return
    end
    local cur_id = m.artist .. m.title
    if cur_id == "" then clear_cover(); return end
    if cur_id ~= state.last_song_id then
        _release_surf(state.cached_cover_surf)
        state.cached_cover_surf = nil
        state.last_cover_fail = 0
        state.last_song_id = cur_id
    end
    if not state.cached_cover_surf and (now - state.last_cover_fail) >= 5 then
        local new_surf = cairo_image_surface_create_from_png("/dev/shm/cover.png")
        if cairo_surface_status(new_surf) == CAIRO_STATUS_SUCCESS then
            state.cached_cover_surf = new_surf
            state.cover_w, state.cover_h = cairo_image_surface_get_width(new_surf), cairo_image_surface_get_height(new_surf)
        else
            _release_surf(new_surf)
            state.last_cover_fail = now
        end
    end
    if state.cached_cover_surf then
        if cairo_surface_status(state.cached_cover_surf) ~= CAIRO_STATUS_SUCCESS then
            _release_surf(state.cached_cover_surf)
            state.cached_cover_surf = nil
            state.last_cover_fail = now
            return
        end
        local cover_max = max(state.cover_w, state.cover_h)
        if cover_max == 0 then
            _release_surf(state.cached_cover_surf)
            state.cached_cover_surf = nil
            state.last_cover_fail = now
            return
        end
        local scale = size / cover_max
        cairo_save(cr)
        cairo_arc(cr, x + size/2, y + size/2, size/2, 0, two_pi); cairo_clip(cr)
        cairo_scale(cr, scale, scale)
        cairo_set_source_surface(cr, state.cached_cover_surf, x/scale + (size/scale - state.cover_w) / 2, y/scale + (size/scale - state.cover_h) / 2)
        cairo_paint_with_alpha(cr, 0.8)
        cairo_restore(cr)
        local r, g, b = hex_to_rgba(raw_colors.PROGRESS, 1)
        local progress = (m.len_raw > 0) and (m.pos_raw / m.len_raw) or 0
        if progress > 1 then progress = 1 end
        cairo_set_line_width(cr, 2.5)
        cairo_set_source_rgba(cr, r, g, b, bg_alpha)
        cairo_arc(cr, x+size/2, y+size/2, size/2, 0, two_pi); cairo_stroke(cr)
        cairo_set_source_rgba(cr, r, g, b, fg_alpha)
        cairo_arc(cr, x+size/2, y+size/2, size/2, -pi/2, -pi/2 + (two_pi * progress)); cairo_stroke(cr)
    end
end

local function draw_bg_image(cr, now)
    local bg_name = get_config_val("BACKGROUND", "dark.png", now)
    if bg_name ~= state.last_bg_name then
        _release_surf(state.bg_surf)
        state.bg_surf = nil
        state.last_bg_name = bg_name
    end
    if not state.bg_surf then
        local img_path = base_dir .. "/res/" .. bg_name
        state.bg_surf = cairo_image_surface_create_from_png(img_path)
        if cairo_surface_status(state.bg_surf) ~= CAIRO_STATUS_SUCCESS then
            _release_surf(state.bg_surf)
            state.bg_surf = nil
        else
            state.bg_w = cairo_image_surface_get_width(state.bg_surf)
            state.bg_h = cairo_image_surface_get_height(state.bg_surf)
        end
    end
    if state.bg_surf then
        if state.bg_w == 0 or state.bg_h == 0 then return end
        cairo_save(cr)
        local target_w, target_h = 370, 775
        local x, y = 10, 40
        cairo_scale(cr, target_w / state.bg_w, target_h / state.bg_h)
        cairo_set_source_surface(cr, state.bg_surf, x / (target_w / state.bg_w), y / (target_h / state.bg_h))
        cairo_paint(cr)
        cairo_restore(cr)
    end
end

function conky_main()
    if conky_window == nil then return end
    local now = os.time()
    _frame_now = now
    load_colors_from_config(now)

    if not state.iface then
        local parsed_iface = conky_parse("${template0}") or ""
        state.iface = (parsed_iface ~= "") and parsed_iface or "lo"
        state.parse_str_base = format('${upspeedf %s}|${downspeedf %s}|${acpitemp}|${fs_used_perc /}|${cpu cpu0}|${memperc}', state.iface, state.iface)
    end

    if now > state.last_update then
        state.nchart = (state.nchart + 1) % max_history_size
        if state.parse_str_base and not state.last_parse_str then
            local t = { state.parse_str_base }
            for i = 1, 4 do
                local p = state.disk_paths[i]
                insert(t, (p and p ~= "/dev/null") and format('|${fs_used_perc %s}', p) or '|0')
            end
            state.last_parse_str = concat(t)
        end
        if state.last_parse_str then
            local parsed = conky_parse(state.last_parse_str)
            if parsed then
                local rt = state.results_table
                for i = #rt, 1, -1 do rt[i] = nil end
                local i = 1
                for v in (parsed .. "|"):gmatch("(.-)|") do rt[i] = v; i = i + 1 end
                state.up[state.nchart], state.down[state.nchart] = safe_number(rt[1], 0.1), safe_number(rt[2], 0.1)
                state.cpu_temp, state.root_perc, state.cpu_perc, state.mem_perc = safe_number(rt[3], 0), safe_number(rt[4], 0), safe_number(rt[5], 0), safe_number(rt[6], 0)
                for j = 1, 4 do state.disk_percs[j] = safe_number(rt[6+j], 0) end
            end
        end
        state.last_update = now
    end

    if state.disk_update_counter == 0 then
        os.execute('timeout 2 ' .. base_dir .. '/scripts/get_mounts.sh > /dev/shm/mimod_mounts.txt 2>/dev/null &')
    end
    if state.disk_update_counter == 2 then
        local f = io.open('/dev/shm/mimod_mounts.txt', 'r')
        if f then
            local res = {}
            for line in f:lines() do insert(res, line) end
            f:close()
            local paths_changed = false
            for j = 1, 4 do
                local np = res[j] or "/dev/null"
                local nn = res[j+4] or "N/A"
                if state.disk_paths[j] ~= np then paths_changed = true end
                state.disk_paths[j], state.disk_names[j] = np, nn
            end
            if paths_changed then state.last_parse_str = nil end
        end
    end
    state.disk_update_counter = (state.disk_update_counter + 1) % 60

    local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable, conky_window.visual, conky_window.width, conky_window.height)
    if cs then
        local cr = cairo_create(cs)
        if cr then
            local status, err = pcall(function()
                cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
                draw_bg_image(cr, now)
                draw_ring(cr, 64, 298, 30, 10, state.cpu_perc, 100, raw_colors.CPU)
                draw_ring(cr, 148, 298, 30, 10, state.mem_perc, 100, raw_colors.MEM)
                draw_ring(cr, 233, 298, 30, 10, state.root_perc, 100, raw_colors.DISK)
                local temp_pct = min(floor(state.cpu_temp / 120 * 100 + 0.5), 100)
                draw_ring(cr, 316, 298, 30, 10, temp_pct, 100, raw_colors.TEMP)
                for i, pt in ipairs(DISK_PTS) do
                    if state.disk_paths[i] ~= "/dev/null" then draw_ring(cr, pt[1], pt[2], 20, 6, state.disk_percs[i], 100, raw_colors.DISK) end
                end
                draw_network_chart(cr, state.up, state.down, state.nchart, 220, 147, 130, 30)
                if get_config_val("COVER_ART", "true", now) ~= "false" then
                    draw_cover(cr, 280, 415, 75, now)
                end
            end)
            if not status then print("Conky Lua Error: " .. tostring(err)) end
            cairo_destroy(cr)
        end
        cairo_surface_finish(cs); cairo_surface_destroy(cs)
    end
end

function conky_get_weather_data(req)
    local now = _frame_now > 0 and _frame_now or os.time()
    if now - state.last_weather_check > 30 or not state.cached_weather then
        local c = read_file(weather_cache_file)
        if c then
            state.cached_weather = {
                icon = c:match('"icon":"([^"]+)"'), temp = c:match('"temp":([%d%.%-]+)'),
                name = c:match('"name":"([^"]+)"'), desc = c:match('"description":"([^"]+)"'),
                wind = c:match('"speed":([%d%.]+)'), hum  = c:match('"humidity":(%d+)')
            }
            state.last_weather_check = now
        end
    end
    local d = state.cached_weather
    if not d then return "..." end
    if req == "temp"     then return tostring(floor(safe_number(d.temp, 0) + 0.5))
    elseif req == "name" then return d.name and d.name:upper() or "..."
    elseif req == "desc" then return d.desc or "..."
    elseif req == "wind" then return d.wind or "..."
    elseif req == "humidity" then return d.hum or "..." end
    return "..."
end

function conky_weather_icon()
    local d = state.cached_weather
    return WEATHER_ICONS[(d and d.icon) or "01d"] or ""
end

local function get_unit_setting()
    local now = _frame_now > 0 and _frame_now or os.time()
    if not state.unit_cache or now - state.unit_cache_time >= state.config_cache_ttl then
        state.unit_cache = get_config_val("UNIT", "metric", now)
        state.unit_cache_time = now
    end
    return state.unit_cache
end

function conky_weather_unit(req)
    local u = get_unit_setting()
    return (req == "wind") and (u == "imperial" and "mph" or "m/s") or (u == "imperial" and "°F" or "°C")
end
function conky_playerctl_status() return PLAYER_ICONS[conky_get_music_info("status")] or "" end
function conky_playerctl_status_text() local s = conky_get_music_info("status"); return (s == "None" or s == "") and "No Player" or s end
function conky_disk_name(idx) return state.disk_names[tonumber(idx)] or "N/A" end
function conky_disk_perc(idx) return state.disk_percs[tonumber(idx)] or 0 end

function conky_cpu_temp()
    local now = _frame_now > 0 and _frame_now or os.time()
    if not state.cpu_unit_cache or now - state.cpu_unit_cache_time >= state.config_cache_ttl then
        local override = get_config_val("TEMP_UNIT_OVERRIDE", "", now)
        state.cpu_unit_cache = (override ~= "") and ((override:upper() == "F") and "imperial" or "metric") or get_unit_setting()
        state.cpu_unit_cache_time = now
    end
    local val  = state.cpu_temp
    local unit = (state.cpu_unit_cache == "imperial") and "°F" or "°C"
    return (unit == "°F" and floor((val * 9 / 5) + 32) or floor(val)) .. unit
end

function conky_get_ssid(fallback)
    local now = _frame_now > 0 and _frame_now or os.time()
    if state.iface and now - state.last_ssid_check > 60 then
        if state.iface:sub(1, 1) == 'w' then
            local sn = conky_parse('${wireless_essid ' .. fallback .. '}') or ""
            state.last_ssid = (sn ~= "" and sn ~= "off" and sn ~= "N/A") and truncate(sn, 10) or fallback
        else
            state.last_ssid = fallback
        end
        state.last_ssid_check = now
    end
    return (state.last_ssid ~= "") and state.last_ssid or (fallback or "N/A")
end

function conky_shutdown()
    _release_surf(state.bg_surf);          state.bg_surf          = nil
    _release_surf(state.cached_cover_surf); state.cached_cover_surf = nil
    rgba_cache = {}
    state.results_table = {}
    state.config_cache_content = nil
    state.cached_weather = nil
    collectgarbage("collect")
end
