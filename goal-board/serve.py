"""Threaded static server so Chrome can open CSS/JS/SVG at once."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = 8765


def main():
    httpd = ThreadingHTTPServer((HOST, PORT), SimpleHTTPRequestHandler)
    print("http://%s:%s/" % (HOST, PORT), flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
