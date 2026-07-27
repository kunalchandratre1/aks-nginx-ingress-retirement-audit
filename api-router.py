import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        target = None
        if self.path.startswith("/api1"):
            target = "http://api1.sample-api.svc.cluster.local:80"
        elif self.path.startswith("/api2"):
            target = "http://api2.sample-api.svc.cluster.local:80"
        elif self.path.startswith("/api3"):
            target = "http://api3.sample-api.svc.cluster.local:80"

        if target is None:
            body = b'{"error":"not-found","allowedEndpoints":["/api1","/api2","/api3"]}'
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        try:
            with urllib.request.urlopen(target, timeout=5) as response:
                body = response.read()
                status = response.getcode()
                content_type = response.headers.get("Content-Type", "application/json")
        except urllib.error.URLError:
            body = b'{"error":"backend-unreachable"}'
            status = 502
            content_type = "application/json"

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
