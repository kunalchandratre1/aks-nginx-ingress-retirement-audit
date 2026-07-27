import json
import os
import socket
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

CLUSTER_NAME = os.getenv("CLUSTER_NAME", "unknown-cluster")
ENDPOINT_NAME = os.getenv("ENDPOINT_NAME", "api3")
HOSTNAME = socket.gethostname()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        payload = {
            "endpoint": ENDPOINT_NAME,
            "cluster": CLUSTER_NAME,
            "pathReceived": self.path,
            "timestampUtc": datetime.now(timezone.utc).isoformat(),
            "podHostname": HOSTNAME,
        }
        data = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
