"""HTTP server for frame extraction web UI."""

import json
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from pathlib import Path
from urllib.parse import urlparse, parse_qs

import numpy as np
from PIL import Image
import io

from .html_interface import get_html, get_gallery_html


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


class ExtractHandler(BaseHTTPRequestHandler):
    """HTTP request handler for frame extraction UI."""
    
    def __init__(self, app_state, *args, **kwargs):
        self.app_state = app_state
        super().__init__(*args, **kwargs)
    
    def log_message(self, format, *args):
        pass  # Silence request logging
    
    def do_GET(self):
        """Handle GET requests."""
        path_parts = urlparse(self.path)
        path = path_parts.path
        query = parse_qs(path_parts.query)
        
        if path == '/':
            # Main UI
            html = get_html()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', len(html))
            self.end_headers()
            self.wfile.write(html.encode())
            
        elif path == '/gallery':
            # Gallery view
            html = get_gallery_html()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', len(html))
            self.end_headers()
            self.wfile.write(html.encode())
            
        elif path == '/preview':
            # Get current preview image
            preview_data = self.app_state.get_preview()
            if preview_data:
                self.send_response(200)
                self.send_header('Content-Type', 'image/jpeg')
                self.send_header('Content-Length', len(preview_data))
                self.end_headers()
                self.wfile.write(preview_data)
            else:
                self.send_error(404)
                
        elif path == '/info':
            # Get image info
            info = self.app_state.get_info()
            data = json.dumps(info)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data.encode())
            
        elif path == '/config':
            # Get current config
            config = self.app_state.get_config()
            data = json.dumps(config)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data.encode())
            
        elif path == '/stocks':
            # Get available film stocks
            stocks = self.app_state.get_stocks()
            data = json.dumps(stocks)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data.encode())
            
        else:
            self.send_error(404)
    
    def do_POST(self):
        """Handle POST requests."""
        path = self.path
        content_length = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(content_length)) if content_length else {}
        
        try:
            if path == '/export':
                # Export selected frames
                result = self.app_state.export_frames(body)
                
            elif path == '/invert':
                # Toggle inversion
                result = self.app_state.toggle_inversion(body)
                
            elif path == '/config':
                # Update config
                result = self.app_state.update_config(body)
                
            elif path == '/detect':
                # Auto-detect frames
                result = self.app_state.detect_frames(body)
                
            elif path == '/switch':
                # Switch between images (multi-page TIFF)
                result = self.app_state.switch_image(body.get('index', 0))
                
            else:
                self.send_error(404)
                return
            
            # Send success response
            data = json.dumps(result if result else {'success': True})
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data.encode())
            
        except Exception as e:
            # Send error response
            data = json.dumps({'error': str(e)})
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data.encode())


def create_handler(app_state):
    """Create handler class with app state."""
    return lambda *args, **kwargs: ExtractHandler(app_state, *args, **kwargs)