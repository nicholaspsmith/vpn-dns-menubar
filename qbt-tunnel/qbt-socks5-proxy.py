#!/usr/bin/env python3
"""SOCKS5 proxy (TCP CONNECT + UDP ASSOCIATE) that forces every outbound
packet to originate from the qbt tunnel address.

Why this exists: libtorrent cannot transmit when it binds utun100 itself
(verified: zero bytes leave the interface). An external process binding the
same address works perfectly, so qBittorrent talks SOCKS5 to this proxy and
the proxy owns the tunnel binding.

Fail-closed: if the tunnel address disappears, bind() fails -> connections
refused and UDP relays die -> torrents stall instead of leaking.
"""
import asyncio, json, socket, struct

DEVJSON = "/etc/wireguard-qbt/device.json"
LISTEN = ("127.0.0.1", 1080)
stats = {"tcp_ok": 0, "tcp_fail": 0, "udp_assoc": 0, "udp_out": 0, "udp_in": 0}


def bind_addr():
    """The tunnel address, re-read every time so a re-registered device is
    picked up without a restart. Returns None when unavailable -> fail closed."""
    try:
        with open(DEVJSON) as f:
            return json.load(f)["ipv4_address"]
    except Exception:
        return None


def parse_udp_header(data):
    """SOCKS5 UDP request: RSV(2) FRAG(1) ATYP(1) DST.ADDR DST.PORT DATA"""
    if len(data) < 10 or data[2] != 0:      # no fragmentation support
        return None, None, None
    atyp = data[3]
    i = 4
    if atyp == 1:
        host = socket.inet_ntoa(data[i:i+4]); i += 4
    elif atyp == 3:
        ln = data[i]; i += 1
        host = data[i:i+ln].decode(errors="replace"); i += ln
    elif atyp == 4:
        return None, None, None             # no IPv6 through the tunnel
    else:
        return None, None, None
    port = struct.unpack(">H", data[i:i+2])[0]; i += 2
    return host, port, data[i:]


def build_udp_header(host, port, payload):
    return b"\x00\x00\x00\x01" + socket.inet_aton(host) + struct.pack(">H", port) + payload


class ClientSide(asyncio.DatagramProtocol):
    """Receives datagrams from qBittorrent, forwards them out the tunnel."""
    def __init__(self, relay): self.relay = relay
    def connection_made(self, transport): self.relay.client_tr = transport
    def datagram_received(self, data, addr):
        self.relay.client_addr = addr
        host, port, payload = parse_udp_header(data)
        if host is None:
            return
        stats["udp_out"] += 1
        self.relay.send_out(host, port, payload)


class RemoteSide(asyncio.DatagramProtocol):
    """Receives replies from the internet, wraps them back to qBittorrent."""
    def __init__(self, relay): self.relay = relay
    def connection_made(self, transport): self.relay.remote_tr = transport
    def datagram_received(self, data, addr):
        if self.relay.client_tr and self.relay.client_addr:
            stats["udp_in"] += 1
            try:
                self.relay.client_tr.sendto(
                    build_udp_header(addr[0], addr[1], data), self.relay.client_addr)
            except Exception:
                pass


class UdpRelay:
    def __init__(self):
        self.client_tr = self.remote_tr = None
        self.client_addr = None
        self.loop = asyncio.get_running_loop()

    async def start(self):
        addr = bind_addr()
        if addr is None:
            raise OSError("tunnel address unavailable")
        await self.loop.create_datagram_endpoint(
            lambda: ClientSide(self), local_addr=("127.0.0.1", 0))
        await self.loop.create_datagram_endpoint(
            lambda: RemoteSide(self), local_addr=(addr, 0))        # <- tunnel-bound
        stats["udp_assoc"] += 1
        return self.client_tr.get_extra_info("sockname")

    def send_out(self, host, port, payload):
        async def go():
            try:
                if not host[0].isdigit():
                    infos = await self.loop.getaddrinfo(
                        host, port, family=socket.AF_INET, type=socket.SOCK_DGRAM)
                    dest = infos[0][4]
                else:
                    dest = (host, port)
                if self.remote_tr:
                    self.remote_tr.sendto(payload, dest)
            except Exception:
                pass
        asyncio.create_task(go())

    def close(self):
        for tr in (self.client_tr, self.remote_tr):
            try:
                if tr: tr.close()
            except Exception:
                pass


async def relay_stream(r, w):
    try:
        while True:
            data = await r.read(65536)
            if not data:
                break
            w.write(data); await w.drain()
    except Exception:
        pass
    finally:
        try: w.close()
        except Exception: pass


async def handle(cr, cw):
    udp = None
    try:
        d = await cr.readexactly(2)
        await cr.readexactly(d[1])
        cw.write(b"\x05\x00"); await cw.drain()

        hdr = await cr.readexactly(4)
        cmd, atyp = hdr[1], hdr[3]
        if atyp == 1:
            host = socket.inet_ntoa(await cr.readexactly(4))
        elif atyp == 3:
            ln = (await cr.readexactly(1))[0]
            host = (await cr.readexactly(ln)).decode()
        elif atyp == 4:
            cw.write(b"\x05\x08\x00\x01" + b"\x00"*6); await cw.drain(); cw.close(); return
        else:
            cw.close(); return
        port = struct.unpack(">H", await cr.readexactly(2))[0]

        if cmd == 3:                                    # UDP ASSOCIATE
            udp = UdpRelay()
            try:
                bnd_host, bnd_port = await udp.start()
            except Exception:                           # tunnel down -> fail closed
                cw.write(b"\x05\x01\x00\x01" + b"\x00"*6); await cw.drain()
                cw.close(); return
            cw.write(b"\x05\x00\x00\x01" + socket.inet_aton("127.0.0.1")
                     + struct.pack(">H", bnd_port))
            await cw.drain()
            while True:                                 # hold association open
                if not await cr.read(4096):
                    break
            return

        if cmd != 1:
            cw.write(b"\x05\x07\x00\x01" + b"\x00"*6); await cw.drain(); cw.close(); return

        try:                                            # TCP CONNECT
            addr = bind_addr()
            if addr is None:
                raise OSError("tunnel address unavailable")
            infos = await asyncio.get_running_loop().getaddrinfo(
                host, port, family=socket.AF_INET, type=socket.SOCK_STREAM)
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setblocking(False)
            s.bind((addr, 0))                           # <- tunnel-bound
            await asyncio.wait_for(
                asyncio.get_running_loop().sock_connect(s, infos[0][4]), timeout=15)
            rr, rw = await asyncio.open_connection(sock=s)
            stats["tcp_ok"] += 1
        except Exception:
            stats["tcp_fail"] += 1
            try:
                cw.write(b"\x05\x05\x00\x01" + b"\x00"*6); await cw.drain()
            except Exception: pass
            cw.close(); return

        cw.write(b"\x05\x00\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
        await cw.drain()
        await asyncio.gather(relay_stream(cr, rw), relay_stream(rr, cw))
    except Exception:
        pass
    finally:
        if udp: udp.close()
        try: cw.close()
        except Exception: pass


async def reporter():
    while True:
        await asyncio.sleep(20)
        print(f"[socks5] tcp ok={stats['tcp_ok']} fail={stats['tcp_fail']} | "
              f"udp assoc={stats['udp_assoc']} out={stats['udp_out']} in={stats['udp_in']}",
              flush=True)


async def main():
    srv = await asyncio.start_server(handle, *LISTEN)
    print(f"[socks5] listening {LISTEN[0]}:{LISTEN[1]} -> bound to "
          f"{bind_addr() or 'NO TUNNEL (failing closed)'} (TCP+UDP)", flush=True)
    asyncio.create_task(reporter())
    async with srv:
        await srv.serve_forever()

asyncio.run(main())
