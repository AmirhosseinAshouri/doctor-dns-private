#!/usr/bin/env python3
"""The Telegram bot, the mini app and online payment, offline.

A fake Telegram records what the bot sends and serves what it downloads, the
database is a throwaway, and Zibal and the exit's API are stood in for on the
relay's side. What is checked is the decisions: who gets an account and who
gets the admin menu, what a plan does to an account, that a receipt reaches the
admins and an approval applies its plan once, that a mini app's launch data has
to be Telegram's, and that a payment is recorded only against the order it was
made for.
"""
import base64
import contextlib
import hashlib
import hmac
import http.server
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import urllib.parse
from datetime import datetime, timezone

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []

# These tests talk to a server of their own on 127.0.0.1. A system-wide proxy -
# macOS settings, or http_proxy in the environment - would have urllib send even
# those requests to the proxy, which answers a local port it knows nothing about
# with 503. Nothing here should ever leave the machine, so proxying is off.
os.environ["no_proxy"] = os.environ["NO_PROXY"] = "*"


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
admin = load("smartdns-admin", "admin")
sync = load("smartdns-sync", "sync")
bot = load("smartdns-bot", "bot")
bot.P = panel

tmp = tempfile.mkdtemp()
db_path = os.path.join(tmp, "panel.db")
store = panel.Store(db_path)
admin.DB = db_path
admin.CFG = {"ADMIN_PATH": "p"}
admin.STORE = admin.Store(db_path)

TOKEN = "123456789:" + "A" * 35
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM"
    "IQAAAABJRU5ErkJggg==")
RELAY_IP = "5.9.10.11"
CUSTOMER, ADMIN, STRANGER, NEWBIE, WAITING = 5001, 7001, 9001, 5002, 5003


class FakeTelegram:
    def __init__(self):
        self.calls = []
        self.files = {}

    def call(self, method, **params):
        self.calls.append((method, params))
        return {"message_id": len(self.calls)}

    def upload(self, method, field, filename, blob, ctype, **params):
        self.calls.append((method, dict(params, _file=filename, _size=len(blob))))
        return {"message_id": len(self.calls)}

    def download(self, file_id, limit):
        blob = self.files[file_id]
        if len(blob) > limit:
            raise bot.TelegramError("too big", code="too_big")
        return blob

    def sent(self, chat, method="sendMessage"):
        return [p for m, p in self.calls if m == method and str(p.get("chat_id")) == str(chat)]


tg = FakeTelegram()
b = bot.Bot(store, tg, relays=(RELAY_IP,))
counter = [0]


def update(chat, text=None, **extra):
    counter[0] += 1
    msg = {"message_id": counter[0], "chat": {"id": chat, "type": "private"},
           "from": {"id": chat, "first_name": "مشتری %d" % chat}}
    if text is not None:
        msg["text"] = text
    msg.update(extra)
    b.handle({"update_id": counter[0], "message": msg})


def press(chat, data):
    counter[0] += 1
    b.handle({"update_id": counter[0], "callback_query": {
        "id": "cq%d" % counter[0], "data": data, "from": {"id": chat, "first_name": "x"},
        "message": {"message_id": 1, "chat": {"id": chat, "type": "private"}}}})


def last(chat):
    msgs = tg.sent(chat)
    return msgs[-1] if msgs else {}


def buttons(p):
    return [x for row in (p.get("reply_markup") or {}).get("inline_keyboard", []) for x in row]


def user_of(chat):
    return store.user_by_telegram(chat)


def outbox(chat):
    return [r["text"] for r in store.q("SELECT text FROM outbox WHERE chat_id = ? ORDER BY id",
                                       (chat,))]


print("starting the bot opens an account")
update(CUSTOMER, "/start")
u = user_of(CUSTOMER)
check("an account is opened", u is not None)
check("it starts pending, with nothing", u and u["status"] == "pending" and u["quota_bytes"] == 0)
check("the Telegram handle is not taken as a login name", u and u["username"] is None)
check("the customer is greeted with the menu", "keyboard" in (last(CUSTOMER).get("reply_markup") or {}))
check("with no admin button", bot.MENU_ADMIN not in json.dumps(b.menu(CUSTOMER), ensure_ascii=False))
update(CUSTOMER, "/start")
check("starting again opens no second account",
      store.one("SELECT count(*) c FROM users WHERE telegram_id = ?", (CUSTOMER,))["c"] == 1)
counter[0] += 1
b.handle({"update_id": counter[0], "message": {"message_id": 1, "text": "/start",
          "chat": {"id": -100, "type": "group"}, "from": {"id": 6001, "first_name": "g"}}})
check("a group chat opens nothing", user_of(6001) is None)

print("becoming the bot's admin")
update(ADMIN, "/start")
update(ADMIN, "/admin 00000000")
check("with no code issued, nothing works", not b.is_admin(ADMIN))
code = panel.new_admin_code(store)
update(STRANGER, "/admin deadbeef")
check("a wrong code is refused", not b.is_admin(STRANGER))
update(ADMIN, "/admin " + code)
check("the right code makes an admin", b.is_admin(ADMIN))
check("the code is used up", store.setting("bot_admin_code") == "")
update(STRANGER, "/admin " + code)
check("and does not work a second time", not b.is_admin(STRANGER))
store.set_setting("bot_admin_code", "abcd1234|2000-01-01T00:00:00+00:00")
update(STRANGER, "/admin abcd1234")
check("an expired code is refused", not b.is_admin(STRANGER))
for _ in range(6):
    update(STRANGER, "/admin ffffffff")
check("guessing is throttled", "تلاش زیاد" in last(STRANGER).get("text", ""))
check("the admin gets the admin button", bot.MENU_ADMIN in json.dumps(b.menu(ADMIN), ensure_ascii=False))
press(STRANGER, "a:st")
check("a customer pressing an admin button is turned away",
      "فقط برای مدیر" in last(STRANGER).get("text", ""))
update(NEWBIE, "/start")
check("the admins hear of a new customer", any("مشتری تازه" in t for t in outbox(ADMIN)))

print("plans")
for text, ok in [("x | 0 | 0 | 0 | 1000", True), ("x | 1 | 1.5 | 0 | 5000", False),
                 ("x | -1 | 30 | 0 | 5000", False), ("x | 1 | 30 | 0 | 500", False),
                 ("x | 1 | 30 | 0", False), (" | 1 | 30 | 0 | 5000", False)]:
    check("parse_plan %r is %s" % (text, "accepted" if ok else "refused"),
          bool(bot.parse_plan(text)[0]) == ok)
press(ADMIN, "a:pn")
update(ADMIN, "نیم‌ساله | abc | 30 | 0 | 150000")
check("a plan with a bad number is refused", store.one("SELECT count(*) c FROM plans")["c"] == 0)
update(ADMIN, "یک‌ماهه ۵۰ گیگ | ۵۰ | ۳۰ | ۲٫۵ | ۱۵۰٬۰۰۰")
plan = store.one("SELECT * FROM plans")
check("a plan typed in Persian digits is saved", plan is not None, last(ADMIN).get("text", ""))
check("with every number right", plan is not None and plan["quota_gb"] == 50 and plan["days"] == 30
      and plan["speed_mbps"] == 2.5 and plan["price"] == 150000, str(dict(plan)) if plan else "")
pid = plan["id"]

print("paying card to card")
update(CUSTOMER, bot.MENU_BUY)
check("the customer sees the plan", any("plan:%d" % pid == x["callback_data"] for x in buttons(last(CUSTOMER))))
press(CUSTOMER, "plan:%d" % pid)
check("with no way to pay set up, they are told", "روش پرداختی" in last(CUSTOMER).get("text", ""))
press(ADMIN, "a:pc")
update(ADMIN, "6037-9912-3456-789 | علی")
check("a card number that is not 16 digits is refused", store.setting("card_number") == "")
update(ADMIN, "۶۰۳۷ ۹۹۱۲ ۳۴۵۶ ۷۸۹۰ | علی رضایی")
check("the card is saved as plain digits", store.setting("card_number") == "6037991234567890")
check("with its holder", store.setting("card_holder") == "علی رضایی")
press(CUSTOMER, "plan:%d" % pid)
labels = [x["text"] for x in buttons(last(CUSTOMER))]
check("card to card is offered", any("کارت" in l for l in labels))
check("online payment is not, with no merchant and no relay", not any("زیبال" in l for l in labels))
press(CUSTOMER, "card:%d" % pid)
check("the card number is shown, grouped", "6037 9912 3456 7890" in last(CUSTOMER).get("text", ""))
check("with the price", "150,000" in last(CUSTOMER).get("text", ""))
update(CUSTOMER, "سلام")
check("text instead of a receipt is asked for again", "عکس رسید" in last(CUSTOMER).get("text", ""))
update(CUSTOMER, document={"file_id": "page", "mime_type": "text/html"})
check("an html file is not a receipt", store.one("SELECT count(*) c FROM transactions")["c"] == 0)
tg.files["big"] = b"x" * (panel.MAX_RECEIPT + 1)
update(CUSTOMER, photo=[{"file_id": "big"}])
check("an oversized photo is refused", store.one("SELECT count(*) c FROM transactions")["c"] == 0)
tg.files["slip"] = PNG
store.run("UPDATE users SET used_bytes = 12345 WHERE telegram_id = ?", (CUSTOMER,))
update(CUSTOMER, photo=[{"file_id": "thumb"}, {"file_id": "slip"}])
t = store.one("SELECT * FROM transactions WHERE kind = 'card'")
check("the receipt is stored, pending", t is not None and t["status"] == "pending")
check("the largest size of the photo is the one kept", t is not None and bytes(t["receipt_blob"]) == PNG)
check("against the plan and its price", t is not None and t["plan_id"] == pid and t["amount"] == 150000)
photos = tg.sent(ADMIN, "sendPhoto")
check("the admin is shown it at once", len(photos) == 1, str(tg.calls[-3:]))
check("with approve and reject buttons",
      bool(photos) and ("a:ok:%d" % t["id"]) in json.dumps(photos[0]["reply_markup"]))
b.forward_receipts()
check("and only once", len(tg.sent(ADMIN, "sendPhoto")) == 1)
check("the customer is no longer asked for a receipt", CUSTOMER not in b.state)

print("approving a receipt applies its plan")
press(CUSTOMER, "a:ok:%d" % t["id"])
check("a customer cannot approve their own",
      store.one("SELECT status FROM transactions WHERE id = ?", (t["id"],))["status"] == "pending")
press(ADMIN, "a:ok:%d" % t["id"])
t = store.one("SELECT * FROM transactions WHERE id = ?", (t["id"],))
u = user_of(CUSTOMER)
check("the receipt is approved", t["status"] == "approved")
check("its photo goes with the decision", t["receipt_blob"] is None)
check("carried out once", t["settled"] == 1)
check("the account is active", u["status"] == "active")
check("with the plan's allowance", u["quota_bytes"] == 50 * panel.GB)
check("and its speed", u["speed_kbps"] == 2500)
check("usage starts again", u["used_bytes"] == 0)
due = panel.parse_ts(u["expires_at"])
check("and the period starts today",
      due is not None and 29 <= (due - datetime.now(timezone.utc)).days <= 30, str(u["expires_at"]))
check("the customer is told", any("«یک‌ماهه ۵۰ گیگ»" in x and "فعال" in x for x in outbox(CUSTOMER)))
press(ADMIN, "a:ok:%d" % t["id"])
check("pressing again does nothing twice", "قبلاً بررسی" in last(ADMIN).get("text", ""))

print("a receipt approved in the admin panel")


class Form:
    def redirect(self, where, headers=None):
        return where

    def one(self, params, key, default=""):
        return (params.get(key) or [default])[0]


form = Form()
nu = user_of(NEWBIE)
tid = store.run(
    "INSERT INTO transactions (user_id, amount, kind, plan_id, receipt_blob, receipt_type,"
    " status, created_at, admin_notified) VALUES (?, 150000, 'card', ?, ?, 'image/png',"
    " 'pending', ?, 0)", (nu["id"], pid, PNG, panel.now())).lastrowid
where = admin.Admin.action(form, "receipt-decide", {"id": [str(tid)], "to": ["approved"]})
check("the web panel says the plan is on its way", "یک‌ماهه" in where, where)
check("the web panel applies nothing itself", user_of(NEWBIE)["status"] == "pending")
panel.enforce_quotas(store)
check("the next quota pass applies it",
      user_of(NEWBIE)["status"] == "active" and user_of(NEWBIE)["quota_bytes"] == 50 * panel.GB)
cols = {r[1]: r for r in store.db.execute("PRAGMA table_info(transactions)")}
check("rows from before the bot count as settled", str(cols["settled"][4]) == "1")
store.run("INSERT INTO transactions (user_id, amount, kind, status, created_at, decided_at)"
          " VALUES (?, 1, 'card', 'approved', ?, ?)", (nu["id"], panel.now(), panel.now()))
before = len(outbox(NEWBIE))
panel.settle_transactions(store)
check("so an old approval is not carried out again", len(outbox(NEWBIE)) == before)
web = store.create_web_user("webbuyer", "وب", "a-password-1")
session = store.open_session(web["id"])


class Api:
    def __init__(self, store):
        self.store = store


for name in ("do_user_receipt", "_session_user", "do_tg_claim", "_order", "do_pay_order",
             "do_pay_started", "do_pay_verified", "do_claim_register"):
    setattr(Api, name, getattr(panel.API, name))
api = Api(store)
api.do_user_receipt({"session": session, "content_type": "image/png",
                     "data": base64.b64encode(PNG).decode()})
b.forward_receipts()
check("a receipt sent on the web reaches the bot's admins too",
      any("از پنل وب" in (p.get("caption") or "") for p in tg.sent(ADMIN, "sendPhoto")))
check("the web's own address registration still works",
      api.do_claim_register(web["id"], "5.77.1.1").get("ok"))

print("quota messages reach Telegram")
cid = user_of(CUSTOMER)["id"]
store.run("UPDATE users SET used_bytes = ? WHERE id = ?", (int(47.6 * panel.GB), cid))
before = len(outbox(CUSTOMER))
panel.enforce_quotas(store)
new = outbox(CUSTOMER)[before:]
check("crossing 80% and 95% in one pass is one message", len(new) == 1 and "95" in new[0], str(new))
panel.enforce_quotas(store)
check("and it is not repeated", len(outbox(CUSTOMER)) == before + 1)
store.run("UPDATE users SET used_bytes = ? WHERE id = ?", (51 * panel.GB, cid))
panel.enforce_quotas(store)
check("running out is told", "تمام شد" in outbox(CUSTOMER)[-1] and user_of(CUSTOMER)["status"] == "over_quota")
store.run("UPDATE users SET status = 'active', quota_bytes = 1, used_bytes = 5 WHERE id = ?", (web["id"],))
total = store.one("SELECT count(*) c FROM outbox")["c"]
panel.enforce_quotas(store)
check("an account with no Telegram queues nothing",
      store.one("SELECT count(*) c FROM outbox")["c"] == total)

print("registering an address in the bot")
update(CUSTOMER, bot.MENU_IP)
check("with no relay domain yet, there is no mini app button",
      not any("web_app" in x for x in buttons(last(CUSTOMER))))
press(CUSTOMER, "typeip")
update(CUSTOMER, "192.168.1.10")
check("a home network address is refused", not store.user_ips(cid))
update(CUSTOMER, RELAY_IP)
check("one of the service's own servers is refused", not store.user_ips(cid))
update(CUSTOMER, "۵.۱۲۳.۴۵.۶۷")
check("an address in Persian digits is registered",
      [r["ip"] for r in store.user_ips(cid)] == ["5.123.45.67"])
store.note_relay("https://relay.example.com:8443", RELAY_IP)
store.note_relay("javascript:alert(1)", "not-an-address")
check("a relay's panel address is remembered", store.setting("relay_panel") == "https://relay.example.com:8443")
check("and rubbish in its place is not", store.setting("relay_dns") == RELAY_IP)
src = open(os.path.join(HERE, "..", "templates", "smartdns-panel"), encoding="utf-8").read()
check("the sync API records it", "self.store.note_relay(" in src)
check("the relay reports it", 'report["panel"]' in open(os.path.join(
    HERE, "..", "templates", "smartdns-sync"), encoding="utf-8").read())
update(CUSTOMER, bot.MENU_IP)
apps = [x for x in buttons(last(CUSTOMER)) if "web_app" in x]
check("the mini app opens on the relay",
      bool(apps) and apps[0]["web_app"]["url"] == "https://relay.example.com:8443/tg")
update(CUSTOMER, bot.MENU_DNS)
check("the DNS address is the relay's", RELAY_IP in last(CUSTOMER).get("text", ""))

print("a mini app's launch data")


def signed(fields, token=TOKEN):
    text = "\n".join("%s=%s" % (k, fields[k]) for k in sorted(fields))
    secret = hmac.new(b"WebAppData", token.encode(), hashlib.sha256).digest()
    return urllib.parse.urlencode(dict(fields, hash=hmac.new(
        secret, text.encode(), hashlib.sha256).hexdigest()))


def launch(user_id, age=0):
    return signed({"auth_date": str(int(time.time()) - age), "query_id": "AAHdF6IQAAAAAN0XohDhrOrc",
                   "user": json.dumps({"id": user_id, "first_name": "x"})})


good = launch(CUSTOMER)
check("Telegram's own signature is accepted", (panel.telegram_init_data(TOKEN, good) or {}).get("id") == CUSTOMER)
check("another bot's is not", panel.telegram_init_data("987654321:" + "B" * 35, good) is None)
tampered = good.replace(str(CUSTOMER), str(ADMIN))
check("a changed user is not", tampered != good and panel.telegram_init_data(TOKEN, tampered) is None)
check("an old one is not", panel.telegram_init_data(TOKEN, launch(CUSTOMER, age=7200)) is None)
check("with no token set, nothing is", panel.telegram_init_data("", good) is None)
check("a repeated field is not",
      panel.telegram_init_data(TOKEN, good + "&user=" + urllib.parse.quote(json.dumps({"id": ADMIN}))) is None)
store.set_setting("bot_token", TOKEN)
res = api.do_tg_claim({"init_data": launch(CUSTOMER), "ip": "5.200.1.2"})
check("the mini app registers the address the relay saw",
      res.get("ok") and [r["ip"] for r in store.user_ips(cid)] == ["5.200.1.2"], str(res))
check("unsigned data registers nothing",
      not api.do_tg_claim({"init_data": "user=%7B%22id%22%3A5001%7D", "ip": "5.200.9.9"}).get("ok"))
check("somebody who never started the bot is told to",
      "استارت" in api.do_tg_claim({"init_data": launch(424242), "ip": "5.200.9.9"}).get("message", ""))
page = sync.tg_page("5.200.1.2")
check("the page reads the launch data from the fragment", "tgWebAppData" in page and "/tg/claim" in page)
check("and loads nothing from telegram.org, which is filtered", "telegram.org" not in page)
check("the address is escaped", "&lt;i&gt;" in sync.tg_page("<i>"))

print("paying online")
press(CUSTOMER, "zp:%d" % pid)
check("with no merchant, no order is opened",
      store.one("SELECT count(*) c FROM transactions WHERE kind = 'zibal'")["c"] == 0)
press(ADMIN, "a:pz")
update(ADMIN, "not a merchant!")
check("a malformed merchant is refused", store.setting("zibal_merchant") == "")
MERCHANT = "6b1a3c9e0f2d4a5b8c7d9e10"
update(ADMIN, MERCHANT)
check("a real one is saved", store.setting("zibal_merchant") == MERCHANT)
press(CUSTOMER, "plan:%d" % pid)
check("online payment is offered now", any("زیبال" in x["text"] for x in buttons(last(CUSTOMER))))
press(CUSTOMER, "zp:%d" % pid)
order = store.one("SELECT * FROM transactions WHERE kind = 'zibal'")
links = [x for x in buttons(last(CUSTOMER)) if x.get("url")]
check("an order is opened", order is not None and order["status"] == "started")
check("and the customer gets a link to the relay", bool(links) and order is not None and
      links[0]["url"] == "https://relay.example.com:8443/pay/" + order["pay_token"])
token = order["pay_token"]
res = api.do_pay_order({"token": token})
check("the relay is told what to charge, in toman",
      res.get("ok") and res["amount"] == 150000 and res["merchant"] == MERCHANT)
check("a made-up token gets nothing", not api.do_pay_order({"token": "x" * 32}).get("ok"))
TRACK = "3714661258"
check("the gateway's track id is recorded", api.do_pay_started({"token": token, "authority": TRACK}).get("ok"))
check("one that is not a number is not",
      not api.do_pay_started({"token": token, "authority": "A0000abc"}).get("ok"))
res = api.do_pay_verified({"token": token, "authority": "3714661259", "ref_id": "1"})
check("another payment's track id does not pay for this one", not res.get("ok") and
      store.one("SELECT status FROM transactions WHERE id = ?", (order["id"],))["status"] == "started")
res = api.do_pay_verified({"token": token, "authority": TRACK, "ref_id": "201", "card_pan": "6037**1234"})
order = store.one("SELECT * FROM transactions WHERE id = ?", (order["id"],))
check("the right one settles the order", res.get("ok") and order["status"] == "approved" and order["ref_id"] == "201")
check("and applies the plan", user_of(CUSTOMER)["status"] == "active" and user_of(CUSTOMER)["used_bytes"] == 0)
check("the admins hear of it", any("پرداخت آنلاین" in x for x in outbox(ADMIN)))
told = len(outbox(CUSTOMER))
check("recording it again is harmless", api.do_pay_verified({"token": token, "authority": TRACK}).get("ok")
      and len(outbox(CUSTOMER)) == told)
check("and a paid link cannot be paid again", api.do_pay_order({"token": token}).get("paid"))
old = "old" + "x" * 29
store.run("INSERT INTO transactions (user_id, amount, kind, plan_id, status, created_at, pay_token)"
          " VALUES (?, 150000, 'zibal', ?, 'started', '2000-01-01T00:00:00+00:00', ?)", (cid, pid, old))
check("an expired link is refused", not api.do_pay_order({"token": old}).get("ok"))
store.run("UPDATE transactions SET authority = ? WHERE pay_token = ?", ("1111111111", old))
check("but somebody coming back from the gateway with it is let in",
      api.do_pay_order({"token": old, "returning": True}).get("ok"))

print("the relay's pages")
sync.CFG = {"PANEL_DOMAIN": "relay.example.com", "SELF_IP": RELAY_IP, "PANEL_HOST": "203.0.113.1"}
routes = {"/pay-order": api.do_pay_order, "/pay-started": api.do_pay_started,
          "/pay-verified": api.do_pay_verified, "/tg-claim": api.do_tg_claim}
sync.post = lambda path, payload: routes[path](payload)
zp = []
PAID = {"result": 100, "status": 1, "amount": 1500000, "refNumber": 777,
        "cardNumber": "6037**9999", "message": "success"}
answers = {"request": {"result": 100, "trackId": 3714669999, "message": "success"},
           "verify": dict(PAID)}
real_zibal = sync.zibal


def fake_zibal(action, payload):
    zp.append((action, payload))
    return dict(answers[action])


sync.zibal = fake_zibal


def relay(method, path, body=b"", ip="5.200.1.2"):
    h = sync.UserPanel.__new__(sync.UserPanel)
    h.path, h.command, h.request_version = path, method, "HTTP/1.1"
    h.requestline = "%s %s HTTP/1.1" % (method, path)
    h.client_address = (ip, 40000)
    h.headers = {"Content-Length": str(len(body)),
                 "Content-Type": "application/x-www-form-urlencoded"}
    h.rfile, h.wfile, h._headers_buffer, h.close_connection = io.BytesIO(body), io.BytesIO(), [], True
    getattr(h, "do_" + method)()
    head, _, page = h.wfile.getvalue().decode("utf-8", "replace").partition("\r\n\r\n")
    return head, page


def newest_order():
    return store.one("SELECT pay_token FROM transactions WHERE kind = 'zibal' AND status = 'started'"
                     " AND created_at > '2001' ORDER BY id DESC")["pay_token"]


press(CUSTOMER, "zp:%d" % pid)
token2 = newest_order()
logged = io.StringIO()
with contextlib.redirect_stdout(logged):
    head, page = relay("GET", "/pay/" + token2)
check("the relay sends the customer to Zibal", head.startswith("HTTP/1.1 303") and
      "Location: https://gateway.zibal.ir/start/3714669999" in head, head)
check("asking for the plan's price in rial - Zibal's unit", zp[-1][1]["amount"] == 1500000)
check("with this merchant", zp[-1][1]["merchant"] == MERCHANT)
check("and its way back through this relay",
      zp[-1][1]["callbackUrl"].startswith("https://relay.example.com:8443/pay/back?t="))
check("and the link's token never reaches the log", token2 not in logged.getvalue(), logged.getvalue())
fresh = "3714669999"
state = lambda t=None: store.one("SELECT status FROM transactions WHERE pay_token = ?",
                                 (t or token2,))["status"]
back = lambda t, track, ok="1": relay("GET", "/pay/back?t=%s&success=%s&trackId=%s&status=%s"
                                      % (t, ok, track, "2" if ok == "1" else "3"))
back(token2, fresh, ok="0")
check("a cancelled payment records nothing", state() == "started")
calls = len(zp)
back(token2, "3714660000")
check("a forged track id is not even verified", state() == "started" and len(zp) == calls)
answers["verify"] = {"result": 202, "message": "order not paid"}
back(token2, fresh)
check("an unpaid one that Zibal does not verify records nothing", state() == "started")
answers["verify"] = dict(PAID, amount=150000)
head, page = back(token2, fresh)
check("a payment of less than the price is not recorded", state() == "started" and "مبلغ" in page, page[-300:])
answers["verify"] = dict(PAID)
head, page = back(token2, fresh)
check("a paid one is verified with Zibal", zp[-1][0] == "verify"
      and zp[-1][1] == {"merchant": MERCHANT, "trackId": 3714669999})
check("and settles the order", state() == "approved")
check("the page shows the reference", "777" in page)
answers["verify"] = {"result": 201, "message": "already verified"}
head, page = back(token2, fresh)
check("coming back to the page again is harmless", state() == "approved" and "✅" in page)

press(CUSTOMER, "zp:%d" % pid)
token3 = newest_order()
relay("GET", "/pay/" + token3)
answers["verify"] = dict(PAID)


def pay_verified_fails(payload):
    raise OSError("the exit is not answering")


routes["/pay-verified"] = pay_verified_fails
head, page = back(token3, fresh)
check("a confirmed payment the exit could not record is not lost",
      state(token3) == "started" and "دوباره باز کنید" in page)
routes["/pay-verified"] = api.do_pay_verified
answers["verify"] = {"result": 201, "message": "already verified"}
head, page = back(token3, fresh)
check("reopening the page records it, on Zibal's 'already verified'", state(token3) == "approved")
head, page = relay("GET", "/tg", ip="5.201.0.1")
check("the mini app shows the address it was opened from", "5.201.0.1" in page)
check("and may be framed by Telegram's web client", "frame-ancestors" in head and "X-Frame-Options" not in head)
body = urllib.parse.urlencode({"init_data": launch(CUSTOMER)}).encode()
relay("POST", "/tg/claim", body, ip="5.201.0.1")
check("its button registers that address", [r["ip"] for r in store.user_ips(cid)] == ["5.201.0.1"])
head, _ = relay("GET", "/")
check("every other page still refuses to be framed", "X-Frame-Options: DENY" in head)

print("the operator's tools in the bot")
press(ADMIN, "a:uf")
update(ADMIN, "5.201.0.1")
check("a customer is found by their address", "#%d" % cid in last(ADMIN).get("text", ""))
press(ADMIN, "a:uq:%d" % cid)
update(ADMIN, "۱۰۰")
check("their allowance is set in Persian digits", user_of(CUSTOMER)["quota_bytes"] == 100 * panel.GB)
press(ADMIN, "a:ud:%d" % cid)
update(ADMIN, "0")
check("zero days means no end date", user_of(CUSTOMER)["expires_at"] is None)
press(ADMIN, "a:uv:%d" % cid)
update(ADMIN, "fast")
check("a speed that is not a number is asked again", b.state.get(ADMIN, ("",))[0] == "admin-speed")
update(ADMIN, "5")
check("then saved", user_of(CUSTOMER)["speed_kbps"] == 5000)
press(ADMIN, "a:ux:%d" % cid)
check("suspending works", user_of(CUSTOMER)["status"] == "suspended")
press(ADMIN, "a:upp:%d:%d" % (cid, pid))
check("a plan given to a suspended account leaves it suspended", user_of(CUSTOMER)["status"] == "suspended")
press(ADMIN, "a:ua:%d" % cid)
check("and it comes back", user_of(CUSTOMER)["status"] == "active")
update(WAITING, "/start")
wid = user_of(WAITING)["id"]
press(ADMIN, "a:uq:%d" % wid)
update(ADMIN, "10")
check("giving a waiting account an allowance activates it", user_of(WAITING)["status"] == "active")
check("and tells them", any("فعال شد" in x for x in outbox(WAITING)))
where = admin.Admin.action(form, "user-save", {"id": [str(web["id"])], "quota_gb": ["1"], "days": [""]})
check("the web panel activating an account without a Telegram queues nothing",
      store.one("SELECT count(*) c FROM outbox WHERE chat_id IS NULL")["c"] == 0)
# The panel makes the default template when it starts; nothing has started here.
default = store.ensure_default_template([])["id"]
press(ADMIN, "a:utt:%d:%d" % (cid, default))
check("the template can be changed", user_of(CUSTOMER)["template_id"] == default)
press(ADMIN, "a:st")
check("stats are shown", "آمار" in last(ADMIN).get("text", "") and "فروش" in last(ADMIN).get("text", ""))
press(ADMIN, "a:pd:%d" % pid)
check("a plan that was sold is only taken off sale",
      store.one("SELECT active FROM plans WHERE id = ?", (pid,))["active"] == 0)
press(ADMIN, "a:pn")
update(ADMIN, "آزمایشی | 1 | 1 | 0 | 1000")
spare = store.one("SELECT id FROM plans WHERE name = 'آزمایشی'")["id"]
press(ADMIN, "a:pd:%d" % spare)
check("one never sold is deleted", store.one("SELECT 1 FROM plans WHERE id = ?", (spare,)) is None)
queued = store.one("SELECT count(*) c FROM outbox")["c"]
press(ADMIN, "a:bc")
update(ADMIN, "سرویس امشب ساعت ۲ به‌روز می‌شود")
check("a broadcast is previewed first, nothing queued", store.one("SELECT count(*) c FROM outbox")["c"] == queued)
press(ADMIN, "a:bcy")
reach = store.one("SELECT count(*) c FROM users WHERE telegram_id IS NOT NULL")["c"]
check("confirming queues one message per Telegram account",
      store.one("SELECT count(*) c FROM outbox")["c"] == queued + reach)
press(ADMIN, "a:bcy")
check("confirming twice sends nothing twice", store.one("SELECT count(*) c FROM outbox")["c"] == queued + reach)

print("the free trial")
TRIAL1, TRIAL2 = 5010, 5011
t = panel.trial_settings(store)
check("it is on by default, 1 GB for 24 hours", t["on"] and t["gb"] == 1 and t["hours"] == 24)
update(TRIAL1, "/start")
first = user_of(TRIAL1)
check("a new account is offered it", panel.trial_reason(store, first) == "")
check("and told so on its card", "تست رایگان" in b.account_text(first))
update(TRIAL1, bot.MENU_BUY)
check("the buy menu offers it first",
      buttons(last(TRIAL1))[0]["callback_data"] == "trial", str(buttons(last(TRIAL1))))
press(TRIAL1, "trial")
first = user_of(TRIAL1)
check("taking it turns the account on", first["status"] == "active")
check("with the trial's allowance", first["quota_bytes"] == panel.GB)
check("and no usage yet", first["used_bytes"] == 0)
ends = panel.parse_ts(first["expires_at"])
hours = (ends - datetime.now(timezone.utc)).total_seconds() / 3600 if ends else 0
check("for 24 hours", 23.9 < hours <= 24, str(first["expires_at"]))
check("it is stamped on the account", first["trial_at"] is not None)
check("and recorded like a payment of nothing",
      store.one("SELECT count(*) c FROM transactions WHERE kind = 'trial' AND user_id = ?",
                (first["id"],))["c"] == 1)
check("the customer is told what to do next", "ثبت آی‌پی" in last(TRIAL1).get("text", ""))
press(TRIAL1, "trial")
check("a second tap gets nothing", "قبلاً" in last(TRIAL1).get("text", ""))
check("and no second trial is recorded",
      store.one("SELECT count(*) c FROM transactions WHERE kind = 'trial' AND user_id = ?",
                (first["id"],))["c"] == 1)
update(TRIAL1, bot.MENU_BUY)
check("nor is it offered again",
      not any(x["callback_data"] == "trial" for x in buttons(last(TRIAL1))))
store.run("UPDATE users SET expires_at = ? WHERE id = ?",
          (bot.ago(hours=1), first["id"]))
panel.enforce_quotas(store)
check("when it runs out the account stops", user_of(TRIAL1)["status"] == "expired")
check("and they are told to buy", any("تمام شد" in x for x in outbox(TRIAL1)))
check("an account whose trial ended is not given another",
      panel.trial_reason(store, user_of(TRIAL1)) != "")
check("neither is one that bought a plan", panel.trial_reason(store, user_of(CUSTOMER)) != "")
check("nor a web account with no Telegram", panel.trial_reason(store, store.one(
    "SELECT * FROM users WHERE id = ?", (web["id"],))) != "")
ok, why = panel.grant_trial(store, user_of(TRIAL1)["id"])
check("and asking for one outright is refused", not ok and why)

print("the operator sets the trial")
press(ADMIN, "a:tr")
check("its card shows the settings and how many took it", "تست رایگان" in last(ADMIN).get("text", "")
      and "گرفته‌اند: 1" in last(ADMIN).get("text", ""))
press(ADMIN, "a:trg")
update(ADMIN, "۲٫۵")
check("the size is set in Persian digits", store.setting("trial_gb") == "2.5")
press(ADMIN, "a:trh")
update(ADMIN, "48")
check("so is the length", store.setting("trial_hours") == "48")
press(ADMIN, "a:trs")
update(ADMIN, "-1")
check("a negative speed is refused", store.setting("trial_mbps") == "0")
update(ADMIN, "3")
check("a real one is saved", store.setting("trial_mbps") == "3")
press(ADMIN, "a:trx")
check("the trial can be switched off", not panel.trial_settings(store)["on"])
update(TRIAL2, "/start")
update(TRIAL2, bot.MENU_BUY)
check("then nobody is offered it",
      not any(x["callback_data"] == "trial" for x in buttons(last(TRIAL2))))
press(TRIAL2, "trial")
check("and taking one is refused", user_of(TRIAL2)["status"] == "pending")
press(ADMIN, "a:trx")
check("and it can be switched back on", panel.trial_settings(store)["on"])
press(TRIAL2, "trial")
second = user_of(TRIAL2)
check("the operator's numbers are what a trial gives",
      second["quota_bytes"] == int(2.5 * panel.GB) and second["speed_kbps"] == 3000)
check("for the hours they set", (panel.parse_ts(second["expires_at"])
                                 - datetime.now(timezone.utc)).total_seconds() > 47 * 3600)
store.set_setting("trial_hours", "0")
check("a length of zero switches it off too", panel.trial_reason(store, user_of(NEWBIE)) != "")
store.set_setting("trial_hours", "24")
store.set_setting("trial_gb", "1")
store.set_setting("trial_mbps", "0")

print("delivering the outbox")


class Blocking(FakeTelegram):
    def call(self, method, **params):
        if params.get("chat_id") == 424242:
            raise bot.TelegramError("Forbidden: bot was blocked by the user", 403)
        return super().call(method, **params)


panel.queue_message(store, 424242, "x")
b2 = bot.Bot(store, Blocking(), relays=(RELAY_IP,))
while b2.drain(limit=500):
    pass
check("everything deliverable is marked sent", store.one(
    "SELECT count(*) c FROM outbox WHERE sent_at IS NULL AND chat_id != 424242")["c"] == 0)
check("a customer who blocked the bot is not asked again",
      store.one("SELECT attempts FROM outbox WHERE chat_id = 424242")["attempts"] == 5)

print("the admin panel's bot settings")
where = admin.Admin.action(form, "bot-token", {"bot_token": ["nonsense"]})
check("a malformed token is refused", where.startswith("settings?m=!") and store.setting("bot_token") == TOKEN)
TOKEN2 = "987654321:" + "C" * 35
admin.Admin.action(form, "bot-token", {"bot_token": [TOKEN2]})
check("a real one is saved", store.setting("bot_token") == TOKEN2)
check("with a fresh admin code", "|" in store.setting("bot_admin_code"))
card = admin.bot_card()
check("the card never shows the token whole", TOKEN2 not in card and "987654" in card)
check("it shows how to become admin", "/admin " + store.setting("bot_admin_code").split("|")[0] in card)
check("the token is masked in the action log", "***" in admin.describe({"bot_token": [TOKEN2]}))
admin.Admin.action(form, "bot-admin-del", {"id": [str(ADMIN)]})
check("an admin can be removed", not b.is_admin(ADMIN))
admin.Admin.action(form, "bot-token", {"clear": ["1"]})
check("and the bot switched off", store.setting("bot_token") == "")

print("talking to Telegram and Zibal over HTTP")


class FakeHTTP(http.server.BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        FakeHTTP.seen.append((self.path, dict(self.headers), body))
        if self.path.endswith("/v1/request"):
            if json.loads(body).get("amount", 0) < 1000:
                return self.reply(200, {"result": 105, "message": "amount must be larger than 1000"})
            return self.reply(200, {"result": 100, "trackId": 3714661258, "message": "success"})
        if self.path.endswith("/v1/verify"):
            return self.reply(400, {"result": 102, "message": "merchant not found"})
        if self.path.endswith("/getFile"):
            return self.reply(200, {"ok": True, "result": {"file_path": "photos/1.jpg", "file_size": 3}})
        if self.path.endswith("/sendMessage") and b'"chat_id": 403' in body:
            return self.reply(403, {"ok": False, "error_code": 403,
                                    "description": "Forbidden: bot was blocked by the user"})
        return self.reply(200, {"ok": True, "result": {"message_id": 9}})

    def do_GET(self):
        body = b"abc"
        self.send_response(200)
        self.send_header("Content-Length", "3")
        self.end_headers()
        self.wfile.write(body)


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeHTTP)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = "http://127.0.0.1:%d" % srv.server_address[1]
real = bot.Telegram(TOKEN, base=base)
check("a call returns Telegram's result", real.call("sendMessage", chat_id=1, text="x") == {"message_id": 9})
err = None
try:
    real.call("sendMessage", chat_id=403, text="x")
except bot.TelegramError as e:
    err = e
check("a refusal carries Telegram's code", err is not None and err.code == 403)
check("and never the token", err is not None and TOKEN not in str(err))
real.upload("sendPhoto", "photo", "r.png", PNG, "image/png", chat_id="5001", caption="رسید",
            reply_markup={"inline_keyboard": []})
path, headers, body = FakeHTTP.seen[-1]
check("a receipt goes up as multipart", "multipart/form-data; boundary=" in headers.get("Content-Type", ""))
check("with the file intact", PNG in body and b'filename="r.png"' in body)
check("and the caption as text", "رسید".encode() in body)
check("a file comes down", real.download("f1", 10) == b"abc")
big = False
try:
    real.download("f1", 2)
except bot.TelegramError as e:
    big = e.code == "too_big"
check("unless it is over the limit", big)
sync.ZIBAL = base
check("zibal: its answer when it accepts",
      real_zibal("request", {"amount": 1500000}).get("trackId") == 3714661258)
check("zibal: its reason when it refuses", real_zibal("request", {"amount": 10}).get("result") == 105)
check("zibal: the body of an HTTP error is still read", real_zibal("verify", {"trackId": 1}).get("result") == 102)
path, headers, body = FakeHTTP.seen[-1]
check("zibal: the v1 endpoints, as JSON", path == "/v1/verify"
      and headers.get("Content-Type") == "application/json")
srv.shutdown()

print("installed with the exit")
root = os.path.join(HERE, "..")
logic = open(os.path.join(root, "tools", "installer-logic.sh"), encoding="utf-8").read()
check("the installer puts the bot on the exit", "payload BOT > /usr/local/bin/smartdns-bot" in logic
      and "enable_service smartdns-bot.service" in logic)
check("it is in the build", '"templates/smartdns-bot"' in open(os.path.join(root, "tools", "build-installer.py")).read())
unit = open(os.path.join(root, "templates", "smartdns-bot.service")).read()
check("its unit can write only the database", "ProtectSystem=strict" in unit and "ReadWritePaths=/var/lib/smart-dns" in unit)
built = os.path.join(root, "doctor-dns.sh")
if os.path.exists(built):
    check("and the built installer carries it", "#__BEGIN_BOT__" in open(built, encoding="utf-8").read())

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
