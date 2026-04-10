#!/bin/bash
PATHS=("/home")
NAMES=("home")

if command -v findmnt >/dev/null 2>&1; then
    readarray -t MOUNT_LIST < <(findmnt -rno TARGET 2>/dev/null \
        | grep -E '^(/media/|/run/media/|/mnt/.+)' \
        | head -n 3)
else
    readarray -t MOUNT_LIST < <(awk '$2 ~ /^(\/media\/|\/run\/media\/|\/mnt\/.+)/ {print $2}' \
        /proc/mounts 2>/dev/null | head -n 3)
fi

for mnt in "${MOUNT_LIST[@]}"; do
    PATHS+=("$mnt")
    NAMES+=("${mnt##*/}")
done

while [[ ${#PATHS[@]} -lt 4 ]]; do
    PATHS+=("/dev/null")
    NAMES+=("N/A")
done

for p in "${PATHS[@]:0:4}"; do printf "%s\n" "$p"; done
for n in "${NAMES[@]:0:4}"; do printf "%s\n" "${n:0:5}"; done
exit 0
