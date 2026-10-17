#!/usr/bin/env python3
"""A name with an exit of its own: EA refusing one exit and accepting another.

Why it exists: FC 27's Ultimate Team front end on Google Cloud reset one of
our exits during the TLS handshake and answered another with a plain 404. The
customer's exit decides everything they do; this decides one name, so the
service that needed moving moves and nothing else does.

Three sides, as ever: the panel keeps the list, the relay turns it into nginx's
map, and - where nginx is installed - nginx itself loads what the relay wrote.
"""
import importlib.machinery
import importlib.util
import os
import re
import shutil
import subprocess
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
    print(("  ok   " if cond else "  FAIL ") + label +
          ((" - " + detail) if detail and not cond else ""))
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


panel = load("smartdns-panel", "panel")
sync = load("smartdns-sync", "sync")
admin = load("smartdns-admin", "admin")
tmp = tempfile.mkdtemp()
MAIN, GERMANY, RELAY = "5.10.20.30", "91.107.1.2", "5.9.10.11"
UT = "*.futc-ext.gcp.ea.com"

# ------------------------------------------------------------- the operator
print("what the panel keeps")
db = os.path.join(tmp, "panel.db")
store = panel.Store(db)
store.run("INSERT INTO exits (id, name, ip, active, created_at)"
          " VALUES (2, 'آلمان', ?, 1, ?)", (GERMANY, panel.now()))
check("a name can be pointed at an exit", store.set_name_exit(UT, 2) == UT)
check("a bare name too",
      store.set_name_exit("utas.prd.s5.prd.futc-ext.gcp.ea.com", 2)
      == "utas.prd.s5.prd.futc-ext.gcp.ea.com")
check("a suffix typed with a dot becomes the wildcard nginx wants",
      store.set_name_exit(".fut.ea.com", 2) == "*.fut.ea.com")
check("the main exit can be the one chosen", store.set_name_exit("accounts.ea.com", 0) == "accounts.ea.com")
for bad in ("not a host", "-x.com", "a..b", "", "*", "*.", "x", "a_b.com", "a" * 300 + ".com"):
    check("  %r is refused" % bad, store.set_name_exit(bad, 2) is None)
check("pointing the same name again moves it rather than doubling it",
      store.set_name_exit(UT, 0) == UT
      and store.one("SELECT count(*) c FROM name_exits WHERE host = ?", (UT,))["c"] == 1
      and store.one("SELECT exit_id e FROM name_exits WHERE host = ?", (UT,))["e"] == 0)
store.set_name_exit(UT, 2)

store.set_name_exit("orphan.example.com", 7)
sent = store.name_exit_map()
check("the relays are told about the live ones",
      sent.get(UT) == "2" and sent.get("accounts.ea.com") == "0", str(sent))
check("and not about a name pointed at an exit that is gone",
      "orphan.example.com" not in sent, str(sent))
store.run("UPDATE exits SET active = 0 WHERE id = 2")
check("an exit switched off takes its names with it",
      UT not in store.name_exit_map(), str(store.name_exit_map()))
store.run("UPDATE exits SET active = 1 WHERE id = 2")
check("and brings them back when it comes back", UT in store.name_exit_map())
store.del_name_exit("orphan.example.com")
check("a name can be taken off the list",
      not store.one("SELECT count(*) c FROM name_exits WHERE host = 'orphan.example.com'")["c"])
check("the sync API hands the list to the relays",
      '"name_exits": self.store.name_exit_map(),' in read("templates", "smartdns-panel"))

# ----------------------------------------------------------------- the relay
print("what the relay makes of it")
sync.CFG = {"SELF_IP": "203.0.113.1", "EXIT_IP": MAIN, "TUNNEL": "off"}
exits = {"2": {"name": "آلمان", "ip": GERMANY}}
check("junk from the panel is dropped, name by name",
      sync.clean_name_exits({"not a host": "2", UT: "2", "x.com": "nine",
                             "y.com": "404", "z.com": 2}, exits)
      == {UT: "2", "z.com": "2"},
      str(sync.clean_name_exits({"not a host": "2", UT: "2", "x.com": "nine",
                                 "y.com": "404", "z.com": 2}, exits)))
check("a name is lower-cased and its trailing dot dropped",
      sync.clean_name_exits({"UTAS.FUT.EA.COM.": "2"}, exits) == {"utas.fut.ea.com": "2"})
check("the relay's own exit is a valid target",
      sync.clean_name_exits({"accounts.ea.com": "0"}, exits) == {"accounts.ea.com": "0"})
check("and a list longer than the cap is cut, not refused",
      len(sync.clean_name_exits({"h%d.example.com" % i: "2" for i in range(400)}, exits))
      == sync.NAME_EXITS_MAX)

conf = sync.exits_conf(exits, {"2.185.4.7": "2"}, None, {UT: "2", "accounts.ea.com": "0"})
check("the map is on the name in the handshake, not the address",
      "map $ssl_preread_server_name $smartdns_route_https {" in conf, conf)
check("and nginx is told these keys are hostnames, so *.name matches",
      "hostnames;" in conf, conf)
check("a name with no rule falls through to the customer's own exit",
      "default $smartdns_exit_https;" in conf, conf)
check("the named one goes to its exit's upstream",
      "    %s exit_2_https;" % UT in conf, conf)
check("a name pointed at the main exit goes straight there",
      "    accounts.ea.com %s:443;" % MAIN in conf, conf)
check("port 80 is left on the customer's exit - a stream proxy reads no name there",
      "$smartdns_exit_http" in conf and "$smartdns_route_http " not in conf)
sync.CFG["TUNNEL"] = "backpack"
tunnelled = sync.exits_conf(exits, {}, None, {"accounts.ea.com": "0"})
check("with a tunnel, the main exit means the tunnel's upstream",
      "    accounts.ea.com to_exit_https;" in tunnelled, tunnelled)
sync.CFG["TUNNEL"] = "off"
plain = sync.exits_conf(exits, {}, None, None)
check("no names, and the map is still there for nginx to pass to",
      "map $ssl_preread_server_name $smartdns_route_https {" in plain
      and "default $smartdns_exit_https;" in plain)

print("writing it")
sync.EXITS_CONF = conf_path = os.path.join(tmp, "exits.conf")
calls = []
nginx_ok = [True]


class Ran:
    def __init__(self, code, err=""):
        self.returncode, self.stdout, self.stderr = code, "", err


def fake_sh(*args):
    calls.append(args)
    if args[:2] == ("nginx", "-t"):
        return Ran(0) if nginx_ok[0] else Ran(1, "nginx: [emerg] unexpected }")
    return Ran(0)


sync.sh = fake_sh
changed = sync.apply_exits(exits, {}, None, {UT: "2"})
check("a name's exit reaches nginx", changed and UT in open(conf_path).read()
      and ("systemctl", "reload", "nginx") in calls)
written = open(conf_path).read()
check("writing the same list again changes nothing",
      not sync.apply_exits(exits, {}, None, {UT: "2"}))
nginx_ok[0] = False
calls.clear()
check("a list nginx refuses is rolled back, and nothing reloaded",
      not sync.apply_exits(exits, {}, None, {"new.example.com": "2"})
      and open(conf_path).read() == written
      and ("systemctl", "reload", "nginx") not in calls)
nginx_ok[0] = True
check("taking the name off the list takes it out of nginx too",
      sync.apply_exits(exits, {}, None, {}) and UT not in open(conf_path).read())

# ------------------------------------------------------------------- nginx
print("nginx loads it")
relay_tpl = read("templates", "relay-nginx.conf")
check("the relay reads the name from the handshake", "ssl_preread on;" in relay_tpl)
check("and does not wait long for one that never comes",
      re.search(r"preread_timeout \d+s;", relay_tpl) is not None)
check("443 passes to the name's map", "proxy_pass $smartdns_route_https;" in relay_tpl)
check("80 stays on the customer's exit", "proxy_pass $smartdns_exit_http;" in relay_tpl)
check("the installer writes the map too, before any sync has happened",
      "$smartdns_route_https" in read("tools", "installer-logic.sh"))

nginx = shutil.which("nginx")
if not nginx:
    print("  --   nginx is not installed here - the real-config check is skipped")
else:
    d = os.path.join(tmp, "ng")
    os.makedirs(d, exist_ok=True)
    text = re.sub(r"load_module [^;]+;", "", relay_tpl.replace("__EXIT_IP__", MAIN))
    text = re.sub(r"    # tunnel begin.*?# tunnel end\n", "", text, flags=re.S)
    with open(os.path.join(d, "exits.conf"), "w") as fh:
        fh.write(sync.exits_conf(exits, {"2.185.4.7": "2"}, None,
                                 {UT: "2", "accounts.ea.com": "0",
                                  "utas.prd.s5.prd.futc-ext.gcp.ea.com": "2"}))
    text = text.replace("/etc/nginx/smartdns-exits.conf", os.path.join(d, "exits.conf"))
    port = [21300]

    def listen(m):
        port[0] += 1
        return "listen 127.0.0.1:%d;" % port[0]
    text = re.sub(r"listen (\[::\]:)?(127\.0\.0\.1:)?\d+( default_server)?;", listen, text)
    path = os.path.join(d, "nginx.conf")
    with open(path, "w") as fh:
        fh.write(text)
    r = subprocess.run([nginx, "-t", "-p", d, "-c", path, "-e", os.path.join(d, "error.log"),
                        "-g", "pid %s;" % os.path.join(d, "nginx.pid")],
                       capture_output=True, text=True, timeout=60)
    check("nginx accepts the relay's config with names mapped to exits",
          r.returncode == 0, (r.stderr or "").strip()[-300:])

# ------------------------------------------------------------- the operator
print("the page the operator uses")
admin.DB = db
admin.CFG = {"ADMIN_PATH": "p"}
admin.STORE = admin.Store(db)
check("a typed name is cleaned the way the panel stores it",
      admin.clean_host_pattern("  HTTPS://UTAS.Fut.EA.com/x ") == "utas.fut.ea.com"
      and admin.clean_host_pattern(".fut.ea.com") == "*.fut.ea.com"
      and admin.clean_host_pattern("**.fut.ea.com") == "*.fut.ea.com")
check("and nonsense is refused rather than stored",
      all(admin.clean_host_pattern(b) is None
          for b in ("", "not a host", "-x.com", "x", "a_b.com")))
check("the exits to choose from are the main one and the live ones",
      admin.exit_choices()[0][0] == "0" and ("2", "آلمان") in admin.exit_choices(),
      str(admin.exit_choices()))


class Page:
    pass


Page.domains = admin.Admin.domains
store.set_name_exit(UT, 2)
page = Page().domains()
check("the page lists the names and which exit each takes",
      UT in page and "آلمان" in page, page[-400:])
check("it says this is a 443-only thing", "۴۴۳" in page)
check("the form offers every exit", "name='exit_id'" in page and ">آلمان<" in page)
check("a name already on the list is not suggested a second time",
      "می‌دانیم که این یکی" not in page and "التیمیت" not in page)
store.run("DELETE FROM name_exits")
empty = Page().domains()
check("with nothing set, it explains itself instead of showing a table",
      "خروجی برای یک نام (0)" in empty and "<th>نام</th>" not in empty, empty[-300:])
check("and it offers the one service we know needs this, ready to point at an exit",
      "futc-ext.gcp.ea.com" in empty and "التیمیت" in empty, empty[-300:])

src = read("templates", "smartdns-admin")
check("adding and removing one are their own actions",
      '"name-exit-add"' in src and '"name-exit-del"' in src)
check("an exit that does not exist is refused",
      'آن خروجی وجود ندارد' in src)

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
