"""Chinon ES-3000 Camera - Windows app (download, convert, control)."""
import json
import os
import queue
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from PIL import Image, ImageTk
from serial.tools import list_ports

import chinon_decode
from chinon_camera import RES_NAMES, Camera, CameraError, CameraFailed

APP_TITLE = "Chinon ES-3000"
APP_VERSION = "1.3"
RES_LONG = {"SF": "Superfine", "F": "Fine", "N": "Normal"}
SIZES = {0: 194560, 1: 97280, 2: 24576}
SPEED_CHOICES = {"Standard (57600)": 57600, "Fast (115200)": 115200}
THUMB = (64, 48)
FORMATS = {"PNG": ".png", "JPG": ".jpg", "TIFF": ".tif", "BMP": ".bmp"}
BATTERY = {0: "Good", 1: "Low"}


def save_image(img, path):
    if path.lower().endswith(".jpg"):
        img.save(path, quality=95, subsampling=0)
    else:
        img.save(path)


def resource(name):
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, name)


def settings_path():
    base = os.environ.get("APPDATA") or os.path.expanduser("~")
    return os.path.join(base, "Chinon ES-3000", "settings.json")


def default_photo_dir():
    """The 'photos' folder next to the program, or up to two levels above it (so running from
    App or App\\dist uses the main Chinon ES-3000\\photos folder). Never App\\photos."""
    base = os.path.dirname(sys.executable if getattr(sys, "frozen", False) else os.path.abspath(__file__))
    d = base
    for _ in range(3):
        cand = os.path.join(d, "photos")
        if os.path.isdir(cand) and os.path.basename(d).lower() not in ("app", "dist"):
            return cand
        d = os.path.dirname(d)
    docs = os.path.join(os.path.expanduser("~"), "Documents", "Chinon ES-3000", "photos")
    return docs if os.path.isdir(docs) else os.path.join(base, "photos")


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.settings = self._load_settings()
        self.title(f"{APP_TITLE} {APP_VERSION}")
        self.geometry(self.settings.get("geometry", "1060x680"))
        self.minsize(900, 580)
        try:
            self.iconbitmap(resource("chinon.ico"))
        except Exception:
            pass
        self.cam = None
        self.pictures = []          # [(n, res)]
        self.thumbs = {}            # (n, res, time) -> PIL thumbnail
        self.tk_thumbs = {}         # n -> PhotoImage shown in the list
        self.saved = {}             # n -> png path
        self.last_status = None
        self.jobs = queue.Queue()
        self.ui = queue.Queue()
        self.busy = False
        self.job_is_background = False
        self.cancel_bg = False
        self.preview_img = None
        self.preview_src = None
        self._warned_battery = False
        saved_dir = self.settings.get("photo_dir")
        self.photo_dir = tk.StringVar(value=saved_dir if saved_dir and os.path.isdir(saved_dir)
                                      else default_photo_dir())
        self.speed_var = tk.StringVar(value=self.settings.get("speed", "Standard (57600)"))
        self.verbose = tk.BooleanVar(value=self.settings.get("verbose", False))
        self.format_var = tk.StringVar(value=self.settings.get("format", "PNG"))
        self.rotations = self.settings.get("rotations", {})   # image path -> degrees
        self._build()
        threading.Thread(target=self._worker, daemon=True).start()
        self.after(100, self._pump)
        self.refresh_ports()
        self.protocol("WM_DELETE_WINDOW", self.on_close)
        self.preview.bind("<Configure>", lambda e: self._redraw_preview())

    # -------------------------------------------------------------- settings
    def _load_settings(self):
        try:
            with open(settings_path(), encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}

    def _save_settings(self):
        self.settings.update(port=self.port_var.get(), photo_dir=self.photo_dir.get(),
                             geometry=self.geometry(), speed=self.speed_var.get(),
                             verbose=self.verbose.get(), format=self.format_var.get(),
                             rotations=self.rotations)
        try:
            os.makedirs(os.path.dirname(settings_path()), exist_ok=True)
            with open(settings_path(), "w", encoding="utf-8") as f:
                json.dump(self.settings, f, indent=1)
        except OSError:
            pass

    def on_close(self):
        self._save_settings()
        if self.cam and not self.busy:
            try:
                self.cam.close()
            except Exception:
                pass
        self.destroy()

    # ---------------------------------------------------------------- layout
    def _build(self):
        style = ttk.Style(self)
        style.configure("Pics.Treeview", rowheight=THUMB[1] + 6)
        style.configure("Big.TButton", padding=(6, 6))

        top = ttk.Frame(self, padding=8)
        top.pack(fill="x")
        ttk.Label(top, text="Port:").pack(side="left")
        self.port_var = tk.StringVar(value=self.settings.get("port", "Auto"))
        self.port_box = ttk.Combobox(top, textvariable=self.port_var, width=10, state="readonly")
        self.port_box.pack(side="left", padx=4)
        ttk.Button(top, text="↻", width=3, command=self.refresh_ports).pack(side="left")
        self.connect_btn = ttk.Button(top, text="Connect", command=self.on_connect)
        self.connect_btn.pack(side="left", padx=8)
        self.status_lbl = ttk.Label(top, text="Not connected - slide the lens cover open, then Connect",
                                    foreground="#a00")
        self.status_lbl.pack(side="left", padx=8)
        ttk.Button(top, text="Convert .DCT files…", command=self.on_convert).pack(side="right")

        body = ttk.Frame(self, padding=(8, 0, 8, 8))
        body.pack(fill="both", expand=True)

        # left: pictures
        left = ttk.Frame(body)
        left.pack(side="left", fill="y")
        ttk.Label(left, text="Pictures in camera").pack(anchor="w")
        lf = ttk.Frame(left)
        lf.pack(fill="both", expand=True)
        self.pic_list = ttk.Treeview(lf, columns=("info",), style="Pics.Treeview",
                                     selectmode="extended", height=8, show="tree")
        self.pic_list.column("#0", width=THUMB[0] + 30, stretch=False)
        self.pic_list.column("info", width=170)
        sb = ttk.Scrollbar(lf, orient="vertical", command=self.pic_list.yview)
        self.pic_list.configure(yscrollcommand=sb.set)
        self.pic_list.pack(side="left", fill="both", expand=True)
        sb.pack(side="left", fill="y")
        self.pic_list.bind("<<TreeviewSelect>>", self.on_select)
        self.pic_list.bind("<Double-Button-1>", lambda e: self.on_download_sel())
        ttk.Label(left, text="Double-click a picture to download it.", foreground="#666").pack(anchor="w")
        bf = ttk.Frame(left)
        bf.pack(fill="x", pady=(6, 0))
        ttk.Button(bf, text="Download new", style="Big.TButton",
                   command=self.on_download_new).pack(fill="x", pady=2)
        row = ttk.Frame(bf)
        row.pack(fill="x")
        ttk.Button(row, text="Download all", command=self.on_download_all).pack(side="left", fill="x", expand=True)
        ttk.Button(row, text="Selected", command=self.on_download_sel).pack(side="left", fill="x", expand=True, padx=(4, 0))
        ttk.Button(bf, text="Refresh list", command=self.on_refresh_list).pack(fill="x", pady=2)
        f = ttk.Frame(left)
        f.pack(fill="x", pady=(8, 0))
        ttk.Label(f, text="Save photos to:").pack(anchor="w")
        ttk.Entry(f, textvariable=self.photo_dir, width=30).pack(fill="x")
        row = ttk.Frame(f)
        row.pack(fill="x", pady=2)
        ttk.Button(row, text="Change…", command=self.on_pick_dir).pack(side="left", fill="x", expand=True)
        ttk.Button(row, text="Open folder", command=self.on_open_dir).pack(side="left", fill="x", expand=True, padx=(4, 0))
        ttk.Label(f, text="Transfer speed:").pack(anchor="w", pady=(6, 0))
        ttk.Combobox(f, textvariable=self.speed_var, values=list(SPEED_CHOICES), state="readonly",
                     width=20).pack(fill="x")
        ttk.Label(f, text="Save pictures as:").pack(anchor="w", pady=(6, 0))
        ttk.Combobox(f, textvariable=self.format_var, values=list(FORMATS), state="readonly",
                     width=20).pack(fill="x")

        # middle: preview + log
        mid = ttk.Frame(body, padding=(10, 0))
        mid.pack(side="left", fill="both", expand=True)
        self.preview = ttk.Label(mid, text="Preview", anchor="center", relief="sunken", compound="top")
        self.preview.pack(fill="both", expand=True)
        row = ttk.Frame(mid)
        row.pack(fill="x")
        self.caption = ttk.Label(row, text="", foreground="#555")
        self.caption.pack(side="left")
        ttk.Button(row, text="Info", width=6, command=self.on_info).pack(side="right")
        ttk.Button(row, text="⟳", width=3, command=lambda: self.on_rotate(-90)).pack(side="right")
        ttk.Button(row, text="⟲", width=3, command=lambda: self.on_rotate(90)).pack(side="right", padx=(0, 2))
        self.progress = ttk.Progressbar(mid, mode="determinate")
        self.progress.pack(fill="x", pady=4)
        self.log_box = tk.Text(mid, height=6, state="disabled", font=("Consolas", 9))
        self.log_box.pack(fill="x")
        ttk.Checkbutton(mid, text="Show technical details in log", variable=self.verbose).pack(anchor="w")

        # right: control
        right = ttk.LabelFrame(body, text="Camera settings", padding=8)
        right.pack(side="left", fill="y")
        self.res_var = tk.StringVar(value="Superfine")
        self.flash_var = tk.StringVar(value="Auto")
        self.focus_var = tk.StringVar(value="Multi-spot")
        self.zoom_var = tk.IntVar(value=0)
        self.timer_var = tk.BooleanVar(value=False)
        self._choice(right, "Resolution", self.res_var, ["Superfine", "Fine", "Normal"], self.on_set_res)
        self._choice(right, "Flash", self.flash_var, ["Auto", "Fill (on)", "Off"], self.on_set_flash)
        self._choice(right, "Focus", self.focus_var, ["Multi-spot", "Single-spot", "Macro"], self.on_set_focus)
        self.zoom_lbl = ttk.Label(right, text="Zoom: 0 (wide)")
        self.zoom_lbl.pack(anchor="w", pady=(8, 0))
        z = ttk.Scale(right, from_=0, to=6, variable=self.zoom_var, orient="horizontal",
                      command=lambda v: self._zoom_moved(v))
        z.pack(fill="x")
        self.zoom_scale = z
        z.bind("<ButtonRelease-1>", lambda e: self.on_set_zoom())
        ttk.Checkbutton(right, text="Self-timer", variable=self.timer_var,
                        command=self.on_set_timer).pack(anchor="w", pady=(8, 0))
        ttk.Button(right, text="📷  Take picture", style="Big.TButton",
                   command=self.on_shoot).pack(fill="x", pady=(14, 4))
        ttk.Button(right, text="Sync camera clock to PC",
                   command=lambda: self.run(self._sync_clock)).pack(fill="x", pady=2)
        self.cam_info = ttk.Label(right, text="", foreground="#555", justify="left")
        self.cam_info.pack(anchor="w", pady=(10, 0))
        ttk.Separator(right).pack(fill="x", pady=10)
        ttk.Button(right, text="Erase ALL pictures…", command=self.on_erase).pack(fill="x")

    def _choice(self, parent, label, var, values, cb):
        ttk.Label(parent, text=label).pack(anchor="w", pady=(8, 0))
        box = ttk.Combobox(parent, textvariable=var, values=values, state="readonly", width=16)
        box.pack(fill="x")
        box.bind("<<ComboboxSelected>>", lambda e: cb(values.index(var.get())))

    def _zoom_moved(self, v):
        v = round(float(v))
        self.zoom_var.set(v)
        self.zoom_lbl.configure(text=f"Zoom: {v}" + (" (wide)" if v == 0 else " (tele)" if v == 6 else ""))

    # --------------------------------------------------------------- helpers
    def log(self, *parts):
        self.ui.put(("log", " ".join(str(p) for p in parts)))

    def detail(self, *parts):
        if self.verbose.get():
            self.log(*parts)

    def _pump(self):
        try:
            while True:
                kind, val = self.ui.get_nowait()
                if kind == "log":
                    self.log_box.configure(state="normal")
                    self.log_box.insert("end", val + "\n")
                    self.log_box.see("end")
                    self.log_box.configure(state="disabled")
                elif kind == "status":
                    text, ok = val
                    self.status_lbl.configure(text=text, foreground="#070" if ok else "#a00")
                elif kind == "pics":
                    self._fill_list()
                elif kind == "thumb":
                    self._set_row(val)
                elif kind == "progress":
                    self.progress.configure(maximum=val[1], value=val[0])
                elif kind == "preview":
                    self._show(*val)
                elif kind == "caminfo":
                    self.cam_info.configure(text=val)
                elif kind == "error":
                    messagebox.showerror(APP_TITLE, val)
                elif kind == "connected":
                    self.connect_btn.configure(text="Disconnect" if val else "Connect")
                    if not val:
                        self.cam_info.configure(text="")
                elif kind == "zoom":
                    self._zoom_moved(val)
                elif kind == "clear":
                    self._clear_preview(val)
                elif kind == "zoomlock":
                    self.zoom_scale.state(["disabled"] if val else ["!disabled"])
                    self.zoom_lbl.configure(foreground="#999" if val else "")
                elif kind == "speed":
                    self.speed_var.set(val)
        except queue.Empty:
            pass
        self.after(100, self._pump)

    def _show(self, img, caption=""):
        self.preview_src = img
        self.caption.configure(text=caption)
        self._redraw_preview()

    def _redraw_preview(self):
        img = self.preview_src
        if img is None:
            return
        w = max(self.preview.winfo_width() - 8, 320)
        h = max(self.preview.winfo_height() - 8, 240)
        scale = min(w / img.width, h / img.height)
        size = (max(1, int(img.width * scale)), max(1, int(img.height * scale)))
        small = img.width < 200
        disp = img.resize(size, Image.BICUBIC if small else Image.LANCZOS)
        self.preview_img = ImageTk.PhotoImage(disp)
        self.preview.configure(image=self.preview_img, text="")

    def _clear_preview(self, text):
        self.preview_src = None
        self.preview_img = None
        self.preview.configure(image="", text=text)
        self.caption.configure(text="")

    def run(self, fn, *args, background=False):
        """Queue a camera job. Background jobs (thumbnail loading) give way to user actions."""
        if self.busy and not self.job_is_background:
            self.log("Busy - please wait for the current task.")
            return
        if self.busy and not background:
            self.cancel_bg = True
        self.jobs.put((fn, args, background))

    def _worker(self):
        while True:
            fn, args, background = self.jobs.get()
            self.busy, self.job_is_background, self.cancel_bg = True, background, False
            try:
                fn(*args)
            except CameraFailed as e:
                self.log(f"Camera refused that ({e}).")
                self.ui.put(("error", f"The camera refused that ({e}).\n\nThe connection is still open."))
                try:
                    self._read_settings()          # put the controls back to the camera's real state
                except CameraError:
                    pass
            except CameraError as e:
                self.log("Error:", e)
                self.ui.put(("error", f"{e}\n\nTip: close and reopen the lens cover (turns the camera off and on), then Connect again."))
                self._drop()
            except Exception as e:
                self.log("Error:", repr(e))
                self.ui.put(("error", repr(e)))
            finally:
                self.busy = self.job_is_background = False
                self.ui.put(("progress", (0, 1)))

    def _drop(self):
        if self.cam:
            try:
                self.cam.ser.close()
            except Exception:
                pass
        self.cam = None
        self.ui.put(("status", ("Not connected", False)))
        self.ui.put(("connected", False))

    def need_cam(self):
        if not self.cam:
            raise CameraError("Not connected. Slide the lens cover open and click Connect.")

    # ----------------------------------------------------------- picture list
    def _time(self, n):
        t = self.cam.times.get(n) if self.cam else None
        return t if t and t.year > 1995 else None

    def _base_name(self, n, res):
        t = self._time(n)
        stamp = t.strftime("%Y%m%d_%H%M%S") if t else f"{time.strftime('%Y%m%d_%H%M%S')}_{n:02d}"
        return os.path.join(self.photo_dir.get(), f"ES3000_{stamp}_{RES_NAMES[res]}")

    def _find_saved(self):
        """Pictures already downloaded earlier (dated pictures only - matched by file name)."""
        for n, res in self.pictures:
            if n in self.saved and os.path.exists(self.saved[n]):
                continue
            self.saved.pop(n, None)
            if self._time(n):
                base = self._base_name(n, res)
                for ext in [FORMATS.get(self.format_var.get(), ".png")] + list(FORMATS.values()):
                    if os.path.exists(base + ext):
                        self.saved[n] = base + ext
                        break

    def _thumb_img(self, n, res):
        img = self.thumbs.get((n, res, self._time(n)))
        if img is None:
            return Image.new("RGB", THUMB, (200, 200, 200))
        angle = self.rotations.get(self.saved.get(n, ""), 0)
        if angle:
            img = img.rotate(angle, expand=True)
        img = img.copy()
        img.thumbnail(THUMB, Image.BILINEAR)
        canvas = Image.new("RGB", THUMB, (240, 240, 240))
        canvas.paste(img, ((THUMB[0] - img.width) // 2, (THUMB[1] - img.height) // 2))
        return canvas

    def _row_text(self, n, res):
        t = self._time(n)
        when = t.strftime("%m/%d/%y  %H:%M") if t else "no date"
        mark = "   ✓ saved" if n in self.saved else ""
        return f"#{n:02d}  {RES_LONG[RES_NAMES[res]]}{mark}\n{when}"

    def _fill_list(self):
        self.pic_list.delete(*self.pic_list.get_children())
        self.tk_thumbs = {}
        for n, res in self.pictures:
            self.tk_thumbs[n] = ImageTk.PhotoImage(self._thumb_img(n, res))
            self.pic_list.insert("", "end", iid=str(n), image=self.tk_thumbs[n],
                                 values=(self._row_text(n, res),))

    def _set_row(self, n):
        if not self.pic_list.exists(str(n)):
            return
        res = dict(self.pictures).get(n)
        if res is None:
            return
        self.tk_thumbs[n] = ImageTk.PhotoImage(self._thumb_img(n, res))
        self.pic_list.item(str(n), image=self.tk_thumbs[n])
        self.pic_list.item(str(n), values=(self._row_text(n, res),))

    def _selected(self):
        nums = [int(i) for i in self.pic_list.selection()]
        return [(n, r) for n, r in self.pictures if n in nums]

    # --------------------------------------------------------------- actions
    def refresh_ports(self):
        ports = [p.device for p in list_ports.comports()]
        self.port_box["values"] = ["Auto"] + ports
        if self.port_var.get() not in self.port_box["values"]:
            self.port_var.set("Auto")

    def on_connect(self):
        if self.cam:
            self.run(self._disconnect)
        else:
            self.run(self._connect, self.port_var.get())

    def _disconnect(self):
        self.cam.close()
        self.cam = None
        self.ui.put(("status", ("Not connected", False)))
        self.ui.put(("connected", False))
        self.log("Disconnected.")

    def _connect(self, port):
        ports = [port] if port != "Auto" else [p.device for p in list_ports.comports()]
        last = self.settings.get("last_port")
        if last in ports:                      # try the port that worked last time first
            ports.remove(last)
            ports.insert(0, last)
        if not ports:
            raise CameraError("No serial ports found - is the USB-serial adapter plugged in?")
        for p in ports:
            self.log(f"Trying {p}…")
            cam = None
            try:
                cam = Camera(p, log=self.detail)
                cam.connect(attempts=2 if len(ports) > 1 else 5)
            except Exception:
                if cam:
                    try:
                        cam.ser.close()
                    except Exception:
                        pass
                continue
            self.cam = cam
            self.log(f"Connected on {p}.")
            self.settings["last_port"] = p
            self.ui.put(("status", (f"Connected ({p})", True)))
            self.ui.put(("connected", True))
            self.last_status = None
            self._read_settings()
            self._list()
            return
        raise CameraError("Camera not found. Check the cable, the batteries, and that the lens cover is open.")

    def _apply_speed(self):
        self.cam.fast_baud = SPEED_CHOICES.get(self.speed_var.get(), 57600)

    def _after_transfer(self):
        """If a fast transfer had to fall back, reflect that in the speed setting."""
        if self.cam and self.cam.fast_baud == 57600 and self.speed_var.get() != "Standard (57600)":
            self.log("This camera or cable doesn't support 115200 baud - switched back to Standard.")
            self.ui.put(("speed", "Standard (57600)"))

    def on_refresh_list(self):
        self.run(self._list)

    def _list(self):
        self.need_cam()
        old = self.pictures
        self.pictures = self.cam.list_pictures()
        if not self.pictures and old:
            time.sleep(1.5)      # camera may still be busy - try once more
            self.pictures = self.cam.list_pictures()
        if self.pictures != old[:len(self.pictures)]:
            self.saved = {}
        self._find_saved()
        self.ui.put(("pics", None))
        new = sum(1 for n, _ in self.pictures if n not in self.saved)
        self.log(f"{len(self.pictures)} picture(s) in camera" + (f", {new} not downloaded yet." if self.pictures else "."))
        if any((n, r, self._time(n)) not in self.thumbs for n, r in self.pictures):
            self.jobs.put((self._load_thumbs, (), True))

    def _load_thumbs(self):
        self.need_cam()
        self._apply_speed()
        todo = [(n, r) for n, r in self.pictures if (n, r, self._time(n)) not in self.thumbs]
        res_of = dict(todo)

        def got(n, data):
            try:
                self.thumbs[(n, res_of[n], self._time(n))] = chinon_decode.decode_thumbnail(data, res_of[n])
            except Exception as e:
                self.detail(f"thumbnail {n}: {e}")
            self.ui.put(("thumb", n))

        self.cam.thumbnails_raw([n for n, _ in todo], got, cancel=lambda: self.cancel_bg)
        self._after_transfer()

    def on_download_new(self):
        self.run(self._download, "new")

    def on_download_all(self):
        self.run(self._download, None)

    def on_download_sel(self):
        sel = self._selected()
        if not sel:
            self.log("Select a picture first.")
            return
        self.run(self._download, sel)

    def _download(self, which):
        self.need_cam()
        self._apply_speed()
        if not self.pictures:
            self._list()
        if which is None:
            which = self.pictures
        elif which == "new":
            which = [(n, r) for n, r in self.pictures if n not in self.saved]
            if not which:
                self.log("Nothing new - every picture is already downloaded.")
                return
        out = self.photo_dir.get()
        os.makedirs(out, exist_ok=True)
        total = sum(SIZES.get(r, 194560) for _, r in which)
        done = 0
        t_start = time.time()
        for i, (n, res) in enumerate(which, 1):
            self.log(f"Downloading picture {n} ({RES_LONG[RES_NAMES[res]]}) [{i}/{len(which)}]…")
            dct = self.cam.download_dct(n, res, lambda b: self.ui.put(("progress", (done + b, total))))
            done += SIZES.get(res, 194560)
            base = self._base_name(n, res)
            with open(base + ".DCT", "wb") as f:
                f.write(dct)
            img, _ = chinon_decode.decode(dct)
            ext = FORMATS.get(self.format_var.get(), ".png")
            save_image(img, base + ext)
            self.rotations.pop(base + ext, None)
            t = self._time(n)
            if t:
                ts = t.timestamp()
                for e in (".DCT", ext):
                    os.utime(base + e, (ts, ts))
            self.saved[n] = base + ext
            self.ui.put(("preview", (img, f"#{n:02d}  {os.path.basename(base)}{ext}")))
            self.ui.put(("thumb", n))
            self.log(f"  saved {os.path.basename(base)}{ext}")
        secs = time.time() - t_start
        self.log(f"Download finished: {len(which)} picture(s) in {secs:.0f} s "
                 f"({done / max(secs, 0.1) / 1024:.1f} KB/s at {self.cam.fast_baud} baud).")
        self._after_transfer()

    def on_select(self, _e=None):
        sel = self._selected()
        if not sel:
            return
        n, res = sel[0]
        path = self.saved.get(n)
        if path and os.path.exists(path):
            self._show(Image.open(path), f"#{n:02d}  {os.path.basename(path)}")
            return
        th = self.thumbs.get((n, res, self._time(n)))
        if th is not None:
            self._show(th, f"#{n:02d}  camera thumbnail - double-click to download the full picture")
        else:
            self._clear_preview(f"Picture {n} not downloaded yet.\nDouble-click it to download and view.")

    def _read_settings(self):
        try:
            st = self.cam.settings()
        except CameraError as e:
            self.log("Could not read camera settings:", e)
            return
        self.last_status = st["raw"]
        res = ["Superfine", "Fine", "Normal"]
        fl = ["Auto", "Fill (on)", "Off"]
        if st["resolution"] < 3: self.res_var.set(res[st["resolution"]])
        if st["flash"] < 3: self.flash_var.set(fl[st["flash"]])
        self.timer_var.set(bool(st["timer"]))
        if st["zoom"] <= 6:
            self.ui.put(("zoom", st["zoom"]))
        if st["focus"] < 3: self.focus_var.set(["Multi-spot", "Single-spot", "Macro"][st["focus"]])
        self._zoom_lock(st["raw"])
        clk = st["clock"]
        if clk.year < 2000:
            self.log("Camera clock is not set - click 'Sync camera clock to PC' so new photos get dates.")
        self._show_caminfo(st["raw"])
        self.detail("  status bytes 20-31: " + " ".join(f"{b:02X}" for b in st["raw"][20:32]))

    def _zoom_lock(self, st):
        """Like the original software: zoom only works in zoom mode 0 and not in Macro focus."""
        self.ui.put(("zoomlock", bool((st[21] >> 6) & 1) or ((st[21] >> 4) & 3) == 2))

    def _show_caminfo(self, st):
        clock = self.cam.camera_time(int.from_bytes(st[14:18], "little"))
        clk = clock.strftime("%m/%d/%y %H:%M") if clock.year >= 2000 else "not set"
        self.ui.put(("status", (f"Connected ({self.cam.port})", True)))
        bat = BATTERY.get(st[29], f"? (code {st[29]})")
        self.ui.put(("caminfo", f"Battery: {bat}\nSpace left: {st[11]} picture(s)\nCamera clock: {clk}"))
        if st[29] == 1 and not self._warned_battery:
            self._warned_battery = True
            self.log("Camera batteries are low - replace them soon (a transfer can fail on weak batteries).")

    def _status_diff(self, label):
        try:
            st = self.cam.status()
        except CameraError as e:
            self.detail("  (status read failed:", e, ")")
            return
        self._show_caminfo(st)
        self._zoom_lock(st)
        if self.last_status is not None:
            ch = [f"[{i}] {a:02X}->{b:02X}" for i, (a, b) in enumerate(zip(self.last_status, st)) if a != b]
            self.detail("  status changed: " + (", ".join(ch) if ch else "nothing"))
        self.last_status = st

    def _current_file(self):
        sel = self._selected()
        if not sel:
            return None, None
        n, res = sel[0]
        path = self.saved.get(n)
        return (sel[0], path) if path and os.path.exists(path) else (sel[0], None)

    def on_rotate(self, deg):
        pic, path = self._current_file()
        if not path:
            self.log("Rotate works on downloaded pictures - select one in the list first.")
            return
        angle = (self.rotations.get(path, 0) + deg) % 360
        dct = os.path.splitext(path)[0] + ".DCT"
        try:
            if os.path.exists(dct):          # always re-decode from the original: no quality loss
                img = chinon_decode.decode(open(dct, "rb").read())[0].rotate(angle, expand=True)
            else:
                img = Image.open(path).rotate(deg, expand=True)
            st = os.stat(path)
            save_image(img, path)
            os.utime(path, (st.st_atime, st.st_mtime))
        except OSError as e:
            messagebox.showerror(APP_TITLE, f"Could not rotate {os.path.basename(path)}:\n{e}")
            return
        if angle:
            self.rotations[path] = angle
        else:
            self.rotations.pop(path, None)
        self._save_settings()
        self._set_row(pic[0])
        self._show(img, f"#{pic[0]:02d}  {os.path.basename(path)}")

    def on_info(self):
        sel = self._selected()
        if not sel or not self.cam:
            self.log("Select a picture in the list first.")
            return
        n, res = sel[0]
        r = RES_NAMES[res]
        P = chinon_decode.PARAMS[r]
        t = self._time(n)
        inf = self.cam.infos.get(n, b"")
        size = int.from_bytes(inf[6:10], "little") if len(inf) >= 10 else 0
        path = self.saved.get(n)
        lines = [f"Picture #{n}",
                 f"Quality: {RES_LONG[r]} ({P['W']} x {P['H']} pixels)",
                 f"Taken: {t:%A %B %d, %Y  %I:%M:%S %p}" if t else "Taken: unknown (camera clock was not set)",
                 f"Data size in camera: {size:,} bytes" if size else "",
                 f"Saved as: {path}" if path and os.path.exists(path) else "Not downloaded yet"]
        if path and self.rotations.get(path):
            lines.append(f"Rotated {self.rotations[path]}° (the .DCT original is unchanged)")
        messagebox.showinfo(f"{APP_TITLE} - picture #{n}", "\n".join(l for l in lines if l))

    def on_pick_dir(self):
        d = filedialog.askdirectory(initialdir=self.photo_dir.get())
        if d:
            self.photo_dir.set(os.path.normpath(d))
            self._save_settings()
            if self.cam and not self.busy:
                self._find_saved()
                self._fill_list()

    def on_open_dir(self):
        d = self.photo_dir.get()
        os.makedirs(d, exist_ok=True)
        os.startfile(d)

    def on_convert(self):
        files = filedialog.askopenfilenames(title="Choose .DCT files",
                                            filetypes=[("Chinon DCT", "*.dct *.DCT")])
        if files:
            self.run(self._convert, files)

    def _convert(self, files):
        for f in files:
            img, res = chinon_decode.decode(open(f, "rb").read())
            out = os.path.splitext(f)[0] + FORMATS.get(self.format_var.get(), ".png")
            save_image(img, out)
            self.rotations.pop(out, None)
            self.ui.put(("preview", (img, os.path.basename(out))))
            self.log(f"Converted {os.path.basename(f)} -> {os.path.basename(out)}")

    # control
    def _ctl(self, label, fn, v, shown):
        self.need_cam()
        if self.last_status is None:
            self._status_diff("baseline")
        fn(v)
        self.log(f"{label}: {shown}")
        self._status_diff(label)

    def on_set_res(self, v):   self.run(self._ctl, "Resolution", lambda x: self.cam.set_resolution(x), v, self.res_var.get())
    def on_set_flash(self, v): self.run(self._ctl, "Flash", lambda x: self.cam.set_flash(x), v, self.flash_var.get())
    def on_set_focus(self, v): self.run(self._ctl, "Focus", lambda x: self.cam.set_focus(x), v, self.focus_var.get())
    def on_set_zoom(self):
        if "disabled" in self.zoom_scale.state():
            return
        self.run(self._ctl, "Zoom", lambda x: self.cam.set_zoom_level(x), self.zoom_var.get(), self.zoom_var.get())

    def on_set_timer(self):    self.run(self._ctl, "Self-timer", lambda x: self.cam.set_timer(x), self.timer_var.get(),
                                        "on" if self.timer_var.get() else "off")

    def _sync_clock(self):
        self.need_cam()
        t = self.cam.set_clock()
        after = self.cam.status()
        self.detail(f"  clock value {t:08X}")
        self.log(f"Camera clock set to {self.cam.camera_time(int.from_bytes(after[14:18], 'little')):%m/%d/%Y %H:%M:%S}.")
        self.last_status = after
        self._show_caminfo(after)

    def on_shoot(self):
        res = ["Superfine", "Fine", "Normal"].index(self.res_var.get())
        self.run(self._shoot, res)

    def _shoot(self, res):
        self.need_cam()
        self.log("Taking picture" + (" (self-timer)…" if self.timer_var.get() else "…"))
        self.cam.shoot(res)
        self.log("Picture taken.")
        self._list()
        self._status_diff("shoot")

    def on_erase(self):
        if not messagebox.askyesno(
                APP_TITLE,
                "Erase ALL pictures from the camera?\n\nThis cannot be undone. "
                "Download them first if you want to keep them.", icon="warning"):
            return
        self.run(self._erase)

    def _erase(self):
        self.need_cam()
        self.log("Erasing all pictures (can take up to a minute)…")
        self.cam.erase_all()
        self.log("Camera erased.")
        pics = []
        for _ in range(8):           # camera reports old pictures for a few seconds
            pics = self.cam.list_pictures()
            if not pics:
                break
            time.sleep(1.5)
        self.pictures, self.saved = pics, {}
        self.ui.put(("pics", None))
        self.ui.put(("clear", "Camera is empty."))
        self.log(f"{len(pics)} picture(s) in camera.")
        self._status_diff("erase")


if __name__ == "__main__":
    App().mainloop()
