#!/usr/bin/env python3
"""Block page server for Blocker - serves on ports 80 (HTTP) and 443 (HTTPS)"""
import http.server
import ssl
import sys
import socket

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
<div class="footer">Blocked by Blocker v1</div>
</div>
</body>
</html>"""

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        domain = self.headers.get("Host", "unknown")
        page = BLOCK_PAGE.replace("__DOMAIN__", domain)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(page.encode())
    do_POST = do_GET
    do_HEAD = do_GET
    do_CONNECT = do_GET

    def log_message(self, format, *args):
        sys.stderr.write("[blockpage] %s - %s\n" % (self.client_address[0], format % args))

def serve_http(port):
    server = http.server.HTTPServer(("0.0.0.0", port), Handler)
    server.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    print("[blockpage] HTTP server on port %d" % port, flush=True)
    server.serve_forever()

def serve_https(port, certfile, keyfile):
    server = http.server.HTTPServer(("0.0.0.0", port), Handler)
    server.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile, keyfile)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    print("[blockpage] HTTPS server on port %d" % port, flush=True)
    server.serve_forever()

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 80
    if port == 443:
        serve_https(port, "/opt/blocker/blockpage.crt", "/opt/blocker/blockpage.key")
    else:
        serve_http(port)
