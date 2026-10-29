# A stand-in for a controller iPhone on a bumpy connection, to check the figures under Prestaties
# tonen (LinkMonitor): sends stamped input messages every 16 ms, holds them back for 60 ms once a
# second and then lets them through together (as AWDL can), and loses one in fifty.
# Expected on the host: about 61/s, largest gap about 60-70 ms, network max about 60 ms, 2% lost.
# Usage: python3 fakepad_timing.py <host UDP port> [seconds]
import random, socket, struct, sys, time, uuid

port = int(sys.argv[1])
duration = float(sys.argv[2]) if len(sys.argv) > 2 else 30
me = uuid.uuid4().bytes
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(0.002)
hello = bytes([0x41, 0x50, 3, 1]) + me

def pad(sequence, sent):
    # Held level (1 g up); then the stamp: number and uptime in tenths of a millisecond.
    return (bytes([0x41, 0x50, 3, 3]) + me + struct.pack("<Ihhhhhhh", 0, 0, 0, 0, 0, 0, 0, 1000)
            + struct.pack("<HI", sequence & 0xFFFF, int(sent * 10_000) & 0xFFFFFFFF))

accepted = None
last_hello = 0
sequence = 0
held = []
next_send = 0
start = time.monotonic()
while time.monotonic() - start < 120:
    now = time.monotonic()
    if accepted is None:
        if now - last_hello > 0.4:
            s.sendto(hello, ("127.0.0.1", port)); last_hello = now
    else:
        if now - accepted > duration:
            s.sendto(bytes([0x41, 0x50, 3, 4]) + me, ("127.0.0.1", port)); print("left", flush=True); break
        if now >= next_send:
            next_send = now + 0.016
            sequence += 1
            message = pad(sequence, now)
            if random.random() >= 0.02:
                held.append(message)
        # Held back for 60 ms at the start of every second.
        if (now - accepted) % 1.0 >= 0.06:
            for message in held:
                s.sendto(message, ("127.0.0.1", port))
            held = []
    try:
        data, _ = s.recvfrom(512)
        if len(data) > 5 and data[3] == 2:
            if data[4] == 1 and accepted is None:
                accepted = time.monotonic(); print("accepted as player", data[5], flush=True)
            if data[4] in (2, 3, 4):
                print("status", data[4], flush=True); break
    except socket.timeout:
        pass
