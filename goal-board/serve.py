"""Threaded static server so Chrome can open CSS/JS/SVG at once."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = 8765


class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    timeout = 8

    def end_headers(self):
        self.send_header("Connection", "close")
        self.send_header("Cache-Control", "no-cache")
        SimpleHTTPRequestHandler.end_headers(self)


class Server(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    httpd = Server((HOST, PORT), Handler)
    print("http://%s:%s/" % (HOST, PORT), flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
