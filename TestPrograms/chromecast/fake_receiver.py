# A stand-in for a Chromecast's mirroring receiver, to test Attic's Cast code on the Mac: the
# CASTV2 control connection (TLS, protobuf-framed JSON), the OFFER/ANSWER, and Cast Streaming
# over UDP (RTP with the Cast header, AES-128-CTR, RTCP sender reports, feedback with lost
# packets, a picture-loss request). It loses 3% of the packets on purpose and asks for a key
# frame after two seconds. The frames it puts together are written to frames.bin (each as a
# 4-byte big-endian length and the frame), for decode_check.swift.
# Usage: python3 -I fake_receiver.py <folder for the certificate and frames.bin> [port, 8009] [alle]
# "alle" listens on every address instead of only 127.0.0.1, so that the app in the Simulator can
# find it once it is announced like a Chromecast:
#   dns-sd -R Nep-Chromecast _googlecast._tcp local <port> fn=Nep-tv md=Proef
import ctypes, json, os, random, socket, ssl, struct, subprocess, sys, threading, time

folder = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8009
everywhere = "alle" in sys.argv[3:]

def bound(kind, port):
    # IPv6 and IPv4 together when listening everywhere.
    if not everywhere:
        sock = socket.socket(socket.AF_INET, kind)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", port)); return sock
    sock = socket.socket(socket.AF_INET6, kind)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    sock.bind(("::", port)); return sock
cert, key = os.path.join(folder, "cert.pem"), os.path.join(folder, "key.pem")
if not os.path.exists(cert):
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                    "-days", "2", "-subj", "/CN=fake-chromecast"], check=True, capture_output=True)

commoncrypto = ctypes.CDLL("/usr/lib/system/libcommonCrypto.dylib")

def aes_ecb(key_bytes, data):
    out = ctypes.create_string_buffer(len(data))
    moved = ctypes.c_size_t()
    # kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode
    status = commoncrypto.CCCrypt(0, 0, 2, key_bytes, 16, None, data, len(data), out, len(data), ctypes.byref(moved))
    assert status == 0, status
    return out.raw

def decrypt(data, frame_id, key_bytes, iv_mask):
    nonce = bytearray(iv_mask)
    for i, b in enumerate(struct.pack(">I", frame_id & 0xFFFFFFFF)):
        nonce[8 + i] ^= b
    start = int.from_bytes(nonce, "big")
    blocks = (len(data) + 15) // 16
    counters = b"".join(((start + n) % (1 << 128)).to_bytes(16, "big") for n in range(blocks))
    stream = aes_ecb(key_bytes, counters)
    return bytes(a ^ b for a, b in zip(data, stream))

# Protobuf CastMessage, only what is needed.
def varint(value):
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80); value >>= 7
    out.append(value)
    return bytes(out)

def encode(source, destination, namespace, payload):
    body = varint(1 << 3) + varint(0)
    for field, text in ((2, source), (3, destination), (4, namespace)):
        raw = text.encode(); body += varint(field << 3 | 2) + varint(len(raw)) + raw
    body += varint(5 << 3) + varint(0)
    raw = json.dumps(payload).encode(); body += varint(6 << 3 | 2) + varint(len(raw)) + raw
    return struct.pack(">I", len(body)) + body

def decode(body):
    fields, i = {}, 0
    def read_varint():
        nonlocal i
        value = shift = 0
        while True:
            b = body[i]; i += 1
            value |= (b & 0x7F) << shift
            if b < 0x80: return value
            shift += 7
    while i < len(body):
        tag = read_varint()
        if tag & 7 == 0:
            fields[tag >> 3] = read_varint()
        elif tag & 7 == 2:
            length = read_varint(); fields[tag >> 3] = body[i:i + length]; i += length
        else:
            raise ValueError("wire type %d" % (tag & 7))
    return fields[2].decode(), fields[3].decode(), fields[4].decode(), json.loads(fields.get(6, b"{}"))

stats = {"packets": 0, "dropped": 0, "resent_in": 0, "frames": 0, "keyframes": 0, "reports": 0, "bad_start": 0, "nack_words": 0}

class Stream:
    def __init__(self, offer_stream, sock):
        self.key = bytes.fromhex(offer_stream["aesKey"]); self.iv = bytes.fromhex(offer_stream["aesIvMask"])
        self.sender_ssrc = offer_stream["ssrc"]; self.ssrc = self.sender_ssrc + 1
        self.sock = sock; self.peer = None
        self.frames = {}          # frame id -> {packet id: payload}, plus counts
        self.counts = {}
        self.keyflags = {}
        self.checkpoint = -1
        self.seen = set()         # (frame, packet) already received once
        self.out = open(os.path.join(folder, "frames.bin"), "wb")
        self.lock = threading.Lock()
        self.pli_sent = False
        self.start = time.monotonic()

    def expand(self, low):
        # The 8-bit frame ID after the checkpoint, as the receiver reads it.
        base = self.checkpoint + 1
        return base + ((low - (base & 0xFF)) & 0xFF)

    def packet(self, data, address):
        self.peer = address
        if data[1] == 200:
            stats["reports"] += 1; return
        if data[1] in (201, 202, 204, 206, 207): return
        stats["packets"] += 1
        assert data[0] == 0x80, data[0]
        ssrc = struct.unpack(">I", data[8:12])[0]
        assert ssrc == self.sender_ssrc, (ssrc, self.sender_ssrc)
        flags, fid8, pid, max_pid = data[12], data[13], *struct.unpack(">HH", data[14:18])
        header = 18 + (1 if flags & 0x40 else 0) + 4 * (flags & 0x3F)
        with self.lock:
            frame = self.expand(fid8)
            if frame <= self.checkpoint: return
            if (frame, pid) in self.seen:
                stats["resent_in"] += 1
            elif random.random() < 0.03:
                self.seen.add((frame, pid)); stats["dropped"] += 1; return
            self.seen.add((frame, pid))
            self.frames.setdefault(frame, {})[pid] = data[header:]
            self.counts[frame] = max_pid + 1
            self.keyflags[frame] = bool(flags & 0x80)
            while self.checkpoint + 1 in self.frames and len(self.frames[self.checkpoint + 1]) == self.counts[self.checkpoint + 1]:
                done = self.checkpoint + 1
                parts = self.frames.pop(done)
                plain = decrypt(b"".join(parts[i] for i in range(len(parts))), done, self.key, self.iv)
                if not plain.startswith(b"\x00\x00\x00\x01"): stats["bad_start"] += 1
                if self.keyflags.pop(done): stats["keyframes"] += 1
                self.out.write(struct.pack(">I", len(plain)) + plain); self.out.flush()
                stats["frames"] += 1
                self.checkpoint = done
                self.seen = {s for s in self.seen if s[0] > done}

    def feedback(self):
        with self.lock:
            if not self.peer: return
            losses = []
            newest = max(self.frames, default=self.checkpoint)
            for frame in range(self.checkpoint + 1, newest + 1):
                if frame not in self.frames:
                    # Nothing of this frame came, but a later one did.
                    if len(losses) < 20: losses.append(struct.pack(">BHB", frame & 0xFF, 0xFFFF, 0))
                    continue
                got, count = self.frames[frame], self.counts[frame]
                missing = [p for p in range(count) if p not in got]
                if missing and len(losses) < 20:
                    first = missing[0]
                    bits = sum(1 << (p - first - 1) for p in missing[1:] if p - first - 1 < 8)
                    losses.append(struct.pack(">BHB", frame & 0xFF, first, bits))
            body = struct.pack(">II", self.ssrc, self.sender_ssrc) + b"CAST" + struct.pack(">BBH", self.checkpoint & 0xFF, len(losses), 100) + b"".join(losses)
            stats["nack_words"] += len(losses)
            packet = struct.pack(">BBH", 0x80 | 15, 206, len(body) // 4) + body
            if not self.pli_sent and time.monotonic() - self.start > 2:
                self.pli_sent = True
                pli = struct.pack(">II", self.ssrc, self.sender_ssrc)
                packet += struct.pack(">BBH", 0x80 | 1, 206, len(pli) // 4) + pli
                print("beginbeeld gevraagd (PLI)", flush=True)
        self.sock.sendto(packet, self.peer)

def serve_udp(stream):
    while True:
        try:
            data, address = stream.sock.recvfrom(2048)
        except OSError:
            return
        stream.packet(data, address)

def feedback_loop(stream, stop):
    while not stop.is_set():
        time.sleep(0.033)
        stream.feedback()

def handle(conn):
    buffer, stream, stop = b"", None, threading.Event()
    def send(source, destination, namespace, payload):
        conn.sendall(encode(source, destination, namespace, payload))
    while True:
        data = conn.recv(65536)
        if not data: break
        buffer += data
        while len(buffer) >= 4 and len(buffer) >= 4 + struct.unpack(">I", buffer[:4])[0]:
            length = struct.unpack(">I", buffer[:4])[0]
            source, destination, namespace, payload = decode(buffer[4:4 + length]); buffer = buffer[4 + length:]
            kind = payload.get("type")
            print("<-", namespace.split(":")[-1], destination, kind, flush=True)
            if kind == "PING":
                send(destination, source, namespace, {"type": "PONG"})
            elif kind == "LAUNCH":
                assert payload["appId"] == "0F5096E8"
                send("receiver-0", source, "urn:x-cast:com.google.cast.receiver", {"type": "RECEIVER_STATUS", "requestId": payload["requestId"],
                     "status": {"applications": [{"appId": "0F5096E8", "sessionId": "fake-session", "transportId": "fake-transport"}]}})
            elif kind == "OFFER":
                assert destination == "fake-transport"
                offered = payload["offer"]["supportedStreams"][0]
                print("aanbod:", {k: offered[k] for k in ("codecName", "rtpPayloadType", "targetDelay", "maxFrameRate", "resolutions", "timeBase")}, flush=True)
                sock = bound(socket.SOCK_DGRAM, 0)
                stream = Stream(offered, sock)
                threading.Thread(target=serve_udp, args=(stream,), daemon=True).start()
                threading.Thread(target=feedback_loop, args=(stream, stop), daemon=True).start()
                send("fake-transport", source, "urn:x-cast:com.google.cast.webrtc", {"type": "ANSWER", "seqNum": payload["seqNum"], "result": "ok",
                     "answer": {"udpPort": sock.getsockname()[1], "sendIndexes": [offered["index"]], "ssrcs": [stream.ssrc], "castMode": "mirroring"}})
            elif kind == "STOP":
                stop.set(); print("gestopt", flush=True)
    stop.set()
    print("uitslag:", stats, flush=True)

context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
server = bound(socket.SOCK_STREAM, port); server.listen(1)
print("nep-Chromecast luistert op", port, flush=True)
conn, peer = server.accept()
print("verbinding van", peer[0], flush=True)
handle(context.wrap_socket(conn, server_side=True))
