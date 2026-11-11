"""切り分け: (A) phone 自身が head と body の間で KeyUpdate を送る  (B) proxy が書いた 1 レコードだけで完結"""
import socket, sys, struct
from tlslite import TLSConnection
from tlslite.handshakesettings import HandshakeSettings
from tlslite.constants import KeyUpdateMessageType
from tlslite.mathtls import HKDF_expand_label
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
host = sys.argv[1]; mode = sys.argv[2]
HEAD = ("POST /v1/messages HTTP/1.1\r\nHost: %s\r\nx-api-key: sk-ant-dummy\r\nanthropic-version: 2023-06-01\r\n"
        "content-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n" % host).encode()
s = socket.create_connection((host, 443))
c = TLSConnection(s); st = HandshakeSettings(); st.minVersion = (3, 4); st.maxVersion = (3, 4); st.cipherNames = ["aes128gcm"]
c.handshakeClientCert(settings=st, serverName=host, alpn=[b"http/1.1"])
try:
    if mode == "A":
        c.write(HEAD)
        for _ in c.send_keyupdate_request(KeyUpdateMessageType.update_not_requested): pass
        c.write(b"{}")
    elif mode == "A2":   # KeyUpdate を update_requested で
        c.write(HEAD)
        for _ in c.send_keyupdate_request(KeyUpdateMessageType.update_requested): pass
        c.write(b"{}")
    elif mode == "B":
        sec = bytes(c.session.cl_app_secret)
        key = bytes(HKDF_expand_label(sec, b"key", b"", 16, "sha256")); iv = bytes(HKDF_expand_label(sec, b"iv", b"", 12, "sha256"))
        inner = HEAD + b"{}" + b"\x17"; hdr = b"\x17\x03\x03" + struct.pack(">H", len(inner) + 16)
        s.sendall(hdr + AESGCM(key).encrypt(iv, inner, hdr))   # seq=0 なので nonce=iv
    print(mode, "->", bytes(c.read(max=4096, min=1))[:60])
except Exception as e:
    print(mode, "-> ERROR", repr(e))
