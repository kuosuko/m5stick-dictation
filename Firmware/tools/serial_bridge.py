"""Holds the Stick's serial port: logs every line, forwards commands written to
a FIFO, and saves `shot` replies as PNG. Development only.

    python serial_bridge.py <log> <fifo> <shot-dir>
    echo "demo ready" > <fifo>; echo shot > <fifo>
"""
import glob, os, struct, sys, threading, time, zlib
import serial

log_path, fifo_path, shot_dir = sys.argv[1:4]
os.makedirs(shot_dir, exist_ok=True)
if not os.path.exists(fifo_path):
    os.mkfifo(fifo_path)
log = open(log_path, "a", buffering=1)
port = None


def png(path, width, height, rgb565):
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            i = (y * width + x) * 2
            v = (rgb565[i] << 8) | rgb565[i + 1]  # big-endian in LovyanGFX sprites
            rows += bytes(((v >> 11) * 255 // 31, ((v >> 5) & 63) * 255 // 63, (v & 31) * 255 // 31))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))


def commands():
    while True:
        with open(fifo_path) as fifo:
            for line in fifo:
                name = line.strip()
                if port and name:
                    port.write((name + "\n").encode())
                    log.write(time.strftime("%H:%M:%S ") + "> " + name + "\n")


threading.Thread(target=commands, daemon=True).start()
shots = 0
while True:
    try:
        found = glob.glob("/dev/cu.usbmodem*")
        if not found:
            time.sleep(0.5)
            continue
        port = serial.Serial()
        port.port, port.baudrate, port.timeout = found[0], 115200, 0.5
        port.dtr = False
        port.rts = False
        port.open()
        while True:
            raw = port.readline()
            if not raw:
                continue
            text = raw.decode(errors="replace").rstrip()
            if text.startswith("SHOT "):
                width, height = map(int, text.split()[1:3])
                data = port.read(width * height * 2)
                shots += 1
                path = os.path.join(shot_dir, time.strftime("%H%M%S") + f"-{shots}.png")
                png(path, width, height, data)
                text = "shot saved " + path
            log.write(time.strftime("%H:%M:%S ") + text + "\n")
    except Exception as error:
        port = None
        log.write(time.strftime("%H:%M:%S ") + "bridge: " + type(error).__name__ + "\n")
        time.sleep(1)
