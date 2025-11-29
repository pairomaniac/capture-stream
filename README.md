# VLC Capture Stream

A Bash script for low-latency capture card streaming on Linux/KDE. Designed for sharing capture card output via Discord screen share, since Discord's built-in capture is broken on Linux.
<p float="left">
  <img src="https://github.com/user-attachments/assets/294310a4-d5e7-4a2d-ac44-b6654b89bffa" width="45%" />
  <img src="https://github.com/user-attachments/assets/b412e6f7-ede4-43a7-9f05-b931a76e3d12" width="45%" />
</p>

## Features

- **Auto device detection** - Automatically finds video and audio devices
- **Dynamic resolution/FPS** - Only shows modes your card actually supports
- **Temporary window rules** - Borderless, always-below window that cleans up on exit
- **HDR compensation** - Brightness boost for HDR sources (no true HDR passthrough on Linux)
- **Smart latency** - Auto-calculated buffer based on resolution, with manual override
- **Remembers settings** - Saves your preferences for next time

## Supported Capture Cards

Tested with Elgato HD60 X, but should work with any V4L2-compatible capture card:

- Elgato (HD60, 4K60, Cam Link, etc.)
- AVerMedia
- Magewell
- Blackmagic
- Most USB/PCIe capture cards with Linux drivers

## Requirements

- **OS:** Linux (tested on Fedora 41+)
- **Desktop:** KDE Plasma 6
- **Display:** Wayland or X11

### Dependencies
```bash
# Fedora
sudo dnf install v4l-utils zenity vlc

# Ubuntu/Debian
sudo apt install v4l-utils zenity vlc

# Arch
sudo pacman -S v4l-utils zenity vlc
```

## Installation

1. Download and make executable:
```bash
chmod +x capture-stream.sh
```

2. (Optional) Install to local bin:
```bash
mkdir -p ~/.local/bin
cp capture-stream.sh ~/.local/bin/
```

3. (Optional) Create desktop entry:
```bash
cat > ~/.local/share/applications/capture-stream.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Capture Stream
Comment=Capture Card Viewer
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

1. Connect your capture card
2. Run the script
3. Select your settings:
   - **Video Device** - Your capture card
   - **Audio Device** - Capture card audio input
   - **Resolution** - 720p / 1080p / 1440p / 4K (device-dependent)
   - **Color Space** - SDR or HDR (brightness boost)
   - **Extra Buffer** - Enable if experiencing stuttering
4. Select framerate (only valid options shown)
5. VLC opens with your capture feed
6. Share the VLC window in Discord

## Configuration

Settings are saved to `~/.config/capture-stream/config` and restored on next launch.

### Latency

Buffer is auto-calculated:
- **720p-1440p:** 20ms
- **4K:** 40ms
- **Extra Buffer:** +20ms

Enable "Extra Buffer" if you see stuttering or `buffer deadlock` errors.

### HDR Mode

HDR passthrough isn't available on Linux. The HDR option applies a brightness/contrast boost to compensate for dim HDR sources:
- Contrast: 1.15
- Brightness: 1.1

### Window Behavior

The script creates a temporary KDE window rule that:
- Removes window borders
- Positions at top-left (0,0)
- Sets window to always-below
- Matches exact capture resolution

The rule is automatically removed when VLC closes.

## Troubleshooting

### No video devices found
- Check if your capture card is connected: `v4l2-ctl --list-devices`
- Ensure drivers are loaded: `lsusb` or `lspci`

### No audio devices found
- Check ALSA devices: `arecord -l`
- The script filters for capture card audio; your card may need to be added to the filter

### Stuttering / Frame drops
- Enable "Extra Buffer" option
- Try a lower resolution or framerate
- Check USB bandwidth (use USB 3.0 port, avoid hubs)

### Window has borders / wrong size
- Ensure KDE Plasma 6 is running
- Check if `kwriteconfig6` and `qdbus-qt6` are available
- Try restarting KWin: `kwin_wayland --replace` or log out/in

## AI Disclaimer
This script was made with AI assistance.
