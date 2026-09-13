#!/usr/bin/env python3
"""Block page server for Cerberus - serves on ports 80 (HTTP) and 443 (HTTPS).

When a blocked domain is actually loaded in a browser, the resolver returns the
local block address, so the browser connects here and sees the block page.
"""
import http.server
import ssl
import socket
import os
import sys
import json

CONFIG = "/opt/cerberus/config"
CUSTOM_FILE = "/opt/cerberus/custom-block.txt"
KEYWORDS_FILE = "/opt/cerberus/search-keywords.json"
CORE = "/opt/cerberus/core.sh"

CUSTOM_DOMAINS = set()


def load_config():
    global CUSTOM_FILE, KEYWORDS_FILE
    try:
        with open(CONFIG) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                k, v = k.strip(), v.strip().strip('"')
                if k == "CUSTOM_BLOCK_FILE":
                    CUSTOM_FILE = v
                elif k == "SEARCH_KEYWORDS_JSON":
                    KEYWORDS_FILE = v
    except FileNotFoundError:
        pass
    load_custom()


def load_custom():
    global CUSTOM_DOMAINS
    s = set()
    try:
        with open(CUSTOM_FILE) as f:
            for line in f:
                line = line.strip().lower()
                if not line or line.startswith("#"):
                    continue
                s.add(line.rstrip("."))
    except FileNotFoundError:
        pass
    CUSTOM_DOMAINS = s


def is_custom_blocked(domain):
    """Return True if the domain (or any parent) matches a custom-blocked entry."""
    if not domain:
        return False
    domain = domain.lower().rstrip(".").strip()
    if not CUSTOM_DOMAINS:
        return False
    parts = domain.split(".")
    # Walk parent suffixes from the full host down to the base TLD.
    for i in range(len(parts)):
        suffix = ".".join(parts[i:])
        if suffix in CUSTOM_DOMAINS:
            return True
    return False


BLOCK_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Site Blocked</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f0f1a; color: #e0e0e0; display: flex; justify-content: center; align-items: center; min-height: 100vh; }
.container { text-align: center; padding: 40px 20px; max-width: 600px; }
.icon { width: 80px; height: 80px; background: #e94560; border-radius: 50%; display: flex; justify-content: center; align-items: center; margin: 0 auto 30px; font-size: 40px; color: #fff; line-height: 1; }
h1 { color: #e94560; font-size: 1.8em; margin-bottom: 15px; font-weight: 700; }
p { color: #a0a0b0; font-size: 1em; line-height: 1.6; margin-bottom: 12px; }
.domain { color: #e0e0e0; background: #1a1a30; padding: 8px 16px; border-radius: 6px; font-family: monospace; display: inline-block; margin: 10px 0; font-size: 0.9em; }
.footer { margin-top: 40px; font-size: 0.75em; color: #555; border-top: 1px solid #1a1a30; padding-top: 20px; }
</style>
</head>
<body>
<div class="container">
<div class="icon">!</div>
<h1>This Site Is Blocked</h1>
<p>The website you are trying to access has been blocked by the system content filter.</p>
<p class="domain">__DOMAIN__</p>
<p>If you believe this is a mistake, request an unlock or remove the domain from the blocklist.</p>
<div class="footer">Blocked by Cerberus</div>
</div>
</body>
</html>"""

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] == "/cerberus/keywords.json":
            return self._serve_keywords()
        domain = self.headers.get("Host", "unknown")
        page = BLOCK_PAGE.replace("__DOMAIN__", domain)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(page.encode())

    def _serve_keywords(self):
        keywords = []
        try:
            with open(KEYWORDS_FILE) as f:
                data = json.load(f)
                keywords = data.get("keywords", [])
        except Exception:
            pass
        body = json.dumps({"keywords": keywords}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    do_POST = do_GET
    do_HEAD = do_GET
    do_CONNECT = do_GET

    def log_message(self, format, *args):
        sys.stderr.write("[cerberus-blockpage] %s - %s\n" % (self.client_address[0], format % args))

def serve_http(port):
    server = http.server.HTTPServer(("0.0.0.0", port), Handler)
    server.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    print("[cerberus-blockpage] HTTP server on port %d" % port, flush=True)
    server.serve_forever()

def serve_https(port, certfile, keyfile):
    server = http.server.HTTPServer(("0.0.0.0", port), Handler)
    server.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile, keyfile)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    print("[cerberus-blockpage] HTTPS server on port %d" % port, flush=True)
    server.serve_forever()

if __name__ == "__main__":
    load_config()
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 80
    if port == 443:
        serve_https(port, "/opt/cerberus/blockpage.crt", "/opt/cerberus/blockpage.key")
    else:
        serve_http(port)
