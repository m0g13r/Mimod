#!/bin/bash
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
set -o allexport
source "$SCRIPT_DIR/config"
set +o allexport

CACHE_FILE="$HOME/.cache/weather.json"
mkdir -p "$(dirname "$CACHE_FILE")"
TEMP_FILE=$(mktemp "${CACHE_FILE}.XXXXXX")
CACHE_EXPIRATION=600
API_URL_BASE="https://api.openweathermap.org/data/2.5/weather?appid=$API_KEY"
UA=$(get_random_ua)

trap 'rm -f "$TEMP_FILE"' EXIT

json_get() {
    local json="$1" key="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r "${key} // empty" 2>/dev/null
    else
        python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    keys = '${key}'.lstrip('.').split('.')
    v = d
    for k in keys:
        v = v[k]
    print(v if v is not None else '')
except Exception:
    pass
" <<< "$json" 2>/dev/null
    fi
}

fetch_data() {
    curl -s --max-time 5 \
        -H 'Referer: https://google.com' \
        -H 'Accept-Language: en-US,en;q=0.9' \
        -A "$UA" "$1" 2>/dev/null \
    || wget -qO- -T 5 \
        --header='Referer: https://google.com' \
        --header='Accept-Language: en-US,en;q=0.9' \
        -U "$UA" "$1" 2>/dev/null
}

fetch_geo() {
    curl -s -4 --max-time 5 \
        -H 'Referer: https://google.com' \
        -H 'Accept-Language: en-US,en;q=0.9' \
        -A "$UA" "$1" 2>/dev/null \
    || wget -qO- -T 5 \
        --header='Referer: https://google.com' \
        --header='Accept-Language: en-US,en;q=0.9' \
        -U "$UA" "$1" 2>/dev/null
}

start_geoclue_agent() {
    local AGENT_PATH="/usr/lib/geoclue-2.0/demos/agent"
    if [[ -x "$AGENT_PATH" ]] && ! pgrep -f "$AGENT_PATH" >/dev/null; then
        "$AGENT_PATH" &>/dev/null &
        disown
    fi
}

GEOCLUE_CMD=""
for path in \
    "/usr/libexec/geoclue-2.0/demos/where-am-i" \
    "/usr/lib/geoclue-2.0/demos/where-am-i" \
    "/usr/bin/where-am-i"
do
    if [[ -x "$path" ]]; then
        GEOCLUE_CMD="$path"
        break
    fi
done

update_config() {
    local key="$1" value="$2"
    local config_file="$SCRIPT_DIR/config"
    [[ -f "$config_file" ]] || return
    local current_val
    current_val=$(grep "^${key}=" "$config_file" | cut -d'"' -f2)
    if [[ "$current_val" != "$value" ]]; then
        local safe_value="${value//|/\\|}"
        sed -i "s|^\(${key}=\).*$|\1\"${safe_value}\"|" "$config_file"
    fi
}

declare -A LANG_MAP=(
    ["DE"]="de" ["AT"]="de" ["CH"]="de" ["LI"]="de"
    ["FR"]="fr" ["BE"]="fr" ["LU"]="fr" ["CA"]="fr"
    ["IT"]="it" ["SM"]="it" ["VA"]="it"
    ["ES"]="es" ["MX"]="es" ["AR"]="ar" ["CO"]="es" ["CL"]="es" ["PE"]="es"
    ["PL"]="pl" ["CZ"]="cz" ["SK"]="sk" ["HU"]="hu" ["RO"]="ro"
    ["RU"]="ru" ["UA"]="ru" ["BY"]="ru"
    ["CN"]="zh_cn" ["TW"]="zh_tw" ["HK"]="zh_tw"
    ["JP"]="ja"  ["KR"]="kr"
    ["BD"]="bn"  ["IN"]="hi"
    ["TR"]="tr"  ["PT"]="pt" ["BR"]="pt"
    ["NL"]="nl"  ["SE"]="sv" ["NO"]="no" ["DK"]="da" ["FI"]="fi"
    ["GR"]="el"  ["EG"]="ar" ["SA"]="ar"
    ["IL"]="he"  ["VN"]="vi" ["TH"]="th" ["ID"]="id"
)

determine_locale() {
    local country="$1"
    local detected_lang="en"
    local detected_unit="metric"
    [[ -n "${LANG_MAP[$country]}" ]] && detected_lang="${LANG_MAP[$country]}"
    [[ "$country" == "US" ]]        && detected_unit="imperial"
    WEATHER_LANG="$detected_lang"
    UNIT="$detected_unit"
    export WEATHER_LANG UNIT
}

_valid_coord_re='^-?[0-9]+(\.[0-9]+)?$'

get_location_and_config() {
    local LAT="" LON="" COUNTRY=""

    if [[ -n "$GEOCLUE_CMD" ]]; then
        start_geoclue_agent
        local GEOCLUE_DATA
        GEOCLUE_DATA=$(timeout 3s "$GEOCLUE_CMD" --timeout=2 2>/dev/null)
        if [[ -n "$GEOCLUE_DATA" ]]; then
            LAT=$(printf "%s\n" "$GEOCLUE_DATA" | grep "Latitude:"  | cut -d: -f2 \
                | tr -d '[:space:]' | sed 's/[^0-9.-]//g')
            LON=$(printf "%s\n" "$GEOCLUE_DATA" | grep "Longitude:" | cut -d: -f2 \
                | tr -d '[:space:]' | sed 's/[^0-9.-]//g' | sed 's/\.$//')
        fi
    fi

    if [[ -z "$LAT" || "$LAT" == "null" ]]; then
        local GEO_PROVIDERS=(
            "https://ipapi.co/json|.latitude|.longitude|.country_code"
            "https://freeipapi.com/api/json|.latitude|.longitude|.countryCode"
            "http://ip-api.com/json|.lat|.lon|.countryCode"
            "https://ipinfo.io/json|.loc|.country"
        )
        local provider_entry provider_url LAT_PATH LON_PATH COUNTRY_PATH GEO_DATA
        for provider_entry in "${GEO_PROVIDERS[@]}"; do
            IFS='|' read -r provider_url LAT_PATH LON_PATH COUNTRY_PATH <<< "$provider_entry"
            GEO_DATA=$(fetch_geo "$provider_url")
            [[ -z "$GEO_DATA" ]] && continue
            if [[ "$LAT_PATH" == ".loc" ]]; then
                local LOC
                LOC=$(json_get "$GEO_DATA" ".loc")
                COUNTRY=$(json_get "$GEO_DATA" ".country")
                if [[ "$LOC" =~ ^(-?[0-9]+\.?[0-9]*),(-?[0-9]+\.?[0-9]*)$ ]]; then
                    LAT="${BASH_REMATCH[1]}"
                    LON="${BASH_REMATCH[2]}"
                fi
            else
                LAT=$(json_get "$GEO_DATA" "$LAT_PATH")
                LON=$(json_get "$GEO_DATA" "$LON_PATH")
                COUNTRY=$(json_get "$GEO_DATA" "$COUNTRY_PATH")
            fi
            if [[ -n "$LAT" && "$LAT" != "null" && "$LAT" =~ $_valid_coord_re ]] &&
               [[ -n "$LON" && "$LON" != "null" && "$LON" =~ $_valid_coord_re ]]; then
                break
            else
                LAT="" LON="" COUNTRY=""
            fi
        done
    fi

    if [[ -n "$LAT" && "$LAT" != "null" ]]; then
        local GEO_API_URL="${API_URL_BASE}&lat=$LAT&lon=$LON"
        if fetch_data "$GEO_API_URL" > "$TEMP_FILE"; then
            if [[ -s "$TEMP_FILE" ]]; then
                local CITY_ID_LOCAL COUNTRY_LOCAL
                if command -v jq &>/dev/null; then
                    CITY_ID_LOCAL=$(jq -r '.id // empty'         "$TEMP_FILE" 2>/dev/null)
                    COUNTRY_LOCAL=$(jq -r '.sys.country // empty' "$TEMP_FILE" 2>/dev/null)
                else
                    CITY_ID_LOCAL=$(grep -o '"id":[0-9]*'          "$TEMP_FILE" | head -1 | cut -d: -f2)
                    COUNTRY_LOCAL=$(grep -o '"country":"[^"]*"'     "$TEMP_FILE" | head -1 | cut -d'"' -f4)
                fi
                if [[ -n "$CITY_ID_LOCAL" && "$CITY_ID_LOCAL" != "null" && \
                      -n "$COUNTRY_LOCAL"  && "$COUNTRY_LOCAL"  != "null" ]]; then
                    COUNTRY="$COUNTRY_LOCAL"
                    determine_locale "$COUNTRY"
                    update_config "CITY_ID"      "$CITY_ID_LOCAL"
                    update_config "UNIT"         "$UNIT"
                    update_config "WEATHER_LANG" "$WEATHER_LANG"
                    export CITY_ID="$CITY_ID_LOCAL"
                    return 0
                fi
            fi
        fi
    fi
    return 1
}

if [[ -z "$CITY_ID" ]]; then
    get_location_and_config || exit 0
    : > "$TEMP_FILE"
fi

API_URL="${API_URL_BASE}&id=$CITY_ID&units=$UNIT&lang=$WEATHER_LANG"

if [[ ! -f "$CACHE_FILE" ]] || \
   (( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) > CACHE_EXPIRATION )); then
    if fetch_data "$API_URL" > "$TEMP_FILE"; then
        if [[ -s "$TEMP_FILE" ]]; then
            has_name=0; has_error=0
            if command -v jq &>/dev/null; then
                jq -e '.name' "$TEMP_FILE" >/dev/null 2>&1    && has_name=1
                grep -q '"cod":[4-5][0-9][0-9]' "$TEMP_FILE"  && has_error=1
            else
                grep -q '"name":"' "$TEMP_FILE"               && has_name=1
                grep -q '"cod":[4-5][0-9][0-9]' "$TEMP_FILE"  && has_error=1
            fi
            if (( has_name && !has_error )); then
                mv -f "$TEMP_FILE" "$CACHE_FILE"
            fi
        fi
    fi
fi

exit 0
