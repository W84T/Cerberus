#!/usr/bin/env python3
import socket, sqlite3, threading, sys, os, signal, subprocess, logging, re

logging.basicConfig(
    format="[cerberus-resolve] %(message)s",
    level=logging.INFO,
    stream=sys.stdout,
)
log = logging.getLogger("cerberus-resolve")

DEFAULT_DB = "/opt/cerberus/cerberus.db"
DEFAULT_PORT = 5353
DEFAULT_UPSTREAM = "8.8.8.8:53"
DEFAULT_CONFIG = "/opt/cerberus/config"
SOCKET_TIMEOUT = 3

def load_safe_search(config_path):
    redirects = {}
    try:
        in_section = False
        with open(config_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("SAFESEARCH_REDIRECTS=("):
                    in_section = True
                    continue
                if in_section:
                    if line.startswith(")"):
                        break
                    line = line.strip('"').strip()
                    if not line or line.startswith("#"):
                        continue
                    parts = line.split()
                    if len(parts) >= 2:
                        ip, domain = parts[0], parts[1]
                        redirects[domain.lower()] = ip
        log.info(f"safe search: {len(redirects)} redirect rules loaded")
    except FileNotFoundError:
        log.warning(f"config not found: {config_path}")
    return redirects


def make_redirect_reply(data, redirect_ip):
    ip_bytes = socket.inet_aton(redirect_ip)
    hdr = data[:2] + b"\x81\x80" + data[4:6] + b"\x00\x01" + data[8:12]
    qend = 12
    while qend < len(data) and data[qend] != 0:
        if data[qend] & 0xC0 == 0xC0:
            qend += 2
            break
        qend = qend + data[qend] + 1
    qend += 5
    ans = hdr + data[12:qend]
    ans += b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04" + ip_bytes
    return ans


def parse_domain(data, offset=12):
    parts = []
    while True:
        if offset >= len(data):
            return None, offset
        length = data[offset]
        if length == 0:
            offset += 1
            break
        if length > 63:
            return None, offset
        offset += 1
        if offset + length > len(data):
            return None, offset
        parts.append(data[offset:offset+length].decode("ascii", errors="replace"))
        offset += length
    return ".".join(parts), offset

def make_blocked_reply(data, domain):
    hdr = data[:2] + b"\x81\x80" + data[4:6] + b"\x00\x01" + data[8:12]
    qend = 12
    while qend < len(data) and data[qend] != 0:
        if data[qend] & 0xC0 == 0xC0:
            qend += 2
            break
        qend += data[qend] + 1
    qend += 5
    ans = hdr + data[12:qend]
    ans += b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\x7f\x00\x00\x01"
    return ans

def make_nxdomain(data):
    return data[:2] + b"\x81\x83" + data[4:6] + b"\x00\x00\x00\x00" + data[12:]

class Resolver:
    def __init__(self, db_path, upstream, config_path=DEFAULT_CONFIG):
        self.db_path = db_path
        self.upstream_host, self.upstream_port = self._parse_upstream(upstream)
        self.safe_search = load_safe_search(config_path)
        self._local = threading.local()
        self._db_lock = threading.Lock()
        self._blocked_count = 0
        self._forward_count = 0
        self._redirect_count = 0
        self._log_interval = 300
        self._last_log = 0

    def _parse_upstream(self, upstream):
        if ":" in upstream:
            h, p = upstream.rsplit(":", 1)
            return h, int(p)
        return upstream, 53

    def _get_db(self):
        if not hasattr(self._local, "db") or self._local.db is None:
            self._local.db = sqlite3.connect(f"file:{self.db_path}?mode=ro&immutable=1", uri=True, timeout=5)
        return self._local.db

    def _is_blocked(self, domain):
        if not domain:
            return False
        try:
            db = self._get_db()
            cur = db.execute(
                "SELECT 1 FROM blocked_domains WHERE domain=?",
                (domain.lower(),),
            )
            return cur.fetchone() is not None
        except Exception:
            return False

    def _resolve_upstream(self, data):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.settimeout(SOCKET_TIMEOUT)
            sock.sendto(data, (self.upstream_host, self.upstream_port))
            return sock.recvfrom(4096)[0]
        except socket.timeout:
            return None
        except Exception:
            return None
        finally:
            sock.close()

    def _resolve_tcp(self, data):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            sock.settimeout(SOCKET_TIMEOUT)
            sock.connect((self.upstream_host, self.upstream_port))
            length = len(data).to_bytes(2, "big")
            sock.sendall(length + data)
            resp_len = sock.recv(2)
            if len(resp_len) < 2:
                return None
            resp_len = int.from_bytes(resp_len, "big")
            resp = b""
            while len(resp) < resp_len:
                chunk = sock.recv(resp_len - len(resp))
                if not chunk:
                    return None
                resp += chunk
            return resp
        except Exception:
            return None
        finally:
            sock.close()

    def handle(self, data, addr, proto):
        domain, _ = parse_domain(data)
        qtype = 0
        if domain and len(data) > 14:
            qtype = int.from_bytes(data[12 + len(domain.encode()) + 2 : 12 + len(domain.encode()) + 4], "big") if len(data) > 14 + len(domain.encode()) else 0
            raw_type = data[-4:-2] if len(data) >= 4 else b"\x00\x00"
            qtype = int.from_bytes(raw_type, "big")

        if domain and self._is_blocked(domain):
            self._blocked_count += 1
            reply = make_blocked_reply(data, domain)
            return reply

        if domain and domain.lower() in self.safe_search:
            redirect_ip = self.safe_search[domain.lower()]
            self._redirect_count += 1
            reply = make_redirect_reply(data, redirect_ip)
            return reply

        self._forward_count += 1
        if proto == "udp":
            reply = self._resolve_upstream(data)
            if reply is None:
                reply = make_nxdomain(data)
            return reply
        else:
            reply = self._resolve_tcp(data)
            if reply is None:
                reply = make_nxdomain(data)
            return reply

def load_upstream_from_system():
    try:
        out = subprocess.check_output(
            ["resolvectl", "status"],
            timeout=5,
            stderr=subprocess.DEVNULL,
        ).decode()
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("Current DNS Server:") or line.startswith("DNS Servers:"):
                ip = line.split(":")[-1].strip().split()[0]
                if ip:
                    return ip
    except Exception:
        pass
    return "8.8.8.8"

class UDPHandler(threading.Thread):
    def __init__(self, resolver, listen, port):
        super().__init__(daemon=True)
        self.resolver = resolver
        self.listen = listen
        self.port = port

    def run(self):
        while True:
            try:
                data, addr = self.listen.recvfrom(4096)
                threading.Thread(
                    target=self._handle, args=(data, addr), daemon=True
                ).start()
            except Exception:
                continue

    def _handle(self, data, addr):
        reply = self.resolver.handle(data, addr, "udp")
        if reply:
            try:
                self.listen.sendto(reply, addr)
            except Exception:
                pass

class TCPHandler(threading.Thread):
    def __init__(self, resolver, listen, port):
        super().__init__(daemon=True)
        self.resolver = resolver
        self.listen = listen
        self.port = port

    def run(self):
        while True:
            try:
                conn, addr = self.listen.accept()
                threading.Thread(
                    target=self._handle_client, args=(conn, addr), daemon=True
                ).start()
            except Exception:
                continue

    def _handle_client(self, conn, addr):
        try:
            conn.settimeout(SOCKET_TIMEOUT)
            length_bytes = conn.recv(2)
            if len(length_bytes) < 2:
                return
            length = int.from_bytes(length_bytes, "big")
            data = b""
            while len(data) < length:
                chunk = conn.recv(length - len(data))
                if not chunk:
                    return
                data += chunk
            reply = self.resolver.handle(data, addr, "tcp")
            if reply:
                conn.sendall(len(reply).to_bytes(2, "big") + reply)
        except Exception:
            pass
        finally:
            conn.close()

def log_stats(resolver):
    import time
    while True:
        time.sleep(300)
        now = time.time()
        log.info(
            f"stats: blocked={resolver._blocked_count} forwarded={resolver._forward_count}"
        )
        resolver._blocked_count = 0
        resolver._forward_count = 0

def main():
    db_path = os.environ.get("CERBERUS_DB", DEFAULT_DB)
    port = int(os.environ.get("CERBERUS_PORT", str(DEFAULT_PORT)))

    upstream = os.environ.get("CERBERUS_UPSTREAM")
    if not upstream:
        upstream = load_upstream_from_system()
        upstream = f"{upstream}:53"
    log.info(f"upstream={upstream}")

    if not os.path.exists(db_path):
        log.error(f"database not found: {db_path}")
        log.error("run blocklist_updater.py first")
        sys.exit(1)

    resolver = Resolver(db_path, upstream)
    log.info(f"database={db_path} entries={resolver._get_db().execute('SELECT count(*) FROM blocked_domains').fetchone()[0]}")

    udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    udp_sock.bind(("127.0.0.1", port))

    tcp_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tcp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tcp_sock.bind(("127.0.0.1", port))
    tcp_sock.listen(128)

    UDPHandler(resolver, udp_sock, port).start()
    TCPHandler(resolver, tcp_sock, port).start()
    threading.Thread(target=log_stats, args=(resolver,), daemon=True).start()

    log.info(f"listening on 127.0.0.1:{port} (UDP+TCP)")

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    try:
        while True:
            signal.pause()
    except (KeyboardInterrupt, SystemExit):
        log.info("shutting down")
        udp_sock.close()
        tcp_sock.close()

if __name__ == "__main__":
    main()
