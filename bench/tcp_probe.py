#!/usr/bin/env python3
"""Quick TCP probe to test if Hivemind leader responds."""
import socket, struct, sys

host = sys.argv[1] if len(sys.argv) > 1 else "10.0.3.70"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 9100

s = socket.socket()
s.settimeout(5)
s.connect((host, port))
print(f"connected to {host}:{port}")

# Build probe: [4B len][2B ver][1B tag=0x20][8B client_id][8B request_id][1B cmd=0][138B register_node]
client_id = struct.pack("<Q", 0xDEAD)
request_id = struct.pack("<Q", 1)
cmd_tag = b"\x00"  # register_node
name = b"probe" + b"\x00" * 59  # 64 bytes
padding = b"\x00" * 74  # rest of register_node (cpu, mem, gpu, provider, region)
payload = client_id + request_id + cmd_tag + name + padding  # 8+8+1+64+74 = 155

version = struct.pack("<H", 1)
tag = b"\x20"  # ClientTag.request
frame_len = struct.pack("<I", 2 + 1 + len(payload))  # version + tag + payload
frame = frame_len + version + tag + payload

print(f"sending {len(frame)} bytes")
s.sendall(frame)

# Read reply
s.settimeout(5)
try:
    data = s.recv(256)
    print(f"got {len(data)} bytes: {data[:40].hex()}")
    if len(data) >= 4:
        reply_len = struct.unpack("<I", data[:4])[0]
        print(f"frame_len={reply_len}")
        if len(data) >= 7:
            ver = struct.unpack("<H", data[4:6])[0]
            reply_tag = data[6]
            print(f"version={ver} tag=0x{reply_tag:02x}")
except socket.timeout:
    print("TIMEOUT - no reply in 5s")
finally:
    s.close()
