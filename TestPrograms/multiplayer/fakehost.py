# A stand-in for the iPhone that plays: lets every controller in as player 2 and prints what it sends.
# Usage: fakehost.py <port> [system, e.g. gc or wii] [Wii controller, e.g. nunchuk]
# Once a controller is in, it vibrates for a second every four seconds, at half and then full strength.
import socket, struct, sys, time
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", port))
s.settimeout(0.5)
def status():
    system, title = (sys.argv[2] if len(sys.argv) > 2 else "gc").encode(), b"Nep-host"
    controller = sys.argv[3].encode() if len(sys.argv) > 3 else b""
    return (bytes([0x41, 0x50, 3, 2, 1, 2]) + bytes([len(system)]) + system + bytes([len(title)]) + title
            + bytes([len(controller)]) + controller)
client = None
last = None
start = time.time()
while time.time() - start < 120:
    try:
        data, addr = s.recvfrom(512)
        client = addr
        if len(data) >= 4 and data[3] == 1:
            s.sendto(status(), addr)
        elif len(data) >= 4 and data[3] == 3:
            mask, lx, ly, rx, ry, mx, my, mz = struct.unpack("<Ihhhhhhh", data[20:38])
            if (mask, lx, ly, rx, ry) != last:
                print(f"{time.time()-start:5.1f}s knoppen {mask:b} stick {lx} {ly} rechts {rx} {ry} beweging {mx} {my} {mz}", flush=True)
                last = (mask, lx, ly, rx, ry)
        elif len(data) >= 4 and data[3] == 4:
            print("controller left", flush=True)
    except socket.timeout:
        pass
    if client:
        s.sendto(status(), client)
        t = time.time() - start
        strength = (128 if int(t / 4) % 2 else 255) if t % 4 < 1 else 0
        s.sendto(bytes([0x41, 0x50, 3, 5, strength]), client)
