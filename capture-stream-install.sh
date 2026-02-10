#!/bin/bash
# Capture Stream Installer — requires bash 4+
# Installs to ~/.local (no sudo required for base install)
# GUI via zenity or kdialog if available, falls back to terminal

set -euo pipefail
trap 'gui_error "Installation failed unexpectedly.\nCheck terminal output for details."' ERR

APP_NAME="capture-stream"
APP_LABEL="Capture Stream"
INSTALL_DIR="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# GUI abstraction — zenity, kdialog, or terminal
# ---------------------------------------------------------------------------

GUI=""
if [[ ! -t 0 ]]; then
    if command -v zenity &>/dev/null; then
        GUI="zenity"
    elif command -v kdialog &>/dev/null; then
        GUI="kdialog"
    fi
fi

gui_info() {
    case "$GUI" in
        zenity)   zenity --info --title="$APP_LABEL" --text="$1" --width=400 2>/dev/null ;;
        kdialog)  kdialog --title "$APP_LABEL" --msgbox "$1" 2>/dev/null ;;
        *)        printf "${GREEN}[+]${NC} %b\n" "$1" ;;
    esac
}

gui_error() {
    case "$GUI" in
        zenity)   zenity --error --title="$APP_LABEL" --text="$1" --width=400 2>/dev/null ;;
        kdialog)  kdialog --title "$APP_LABEL" --error "$1" 2>/dev/null ;;
        *)        printf "${RED}[✗]${NC} %b\n" "$1" ;;
    esac
}

gui_confirm() {
    case "$GUI" in
        zenity)   zenity --question --title="$APP_LABEL" --text="$1" --width=400 2>/dev/null ;;
        kdialog)  kdialog --title "$APP_LABEL" --yesno "$1" 2>/dev/null ;;
        *)        printf "%b\n" "$1"; read -rp "[y/N] " ans; [[ "$ans" =~ ^[Yy]$ ]] ;;
    esac
}

gui_action() {
    case "$GUI" in
        zenity)
            zenity --list --title="$APP_LABEL" --text="Choose an action:" \
                --column="Action" --column="Description" \
                "install" "Install $APP_LABEL" \
                "uninstall" "Remove $APP_LABEL and config" \
                --width=400 --height=250 2>/dev/null
            ;;
        kdialog)
            kdialog --title "$APP_LABEL" --menu "Choose an action:" \
                "install" "Install $APP_LABEL" \
                "uninstall" "Remove $APP_LABEL and config" 2>/dev/null
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Distro detection
# ---------------------------------------------------------------------------

get_distro_family() {
    local ids=""
    [[ -f /etc/os-release ]] && . /etc/os-release
    ids="${ID:-} ${ID_LIKE:-}"

    for id in $ids; do
        case "$id" in
            fedora)                echo "fedora"; return ;;
            ubuntu|debian)         echo "debian"; return ;;
            arch)                  echo "arch"; return ;;
            opensuse*|suse)        echo "suse"; return ;;
        esac
    done
    echo ""
}

get_install_cmd() {
    case "$(get_distro_family)" in
        fedora) echo "sudo dnf install" ;;
        debian) echo "sudo apt install" ;;
        arch)   echo "sudo pacman -S" ;;
        suse)   echo "sudo zypper install" ;;
        *)      echo "" ;;
    esac
}

get_pkg_name() {
    local cmd="$1"
    local family
    family=$(get_distro_family)
    case "$cmd:$family" in
        pactl:arch)            echo "libpulse" ;;
        pactl:*)               echo "pulseaudio-utils" ;;
        qdbus:fedora)          echo "qt6-qttools" ;;
        qdbus:debian)          echo "qdbus-qt6" ;;
        qdbus:arch)            echo "qt6-tools" ;;
        qdbus:suse)            echo "qt6-tools-qdbus" ;;
        python3-gi:debian)     echo "python3-gi" ;;
        python3-gi:arch)       echo "python-gobject" ;;
        python3-gi:*)          echo "python3-gobject" ;;
        v4l2-ctl:*)            echo "v4l-utils" ;;
        vlc:*)                 echo "vlc" ;;
        arecord:*)             echo "alsa-utils" ;;
        python3:*)             echo "python3" ;;
        wmctrl:*)              echo "wmctrl" ;;
        *)                     echo "$cmd" ;;
    esac
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

check_deps() {
    local missing=()
    local missing_pkgs=()

    local cmds=(v4l2-ctl vlc arecord pactl python3)

    local session_type="${XDG_SESSION_TYPE:-}"
    local desktop="${XDG_CURRENT_DESKTOP:-}"

    case "${session_type,,}:${desktop^^}" in
        wayland:*KDE*)
            cmds+=(qdbus)
            ;;
        x11:*)
            cmds+=(wmctrl)
            ;;
    esac

    for cmd in "${cmds[@]}"; do
        if [[ "$cmd" == "qdbus" ]]; then
            if ! command -v qdbus-qt6 &>/dev/null && \
               ! command -v qdbus6 &>/dev/null && \
               ! command -v qdbus &>/dev/null; then
                missing+=("qdbus-qt6/qdbus6")
                missing_pkgs+=("$(get_pkg_name qdbus)")
            fi
        elif ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
            missing_pkgs+=("$(get_pkg_name "$cmd")")
        fi
    done

    if command -v python3 &>/dev/null; then
        if ! python3 -c "import gi; gi.require_version('Gtk', '3.0')" 2>/dev/null; then
            missing+=("python3-gi (GTK3)")
            missing_pkgs+=("$(get_pkg_name python3-gi)")
        fi
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        local unique_pkgs=()
        mapfile -t unique_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | sort -u)
        local install_cmd
        install_cmd=$(get_install_cmd)

        local msg="Missing dependencies:\n"
        for m in "${missing[@]}"; do
            msg+="  • $m\n"
        done

        local full_cmd=""
        if [[ -n "$install_cmd" ]]; then
            full_cmd="$install_cmd ${unique_pkgs[*]}"
            msg+="\nInstall with:\n$full_cmd"
        else
            msg+="\nPackages needed: ${unique_pkgs[*]}"
        fi
        msg+="\n\nInstall dependencies and try again."

        gui_error "$msg"
        if [[ -n "$full_cmd" ]]; then
            printf "%s\n" "$full_cmd"
        fi
        exit 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

install() {
    if [[ ! -f "$SCRIPT_DIR/capture-stream.py" ]]; then
        gui_error "capture-stream.py not found in $SCRIPT_DIR\n\nMake sure capture-stream.py is in the same directory as the installer."
        exit 1
    fi

    mkdir -p "$INSTALL_DIR" "$DESKTOP_DIR"

    cp "$SCRIPT_DIR/capture-stream.py" "$INSTALL_DIR/$APP_NAME"
    chmod +x "$INSTALL_DIR/$APP_NAME"

    if [[ ! -x "$INSTALL_DIR/$APP_NAME" ]]; then
        gui_error "Failed to install $APP_NAME to $INSTALL_DIR.\nCheck directory permissions."
        exit 1
    fi

    cat > "$DESKTOP_DIR/$APP_NAME.desktop" << EOF
[Desktop Entry]
Name=Capture Stream
Comment=Low-latency capture card viewer
Exec=$INSTALL_DIR/$APP_NAME
Icon=camera-video
Terminal=false
Type=Application
Categories=AudioVideo;Video;
Keywords=capture;card;v4l2;vlc;hdmi;
EOF

    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    kbuildsycoca6 --noincremental 2>/dev/null || true

    local path_note=""
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        path_note="\n\n⚠ $INSTALL_DIR is not in PATH\nAdd to your shell profile:\nexport PATH=\"\$HOME/.local/bin:\$PATH\""
    fi

    gui_info "Installed successfully!\n\n• $INSTALL_DIR/$APP_NAME\n• Desktop menu entry created\n• Config: ~/.config/capture-stream/$path_note"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

uninstall() {
    if ! gui_confirm "Remove $APP_LABEL?\n\nThis will delete:\n• $INSTALL_DIR/$APP_NAME\n• Desktop menu entry\n• Config in ~/.config/capture-stream"; then
        exit 0
    fi

    rm -f "$INSTALL_DIR/$APP_NAME"
    rm -f "$DESKTOP_DIR/$APP_NAME.desktop"
    rm -rf "$HOME/.config/capture-stream"

    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    kbuildsycoca6 --noincremental 2>/dev/null || true

    gui_info "$APP_LABEL has been removed."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${1:-}" in
    --uninstall)
        uninstall
        ;;
    "")
        if [[ -n "$GUI" ]]; then
            action=$(gui_action)
            case "$action" in
                install)   check_deps; install ;;
                uninstall) uninstall ;;
                *)         exit 0 ;;
            esac
        else
            check_deps
            install
        fi
        ;;
    *)
        printf "${RED}[✗]${NC} Unknown option: %s\n" "$1"
        echo "Usage: $0 [--uninstall]"
        exit 1
        ;;
esac
