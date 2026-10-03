#!/usr/bin/env python3
"""Local MacCMS-compatible fixture backed by Apple's public HLS test stream.
Run: python3 scripts/vod_fixture_server.py
Add VOD endpoint: http://127.0.0.1:18766/api.php/provide/vod
This serves metadata only; the player fetches Apple's stream directly.
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

STREAM = 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8'
ITEM = dict(vod_id=1, vod_name='Apple Bip Bop HLS Test', type_id=1,
            type_name='HLS Test', vod_remarks='AVC / HEVC', vod_content='Apple public HLS playback test.',
            vod_play_from='Apple HLS', vod_play_url='Bip Bop$' + STREAM)

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlsplit(self.path)
        if parsed.path.rstrip('/') != '/api.php/provide/vod':
            self.send_error(404)
            return
        query = parse_qs(parsed.query)
        values = [ITEM]
        if query.get('wd', [''])[0].casefold() not in ITEM['vod_name'].casefold():
            values = []
        if query.get('ids', ['1'])[0] != '1' or query.get('t', ['1'])[0] != '1' or query.get('pg', ['1'])[0] != '1':
            values = []
        payload = dict(code=1, page=1, pagecount=1, total=len(values), list=values)
        payload['class'] = [dict(type_id=1, type_pid=0, type_name='HLS Test')]
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

if __name__ == '__main__':
    print('VOD fixture: http://127.0.0.1:18766/api.php/provide/vod', flush=True)
    HTTPServer(('127.0.0.1', 18766), Handler).serve_forever()
