# A stand-in for a controller iPhone: asks to join over loopback, then presses buttons once let in.
import socket, struct, sys, time, uuid
port = int(sys.argv[1])
me = uuid.uuid4().bytes
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(0.05)
hello = bytes([0x41, 0x50, 3, 1]) + me
def pad(mask, lx=0, ly=0):
    # Held level: the Wii Remote's accelerometer reads 1 g up (in thousandths of g).
    return bytes([0x41, 0x50, 3, 3]) + me + struct.pack("<Ihhhhhhh", mask, lx, ly, 0, 0, 0, 0, 1000)
accepted_at = None
last_hello = 0
start = time.time()
names = {0: "waiting", 1: "accepted", 2: "rejected", 3: "full", 4: "ended"}
seen = None
while time.time() - start < 90:
    now = time.time()
    if accepted_at is None and now - last_hello > 0.4:
        s.sendto(hello, ("127.0.0.1", port)); last_hello = now
    if accepted_at is not None:
        t = now - accepted_at
        # A (bit 8) held for 1 s, then nothing, then B (bit 0) and the stick right for 1 s, then nothing.
        mask, lx = (1 << 8, 0) if 1 < t < 2 else ((1 << 0, 0x7FFF) if 3 < t < 4 else (0, 0))
        s.sendto(pad(mask, lx), ("127.0.0.1", port))
        if t > 6:
            s.sendto(bytes([0x41, 0x50, 3, 4]) + me, ("127.0.0.1", port)); print("left", flush=True); break
    try:
        data, _ = s.recvfrom(512)
        if len(data) == 5 and data[3] == 5:
            print(f"{time.time()-start:5.1f}s trillen {data[4]}", flush=True)
        if len(data) > 5 and data[3] == 2:
            status = names.get(data[4]); player = data[5]
            if status != seen:
                print(f"{time.time()-start:5.1f}s status {status} player {player}", flush=True); seen = status
            if status == "accepted" and accepted_at is None:
                accepted_at = time.time()
            if status in ("rejected", "full", "ended"):
                break
    except socket.timeout:
        pass
    time.sleep(0.016)
