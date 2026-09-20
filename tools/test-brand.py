#!/usr/bin/env python3
"""The Fasty DNS brand, as the panels actually serve it.

The design system is not a stylesheet to be admired: what matters is that both
panels draw in the brand's colours and faces, that the faces are served by the
panels themselves - Google Fonts is blocked where these pages are opened - and
that the installer carries real font files to serve.
"""
import base64
import importlib.machinery
import importlib.util
import io
import os
import shutil
import sys
import tempfile

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
os.environ["no_proxy"] = os.environ["NO_PROXY"] = "*"
fails = []


def check(label, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + label + ((" - " + detail) if detail and not cond else ""))
    if not cond:
        fails.append(label)


def load(name, mod):
    spec = importlib.util.spec_from_loader(
        mod, importlib.machinery.SourceFileLoader(mod, os.path.join(ROOT, "templates", name)))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def read(*parts):
    return open(os.path.join(ROOT, *parts), encoding="utf-8").read()


sync = load("smartdns-sync", "sync")
admin = load("smartdns-admin", "admin")
tmp = tempfile.mkdtemp()

# The tokens the whole system is built from. Every one of them has to be in
# both panels' stylesheets, and none of the old palette may be left.
TOKENS = {"--void:#07080A", "--surface:#0D0F12", "--line:#23272E", "--dim:#646B76",
          "--muted:#9AA1AC", "--text:#EDEFF2", "--signal:#C7F000", "--warn:#FFB020",
          "--fail:#FF4D3D"}
OLD = ("#7dd3a0", "#238636", "#0f1115", "#171a21", "border-radius:16px", "border-radius:12px",
       "linear-gradient", "🩺")

print("the customer panel")
css = sync.USER_CSS
check("every colour token is there", TOKENS <= {t for t in TOKENS if t in css}, str(TOKENS))
check("and none of the old palette", not any(o in css for o in OLD),
      str([o for o in OLD if o in css]))
check("no rounded corners on any surface", "border-radius" not in css)
check("both faces come from this panel", "url(/f/space.woff2)" in css and "url(/f/mono.woff2)" in css)
check("numerals are mono", "'JetBrains Mono'" in css and ".big{font-family:'JetBrains Mono'" in css)
check("Persian falls through to the device's face", "Vazirmatn,Tahoma" in css)
check("buttons keep a 44px hit target", "min-height:44px" in css)
check("the brand's own transition, and nothing else", css.count("ease-out") >= 1
      and "transform:" not in css.replace("text-transform:", "") and "box-shadow" not in css)
check("it is called Fasty DNS", sync.brand() == "Fasty DNS")
mark = sync.brand_html()
check("the mark is drawn, not fetched", "<svg" in mark and "#C7F000" in mark
      and "M12 14 L20 22 L12 30" in mark and "rx='11'" in mark)
check("the lockup is Fasty + DNS", ">Fasty<" in mark and ">DNS<" in mark)
check("no emoji mark is left", "🩺" not in mark)
page = sync.user_page("<p>x</p>")
check("the page carries the mark as its icon", "rel=\"icon\"" in page and "%23C7F000" in page)
check("and says Fasty DNS in the footer", "FASTY DNS" in page)

print("the admin panel")
acss = admin.CSS
check("every colour token is there", TOKENS <= {t for t in TOKENS if t in acss})
check("and none of the old palette", not any(o in acss for o in OLD),
      str([o for o in OLD if o in acss]))
check("no rounded corners", "border-radius" not in acss)
check("both faces come from this panel", "url(f/space.woff2)" in acss and "url(f/mono.woff2)" in acss)
check("table headings and metrics are mono", acss.count("'JetBrains Mono'") >= 4)
amark = admin.brand_html()
check("the same mark", "#C7F000" in amark and "M23 14 L31 22 L23 30" in amark)
admin.CFG = {"ADMIN_PATH": "secret", "ADMIN_PORT": "9443"}
apage = admin.page("کاربران", "<p>x</p>", admin.CFG, "users")
check("the page carries the mark as its icon", "rel=\"icon\"" in apage and "%23C7F000" in apage)
check("and the lockup in its header", ">Fasty<" in apage and ">DNS<" in apage)
check("the sign-in page is branded too", ">Fasty<" in admin.login_page(admin.CFG))

print("the faces themselves")
for name, b64 in (("space", "space-grotesk.woff2.b64"), ("mono", "jetbrains-mono.woff2.b64")):
    raw = base64.b64decode(read("assets", "fonts", b64))
    check("%s is a real woff2" % name, raw[:4] == b"wOF2", str(raw[:8]))
    check("%s is small enough to carry" % name, len(raw) < 40000, "%d bytes" % len(raw))
    with open(os.path.join(tmp, "%s.woff2" % name), "wb") as fh:
        fh.write(raw)
carried = sum(len(read("assets", "fonts", f)) for f in
              ("space-grotesk.woff2.b64", "jetbrains-mono.woff2.b64"))
check("both together stay under 60 KB of the installer", carried < 60000, "%d bytes" % carried)

print("served by the panels")
sync.FONT_DIR = admin.FONT_DIR = tmp


def relay_get(path):
    h = sync.UserPanel.__new__(sync.UserPanel)
    h.path, h.command, h.request_version = path, "GET", "HTTP/1.1"
    h.requestline = "GET %s HTTP/1.1" % path
    h.client_address = ("5.200.1.2", 40000)
    h.headers = {}
    h.rfile, h.wfile, h._headers_buffer, h.close_connection = io.BytesIO(), io.BytesIO(), [], True
    h.do_GET()
    raw = h.wfile.getvalue()
    head, _, body = raw.partition(b"\r\n\r\n")
    return head.decode("utf-8", "replace"), body


sync.CFG = {"PANEL_DOMAIN": "relay.example.com", "SELF_IP": "5.9.10.11"}
head, body = relay_get("/f/space.woff2")
check("the relay serves the face", head.startswith("HTTP/1.1 200") and body[:4] == b"wOF2", head[:80])
check("as a font, cached for a year", "Content-Type: font/woff2" in head
      and "max-age=31536000, immutable" in head)
head, _ = relay_get("/f/../../etc/passwd")
check("and serves nothing else from that directory", "404" in head.split("\r\n")[0])
head, _ = relay_get("/f/other.woff2")
check("nor a face it does not have", "404" in head.split("\r\n")[0])

src = read("templates", "smartdns-admin")
check("the admin panel serves them before asking for a password",
      src.index('if rest.startswith("f/")') < src.index("return self.send(login_page(CFG))"))

print("carried by the installer")
logic = read("tools", "installer-logic.sh")
build = read("tools", "build-installer.py")
check("both faces are payloads", '"assets/fonts/space-grotesk.woff2.b64"' in build
      and '"assets/fonts/jetbrains-mono.woff2.b64"' in build)
check("written where the panels look", "/usr/local/share/smart-dns/fonts" in logic
      and "base64 -d" in logic)
check("and recorded, so uninstall takes them away", 'note_file "$dest"' in logic)
check("an extra exit gets none - it has no panel", '[ "$ROLE" != extra ]' in
      logic[logic.index("step \"Panel fonts\"") - 400:logic.index("step \"Panel fonts\"")])
built = os.path.join(ROOT, "doctor-dns.sh")
if os.path.exists(built):
    whole = read("doctor-dns.sh")
    check("the built installer carries them", "#__BEGIN_FONT_SPACE__" in whole
          and "#__BEGIN_FONT_MONO__" in whole)
    check("and the brand with them", "#C7F000" in whole and "Fasty" in whole)

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
