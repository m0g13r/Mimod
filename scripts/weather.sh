#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="$SCRIPT_DIR/config"
[[ ! -f "$CONFIG_FILE" ]] && touch "$CONFIG_FILE"
source "$CONFIG_FILE" 2>/dev/null || true
CACHE_FILE="$HOME/.cache/weather.json"
mkdir -p "${HOME}/.cache"
TEMP_FILE=""
_cleanup(){ [[ -n "${TEMP_FILE:-}" && -f "$TEMP_FILE" ]] && rm -f "$TEMP_FILE"; }
trap '_cleanup' EXIT
CACHE_EXPIRATION=600
UA=$(type -t get_random_ua >/dev/null 2>&1 && get_random_ua || printf "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36")
json_get(){
local data="$1" query="${2#.}"
if command -v jq &>/dev/null;then jq -r ".${query}//empty" <<<"$data" 2>/dev/null
else local key="${query##*.}";printf '%s' "$data"|sed 's/[:,{}]/\n/g'|grep -A1 "\"$key\""|grep -v "\"$key\""|sed 's/^[[:space:]]*//;s/[",]//g;s/[[:space:]]*$//'|head -n1;fi
}
_fetch(){
local u="$1" mode="${2:-}"
local -a extra_opts=()
[[ "$mode" == "geo" ]] && extra_opts+=("-4")
curl -s --fail "${extra_opts[@]}" --max-time 5 -H 'Referer: https://google.com' -H 'Accept-Language: en-US,en;q=0.9' -A "$UA" "$u" 2>/dev/null \
|| wget -qO- -T 5 --no-check-certificate --header='Referer: https://google.com' --header='Accept-Language: en-US,en;q=0.9' -U "$UA" "$u" 2>/dev/null \
|| true
}
update_config(){
local k="$1" v="$2" f="$CONFIG_FILE" tmp cur
[[ -z "$v" || ! -f "$f" ]] && return
cur=$(sed -n "s/^${k}=['\"]\\{0,1\\}\\([^'\"]*\\)['\"]\\{0,1\\}.*$/\\1/p" "$f"|head -n1||true)
[[ "$cur" == "$v" ]] && return
tmp=$(mktemp "${f}.XXXXXX") || return
if grep -q "^${k}=" "$f";then sed "s|^\\(${k}=\\).*$|\\1\"${v//|/\\|}\"|" "$f" >"$tmp"
else cat "$f" >"$tmp";printf '%s="%s"\n' "$k" "$v" >>"$tmp";fi
mv -f "$tmp" "$f" || rm -f "$tmp"
}
get_loc(){
local lat="" lon="" cc="" gcmd="" d id c l u
declare -A lm=([DE]="de" [AT]="de" [CH]="de" [LI]="de" [FR]="fr" [BE]="fr" [LU]="fr" [CA]="fr" [IT]="it" [SM]="it" [VA]="it" [ES]="es" [MX]="es" [AR]="es" [CO]="es" [CL]="es" [PE]="es" [PL]="pl" [CZ]="cz" [SK]="sk" [HU]="hu" [RO]="ro" [RU]="ru" [UA]="ru" [BY]="ru" [CN]="zh_cn" [TW]="zh_tw" [HK]="zh_tw" [JP]="ja" [KR]="kr" [BD]="bn" [IN]="hi" [TR]="tr" [PT]="pt" [BR]="pt" [NL]="nl" [SE]="sv" [NO]="no" [FI]="fi" [GR]="el" [EG]="ar" [SA]="ar" [IL]="he" [VN]="vi" [TH]="th" [ID]="id")
local p
for p in "/usr/libexec/geoclue-2.0/demos/where-am-i" "/usr/lib/geoclue-2.0/demos/where-am-i" "/usr/bin/where-am-i";do
[[ -x "$p" ]] && { gcmd="$p";break; }
done
if [[ -n "$gcmd" ]];then
if [[ -x "/usr/lib/geoclue-2.0/demos/agent" ]] && ! pgrep -xf "/usr/lib/geoclue-2.0/demos/agent" >/dev/null;then
"/usr/lib/geoclue-2.0/demos/agent" &>/dev/null &
fi
d=$(timeout 2s "$gcmd" --timeout=1 2>/dev/null||true)
if [[ -n "$d" ]];then
lat=$(sed -n 's/.*Latitude: \?\([-0-9.]\+\).*/\1/p' <<<"$d"||true)
lon=$(sed -n 's/.*Longitude: \?\([-0-9.]\+\).*/\1/p' <<<"$d"||true)
fi
fi
if [[ -z "$lat" ]];then
local -a provs=("https://ipapi.co/json|.latitude|.longitude|.country_code" "http://ip-api.com/json|.lat|.lon|.countryCode" "https://ipinfo.io/json|.loc|.country")
local u_p lp op cp lstr
for p in "${provs[@]}";do
IFS='|' read -r u_p lp op cp <<<"$p"
d=$(_fetch "$u_p" "geo")
[[ -z "$d" ]] && continue
if [[ "$lp" == ".loc" ]];then
lstr=$(json_get "$d" ".loc");cc=$(json_get "$d" ".country")
if [[ "$lstr" =~ ^([-0-9.]+),([-0-9.]+)$ ]];then lat="${BASH_REMATCH[1]}";lon="${BASH_REMATCH[2]}";fi
else
lat=$(json_get "$d" "$lp");lon=$(json_get "$d" "$op");cc=$(json_get "$d" "$cp")
fi
lat="${lat// /}";lon="${lon// /}"
if [[ -n "$lat" && -n "$lon" && "$lat" =~ ^-?[0-9.]+$ && "$lon" =~ ^-?[0-9.]+$ ]];then break
else lat="";lon="";cc="";fi
done
fi
if [[ -n "$lat" ]];then
d=$(_fetch "https://api.openweathermap.org/data/2.5/weather?appid=${API_KEY:-}&lat=${lat}&lon=${lon}")
id=$(json_get "$d" ".id");c=$(json_get "$d" ".sys.country")
if [[ -n "$id" && "$id" != "null" ]];then
l="en";[[ -n "${lm[$c]:-}" ]] && l="${lm[$c]}"
u="metric";[[ "$c" == "US" ]] && u="imperial"
update_config "CITY_ID" "$id";update_config "UNIT" "$u";update_config "WEATHER_LANG" "$l"
return 0
fi
fi
return 1
}
weather_main(){
[[ -z "${API_KEY:-}" ]] && exit 1
local city_age=0 ts_val
ts_val=$(grep -o 'CITY_ID_TIMESTAMP=[0-9]*' "$CONFIG_FILE" 2>/dev/null|cut -d= -f2||true)
[[ -n "$ts_val" ]] && city_age=$(( $(date +%s) - ts_val ))
local city_stale=0
[[ -z "${CITY_ID:-}" || $city_age -gt 2592000 ]] && city_stale=1
if [[ $city_stale -eq 1 ]];then
get_loc || { [[ -z "${CITY_ID:-}" ]] && exit 1; }
update_config "CITY_ID_TIMESTAMP" "$(date +%s)"
source "$CONFIG_FILE"
fi
local now mtime
now=$(date +%s);mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null||printf "0")
if [[ ! -f "$CACHE_FILE" || $((now-mtime)) -gt $CACHE_EXPIRATION ]];then
TEMP_FILE=$(mktemp "${CACHE_FILE}.XXXXXX")
local url="https://api.openweathermap.org/data/2.5/weather?appid=${API_KEY}&id=${CITY_ID}&units=${UNIT:-metric}&lang=${WEATHER_LANG:-de}"
if _fetch "$url" >"$TEMP_FILE" && [[ -s "$TEMP_FILE" ]] && grep -q '"name":"' "$TEMP_FILE" && ! grep -qE '"cod":[4-5][0-9][0-9]' "$TEMP_FILE";then
mv -f "$TEMP_FILE" "$CACHE_FILE"
else
rm -f "$TEMP_FILE"
fi
TEMP_FILE=""
fi
}
weather_main
