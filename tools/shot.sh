#!/bin/sh
# Renders one frame with the real Forward+ renderer on a machine without a GPU
# (Mesa lavapipe under Xvfb). Usage: tools/shot.sh out.png [game flags...]
# Example: tools/shot.sh /tmp/a.png --frames 1500 --seed 3 --at 400 --cam chase
out=$1; shift
export VK_ICD_FILENAMES=${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}
exec xvfb-run -a -s "-screen 0 1920x1080x24" ${GODOT:-godot} --path "$(dirname "$0")/.." --fixed-fps 60 --resolution ${RES:-1280x720} -- --shot "$out" "$@"
