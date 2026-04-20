require 'cairo'
require 'cairo_xlib'
collectgarbage("setpause",110)
collectgarbage("setstepmul",200)
local floor,pi,max,min=math.floor,math.pi,math.max,math.min
local tointeger=math.tointeger or math.floor
local two_pi=2.0*pi
local tonumber,tostring=tonumber,tostring
local format=string.format
local insert,concat=table.insert,table.concat
local ipairs=ipairs
local CAIRO_STATUS_SUCCESS=0
local CAIRO_FONT_SLANT_NORMAL=0
local CAIRO_FONT_WEIGHT_NORMAL=0
local CAIRO_LINE_CAP_ROUND=1
local color_defaults={CPU=0x268BA0,MEM=0x60C9C5,TEMP=0xA9E2C2,DISK=0x63EDD0,NET_UP=0xA9E2C2,NET_DOWN=0x268BA0,TEXT=0xEEEEEE,PROGRESS=0xe0e077}
local raw_colors={CPU=color_defaults.CPU,MEM=color_defaults.MEM,TEMP=color_defaults.TEMP,DISK=color_defaults.DISK,NET_UP=color_defaults.NET_UP,NET_DOWN=color_defaults.NET_DOWN,TEXT=color_defaults.TEXT,PROGRESS=color_defaults.PROGRESS}
local bg_alpha,fg_alpha=0.3,1.0
local max_history_size=81
local max_history_size_m1=80
local angle_0=-150.0*(two_pi/360.0)-pi/2.0
local angle_f=150.0*(two_pi/360.0)-pi/2.0
local max_arc=angle_f-angle_0
local home_dir=os.getenv("HOME")
local base_dir=home_dir.."/.config/conky/Mimod"
local _playerctl_cmd='bash "'..base_dir..'/scripts/playerctl.sh" >/dev/null 2>&1 &'
local _weather_cmd='bash "'..base_dir..'/scripts/weather.sh" >/dev/null 2>&1 &'
local _last_playerctl_run,_last_weather_run=0,0
local mount_cmd='timeout 2 '..base_dir..'/scripts/get_mounts.sh > /dev/shm/mimod_mounts.tmp 2>/dev/null && mv -f /dev/shm/mimod_mounts.tmp /dev/shm/mimod_mounts.txt 2>/dev/null &'
local TEMP_SCALE=100.0/120.0
local music_cache_file="/dev/shm/current_song_music_script.txt"
local music_pos_file="/dev/shm/music_position"
local weather_cache_file=home_dir.."/.cache/weather.json"
local config_file=base_dir.."/scripts/config"
local DISK_PTS={{56,443},{137,443},{56,523},{137,523}}
local WEATHER_ICONS={["01d"]="",["01n"]="",["02d"]="",["02n"]="",["03d"]="",["03n"]="",["04d"]="",["04n"]="",["09d"]="",["09n"]="",["10d"]="",["10n"]="",["11d"]="",["11n"]="",["13d"]="",["13n"]="",["50d"]="",["50n"]=""}
local PLAYER_ICONS={["Stopped"]="",["Playing"]="",["Paused"]="",["Unknown"]="",["None"]=""}
local _frame_now=0
local state={up={},down={},nchart=0,last_update=0,disk_update_counter=0,disk_paths={"/dev/null","/dev/null","/dev/null","/dev/null"},disk_names={"N/A","N/A","N/A","N/A"},disk_percs={0,0,0,0},cpu_temp=0.0,cpu_perc=0,mem_perc=0,root_perc=0,cached_weather=nil,last_weather_check=0,cached_music={artist="",title="",status="",position="",pos_raw=0.0,len_raw=0.0},last_read_tick=0,cached_cover_surf=nil,last_song_id="",last_cover_fail=0,cover_retry_interval=15,cover_retry_count=0,cover_w=1,cover_h=1,last_ssid="",last_ssid_check=0,results_table={},config_cache_content=nil,config_cache_time=0,config_cache_ttl=60,parse_str_base=nil,last_parse_str=nil,bg_surf=nil,bg_w=0,bg_h=0,bg_sx=1.0,bg_sy=1.0,bg_ox=0.0,bg_oy=0.0,iface=nil,unit_cache=nil,unit_cache_time=0,last_colors_check=0,last_bg_name="",cached_bg_name="dark.png",cpu_unit_cache=nil,cpu_unit_cache_time=0,thermal_zone_path=nil,thermal_zone_check_time=0,acpi_works=nil,cover_art_enabled=true}
for i=0,max_history_size_m1 do state.up[i],state.down[i]=0.1,0.1 end
local rgba_cache={}
local rgba_cache_count=0
local RGBA_CACHE_MAX=128
local pattern_cache={up=nil,down=nil,h=0,col_up=0,col_down=0}
local function _release_surf(s)
if s==nil then return end
pcall(cairo_surface_finish,s)
pcall(cairo_surface_destroy,s)
end
local function _surf_valid(s)
if s==nil then return false end
local ok,status=pcall(cairo_surface_status,s)
return ok and status==CAIRO_STATUS_SUCCESS
end
local function _clear_patterns()
if pattern_cache.up then cairo_pattern_destroy(pattern_cache.up);pattern_cache.up=nil end
if pattern_cache.down then cairo_pattern_destroy(pattern_cache.down);pattern_cache.down=nil end
pattern_cache.h,pattern_cache.col_up,pattern_cache.col_down=0,0,0
end
local function read_file(path)
local f=io.open(path,"r")
if not f then return nil end
local content=f:read("*a")
f:close()
return content
end
local function read_config_cached(now)
if state.config_cache_content and (now-state.config_cache_time)<state.config_cache_ttl then return state.config_cache_content end
local content=read_file(config_file)
if content then state.config_cache_content=content;state.config_cache_time=now end
return state.config_cache_content or ""
end
local function get_config_val(key,default,now)
local content=read_config_cached(now or os.time())
if not content or content=="" then return default end
return content:match(key..'=["\']?([^"\'\n]+)["\']?') or default
end
local function truncate(s,n,suffix)
if not s then return "" end
suffix=suffix or ".."
local chars,pos=0,1
while pos<=#s do
local b=s:byte(pos)
chars=chars+1
if chars>n then return s:sub(1,pos-1)..suffix end
pos=pos+((b>=240) and 4 or (b>=224) and 3 or (b>=192) and 2 or 1)
end
return s
end
local function safe_number(v,default)
local n=tonumber(v)
return (n==nil or n~=n) and (default or 0) or n
end
local function parse_color(s,fallback)
if not s or s=="" then return fallback end
local hex=s:match("^#?(%x+)$")
return hex and tonumber(hex,16) or fallback
end
local function load_colors_from_config(now)
if now-state.last_colors_check<state.config_cache_ttl then return end
state.last_colors_check=now
local n_cpu=parse_color(get_config_val("COLOR_CPU","",now),color_defaults.CPU)
local n_mem=parse_color(get_config_val("COLOR_MEM","",now),color_defaults.MEM)
local n_temp=parse_color(get_config_val("COLOR_TEMP","",now),color_defaults.TEMP)
local n_disk=parse_color(get_config_val("COLOR_DISK","",now),color_defaults.DISK)
local n_nu=parse_color(get_config_val("COLOR_NET_UP","",now),color_defaults.NET_UP)
local n_nd=parse_color(get_config_val("COLOR_NET_DOWN","",now),color_defaults.NET_DOWN)
local n_txt=parse_color(get_config_val("COLOR_TEXT","",now),color_defaults.TEXT)
local n_prg=parse_color(get_config_val("COLOR_PROGRESS","",now),color_defaults.PROGRESS)
if n_cpu~=raw_colors.CPU or n_mem~=raw_colors.MEM or n_temp~=raw_colors.TEMP or n_disk~=raw_colors.DISK or n_nu~=raw_colors.NET_UP or n_nd~=raw_colors.NET_DOWN or n_txt~=raw_colors.TEXT or n_prg~=raw_colors.PROGRESS then
rgba_cache={}
rgba_cache_count=0
_clear_patterns()
end
raw_colors.CPU=n_cpu;raw_colors.MEM=n_mem;raw_colors.TEMP=n_temp;raw_colors.DISK=n_disk
raw_colors.NET_UP=n_nu;raw_colors.NET_DOWN=n_nd;raw_colors.TEXT=n_txt;raw_colors.PROGRESS=n_prg
state.cover_art_enabled=(get_config_val("COVER_ART","true",now)~="false")
state.cached_bg_name=get_config_val("BACKGROUND","dark.png",now)
end
local function hex_to_rgba(hex,alpha)
local ihex=tointeger(hex) or 0
local ialpha=floor(alpha*1023.0+0.5)
local key=ihex*1024+ialpha
local c=rgba_cache[key]
if c then return c[1],c[2],c[3],c[4] end
if rgba_cache_count>=RGBA_CACHE_MAX then rgba_cache={};rgba_cache_count=0 end
local r=floor(ihex/65536)%256/255.0
local g=floor(ihex/256)%256/255.0
local b=ihex%256/255.0
c={r,g,b,alpha}
rgba_cache[key]=c
rgba_cache_count=rgba_cache_count+1
return r,g,b,alpha
end
local function draw_ring(cr,x,y,radius,thickness,val,max_val,color_hex)
if max_val<=0 then return end
val=min(max(val,0.0),max_val+0.0)
local r,g,b=hex_to_rgba(color_hex,bg_alpha)
cairo_set_line_width(cr,thickness)
cairo_arc(cr,x,y,radius,angle_0,angle_f)
cairo_set_source_rgba(cr,r,g,b,bg_alpha)
cairo_stroke(cr)
cairo_arc(cr,x,y,radius,angle_0,angle_0+max_arc*(val/max_val))
cairo_set_source_rgba(cr,r,g,b,fg_alpha)
cairo_stroke(cr)
end
local function draw_smooth_curve(cr,data,x,y,l,h,nchart,direction,max_val,step)
local _chart=(nchart+1)%max_history_size
local mult=(direction=="down" and 1.0 or -1.0)
local scale=h/max_val
local px=x+0.0
for i=0,max_history_size_m1 do
local py=y+floor((data[_chart] or 0.1)*scale)*mult
if i==0 then cairo_move_to(cr,px,py) else cairo_line_to(cr,px,py) end
_chart=(_chart+1)%max_history_size
px=px+step
end
end
local function draw_peaks(cr,data,x,y,l,h,nchart,dir,r,g,b,max_v,step)
local tr,tg,tb=hex_to_rgba(raw_colors.TEXT,1.0)
local _c=(nchart+1)%max_history_size
local mult=(dir=="up" and -1.0 or 1.0)
local txt_off=(dir=="up" and -4.0 or 9.0)
local last_xp=-50.0
local scale=h/max_v
local thresh=0.85*max_v
for i=2,max_history_size_m1 do
local v=data[(_c+i)%max_history_size] or 0.1
if v>thresh then
local xp=x+step*i
if xp>last_xp+40.0 then
local py=y+floor(v*scale)*mult+(mult*6.0)
cairo_arc(cr,xp,py,2.5,0,two_pi)
cairo_set_source_rgba(cr,tr,tg,tb,0.5)
cairo_fill(cr)
cairo_arc(cr,xp,py,1.2,0,two_pi)
cairo_set_source_rgba(cr,r,g,b,1.0)
cairo_fill(cr)
cairo_set_source_rgba(cr,tr,tg,tb,1.0)
local text_str=(v>=1024.0 and format("%.1fM",v/1024.0) or format("%.0fK",v))
local text_width=#text_str*3.4
cairo_move_to(cr,xp-(text_width/2.0),py+txt_off)
cairo_show_text(cr,text_str)
last_xp=xp
end
end
end
end
local function draw_network_chart(cr,up,down,nchart,x,y,l,h)
local mu,md=1.0,1.0
for i=0,max_history_size_m1 do mu=max(mu,up[i] or 0.1);md=max(md,down[i] or 0.1) end
local step=l/max_history_size_m1
local ru,gu,bu=hex_to_rgba(raw_colors.NET_UP,1.0)
local rd,gd,bd=hex_to_rgba(raw_colors.NET_DOWN,1.0)
cairo_set_line_width(cr,1.2)
cairo_select_font_face(cr,"sans",CAIRO_FONT_SLANT_NORMAL,CAIRO_FONT_WEIGHT_NORMAL)
cairo_set_font_size(cr,6)
local need_rebuild=(pattern_cache.h~=h or pattern_cache.col_up~=raw_colors.NET_UP or pattern_cache.col_down~=raw_colors.NET_DOWN or not pattern_cache.up or not pattern_cache.down)
if need_rebuild then
_clear_patterns()
pattern_cache.col_up=raw_colors.NET_UP
pattern_cache.col_down=raw_colors.NET_DOWN
pattern_cache.h=h
pattern_cache.up=cairo_pattern_create_linear(x,y-h,x,y)
if pattern_cache.up then
cairo_pattern_add_color_stop_rgba(pattern_cache.up,0,ru,gu,bu,0.3)
cairo_pattern_add_color_stop_rgba(pattern_cache.up,1,ru,gu,bu,0.8)
end
pattern_cache.down=cairo_pattern_create_linear(x,y,x,y+h)
if pattern_cache.down then
cairo_pattern_add_color_stop_rgba(pattern_cache.down,0,rd,gd,bd,0.8)
cairo_pattern_add_color_stop_rgba(pattern_cache.down,1,rd,gd,bd,0.3)
end
end
if pattern_cache.up then
cairo_new_path(cr)
draw_smooth_curve(cr,up,x,y,l,h,nchart,"up",mu,step)
cairo_line_to(cr,x+l,y)
cairo_line_to(cr,x,y)
cairo_set_source(cr,pattern_cache.up)
cairo_fill_preserve(cr)
cairo_set_source_rgba(cr,ru,gu,bu,1.0)
cairo_stroke(cr)
end
if pattern_cache.down then
cairo_new_path(cr)
draw_smooth_curve(cr,down,x,y,l,h,nchart,"down",md,step)
cairo_line_to(cr,x+l,y)
cairo_line_to(cr,x,y)
cairo_set_source(cr,pattern_cache.down)
cairo_fill_preserve(cr)
cairo_set_source_rgba(cr,rd,gd,bd,1.0)
cairo_stroke(cr)
end
draw_peaks(cr,up,x,y,l,h,nchart,"up",ru,gu,bu,mu,step)
draw_peaks(cr,down,x,y,l,h,nchart,"down",rd,gd,bd,md,step)
end
function conky_get_music_info(info_type)
local now=_frame_now>0 and _frame_now or os.time()
if now-state.last_read_tick>=1 then
state.last_read_tick=now
local content=read_file(music_cache_file)
if content and content~="" then
local a,t,s=content:match("([^|]*)|([^|]*)|([^|]*)")
state.cached_music.artist=(a and a:match("^%s*(.-)%s*$") or "")
state.cached_music.title=(t and t:match("^%s*(.-)%s*$") or "")
state.cached_music.status=(s and s:match("^%s*(.-)%s*$") or "")
else
state.cached_music.artist=""
state.cached_music.title=""
state.cached_music.status="None"
end
local p_data=read_file(music_pos_file) or "0:00|0|1"
local pos,r_pos,r_len=p_data:match("([^|]*)|([^|]*)|([^|]*)")
state.cached_music.position=(pos or "0:00")
state.cached_music.pos_raw=(safe_number(r_pos,0)/1000000.0)
state.cached_music.len_raw=(safe_number(r_len,0)/1000000.0)
end
local m=state.cached_music
if info_type=="artist" then return truncate(m.artist=="" and (m.title~="" and m.title or "¯\\_(•.°)_/¯") or m.artist,14)
elseif info_type=="title" then return truncate(m.title=="" and m.artist or m.title,22)
elseif info_type=="status" then return m.status or "None"
elseif info_type=="position" then
local s=m.status
return (s=="None" or s=="" or s=="Stopped") and "" or (m.position or "0:00")
end
return ""
end
function conky_main()
if conky_window==nil or conky_window.width==0 or conky_window.height==0 then return end
local now=os.time()
_frame_now=now
load_colors_from_config(now)
if now-_last_playerctl_run>=1 then _last_playerctl_run=now;os.execute(_playerctl_cmd) end
if now-_last_weather_run>=600 then _last_weather_run=now;os.execute(_weather_cmd) end
if not state.iface then
local ok,pi_val=pcall(conky_parse,"${template0}")
state.iface=(ok and pi_val and pi_val~="") and pi_val or "lo"
state.parse_str_base=format('${upspeedf %s}|${downspeedf %s}|${acpitemp}|${fs_used_perc /}|${cpu cpu0}|${memperc}',state.iface,state.iface)
end
if state.parse_str_base and not state.last_parse_str then
local t={state.parse_str_base}
for i=1,4 do
local p=state.disk_paths[i]
insert(t,(p and p~="/dev/null") and format('|${fs_used_perc %s}',p) or '|0')
end
state.last_parse_str=concat(t)
end
if now>state.last_update then
state.nchart=(state.nchart+1)%max_history_size
if state.last_parse_str then
local ok,parsed=pcall(conky_parse,state.last_parse_str)
if ok and parsed and parsed~="" then
local rt=state.results_table
local idx=1
for v in (parsed.."|"):gmatch("(.-)|") do rt[idx]=v;idx=idx+1 end
for i=idx,10 do rt[i]=nil end
state.up[state.nchart]=safe_number(rt[1],0.1)
state.down[state.nchart]=safe_number(rt[2],0.1)
state.root_perc=safe_number(rt[4],0)
state.cpu_perc=safe_number(rt[5],0)
state.mem_perc=safe_number(rt[6],0)
for j=1,4 do state.disk_percs[j]=safe_number(rt[6+j],0) end
local raw_temp=safe_number(rt[3],0)
if raw_temp>0 then
state.cpu_temp=raw_temp+0.0
state.acpi_works=true
else
if state.acpi_works==nil then
state.acpi_works=false
state.parse_str_base=format('${upspeedf %s}|${downspeedf %s}|0|${fs_used_perc /}|${cpu cpu0}|${memperc}',state.iface,state.iface)
state.last_parse_str=nil
end
if now-state.thermal_zone_check_time>=300 then
state.thermal_zone_check_time=now
local CPU_TYPES={"x86_pkg_temp","cpu-thermal","cpu_thermal","CPU"}
local pref,fb
for zi=0,15 do
local b="/sys/class/thermal/thermal_zone"..zi
local tf=io.open(b.."/temp","r")
if tf then
local v=tonumber(tf:read("*l"))
tf:close()
if v and v>=1000 and v<=150000 then
if not pref then
local tt=io.open(b.."/type","r")
if tt then
local z=tt:read("*l")
tt:close()
for _,ct in ipairs(CPU_TYPES) do
if z and z:lower():find(ct:lower(),1,true) then pref=b.."/temp";break end
end
end
end
fb=fb or (b.."/temp")
end
end
end
state.thermal_zone_path=pref or fb
end
if state.thermal_zone_path then
local tf=io.open(state.thermal_zone_path,"r")
if tf then
local v=tonumber(tf:read("*l"))
tf:close()
if v then state.cpu_temp=v/1000.0 end
end
end
end
end
end
state.last_update=now
end
if state.disk_update_counter==0 then os.execute(mount_cmd) end
if state.disk_update_counter==2 then
local f=io.open('/dev/shm/mimod_mounts.txt','r')
if f then
local res={}
for line in f:lines() do insert(res,line) end
f:close()
local chg=false
for j=1,4 do
local np=res[j] or "/dev/null"
local nn=res[j+4] or "N/A"
if state.disk_paths[j]~=np then chg=true end
state.disk_paths[j]=np;state.disk_names[j]=nn
end
if chg then state.last_parse_str=nil end
else
local any_valid=false
for j=1,4 do if state.disk_paths[j]~="/dev/null" then any_valid=true;break end end
if any_valid then
for j=1,4 do state.disk_paths[j]="/dev/null";state.disk_names[j]="N/A" end
state.last_parse_str=nil
end
end
end
state.disk_update_counter=(state.disk_update_counter+1)%60
local cs=cairo_xlib_surface_create(conky_window.display,conky_window.drawable,conky_window.visual,conky_window.width,conky_window.height)
if not _surf_valid(cs) then _release_surf(cs);return end
local cr=cairo_create(cs)
if cr then
local draw_ok,draw_err=pcall(function()
cairo_set_line_cap(cr,CAIRO_LINE_CAP_ROUND)
local bg_name=state.cached_bg_name or "dark.png"
if bg_name~=state.last_bg_name then
_release_surf(state.bg_surf)
state.bg_surf=nil
state.last_bg_name=bg_name
end
if not state.bg_surf then
local nb=cairo_image_surface_create_from_png(base_dir.."/res/"..bg_name)
if _surf_valid(nb) then
state.bg_surf=nb
state.bg_w=cairo_image_surface_get_width(nb)
state.bg_h=cairo_image_surface_get_height(nb)
state.bg_sx=370.0/state.bg_w
state.bg_sy=775.0/state.bg_h
state.bg_ox=10.0/state.bg_sx
state.bg_oy=40.0/state.bg_sy
else
_release_surf(nb)
end
end
if state.bg_surf then
cairo_save(cr)
cairo_scale(cr,state.bg_sx,state.bg_sy)
cairo_set_source_surface(cr,state.bg_surf,state.bg_ox,state.bg_oy)
cairo_paint(cr)
cairo_restore(cr)
end
draw_ring(cr,64,298,30,10,state.cpu_perc,100,raw_colors.CPU)
draw_ring(cr,148,298,30,10,state.mem_perc,100,raw_colors.MEM)
draw_ring(cr,233,298,30,10,state.root_perc,100,raw_colors.DISK)
draw_ring(cr,316,298,30,10,min(floor(state.cpu_temp*TEMP_SCALE+0.5),100),100,raw_colors.TEMP)
for i,pt in ipairs(DISK_PTS) do
if state.disk_paths[i]~="/dev/null" then draw_ring(cr,pt[1],pt[2],20,6,state.disk_percs[i],100,raw_colors.DISK) end
end
draw_network_chart(cr,state.up,state.down,state.nchart,220,147,130,30)
if state.cover_art_enabled then
local m=state.cached_music
local st=m.status
local cid=m.artist..m.title
if st=="None" or st=="" or st=="Stopped" or cid=="" then
if state.cached_cover_surf or state.last_song_id~="" then
_release_surf(state.cached_cover_surf)
state.cached_cover_surf=nil
state.last_song_id=""
end
else
if cid~=state.last_song_id then
_release_surf(state.cached_cover_surf)
state.cached_cover_surf=nil
state.last_cover_fail=0
state.cover_retry_interval=15
state.cover_retry_count=0
state.last_song_id=cid
end
if not state.cached_cover_surf and (now-state.last_cover_fail)>=state.cover_retry_interval then
local ns=cairo_image_surface_create_from_png("/dev/shm/cover.png")
if _surf_valid(ns) then
state.cached_cover_surf=ns
state.cover_w=cairo_image_surface_get_width(ns)
state.cover_h=cairo_image_surface_get_height(ns)
state.cover_retry_count=0
state.cover_retry_interval=15
else
_release_surf(ns)
state.cover_retry_count=(state.cover_retry_count or 0)+1
state.cover_retry_interval=min(15*(2^(state.cover_retry_count-1)),120)
state.last_cover_fail=now
end
end
if state.cached_cover_surf and _surf_valid(state.cached_cover_surf) then
local sz=75
local hf=sz*0.5
local sc=sz/max(state.cover_w,state.cover_h)
local cx,cy=280+hf,415+hf
cairo_save(cr)
cairo_arc(cr,cx,cy,hf,0,two_pi)
cairo_clip(cr)
cairo_scale(cr,sc,sc)
cairo_set_source_surface(cr,state.cached_cover_surf,cx/sc-state.cover_w*0.5,cy/sc-state.cover_h*0.5)
cairo_paint_with_alpha(cr,0.8)
cairo_restore(cr)
local r,g,b=hex_to_rgba(raw_colors.PROGRESS,1.0)
local pr=(m.len_raw>0.0) and min(m.pos_raw/m.len_raw,1.0) or 0.0
cairo_set_line_width(cr,2.5)
cairo_set_source_rgba(cr,r,g,b,bg_alpha)
cairo_arc(cr,cx,cy,hf,0,two_pi)
cairo_stroke(cr)
if pr>0.0 then
cairo_set_source_rgba(cr,r,g,b,fg_alpha)
cairo_arc(cr,cx,cy,hf,-pi/2.0,-pi/2.0+two_pi*pr)
cairo_stroke(cr)
end
end
end
end
end)
cairo_destroy(cr)
if not draw_ok then io.stderr:write("conky_main draw error: "..(draw_err or "unknown").."\n") end
end
_release_surf(cs)
end
function conky_get_weather_data(req)
local now=_frame_now>0 and _frame_now or os.time()
if now-state.last_weather_check>=30 or not state.cached_weather then
state.last_weather_check=now
local c=read_file(weather_cache_file)
if c then
local w=state.cached_weather or {}
w.icon=c:match('"icon":"([^"]+)"')
w.temp=c:match('"temp":([%d%.%-]+)')
w.name=c:match('"name":"([^"]+)"')
w.desc=c:match('"description":"([^"]+)"')
w.wind=c:match('"speed":([%d%.]+)')
w.hum=c:match('"humidity":(%d+)')
state.cached_weather=w
end
end
local d=state.cached_weather
if not d then return "..." end
if req=="temp" then return tostring(floor(safe_number(d.temp,0)+0.5))
elseif req=="name" then return d.name and d.name:upper() or "..."
elseif req=="desc" then return d.desc or "..."
elseif req=="wind" then return d.wind or "..."
elseif req=="humidity" then return d.hum or "..."
end
return "..."
end
function conky_weather_icon()
conky_get_weather_data("temp")
return WEATHER_ICONS[(state.cached_weather and state.cached_weather.icon) or "01d"] or ""
end
function conky_weather_unit(req)
local now=_frame_now>0 and _frame_now or os.time()
if not state.unit_cache or now-state.unit_cache_time>=state.config_cache_ttl then
state.unit_cache=get_config_val("UNIT","metric",now)
state.unit_cache_time=now
end
if req=="wind" then return state.unit_cache=="imperial" and "mph" or "m/s" end
return state.unit_cache=="imperial" and "°F" or "°C"
end
function conky_playerctl_status() return PLAYER_ICONS[conky_get_music_info("status")] or "" end
function conky_playerctl_status_text()
local s=conky_get_music_info("status")
return (s=="None" or s=="") and "No Player" or s
end
function conky_disk_name(idx) return state.disk_names[tonumber(idx)] or "N/A" end
function conky_disk_perc(idx) return state.disk_percs[tonumber(idx)] or 0 end
function conky_cpu_temp()
local now=_frame_now>0 and _frame_now or os.time()
if not state.cpu_unit_cache or now-state.cpu_unit_cache_time>=state.config_cache_ttl then
local o=get_config_val("TEMP_UNIT_OVERRIDE","",now)
state.cpu_unit_cache=(o~="" and (o:upper()=="F" and "imperial" or "metric") or (not state.unit_cache and get_config_val("UNIT","metric",now) or state.unit_cache))
state.cpu_unit_cache_time=now
end
local v=state.cpu_temp
local u=(state.cpu_unit_cache=="imperial" and "°F" or "°C")
return tostring(u=="°F" and floor(v*9.0/5.0+32.0) or floor(v))..u
end
function conky_get_ssid(fallback)
if not state.iface then return fallback or "N/A" end
local now=_frame_now>0 and _frame_now or os.time()
if now-state.last_ssid_check>=60 then
state.last_ssid_check=now
if state.iface:sub(1,1)=='w' then
local ok,sn=pcall(conky_parse,'${wireless_essid '..state.iface..'}')
local val=(ok and sn and type(sn)=="string" and sn~="" and sn~="off" and sn~="N/A") and truncate(sn,10) or nil
state.last_ssid=val or (fallback or "N/A")
else
state.last_ssid=fallback or "N/A"
end
end
return (state.last_ssid and state.last_ssid~="") and state.last_ssid or (fallback or "N/A")
end
function conky_shutdown()
_release_surf(state.bg_surf)
_release_surf(state.cached_cover_surf)
_clear_patterns()
state.bg_surf=nil
state.cached_cover_surf=nil
rgba_cache={}
rgba_cache_count=0
state.results_table={}
state.config_cache_content=nil
state.cached_weather=nil
state.thermal_zone_path=nil
state.thermal_zone_check_time=0
state.acpi_works=nil
state.config_cache_time=0
state.last_weather_check=0
state.last_read_tick=0
state.last_ssid_check=0
state.last_cover_fail=0
state.cover_retry_interval=15
state.cover_retry_count=0
state.last_update=0
state.disk_update_counter=0
state.nchart=0
state.last_song_id=""
state.last_ssid=""
state.last_bg_name=""
state.iface=nil
state.last_parse_str=nil
state.parse_str_base=nil
collectgarbage("collect")
end
