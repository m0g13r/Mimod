#!/bin/bash
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/config" 2>/dev/null || true
PATHS=()
NAMES=()
for i in 1 2 3 4; do
    path_var="MOUNT_PATH_$i"
    name_var="MOUNT_NAME_$i"
    p="${!path_var}"
    n="${!name_var}"
    if [[ -n "$p" && -d "$p" ]]; then
        PATHS+=("$p")
        NAMES+=("${n:-${p##*/}}")
    fi
done
if [[ ${#PATHS[@]} -eq 0 ]]; then
    PATHS=("/home")
    NAMES=("home")
fi
if (( ${#PATHS[@]} < 4 )); then
    if command -v findmnt >/dev/null 2>&1; then
        readarray -t MOUNT_LIST < <(findmnt -rno TARGET 2>/dev/null \
            | grep -E '^(/media/|/run/media/|/mnt/.+)' \
            | head -n $(( 4 - ${#PATHS[@]} )))
    else
        readarray -t MOUNT_LIST < <(awk \
            '$2 ~ /^(\/media\/|\/run\/media\/|\/mnt\/.+)/ {print $2}' \
            /proc/mounts 2>/dev/null | head -n $(( 4 - ${#PATHS[@]} )))
    fi
    for mnt in "${MOUNT_LIST[@]}"; do
        PATHS+=("$mnt")
        NAMES+=("${mnt##*/}")
    done
fi
while (( ${#PATHS[@]} < 4 )); do
    PATHS+=("/dev/null")
    NAMES+=("N/A")
done
for p in "${PATHS[@]:0:4}"; do printf "%s\n" "$p"; done
for n in "${NAMES[@]:0:4}"; do printf "%s\n" "${n:0:5}"; done
exit 0
