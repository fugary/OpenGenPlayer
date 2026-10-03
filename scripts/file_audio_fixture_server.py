#!/usr/bin/env python3
"""Loopback protocol fixtures only; no NAS, cloud credentials or GUI required."""
import http.server, socketserver, socket, threading, json, sys, time
DATA = bytes(range(256)) * 8192
LOCK = threading.Lock()
STATS = {'http': [], 'ftp': [], 'logins': 0}
class HTTP(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/stats':
            with LOCK: body = json.dumps(STATS).encode()
            self.send_response(200); self.send_header('Content-Length', len(body)); self.end_headers(); self.wfile.write(body); return
        with LOCK: STATS['http'].append({'path':path,'clientPort':self.client_address[1],'range':self.headers.get('Range'), 'auth':self.headers.get('Authorization'), 'cookie':self.headers.get('Cookie'), 'ifRange':self.headers.get('If-Range')})
        if path in ['/redirect', '/loop']:
            self.send_response(302); self.send_header('Location', f'http://localhost:{self.server.server_port}/redirected' if path == '/redirect' else '/loop'); self.send_header('Content-Length', '0'); self.end_headers(); return
        if path.startswith('/expired'):
            with LOCK: attempts = sum(r['path'] == path for r in STATS['http'])
            if attempts == 1:
                self.send_response(403); self.send_header('Content-Length','0'); self.end_headers(); return
        if path == '/slow': time.sleep(3)
        raw = self.headers.get('Range', 'bytes=0-0')[6:].split('-'); first,last = map(int,raw)
        body = DATA[first:last+1]
        if path == '/ignore':
            self.send_response(200); self.send_header('Content-Length', len(DATA)); self.end_headers(); return
        self.send_response(206)
        self.send_header('Content-Range', f'bytes {first if path != "/wrong" else first + 1}-{last}/{len(DATA)}')
        if path == '/compressed': self.send_header('Content-Encoding', 'gzip')
        if path in ['/date', '/baddate']: self.send_header('Last-Modified', 'Wed, 24 Sep 2025 00:00:00 GMT' if path == '/date' else 'invalid')
        elif path != '/noversion': self.send_header('ETag', 'W/"one"' if path == '/weak' else ('"two"' if path == '/changed' and first else '"one"'))
        if path == '/overflow': body += b'X'
        if path == '/short': body = body[:-1]
        self.send_header('Content-Length', last-first+1 if path != '/overflow' else len(body))
        if path != '/ok': self.send_header('Connection', 'close')
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
        self.close_connection = path != "/ok"
class FTP(socketserver.StreamRequestHandler):
    def handle(self):
        data_server = None; offset = 0; path = ''; changed = False
        def reply(s): self.wfile.write((s+'\r\n').encode()); self.wfile.flush()
        reply('220 fixture')
        try:
            while True:
                line = self.rfile.readline().decode().rstrip('\r\n')
                if not line: break
                cmd,_,arg = line.partition(' ')
                with LOCK: STATS['ftp'].append(cmd + (' '+arg if cmd not in ['USER','PASS'] and arg else ''))
                if cmd == 'USER':
                    with LOCK: STATS['logins'] += 1
                    reply('331 password')
                elif cmd == 'PASS': reply('230 ok')
                elif cmd == 'TYPE': reply('200 binary')
                elif cmd == 'SIZE': path = arg; reply('213 '+str(len(DATA)))
                elif cmd == 'MDTM': reply('213 '+('20260925000001' if changed else '20260925000000'))
                elif cmd in ['EPSV','PASV']:
                    if cmd == 'EPSV' and path == '/pasv.mp4': reply('502 no EPSV'); continue
                    if data_server: data_server.close()
                    data_server = socket.socket(); data_server.bind(('127.0.0.1',0)); data_server.listen(); data_server.settimeout(5)
                    port = data_server.getsockname()[1]
                    reply(f'229 Extended passive (|||{port}|)' if cmd == 'EPSV' else f'227 Passive (192,0,2,1,{port//256},{port%256})')
                elif cmd == 'REST':
                    if path == '/no-rest.mp4': reply('502 no REST')
                    else: offset = int(arg); reply('350 restart')
                elif cmd == 'RETR':
                    reply('150 data'); peer,_ = data_server.accept(); peer.settimeout(5)
                    try:
                        if path == '/slow.mp4': time.sleep(3)
                        peer.sendall(DATA[offset:]); reply('226 complete')
                    except (BrokenPipeError,ConnectionResetError,TimeoutError): reply('426 aborted'); reply('226 closed')
                    finally: peer.close(); data_server.close(); data_server = None
                    if path == '/changed.mp4': changed = True
                elif cmd == 'ABOR': reply('225 done')
                elif cmd == 'NOOP': reply('200 fence')
                else: reply('502 unknown')
        except (BrokenPipeError,ConnectionResetError): pass
        finally:
            if data_server: data_server.close()
class FTPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address=True; daemon_threads=True
http = http.server.ThreadingHTTPServer(('127.0.0.1',0), HTTP)
ftp = FTPServer(('127.0.0.1',0),FTP)
for server in [http,ftp]: threading.Thread(target=server.serve_forever,daemon=True).start()
with open(sys.argv[1],'w') as f: json.dump({'http':http.server_port,'ftp':ftp.server_address[1]},f)
threading.Event().wait()
