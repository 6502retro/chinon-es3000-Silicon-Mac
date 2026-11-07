r"""
Chinon ES-3000 serial sniffer / bridge
--------------------------------------
Sits between the Windows XP VM and the real camera and logs every byte.

    XP VM (COM1)  <--TCP-->  this script  <--COM3-->  USB serial adapter  -->  camera

VirtualBox setup (VM powered off):
    Settings -> Serial Ports -> Port 1
        Enable Serial Port: yes
        Port Number:        COM1
        Port Mode:          TCP
        Connect to existing pipe/socket: UNCHECKED  (VirtualBox is the server)
        Path/Address:       2323

Run on Windows 11 BEFORE starting the VM is fine; the script retries until the VM is up:
    py -m pip install pyserial
    py chinon_sniffer.py --port COM3

Keys while running (in this console window):
    b   toggle the real COM port between 9600 and 57600 baud
    m   write a marker line into the log (e.g. "about to download superfine")
    q   quit

Why the 'b' key: a TCP link carries bytes but not baud-rate changes. The Chinon software
talks at 9600 for commands and switches to 57600 for image downloads. Until we've found
the command that triggers the switch, you flip it by hand when the download starts
(or use --switch-on HEX once we know the trigger bytes).

Logs go to .\logs\ as:
    session_YYYYmmdd_HHMMSS.txt   human-readable, timestamped, direction-tagged hex+ASCII
    session_..._host.bin          raw bytes PC -> camera
    session_..._cam.bin           raw bytes camera -> PC
"""

import argparse
import msvcrt
import os
import socket
import sys
import threading
import time
from datetime import datetime

import serial  # pyserial

HELLO = bytes.fromhex("7E 00 00 00 00 00 00 1A")
lock = threading.Lock()
running = True


class Logger:
    def __init__(self, folder):
        os.makedirs(folder, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        base = os.path.join(folder, f"session_{stamp}")
        self.txt = open(base + ".txt", "w", encoding="utf-8")
        self.host_bin = open(base + "_host.bin", "wb")
        self.cam_bin = open(base + "_cam.bin", "wb")
        self.t0 = time.perf_counter()
        self.last_dir = None
        self.base = base

    def note(self, msg):
        line = f"{time.perf_counter() - self.t0:10.4f}  ##  {msg}"
        with lock:
            self.txt.write(line + "\n")
            self.txt.flush()
        print(line)

    def data(self, direction, chunk, baud):
        t = time.perf_counter() - self.t0
        (self.host_bin if direction == "PC>CAM" else self.cam_bin).write(chunk)
        with lock:
            for i in range(0, len(chunk), 16):
                part = chunk[i:i + 16]
                hexs = " ".join(f"{b:02X}" for b in part)
                asc = "".join(chr(b) if 32 <= b < 127 else "." for b in part)
                self.txt.write(f"{t:10.4f}  {direction}  @{baud:<5}  {hexs:<47}  |{asc}|\n")
            self.txt.flush()
        if direction != self.last_dir or len(chunk) < 64:
            preview = " ".join(f"{b:02X}" for b in chunk[:24])
            more = " ..." if len(chunk) > 24 else ""
            print(f"{t:10.4f}  {direction}  {len(chunk):5d} B  {preview}{more}")
        self.last_dir = direction

    def close(self):
        for f in (self.txt, self.host_bin, self.cam_bin):
            f.close()


def connect_vm(port_num):
    while running:
        try:
            s = socket.create_connection(("127.0.0.1", port_num), timeout=2)
            s.settimeout(0.05)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            return s
        except OSError:
            print(f"Waiting for the VM's serial port on TCP {port_num}... (start the VM)")
            time.sleep(2)
    return None


def main():
    global running
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM3", help="real COM port of the USB serial adapter")
    ap.add_argument("--tcp", type=int, default=2323, help="VirtualBox serial TCP port")
    ap.add_argument("--baud", type=int, default=9600, help="starting baud")
    ap.add_argument("--fast", type=int, default=57600, help="download baud")
    ap.add_argument("--switch-on", default="", help="hex bytes from PC that trigger the fast baud, e.g. '1B 53'")
    ap.add_argument("--logs", default="logs")
    ap.add_argument("--parity", default="E", choices="NEO", help="serial parity (camera appears to use EVEN)")
    ap.add_argument("--no-wake-break", dest="wake_break", action="store_false",
                    help="don't send a BREAK before the hello packet")
    args = ap.parse_args()

    trigger = bytes.fromhex(args.switch_on) if args.switch_on else b""
    log = Logger(args.logs)
    log.note(f"session start  port={args.port}  tcp={args.tcp}  baud={args.baud}  parity={args.parity}")

    ser = serial.Serial(args.port, args.baud, bytesize=8, parity=args.parity, stopbits=1, timeout=0.02)
    state = {"baud": args.baud, "recent": b""}

    def set_baud(new):
        ser.baudrate = new
        state["baud"] = new
        log.note(f"COM baud -> {new}")

    vm = connect_vm(args.tcp)
    if vm is None:
        return
    log.note("VM connected")
    print("Keys: b = toggle baud, m = marker, q = quit")

    def vm_to_cam():
        global running
        while running:
            try:
                chunk = vm.recv(4096)
                if not chunk:
                    log.note("VM closed the serial connection")
                    running = False
                    break
            except socket.timeout:
                continue
            except OSError as e:
                log.note(f"VM socket error: {e}")
                running = False
                break
            # The original software wakes the camera with a ~200 ms BREAK (SetCommBreak in
            # ESC3K100.DLL) before its hello packet. VirtualBox's TCP mode drops breaks,
            # so recreate it here when we see the hello.
            if args.wake_break and chunk.startswith(HELLO) and time.time() - state.get("last_break", 0) > 2:
                ser.flush()
                if state["baud"] != args.baud:
                    set_baud(args.baud)  # new session: camera is back at the command speed
                ser.send_break(duration=0.2)
                time.sleep(0.05)
                state["last_break"] = time.time()
                log.note("sent BREAK 200 ms (wake) before hello")
            log.data("PC>CAM", chunk, state["baud"])
            ser.write(chunk)
            # Command 0x41 = set speed; args carry the baud as hex digits (41 00 57 60 = 57600).
            if len(chunk) >= 8 and chunk[0] == 0x41 and chunk[7] == 0x1A:
                digits = f"{chunk[2]:02X}{chunk[3]:02X}"
                table = {"5760": 57600, "9600": 9600, "0960": 9600, "1920": 19200,
                         "3840": 38400, "1152": 115200, "2880": 28800, "1440": 14400}
                if digits in table:
                    state["pending_baud"] = table[digits]
                    log.note(f"speed-change command seen -> {table[digits]} (waiting for D1)")
            if trigger:
                state["recent"] = (state["recent"] + chunk)[-64:]
                if trigger in state["recent"] and state["baud"] != args.fast:
                    ser.flush()
                    time.sleep(0.05)
                    set_baud(args.fast)
                    state["recent"] = b""

    def cam_to_vm():
        global running
        while running:
            try:
                chunk = ser.read(4096)
            except serial.SerialException as e:
                log.note(f"COM error: {e}")
                running = False
                break
            if chunk:
                log.data("CAM>PC", chunk, state["baud"])
                try:
                    vm.sendall(chunk)
                except OSError:
                    running = False
                    break
                if state.get("pending_baud") and 0xD1 in chunk:
                    new = state.pop("pending_baud")
                    time.sleep(0.01)
                    set_baud(new)

    threads = [threading.Thread(target=vm_to_cam, daemon=True),
               threading.Thread(target=cam_to_vm, daemon=True)]
    for t in threads:
        t.start()

    # Remote control: write one command per line to control.txt next to this script.
    #   baud 57600 | baud 9600 | toggle | mark <text> | quit
    ctl_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "control.txt")
    ctl_state = {"seen": os.path.getmtime(ctl_path) if os.path.exists(ctl_path) else 0}

    def poll_control():
        global running
        try:
            mt = os.path.getmtime(ctl_path)
        except OSError:
            return
        if mt == ctl_state["seen"]:
            return
        ctl_state["seen"] = mt
        try:
            lines = open(ctl_path, encoding="utf-8").read().splitlines()
        except OSError:
            return
        for line in lines:
            cmd, _, rest = line.strip().partition(" ")
            cmd = cmd.lower()
            if cmd == "baud" and rest.strip().isdigit():
                set_baud(int(rest.strip()))
            elif cmd == "parity" and rest.strip().upper() in ("N", "E", "O"):
                ser.parity = rest.strip().upper()
                log.note(f"COM parity -> {ser.parity}")
            elif cmd == "toggle":
                set_baud(args.fast if state["baud"] == args.baud else args.baud)
            elif cmd == "mark":
                log.note("MARK " + rest)
            elif cmd == "quit":
                running = False

    try:
        while running:
            poll_control()
            if msvcrt.kbhit():
                k = msvcrt.getwch().lower()
                if k == "b":
                    set_baud(args.fast if state["baud"] == args.baud else args.baud)
                elif k == "m":
                    print("Marker text: ", end="", flush=True)
                    log.note("MARK " + input())
                elif k == "q":
                    running = False
            time.sleep(0.05)
    except KeyboardInterrupt:
        running = False
    finally:
        log.note("session end")
        log.close()
        ser.close()
        vm.close()
        print(f"\nLogs saved: {log.base}.txt (+ _host.bin, _cam.bin)")


if __name__ == "__main__":
    main()
