#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
[[ -f "$SCRIPT_DIR/config" ]] && source "$SCRIPT_DIR/config"
CACHE_DIR="$HOME/.cache"
CACHE_FILE="$CACHE_DIR/old_quote.txt"
RENDER_FILE="$CACHE_DIR/conky_quote_render.txt"
LOCK_FILE="/dev/shm/quote_script.lock"
MAX_L=150
WRAP=40
UA=$(type -t get_random_ua >/dev/null 2>&1 && get_random_ua || printf "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36")
mkdir -p "$CACHE_DIR"
fetch_url(){
curl -s -L --fail --max-time 5 -H 'Referer: https://google.com' -H 'Accept-Language: en-US,en;q=0.9' -A "$UA" "$1" 2>/dev/null \
|| wget -qO- -T 5 --no-check-certificate --header='Referer: https://google.com' --header='Accept-Language: en-US,en;q=0.9' -U "$UA" "$1" 2>/dev/null \
|| true
}
read_cache(){ [[ ! -f "$CACHE_FILE" ]] && return; awk 'found{print} /^---$/{found=1}' "$CACHE_FILE" 2>/dev/null || true; }
wrap_text(){
local w="$WRAP"
if command -v fmt &>/dev/null;then fmt -w "$w"
elif command -v fold &>/dev/null;then fold -s -w "$w"
else awk -v w="$w" '{n=split($0,a," ");l="";for(i=1;i<=n;i++){if(length(l)+length(a[i])+(l!=""?1:0)>w){print l;l=a[i]}else l=(l==""?a[i]:l" "a[i])};if(l!="")print l}';fi
}
format_output(){
local line out=""
while IFS= read -r line;do out+="${out:+$'\n'}\${alignc}${line}";done < <(wrap_text <<<"$1")
printf '%s\n' "$out"
}
fetch_and_save(){
exec 9>"$LOCK_FILE"
flock -n 9 || return 0
local src="${QUOTE_SOURCE:-ROUNDROBIN}" last raw="" lang final tmp_c tmp_r
if [[ "$src" == "ROUNDROBIN" ]];then
last=$(head -n1 "$RENDER_FILE" 2>/dev/null|grep -o 'RR:[A-Z]*'|cut -c4-||true)
[[ -z "$last" ]] && last=$(head -n1 "$CACHE_FILE" 2>/dev/null||true)
case "$last" in
BRAINYQUOTE) src="RANDOMQUOTE";;
RANDOMQUOTE) src="ZENQUOTES";;
ZENQUOTES) src="QUOTESLATE";;
QUOTESLATE) src="QUOTABLE";;
QUOTABLE) src="BRAINYQUOTE";;
*) src="BRAINYQUOTE";;
esac
fi
case "$src" in
BRAINYQUOTE) raw=$(fetch_url "http://www.brainyquote.com/link/quotebr.js"|sed -n -e 's/.*innerHTML="\([^"]*\)".*/\1/p' -e 's/.*br\.writeln("\([^"]*\)");.*/\1/p'|sed 's/<[^>]*>//g'|grep -v "Today's Quote"|awk 'NF{print;exit}'||true);;
RANDOMQUOTE) raw=$(fetch_url "https://random-quotes-freeapi.vercel.app/api/random"|jq -r '.quote//empty' 2>/dev/null||true);;
QUOTESLATE) raw=$(fetch_url "https://quoteslate.ir/api/quotes/random"|jq -r '.quote//empty' 2>/dev/null||true);;
QUOTABLE) raw=$(fetch_url "https://api.quotable.io/random"|jq -r '.content//empty' 2>/dev/null||true);;
ZENQUOTES|*) raw=$(fetch_url "https://zenquotes.io/api/random"|jq -r '.[0].q//empty' 2>/dev/null||true);;
esac
if [[ -n "$raw" ]];then
lang="${WEATHER_LANG:-de}";final=""
if [[ "$lang" == "en" ]];then final="$raw"
else final=$(timeout 10 trans -brief :"$lang" <<<"$raw" 2>/dev/null||true)
[[ -z "$final" ]] && final="$raw"
fi
if [[ -n "$final" && ${#final} -le $MAX_L ]];then
tmp_c="${CACHE_FILE}.tmp.$$";tmp_r="${RENDER_FILE}.tmp.$$"
{ printf "%s\n---\n%s\n" "$src" "$final" >"$tmp_c" && mv -f "$tmp_c" "$CACHE_FILE"; } || rm -f "$tmp_c"
{ { printf '# RR:%s\n' "$src";format_output "$final"; } >"$tmp_r" && mv -f "$tmp_r" "$RENDER_FILE"; } || rm -f "$tmp_r"
fi
fi
exec 9>&-
}
quote_main(){
local mtime f r
if [[ "${WEATHER_LANG:-de}" != "en" ]] && ! command -v trans &>/dev/null;then
if [[ -s "$RENDER_FILE" ]];then grep -v '^#' "$RENDER_FILE"
else f=$(read_cache);[[ -n "$f" ]] && format_output "$f" || true;fi
return 0
fi
mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || printf "0")
if (( $(date +%s) - mtime >= 1800 ));then
if [[ ! -s "$CACHE_FILE" ]];then fetch_and_save
else (fetch_and_save) & disown $!;fi
fi
if [[ -s "$RENDER_FILE" ]];then grep -v '^#' "$RENDER_FILE"
else
f=$(read_cache)
if [[ -n "$f" ]];then
r=$(format_output "$f")
printf '%s\n' "$r"
{ printf '# RR:%s\n' "${QUOTE_SOURCE:-}";printf '%s\n' "$r"; } >"$RENDER_FILE"
fi
fi
}
quote_main "$@"
