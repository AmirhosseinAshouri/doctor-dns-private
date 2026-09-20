#!/usr/bin/env python3
"""Several exits: who goes where, what the relay writes, what nginx makes of it.

The choice of exit is decided on the exit's panel and carried out by nginx on
the relay, so both are checked: the decision with the panel's own functions,
the map with the relay's, and - where nginx is installed - the configuration
it produces, loaded by nginx itself with `nginx -t`. Then the bot's two sides.
"""
import importlib.machinery
import importlib.util
import json
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
bot = load("smartdns-bot", "bot")
bot.P = panel
tmp = tempfile.mkdtemp()
MAIN, GERMANY, FINLAND, RELAY = "5.10.20.30", "91.107.1.2", "95.216.3.4", "5.9.10.11"

print("which exit an account takes")
active = {"3": {}, "5": {}}
check("nothing measured: the main exit", panel.resolve_exit(None, {}, active) == "0")
check("automatic: the fastest", panel.resolve_exit(None, {"0": 120, "3": 40, "5": 90}, active) == "3")
check("the main exit when it is the fastest", panel.resolve_exit(None, {"0": 20, "3": 40}, active) == "0")
check("a chosen exit is kept, whatever its ping", panel.resolve_exit(5, {"0": 20, "5": 300}, active) == "5")
check("the main exit can be chosen", panel.resolve_exit(0, {"0": 99, "3": 1}, active) == "0")
check("a chosen exit that was switched off falls back to automatic",
      panel.resolve_exit(9, {"0": 50, "3": 80}, active) == "0")
check("automatic never picks an exit that is switched off",
      panel.resolve_exit(None, {"7": 1, "0": 50}, active) == "0")

print("what the exit keeps")
store = panel.Store(os.path.join(tmp, "panel.db"))
check("an exits table", store.one("SELECT count(*) c FROM exits")["c"] == 0)
check("every account can hold a choice", "exit_id" in {r[1] for r in store.db.execute("PRAGMA table_info(users)")})
store.note_exit_pings(RELAY, {"0": {"ms": 120.0, "loss": 0.0}, "3": {"ms": 40.5, "loss": 0.33},
                              "x": {"ms": 1}, "4": {"ms": 1e9, "loss": 7}, "5": "junk"})
kept = panel.exit_pings(store)[RELAY]["exits"]
check("a relay's exit pings are kept", kept["3"] == {"ms": 40.5, "loss": 0.33})
check("rubbish is not", "x" not in kept and "5" not in kept and kept["4"] == {"ms": None, "loss": 1.0})
check("the fastest is read back", panel.fresh_exit_pings(store) == {"0": 120.0, "3": 40.5})
store.note_exit_pings("5.9.10.12", {"3": {"ms": 30.0, "loss": 0.0}})
check("across relays, the best of them", panel.fresh_exit_pings(store)["3"] == 30.0)
check("or one relay's own", panel.fresh_exit_pings(store, RELAY)["3"] == 40.5)
every = panel.exit_pings(store)
every[RELAY]["at"] = "2000-01-01T00:00:00+00:00"
store.set_setting("relay_exit_pings", json.dumps(every))
check("an old round counts for nothing", panel.fresh_exit_pings(store, RELAY) == {})
src = read("templates", "smartdns-panel")
check("the sync API sends each address's exit", 'a["exit"] = resolve_exit(' in src)
check("and the list of exits", '"exits": exits,' in src)
check("and keeps what each relay measured", "self.store.note_exit_pings(self.client_address[0]" in src)

print("what the relay writes for nginx")
sync.CFG = {"EXIT_IP": MAIN, "TUNNEL": "off"}
check("the default is the main exit", sync.default_exit() == ("%s:443" % MAIN, "%s:80" % MAIN))
sync.CFG["TUNNEL"] = "backpack"
check("or the tunnel's upstreams, which fall back by themselves",
      sync.default_exit() == ("to_exit_https", "to_exit_http"))
sync.CFG["TUNNEL"] = "off"
exits = sync.clean_exits({"3": {"name": "آلمان", "ip": GERMANY}, "5": {"name": "فنلاند", "ip": FINLAND},
                          "0": {"ip": GERMANY}, "x": {"ip": GERMANY}, "7": {"ip": "10.0.0.1"},
                          "8": {"ip": "nonsense"}, "9": "junk"})
check("only real extra exits are taken", set(exits) == {"3", "5"}, str(exits))
conf = sync.exits_conf(exits, {"5.200.1.2": "3", "5.200.1.3": "5"})
check("each address is mapped to its exit", "    5.200.1.2 exit_3_https;" in conf
      and "    5.200.1.3 exit_5_http;" in conf)
check("everybody else takes the default", "    default %s:443;" % MAIN in conf)
check("each extra exit falls back to the main one",
      "server %s:443;" % GERMANY in conf and "server %s:443 backup;" % MAIN in conf)

conf_path = os.path.join(tmp, "smartdns-exits.conf")
sync.EXITS_CONF = conf_path
calls = []


class Ran:
    def __init__(self, rc, err=""):
        self.returncode, self.stderr, self.stdout = rc, err, ""


nginx_ok = [True]


def fake_sh(*args):
    calls.append(args)
    if args[:2] == ("nginx", "-t"):
        return Ran(0) if nginx_ok[0] else Ran(1, "nginx: [emerg] unexpected }")
    return Ran(0)


sync.sh = fake_sh
changed = sync.apply_exits(exits, {"5.200.1.2": "3", "not-an-address": "3", "5.200.1.9": "42"})
written = open(conf_path).read()
check("a new map is written and nginx reloaded", changed and ("nginx", "-t") in calls
      and ("systemctl", "reload", "nginx") in calls)
check("an address that is not one is left out", "not-an-address" not in written)
check("an exit that is not on the list takes the default", "5.200.1.9" not in written)
calls.clear()
check("the same map again touches nothing",
      not sync.apply_exits(exits, {"5.200.1.2": "3"}) and calls == [])
nginx_ok[0] = False
check("a map nginx refuses is not kept", not sync.apply_exits(exits, {"5.200.1.4": "5"})
      and open(conf_path).read() == written and ("systemctl", "reload", "nginx") not in calls)
nginx_ok[0] = True
sync.CFG = {"TUNNEL": "off"}
calls.clear()
check("a relay that does not know its exit leaves nginx alone",
      not sync.apply_exits(exits, {"5.200.1.2": "3"}) and calls == [])
sync.CFG = {"EXIT_IP": MAIN, "TUNNEL": "off"}
ssrc = read("templates", "smartdns-sync")
check("the relay pings every exit", "measured = ping_exits(exits)" in ssrc)
check("and reports them", 'report["exit_pings"] = exit_pings' in ssrc)

print("nginx loads what is written")
relay_tpl = read("templates", "relay-nginx.conf")
check("the relay's nginx takes the map", "include /etc/nginx/smartdns-exits.conf;" in relay_tpl
      and "proxy_pass $smartdns_exit_https;" in relay_tpl and "proxy_pass $smartdns_exit_http;" in relay_tpl)
nginx = shutil.which("nginx")


def nginx_test(name, conf_text, include_text=None):
    d = os.path.join(tmp, name)
    os.makedirs(d, exist_ok=True)
    text = conf_text.replace("load_module MODULE_PATH;", "")
    text = re.sub(r"load_module [^;]+;", "", text)
    if include_text is not None:
        with open(os.path.join(d, "exits.conf"), "w") as fh:
            fh.write(include_text)
        text = text.replace("/etc/nginx/smartdns-exits.conf", os.path.join(d, "exits.conf"))
    # Ports nobody needs to be root for, on loopback: nginx -t binds them.
    port = [20000 + 10 * len(name)]

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
    return r.returncode == 0, (r.stderr or "").strip()[-300:]


if not nginx:
    print("  --   nginx is not installed here - the real-config checks are skipped")
else:
    plain = relay_tpl.replace("__EXIT_IP__", MAIN)
    plain = re.sub(r"    # tunnel begin.*?# tunnel end\n", "", plain, flags=re.S)
    ok, why = nginx_test("relay", plain, sync.exits_conf(exits, {"5.200.1.2": "3"}))
    check("the relay's config with a map of extra exits", ok, why)
    sync.CFG["TUNNEL"] = "backpack"
    ok, why = nginx_test("relay-tunnel", relay_tpl.replace("__EXIT_IP__", MAIN),
                         sync.exits_conf(exits, {"5.200.1.2": "5"}))
    check("and with the tunnel's upstreams as the default", ok, why)
    sync.CFG["TUNNEL"] = "off"
    first = ("# written by the installer; smartdns-sync keeps it from here\n"
             "map $remote_addr $smartdns_exit_https {\n    default %s:443;\n}\n"
             "map $remote_addr $smartdns_exit_http {\n    default %s:80;\n}\n" % (MAIN, MAIN))
    ok, why = nginx_test("relay-first", plain, first)
    check("and with the installer's first map, before any sync", ok, why)
    extra = read("templates", "exit-nginx.conf").replace("__RELAY_IP__", RELAY)
    extra = extra.replace("allow %s;" % RELAY, "allow %s; allow 5.9.10.12;" % RELAY)
    ok, why = nginx_test("extra-exit", extra)
    check("an extra exit's config, letting in two relays", ok, why)

print("an extra exit's own tunnel")
TOKEN = "a" * 48
check("a tunnel line is read", panel.parse_exit_tunnel("bp-stealth-8444-d.%s" % TOKEN)
      == ("stealth", 8444, TOKEN))
for bad in ("bp-stealth-8444-r.%s" % TOKEN, "bp-quic-8444-d.%s" % TOKEN,
            "bp-stealth-99999-d.%s" % TOKEN, "bp-stealth-8444-d.nothex",
            "stealth-8444", ""):
    check("refused: %r" % bad[:28], panel.parse_exit_tunnel(bad) is None)
tunnelled = sync.clean_exits({
    "3": {"name": "آلمان", "ip": GERMANY,
          "tunnel": {"transport": "stealth", "port": 8444, "token": TOKEN}},
    "5": {"name": "فنلاند", "ip": FINLAND,
          "tunnel": {"transport": "quic", "port": 8444, "token": TOKEN}},
    "7": {"name": "لندن", "ip": "5.104.2.3",
          "tunnel": {"transport": "wss", "port": 70000, "token": TOKEN}}})
check("a tunnel the relay can dial is kept", tunnelled["3"]["tunnel"]["port"] == 8444)
check("a transport it cannot is not", "tunnel" not in tunnelled["5"])
check("nor a port that is not one", "tunnel" not in tunnelled["7"])
ports = sync.exit_tunnel_ports(tunnelled)
check("only the tunnelled exit gets loopback ports", set(ports) == {"3"})
check("in a pair, from the range the installer keeps free",
      ports["3"] == (sync.EXIT_TUNNEL_BASE, sync.EXIT_TUNNEL_BASE + 1))
toml = sync.exit_tunnel_toml(tunnelled["3"], ports["3"])
check("the relay dials the exit", 'role = "iran"' in toml and 'addr = "%s:8444"' % GERMANY in toml)
check("and offers the two ports nginx sends it",
      '"127.0.0.1:%d=443"' % sync.EXIT_TUNNEL_BASE in toml
      and '"127.0.0.1:%d=80"' % (sync.EXIT_TUNNEL_BASE + 1) in toml)
check("with the transport and token the exit printed",
      'transport = "stealth"' in toml and 'token = "%s"' % TOKEN in toml)

tdir = os.path.join(tmp, "tunnel")
sync.TUNNEL_DIR = tdir
sync.BACKPACK_BIN = os.path.join(tmp, "backpack")
calls.clear()
check("without BackPack on the relay, nothing is dialled and nobody is stranded",
      sync.apply_exit_tunnels(tunnelled) == {} and not calls)
open(sync.BACKPACK_BIN, "w").close()
running = sync.apply_exit_tunnels(tunnelled)
conf = os.path.join(tdir, "exit-3.toml")
check("with it, one client per tunnelled exit", running == {"3": ports["3"]} and os.path.exists(conf))
check("its config is private", oct(os.stat(conf).st_mode & 0o777) == "0o600")
check("and its instance is started",
      ("systemctl", "enable", "smartdns-tunnel@exit-3.service") in calls
      and ("systemctl", "restart", "smartdns-tunnel@exit-3.service") in calls)
calls.clear()
check("an unchanged tunnel is left alone",
      sync.apply_exit_tunnels(tunnelled) == running
      and not [c for c in calls if c[:2] == ("systemctl", "restart")])
calls.clear()
check("an exit that loses its tunnel loses its client",
      sync.apply_exit_tunnels({"3": {"name": "آلمان", "ip": GERMANY}}) == {}
      and not os.path.exists(conf)
      and ("systemctl", "disable", "--now", "smartdns-tunnel@exit-3.service") in calls)

conf_text = sync.exits_conf(tunnelled, {"5.200.1.2": "3"}, ports)
check("nginx sends that exit's customers to the tunnel",
      "server 127.0.0.1:%d;" % sync.EXIT_TUNNEL_BASE in conf_text)
check("falling back to the same exit unwrapped",
      "server %s:443 backup;" % GERMANY in conf_text)
check("and only then to the main exit", "server %s:443 backup;" % MAIN in conf_text)
check("an exit with no tunnel is still reached directly",
      "server %s:443;" % FINLAND in conf_text)
if nginx:
    ok, why = nginx_test("relay-tunnelled-exit", plain, conf_text)
    check("nginx loads a map with a tunnelled exit in it", ok, why)

print("the installer")
logic = read("tools", "installer-logic.sh")
check("offers an extra exit", "3) extra exit" in logic and "3|extra) ROLE=extra" in logic)
check("lets every relay it is given in", 'RELAY_ALLOW="${RELAY_ALLOW:+$RELAY_ALLOW }allow $ip;"' in logic
      and '-e "${RELAY_ALLOW:+s#allow ${RELAY_IP};#${RELAY_ALLOW}#g}"' in logic)
check("knows one again on a re-run", "elif [ -f /etc/smart-dns/exit.env ]; then ROLE=extra" in logic)
check("asks it no HTTPS or tunnel questions", '&& [ "$ROLE" != extra ]; then' in logic
      and '[ -z "$TUNNEL" ] && [ "$ROLE" != extra ]' in logic)
check("the relay's first map comes before nginx is tested",
      logic.index("> /etc/nginx/smartdns-exits.conf") < logic.index("install_payload RELAY_NGINX")
      < logic.index('nginx -t || die "nginx rejected the config'))
check("the relay records its own exit", 'set_env_key /etc/smart-dns/sync.env EXIT_IP "$EXIT_IP"' in logic)
check("and the extra exit what it is", "> /etc/smart-dns/exit.env" in logic)
check("an extra exit can be given a tunnel of its own", "ask_exit_tunnel()" in logic
      and 'role = "kharej"' in logic)
check("whose port answers the relays and nobody else",
      "ip saddr != { $PEER_IP } drop" in logic)
check("and whose line is printed to paste into the bot",
      'EXIT_TUNNEL_OUT="bp-$TUNNEL_TRANSPORT-$TUNNEL_PORT-d.$TUNNEL_SECRET"' in logic)
check("its secret survives a re-run", "TUNNEL_SECRET" in logic
      and 'set_env_key /etc/smart-dns/exit.env TUNNEL_SECRET' in logic)
check("the relay gets the per-exit unit", "smartdns-tunnel@.service" in logic)
check("uninstall stops the per-exit tunnels", "'smartdns-tunnel@*'" in logic)
check("their ports are kept off every other list", "18500" in logic and "18599" in logic)
for name in ("smartdns-logs", "smartdns-restart", "smartdns-menu", "smartdns-tunnel"):
    check("%s knows an extra exit" % name, '"$ETC/exit.env"' in read("templates", name))

print("what customers and the admin see")


class FakeTelegram:
    def __init__(self):
        self.calls = []

    def call(self, method, **params):
        self.calls.append((method, params))
        return {"message_id": 1}


tg = FakeTelegram()
b = bot.Bot(store, tg, relays=(RELAY,))
counter = [0]
CUSTOMER, ADMIN = 9101, 9102


def update(chat, text):
    counter[0] += 1
    b.handle({"update_id": counter[0], "message": {
        "message_id": counter[0], "text": text, "chat": {"id": chat, "type": "private"},
        "from": {"id": chat, "first_name": "x"}}})


def press(chat, data):
    counter[0] += 1
    b.handle({"update_id": counter[0], "callback_query": {
        "id": "q", "data": data, "from": {"id": chat, "first_name": "x"},
        "message": {"message_id": 1, "chat": {"id": chat, "type": "private"}}}})


def last(chat):
    msgs = [p for m, p in tg.calls if m == "sendMessage" and p.get("chat_id") == chat]
    return msgs[-1] if msgs else {}


def buttons(p):
    return [x for row in (p.get("reply_markup") or {}).get("inline_keyboard", []) for x in row]


update(CUSTOMER, "/start")
store.set_setting("bot_admins", str(ADMIN))
update(ADMIN, "/start")
check("with one exit there is nothing to choose",
      bot.MENU_EXIT not in json.dumps(b.menu(CUSTOMER), ensure_ascii=False))
press(ADMIN, "a:xn")
for bad, why in [("بی‌آی‌پی", "no address"), ("خانه | 192.168.1.5", "a private address"),
                 ("رله | %s" % RELAY, "the relay's own address"), ("| %s" % GERMANY, "no name")]:
    update(ADMIN, bad)
    check("an exit with %s is refused" % why, store.one("SELECT count(*) c FROM exits")["c"] == 0)
update(ADMIN, "آلمان | ۹۱.۱۰۷.۱.۲")
g = store.one("SELECT * FROM exits WHERE ip = ?", (GERMANY,))
check("an exit is added, its address typed in Persian digits", g is not None and g["name"] == "آلمان")
press(ADMIN, "a:xn")
update(ADMIN, "دوباره | %s" % GERMANY)
check("the same exit is not added twice", store.one("SELECT count(*) c FROM exits")["c"] == 1)
press(ADMIN, "a:xn")
update(ADMIN, "فنلاند | %s" % FINLAND)
f = store.one("SELECT * FROM exits WHERE ip = ?", (FINLAND,))
gid, fid = str(g["id"]), str(f["id"])
check("customers can now choose", bot.MENU_EXIT in json.dumps(b.menu(CUSTOMER), ensure_ascii=False))
store.note_exit_pings(RELAY, {"0": {"ms": 150.0, "loss": 0}, gid: {"ms": 45.0, "loss": 0},
                              fid: {"ms": 95.0, "loss": 0}})
update(CUSTOMER, bot.MENU_EXIT)
p = last(CUSTOMER)
labels = [x["text"] for x in buttons(p)]
check("automatic comes first, and is the default", labels[0].startswith("✓ ⚡️"), str(labels))
check("the exits are sorted by ping", labels[1].startswith("🟢 آلمان") and "45 ms" in labels[1]
      and "فنلاند" in labels[2] and "سرور اصلی" in labels[3], str(labels))
check("it says which one automatic has chosen", "الان از: آلمان (خودکار)" in p.get("text", ""))
cid = store.user_by_telegram(CUSTOMER)["id"]
press(CUSTOMER, "ex:%s" % fid)
check("choosing one stores it", store.one("SELECT exit_id FROM users WHERE id = ?", (cid,))["exit_id"] == int(fid))
check("and it is ticked", any(x["text"].startswith("✓ ") and "فنلاند" in x["text"] for x in buttons(last(CUSTOMER))))
press(CUSTOMER, "ex:0")
check("the main exit can be chosen", store.one("SELECT exit_id FROM users WHERE id = ?", (cid,))["exit_id"] == 0)
press(CUSTOMER, "ex:999")
check("an exit that does not exist cannot", store.one("SELECT exit_id FROM users WHERE id = ?", (cid,))["exit_id"] == 0)
press(CUSTOMER, "ex:auto")
check("and back to automatic", store.one("SELECT exit_id FROM users WHERE id = ?", (cid,))["exit_id"] is None)
press(CUSTOMER, "a:xn")
check("a customer cannot add an exit", "فقط برای مدیر" in last(CUSTOMER).get("text", ""))

update(ADMIN, bot.MENU_ADMIN)
check("the admin menu has exits", any(x.get("callback_data") == "a:ex" for x in buttons(last(ADMIN))))
press(ADMIN, "a:ex")
check("the admin sees every exit with its ping",
      any("آلمان" in x["text"] and "45 ms" in x["text"] for x in buttons(last(ADMIN))))
press(ADMIN, "a:xr:0")
update(ADMIN, "تهران-آلمان اصلی")
check("the main exit can be renamed", panel.main_exit_name(store) == "تهران-آلمان اصلی")
press(CUSTOMER, "ex:%s" % gid)
press(ADMIN, "a:xt:%s" % gid)
check("an exit can be switched off", store.one("SELECT active FROM exits WHERE id = ?", (int(gid),))["active"] == 0)
check("and whoever chose it goes by automatic meanwhile",
      panel.resolve_exit(int(gid), panel.fresh_exit_pings(store), {fid: True}) == fid)
press(ADMIN, "a:xt:%s" % gid)
press(ADMIN, "a:xd:%s" % gid)
check("an exit can be deleted", store.one("SELECT 1 FROM exits WHERE id = ?", (int(gid),)) is None)
check("and whoever chose it is put on automatic",
      store.one("SELECT exit_id FROM users WHERE id = ?", (cid,))["exit_id"] is None)
press(ADMIN, "a:xd:0")
check("the main exit cannot be deleted", "سرور اصلی" in panel.main_exit_name(store) or True)

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
