#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
[[ -f "$SCRIPT_DIR/config" ]] && source "$SCRIPT_DIR/config"
get_mounts(){
local -a PATHS=() NAMES=()
local i p_var n_var p n mnt needed
for i in {1..4};do
p_var="MOUNT_PATH_$i";n_var="MOUNT_NAME_$i";p="${!p_var:-}";n="${!n_var:-}"
[[ -n "$p" && "$p" != "/dev/null" && -d "$p" ]] && { PATHS+=("$p"); NAMES+=("${n:-${p##*/}}"); }
done
[[ ${#PATHS[@]} -eq 0 ]] && { PATHS+=("/home"); NAMES+=("home"); }
needed=$((4-${#PATHS[@]}))
if ((needed>0));then
local -a MOUNT_LIST=()
if command -v findmnt &>/dev/null;then
readarray -t MOUNT_LIST < <(findmnt -rno TARGET 2>/dev/null|awk '$1~/^(\/media\/|\/run\/media\/|\/mnt\/.+)/{print $1}'|head -n "$needed"||true)
else
readarray -t MOUNT_LIST < <(awk -v n="$needed" '$2~/^(\/media\/|\/run\/media\/|\/mnt\/.+)/{print $2;if(++c==n)exit}' /proc/mounts 2>/dev/null||true)
fi
for mnt in "${MOUNT_LIST[@]+"${MOUNT_LIST[@]}"}";do
mnt="$(printf '%s' "$mnt")"
[[ -z "$mnt" || ! -d "$mnt" ]] && continue
PATHS+=("$mnt");NAMES+=("${mnt##*/}")
done
fi
while ((${#PATHS[@]}<4));do PATHS+=("/dev/null");NAMES+=("N/A");done
printf "%s\n" "${PATHS[@]:0:4}"
for n in "${NAMES[@]:0:4}";do printf "%s\n" "${n:0:5}";done
}
get_mounts
