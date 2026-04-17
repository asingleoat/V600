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
import threading
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
    parser.add_argument('--browser', action='store_true',
                        help='Open in browser instead of native window')
    args = parser.parse_args()

    scan_dir = args.scan_dir
    output_dir = args.output_dir
    os.makedirs(scan_dir, exist_ok=True)

    # Scanner config lives in the scan directory
    cfg_mod.CONFIG_FILE = Path(os.path.join(scan_dir, "epdaughter_config.toml"))

    # Processing config lives in the working directory
    import scratchndent.config as process_cfg
    process_cfg.CONFIG_FILE = Path("scratchndent_config.toml")

    # --- Initialize scanner (background) ---
    # Scanner detection via SANE is slow (10-15s). Start the server
    # immediately so the UI is usable, and connect in the background.
    scan_handlers.init(None, scan_dir)
    scan_handlers.state.scanner_connecting = True

    def _connect_scanner():
        try:
            from scanner import EpsonScanner
            scanner = EpsonScanner()
            scanner.open()
            scan_handlers.state.scanner = scanner
            print("Scanner connected")
        except RuntimeError as e:
            print(f"Warning: {e}")
            print("Scanner offline — scanner operations will be disabled")
            scan_handlers.state.scanner_error = str(e)
        except Exception as e:
            print(f"Unexpected scanner error: {e}")
            scan_handlers.state.scanner_error = str(e)
        finally:
            scan_handlers.state.scanner_connecting = False

    scanner_thread = threading.Thread(target=_connect_scanner, daemon=True)
    scanner_thread.start()

    # --- Initialize processing ---
    process_handlers.init(scan_dir, output_dir)

    # --- Start server ---
    server = ThreadedHTTPServer(('127.0.0.1', args.port), Handler)
    url = f'http://127.0.0.1:{args.port}'
    print(f"Server: {url}")
    print(f"  Scanner UI: {url}/scan/")
    print(f"  Processing: {url}/process/")
    print(f"  Gallery:    {url}/gallery/")

    # Run HTTP server in a background thread
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    if not args.browser:
        try:
            # Ensure Qt can find its platform plugins (nix sets QT_PLUGIN_PATH
            # in the shell but PyQt6 init can clear it before webview loads)
            import platform as _plat
            if _plat.system() == 'Linux':
                try:
                    from PyQt6.QtCore import QLibraryInfo
                    plugin_path = QLibraryInfo.path(QLibraryInfo.LibraryPath.PluginsPath)
                    os.environ['QT_PLUGIN_PATH'] = plugin_path
                except ImportError:
                    pass
            import webview
            window = webview.create_window('V600 Scanner', url, width=1280, height=900)
            webview.start()
        except ImportError:
            print("pywebview not available, opening in browser")
            args.browser = True

    if args.browser:
        import webbrowser
        webbrowser.open(url)
        try:
            server_thread.join()
        except KeyboardInterrupt:
            pass
    except KeyboardInterrupt:
        pass
    finally:
        print("Shutting down...")
        if scan_handlers.state.scanner:
            try:
                scan_handlers.state.scanner.close()
                print("Scanner released")
            except Exception as e:
                print(f"Error closing scanner: {e}")
        server.shutdown()
        print("Server stopped")


if __name__ == '__main__':
    main()
