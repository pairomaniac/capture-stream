#!/usr/bin/env python3
"""
Capture Stream - Low-latency capture card viewer for Linux
https://github.com/pairomaniac/capture-stream

Supported window rule backends:
  KDE Wayland - kwinrulesrc    |  Any X11 - wmctrl    |  Other - no-op
"""

import os, sys, re, signal, subprocess, configparser, shutil, threading, json
from pathlib import Path

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

APP_NAME = "Capture Stream"
CONFIG_DIR = Path.home() / ".config" / "capture-stream"
CONFIG_FILE = CONFIG_DIR / "config.ini"
DISCORD_RESOLUTIONS = {"3840x2160", "2560x1440", "1920x1080", "1280x720", "854x480", "640x480"}
DISCORD_FPS = {15, 30, 60}

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

_session_cache = None

def detect_session():
    global _session_cache
    if _session_cache is not None:
        return _session_cache
    session = os.environ.get("XDG_SESSION_TYPE", "").lower()
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").upper()
    if not session:
        if os.environ.get("WAYLAND_DISPLAY"):   session = "wayland"
        elif os.environ.get("DISPLAY"):          session = "x11"
    _session_cache = (session, desktop)
    return _session_cache

def _detect_distro_family():
    ids = set()
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            if line.startswith("ID="):
                ids.add(line.split("=", 1)[1].strip('"').lower())
            elif line.startswith("ID_LIKE="):
                ids.update(line.split("=", 1)[1].strip('"').lower().split())
    except FileNotFoundError:
        pass
    for family, distros in [
        ("fedora",  {"fedora"}),
        ("debian",  {"ubuntu","debian"}),
        ("arch",    {"arch"}),
        ("suse",    {"opensuse","suse"}),
    ]:
        if ids & distros:
            return family
    return None

# Packages that are the same name everywhere
_UNIVERSAL_PKGS = {
    "v4l2-ctl": "v4l-utils", "vlc": "vlc",
    "arecord": "alsa-utils", "wmctrl": "wmctrl",
}

# Packages that differ per distro family
_DISTRO_PKGS = {
    "pactl":         {"fedora": "pulseaudio-utils", "debian": "pulseaudio-utils",
                       "arch": "libpulse", "suse": "pulseaudio-utils"},
    "qdbus":         {"fedora": "qt6-qttools", "debian": "qdbus-qt6",
                       "arch": "qt6-tools", "suse": "qt6-tools-qdbus"},
}

_INSTALL_PREFIX = {
    "fedora": "sudo dnf install",
    "debian": "sudo apt install",
    "arch":   "sudo pacman -S",
    "suse":   "sudo zypper install",
}

_qdbus_cmd = None

def _find_qdbus():
    global _qdbus_cmd
    if _qdbus_cmd:
        return _qdbus_cmd
    for name in ("qdbus-qt6", "qdbus6", "qdbus"):
        if shutil.which(name):
            _qdbus_cmd = name
            return name
    return None

def check_dependencies():
    session, desktop = detect_session()
    family = _detect_distro_family()
    checks = ["v4l2-ctl", "vlc", "arecord", "pactl"]
    if session == "wayland" and "KDE" in desktop:
        checks.append("qdbus")
    elif session == "x11":
        checks.append("wmctrl")

    missing_cmds = []
    for cmd in checks:
        if cmd == "qdbus":
            if not _find_qdbus():
                missing_cmds.append(cmd)
        elif not shutil.which(cmd):
            missing_cmds.append(cmd)

    if not missing_cmds:
        return None

    missing_pkgs = []
    for cmd in missing_cmds:
        if cmd in _UNIVERSAL_PKGS:
            missing_pkgs.append(_UNIVERSAL_PKGS[cmd])
        elif family and family in _DISTRO_PKGS.get(cmd, {}):
            missing_pkgs.append(_DISTRO_PKGS[cmd][family])
        else:
            missing_pkgs.append(cmd)
    return sorted(set(missing_pkgs))

def get_install_hint(packages):
    family = _detect_distro_family()
    if family and family in _INSTALL_PREFIX:
        return f"{_INSTALL_PREFIX[family]} {' '.join(packages)}"
    return None

def find_icon():
    try:
        return Gtk.IconTheme.get_default().load_icon("camera-video", 64, 0)
    except Exception:
        return None

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

class Config:
    SECTION = "capture"
    DEFAULTS = {"video_device": "", "audio_device": "", "resolution": "",
                "format": "NV12", "fps": "", "brightness": "1.0",
                "contrast": "1.0", "latency": "20"}

    def __init__(self):
        self._cp = configparser.ConfigParser()
        if CONFIG_FILE.exists():
            self._cp.read(CONFIG_FILE)
        if not self._cp.has_section(self.SECTION):
            self._cp.add_section(self.SECTION)
            for k, v in self.DEFAULTS.items():
                self._cp.set(self.SECTION, k, v)

    def get(self, key):
        return self._cp.get(self.SECTION, key, fallback=self.DEFAULTS.get(key, ""))

    def set(self, key, value):
        self._cp.set(self.SECTION, key, str(value))

    def save(self):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        with open(CONFIG_FILE, "w") as f:
            self._cp.write(f)

# ---------------------------------------------------------------------------
# Device / format discovery
# ---------------------------------------------------------------------------

def _run(cmd):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""

def _clean_device_name(name):
    clean = re.sub(r"\s*\((usb|pci)-[^)]*\)\s*$", "", name)
    if ": " in clean:
        left, right = clean.split(": ", 1)
        if left.strip() == right.strip():
            clean = left.strip()
    return clean

def get_video_devices():
    devices, name, seen_names = [], None, set()
    for line in _run(["v4l2-ctl", "--list-devices"]).splitlines():
        if not line.strip(): continue
        if not line[0].isspace():
            name = line.rstrip(":")
        elif name and "/dev/video" in line and name not in seen_names:
            devices.append((_clean_device_name(name), line.strip()))
            seen_names.add(name)
    return devices

def get_audio_devices():
    known_cards = re.compile(
        r"Elgato|Game Capture|Cam Link|Live Gamer|Magewell|USB Capture|"
        r"Blackmagic|Intensity|DeckLink|HDMI.*In|SDI",
        re.I)
    pat = re.compile(r"card\s+(\d+):\s+\w+\s+\[([^\]]+)\]")
    devices = []
    all_devices = []
    seen_hw = set()
    for line in _run(["arecord", "-l"]).splitlines():
        m = pat.search(line)
        if not m: continue
        hw = f"hw:{m.group(1)},0"
        if hw in seen_hw: continue
        seen_hw.add(hw)
        entry = (m.group(2), hw)
        all_devices.append(entry)
        if known_cards.search(line):
            devices.append(entry)
    return devices if devices else all_devices

def _parse_formats_ext(device):
    modes = {}
    seen = {}
    cur_fmt, cur_res = None, None
    for line in _run(["v4l2-ctl", "-d", device, "--list-formats-ext"]).splitlines():
        if (m := re.search(r"'([A-Z0-9]+)'", line)):
            cur_fmt = m.group(1)
            modes.setdefault(cur_fmt, [])
            seen.setdefault(cur_fmt, set())
            cur_res = None
            continue
        if not cur_fmt: continue
        if "Size:" in line and (m := re.search(r"(\d+x\d+)", line)):
            cur_res = m.group(1); continue
        if cur_res and "fps" in line and (m := re.search(r"(\d+(?:\.\d+)?)\s*fps", line)):
            fps = int(float(m.group(1)))
            if cur_res in DISCORD_RESOLUTIONS and fps in DISCORD_FPS:
                pair = (cur_res, fps)
                if pair not in seen[cur_fmt]:
                    seen[cur_fmt].add(pair)
                    modes[cur_fmt].append(pair)
    return modes

# ---------------------------------------------------------------------------
# Window rule backends
# ---------------------------------------------------------------------------

class WindowRule:
    def create(self, title, w, h): pass
    def remove(self): pass

def _get_display_scale():
    session, desktop = detect_session()
    if session == "wayland" and "KDE" in desktop:
        # Plasma 6 per-output config
        try:
            cfg = Path.home() / ".config/kwinoutputconfig.json"
            if cfg.exists():
                for section in json.loads(cfg.read_text()):
                    if section.get("name") != "outputs":
                        continue
                    for output in section.get("data", []):
                        scale = output.get("scale")
                        if scale and float(scale) != 1.0:
                            return float(scale)
        except (ValueError, KeyError, OSError):
            pass
        # kdeglobals fallback
        try:
            kglobals = Path.home() / ".config/kdeglobals"
            if kglobals.exists():
                cp = configparser.ConfigParser()
                cp.optionxform = str
                cp.read(str(kglobals))
                val = cp.get("KScreen", "ScaleFactor", fallback="")
                if val:
                    return float(val)
        except (ValueError, OSError):
            pass
    for var in ("QT_SCALE_FACTOR", "GDK_SCALE"):
        val = os.environ.get(var)
        if val:
            try:
                return float(val)
            except ValueError:
                pass
    return 1.0

class KWinWaylandRule(WindowRule):
    def __init__(self):
        self.rule_id = None
        self._rc = str(Path.home() / ".config/kwinrulesrc")

    def _reconfigure(self):
        qdbus = _find_qdbus()
        if qdbus:
            subprocess.run([qdbus, "org.kde.KWin", "/KWin", "reconfigure"],
                           check=False, capture_output=True)

    def _cleanup_stale_rules(self):
        rc = Path(self._rc)
        if not rc.exists():
            return
        cp = configparser.ConfigParser()
        cp.optionxform = str
        cp.read(str(rc))
        stale = []
        for section in cp.sections():
            if not section.startswith("capture-stream-"):
                continue
            try:
                pid = int(section.rsplit("-", 1)[1])
                os.kill(pid, 0)
            except (ValueError, ProcessLookupError):
                stale.append(section)
            except PermissionError:
                pass  # process exists
        if not stale:
            return
        for section in stale:
            cp.remove_section(section)
        if cp.has_option("General", "rules"):
            rules = [r for r in cp.get("General", "rules").split(",")
                     if r and r not in stale]
            cp.set("General", "rules", ",".join(rules))
            cp.set("General", "count", str(len(rules)))
        with open(rc, "w") as f:
            cp.write(f)
        self._reconfigure()

    def create(self, title, w, h):
        self._cleanup_stale_rules()
        self.rule_id = f"capture-stream-{os.getpid()}"
        rc = Path(self._rc)
        cp = configparser.ConfigParser()
        cp.optionxform = str
        if rc.exists():
            cp.read(str(rc))
        if not cp.has_section(self.rule_id):
            cp.add_section(self.rule_id)
        for k, v in [("Description", title), ("wmclass", "vlc"), ("wmclassmatch", "1"),
                      ("title", title), ("titlematch", "2"), ("position", "0,0"),
                      ("positionrule", "2"), ("size", f"{w},{h}"), ("sizerule", "2"),
                      ("below", "true"), ("belowrule", "2"), ("noborder", "true"),
                      ("noborderrule", "2"), ("minimize", "false"),
                      ("minimizerule", "2")]:
            cp.set(self.rule_id, k, v)
        if not cp.has_section("General"):
            cp.add_section("General")
        existing = cp.get("General", "rules", fallback="")
        rules = [r for r in existing.split(",") if r]
        if self.rule_id not in rules:
            rules.append(self.rule_id)
        cp.set("General", "rules", ",".join(rules))
        cp.set("General", "count", str(len(rules)))
        with open(rc, "w") as f:
            cp.write(f)
        self._reconfigure()

    def remove(self):
        if not self.rule_id: return
        rc = Path(self._rc)
        if rc.exists():
            cp = configparser.ConfigParser()
            cp.optionxform = str
            cp.read(str(rc))
            if cp.has_section(self.rule_id):
                cp.remove_section(self.rule_id)
            if cp.has_option("General", "rules"):
                rules = [r for r in cp.get("General", "rules").split(",")
                         if r and r != self.rule_id]
                cp.set("General", "rules", ",".join(rules))
                cp.set("General", "count", str(len(rules)))
            with open(rc, "w") as f:
                cp.write(f)
        self._reconfigure()
        self.rule_id = None

class X11Rule(WindowRule):
    def __init__(self):
        self.title = None
        self._wid = None

    def create(self, title, w, h):
        self.title, self._w, self._h, self._wid = title, w, h, None

    def apply_if_ready(self):
        if not self.title: return
        if not self._wid:
            for line in _run(["wmctrl", "-l"]).splitlines():
                if self.title in line:
                    self._wid = line.split()[0]
                    subprocess.run(["wmctrl", "-i", "-r", self._wid, "-b", "add,below"],
                                   check=False, capture_output=True)
                    if shutil.which("xprop"):
                        subprocess.run(["xprop", "-id", self._wid, "-f", "_MOTIF_WM_HINTS", "32c",
                                       "-set", "_MOTIF_WM_HINTS", "2, 0, 0, 0, 0"],
                                       check=False, capture_output=True)
                    break
            else:
                return
        subprocess.run(["wmctrl", "-i", "-r", self._wid, "-e",
                       f"0,0,0,{self._w},{self._h}"],
                       check=False, capture_output=True)

    def remove(self):
        self.title = None
        self._wid = None

def get_window_rule():
    session, desktop = detect_session()
    if session == "wayland" and "KDE" in desktop:   return KWinWaylandRule()
    if session == "x11" and shutil.which("wmctrl"): return X11Rule()
    return WindowRule()

# ---------------------------------------------------------------------------
# Settings window
# ---------------------------------------------------------------------------

class SettingsWindow(Gtk.Window):
    def __init__(self, config):
        super().__init__(title=APP_NAME)
        self.config = config
        self.set_border_width(20)
        self.set_resizable(False)
        self.set_position(Gtk.WindowPosition.CENTER)
        icon = find_icon()
        if icon: self.set_icon(icon)

        self.video_devices = get_video_devices()
        self.audio_devices = get_audio_devices()
        if not self.video_devices:  self._error("No video capture devices found."); return
        if not self.audio_devices:  self._error("No capture card audio devices found."); return

        grid = Gtk.Grid(column_spacing=14, row_spacing=8)
        self.add(grid)
        row = 0

        header_row = Gtk.Box(spacing=14)
        header_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        header = Gtk.Label()
        header.set_markup(f"<span size='large' weight='bold'>{APP_NAME}</span>")
        header.set_halign(Gtk.Align.START)
        subtitle = Gtk.Label(label="Low-latency capture card viewer")
        subtitle.set_halign(Gtk.Align.START)
        subtitle.set_opacity(0.5)
        header_box.pack_start(header, False, False, 0)
        header_box.pack_start(subtitle, False, False, 0)
        header_row.pack_start(header_box, True, True, 0)
        btn_refresh = Gtk.Button(label="↻ Refresh")
        btn_refresh.set_tooltip_text("Re-detect video and audio devices")
        btn_refresh.set_valign(Gtk.Align.CENTER)
        btn_refresh.connect("clicked", self._on_refresh)
        header_row.pack_end(btn_refresh, False, False, 0)
        grid.attach(header_row, 0, row, 2, 1); row += 1

        grid.attach(Gtk.Separator(), 0, row, 2, 1); row += 1

        self.combo_video = self._add_combo(grid, row, "Video Device",
            self.video_devices, config.get("video_device"),
            tooltip="V4L2 capture device (e.g. HDMI capture card)"); row += 1

        self.combo_audio = self._add_combo(grid, row, "Audio Device",
            self.audio_devices, config.get("audio_device"),
            tooltip="ALSA capture device — audio input from the capture card"); row += 1

        self.combo_format = self._add_combo(grid, row, "Pixel Format", [], config.get("format"),
            tooltip="Pixel format supported by the device (NV12 is usually best)"); row += 1

        self.combo_resolution = self._add_combo(grid, row, "Resolution", [], config.get("resolution"),
            tooltip="Capture resolution — shows modes supported by the device"); row += 1

        self.combo_fps = self._add_combo(grid, row, "Framerate", [], "",
            tooltip="Capture framerate — shows rates available for the selected resolution"); row += 1

        grid.attach(Gtk.Separator(), 0, row, 2, 1); row += 1

        self.scale_brightness = self._add_slider(grid, row, "Brightness",
            0.0, 2.0, 0.05, float(config.get("brightness")),
            tooltip="VLC video brightness adjustment (default 1.0)"); row += 1
        self.scale_contrast = self._add_slider(grid, row, "Contrast",
            0.0, 2.0, 0.05, float(config.get("contrast")),
            tooltip="VLC video contrast adjustment (default 1.0)"); row += 1

        preset_box = Gtk.Box(spacing=8)
        preset_box.set_halign(Gtk.Align.END)
        lbl_p = Gtk.Label(label="Presets:")
        lbl_p.set_opacity(0.5)
        preset_box.pack_start(lbl_p, False, False, 0)
        for label, b, c, tip in [
            ("SDR", 1.0, 1.0, "No adjustment — use for SDR sources"),
            ("HDR", 1.1, 1.15, "Compensates for washed-out HDR on SDR displays"),
        ]:
            btn = Gtk.Button(label=label)
            btn.set_tooltip_text(tip)
            btn.connect("clicked", lambda _, b=b, c=c: (
                self.scale_brightness.set_value(b), self.scale_contrast.set_value(c)))
            preset_box.pack_start(btn, False, False, 0)
        grid.attach(preset_box, 1, row, 1, 1); row += 1

        grid.attach(Gtk.Separator(), 0, row, 2, 1); row += 1

        self.scale_latency = self._add_slider(grid, row, "Latency (ms)",
            20, 60, 5, int(config.get("latency")),
            tooltip="VLC live-caching buffer — mainly affects audio lag",
            marks=[(20, "Low"), (40, "Medium"), (60, "High")],
            desc="Low: least audio lag, may stutter at 4K\n"
                 "Medium: good balance, recommended for 4K\n"
                 "High: smoothest audio, for problematic setups"); row += 1

        btn_box = Gtk.Box(spacing=8)
        btn_box.set_halign(Gtk.Align.END)
        btn_box.set_margin_top(10)
        btn_quit = Gtk.Button(label="Quit")
        btn_quit.connect("clicked", lambda _: Gtk.main_quit())
        btn_box.pack_start(btn_quit, False, False, 0)
        btn_start = Gtk.Button(label="Start Stream")
        btn_start.get_style_context().add_class("suggested-action")
        btn_start.connect("clicked", self._on_start)
        btn_box.pack_start(btn_start, False, False, 0)
        grid.attach(btn_box, 0, row, 2, 1)

        self._modes_cache_by_fmt = {}
        self._modes_cache = []

        self.combo_video.connect("changed", self._on_video_changed)
        self.combo_format.connect("changed", self._on_format_changed)
        self.combo_resolution.connect("changed", self._on_resolution_changed)

        self._on_video_changed(self.combo_video)

        # Explicitly restore fps — cascade may not set it if combo didn't change
        saved_fps = self.config.get("fps")
        if saved_fps:
            self.combo_fps.set_active_id(saved_fps)

        self.connect("delete-event", lambda *_: Gtk.main_quit())
        self.show_all()

    def _save_current(self):
        self.config.set("video_device", self._combo_value(self.combo_video))
        self.config.set("audio_device", self._combo_value(self.combo_audio))
        self.config.set("resolution", self._combo_value(self.combo_resolution))
        self.config.set("fps", self._combo_value(self.combo_fps))
        self.config.set("format", self._combo_value(self.combo_format))
        self.config.set("brightness", f"{self.scale_brightness.get_value():.2f}")
        self.config.set("contrast", f"{self.scale_contrast.get_value():.2f}")
        self.config.set("latency", str(int(self.scale_latency.get_value())))
        self.config.save()

    def _error(self, msg):
        dlg = Gtk.MessageDialog(transient_for=self, modal=True,
            message_type=Gtk.MessageType.ERROR, buttons=Gtk.ButtonsType.OK, text=msg)
        dlg.run(); dlg.destroy()
        sys.exit(1)

    # -- UI helpers --

    @staticmethod
    def _add_combo(grid, row, label, items, saved, tooltip=""):
        lbl = Gtk.Label(label=label); lbl.set_halign(Gtk.Align.END)
        grid.attach(lbl, 0, row, 1, 1)
        combo = Gtk.ComboBoxText()
        combo.set_hexpand(True)
        combo.set_popup_fixed_width(False)
        if tooltip: combo.set_tooltip_text(tooltip)
        SettingsWindow._populate_combo(combo, items, saved)
        grid.attach(combo, 1, row, 1, 1)
        return combo

    @staticmethod
    def _combo_value(combo):
        return combo.get_active_id() or ""

    @staticmethod
    def _populate_combo(combo, items, preferred=""):
        combo.remove_all()
        active = 0
        for i, (display, value) in enumerate(items):
            combo.append(value, display)
            if value == preferred: active = i
        if items: combo.set_active(active)

    @staticmethod
    def _add_slider(grid, row, label, lo, hi, step, value, tooltip="", marks=None, desc=""):
        lbl = Gtk.Label(label=label); lbl.set_halign(Gtk.Align.END)
        lbl.set_valign(Gtk.Align.START if (marks or desc) else Gtk.Align.CENTER)
        grid.attach(lbl, 0, row, 1, 1)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, lo, hi, step)
        scale.set_value(value)
        scale.set_hexpand(True)
        digits = 2 if step < 1 else 0
        scale.set_digits(digits)
        scale.set_draw_value(True)
        scale.set_value_pos(Gtk.PositionType.RIGHT)
        scale.connect("format-value",
                      lambda s, v: f"{v:.{digits}f}")
        def _snap(s):
            snapped = round(round(s.get_value() / step) * step, 10)
            if abs(s.get_value() - snapped) > 1e-12:
                s.handler_block_by_func(_snap)
                s.set_value(snapped)
                s.handler_unblock_by_func(_snap)
        scale.connect("value-changed", _snap)
        if tooltip: scale.set_tooltip_text(tooltip)
        if marks:
            for val, text in marks:
                scale.add_mark(val, Gtk.PositionType.BOTTOM, text)
        box.pack_start(scale, False, False, 0)
        if desc:
            hint = Gtk.Label()
            hint.set_markup(f"<small>{desc}</small>")
            hint.set_halign(Gtk.Align.START)
            hint.set_opacity(0.5)
            hint.set_line_wrap(True)
            box.pack_start(hint, False, False, 0)
        grid.attach(box, 1, row, 1, 1)
        return scale

    # -- Cascading dropdowns --

    def _on_refresh(self, _widget):
        self.video_devices = get_video_devices()
        self.audio_devices = get_audio_devices()
        self._populate_combo(self.combo_video, self.video_devices,
                             self.config.get("video_device"))
        self._populate_combo(self.combo_audio, self.audio_devices,
                             self.config.get("audio_device"))
        self._on_video_changed(self.combo_video)

    def _on_video_changed(self, combo):
        device = self._combo_value(combo)
        if not device: return
        self._modes_cache_by_fmt = _parse_formats_ext(device)
        fmts = sorted(self._modes_cache_by_fmt)
        saved = self.config.get("format")
        if saved not in fmts and fmts: saved = fmts[0]
        self._populate_combo(self.combo_format, [(f, f) for f in fmts], saved)

    def _on_format_changed(self, combo):
        fmt = self._combo_value(combo)
        if not fmt: return
        self._modes_cache = self._modes_cache_by_fmt.get(fmt, [])
        resolutions = sorted({r for r, _ in self._modes_cache},
                             key=lambda r: int(r.split("x")[0]), reverse=True)
        self._populate_combo(self.combo_resolution,
                             [(r, r) for r in resolutions], self.config.get("resolution"))

    def _on_resolution_changed(self, combo):
        res = self._combo_value(combo)
        if not res: return
        fps_list = sorted({f for r, f in self._modes_cache if r == res}, reverse=True)
        self._populate_combo(self.combo_fps,
                             [(f"{f} fps", str(f)) for f in fps_list],
                             self.config.get("fps"))

    # -- Launch --

    def _on_start(self, _widget):
        video      = self._combo_value(self.combo_video)
        audio      = self._combo_value(self.combo_audio)
        resolution = self._combo_value(self.combo_resolution)
        fps        = self._combo_value(self.combo_fps)
        fmt        = self._combo_value(self.combo_format)
        brightness = self.scale_brightness.get_value()
        contrast   = self.scale_contrast.get_value()
        latency    = int(self.scale_latency.get_value())

        if not all([video, audio, resolution, fps, fmt]):
            dlg = Gtk.MessageDialog(transient_for=self, modal=True,
                message_type=Gtk.MessageType.ERROR, buttons=Gtk.ButtonsType.OK,
                text="Please fill in all fields.")
            dlg.run(); dlg.destroy()
            return

        self._save_current()

        self.set_sensitive(False)
        self.hide()
        self._launch(video, audio, resolution, int(fps), fmt,
                     brightness, contrast, latency)

    def _launch(self, video, audio, resolution, fps, fmt,
                brightness, contrast, latency):
        width, height = resolution.split("x")
        title = f"Capture Stream {resolution}"

        rule = get_window_rule()
        scale = _get_display_scale() if isinstance(rule, KWinWaylandRule) else 1.0
        win_w = str(round(int(width) / scale))
        win_h = str(round(int(height) / scale))
        rule.create(title, win_w, win_h)

        cmd = ["vlc", "--ignore-config", "--no-qt-privacy-ask",
               f"v4l2://{video}",
               f"--v4l2-width={width}", f"--v4l2-height={height}",
               f"--v4l2-fps={fps}", f"--v4l2-chroma={fmt}",
               f":input-slave=alsa://{audio}", f":live-caching={latency}",
               "--aout=pulse", "--qt-minimal-view", "--no-mouse-events",
               "--no-video-title-show", f"--meta-title={title}"]

        if abs(brightness - 1.0) > 0.01 or abs(contrast - 1.0) > 0.01:
            cmd += ["--video-filter=adjust",
                    f"--brightness={brightness:.2f}", f"--contrast={contrast:.2f}"]

        proc = subprocess.Popen(cmd, stderr=subprocess.PIPE)

        stderr_lines = []
        def _drain_stderr():
            try:
                for line in proc.stderr:
                    stderr_lines.append(line.decode(errors="replace"))
            except Exception:
                pass

        threading.Thread(target=_drain_stderr, daemon=True).start()

        poll_count = [0]

        def poll():
            if proc.poll() is not None:
                rule.remove()
                if proc.returncode != 0:
                    stderr = "".join(stderr_lines).strip()
                    msg = f"VLC exited with code {proc.returncode}"
                    if stderr:
                        lines = stderr.splitlines()[-5:]
                        msg += f"\n\n{''.join(l + chr(10) for l in lines)}"
                    dlg = Gtk.MessageDialog(transient_for=self, modal=True,
                        message_type=Gtk.MessageType.WARNING,
                        buttons=Gtk.ButtonsType.OK, text=msg)
                    dlg.run(); dlg.destroy()
                self.set_sensitive(True)
                self.show()
                return False
            poll_count[0] += 1
            if isinstance(rule, KWinWaylandRule) and poll_count[0] == 3:
                rule._reconfigure()
            if isinstance(rule, X11Rule):
                rule.apply_if_ready()
            return True

        GLib.timeout_add(500, poll)

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    signal.signal(signal.SIGINT, signal.SIG_DFL)

    screen = Gdk.Screen.get_default()
    if screen:
        css = Gtk.CssProvider()
        css.load_from_data(b"* { -GtkComboBox-appears-as-list: 1; }")
        Gtk.StyleContext.add_provider_for_screen(
            screen, css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    missing = check_dependencies()
    if missing:
        msg = f"Missing packages: {', '.join(missing)}"
        hint = get_install_hint(missing)
        if hint:
            msg += f"\n\nInstall with:\n{hint}"
        try:
            dlg = Gtk.MessageDialog(message_type=Gtk.MessageType.ERROR,
                                    buttons=Gtk.ButtonsType.OK, text=msg)
            if hint:
                entry = Gtk.Entry(text=hint, editable=False)
                entry.set_can_focus(True)
                dlg.get_content_area().pack_start(entry, False, False, 0)
                entry.show()
            dlg.run(); dlg.destroy()
        except Exception:
            pass
        print(msg, file=sys.stderr)
        sys.exit(1)

    SettingsWindow(Config())
    Gtk.main()

if __name__ == "__main__":
    main()
