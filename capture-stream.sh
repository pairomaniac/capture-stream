#!/bin/bash

# Check for required dependencies
check_dependencies() {
    local missing_deps=""

    if ! command -v v4l2-ctl &> /dev/null; then
        missing_deps="$missing_deps\n- v4l2-ctl (install: sudo dnf install v4l-utils)"
    fi

    if ! command -v zenity &> /dev/null; then
        missing_deps="$missing_deps\n- zenity (install: sudo dnf install zenity)"
    fi

    if ! command -v vlc &> /dev/null; then
        missing_deps="$missing_deps\n- vlc (install: sudo dnf install vlc)"
    fi

    # If any dependencies are missing, show error and exit
    if [ -n "$missing_deps" ]; then
        # Check if zenity itself is available for the GUI error
        if command -v zenity &> /dev/null; then
            zenity --error --text="Missing required dependencies:$missing_deps"
        else
            echo -e "Missing required dependencies:$missing_deps"
        fi
        exit 1
    fi
}

# Check dependencies before proceeding
check_dependencies

# Find capture device dynamically
DEVICE_NAME="Elgato HD60 X"
VIDEO_DEVICE=$(v4l2-ctl --list-devices 2>/dev/null | grep -A1 "$DEVICE_NAME" | grep "/dev/video" | head -n1 | tr -d '[:space:]')
AUDIO_ID=$(arecord -l | grep -i "$DEVICE_NAME" | head -n1 | sed -n 's/card \([0-9]\+\):.*/\1/p')
AUDIO_DEVICE="hw:$AUDIO_ID,0"

# Check if devices were found
if [ -z "$VIDEO_DEVICE" ]; then
    zenity --error --text="$DEVICE_NAME video device not found!"
    exit 1
fi

if [ -z "$AUDIO_ID" ]; then
    zenity --error --text="$DEVICE_NAME audio device not found!"
    exit 1
fi

# Function to check if window rule exists
rule_exists() {
    grep -q "Description=$1" ~/.config/kwinrulesrc 2>/dev/null
}

# Function to create window rule
create_rule() {
    local title=$1
    local width=$2
    local height=$3
    local pos_x=$4
    local pos_y=$5
    local rule_name=$6

    kwriteconfig6 --file ~/.config/kwinrulesrc --group "$rule_name" --key "Description" "$title"
    kwriteconfig6 --file ~/.config/kwinrulesrc --group "$rule_name" --key "wmclass" "vlc"
    kwriteconfig6 --file ~/.config/kwinrulesrc --group "$rule_name" --key "wmclassmatch" "1"
    kwriteconfig6 --file ~/.config/kwinrulesrc --group "$rule_name" --key "title" "$title"
    kwriteconfig6 --file ~/.config/kwinrulesrc --group "$rule_name" --key "titlematch" "2"
    kwriteconfig6 --file ~/.config/kwinrulesrc --group "$rule_name" --key "position" "$pos_x,$pos_y"
    kwriteconfig6 --file ~/.config/kwinrulesrc --group "$rule_name" --key "positionrule" "2"
    kwriteconfig6 --file ~/.config/kwinrulesrc --group "$rule_name" --key "size" "$width,$height"
    kwriteconfig6 --file ~/.config/kwinrulesrc --group "$rule_name" --key "sizerule" "2"
    kwriteconfig6 --file ~/.config/kwinrulesrc --group "$rule_name" --key "below" "true"
    kwriteconfig6 --file ~/.config/kwinrulesrc --group "$rule_name" --key "belowrule" "2"
    kwriteconfig6 --file ~/.config/kwinrulesrc --group "$rule_name" --key "noborder" "true"
    kwriteconfig6 --file ~/.config/kwinrulesrc --group "$rule_name" --key "noborderrule" "2"
}

# Check if any rules are missing
if ! rule_exists "Capture Stream 1080p" || ! rule_exists "Capture Stream 1440p"; then
    # Prompt for position
    position_result=$(zenity --forms --title="Window Position Setup" \
        --text="Set window position (X and Y offset in pixels)\nYou can change this later in System Settings → Window Rules" \
        --add-entry="X Position:" \
        --add-entry="Y Position:")

    # Parse position values or use defaults
    POS_X=$(echo $position_result | cut -d'|' -f1)
    POS_Y=$(echo $position_result | cut -d'|' -f2)
    POS_X=${POS_X:-0}
    POS_Y=${POS_Y:-0}

    # Get current config state
    current_count=$(kreadconfig6 --file ~/.config/kwinrulesrc --group "General" --key "count" 2>/dev/null)
    current_count=${current_count:-0}
    current_rules=$(kreadconfig6 --file ~/.config/kwinrulesrc --group "General" --key "rules" 2>/dev/null)

    new_count=$current_count
    new_rule_ids=""

    # Create 1080p rule if missing
    if ! rule_exists "Capture Stream 1080p"; then
        create_rule "Capture Stream 1080p" "1920" "1080" "$POS_X" "$POS_Y" "Capture1080p"
        new_rule_ids="Capture1080p"
        new_count=$((new_count + 1))
    fi

    # Create 1440p rule if missing
    if ! rule_exists "Capture Stream 1440p"; then
        create_rule "Capture Stream 1440p" "2560" "1440" "$POS_X" "$POS_Y" "Capture1440p"
        if [ -z "$new_rule_ids" ]; then
            new_rule_ids="Capture1440p"
        else
            new_rule_ids="$new_rule_ids,Capture1440p"
        fi
        new_count=$((new_count + 1))
    fi

    # Update rules list
    if [ -z "$current_rules" ]; then
        new_rules="$new_rule_ids"
    else
        new_rules="$current_rules,$new_rule_ids"
    fi

    # Update config
    kwriteconfig6 --file ~/.config/kwinrulesrc --group "General" --key "count" "$new_count"
    kwriteconfig6 --file ~/.config/kwinrulesrc --group "General" --key "rules" "$new_rules"

    # Tell KWin to reload configuration
    qdbus-qt6 org.kde.KWin /KWin reconfigure 2>/dev/null
fi

# Show dialog for capture settings selection
result=$(zenity --forms --title="Capture Settings" \
    --text="Select capture configuration" \
    --add-combo="Resolution:" --combo-values="1080p|1440p" \
    --add-combo="Color Space:" --combo-values="SDR|HDR")

# Exit if user cancelled
if [ $? -ne 0 ]; then
    exit 0
fi

# Parse user selections (format: "resolution|colorspace")
resolution=$(echo $result | cut -d'|' -f1)
colorspace=$(echo $result | cut -d'|' -f2)

# Set resolution parameters based on selection
if [ "$resolution" = "1440p" ]; then
    WIDTH=2560
    HEIGHT=1440
    TITLE="Capture Stream 1440p"
else
    WIDTH=1920
    HEIGHT=1080
    TITLE="Capture Stream 1080p"
fi

# Set HDR color adjustment parameters based on selection
if [ "$colorspace" = "HDR" ]; then
    COLOR_ADJUST="--video-filter=adjust --contrast=1.15 --brightness=1.1"
else
    COLOR_ADJUST=""
fi

# Clear VLC's cached window geometry to ensure proper sizing
rm -f ~/.config/vlc/vlc-qt-interface.conf

# Launch VLC with selected parameters
vlc v4l2://$VIDEO_DEVICE --v4l2-width=$WIDTH --v4l2-height=$HEIGHT --v4l2-chroma=NV12 $COLOR_ADJUST :input-slave=alsa://$AUDIO_DEVICE :live-caching=20 --aout=pulse --qt-minimal-view --meta-title="$TITLE"
