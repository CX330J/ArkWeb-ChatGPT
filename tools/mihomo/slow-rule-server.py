"""Serve a slow, synthetic rule set for the device startup regression test."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time


class SlowRuleHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/slow.yaml':
            self.send_error(404)
            return
        time.sleep(8)
        body = b"payload:\n  - '+.example.com'\n"
        self.send_response(200)
        self.send_header('Content-Type', 'text/yaml')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 18080), SlowRuleHandler).serve_forever()
