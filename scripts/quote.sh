#!/bin/bash
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
set -o allexport
source "$SCRIPT_DIR/config"
set +o allexport

CACHE_FILE="$HOME/.cache/old_quote.txt"
RENDER_FILE="$HOME/.cache/conky_quote_render.txt"
LOCK_DIR="$HOME/.cache/quote_lock"
MAX_L=150
WRAP=40
UA=$(get_random_ua 2>/dev/null || echo "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36")

fetch_url() {
    curl -s -L --max-time 5 \
        -H 'Referer: https://google.com' \
        -H 'Accept-Language: en-US,en;q=0.9' \
        -A "$UA" "$1" 2>/dev/null \
    || wget -qO- -T 5 --no-check-certificate \
        --header='Referer: https://google.com' \
        --header='Accept-Language: en-US,en;q=0.9' \
        -U "$UA" "$1" 2>/dev/null
}

read_cache() {
    local body
    body=$(awk 'found; /^---$/{found=1}' "$CACHE_FILE" 2>/dev/null)
    [[ -z "$body" ]] && body=$(sed -n '2p' "$CACHE_FILE" 2>/dev/null)
    echo "$body"
}

wrap_text() {
    if command -v fmt &>/dev/null; then
        fmt -w "$WRAP"
    elif command -v fold &>/dev/null; then
        fold -s -w "$WRAP"
    else
        awk -v w="$WRAP" '{
            n=split($0,a," "); line=""
            for(i=1;i<=n;i++){
                if(length(line)+length(a[i])+(line!=""?1:0)>w){print line; line=a[i]}
                else line=(line==""?a[i]:line" "a[i])
            }
            if(line!="")print line
        }'
    fi
}

format_output() {
    local text="$1"
    local line out=""
    while IFS= read -r line; do
        out+="${out:+$'\n'}\${alignc}${line}"
    done < <(echo "$text" | wrap_text)
    echo "$out"
}

fetch_and_save() {
    local SRC_ACTUAL="$QUOTE_SOURCE"

    if [[ "$QUOTE_SOURCE" == "ROUNDROBIN" ]]; then
        local LAST=""
        [[ -f "$CACHE_FILE" ]] && LAST=$(head -1 "$CACHE_FILE" 2>/dev/null)
        case "$LAST" in
            "BRAINYQUOTE") SRC_ACTUAL="RANDOMQUOTE" ;;
            "RANDOMQUOTE") SRC_ACTUAL="ZENQUOTES"   ;;
            "ZENQUOTES")   SRC_ACTUAL="QUOTESLATE"  ;;
            *)             SRC_ACTUAL="BRAINYQUOTE" ;;
        esac
    fi

    local RAW=""
    case "$SRC_ACTUAL" in
        "BRAINYQUOTE")
            local JS
            JS=$(fetch_url "http://www.brainyquote.com/link/quotebr.js")
            RAW=$(echo "$JS" | sed -n 's/.*innerHTML="\([^"]*\)".*/\1/p' | sed 's/<[^>]*>//g')
            if [[ -z "$RAW" ]]; then
                RAW=$(echo "$JS" \
                    | sed -n 's/.*br\.writeln("\([^"]*\)");.*/\1/p' \
                    | sed 's/<[^>]*>//g' \
                    | grep -v "Today's Quote" \
                    | awk 'NF{print;exit}')
            fi
            ;;
        "RANDOMQUOTE")
            RAW=$(fetch_url "https://random-quotes-freeapi.vercel.app/api/random" \
                | jq -r '.quote // empty' 2>/dev/null)
            ;;
        "QUOTESLATE")
            RAW=$(fetch_url "https://quoteslate.ir/api/quotes/random" \
                | jq -r '.quote // empty' 2>/dev/null)
            ;;
        *)
            RAW=$(fetch_url "https://zenquotes.io/api/random" \
                | jq -r '.[0].q // empty' 2>/dev/null)
            ;;
    esac

    local FINAL=""
    if [[ -n "$RAW" ]]; then
        if [[ "${WEATHER_LANG:-de}" == "en" ]]; then
            FINAL="$RAW"
        else
            FINAL=$(echo "$RAW" | timeout 10 trans -brief :"${WEATHER_LANG:-de}" 2>/dev/null)
            [[ -z "$FINAL" ]] && FINAL="$RAW"
        fi
    fi

    if [[ -n "$FINAL" && ${#FINAL} -le $MAX_L ]]; then
        local tmp_cache="${CACHE_FILE}.tmp" tmp_render="${RENDER_FILE}.tmp"
        printf "%s\n---\n%s\n" "$SRC_ACTUAL" "$FINAL" > "$tmp_cache" && \
            mv -f "$tmp_cache" "$CACHE_FILE"
        format_output "$FINAL" > "$tmp_render" && \
            mv -f "$tmp_render" "$RENDER_FILE"
    fi

    rmdir "$LOCK_DIR" 2>/dev/null
}

_maybe_clear_stale_lock() {
    if [[ -d "$LOCK_DIR" ]]; then
        local lock_mtime lock_age=0
        lock_mtime=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)
        if (( lock_mtime > 0 )); then
            lock_age=$(( $(date +%s) - lock_mtime ))
        else
            lock_age=999
        fi
        if (( lock_age > 120 )); then
            rmdir "$LOCK_DIR" 2>/dev/null
        fi
    fi
}

main() {
    if ! command -v trans &>/dev/null; then
        if [[ -f "$RENDER_FILE" ]]; then
            cat "$RENDER_FILE"
        elif [[ -f "$CACHE_FILE" ]]; then
            local FINAL
            FINAL=$(read_cache)
            [[ -n "$FINAL" ]] && format_output "$FINAL"
        else
            printf "\${alignc}Install 'translate-shell'\n"
        fi
        return 0
    fi

    local mtime now age
    mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$(( now - mtime ))

    if (( age >= 1800 )); then
        _maybe_clear_stale_lock
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            fetch_and_save &
            disown
        fi
    fi

    if [[ -f "$RENDER_FILE" ]]; then
        cat "$RENDER_FILE"
    elif [[ -f "$CACHE_FILE" ]]; then
        local FINAL
        FINAL=$(read_cache)
        if [[ -n "$FINAL" ]]; then
            local rendered
            rendered=$(format_output "$FINAL")
            echo "$rendered"
            echo "$rendered" > "$RENDER_FILE"
        fi
    fi
}

main "$@"
exit 0
