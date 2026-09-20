#!/usr/bin/env python3
"""Game pings: what the relay measures, what the exit keeps, what the bot shows.

A fake DNS server and a real listening socket on 127.0.0.1 stand in for the
public resolvers and the game servers, so the relay's own resolving and timing
are what is exercised. Then the exit's storage, and the bot's two views.
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
# Everything here talks to servers of its own on 127.0.0.1; a system proxy must
# not be asked to carry any of it.
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
bot = load("smartdns-bot", "bot")
bot.P = panel
ROOT = os.path.join(HERE, "..")
tmp = tempfile.mkdtemp()
RELAY = "5.9.10.11"

print("what gets pinged")
catalogue = json.load(open(os.path.join(ROOT, "domains", "services.json"), encoding="utf-8"))["services"]
targets = panel.ping_targets(catalogue)
check("the games are pinged", "steam" in targets and "playstation" in targets and "xbox" in targets)
check("nothing that is not a game",
      not {"netflix", "openai", "bypass", "github"} & set(targets), str(sorted(targets)))
check("a few hosts per game",
      all(1 <= len(v["hosts"]) <= panel.PING_HOSTS_PER_GAME for v in targets.values()))
routed = {l.strip() for l in open(os.path.join(ROOT, "domains", "domains.txt"), encoding="utf-8")
          if l.strip() and not l.startswith("#")}
check("every host comes from the relay's own DNS list", all(
    h in routed or any(h.endswith("." + d) for d in routed)
    for v in targets.values() for h in v["hosts"]))
check("with each game's catalogue name", targets["steam"]["label"] == "Steam")
src = open(os.path.join(ROOT, "templates", "smartdns-panel"), encoding="utf-8").read()
check("the sync API hands the list to the relays", '"ping_targets": ping_targets(CATALOGUE)' in src)
check("and keeps what comes back", "self.store.note_pings(self.client_address[0]" in src)

print("the relay resolves names itself")
dns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
dns.bind(("127.0.0.1", 0))
ANSWERS = {"game.test": "127.0.0.1", "blocked.test": "10.10.34.35"}


def serve_dns():
    while True:
        try:
            data, addr = dns.recvfrom(512)
        except OSError:
            return
        pos, labels = 12, []
        while data[pos]:
            n = data[pos]
            labels.append(data[pos + 1:pos + 1 + n].decode())
            pos += n + 1
        name, question = ".".join(labels), data[12:pos + 5]
        if name == "cname.test":
            target = b"\x04game\x04test\x00"
            body = (b"\xc0\x0c" + struct.pack(">HHIH", 5, 1, 60, len(target)) + target +
                    b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + socket.inet_aton("127.0.0.1"))
            dns.sendto(data[:2] + struct.pack(">HHHHH", 0x8180, 1, 2, 0, 0) + question + body, addr)
        elif name in ANSWERS:
            body = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + socket.inet_aton(ANSWERS[name])
            dns.sendto(data[:2] + struct.pack(">HHHHH", 0x8180, 1, 1, 0, 0) + question + body, addr)
        else:
            dns.sendto(data[:2] + struct.pack(">HHHHH", 0x8183, 1, 0, 0, 0) + question, addr)


threading.Thread(target=serve_dns, daemon=True).start()
sync.DNS_PORT = dns.getsockname()[1]
sync.PING_RESOLVERS = ("127.0.0.1",)
sync.PING_TIMEOUT = 1.0
check("a name is answered by the resolver it asks", sync.resolve_a("game.test") == ("127.0.0.1", "ok"))
check("an answer behind a CNAME is followed", sync.resolve_a("cname.test")[0] == "127.0.0.1")
check("Iran's block address is recognised", sync.resolve_a("blocked.test") == ("10.10.34.35", "filtered"))
check("a name with no address says so", sync.resolve_a("nowhere.test") == (None, "no-dns"))
check("a name it cannot even spell says so", sync.resolve_a("badé.test") == (None, "no-dns"))
ssrc = open(os.path.join(ROOT, "templates", "smartdns-sync"), encoding="utf-8").read()
check("public resolvers, never this relay's dnsmasq", 'PING_RESOLVERS = ("1.1.1.1", "8.8.8.8")' in ssrc)

print("and times the servers")
srv = socket.socket()
srv.bind(("127.0.0.1", 0))
srv.listen(64)


def accept():
    while True:
        try:
            c, _ = srv.accept()
            c.close()
        except OSError:
            return


threading.Thread(target=accept, daemon=True).start()
closed = socket.socket()
closed.bind(("127.0.0.1", 0))
closed_port = closed.getsockname()[1]
closed.close()
sync.PING_PORTS = (closed_port, srv.getsockname()[1])
ms, loss = sync.time_host("127.0.0.1")
check("a server that answers is timed, on the first port that answers",
      ms is not None and 0 <= ms < 1000 and loss == 0.0, "%r %r" % (ms, loss))
sync.PING_PORTS = (closed_port,)
check("one that answers on no port is all loss", sync.time_host("127.0.0.1") == (None, 1.0))
sync.PING_PORTS = (closed_port, srv.getsockname()[1])
res = sync.ping_round({"steam": {"label": "Steam",
                                 "hosts": ["game.test", "blocked.test", "nowhere.test"]}})
hosts = {h["host"]: h for h in res["steam"]["hosts"]}
check("a round reports every host", set(hosts) == {"game.test", "blocked.test", "nowhere.test"})
check("a reachable one with its time", hosts["game.test"]["state"] == "ok"
      and hosts["game.test"]["ms"] is not None and hosts["game.test"]["ip"] == "127.0.0.1")
check("a filtered one, never connected to",
      hosts["blocked.test"]["state"] == "filtered" and hosts["blocked.test"]["ms"] is None)
check("one with no address", hosts["nowhere.test"]["state"] == "no-dns")
check("under the game's name", res["steam"]["label"] == "Steam")

print("the relay reports each round once")
sync.note_ping_targets({"steam": {"label": "Steam", "hosts": ["game.test"]}, "junk": "x"})
check("targets from the exit are kept", "steam" in sync.PING_TARGETS and "junk" not in sync.PING_TARGETS)
with sync.PING_LOCK:
    sync.PINGS.update(res)
check("a finished round is handed to the sync", sync.take_pings() == res)
check("and only once", sync.take_pings() == {})
check("it goes up with the sync report", 'report["pings"] = pings' in ssrc)
check("and the pinging runs beside the sync", "target=ping_loop" in ssrc)

print("and through each exit, the way a customer goes")
# A TLS server on loopback stands in for an exit's proxy: what time_through
# measures is a handshake completing, whatever is behind it.
crt, key = os.path.join(tmp, "t.crt"), os.path.join(tmp, "t.key")
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                "-subj", "/CN=exit.test", "-keyout", key, "-out", crt],
               capture_output=True, timeout=120)
tls_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls_ctx.load_cert_chain(crt, key)
tls_srv = socket.socket()
tls_srv.bind(("127.0.0.1", 0))
tls_srv.listen(32)
EXIT_ENDPOINT = ("127.0.0.1", tls_srv.getsockname()[1])


def serve_tls():
    while True:
        try:
            raw, _ = tls_srv.accept()
        except OSError:
            return
        try:
            tls_ctx.wrap_socket(raw, server_side=True).close()
        except OSError:
            pass


threading.Thread(target=serve_tls, daemon=True).start()
sync.THROUGH_TIMEOUT = 5.0
ms, state = sync.time_through(EXIT_ENDPOINT, "playstation.com")
check("a game answering through an exit is timed", state == "ok" and ms is not None and ms < 5000,
      "%r %r" % (ms, state))
check("an exit that does not answer at all says so",
      sync.time_through(("127.0.0.1", closed_port), "playstation.com") == (None, "no-exit"))
check("an exit that answers but cannot reach the game says so",
      sync.time_through(("127.0.0.1", srv.getsockname()[1]), "playstation.com")[1] == "no-answer")

routes = {"0": EXIT_ENDPOINT, "3": EXIT_ENDPOINT}
through = sync.ping_through_exits(
    {"steam": {"label": "Steam", "hosts": ["steampowered.com", "steamcommunity.com"]},
     "xbox": {"label": "Xbox", "hosts": ["xbox.com"]}}, routes)
check("every exit is measured", set(through) == {"0", "3"})
check("one host per game, not all of them",
      set(through["0"]) == {"steam", "xbox"} and through["0"]["steam"]["ms"] is not None)
check("under the game's name", through["3"]["xbox"]["label"] == "Xbox")

sync.CFG = {"EXIT_IP": "5.10.20.30", "TUNNEL": "off"}
r = sync.note_exit_routes({"3": {"name": "de", "ip": "91.107.1.2"}}, {})
check("without tunnels, each exit is reached at its own address",
      r == {"0": ("5.10.20.30", 443), "3": ("91.107.1.2", 443)}, str(r))
r = sync.note_exit_routes({"3": {"name": "de", "ip": "91.107.1.2"}}, {"3": (18500, 18501)})
check("a tunnelled exit is measured through its tunnel", r["3"] == ("127.0.0.1", 18500))
sync.CFG["TUNNEL"] = "backpack"
r = sync.note_exit_routes({}, {})
check("and so is the relay's own exit, when the pair has one", r["0"] == ("127.0.0.1", 18443))
sync.CFG["TUNNEL"] = "off"
with sync.PING_LOCK:
    sync.EXIT_GAME_PINGS.update(through)
check("a finished round goes up with the sync once", sync.take_exit_game_pings() == through
      and sync.take_exit_game_pings() == {})
check("it is reported", 'report["exit_game_pings"] = through' in ssrc)
check("and measured against the endpoints nginx was pointed at",
      "note_exit_routes(exits, tunnels)" in ssrc)

print("the exit keeps what each relay measured")
store = panel.Store(os.path.join(tmp, "panel.db"))
store.note_pings("5.9.10.11", res)
kept = panel.relay_pings(store)
check("it is kept", kept["5.9.10.11"]["games"]["steam"]["label"] == "Steam")
check("with when", panel.parse_ts(kept["5.9.10.11"]["at"]) is not None)
store.note_pings("5.9.10.11", {"Bad Key!": {}, "steam": {"label": "S" * 100, "hosts": [
    {"host": "x", "ip": "not-an-ip", "ms": 1e9, "loss": 5}, "junk"]}})
games = panel.relay_pings(store)["5.9.10.11"]["games"]
check("a key that is not a key is dropped", "Bad Key!" not in games)
check("a bogus address, time or loss is not kept", games["steam"]["hosts"] ==
      [{"host": "x", "ip": "", "ms": None, "loss": 1.0, "state": ""}], str(games["steam"]["hosts"]))
check("labels are kept short", len(games["steam"]["label"]) <= 40)
store.note_pings("5.9.10.12", res)
check("each relay keeps its own", set(panel.relay_pings(store)) == {"5.9.10.11", "5.9.10.12"})
store.note_pings("5.9.10.12", "nonsense")
check("nonsense changes nothing", set(panel.relay_pings(store)) == {"5.9.10.11", "5.9.10.12"})

print("what the exit keeps of them")
store.note_exit_game_pings(RELAY, {
    "0": {"steam": {"label": "Steam", "ms": 120.0, "state": "ok"},
          "xbox": {"label": "Xbox", "ms": None, "state": "no-answer"}},
    "3": {"steam": {"label": "Steam", "ms": 44.0, "state": "ok"}},
    "bad key": {"steam": {}}, "9": "junk"})
games, seen = panel.games_through_exit(store, 3)
check("what a game answers like through one exit", games["steam"]["ms"] == 44.0)
check("with when it was measured", seen is not None)
check("rubbish is dropped", panel.games_through_exit(store, "bad key")[0] == {})
main_games, _ = panel.games_through_exit(store, 0)
check("the main exit is kept apart", main_games["xbox"]["state"] == "no-answer")
old = panel.exit_game_pings(store)
old[RELAY]["at"] = "2000-01-01T00:00:00+00:00"
store.set_setting("relay_exit_game_pings", json.dumps(old))
check("an old round counts for nothing", panel.games_through_exit(store, 3) == ({}, None))
print("what the bot shows")


class FakeTelegram:
    def __init__(self):
        self.calls = []

    def call(self, method, **params):
        self.calls.append((method, params))
        return {"message_id": 1}


tg = FakeTelegram()
b = bot.Bot(store, tg, relays=("5.9.10.11",))
counter = [0]


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
    return (msgs[-1].get("text") or "") if msgs else ""


MEASURED = {"5.9.10.11": {"at": panel.now(), "games": {
    "xbox": {"label": "Xbox", "hosts": [
        {"host": "xboxlive.com", "ip": "1.2.3.4", "ms": 182.4, "loss": 0.0, "state": "ok"}]},
    "steam": {"label": "Steam", "hosts": [
        {"host": "steampowered.com", "ip": "5.6.7.8", "ms": 46.0, "loss": 0.33, "state": "ok"},
        {"host": "steamcontent.com", "ip": "", "ms": None, "loss": 1.0, "state": "no-answer"}]},
    "riot": {"label": "Riot Games", "hosts": [
        {"host": "riotgames.com", "ip": "10.10.34.35", "ms": None, "loss": 1.0, "state": "filtered"}]},
    "ea": {"label": "EA", "hosts": [
        {"host": "ea.com", "ip": "9.9.9.9", "ms": None, "loss": 1.0, "state": "no-answer"}]}}}}
store.set_setting("relay_pings", json.dumps(MEASURED))
# No round through an exit yet: what a customer sees until one has run is the
# relay's own numbers, which is what the checks below are about.
store.set_setting("relay_exit_game_pings", "")
CUSTOMER, ADMIN = 8001, 8002
update(CUSTOMER, "/start")
check("customers have a ping button", bot.MENU_PING in json.dumps(b.menu(CUSTOMER), ensure_ascii=False))
update(CUSTOMER, bot.MENU_PING)
text = last(CUSTOMER)
check("every game is listed", all(x in text for x in ("Steam", "Xbox", "Riot Games", "EA")), text)
check("a good ping is green, with its fastest host", "🟢 Steam — 46 ms" in text, text)
check("a slow one is red", "🔴 Xbox — 182 ms" in text, text)
check("the fastest comes first", text.index("Steam") < text.index("Xbox"))
check("a filtered game is said to be", "🚫 Riot Games" in text)
check("a silent one is said to be", "⚫ EA" in text)
check("games that answer come before those that do not", text.index("Xbox") < text.index("Riot Games"))
check("it says how fresh it is", "همین حالا" in text)
check("and whose ping it is", "سرور ما در ایران" in text)
check("customers are shown no addresses", "5.6.7.8" not in text and "steampowered.com" not in text)
old = dict(MEASURED)
old["5.9.10.11"] = dict(MEASURED["5.9.10.11"], at=bot.ago(minutes=40))
store.set_setting("relay_pings", json.dumps(old))
update(CUSTOMER, bot.MENU_PING)
check("an old measurement says it is old", "قدیمی" in last(CUSTOMER))
store.set_setting("relay_pings", "")
update(CUSTOMER, bot.MENU_PING)
check("before any measurement, it says to wait", "هنوز" in last(CUSTOMER))

print("and once a round through their exit has run")
store.set_setting("relay_pings", json.dumps(MEASURED))
store.note_exit_game_pings(RELAY, {
    "0": {"steam": {"label": "Steam", "ms": 120.0, "state": "ok"},
          "xbox": {"label": "Xbox", "ms": 61.0, "state": "ok"},
          "riot": {"label": "Riot Games", "ms": None, "state": "no-answer"}}})
update(CUSTOMER, bot.MENU_PING)
text = last(CUSTOMER)
check("the customer sees it through their own exit, named",
      "از راه" in text and panel.main_exit_name(store) in text, text)
check("with the numbers measured through it, not the relay's own",
      "🟡 Steam — 120 ms" in text and "46 ms" not in text, text)
check("the fastest through that exit comes first", text.index("Xbox") < text.index("Steam"))
check("a game that did not answer through it is said to be", "⚫ Riot Games" in text)
check("and it says whose path this is", "ترافیک شما" in text)


store.set_setting("relay_pings", json.dumps(MEASURED))
store.set_setting("bot_admins", str(ADMIN))
update(ADMIN, bot.MENU_ADMIN)
admin_menu = [p for m, p in tg.calls if m == "sendMessage" and p.get("chat_id") == ADMIN][-1]
check("the admin menu has it", any(x.get("callback_data") == "a:pg"
                                   for row in admin_menu["reply_markup"]["inline_keyboard"] for x in row))
before = len([p for m, p in tg.calls if m == "sendMessage" and p.get("chat_id") == ADMIN])
press(ADMIN, "a:pg")
sent = [p.get("text") or "" for m, p in tg.calls
        if m == "sendMessage" and p.get("chat_id") == ADMIN][before:]
check("the admin gets the direct view, then one message per exit", len(sent) >= 2, str(len(sent)))
direct = sent[0]
check("the admin sees every host and its address",
      "steampowered.com" in direct and "(5.6.7.8)" in direct, direct)
check("with its loss", "33٪" in direct)
check("and which relay measured", "5.9.10.11" in direct)
check("hosts Iran filters are named", "فیلتر" in direct)
check("and then what each game answers through each exit",
      any("از راه" in m and "120 ms" in m for m in sent[1:]), str(sent[1:])[:200])
press(CUSTOMER, "a:pg")
check("a customer cannot open the admin view", "steampowered.com" not in last(CUSTOMER))

dns.close()
srv.close()
shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
