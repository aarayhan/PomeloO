"""Phone <-> PC over the local Wi-Fi, no app or account: a tiny HTTP server behind a secret link that
the phone opens by scanning a QR code. The page lists the shared files (tap to download) and has a
button to send files from the phone to the PC. It only lives while the PomeloO window is open."""
import html
import secrets
import shutil
import socket
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def _downloads() -> Path:
    """The real Downloads folder (it may have been moved to another drive)."""
    try:
        from win32com.shell import shell
        return Path(shell.SHGetKnownFolderPath(shell.FOLDERID_Downloads, 0, 0))
    except Exception:
        return Path.home() / "Downloads"


INBOX = _downloads()
_CHUNK = 1 << 20


def lan_ip() -> str | None:
    """The address other devices on this network reach us at (no packet is sent)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        return None if ip.startswith("127.") else ip
    except OSError:
        return None
    finally:
        s.close()


_RESERVED = {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(10)), *(f"LPT{i}" for i in range(10))}


def _safe_name(name: str) -> str:
    """A phone-supplied name as a plain file name in INBOX: no folders, no characters or device names
    (CON, NUL, COM1...) that Windows treats specially."""
    from .rename import _BAD
    name = _BAD.sub("_", Path(name.replace("\\", "/")).name).strip(" .") or "file"
    return "_" + name if name.split(".")[0].upper() in _RESERVED else name


_PAGE = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PomeloO</title><style>
body{{margin:0;font:16px system-ui,sans-serif;background:#18181b;color:#f4f4f5}}main{{max-width:560px;margin:auto;padding:20px 16px}}
h1{{font-size:22px;margin:4px 0 18px}}h1 b{{color:#ff8a00}}h2{{font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:#a1a1aa;margin:22px 0 8px}}
a.f{{display:flex;justify-content:space-between;gap:12px;padding:14px;margin:6px 0;border-radius:12px;background:#27272a;color:inherit;text-decoration:none}}
a.f span:last-child{{color:#a1a1aa;white-space:nowrap}}label{{display:block;text-align:center;padding:16px;border-radius:12px;background:#ff8a00;color:#18181b;font-weight:700}}
input{{display:none}}#log .row{{display:flex;justify-content:space-between;gap:12px;padding:8px 2px;color:#d4d4d8}}#log .row span:last-child{{white-space:nowrap}}p{{color:#a1a1aa}}
#st{{position:sticky;top:0;z-index:5;margin:-20px -16px 16px;padding:14px 16px;font-weight:700;text-align:center;background:#27272a}}
#st.ok{{background:#16a34a;color:#fff}}#st.bad{{background:#dc2626;color:#fff}}
</style></head><body><main><div id="st" hidden></div><h1><b>PomeloO</b> · {host}</h1>{files}
<h2>Send to this PC</h2><label for="up">Choose files</label><input id="up" type="file" multiple>
<div id="log"></div><p>Files go to Downloads on {host}.</p></main><script>
const log=document.getElementById('log'),st=document.getElementById('st'),inp=document.getElementById('up');
let failed=[];
function status(cls,text){{st.hidden=false;st.className=cls;st.textContent=text}}
function send(f,pct){{return new Promise(ok=>{{const x=new XMLHttpRequest();x.open('PUT','up?name='+encodeURIComponent(f.name));
 x.upload.onprogress=p=>{{if(p.lengthComputable)pct(p.loaded/p.total)}};
 x.onload=()=>ok(x.status==200?'':(x.responseText||'error '+x.status));
 x.onerror=x.ontimeout=()=>ok('connection lost');x.send(f)}})}}
async function run(files){{
 failed=[];let done=0;const n=files.length;
 for(const f of files){{
  const row=document.createElement('div'),nm=document.createElement('span'),info=document.createElement('span');
  row.className='row';nm.textContent=f.name;info.textContent='…';row.append(nm,info);log.append(row);
  status('',(n>1?'Sending '+(done+1)+' of '+n:'Sending')+'…');
  const err=await send(f,r=>{{const t=Math.round(r*100)+'%';info.textContent=t;status('',(n>1?'Sending '+(done+1)+' of '+n+': ':'Sending: ')+t)}});
  if(err){{failed.push(f);info.textContent='✗ '+err;row.style.color='#fca5a5'}}else{{done++;info.textContent='✓'}}
 }}
 if(failed.length)status('bad','✗ '+failed.length+' not sent. Tap here to retry.');
 else{{status('ok','✓ '+n+(n>1?' files':' file')+' sent to {host}');if(navigator.vibrate)navigator.vibrate(120)}}
}}
st.onclick=()=>{{if(st.className=='bad'&&failed.length)run(failed.slice())}};
inp.onchange=()=>{{const files=[...inp.files];inp.value='';if(files.length)run(files)}};
</script></body></html>"""


class Share:
    """Serves `files` (folders are zipped first) and receives uploads into INBOX until close()."""

    def __init__(self, files=(), on_receive=None):
        ip = lan_ip()
        if not ip:
            raise RuntimeError("Connect this PC to Wi-Fi (the same network as your phone) first.")
        self.tmp = Path(tempfile.mkdtemp(prefix="pomeloo-phone-"))
        self.files = []
        for f in map(Path, files):
            if f.is_dir():
                f = Path(shutil.make_archive(str(self.tmp / f.name), "zip", f))
            self.files.append(f)
        self.on_receive = on_receive or (lambda path: None)
        self.token = secrets.token_urlsafe(12)
        self.server = ThreadingHTTPServer((ip, 0), _handler(self))
        self.url = f"http://{ip}:{self.server.server_port}/{self.token}/"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def page(self) -> bytes:
        rows = "".join(f'<a class="f" href="f/{i}" download><span>{html.escape(f.name)}</span>'
                       f'<span>{f.stat().st_size / 1e6:.1f} MB</span></a>' for i, f in enumerate(self.files))
        files = f"<h2>From the PC</h2>{rows}" if rows else ""
        return _PAGE.format(host=html.escape(socket.gethostname()), files=files).encode()

    def receive(self, name: str, length: int, stream) -> Path:
        from .catalog import unique
        INBOX.mkdir(parents=True, exist_ok=True)
        dst = unique(INBOX / _safe_name(name))
        part = dst.with_name(dst.name + ".part")
        with open(part, "wb") as out:
            left = length
            while left > 0:
                chunk = stream.read(min(_CHUNK, left))
                if not chunk:
                    raise ConnectionError("upload interrupted")
                out.write(chunk)
                left -= len(chunk)
        part.replace(dst)
        self.on_receive(dst)
        return dst

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)


def _handler(share: Share):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):  # quiet
            pass

        def _route(self):
            url = urllib.parse.urlsplit(self.path)
            parts = url.path.strip("/").split("/")
            if not parts or not secrets.compare_digest(parts[0], share.token):
                return None, url
            return parts[1:], url

        def _send(self, code, body=b"", ctype="text/plain; charset=utf-8"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            rest, _ = self._route()
            if rest == [] or rest == [""]:
                return self._send(200, share.page(), "text/html; charset=utf-8")
            if rest and len(rest) == 2 and rest[0] == "f" and rest[1].isdigit() and int(rest[1]) < len(share.files):
                f = share.files[int(rest[1])]
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(f.stat().st_size))
                self.send_header("Content-Disposition", "attachment; filename*=UTF-8''" + urllib.parse.quote(f.name))
                self.end_headers()
                with open(f, "rb") as src:
                    shutil.copyfileobj(src, self.wfile, _CHUNK)
                return
            self._send(404, b"Not found")

        def do_PUT(self):
            rest, url = self._route()
            name = urllib.parse.parse_qs(url.query).get("name", [""])[0]
            length = int(self.headers.get("Content-Length") or 0)
            if rest != ["up"] or not name or length <= 0:
                return self._send(404 if rest != ["up"] else 400, b"Bad request")
            try:
                share.receive(name, length, self.rfile)
                self._send(200, b"ok")
            except (OSError, ConnectionError) as e:
                self._send(500, str(e).encode())
    return Handler
