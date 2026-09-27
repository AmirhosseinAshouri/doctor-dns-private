#!/usr/bin/env python3
"""The monitoring dashboard: where the numbers come from and what they show.

Three legs, in the order the data travels. The relay reads round trips out of
its own kernel, the exit keeps them beside where it found each game's servers,
and the admin panel draws the table the operator reads before buying another
exit. Nothing here reaches the internet: `ss`, DNS and the country lookup are
all stood in for.
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime, timedelta, timezone

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ["no_proxy"] = os.environ["NO_PROXY"] = "*"
fails = []


def check(label, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + label +
          ((" - " + detail) if detail and not cond else ""))
    if not cond:
        fails.append(label)


def load(name, mod):
    spec = importlib.util.spec_from_loader(
        mod, importlib.machinery.SourceFileLoader(
            mod, os.path.join(HERE, "..", "templates", name)))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


panel = load("smartdns-panel", "panel")
sync = load("smartdns-sync", "sync")
admin = load("smartdns-admin", "admin")
tmp = tempfile.mkdtemp()
RELAY = "5.9.10.11"

# ---------------------------------------------------------------- the relay
print("what the relay reads out of its own kernel")

# Real `ss -Htin` output: a socket line, then its details indented. Two
# connections from one customer, one from another, one from a private address
# (the operator's own tunnel, or a probe), and one still handshaking with no
# round trip yet.
SS = """ESTAB 0 0 203.0.113.9:443 2.185.4.7:51234
\t cubic wscale:7,7 rto:236 rtt:36.5/4.2 mss:1448 cwnd:10
ESTAB 0 0 203.0.113.9:443 2.185.4.7:51240
\t cubic wscale:7,7 rto:210 rtt:31.5/2.0 mss:1448 cwnd:10
ESTAB 0 0 203.0.113.9:80 2.185.4.7:51250
\t cubic rto:220 rtt:40.0/3.0 mss:1448 cwnd:10
ESTAB 0 0 203.0.113.9:443 91.98.30.40:40000
\t cubic wscale:7,7 rto:300 rtt:112.25/9.0 mss:1448 cwnd:10
ESTAB 0 0 203.0.113.9:443 10.8.0.2:50000
\t cubic rto:204 rtt:1.5/0.5 mss:1448 cwnd:10
ESTAB 0 0 203.0.113.9:443 2.185.4.99:44444
\t cubic rto:1000 mss:1448 cwnd:10
"""


class Ran:
    def __init__(self, out, code=0):
        self.stdout, self.stderr, self.returncode = out, "", code


asked = []


def fake_ss(*args):
    asked.append(args)
    return Ran(SS)


sync.sh = fake_ss
rtts = sync.client_rtts()
check("it asks the kernel, not the network",
      asked and asked[0][0] == "ss" and "-Htin" in asked[0], str(asked))
check("and only about the ports the service listens on",
      any("sport = :443" in a and "sport = :80" in a for a in asked[0]), str(asked[0]))
check("a customer with three connections is one row",
      rtts.get("2.185.4.7", {}).get("conns") == 3, json.dumps(rtts))
check("with the middle round trip, not the worst",
      rtts["2.185.4.7"]["ms"] == 36.5, json.dumps(rtts.get("2.185.4.7")))
check("a second customer is their own row",
      rtts.get("91.98.30.40", {}) == {"ms": 112.2, "conns": 1}
      or rtts.get("91.98.30.40", {}) == {"ms": 112.3, "conns": 1}, json.dumps(rtts))
check("a private address is not a customer", "10.8.0.2" not in rtts, json.dumps(rtts))
check("a connection with no round trip yet is skipped",
      "2.185.4.99" not in rtts, json.dumps(rtts))

sync.sh = lambda *a: Ran("", 1)
check("when ss is not there, nothing is reported", sync.client_rtts() == {})

sync.sh = lambda *a: 1 / 0
sync.current_state = lambda: []
sync.CFG = {"SELF_IP": "203.0.113.9", "SYNC_SECRET": "x", "SYNC_FINGERPRINT": "x"}
sent = {}


class Stop(Exception):
    """Stop sync_once once the report is in hand; the rest of it talks to
    nftables, nginx and dnsmasq, which is not what this file is about."""


def fake_post(path, payload):
    sent[path] = payload
    raise Stop()


sync.post = fake_post
try:
    sync.sync_once()
except Stop:
    pass
check("the report still goes out when the reading fails", "/sync" in sent, str(sent))
check("with no round trips in it rather than none of the report",
      sent.get("/sync", {}).get("client_rtt") == {}, json.dumps(sent.get("/sync", {}))[:200])

sync.sh = fake_ss
sent.clear()
try:
    sync.sync_once()
except Stop:
    pass
check("they ride along on the sync that was happening anyway",
      sent["/sync"]["client_rtt"].get("2.185.4.7", {}).get("ms") == 36.5,
      json.dumps(sent["/sync"].get("client_rtt")))
check("beside the usage counters, not on a second connection",
      "counters" in sent["/sync"] and len(asked) > 1, str(list(sent["/sync"])))

# ----------------------------------------------------------------- the exit
print("what the exit keeps")
db = os.path.join(tmp, "panel.db")
store = panel.Store(db)
store.note_client_rtt(RELAY, {"2.185.4.7": {"ms": 36.5, "conns": 3},
                              "91.98.30.40": {"ms": 112.2, "conns": 1}})
rows = {r["ip"]: r for r in store.q("SELECT * FROM client_paths")}
check("both customers are stored", sorted(rows) == ["2.185.4.7", "91.98.30.40"], str(sorted(rows)))
check("with the relay that measured them", rows["2.185.4.7"]["relay"] == RELAY)
check("and their round trip and connection count",
      rows["2.185.4.7"]["rtt_ms"] == 36.5 and rows["2.185.4.7"]["conns"] == 3)

store.note_client_rtt(RELAY, {"2.185.4.7": {"ms": 51.0, "conns": 1}})
row = store.one("SELECT * FROM client_paths WHERE ip = '2.185.4.7'")
check("the next reading replaces the last - this is a live picture",
      row["rtt_ms"] == 51.0 and row["conns"] == 1,
      str(dict(row)))
check("and the customer who stopped syncing is still there for now",
      store.one("SELECT count(*) c FROM client_paths")["c"] == 2)

store.note_client_rtt(RELAY, {"nonsense": {"ms": 5}, "5.22.1.9": {"ms": "fast"},
                             "5.22.1.10": {"ms": 90000}, "5.22.1.11": "no",
                             "5.22.1.12": {"ms": 12, "conns": -4}})
kept = {r["ip"]: r["conns"] for r in store.q("SELECT * FROM client_paths")}
check("junk from a relay is dropped, address by address",
      "nonsense" not in kept and "5.22.1.9" not in kept
      and "5.22.1.10" not in kept and "5.22.1.11" not in kept, str(sorted(kept)))
check("a sane address with a silly count is kept, counting zero",
      kept.get("5.22.1.12") == 0, str(kept))
store.note_client_rtt(RELAY, "not a dict")
check("a report that is not a table at all changes nothing",
      store.one("SELECT count(*) c FROM client_paths")["c"] == 3)

store.run("UPDATE client_paths SET at = ? WHERE ip = '91.98.30.40'",
          ((datetime.now(timezone.utc) - timedelta(hours=7)).isoformat(timespec="seconds"),))
store.note_client_rtt(RELAY, {"2.185.4.7": {"ms": 44.0, "conns": 2}})
check("a customer quiet for hours drops off the board",
      not store.one("SELECT count(*) c FROM client_paths WHERE ip = '91.98.30.40'")["c"])

print("where the games are")
catalogue = json.load(open(os.path.join(HERE, "..", "domains", "services.json"),
                          encoding="utf-8"))["services"]
# Two of Steam's hosts as the catalogue names them, rather than two names
# written out here: the catalogue is edited often, and a test that hard-codes
# what is in it fails for the wrong reason the next time it is.
STEAM_A, STEAM_B = panel.ping_targets(catalogue)["steam"]["hosts"][:2]
where = {STEAM_A: "104.90.1.1", STEAM_B: "23.50.2.2"}
countries = {"104.90.1.1": ("DE", "Akamai"), "23.50.2.2": ("NL", "Akamai"),
             "1.2.3.4": ("SG", "Somebody")}
looked = []


def fake_resolve(host):
    if host not in where:
        raise OSError("NXDOMAIN")
    return where[host]


def fake_country(ip, timeout=8):
    looked.append(ip)
    return countries.get(ip, (None, None))


real_country = panel.ip_country
panel.socket.gethostbyname = fake_resolve
panel.ip_country = fake_country
done = panel.refresh_game_hosts(store, catalogue, lookups=200)
hosts = {r["host"]: r for r in store.q("SELECT * FROM game_hosts")}
check("every game host in the catalogue gets a row",
      set(hosts) >= set(panel.ping_targets(catalogue)["steam"]["hosts"]), str(len(hosts)))
check("only the games, nothing else the service resolves",
      not any(h.endswith("netflix.com") or "openai" in h for h in hosts), str(sorted(hosts)[:5]))
check("a host that resolved is located",
      hosts[STEAM_A]["ip"] == "104.90.1.1"
      and hosts[STEAM_A]["country"] == "DE", str(dict(hosts[STEAM_A])))
check("with who owns the address", hosts[STEAM_A]["org"] == "Akamai")
check("and it says which game it belongs to",
      hosts[STEAM_A]["service"] == "steam"
      and hosts[STEAM_A]["label"], str(dict(hosts[STEAM_A])))
check("a host that does not resolve is left blank, not guessed",
      all(hosts[h]["ip"] is None for h in hosts if h not in where), str(done))
check("and nobody is asked about an address that was never found",
      set(looked) and set(looked) <= set(where.values()), str(looked))

looked.clear()
panel.refresh_game_hosts(store, catalogue, lookups=200)
check("a second pass asks nothing again - the answers are kept", looked == [], str(looked))
store.run("UPDATE game_hosts SET at = ? WHERE host = ?",
          ((datetime.now(timezone.utc) - timedelta(hours=30)).isoformat(timespec="seconds"),
           STEAM_A))
where[STEAM_A] = "1.2.3.4"
panel.refresh_game_hosts(store, catalogue, lookups=200)
check("an address that moved is looked up again", looked == ["1.2.3.4"], str(looked))
check("and the new country replaces the old",
      store.one("SELECT * FROM game_hosts WHERE host = ?", (STEAM_A,))["country"] == "SG")

store.run("UPDATE game_hosts SET at = '1970-01-01T00:00:00+00:00'")
looked.clear()
panel.refresh_game_hosts(store, catalogue, lookups=1)
check("a pass only asks about a few - a burst is a good way to be refused",
      len(looked) <= 1, str(looked))

counted = panel.game_countries(store)
check("the countries come back with how many hosts are in each",
      ("SG", 1, ["Steam"]) in [(c, n, g) for c, n, g in counted]
      or any(c == "SG" and n == 1 for c, n, _ in counted), str(counted))
check("the busiest country first - that is the one to buy an exit in",
      counted == sorted(counted, key=lambda x: (-x[1], x[0])), str(counted))
check("a country nothing resolved into is not in the list",
      not any(c == "IR" for c, _, _ in counted), str(counted))

print("asking where an address is")
panel.ip_country = real_country
answers = {"https://ipwho.is/%s" % "9.9.9.9": b'{"success":true,"country_code":"US","connection":{"org":"Quad9"}}',
           "http://ip-api.com/json/%s" % "8.8.4.4": b'{"status":"success","countryCode":"US","isp":"Google"}',
           "https://ipwho.is/%s" % "8.8.4.4": b'{"success":false}'}


class FakeRes:
    def __init__(self, body):
        self.body = body

    def read(self):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def fake_open(url, timeout=8):
    if url not in answers:
        raise OSError("unreachable")
    return FakeRes(answers[url])


panel.urllib.request.urlopen = fake_open
check("the first service is used when it answers", panel.ip_country("9.9.9.9") == ("US", "Quad9"))
check("the second one when it does not", panel.ip_country("8.8.4.4") == ("US", "Google"))
check("and nothing is invented when neither answers", panel.ip_country("1.1.1.1") == (None, None))

# ---------------------------------------------------------------- the panel
print("the dashboard the operator reads")
admin.DB = db
admin.CFG = {"ADMIN_PATH": "p"}
admin.STORE = admin.Store(db)
store.run("INSERT INTO users (phone, first_name, created_at, status)"
          " VALUES ('09120000001', 'رضا', ?, 'active')", (panel.now(),))
store.run("INSERT INTO users (phone, first_name, created_at, status, exit_id)"
          " VALUES ('09120000002', 'سارا', ?, 'active', 2)", (panel.now(),))
store.run("INSERT INTO ips (user_id, ip, added_at) VALUES (1, '2.185.4.7', ?)", (panel.now(),))
store.run("INSERT INTO ips (user_id, ip, added_at) VALUES (2, '91.98.30.40', ?)", (panel.now(),))
store.run("INSERT INTO exits (id, name, ip, active, created_at)"
          " VALUES (2, 'آلمان', '203.0.113.2', 1, ?)", (panel.now(),))
store.set_setting("main_exit_name", "هلند")
store.run("DELETE FROM client_paths")
store.note_client_rtt(RELAY, {"2.185.4.7": {"ms": 36.5, "conns": 3},
                              "91.98.30.40": {"ms": 112.2, "conns": 1}})
store.set_setting("relay_exit_pings", json.dumps(
    {RELAY: {"at": panel.now(), "exits": {"0": {"ms": 60.0}, "2": {"ms": 25.0}}}}))

legs = admin.exit_legs()
check("the relay's own legs are read from what it reported",
      legs == {"0": 60.0, "2": 25.0}, str(legs))
check("a customer who picked an exit is shown on it",
      admin.effective_exit(2, legs, {"0": "هلند", "2": "آلمان"}) == "2")
check("one who picked nothing is on the fastest measured",
      admin.effective_exit(None, legs, {"0": "هلند", "2": "آلمان"}) == "2")
check("and on the main exit when nothing has been measured",
      admin.effective_exit(None, {}, {"0": "هلند", "2": "آلمان"}) == "0")
check("an exit that was turned off does not keep its customers",
      admin.effective_exit(7, legs, {"0": "هلند", "2": "آلمان"}) == "2")

stale = json.dumps({RELAY: {"at": (datetime.now(timezone.utc) - timedelta(hours=2))
                            .isoformat(timespec="seconds"),
                            "exits": {"0": {"ms": 60.0}}}})
store.set_setting("relay_exit_pings", stale)
check("an hours-old round is not passed off as current", admin.exit_legs() == {})
store.set_setting("relay_exit_pings", json.dumps(
    {RELAY: {"at": panel.now(), "exits": {"0": {"ms": 60.0}, "2": {"ms": 25.0}}}}))


class Mon:
    pass


Mon.monitor = admin.Admin.monitor
page = Mon().monitor()
check("the page counts who is connected", "مشتری‌های فعال (2)" in page, page[:200])
check("it names the customer, not just the address", "رضا" in page and "سارا" in page)
check("it shows each address", "2.185.4.7" in page and "91.98.30.40" in page)
check("their distance from the relay", "37 ms" in page or "36 ms" in page, page[:400])
check("the leg on to their exit", "25 ms" in page)
check("and the two added up - what a game's login feels",
      "62 ms" in page or "61 ms" in page, "sum missing")
check("which relay each is on", RELAY in page)
check("the exit each one takes, by name", "آلمان" in page and "هلند" in page)
check("it says plainly this is not an in-game ping",
      "پینگ بازی" in page and "از سرویس رد نمی‌شود" in page)
check("the exits are listed with their latency", "خروجی‌ها" in page)
check("the games' countries are grouped", "SG" in page and "سرورهای بازی‌ها کجا هستند" in page)
check("with the games in each", "Steam" in page)
check("and the hosts one by one", STEAM_A in page)
check("nothing is left unescaped", "<script" not in page)

store.run("DELETE FROM client_paths")
empty = Mon().monitor()
check("an empty board says so rather than showing a bare table",
      "الان کسی وصل نیست" in empty, empty[:200])
check("the page is reachable from the menu",
      "/p/monitor" in admin.page("x", "y", admin.CFG, "monitor"))
check("and the menu marks it while you are on it",
      "/p/monitor' class='on'" in admin.page("x", "y", admin.CFG, "monitor"),
      "not marked")

print("the exit refreshes it on its own")
src = open(os.path.join(HERE, "..", "templates", "smartdns-panel"), encoding="utf-8").read()
check("a thread keeps the game hosts fresh",
      "threading.Thread(target=watch_games" in src, "watch_games not started")
check("and it is a slow loop, not a burst", "time.sleep(900)" in src)

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d check(s) failed:" % len(fails))
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("all monitoring checks passed")
