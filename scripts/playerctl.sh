#!/bin/bash
set -euo pipefail
LOCK_FILE="/dev/shm/playerctl_script.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0
BASE_DIR="$HOME/.config/conky/Mimod"
COVER_FILE="/dev/shm/cover.png"
CACHE_FILE="/dev/shm/current_song_music_script.txt"
POS_FILE="/dev/shm/music_position"
PLACEHOLDER="$BASE_DIR/res/noplayer.png"
set +e;[[ -f "$BASE_DIR/scripts/config" ]]&&source "$BASE_DIR/scripts/config"||true;set -e
HAS_MAGICK=0
MAGICK_BIN=""
if command -v magick &>/dev/null;then HAS_MAGICK=1;MAGICK_BIN="magick"
elif command -v convert &>/dev/null;then HAS_MAGICK=1;MAGICK_BIN="convert";fi
command -v playerctl >/dev/null 2>&1||{ exec 9>&-;exit 0; }
USER_AGENT=$(type -t get_random_ua >/dev/null 2>&1&&get_random_ua||printf "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36")
COVER_ART="${COVER_ART:-true}"
_TV_FOUND_DIR=""
declare -a _TV_WORKER_PIDS=()
_cleanup(){
local pid
for pid in "${_TV_WORKER_PIDS[@]+"${_TV_WORKER_PIDS[@]}"}";do kill "$pid" 2>/dev/null||true;done
for pid in "${_TV_WORKER_PIDS[@]+"${_TV_WORKER_PIDS[@]}"}";do wait "$pid" 2>/dev/null||true;done
[[ -n "${_TV_FOUND_DIR:-}" && -d "$_TV_FOUND_DIR" ]]&&rm -rf "$_TV_FOUND_DIR"
rm -f "/dev/shm/temp_cover_raw_$$"
exec 9>&-
}
trap '_cleanup' EXIT INT TERM
make_cover_round_smart(){
[[ $HAS_MAGICK -eq 0 ]]&&return 1
local src="$1" dst="$2" mode="${3:-crop}" bg="black" b pbg="black"
local -a opts=("-quiet")
if [[ "$mode" == "pad" ]];then
b=$("$MAGICK_BIN" "$src" -alpha off -scale 3x3\! -format "%[fx:int(maxima*100)]" info: 2>/dev/null||printf "100")
[[ "$b" -lt 40 ]]&&pbg="white"
opts+=(-background "$pbg" -alpha remove -alpha off -resize 300x300 -gravity center -extent 300x300)
else opts+=(-resize 300x300^ -gravity center -extent 300x300);fi
"$MAGICK_BIN" "$src" "${opts[@]}" -gravity center -extent 300x300 \( -size 300x300 xc:"$bg" -fill white -draw "circle 150,150 150,290" \) -alpha Off -compose CopyOpacity -composite -background "$bg" -compose over -resize 75x75 "$dst" 2>/dev/null
}
url_safe_encode(){
if command -v jq &>/dev/null;then jq -Rnr --arg x "$1" '$x|@uri'
else
local string="$1" length="${#1}" c i
for((i=0;i<length;i++));do
c="${string:i:1}"
case "$c" in
[a-zA-Z0-9.~_-]) printf '%s' "$c";;
*) printf '%%%02X' "'$c";;
esac
done
fi
}
clean_yt_title(){ sed -E -e 's/\|.*//;s/｜.*//;s/\.[a-zA-Z0-9]{2,5}$//' -e 's/ \((Official [^)]+|Audio|Full Album|HD|HQ|4K|Lyric[^)]*|Video|Edit|Remastered|Radio Edit|Original Mix)\)//gi' -e 's/ \[[^]]+\]//g;s/【[^】]*】//g;s/『[^』]*』//g' -e 's/ - Topic| (prod\.|feat\.|ft\.).*//gi' -e 's/[^[:alpha:][:digit:][:space:][:punct:]]//g' -e 's/\|/-/g;s/^ +//;s/ +$//;s/ {2,}/ /g' <<<"$1"; }
clean_tv_title(){ sed -E -e 's/ im Livestream anschauen.*//gi' -e 's/ en [Dd]irecto.*//g' -e 's/ en [Ll]ive.*//g' -e 's/ [Ll]ive [Ss]tream(ing)?.*//gi' -e 's/ [Ww]atch [Ll]ive.*//g' -e 's/ – [Ll]ive.*//g' -e 's/ \| .*//g' -e 's/ - (Watch|Stream|Live TV|Live Stream).*//gi' -e 's/^[A-Z]{2,3}: //g' -e 's/ (HD|FHD|UHD|4K|SD|LIVE|VOD|HEVC|H\.?264|1080[pi]|720[pi])//gi' -e 's/^ +//;s/ +$//' <<<"$1"; }
perform_download(){
[[ $HAS_MAGICK -eq 0 || -z "${1:-}" || "$1" == "null" ]]&&return 1
local tmp="/dev/shm/temp_cover_raw_$$"
if curl -s -L --fail --max-time 10 --connect-timeout 5 -A "$USER_AGENT" -o "$tmp" "$1" 2>/dev/null&&[[ -s "$tmp" ]]&&"$MAGICK_BIN" "$tmp" -format "%[width]" info: &>/dev/null;then
if make_cover_round_smart "$tmp" "$COVER_FILE" "${2:-crop}";then rm -f "$tmp";return 0;fi
fi
rm -f "$tmp";return 1
}
download_itunes_cover(){
local q enc url
if [[ -z "$1" || "$2" == *"$1"* ]];then q="$2";else q="$1 $2";fi
enc=$(url_safe_encode "$q")
url=$(curl -s --max-time 5 -A "$USER_AGENT" "https://itunes.apple.com/search?term=${enc//%20/+}&limit=1&entity=song" 2>/dev/null|grep -o '"artworkUrl100":"[^"]*"'|head -n1|cut -d'"' -f4|sed 's/100x100bb/512x512bb/g')
[[ -n "${url:-}" && "$url" != "null" ]]&&perform_download "$url"
}
download_deezer_cover(){
local q enc url
if [[ -z "$1" || "$2" == *"$1"* ]];then q="$2";else q="$1 $2";fi
enc=$(url_safe_encode "$q")
url=$(curl -s --max-time 5 -A "$USER_AGENT" "https://api.deezer.com/search?q=$enc" 2>/dev/null|grep -o '"cover_big":"[^"]*"'|head -n1|cut -d'"' -f4|sed 's/\\//g')
[[ -n "${url:-}" && "$url" != "null" ]]&&perform_download "$url"
}
download_musicbrainz_cover(){
local artist="$1" title="$2" mbid
[[ -z "$artist" ]]&&return 1
mbid=$(curl -s --max-time 5 -A "$USER_AGENT" "https://musicbrainz.org/ws/2/recording/?query=artist:$(url_safe_encode "$artist")%20AND%20recording:$(url_safe_encode "$title")&fmt=json&limit=1" 2>/dev/null|grep -o '"releases":\[{"id":"[^"]*"'|head -n1|sed 's/.*"id":"\([^"]*\)".*/\1/')
[[ -n "${mbid:-}" && "$mbid" != "null" ]]&&perform_download "https://coverartarchive.org/release/$mbid/front-500"
}
download_universal_tv_logo(){
local q="$1" mode="${2:-pad}" raw s_none s_dash s_under s_vavoo s_joyn cc country="germany" flag ufile u c r f surl pid
local -a repos=() country_dirs=() cands=() all_urls=() cc_suffixes=()
_TV_WORKER_PIDS=()
raw=$(printf '%s' "$q"|tr '[:upper:]' '[:lower:]'|sed -E -e 's/ im livestream anschauen//gi' -e 's/ en (directo|live)//gi' -e 's/ live stream(ing)?//gi' -e 's/ watch live//gi' -e 's/ [|–-] .*//g')
s_none=$(sed 's/[^a-z0-9]//g' <<<"$raw")
s_dash=$(sed -E 's/[^a-z0-9]+/-/g;s/^-|-$//g' <<<"$raw")
s_under=$(sed -E 's/[^a-z0-9]+/_/g;s/^_|_$//g' <<<"$raw")
s_vavoo="${q// /%20}";s_joyn="$s_none"
cc="DE"
if [[ -f "$HOME/.cache/weather.json" ]];then
cc=$(grep -o '"country":"[^"]*"' "$HOME/.cache/weather.json"|head -n1|cut -d'"' -f4|tr '[:lower:]' '[:upper:]'||printf "DE")
fi
case "$cc" in
AT) country="austria";;AU) country="australia";;
BE) country="belgium";;BR) country="brazil";;
CA) country="canada";;CH) country="switzerland";;
CZ) country="czech-republic";;DK) country="denmark";;
FI) country="finland";;FR) country="france";;
GR) country="greece";;HR) country="croatia";;
HU) country="hungary";;IE) country="ireland";;
IN) country="india";;IT) country="italy";;
JP) country="japan";;KR) country="south-korea";;
MX) country="mexico";;NL) country="netherlands";;
NO) country="norway";;PL) country="poland";;
PT) country="portugal";;RO) country="romania";;
RS) country="serbia";;RU) country="russia";;
SE) country="sweden";;SK) country="slovakia";;
TR) country="turkey";;UA) country="ukraine";;
US) country="united-states";;GB|UK) country="united-kingdom";;
ZA) country="south-africa";;*) country="germany";;
esac
local cc_lc="${cc,,}"
cc_suffixes=("-${cc_lc}" "_${cc_lc}")
country_dirs=("$country" "international" "united-states" "united-kingdom")
declare -A _seen_dir=()
local -a unique_dirs=()
for d in "${country_dirs[@]}";do
[[ -z "${_seen_dir[$d]+_}" ]]&&unique_dirs+=("$d")&&_seen_dir[$d]=1
done
repos=(
"https://raw.githubusercontent.com/cytec/tvlogos/master"
"https://raw.githubusercontent.com/Jasmeet181/mediaportal-de-logos/master/Logos"
"https://raw.githubusercontent.com/picons/picons/master/build-source/logos"
"https://raw.githubusercontent.com/iptv-org/logos/master/logos"
"https://raw.githubusercontent.com/jnk22/kodinerds-iptv/master/logos/tv"
"https://raw.githubusercontent.com/waipu/waipu-logos/master/logos"
)
for d in "${unique_dirs[@]}";do repos+=("https://raw.githubusercontent.com/tv-logo/tv-logos/main/countries/$d");done
local -a raws=("$raw")
local raw_word="$raw" raw_digit="$raw"
local -a num_words=()
case "$cc" in
DE|AT|CH) num_words=("eins" "zwei" "drei" "vier" "fuenf" "sechs" "sieben" "acht" "neun")
local raw_ard="${raw//das erste/ard}"
[[ "$raw_ard" != "$raw" ]]&&raws+=("$raw_ard")
local raw_erste="${raw//ard/das erste}"
[[ "$raw_erste" != "$raw" ]]&&raws+=("$raw_erste");;
FR|BE) num_words=("un" "deux" "trois" "quatre" "cinq" "six" "sept" "huit" "neuf");;
ES|MX|AR) num_words=("uno" "dos" "tres" "cuatro" "cinco" "seis" "siete" "ocho" "nueve");;
IT) num_words=("uno" "due" "tre" "quattro" "cinque" "sei" "sette" "otto" "nove");;
NL) num_words=("een" "twee" "drie" "vier" "vijf" "zes" "zeven" "acht" "negen");;
*) num_words=("one" "two" "three" "four" "five" "six" "seven" "eight" "nine");;
esac
for((idx=1;idx<=9;idx++));do
raw_word="${raw_word//${idx}/${num_words[$((idx-1))]}}"
raw_digit="${raw_digit//${num_words[$((idx-1))]}/${idx}}"
done
[[ "$raw_word" != "$raw" ]]&&raws+=("$raw_word")
[[ "$raw_digit" != "$raw" ]]&&raws+=("$raw_digit")
local -a s_list=()
for r in "${raws[@]}";do
s_list+=("$(sed 's/[^a-z0-9]//g' <<<"$r")")
s_list+=("$(sed -E 's/[^a-z0-9]+/-/g;s/^-|-$//g' <<<"$r")")
s_list+=("$(sed -E 's/[^a-z0-9]+/_/g;s/^_|_$//g' <<<"$r")")
s_list+=("$(sed -E 's/[^a-z0-9.]+/-/g;s/^-|-$//g' <<<"$r")")
done
for s in "${s_list[@]}";do
[[ -z "$s" ]]&&continue
cands+=("$s" "${s^^}" "${s^}")
for sfx in "${cc_suffixes[@]}" "-hd" "_hd" "-4k" "_4k";do cands+=("${s}${sfx}" "${s^^}${sfx}" "${s^}${sfx}");done
done
[[ "$s_dash" == *"-"* ]]&&{
f="${s_dash%%-*}"
cands+=("$f" "${f^^}" "${f^}")
for sfx in "${cc_suffixes[@]}" "-hd" "_hd";do cands+=("${f}${sfx}" "${f^^}${sfx}" "${f^}${sfx}");done
}
all_urls=(
"https://www.joyn.de/logos/v1/channel/$s_joyn.png"
"https://raw.githubusercontent.com/michaz80/vavoo-logos/master/icons/$s_vavoo.png"
"https://raw.githubusercontent.com/cytec/tvlogos/master/logos/$s_vavoo.png"
)
for r in "${repos[@]}";do
while IFS= read -r cand;do [[ -n "$cand" ]]&&all_urls+=("$r/$cand.png");done < <(printf "%s\n" "${cands[@]}"|awk '!seen[$0]++')
done
local fdir="/dev/shm/tvlogo_search_$$"
mkdir -p "$fdir";_TV_FOUND_DIR="$fdir"
flag="$fdir/found.txt";ufile="$fdir/urls.txt"
printf "%s\n" "${all_urls[@]}"|awk '!seen[$0]++' >"$ufile"
local -a urls=()
while IFS= read -r u;do urls+=("$u");done <"$ufile"
local total=${#urls[@]} res_file="$fdir/results.txt"
touch "$res_file"
local title_hash logo_cache_file cached_url
title_hash=$(printf '%s' "$q"|md5sum|cut -c1-8||printf '%s' "$q"|cksum|cut -d' ' -f1)
logo_cache_file="/dev/shm/tvlogo_${title_hash}.url"
if [[ -f "$logo_cache_file" ]];then
cached_url=$(<"$logo_cache_file")
if [[ -n "$cached_url" ]]&&perform_download "$cached_url" "$mode";then return 0;fi
rm -f "$logo_cache_file"
fi
local -a finished=()
local best_200=-1 next_submit=0 max_active=25 start_time=$SECONDS
while [[ $SECONDS -lt $((start_time+6)) ]];do
local active=$((next_submit-${#finished[@]}))
while [[ $active -lt $max_active && $next_submit -lt $total ]];do
local u="${urls[$next_submit]}" idx=$next_submit
(local code;code=$(curl -s -o /dev/null -I -w '%{http_code}' -L --max-time 2 --connect-timeout 1 -A "$USER_AGENT" "$u" 2>/dev/null||echo "000");echo "$idx $code $u" >>"$res_file") &
_TV_WORKER_PIDS+=($!);((next_submit++));active=$((next_submit-${#finished[@]}))
done
active=$((next_submit-${#finished[@]}))
if [[ $active -gt 0 ]];then wait -n 2>/dev/null||true;elif [[ $next_submit -ge $total ]];then break;fi
while read -r idx code u||[[ -n "${idx:-}" ]];do
[[ -z "${idx:-}" || -z "${code:-}" || -z "${u:-}" ]]&&continue
if [[ -z "${finished[$idx]:-}" ]];then
finished[$idx]=$code
if [[ "$code" == "200" ]];then
if [[ $best_200 -eq -1 || $idx -lt $best_200 ]];then best_200=$idx;fi
fi
fi
done <"$res_file"
if [[ $best_200 -ne -1 ]];then
local winner_found=1
for((i=0;i<best_200;i++));do if [[ -z "${finished[$i]:-}" ]];then winner_found=0;break;fi;done
[[ $winner_found -eq 1 ]]&&break
if [[ $best_200 -lt 15 && $winner_found -eq 1 ]];then break;fi
fi
done
for pid in "${_TV_WORKER_PIDS[@]+"${_TV_WORKER_PIDS[@]}"}";do kill "$pid" 2>/dev/null||true;done
for pid in "${_TV_WORKER_PIDS[@]+"${_TV_WORKER_PIDS[@]}"}";do wait "$pid" 2>/dev/null||true;done
surl=""
if [[ $best_200 -ne -1 ]];then surl="${urls[$best_200]}";fi
rm -rf "$fdir";_TV_FOUND_DIR=""
if [[ -n "$surl" ]]&&perform_download "$surl" "$mode";then printf '%s' "$surl" >"$logo_cache_file";return 0;fi
return 1
}
player_main(){
local d=$'\x1f' DATA ARTIST TITLE STATUS ART_URL POS RAW_POS RAW_LEN PLAYER TV_RAW is_tv CUR_S LAST_S ok
DATA=$(timeout 0.9 playerctl metadata --format "{{xesam:artist}}${d}{{xesam:title}}${d}{{status}}${d}{{mpris:artUrl}}${d}{{duration(position)}}${d}{{position}}${d}{{mpris:length}}${d}{{playerName}}" 2>/dev/null||true)
if [[ -z "$DATA" ]];then
if ! playerctl status >/dev/null 2>&1&&[[ -f "$CACHE_FILE" ]];then
[[ "$COVER_ART" == "true" && $HAS_MAGICK -eq 1 && -f "$PLACEHOLDER" ]]&&make_cover_round_smart "$PLACEHOLDER" "$COVER_FILE" "crop"
rm -f "$CACHE_FILE" "$POS_FILE"
fi
return 0
fi
IFS="$d" read -r ARTIST TITLE STATUS ART_URL POS RAW_POS RAW_LEN PLAYER <<<"$DATA"
STATUS="${STATUS:-Unknown}";TV_RAW="$TITLE"
if [[ -z "$ARTIST" || "$ARTIST" == "null" ]]&&[[ "$TITLE" == *" - "* ]];then
ARTIST="${TITLE%% - *}";TITLE="${TITLE#* - }"
fi
is_tv=0
if [[ "$PLAYER" =~ ^(vlc|mpv|chromium|firefox)$ ]];then
if [[ "$TITLE" == *"Joyn"* || "$ARTIST" == *"Joyn"* ]];then is_tv=1
elif [[ "$TITLE" == *"Vavoo"* || "$ARTIST" == *"Vavoo"* ]];then is_tv=2
else is_tv=3;fi
fi
local DISPLAY_ARTIST="$ARTIST" DISPLAY_TITLE="$TITLE"
local SEARCH_ARTIST SEARCH_TITLE
SEARCH_ARTIST=$(clean_yt_title "$ARTIST");SEARCH_TITLE=$(clean_yt_title "$TITLE")
printf '%s|%s|%s' "$POS" "${RAW_POS:-0}" "${RAW_LEN:-0}" >"$POS_FILE"
CUR_S="$DISPLAY_ARTIST|$DISPLAY_TITLE|$STATUS";LAST_S=""
[[ -f "$CACHE_FILE" ]]&&LAST_S=$(<"$CACHE_FILE")
if [[ "${LAST_S%|*}" != "$DISPLAY_ARTIST|$DISPLAY_TITLE" && "$COVER_ART" == "true" && $HAS_MAGICK -eq 1 ]];then
ok=0
if [[ "$ART_URL" == file://* ]];then make_cover_round_smart "${ART_URL#file://}" "$COVER_FILE" "crop"&&ok=1
elif [[ "$ART_URL" == http* ]];then perform_download "$ART_URL" "crop"&&ok=1
elif [[ $is_tv -gt 0 ]];then download_universal_tv_logo "$(clean_tv_title "$TV_RAW")" "pad"&&ok=1;fi
[[ $ok -eq 0 ]]&&download_deezer_cover "$SEARCH_ARTIST" "$SEARCH_TITLE"&&ok=1
[[ $ok -eq 0 ]]&&download_itunes_cover "$SEARCH_ARTIST" "$SEARCH_TITLE"&&ok=1
[[ $ok -eq 0 ]]&&download_musicbrainz_cover "$SEARCH_ARTIST" "$SEARCH_TITLE"&&ok=1
[[ $ok -eq 0 && -f "$PLACEHOLDER" ]]&&make_cover_round_smart "$PLACEHOLDER" "$COVER_FILE" "crop"
fi
[[ "$LAST_S" != "$CUR_S" ]]&&printf '%s' "$CUR_S" >"$CACHE_FILE"
}
player_main "$@"
exec 9>&-
