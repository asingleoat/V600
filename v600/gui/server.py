"""Unified HTTP server for scanning and processing.

Routes:
    /           -> redirect to /scan/
    /scan/*     -> scanner UI and API (scan_handlers)
    /process/*  -> processing UI and API (process_handlers)
    /gallery/*  -> gallery UI and API (process_handlers)
"""

import argparse
import os
import sys
import webbrowser
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from socketserver import ThreadingMixIn

from v600.config import settings as cfg_mod
from . import scan_handlers
from . import process_handlers


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        path = self.path.split('?')[0]  # strip query string

        if path == '/':
            self.send_response(302)
            self.send_header('Location', '/scan/')
            self.end_headers()

        elif path.startswith('/scan'):
            sub = path[5:] or '/'  # strip "/scan"
            scan_handlers.handle_get(self, sub)

        elif path.startswith('/process'):
            sub = path[8:] or '/'  # strip "/process"
            process_handlers.handle_get(self, sub)

        elif path.startswith('/gallery'):
            sub = path[8:] or '/'  # strip "/gallery"
            process_handlers.handle_gallery_get(self, sub)

        else:
            self.send_error(404)

    def do_POST(self):
        path = self.path.split('?')[0]

        if path.startswith('/scan'):
            sub = path[5:] or '/'
            scan_handlers.handle_post(self, sub)

        elif path.startswith('/process'):
            sub = path[8:] or '/'
            process_handlers.handle_post(self, sub)

        elif path.startswith('/gallery'):
            sub = path[8:] or '/'
            process_handlers.handle_gallery_post(self, sub)

        else:
            self.send_error(404)


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


def main():
    # Add parent dir to path so we can import scanner from root
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

    parser = argparse.ArgumentParser(description='Epson Scanner + Processing Suite')
    parser.add_argument('--port', type=int, default=8432,
                        help='Web server port (default: 8432)')
    parser.add_argument('--scan-dir', type=str, default='scans',
                        help='Scanner output / processing input directory (default: scans/)')
    parser.add_argument('--output-dir', type=str, default='frames',
                        help='Processing output directory (default: frames/)')
    args = parser.parse_args()

    scan_dir = args.scan_dir
    output_dir = args.output_dir
    os.makedirs(scan_dir, exist_ok=True)

    # Scanner config lives in the scan directory
    cfg_mod.CONFIG_FILE = Path(os.path.join(scan_dir, "epdaughter_config.toml"))

    # Processing config lives in the working directory
    process_handlers.CONFIG_FILE = Path("scratchndent_config.toml")

    # --- Initialize scanner ---
    scanner = None
    scanner_error = None
    try:
        from scanner import EpsonScanner
        scanner = EpsonScanner()
        scanner.open()
        print("Scanner connected")
    except RuntimeError as e:
        print(f"Warning: {e}")
        print("Starting in offline mode — scanner operations will be disabled")
        scanner = None
        scanner_error = str(e)
    except Exception as e:
        print(f"Unexpected scanner error: {e}")
        scanner = None
        scanner_error = str(e)

    scan_handlers.init(scanner, scan_dir)
    if scanner_error:
        scan_handlers.state.scanner_error = scanner_error

    # --- Initialize processing ---
    process_handlers.init(scan_dir, output_dir)

    # --- Start server ---
    server = None
    try:
        server = ThreadedHTTPServer(('127.0.0.1', args.port), Handler)
        url = f'http://127.0.0.1:{args.port}'
        print(f"Server: {url}")
        print(f"  Scanner UI: {url}/scan/")
        print(f"  Processing: {url}/process/")
        print(f"  Gallery:    {url}/gallery/")

        webbrowser.open(url)
        server.serve_forever()

    except KeyboardInterrupt:
        print("\nShutting down...")
    except Exception as e:
        print(f"\nError: {e}")
        import traceback
        traceback.print_exc()
    finally:
        print("Cleaning up...")
        if scanner:
            try:
                scanner.close()
                print("Scanner released")
            except Exception as e:
                print(f"Error closing scanner: {e}")
        if server:
            try:
                server.shutdown()
                print("Server stopped")
            except Exception as e:
                print(f"Error stopping server: {e}")


if __name__ == '__main__':
    main()
