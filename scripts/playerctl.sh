#!/bin/bash
LOCK_FILE="/dev/shm/playerctl_script.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

COVER_FILE="/dev/shm/cover.png"
CACHE_FILE="/dev/shm/current_song_music_script.txt"
POS_FILE="/dev/shm/music_position"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PLACEHOLDER="$(dirname "$SCRIPT_DIR")/res/noplayer.png"
source "$SCRIPT_DIR/config" 2>/dev/null || true
USER_AGENT=$(type -t get_random_ua >/dev/null && get_random_ua || \
    echo "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

HAS_MAGICK=0
command -v magick &>/dev/null && HAS_MAGICK=1

if ! command -v playerctl &>/dev/null; then
    exec 9>&-
    exit 0
fi

COVER_ART="${COVER_ART:-true}"

_TV_FOUND_DIR=""
_TV_WORKER_PIDS=()

_cleanup() {
    for pid in "${_TV_WORKER_PIDS[@]}"; do
        kill "$pid" 2>/dev/null
    done
    [[ ${#_TV_WORKER_PIDS[@]} -gt 0 ]] && wait "${_TV_WORKER_PIDS[@]}" 2>/dev/null
    [[ -n "$_TV_FOUND_DIR" && -d "$_TV_FOUND_DIR" ]] && rm -rf "$_TV_FOUND_DIR"
    rm -f "/dev/shm/temp_cover_raw"
    exec 9>&-
}
trap '_cleanup; exit' EXIT INT TERM

make_cover_round_smart() {
    [[ $HAS_MAGICK -eq 0 ]] && return 1
    local source="$1"
    local target="$2"
    local mode="${3:-crop}"
    local bg_color="black"
    local opts=("-quiet")

    if [[ "$mode" == "pad" ]]; then
        local peak_brightness
        peak_brightness=$(magick "$source" -alpha off -scale 3x3\! \
            -format "%[fx:int(maxima*100)]" info: 2>/dev/null || echo "100")
        local pad_bg="black"
        [ "$peak_brightness" -lt 40 ] && pad_bg="white"
        opts+=(-background "$pad_bg" -alpha remove -alpha off)
        opts+=(-resize 300x300 -background "$pad_bg" -gravity center -extent 300x300)
    else
        opts+=(-resize 300x300^ -gravity center -extent 300x300)
    fi

    local temp_target="${target}.tmp"
    if magick "$source" "${opts[@]}" \
        \( -size 300x300 xc:"$bg_color" -fill white -draw "circle 150,150 150,290" \) \
        -alpha Off -compose CopyOpacity -composite \
        -background "$bg_color" -compose over \
        -resize 75x75 "$temp_target"; then
        mv -f "$temp_target" "$target"
    else
        rm -f "$temp_target"
        return 1
    fi
}

url_safe_encode() {
    if command -v jq &>/dev/null; then
        jq -Rnr --arg x "$1" '$x | @uri'
    elif command -v python3 &>/dev/null; then
        python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read().strip()))" <<< "${1}"
    else
        local encoded="" byte hex_str dec
        hex_str=$(printf "%s" "$1" | od -An -tx1 | tr -d ' \n')
        local len=${#hex_str}
        for (( i=0; i<len; i+=2 )); do
            byte="${hex_str:$i:2}"
            dec=$(( 16#$byte ))
            if (( (dec >= 65 && dec <= 90) || (dec >= 97 && dec <= 122) ||
                  (dec >= 48 && dec <= 57) ||
                  dec == 45 || dec == 46 || dec == 95 || dec == 126 )); then
                encoded+=$(printf "\x${byte}")
            else
                encoded+="%${byte^^}"
            fi
        done
        echo "$encoded"
    fi
}

clean_yt_title() {
    local text="$1"
    text="${text%%|*}"
    text="${text%%｜*}"
    sed -E \
        -e 's/\.[a-zA-Z0-9]{2,5}$//' \
        -e 's/ \((Official [^)]+|Audio|Full Album|HD|HQ|4K|Lyric[^)]*|Video|Edit|Remastered|Radio Edit|Original Mix|Live[^)]*|Acoustic)\)//gi' \
        -e 's/ \[[^]]+\]//g' \
        -e 's/【[^】]*】//g' \
        -e 's/『[^』]*』//g' \
        -e 's/ - Topic| (prod\.|feat\.|ft\.).*//gi' \
        -e 's/[^[:alpha:][:digit:][:space:][:punct:]]//g' \
        -e 's/\|/-/g' \
        -e 's/^ +//; s/ +$//; s/ {2,}/ /g' \
        <<< "$text"
}

clean_tv_title() {
    local text="$1"
    sed -E \
        -e 's/ im Livestream anschauen.*//gi' \
        -e 's/^[A-Z]{2}: //g' \
        -e 's/ (HD|FHD|4K|SD|LIVE|VOD)//gi' \
        -e 's/^ +//; s/ +$//' \
        <<< "$text"
}

perform_download() {
    [[ $HAS_MAGICK -eq 0 ]] && return 1
    local url="$1"
    local mode="${2:-crop}"
    [[ -z "$url" || "$url" == "null" ]] && return 1
    local temp_raw="/dev/shm/temp_cover_raw"
    if curl -s -L --compressed --fail --max-time 10 --connect-timeout 5 \
            -A "$USER_AGENT" -o "$temp_raw" "$url"; then
        if magick "$temp_raw" -format "%[width]x%[height]" info: &>/dev/null; then
            make_cover_round_smart "$temp_raw" "$COVER_FILE" "$mode"
            rm -f "$temp_raw"
            return 0
        fi
    fi
    rm -f "$temp_raw"
    return 1
}

download_itunes_cover() {
    local search_query
    if [[ -z "$1" ]]; then
        search_query=$(url_safe_encode "$2")
    elif [[ "$2" == *"$1"* ]]; then
        search_query=$(url_safe_encode "$2")
    else
        search_query=$(url_safe_encode "$1 $2")
    fi
    search_query="${search_query//%20/+}"
    local cover_url
    cover_url=$(curl -s --compressed --max-time 2 -A "$USER_AGENT" \
        "https://itunes.apple.com/search?term=$search_query&limit=1&entity=song" \
        | jq -r '.results[0].artworkUrl100' 2>/dev/null \
        | sed 's/100x100bb/512x512bb/g')
    [[ -n "$cover_url" && "$cover_url" != "null" ]] && perform_download "$cover_url"
}

download_deezer_cover() {
    local search_query
    if [[ -z "$1" ]]; then
        search_query=$(url_safe_encode "$2")
    elif [[ "$2" == *"$1"* ]]; then
        search_query=$(url_safe_encode "$2")
    else
        search_query=$(url_safe_encode "$1 $2")
    fi
    local cover_url
    cover_url=$(curl -s --compressed --max-time 2 -A "$USER_AGENT" \
        "https://api.deezer.com/search?q=$search_query" \
        | jq -r '.data[0].album.cover_big' 2>/dev/null)
    [[ -n "$cover_url" && "$cover_url" != "null" ]] && perform_download "$cover_url"
}

download_musicbrainz_cover() {
    [[ -z "$1" ]] && return 1
    local url_artist url_title
    url_artist=$(url_safe_encode "$1")
    url_title=$(url_safe_encode "$2")
    local mbid
    mbid=$(curl -s --compressed --max-time 2 -A "$USER_AGENT" \
        "https://musicbrainz.org/ws/2/recording/?query=artist:$url_artist%20AND%20recording:$url_title&fmt=json&limit=1" \
        | jq -r '.recordings[0].releases[0].id' 2>/dev/null)
    [[ -n "$mbid" && "$mbid" != "null" ]] && \
        perform_download "https://coverartarchive.org/release/$mbid/front-500"
}


download_universal_tv_logo() {
    [[ $HAS_MAGICK -eq 0 ]] && return 1

    local query="$1"
    local mode="${2:-pad}"
    local slug_raw slug_dash slug_none slug_under slug_vavoo slug_joyn
    slug_raw=$(echo "$query" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/ im livestream anschauen//gi; s/ [|] .*//g')
    slug_none=$(echo "$slug_raw"  | sed 's/[^a-z0-9]//g')
    slug_dash=$(echo "$slug_raw"  | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')
    slug_under=$(echo "$slug_raw" | sed -E 's/[^a-z0-9]+/_/g; s/^_|_$//g')
    slug_vavoo=$(echo "$query"    | sed 's/ /%20/g')
    slug_joyn=$(echo "$query"     | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')

    local tv_country="germany"
    if [[ -f "$HOME/.cache/weather.json" ]]; then
        local cc
        cc=$(jq -r '.sys.country // empty' "$HOME/.cache/weather.json" 2>/dev/null \
            | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
        case "$cc" in
            AT) tv_country="austria"     ;;
            CH) tv_country="switzerland" ;;
            FR) tv_country="france"      ;;
            IT) tv_country="italy"       ;;
            ES) tv_country="spain"       ;;
            NL) tv_country="netherlands" ;;
            PL) tv_country="poland"      ;;
            GB|UK) tv_country="uk"       ;;
            *) tv_country="germany"      ;;
        esac
    fi

    local repos=(
        "https://raw.githubusercontent.com/cytec/tvlogos/master"
        "https://raw.githubusercontent.com/Jasmeet181/mediaportal-de-logos/master/Logos"
        "https://raw.githubusercontent.com/tv-logo/tv-logos/main/countries/$tv_country"
        "https://raw.githubusercontent.com/picons/picons/master/build-source/logos"
        "https://raw.githubusercontent.com/iptv-org/logos/master/logos"
        "https://raw.githubusercontent.com/jnk22/kodinerds-iptv/master/logos/tv"
        "https://raw.githubusercontent.com/waipu/waipu-logos/master/logos"
    )

    local candidates=()
    for s in "$slug_dash" "$slug_none" "$slug_under"; do
        [[ -z "$s" ]] && continue
        candidates+=("$s" "${s^^}" "${s^}")
        candidates+=("${s}-de" "${s}-hd" "${s}_de" "${s}_hd")
    done
    if [[ "$slug_dash" == *"-"* ]]; then
        local first="${slug_dash%%-*}"
        candidates+=("$first" "${first^^}" "${first^}")
        candidates+=("${first}-de" "${first}-hd" "${first}_de" "${first}_hd")
    fi
    local unique_candidates
    unique_candidates=$(printf "%s\n" "${candidates[@]}" | sort -u)

    local all_urls=()
    all_urls+=("https://www.joyn.de/logos/v1/channel/$slug_joyn.png")
    all_urls+=("https://raw.githubusercontent.com/michaz80/vavoo-logos/master/icons/$slug_vavoo.png")
    all_urls+=("https://raw.githubusercontent.com/cytec/tvlogos/master/logos/$slug_vavoo.png")
    for repo in "${repos[@]}"; do
        while read -r cand; do
            [[ -z "$cand" ]] && continue
            all_urls+=("$repo/$cand.png")
        done <<< "$unique_candidates"
    done

    local found_dir="/dev/shm/tvlogo_search_$$"
    mkdir -p "$found_dir"
    _TV_FOUND_DIR="$found_dir"
    local url_file="$found_dir/urls.txt"

    printf "%s\n" "${all_urls[@]}" | awk '!seen[$0]++' | head -n 60 > "$url_file"

    _TV_WORKER_PIDS=()
    local found_flag="$found_dir/found.txt"
    local spawn_count=0

    while IFS= read -r url; do
        [[ -s "$found_flag" ]] && break

        (
            exec 9>&-
            [[ -s "$found_flag" ]] && exit 0
            code=$(curl -s -o /dev/null -I -w '%{http_code}' -L \
                --max-time 3 -A "$USER_AGENT" "$url" 2>/dev/null)
            if [[ "$code" == "200" ]]; then
                echo "$url" > "${found_flag}.tmp.$$" && \
                    mv -f "${found_flag}.tmp.$$" "$found_flag" 2>/dev/null || true
            fi
        ) &
        _TV_WORKER_PIDS+=($!)
        (( spawn_count++ ))

        if (( spawn_count % 15 == 0 )); then
            local alive=()
            for pid in "${_TV_WORKER_PIDS[@]}"; do
                kill -0 "$pid" 2>/dev/null && alive+=("$pid")
            done
            _TV_WORKER_PIDS=("${alive[@]}")
            wait -n 2>/dev/null || true
        fi
    done < "$url_file"

    while true; do
        [[ -s "$found_flag" ]] && break
        local running=0
        for pid in "${_TV_WORKER_PIDS[@]}"; do
            kill -0 "$pid" 2>/dev/null && running=1 && break
        done
        (( running == 0 )) && break
        sleep 0.15
    done

    for pid in "${_TV_WORKER_PIDS[@]}"; do kill "$pid" 2>/dev/null; done
    [[ ${#_TV_WORKER_PIDS[@]} -gt 0 ]] && wait "${_TV_WORKER_PIDS[@]}" 2>/dev/null
    _TV_WORKER_PIDS=()

    local success_url=""
    [[ -s "$found_flag" ]] && success_url=$(head -n 1 "$found_flag")
    _TV_FOUND_DIR=""
    rm -rf "$found_dir"

    if [[ -n "$success_url" ]]; then
        perform_download "$success_url" "$mode"
        return $?
    fi
    return 1
}

main() {
    local delim=$'\x1f'
    local DATA
    DATA=$(timeout 0.9 playerctl metadata \
        --format "{{xesam:artist}}${delim}{{xesam:title}}${delim}{{status}}${delim}{{mpris:artUrl}}${delim}{{duration(position)}}${delim}{{position}}${delim}{{mpris:length}}${delim}{{playerName}}" \
        2>/dev/null)

    local RAW_CACHE_FILE="/dev/shm/current_song_raw.txt"

    if [[ -z "$DATA" ]]; then
        if ! playerctl status &>/dev/null; then
            if [[ -f "$CACHE_FILE" ]]; then
                [[ "$COVER_ART" == "true" && $HAS_MAGICK -eq 1 && -f "$PLACEHOLDER" ]] && \
                    make_cover_round_smart "$PLACEHOLDER" "$COVER_FILE" "crop"
                rm -f "$CACHE_FILE" "$POS_FILE" "$RAW_CACHE_FILE"
            fi
        fi
        return 0
    fi

    local ARTIST TITLE STATUS ART_URL POS RAW_POS RAW_LEN PLAYER
    IFS="$delim" read -r ARTIST TITLE STATUS ART_URL POS RAW_POS RAW_LEN PLAYER <<< "$DATA"

    [[ -z "$STATUS" || "$STATUS" == "null" ]] && STATUS="Unknown"

    local RAW_SONG="$ARTIST|$TITLE|$STATUS|$ART_URL"
    local LAST_RAW=""
    [[ -f "$RAW_CACHE_FILE" ]] && LAST_RAW=$(cat "$RAW_CACHE_FILE" 2>/dev/null)

    [[ -z "$RAW_LEN" || "$RAW_LEN" == "null" ]] && RAW_LEN=0
    [[ -z "$RAW_POS" || "$RAW_POS" == "null" ]] && RAW_POS=0

    printf "%s" "$POS|$RAW_POS|$RAW_LEN" > "${POS_FILE}.tmp" && \
        mv -f "${POS_FILE}.tmp" "$POS_FILE"

    if [[ "$RAW_SONG" == "$LAST_RAW" ]]; then
        return 0
    fi
    printf "%s" "$RAW_SONG" > "${RAW_CACHE_FILE}"

    if [[ -z "$ARTIST" || "$ARTIST" == "null" ]]; then
        if [[ "$TITLE" == *" - "* ]]; then
            ARTIST="${TITLE%% - *}"
            TITLE="${TITLE#* - }"
        fi
    fi

    local is_tv=0
    if [[ "$PLAYER" == *"vlc"* || "$PLAYER" == *"mpv"* || \
          "$PLAYER" == *"chromium"* || "$PLAYER" == *"firefox"* ]]; then
        if   [[ "$TITLE" == *"Joyn"*  || "$ARTIST" == *"Joyn"*  ]]; then is_tv=1
        elif [[ "$TITLE" == *"Vavoo"* || "$ARTIST" == *"Vavoo"* ]]; then is_tv=2
        else is_tv=3; fi
    fi

    local RAW_TITLE_FOR_TV="$TITLE"

    ARTIST=$(clean_yt_title "$ARTIST")
    TITLE=$(clean_yt_title "$TITLE")

    local CUR_SONG="$ARTIST|$TITLE|$STATUS"
    local CUR_META="$ARTIST|$TITLE"
    
    local LAST_SONG=""
    local LAST_META=""
    if [[ -f "$CACHE_FILE" ]]; then
        LAST_SONG=$(cat "$CACHE_FILE" 2>/dev/null)
        LAST_META="${LAST_SONG%|*}"
    fi

    if [[ "$CUR_META" != "$LAST_META" ]]; then
        if [[ "$COVER_ART" == "true" && $HAS_MAGICK -eq 1 ]]; then
            local success=0
            if [[ "$ART_URL" == file://* ]]; then
                local fix_url="${ART_URL#file://}"
                fix_url=$(printf "%b" "${fix_url//%/\\x}")
                make_cover_round_smart "$fix_url" "$COVER_FILE" "crop" && success=1
            elif [[ "$ART_URL" == http* ]]; then
                perform_download "$ART_URL" "crop" && success=1
            elif [[ $is_tv -gt 0 ]]; then
                local tv_title
                tv_title=$(clean_tv_title "$RAW_TITLE_FOR_TV")
                download_universal_tv_logo "$tv_title" "pad" && success=1
            fi
            if [[ $success -eq 0 ]]; then
                download_deezer_cover       "$ARTIST" "$TITLE" && success=1
                [[ $success -eq 0 ]] && download_itunes_cover      "$ARTIST" "$TITLE" && success=1
                [[ $success -eq 0 ]] && download_musicbrainz_cover "$ARTIST" "$TITLE" && success=1
            fi
            [[ $success -eq 0 && -f "$PLACEHOLDER" ]] && \
                make_cover_round_smart "$PLACEHOLDER" "$COVER_FILE" "crop"
        fi
    fi

    if [[ "$LAST_SONG" != "$CUR_SONG" ]]; then
        printf "%s" "$CUR_SONG" > "${CACHE_FILE}.tmp" && mv -f "${CACHE_FILE}.tmp" "$CACHE_FILE"
    fi
}

main "$@"
exit 0
