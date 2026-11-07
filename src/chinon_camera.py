r"""
Chinon ES-3000 serial protocol (reverse-engineered from ESC3K100.DLL, Monsoon Software 1995,
plus serial captures, Nov 2026).

Link     9600 baud 8E1; wake with ~200 ms BREAK. Image transfers at 57600 (command 41).
Command  8 bytes: CMD 00 a b c d e 1A  ->  camera replies D1 (accepted) or E1 (rejected),
         then performs the action and sends ONE completion byte: 00 = success.
Data     packets of N data bytes + XOR checksum; host acks each with D2.

  7E                 hello                        (ESCComm::Open)
  7F                 camera status, 256 B packet  (GetCameraStatus)
  55 00 00 n         picture n info, 256 B        (GetImageInfo)
  56 00 00 n         picture n thumbnail, 1 KB packets: the first byte(s) of every
                     compressed block of the picture (DC terms), FF padded
  51 00 00 n         picture n full image, 1 KB packets
  41 00 hh ll        link speed, first 4 digits as BCD: 96 00 = 9600, 19 20, 38 40,
                     57 60 = 57600, 11 52 = 115200 (all five are in the DLL's speed table)
  71 00 v            resolution 0=Superfine 1=Fine 2=Normal        (SetResolution)
  72 00 v            flash      0..2 (Auto/sensor, Fill, Off)      (SetFlashMode)
  73 00 v            focus      0..2 (Multi-spot, Single-spot, Macro) (SetAutoFocusMode)
  79 00 v            zoom mode  0..1                               (SetZoomMode)
  78 00 v            zoom level 0..6                               (SetZoomLevel)
  74 00 v            self-timer 0/1                                (SetTimer)
  77                 take picture (internal memory; 7C = card)     (Shoot)
  7A                 ERASE ALL pictures (internal memory; 7B = card) (EraseImages)
  75 00 t0 t1 t2 t3  set clock: t = half-seconds since 1994-01-01, LE (SetTime)
"""
import datetime
import struct
import time
from functools import reduce

import serial

RES_NAMES = {0: "SF", 1: "F", 2: "N"}


def xor(data):
    return reduce(lambda a, b: a ^ b, data, 0)


def dct_header(raw_len, res):
    h = bytearray(384)
    h[0:4] = b"Cdcx"
    h[7] = 0x02
    h[8] = 0x80
    struct.pack_into("<H", h, 9, raw_len // 256 - 1)
    h[12] = res
    return bytes(h)


class CameraError(IOError):
    pass


class CameraFailed(CameraError):
    """Camera accepted a command but reported a failure code (e.g. E2 = not allowed in the
    current mode). The link is still fine."""


class CameraRejected(CameraError):
    """Camera answered E1 (e.g. no such picture) - retrying won't help."""


class Camera:
    def __init__(self, port, log=None):
        self.ser = serial.Serial(port, 9600, bytesize=8, parity="E", stopbits=1, timeout=1)
        self.port = port
        self.times = {}
        self.infos = {}                 # picture number -> raw 256-byte info packet
        self.fast_baud = 57600          # transfer speed for images/thumbnails
        self.log = log or (lambda *a: None)
        self.last_cmd = 0

    # ---- low level -------------------------------------------------------
    def read_exact(self, n, timeout=2.0):
        self.ser.timeout = timeout
        data = self.ser.read(n)
        if len(data) != n:
            raise CameraError(f"timeout: wanted {n} bytes, got {len(data)}")
        return data

    def drain(self, wait=0.2):
        time.sleep(wait)
        if self.ser.in_waiting:
            self.ser.read(self.ser.in_waiting)

    def command(self, cmd, a=0, b=0, c=0, d=0, e=0):
        wait = 0.1 - (time.time() - self.last_cmd)  # >=100 ms between commands
        if wait > 0:
            time.sleep(wait)
        pkt = bytes([cmd, 0, a, b, c, d, e, 0x1A])
        self.ser.reset_input_buffer()
        self.ser.write(pkt)
        self.last_cmd = time.time()
        r = self.read_exact(1)
        self.log(f"> {pkt.hex(' ')}  < {r.hex()}")
        if r[0] != 0xD1:
            raise CameraRejected(f"camera rejected command {cmd:02X} (reply {r[0]:02X})")

    def finish(self, timeout):
        """Wait for the completion byte (00 = success)."""
        r = self.read_exact(1, timeout=timeout)
        if r[0] != 0:
            raise CameraFailed(f"code {r[0]:02X}")

    def simple(self, cmd, value=0, timeout=5.0):
        self.command(cmd, value)
        self.finish(timeout)

    def read_packet(self, size):
        p = self.read_exact(size + 1)
        if xor(p[:-1]) != p[-1]:
            raise CameraError("checksum error")
        self.ser.write(b"\xD2")
        return p[:-1]

    def read_short_block(self):
        data = self.read_packet(256)
        self.drain()
        return data

    SPEEDS = {9600: (0x96, 0x00), 19200: (0x19, 0x20), 38400: (0x38, 0x40),
              57600: (0x57, 0x60), 115200: (0x11, 0x52)}

    def set_speed(self, baud):
        if self.ser.baudrate == baud:
            return
        arg = self.SPEEDS[baud]
        self.command(0x41, arg[0], arg[1])
        self.ser.flush()
        time.sleep(0.05)
        self.ser.baudrate = baud

    # ---- session ---------------------------------------------------------
    def connect(self, attempts=5):
        for _ in range(attempts):
            self.ser.baudrate = 9600
            self.ser.send_break(duration=0.2)
            time.sleep(0.1)
            try:
                self.command(0x7E)
                self.drain()
                return
            except CameraError as e:
                self.log("hello failed:", e)
                time.sleep(0.3)
        raise CameraError("could not connect - cover open, cable in, fresh batteries?")

    def close(self):
        try:
            self.set_speed(9600)
        except Exception:
            pass
        self.ser.close()

    # ---- queries ---------------------------------------------------------
    def status(self, retries=4):
        """256-byte status. Known bytes: [11] pictures left, [14..17] clock (LE half-seconds
        since 1994), [21] lens: low nibble zoom 0-6, high nibble focus mode,
        [22] self-timer, [23] resolution, [24] flash, [29] battery (0 ok, 1 low - from the DLL's
        UpdateBatteryIcon). Byte 21 per InterpretCameraStatus: bits 0-3 zoom, 4-5 focus, 6 zoom mode."""
        for i in range(retries):
            try:
                self.command(0x7F)
                return self.read_short_block()
            except CameraError:
                if i == retries - 1:
                    raise
                time.sleep(0.8)   # camera busy (e.g. lens still moving)
                self.drain(0.2)

    def settings(self):
        st = self.status()
        return {"pictures_left": st[11], "timer": st[22], "resolution": st[23],
                "flash": st[24], "zoom": st[21] & 0x0F, "focus": (st[21] >> 4) & 3,
                "zoom_mode": (st[21] >> 6) & 1, "battery": st[29],
                "clock": self.camera_time(struct.unpack_from("<I", st, 14)[0]), "raw": st}

    def info(self, n, retries=3):
        for i in range(retries):
            try:
                self.command(0x55, 0, n)
                return self.read_short_block()
            except CameraRejected:
                raise
            except CameraError:
                if i == retries - 1:
                    raise
                time.sleep(0.8)
                self.drain(0.2)

    @staticmethod
    def camera_time(t):
        """Camera time (half-seconds since 1994-01-01) -> datetime."""
        return datetime.datetime(1994, 1, 1) + datetime.timedelta(seconds=t / 2)

    def wait_ready(self, timeout=30):
        """Poll until the camera answers again (it is silent while processing a shot)."""
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                return self.status(retries=1)
            except CameraError:
                time.sleep(1.0)
                self.drain(0.2)
        raise CameraError("camera did not become ready")

    def list_pictures(self, maximum=40):
        pics = []
        self.times, self.infos = {}, {}
        for n in range(1, maximum + 1):
            try:
                inf = self.info(n)
            except CameraError:
                self.drain(0.3)
                break
            if inf[2] != n:
                break
            pics.append((n, inf[4]))
            self.infos[n] = inf
            self.times[n] = self.camera_time(struct.unpack_from("<I", inf, 10)[0])
        return pics

    def _read_blocks(self, cmd, n, progress=None):
        """Send cmd for picture n and collect its 1 KB packets until the 00 completion byte."""
        self.command(cmd, 0, n)
        data = bytearray()
        while True:
            first = self.read_exact(1, timeout=3)
            self.ser.timeout = 0.25
            rest = self.ser.read(1024)
            if not rest and first == b"\x00":
                break  # completion byte
            if len(rest) < 1024:
                rest += self.read_exact(1024 - len(rest))
            p = first + rest
            if xor(p[:-1]) != p[-1]:
                raise CameraError(f"checksum error in packet {len(data) // 1024 + 1}")
            data += p[:-1]
            self.ser.write(b"\xD2")
            if progress:
                progress(len(data))
        return bytes(data)

    def _fast(self, fn):
        """Run fn at the fast transfer speed. If a speed above 57600 fails, recover the link,
        fall back to 57600 for the rest of the session and retry once."""
        try:
            self.set_speed(self.fast_baud)
            return fn()
        except CameraError as e:
            if self.fast_baud <= 57600:
                raise
            self.log(f"{self.fast_baud} baud failed ({e}) - falling back to 57600.")
            self.fast_baud = 57600
            self.ser.baudrate = 9600
            self.drain(1.0)
            self.connect()
            self.set_speed(57600)
            return fn()
        finally:
            try:
                self.set_speed(9600)
            except CameraError:
                self.ser.baudrate = 9600

    def image(self, n, progress=None):
        return self._fast(lambda: self._read_blocks(0x51, n, progress))

    def thumbnail_raw(self, n):
        return self._fast(lambda: self._read_blocks(0x56, n))

    def thumbnails_raw(self, numbers, on_each, cancel=None):
        """Fetch several thumbnails in one fast-speed session, calling on_each(n, data)."""
        todo = list(numbers)
        def run():
            while todo:
                if cancel and cancel():
                    return
                n = todo[0]
                on_each(n, self._read_blocks(0x56, n))
                todo.pop(0)
        self._fast(run)

    def download_dct(self, n, res, progress=None):
        raw = self.image(n, progress)
        return dct_header(len(raw), res) + raw

    # ---- control (from ESC3K100.DLL; all verified on hardware Nov 2026) ----
    def set_resolution(self, v):  self.simple(0x71, v)       # 0 SF, 1 F, 2 N
    def set_flash(self, v):       self.simple(0x72, v)       # 0..2
    def set_focus(self, v):       self.simple(0x73, v, 10); time.sleep(1.0)   # 0..2, lens moves
    def set_zoom_mode(self, v):   self.simple(0x79, v)       # 0..1
    def set_zoom_level(self, v):  self.simple(0x78, v, 10); time.sleep(1.5)   # 0..6, lens moves
    def set_timer(self, on):      self.simple(0x74, 1 if on else 0)

    def set_clock(self, when=None):
        """Camera clock = half-seconds since 1994-01-01 00:00 (from ESCComm::SetTime)."""
        when = when or datetime.datetime.now()
        t = int((when - datetime.datetime(1994, 1, 1)).total_seconds()) * 2
        b = t.to_bytes(4, "little")
        self.command(0x75, b[0], b[1], b[2], b[3], 0)
        self.finish(5)
        return t

    def shoot(self, res_hint=0):
        timeout = {0: 25, 1: 20, 2: 11}.get(res_hint, 25) + 15  # original: 25/20/11 s (+ timer margin)
        self.simple(0x77, 0, timeout)
        time.sleep(1.0)
        self.wait_ready()

    def erase_all(self):
        self.simple(0x7A, 0, 80)
        time.sleep(1.0)
        self.wait_ready()
