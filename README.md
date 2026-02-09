# Capture Stream

Low-latency capture card viewer for Linux. Opens your capture card in a borderless, always-below VLC window — useful for Discord screen sharing, since Discord's built-in capture is broken on Linux.

<p float="left">
  <img src="https://github.com/user-attachments/assets/833fe4cb-3ee8-423c-9eaf-feaa3556ec30" width="30%" />
</p>

## Features

- Auto-detects V4L2 video and ALSA audio devices
- Cascading dropdowns — device → format → resolution → FPS (filtered to Discord-supported values)
- Session-aware window rules (KDE Wayland, X11, Wayland fallback) with DPI scaling support
- Brightness/contrast sliders with SDR/HDR presets
- Latency slider (20–60 ms)
- Settings persist between sessions

## Supported Capture Cards

Tested with Elgato HD60 X, but works with any UVC-compatible capture card (Elgato, AVerMedia, Magewell, Blackmagic, etc). If your card's audio isn't detected by the known-device filter, all ALSA capture devices are shown as a fallback.

## Installation

```bash
chmod +x capture-stream-install.sh
./capture-stream-install.sh
```

You can also double-click the installer from your file manager. To uninstall: `./capture-stream-install.sh --uninstall`

### Dependencies

```bash
# Fedora / Nobara / Bazzite
sudo dnf install v4l-utils vlc alsa-utils pulseaudio-utils python3-gobject

# Ubuntu / Debian / Mint / Pop
sudo apt install v4l-utils vlc alsa-utils pulseaudio-utils python3-gi

# Arch / Manjaro / CachyOS
sudo pacman -S v4l-utils vlc alsa-utils libpulse python-gobject
```

Additional session-specific deps (`wmctrl` on X11, `kreadconfig6`/`qdbus-qt6` or `qdbus6` on KDE Wayland) are detected and prompted by the installer.

## Usage

1. Connect your capture card
2. Launch **Capture Stream** from your app menu or run `capture-stream`
3. Select your devices, format, resolution, and framerate
4. Adjust brightness/contrast if needed (HDR preset for HDR sources)
5. Set latency and click **Start Stream**
6. Close VLC to return to settings

### Volume

Adjust capture card volume through your DE's volume mixer — look for the VLC stream under playback or recording.

### Latency

Controls VLC's live-caching buffer, mainly affects audio lag.

| Preset | Value | Use case |
|--------|-------|----------|
| Low | 20 ms | Least audio lag, may stutter at 4K |
| Medium | 40 ms | Good balance, recommended for 4K |
| High | 60 ms | Smoothest audio, for problematic setups |

### HDR

HDR passthrough isn't available on Linux. The HDR preset adjusts brightness/contrast to compensate for dim HDR sources on SDR displays.

## Troubleshooting

### No devices found
- Video: `v4l2-ctl --list-devices` — Audio: `arecord -l`
- Try the ↻ Refresh button after plugging in

### VLC fails to start
- Error dialog shows exit code and last lines of output
- Common causes: device busy, invalid resolution/format combo, missing PulseAudio

### Stuttering
- Increase latency, lower resolution/framerate, use USB 3.0

### Stream pauses when minimized
- **KDE Wayland**: handled automatically — the window rule blocks minimization
- **X11 / other Wayland**: VLC stops rendering when minimized. Avoid minimizing the stream window; it stays below other windows so it won't be in the way

### Window has borders / wrong size
- KDE Wayland: needs `kreadconfig6` and `qdbus-qt6`
- X11: needs `wmctrl`
- Other Wayland: window rules not supported, VLC opens normally

### Wrong size with display scaling
- KDE Wayland: scale is read from `~/.config/kwinoutputconfig.json` — check it exists and has your scale value
- Falls back to `QT_SCALE_FACTOR` / `GDK_SCALE` env vars

## Configuration

Settings saved to `~/.config/capture-stream/config.ini`.

## AI Disclaimer
This project was made with AI assistance.
