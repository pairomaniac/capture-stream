# VLC Capture Script for easier Discord sharing

A Bash script to make Discord capture card streaming easier on Linux, since the built-in functionality is broken. Only tested with Elgato HD60 X - check **Adapting for Other Capture Cards** for other uses.

## Features

- Resolution selection (1080p/1440p at 60fps)
- HDR to SDR tone mapping adjustment (stock picture from hardware tone mapping was pretty dim)
- Automatic KDE window rule creation (borderless, always-below, custom positioning)

## Requirements

### System
- **OS**: Linux (tested on Fedora 43)
- **Desktop Environment**: KDE Plasma 6.0 or later
- **Display Protocol**: Wayland or X11

### Hardware
- Elgato HD60 X capture card (or other compatible V4L2 capture devices)

### Software Dependencies

**In addition to KDE Plasma 6, you must install:**
```bash
sudo dnf install v4l-utils zenity vlc
```

## Installation

1. Make the script executable:
```bash
chmod +x capture-stream.sh
```

2. (Optional) Move to your local bin directory:
```bash
mkdir -p ~/.local/bin
cp capture-stream.sh ~/.local/bin/
```

3. (Optional) Create a desktop entry for launcher integration:
```bash
cat > ~/.local/share/applications/capture-stream.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Capture Stream
Comment=Elgato Capture Feed
Exec=/home/YOUR_USERNAME/.local/bin/capture-stream.sh
Icon=camera-video
Terminal=false
Categories=AudioVideo;Video;
EOF
```

Replace `YOUR_USERNAME` with your actual username, then:
```bash
chmod +x ~/.local/share/applications/capture-stream.desktop
kbuildsycoca6
```

## Usage

### First Run

On first launch, you'll be prompted to set the window position (X and Y offset in pixels). This determines where the capture window appears on your screen.

The script will automatically create KDE window rules for 1080p and 1440p capture streams with:
- No window borders or titlebar
- Always below other windows
- Fixed size matching capture resolution
- Custom position

### Normal Usage

1. Connect your capture card
2. Run the script (from terminal or application launcher)
3. Select your capture settings:
   - **Resolution**: 1080p (1920x1080) or 1440p (2560x1440)
   - **Color Space**: SDR (standard) or HDR (brightness boost for HDR content)
4. VLC will open with your capture feed
5. Share the VLC window in Discord via screen share

## Adapting for Other Capture Cards

To use this script with a different capture card, you only need to change one line.

### Find Your Device Name

**Video device:**
```bash
v4l2-ctl --list-devices
```

**Audio device:**
```bash
arecord -l
```

Look for your capture card's name in the output.

### Modify the Script

Edit the `DEVICE_NAME` variable near the top of the script:
```bash
# Original (Elgato HD60 X):
DEVICE_NAME="Elgato HD60 X"
```

The script will automatically detect video and audio devices matching this name.

### Check Supported Resolutions

Different capture cards support different resolutions and formats:
```bash
v4l2-ctl -d /dev/video0 --list-formats-ext
```

**You may need to adjust the resolution options in the script's dialog and `--v4l2-chroma` parameter based on your device's capabilities.**

## Configuration

Window rules can be modified after creation via:
**System Settings → Window Management → Window Rules**

Look for rules named:
- "Capture Stream 1080p"
- "Capture Stream 1440p"

HDR brightness adjustment values are hardcoded:
- Contrast: 1.15
- Brightness: 1.1

To modify, edit the script and change the values in the HDR section:
```bash
COLOR_ADJUST="--video-filter=adjust --contrast=1.15 --brightness=1.1"
```

## Limitations

- **HDR Capture**: HDR passthrough not available on Linux to my knowledge
- **Audio Latency**: Configured for 20ms buffering. Adjust `--live-caching`, `--v4l2-caching`, and `--alsa-caching` values if needed
- **DPI Scaling**: When using desktop scaling above 100%, the window might be larger than expected
