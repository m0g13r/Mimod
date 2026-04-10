#!/bin/bash
main() {
    local SCRIPT_DIR
    SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
    set -o allexport
    source "$SCRIPT_DIR/config"
    set +o allexport
    local CACHE_FILE="$HOME/.cache/old_quote.txt"
    local LOCK_DIR="$HOME/.cache/quote_lock"
    local MAX_L=150
    local WRAP=40
    local UA
    UA=$(get_random_ua 2>/dev/null || echo "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36")
    fetch_url() {
        curl -s -L --max-time 5 -H 'Referer: https://google.com' -H 'Accept-Language: en-US,en;q=0.9' -k -A "$UA" "$1" 2>/dev/null || wget -qO- -T 5 --no-check-certificate --header='Referer: https://google.com' --header='Accept-Language: en-US,en;q=0.9' -U "$UA" "$1" 2>/dev/null
    }
    read_cache() {
        local body
        body=$(awk 'found; /^---$/{found=1}' "$CACHE_FILE")
        [[ -z "$body" ]] && body=$(sed -n '2p' "$CACHE_FILE")
        echo "$body"
    }
    wrap_text() {
        if command -v fmt &>/dev/null; then
            fmt -w "$WRAP"
        else
            fold -s -w "$WRAP"
        fi
    }
    format_output() {
        local text="$1"
        local wrapped
        wrapped=$(echo "$text" | wrap_text)
        echo "\${alignc}${wrapped//$'\n'/$'\n'\$\{alignc\}}"
    }
    fetch_and_save() {
        local SRC_ACTUAL="$QUOTE_SOURCE"
        if [[ "$QUOTE_SOURCE" == "ROUNDROBIN" ]]; then
            local LAST=""
            [[ -f "$CACHE_FILE" ]] && LAST=$(head -1 "$CACHE_FILE" 2>/dev/null)
            case "$LAST" in
                "BRAINYQUOTE")  SRC_ACTUAL="RANDOMQUOTE" ;;
                "RANDOMQUOTE")  SRC_ACTUAL="ZENQUOTES"   ;;
                "ZENQUOTES")    SRC_ACTUAL="QUOTABLE"    ;;
                *)              SRC_ACTUAL="BRAINYQUOTE"  ;;
            esac
        fi
        local RAW=""
        case "$SRC_ACTUAL" in
            "BRAINYQUOTE")
                local JS
                JS=$(fetch_url "http://www.brainyquote.com/link/quotebr.js")
                RAW=$(echo "$JS" | sed -n 's/.*innerHTML="\([^"]*\)".*/\1/p' | sed 's/<[^>]*>//g')
                if [[ -z "$RAW" ]]; then
                    RAW=$(echo "$JS" | sed -n 's/.*br\.writeln("\([^"]*\)");.*/\1/p' | sed 's/<[^>]*>//g' | grep -v "Today's Quote" | awk 'NF' | awk 'NR==1{print $0}')
                fi
                ;;
            "RANDOMQUOTE")
                RAW=$(fetch_url "https://random-quotes-freeapi.vercel.app/api/random" | jq -r '.quote // empty' 2>/dev/null)
                ;;
            "QUOTABLE")
                RAW=$(fetch_url "https://api.quotable.io/random" | jq -r '.content // empty' 2>/dev/null)
                ;;
            *)
                RAW=$(fetch_url "https://zenquotes.io/api/random" | jq -r '.[0].q // empty' 2>/dev/null)
                ;;
        esac
        local FINAL=""
        if [[ -n "$RAW" ]]; then
            FINAL=$(echo "$RAW" | timeout 10 trans -brief :"${WEATHER_LANG:-de}" 2>/dev/null)
            [[ -z "$FINAL" ]] && FINAL="$RAW"
        fi
        if [[ -n "$FINAL" && ${#FINAL} -le $MAX_L ]]; then
            printf "%s\n---\n%s\n" "$SRC_ACTUAL" "$FINAL" > "$CACHE_FILE"
        fi
        rmdir "$LOCK_DIR" 2>/dev/null
    }
    if ! command -v trans &>/dev/null; then
        if [[ -f "$CACHE_FILE" ]]; then
            local FINAL
            FINAL=$(read_cache)
            [[ -n "$FINAL" ]] && format_output "$FINAL" && return 0
        fi
        printf "\${alignc}Install 'translate-shell'\n"
        return 0
    fi
    local mtime now age
    mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$(( now - mtime ))
    if (( age >= 1800 )); then
        local lock_age=0
        if [[ -d "$LOCK_DIR" ]]; then
            lock_age=$(( now - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo "$now") ))
            if (( lock_age > 120 )); then
                rmdir "$LOCK_DIR" 2>/dev/null
            fi
        fi
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            fetch_and_save &
        fi
    fi
    if [[ -f "$CACHE_FILE" ]]; then
        local FINAL
        FINAL=$(read_cache)
        [[ -n "$FINAL" ]] && format_output "$FINAL"
    fi
}
main "$@"
exit 0
