#!/usr/bin/env python3
"""Test server for Model Library downloads. Serves files from argv[1] at /<mode>/<name>; modes:
  ok          normal, honours Range
  cut         first request per path stops after half the bytes; later ones are normal
  cutnorange  first request cut at half; later ones IGNORE Range (send 200 + everything)
  corrupt     every byte of the body is flipped
  dead        404
Every request is logged to argv[2] as: <mode> <name> <range or ->. Port: argv[3], default 8765."""
import http.server, os, sys
ROOT, LOG = sys.argv[1], sys.argv[2]
seen = set()

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        parts = self.path.strip('/').split('/', 1)
        mode, name = (parts + [''])[:2]
        rng = self.headers.get('Range')
        with open(LOG, 'a') as f: f.write(f"{mode} {name} {rng or '-'}\n")
        path = os.path.join(ROOT, name)
        if mode == 'dead' or not os.path.isfile(path):
            self.send_response(404); self.end_headers(); return
        data = open(path, 'rb').read()
        first = (mode, name) not in seen; seen.add((mode, name))
        start = 0
        if rng and mode in ('ok', 'cut', 'corrupt') or (rng and mode == 'cutnorange' and first):
            start = int(rng.split('=')[1].split('-')[0])
        body = data[start:]
        if mode == 'corrupt': body = bytes(b ^ 0xFF for b in body)
        if start: self.send_response(206); self.send_header('Content-Range', f"bytes {start}-{len(data)-1}/{len(data)}")
        else: self.send_response(200)
        self.send_header('Content-Length', str(len(body))); self.end_headers()
        if mode in ('cut', 'cutnorange') and first:
            self.wfile.write(body[:len(body) // 2]); self.wfile.flush()
            self.connection.shutdown(2); return
        self.wfile.write(body)

http.server.ThreadingHTTPServer(('0.0.0.0', int(sys.argv[3]) if len(sys.argv) > 3 else 8765), H).serve_forever()
