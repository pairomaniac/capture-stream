#!/bin/bash
# VLC Capture Stream - Low-latency capture card viewer for Linux/KDE
# https://github.com/pairomaniac/vlc-capture-stream

CONFIG_FILE="$HOME/.config/capture-stream/config"
RULE_ID=""

die() { zenity --error --text="$1"; exit 1; }

check_dependencies() {
    local missing=()
    for cmd in v4l2-ctl vlc zenity arecord kwriteconfig6; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -gt 0 ]] && die "Missing: ${missing[*]}"
}

# --- KDE Window Rules ---
# Creates temporary rules for borderless, always-below windows
# Rules are automatically cleaned up when the script exits

kw() { kwriteconfig6 --file ~/.config/kwinrulesrc --group "$@"; }
kr() { kreadconfig6 --file ~/.config/kwinrulesrc --group "$@" 2>/dev/null; }

create_window_rule() {
    local title="$1" width="$2" height="$3"
    RULE_ID="capture-stream-$$"

    # Window matching
    kw "$RULE_ID" --key "Description" "$title"
    kw "$RULE_ID" --key "wmclass" "vlc"
    kw "$RULE_ID" --key "wmclassmatch" "1"
    kw "$RULE_ID" --key "title" "$title"
    kw "$RULE_ID" --key "titlematch" "2"

    # Position and size (top-left corner)
    kw "$RULE_ID" --key "position" "0,0"
    kw "$RULE_ID" --key "positionrule" "2"
    kw "$RULE_ID" --key "size" "$width,$height"
    kw "$RULE_ID" --key "sizerule" "2"

    # Always below other windows, no borders
    kw "$RULE_ID" --key "below" "true"
    kw "$RULE_ID" --key "belowrule" "2"
    kw "$RULE_ID" --key "noborder" "true"
    kw "$RULE_ID" --key "noborderrule" "2"

    # Register rule with KWin
    local existing=$(kr "General" --key "rules")
    kw "General" --key "rules" "${existing:+$existing,}$RULE_ID"
    kw "General" --key "count" "$(($(kr "General" --key "count" || echo 0) + 1))"

    qdbus-qt6 org.kde.KWin /KWin reconfigure 2>/dev/null
}

remove_window_rule() {
    [[ -z "$RULE_ID" ]] && return

    # Remove rule group from config
    sed -i "/^\[${RULE_ID}\]$/,/^\[/{ /^\[${RULE_ID}\]$/d; /^\[/!d; }" ~/.config/kwinrulesrc

    # Update rules list
    local existing=$(kr "General" --key "rules")
    kw "General" --key "rules" "$(echo "$existing" | sed "s/,${RULE_ID}//g; s/${RULE_ID},//g; s/^${RULE_ID}$//g")"

    local count=$(kr "General" --key "count")
    [[ $count -gt 0 ]] && kw "General" --key "count" "$((count - 1))"

    qdbus-qt6 org.kde.KWin /KWin reconfigure 2>/dev/null
}

# Cleanup rule on exit, interrupt, or termination
trap remove_window_rule EXIT INT TERM

# --- Device Discovery ---
# Automatically detects V4L2 video devices and ALSA capture card audio

get_video_devices() {
    v4l2-ctl --list-devices 2>/dev/null | awk '
        /^[^ \t]/ { if (d && p) print d"|"p; d=$0; sub(/:$/,"",d); p="" }
        /\/dev\/video/ && !p { p=$1 }
        END { if (d && p) print d"|"p }' | sort -u
}

get_audio_devices() {
    # Filter for common capture card identifiers
    arecord -l 2>/dev/null | awk '
        /^card [0-9]+:/ && /[Cc]apture|[Ee]lgato|[Aa]ver|[Mm]agewell|[Bb]lackmagic|HDMI.*In|SDI/ {
            match($0, /card ([0-9]+):/, c); match($0, /\[([^\]]+)\]/, n)
            if (c[1] != "" && n[1] != "") print n[1]"|hw:"c[1]",0"
        }' | sort -u
}

# --- Format/Mode Detection ---
# Queries device capabilities and filters to supported resolutions/framerates

get_modes() {
    v4l2-ctl -d "$1" --list-formats-ext 2>/dev/null | awk -v fmt="$2" '
        /'\''[A-Z0-9]+'\''/ { match($0,/'\''[A-Z0-9]+'\''/); f=substr($0,RSTART+1,RLENGTH-2) }
        /Size: Discrete/ && f==fmt { for(i=1;i<=NF;i++) if($i~/^[0-9]+x[0-9]+$/) res=$i }
        /Interval:.*fps/ && f==fmt && res {
            match($0,/[0-9]+\.[0-9]+ fps/); fps=int(substr($0,RSTART,RLENGTH))
            if ((res=="3840x2160" || res=="2560x1440" || res=="1920x1080" || res=="1280x720") && \
                (fps==25 || fps==30 || fps==50 || fps==60))
                print res"|"fps
        }' | sort -u
}

get_format() {
    v4l2-ctl -d "$1" --list-formats-ext 2>/dev/null | awk '
        /'\''[A-Z0-9]+'\''/ { match($0,/'\''[A-Z0-9]+'\''/); f[substr($0,RSTART+1,RLENGTH-2)] }
        END { for(x in f) print x }'
}

# --- Latency Calculation ---
# 4K requires more buffer; extra buffer option for problematic setups

get_latency() {
    local res="$1" extra="$2"
    local base=20
    [[ "$res" == "3840x2160" ]] && base=40
    [[ "$extra" == "TRUE" ]] && base=$((base + 20))
    echo $base
}

# Put saved value first in dropdown list
prioritize() {
    local saved="$1" list="$2"
    [[ -z "$saved" ]] && { echo "$list"; return; }
    local filtered=$(echo "$list" | tr '|' '\n' | grep -vx "$saved" | paste -sd'|')
    echo "$saved${filtered:+|$filtered}"
}

# --- Configuration ---
# Saves/loads user preferences to ~/.config/capture-stream/config

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        mkdir -p "${CONFIG_FILE%/*}"
        SAVED_VIDEO_DEVICE="" SAVED_AUDIO_DEVICE="" SAVED_RESOLUTION=""
        SAVED_COLOR_SPACE="SDR" SAVED_FORMAT="NV12" SAVED_EXTRA_BUFFER="FALSE"
        save_config
    fi
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
SAVED_VIDEO_DEVICE="$SAVED_VIDEO_DEVICE"
SAVED_AUDIO_DEVICE="$SAVED_AUDIO_DEVICE"
SAVED_RESOLUTION="$SAVED_RESOLUTION"
SAVED_COLOR_SPACE="$SAVED_COLOR_SPACE"
SAVED_FORMAT="$SAVED_FORMAT"
SAVED_EXTRA_BUFFER="$SAVED_EXTRA_BUFFER"
EOF
}

# --- Main ---

check_dependencies
load_config

# Detect available devices
video_devices=$(get_video_devices); [[ -z "$video_devices" ]] && die "No video devices found!"
audio_devices=$(get_audio_devices); [[ -z "$audio_devices" ]] && die "No capture card audio devices found!"

# Build dropdown lists
video_names=$(cut -d'|' -f1 <<< "$video_devices" | paste -sd'|')
audio_names=$(cut -d'|' -f1 <<< "$audio_devices" | paste -sd'|')

saved_video_name=$(grep "|${SAVED_VIDEO_DEVICE}$" <<< "$video_devices" 2>/dev/null | cut -d'|' -f1)
saved_audio_name=$(grep "|${SAVED_AUDIO_DEVICE}$" <<< "$audio_devices" 2>/dev/null | cut -d'|' -f1)

# Get supported modes for default/saved device
default_video=${SAVED_VIDEO_DEVICE:-$(echo "$video_devices" | head -1 | cut -d'|' -f2)}
format="$SAVED_FORMAT"
available_formats=$(get_format "$default_video")
grep -q "^${format}$" <<< "$available_formats" || format=$(head -1 <<< "$available_formats")

modes=$(get_modes "$default_video" "$format")
[[ -z "$modes" ]] && die "No supported modes found!"

resolutions=$(echo "$modes" | cut -d'|' -f1 | sort -t'x' -k1 -rn | uniq)

# Main settings dialog
result=$(zenity --forms --title="Capture Stream" \
    --text="Capture Settings\n<small><i>Enable extra buffer if you experience stuttering</i></small>" \
    --separator="|" \
    --add-combo="Video Device:" --combo-values="$(prioritize "$saved_video_name" "$video_names")" \
    --add-combo="Audio Device:" --combo-values="$(prioritize "$saved_audio_name" "$audio_names")" \
    --add-combo="Resolution:" --combo-values="$(prioritize "$SAVED_RESOLUTION" "$(echo "$resolutions" | paste -sd'|')")" \
    --add-combo="Color Space:" --combo-values="$(prioritize "$SAVED_COLOR_SPACE" "SDR|HDR")" \
    --add-combo="Extra Buffer:" --combo-values="$(prioritize "$SAVED_EXTRA_BUFFER" "FALSE|TRUE")" \
    --ok-label="Next" --cancel-label="Quit") || exit 0

IFS='|' read -r sel_video_name sel_audio_name RESOLUTION COLOR_SPACE EXTRA_BUFFER <<< "$result"

# Resolve device paths from display names
VIDEO_DEVICE=$(grep -m1 "^${sel_video_name}|" <<< "$video_devices" | cut -d'|' -f2)
AUDIO_DEVICE=$(grep -m1 "^${sel_audio_name}|" <<< "$audio_devices" | cut -d'|' -f2)
[[ -z "$VIDEO_DEVICE" || -z "$AUDIO_DEVICE" ]] && die "Device not found!"

RESOLUTION=${RESOLUTION:-$(head -1 <<< "$resolutions")}
COLOR_SPACE=${COLOR_SPACE:-SDR}
EXTRA_BUFFER=${EXTRA_BUFFER:-FALSE}

# FPS selection (only valid rates for chosen resolution)
fps_options=$(echo "$modes" | awk -F'|' -v r="$RESOLUTION" '$1==r {print $2}' | sort -rn | uniq)
fps_count=$(echo "$fps_options" | wc -l)

if [[ $fps_count -eq 1 ]]; then
    FPS=$(echo "$fps_options" | head -1)
else
    FPS=$(zenity --list --title="Select Framerate" --text="Available framerates for $RESOLUTION:" \
        --column="FPS" $fps_options --ok-label="Start Stream" --cancel-label="Back") || exec "$0"
fi

LATENCY=$(get_latency "$RESOLUTION" "$EXTRA_BUFFER")

# Save settings for next run
SAVED_VIDEO_DEVICE="$VIDEO_DEVICE" SAVED_AUDIO_DEVICE="$AUDIO_DEVICE"
SAVED_RESOLUTION="$RESOLUTION" SAVED_COLOR_SPACE="$COLOR_SPACE" SAVED_EXTRA_BUFFER="$EXTRA_BUFFER"
save_config

# Prepare VLC options
WIDTH=${RESOLUTION%x*}; HEIGHT=${RESOLUTION#*x}
COLOR_ADJUST=""; [[ "$COLOR_SPACE" == "HDR" ]] && COLOR_ADJUST="--video-filter=adjust --contrast=1.15 --brightness=1.1"
TITLE="Capture Stream $RESOLUTION"

# Create window rule and clear VLC's cached geometry
create_window_rule "$TITLE" "$WIDTH" "$HEIGHT"
rm -f ~/.config/vlc/vlc-qt-interface.conf

# Launch VLC with capture settings
vlc v4l2://$VIDEO_DEVICE \
    --v4l2-width=$WIDTH --v4l2-height=$HEIGHT --v4l2-fps=$FPS --v4l2-chroma=$format \
    $COLOR_ADJUST :input-slave=alsa://$AUDIO_DEVICE :live-caching=$LATENCY \
    --aout=pulse --qt-minimal-view --meta-title="$TITLE"
