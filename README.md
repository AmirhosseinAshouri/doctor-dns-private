<h2 align="center">تقدیم به حدیث❤️ که منو تو اولین پروژم یاری و تحمل کرد</h2>

# doctor dns

*[فارسی](README.fa.md)*

A smart DNS service for Iran, in two halves: a relay inside the country and an
exit node outside it. Sanctioned domains resolve to the relay, which carries
those connections abroad; everything else resolves normally and goes direct.

It is a whole service, not just a proxy — per-customer access control, traffic
accounting, quotas, speed limits, a customer panel and an operator panel, all
in one install script with no dependencies beyond what Debian ships.

**Alpha.** Help us carry this project forward with your bug reports.

They are worth more than anything else right now. If something breaks, or a
service you expected to work does not,
[open an issue](https://github.com/AmirhosseinAshouri/doctor-dns-private/issues) — say which
side it was, what you ran, and what happened. A report of one console failing
one download is a genuinely useful thing; most of what is in here was learnt
exactly that way.

---

## What it does

```
   customer            relay (Iran)              exit (abroad)          service
  ┌────────┐          ┌────────────┐            ┌───────────┐        ┌─────────┐
  │ PS5    │   DNS    │ dnsmasq    │            │           │        │ Sony    │
  │ phone  │ ───────► │  answers   │            │  nginx    │        │ Spotify │
  │ PC     │          │  with self │            │  reads    │        │ …       │
  │        │   TLS    │ nginx      │ ─────────► │  the SNI  │ ─────► │         │
  └────────┘ ───────► │  SNI proxy │            │           │        └─────────┘
                      │ nftables   │            └───────────┘
                      │  gate +    │
                      │  counters  │
                      └────────────┘
```

The relay never terminates TLS. nginx reads the SNI from the handshake and
opens a plain TCP tunnel to the exit, which does the same and connects to the
real host. Nothing decrypts anything, and no certificate is presented to the
client.

Port 80 is forwarded rather than redirected, because Sony and Microsoft serve
game packages over plain HTTP from Akamai edges that answer 443 with a
certificate naming no console host at all.

## What is in it

| | |
|---|---|
| **Routing** | dnsmasq hijacks a list of ~480 sanctioned domains; AAAA answers are filtered so clients cannot route around the proxy |
| **Games** | PlayStation, Xbox and Steam storefronts and downloads; EA, Epic; STUN/TURN on the relay so console NAT detection still works |
| **Access control** | an nftables allowlist keyed on the customer's address, with per-address byte counters in the kernel |
| **Quotas** | monthly or one-off, with warnings at 80% and 95% and automatic cutoff |
| **Speed limits** | a per-customer download cap, shaped with htb + fq_codel rather than by dropping packets |
| **Service templates** | which brands a customer's plan routes, down to individual domains; a few groups ship visible but unticked, because routing them breaks the thing they belong to |
| **Customer panel** | sign up, register an address, see usage, send a payment receipt |
| **Telegram bot** | the customer panel in Telegram, plus buying a plan - card to card or Zibal - and the operator's receipts, customers, plans and broadcasts |
| **Operator panel** | customers, templates, domains, live monitoring, host health, backup and restore |
| **TLS** | certificates obtained and renewed automatically, asking for nothing but a domain name |

## What it looks like

The operator's panel, on the exit. Customers, what each has used, their
quota, their speed cap and how long they have left — all editable in the row:

![The operator's user list](docs/screenshots/admin-users.png)

A template decides which brands a customer's plan carries. Open a service and
the domains inside it can be picked one at a time; the amber note is a group
that ships switched off because routing it breaks the thing it belongs to:

![The template editor](docs/screenshots/admin-template.png)

And the machines themselves, reporting in every thirty seconds:

![Host monitoring](docs/screenshots/admin-home.png)

The customer's own page, served by the relay. It shows what is left, the DNS
address to type into a console, and the button that re-registers their
address after the ISP has changed it:

<img src="docs/screenshots/user-panel.png" alt="The customer's page" width="360">

*(Made-up customers. Nobody in these pictures is real.)*

## Install

One script, run once on each machine. It asks which side it is on and the
address of the other.

This repository is private, so the servers never fetch anything from it:
nothing on them has - or needs - a way in. Download `doctor-dns.sh` from the
[releases](https://github.com/AmirhosseinAshouri/doctor-dns-private/releases) on your own computer, signed in, and copy it to each
machine:

```sh
gh release download -R AmirhosseinAshouri/doctor-dns-private -p doctor-dns.sh
scp doctor-dns.sh root@SERVER:
ssh -t root@SERVER 'bash doctor-dns.sh'
```

It runs from a file rather than a pipe on purpose. Every config this installs
is stored inside the script itself, below `exit 0`, so it has to be able to
read its own file — and it asks questions, which a pipe would answer with
end-of-file. The copy also stays behind, to read, to re-run, and to uninstall
from. It refuses to run if that copy is not whole.

Run the **exit** first: it prints a pairing token that the relay asks for.

Safe to re-run — configs are backed up, and a step that would change nothing
does nothing. `sudo bash doctor-dns.sh --uninstall` puts the machine back,
undoing only what this script did.

### Upgrading

Copy the new file over, the same way, and run it - or put it at
`/root/doctor-dns.sh` and choose *update* in `smartdns-menu`. Before it
touches anything it compares its
own version against what the machine has, says which way it is going, and
waits for an answer:

```
Version

    installed on this machine:  0.1.0
    this file:                  0.2.0

    this will upgrade this machine from 0.1.0 to 0.2.0.
    your customers, settings, certificates and allowlist are kept.

  go ahead? [y]:
```

The case worth having it for is the other one. Run an old file over a newer
install — a download still sitting in a home directory, months later — and it
says so, and the default answer becomes no.

Your customers, their usage, the sync secret, the panel password and any
certificate all live outside the files the script writes, so an upgrade keeps
them. A copy of the database is taken into `/var/backups/smart-dns/` first
anyway, with `VACUUM INTO` rather than `cp`, because the panel keeps a
write-ahead log beside the database and copying the file alone can miss its
newest rows. `--version` prints what a file is without installing anything,
and `ASSUME_YES=1` takes the default — yes for an upgrade, no for a
downgrade — for anyone scripting it.

### Requirements

Two machines with Debian or Ubuntu and a public address each:

- **relay** — inside Iran, the address customers point their DNS at
- **exit** — outside, reachable from the relay

No pip, no npm, no containers. Python's standard library, nginx, dnsmasq,
nftables and coturn, all from the distribution.

### ⚠️Choosing servers⚠️ - ⚠️what we have measured⚠️

How fast the service is, and whether it works at all, depends less on this
script than on the path between the Iran server and the exit. Iran's filtering
does not treat every foreign server alike: some it leaves alone, some it slows
down, and some it effectively shuts off. The results below come from our own
tests, so that your money does not go on a server that will not work.

| Exit | Result |
|---|---|
| AWS Lightsail, Germany | worked without problems |
| Hetzner (Germany, Finland) | worked without problems, and fast - about 2 MB/s |
| Linode Frankfurt, OVH France, a netlen host in Turkey | worked well |
| DigitalOcean | did not work in any of the 8 regions tested; the connection opens, but after a few KB nothing more gets through |
| OVH (some newer addresses) | the same problem as DigitalOcean |
| Vultr Miami | works, but very slowly - about 100 KB/s |

A few notes:

- A provider's test file downloading fast from inside Iran does not mean the
  server you buy from that provider will be fast; we saw exactly this with OVH
  and Vultr.
- An exit may work well with one Iran server and not with another.
- The service did not behave the same on every internet connection: with the
  same setup it worked well on mobile internet but was very slow on home
  internet. Test it on the connections your customers actually use.

**Our advice:** if you are buying servers for this script, rent both the Iran
server and the exit by the hour first. Set the service up, try it on different
connections, and only renew the servers for longer once you are satisfied.

### Ports

Everything below is taken by the service. Open them in the firewall, and do
not give any of them to the admin panel — the installer refuses the ones it
can see, but a firewall rule you wrote yourself it cannot.

| | relay (inside Iran) | exit (abroad) |
|---|---|---|
| **53** udp + tcp | dnsmasq, the address customers point at | — |
| **80** tcp | forwarded abroad; also how certificates are proved | the same |
| **443** tcp | the SNI proxy | the same |
| **3478** udp | STUN, so a console can work out its own NAT | — |
| **8443** tcp | the customer panel — TLS only, so a relay without a certificate serves no panel at all | the sync API — it answers the relays and nobody else |
| **8446** tcp | — | loopback only: the exit's route to Google over IPv6, where it has IPv6 |
| **8444** tcp + udp | only with a tunnel: its port, answering the exit alone — a *reverse* tunnel listens here | the same, for a *direct* tunnel |
| **22** tcp | ssh — never gated, so a wrong allowlist cannot lock you out | the same |

The admin panel is the one port you choose. It defaults to **9443** and can be
anything free; the installer stops you at 22, 53, 80, 443, 8443, 8446 and the
tunnel's port, and `smartdns-access port` applies the same rule later, plus a
check that nothing else is already listening.

Inbound, the relay is the machine customers reach, so its DNS, proxy, STUN and
panel ports have to be open to the internet. The exit only ever hears from the
relay and from you, so 80, 443, 8443 and the panel port are enough there.

### A tunnel between the relay and the exit (optional)

By default the relay hands each connection to the exit as it is: plain TCP,
the customer's TLS untouched inside. That is the fastest path, but the name of
every site shows on the way, and on some routes filtering acts on exactly that
— Google's names killed while everything else passes, or a whole provider
slowed to a crawl.

The installer can put a [BackPack](https://github.com/AminMGMT/BackPack) tunnel
— Amin Mohammadi's work, see [Credits](#credits) — on that link instead. The exit asks when it is installed — plain TCP or
BackPack, which transport, which end dials, which port — and the relay learns
the answer from the pairing token, so the two ends cannot disagree. Customers
notice nothing: DNS, the allowlist, usage, speed limits and both panels all sit
in front of the tunnel.

- The relay's nginx goes through the tunnel, and straight to the exit only
  while the tunnel is down.
- BackPack is fetched from its own releases when you ask for it and checked
  against a hash pinned in the installer. It is not part of this project (it is
  AGPL-3.0). A server with no internet: `BACKPACK_TARBALL=/path/to/the.tar.gz`.
- The listening end's port answers the other machine and nobody else.
- Back to plain TCP in one command, on either machine:
  `sudo smartdns-tunnel off`. To change the transport, the port or which end
  dials: `sudo bash doctor-dns.sh --tunnel` on the exit, then on the relay.
  `smartdns-logs` shows its log and `smartdns-restart` restarts it.

Which transport suits a route depends on the route, so try one or two:
`--tunnel` makes changing it one line. **stealth** is encrypted and looks like
random bytes, and is the default; **wss** and **wssmux** look like an ordinary
HTTPS website; **tcp**, **ws** and their pooled forms are not encrypted, so the
names of the sites still show. In our own test **quic** and **udp** did not
connect at all. A *direct* tunnel, where the relay dials the exit, has four
transports: stealth, wss, tcp and ws.

### Several exits (optional)

A relay can send its customers out through more than one exit. The exit you
install first stays the main one - it keeps the database, the admin panel and
the bot. Any others are *extra exits*: servers abroad that carry traffic and
nothing else.

1. Upgrade the relay to this version first: it has to know its own exit to
   fall back to.
2. On the new server, run the installer and choose **3) extra exit**. Give it
   the relay's address - several relays, comma separated. It sets up nginx to
   let those relays in and nobody else: no panel, no bot, no second database.
3. In the bot, **🛠 مدیریت → 🌍 خروجی‌ها → ➕**, add it by name and address.

Within a minute the relay knows it, and within five it has measured it. Every
five minutes the relay times a connection to each exit - the leg it adds to
every customer's connection - and customers see **🌍 سرور خروجی** in the bot:
the exits sorted by that ping, and **⚡️ automatic**, the default, which always
puts them on the fastest. Their choice reaches nginx as a map on their address,
rewritten only when it changes and only once `nginx -t` accepts it. If an extra
exit stops answering, nginx sends its customers to the main exit until it is
back.

**A tunnel to an extra exit.** An extra exit can have one of its own. Its
installer asks - transport and port, the relay always dials - and prints one
line at the end:

```
a name | 203.0.113.10 | bp-stealth-8444-d.<token>
```

Paste that into the bot when you add the exit, or later under the exit's
**🔀 تونل** button; send `حذف` there to go back to plain TCP. The relay then
runs one BackPack client per tunnelled exit, and nginx sends that exit's
customers to its end of the tunnel, falling back to the same exit unwrapped
and only then to the main exit.

The relay needs BackPack for this. If it has never had a tunnel of its own,
run the installer there once with `--tunnel`; until then the relay reaches
such an exit directly and says so in `smartdns-logs`.

The pair's own tunnel is unchanged: relay and main exit, its settings carried
by the pairing token.

#### Deciding where the next exit goes

The admin panel's **مانیتورینگ** page is that decision, on one screen:

* **Active customers** - every address connected right now, the round trip
  from their device to the relay, how many connections they have open, which
  exit they take, the relay→exit leg, and the two added up. The first number
  is read out of the relay's own kernel (`ss -ti`) on connections the customer
  already had open, so measuring it costs nothing and probes nobody.
* **Exits** - each one with the ping the relay last measured and how many
  customers sit on it.
* **Where the games' servers are** - each game domain resolved from the exit
  and the country of the address it resolved to, grouped by country with the
  games in each. A country that holds a lot of them is where another exit is
  worth having: from there the same login, store and download traffic has a
  shorter way to go.

This is not an in-game ping, and no page here claims to be one. Match traffic
never touches the service - only the store, the login and the downloads do -
so what these numbers describe is exactly the path the service carries. The
countries are looked up once per address and kept for a day; the whole list
fills in over a few hours in the background.

### Access control

A fresh relay answers everyone. That is not a default anybody chose - it is
that a relay is installed before a single address is registered, and closing
it against an empty allowlist cuts off every user at once, the operator
included.

So the relay closes itself at the first sync that brings a registered
address, and only registered addresses get DNS, HTTP and HTTPS from then on.
SSH is never gated, so a wrong allowlist cannot cost anyone access to the
machine.

```sh
smartdns-acl enforce status   # which it is right now
smartdns-acl enforce off      # stay open, and cancel the automatic close
```

`ENFORCE=no` on the installer's command line opts out from the start.

## After installing

Each side prints what it set up at the end of its install: the relay names the
DNS address and the customers' panel, the exit names the operator's panel and
its password, shown once.

The operator's panel is the whole administrative interface — customers, their
quotas and speeds, service templates, the domain list, live monitoring of
who is connected and where the games are, host health, payment receipts, and
backup and restore. Everything below is for the cases a
web page cannot serve: reading state over ssh, and getting back into a panel
you can no longer reach.

### On the exit

**`smartdns-access`** — where the admin panel is, and how to change it. Run it
with no arguments and it prints the full address, read from the config the
panel actually serves.

```sh
smartdns-access                  # the URL it answers on - forgot it? start here
smartdns-access port 9443        # move it, if a firewall is in the way
smartdns-access path [new]       # change the secret path, or roll a fresh one
smartdns-access password [new]   # set a new one; the old is not recoverable
smartdns-access rotate           # new path and new password at once
```

Of those three, only the password is authentication. The port keeps the panel
out of the way of casual scanning and nothing more; the path is unguessable
but travels in every request line and lands in any proxy log on the way. The
password is never stored — only a salted hash — which is why a forgotten one
is replaced rather than recovered.

### On the relay

**`smartdns`** — the list of domains that go through the relay.

```sh
smartdns status                  # what this machine is doing
smartdns list                    # every domain being routed
smartdns find spotify            # which ones match
smartdns add example.com         # route one more
smartdns del example.com         # stop routing it
smartdns bypass api.example.com  # never route this one, even though its
                                 # parent is routed - for services that are
                                 # not on 443 at all
smartdns test example.com        # what this relay answers for it
```

**`smartdns-rules`** — what each template does with a domain, asked of the
resolvers themselves. Every template with customers gets its own resolver on
the relay; the default template is the resolver on port 53.

```sh
smartdns-rules                   # every template: its port, its customers, and
                                 # how many names it redirects, bypasses and pins
smartdns-rules show test         # the full lists for one template
smartdns-rules check gemini.google.com
                                 # each template's rule for it and what its
                                 # resolver really answers - flagged if the two
                                 # disagree
```

**`smartdns-watch`** — the names a customer's device asks for, live, and
where this relay sent each. For finding what a service needs routed: have the
customer open it until it fails, and watch.

```sh
sudo smartdns-watch ali          # one customer - by username, by the label
                                 # smartdns-acl list shows (u12), or by address
sudo smartdns-watch              # everybody, each line naming who asked
```

`via relay` is already routed. `direct` went around the relay: if the service
refuses Iran, those are the names to add, with `smartdns add` or the panel's
domains page. `filtered in Iran` is Iran's own block, which no routing gets
past, and `no answer` usually means the address is not registered. Add only
names a service uses over HTTPS or plain HTTP - a game's match servers talk on
other ports, and routing them breaks the game. Nothing is kept: what it prints
is all there is.

#### Adding a game or an app

A service that refuses Iran and is not in the list yet: the relay can show you
what it needs.

1. Register the address of the device you will test from, as usual, then on
   the relay watch it by username:

   ```sh
   sudo smartdns-watch ali
   ```

2. Open the game or the app on that device until it shows its error.
3. Read the names that go by. The `direct` ones went around the relay; the
   service's own names among them - not ads or analytics - are the ones to
   route. A name answered with an address that leads nowhere, like
   `direct 0.0.0.1`, is the service refusing Iran in its DNS: route that one
   too.
4. Route them, from the panel's domains page (then tick them in the template
   the customer is on), or on the relay:

   ```sh
   sudo smartdns add example.com
   ```

5. Open it again. Those names should now say `via relay`.

If the service stops working once a name is added, that name is used on a port
the relay does not carry - a game's match servers usually are. Take it back out:

```sh
sudo smartdns del example.com
```

What this cannot fix: names a service looks up itself without asking DNS -
some mobile games do, and nothing shows in `smartdns-watch` for them - traffic
that is neither HTTPS nor plain HTTP, and names that are `filtered in Iran`.
When a set of names works, [open an issue](https://github.com/AmirhosseinAshouri/doctor-dns-private/issues)
with them, so they can go in the default list.

**`smartdns-acl`** — who may use the relay, and what they have used. The panel
drives this rather than touching nftables itself, so there is one place where
the rules about what is legal live.

```sh
smartdns-acl list                # everyone, with usage
smartdns-acl usage 5.188.44.19   # one address
smartdns-acl add 5.188.44.19 ali # register one by hand
smartdns-acl del 5.188.44.19
smartdns-acl reset <ip>|--all    # zero the counters
smartdns-acl enforce status      # open, or only registered addresses?
smartdns-acl enforce on          # close it
smartdns-acl enforce off         # open it to everyone
smartdns-acl save                # persist to disk now
```

`enforce on` refuses when nobody is registered — closing a live relay against
an empty list cuts off every customer at once, and that is a mistake which
feels irreversible from the far end of a broken connection. Add
`--allow-empty` if you mean it. `--json` on `list` or `usage` gives output
meant for a program.

**`smartdns-shape`** — per-customer download limits, htb + fq_codel.

```sh
smartdns-shape list              # what is in force
smartdns-shape off               # remove all shaping
```

The sync agent applies these from the panel every thirty seconds, so set
speeds there rather than here.

### On either

**`smartdns-logs`** — what this machine has been doing, every part of it at
once. It tells a relay from an exit by itself.

```sh
sudo smartdns-logs               # each part: running or not, and its last 100 lines
sudo smartdns-logs -e            # only warnings and errors
sudo smartdns-logs -f            # follow live; -e -f for problems only
sudo smartdns-logs -n 500        # more lines per part
sudo smartdns-logs --report      # all of it in one file to send, secrets masked
```

The panels log one line per request and one per operator action; the relay
logs each domain that changes route in each template, and each customer that
moves between templates. Warnings and errors carry a syslog level, which is
what `-e` reads. Passwords, sessions and tokens are never written. Plain output
is for your own screen - the admin panel's start-up line includes its address.
`--report` masks every secret in the machine's config wherever it turns up,
that address included; it still holds customers' addresses and usernames, so
send it only to someone you trust.

**`smartdns-restart`** — restart every part of this machine at once, then
show which came back up. It tells a relay from an exit by itself.

```sh
sudo smartdns-restart
```

On a relay, customers' open connections drop for a moment and come straight
back. If nginx's or dnsmasq's config does not load, that part is left running
as it was rather than restarted into a failure, and the command says why.
nftables is never restarted: that would throw away the allowlist and the usage
counted since the last save.

**`smartdns-tunnel`** — the tunnel between the relay and the exit, when there
is one: see it, stop it, start it.

```sh
sudo smartdns-tunnel             # what it is, and whether it is carrying traffic
sudo smartdns-tunnel off         # back to plain TCP, now
sudo smartdns-tunnel on          # start it again, with the settings it had
sudo bash doctor-dns.sh --tunnel # change it - on the exit first, then the relay
```

Either machine will do for `off`: the relay's nginx goes straight to the exit
the moment its end of the tunnel stops answering, whichever machine stopped it.
The choice is kept, so an upgrade does not bring the tunnel back. `--tunnel`
asks the tunnel's questions again on a machine that is already set up: on the
exit with what it has now as the answers enter gives, on the relay for the new
pairing token the exit printed.

**`smartdns-menu`** — every command on this page in one menu, for when you do
not remember the one you want. Each choice shows the command before running it,
so the next time you can type it yourself.

```sh
sudo smartdns-menu
```

```sh
smartdns-cert panel.example.com  # get or renew a certificate for that name
sudo bash doctor-dns.sh --version
sudo bash doctor-dns.sh --uninstall
```

`smartdns-cert` borrows port 80 for the twenty seconds a challenge takes, so
console downloads through a relay stall for that long and resume. A timer
renews on its own once there is something to renew.

## The Telegram bot

Everything a customer does on the relay's page, they can do in a Telegram bot
as well - and buy a plan there, which the page cannot. The operator runs the
service from the same bot.

It runs on the exit, as `smartdns-bot`, because Telegram is filtered inside
Iran. It is installed with the exit and does nothing until it has a token. It
listens on no port: it only dials out to Telegram.

### Setting it up

1. In Telegram, create a bot with [@BotFather](https://t.me/BotFather) and copy
   its token.
2. In the admin panel, **Settings → Telegram bot**, paste the token. The bot
   connects within a few seconds.
3. The same card shows a one-time code. Send `/admin <code>` to your bot: you
   are its admin, and a **🛠 مدیریت** button appears in its menu. A code works
   once, for 24 hours; the card makes a fresh one for each admin you add.
4. In the bot, under **🛠 مدیریت**, create plans and set a card number, a
   Zibal merchant ID, or both.

Or over ssh:

```sh
sudo smartdns-bot token          # asks for the token, prints an admin code
sudo smartdns-bot code           # a fresh admin code
sudo smartdns-bot status         # token, bot name, admins, the relay it links to
sudo smartdns-bot off            # forget the token
```

### What customers can do

| | |
|---|---|
| **`/start`** | opens an account - pending, with nothing, like a web signup |
| **🎁 تست رایگان** | one free 24-hour trial, once per Telegram account, offered until they buy anything |
| **👤 حساب من** | status, plan, registered address, usage, allowance, speed, end date |
| **🛒 خرید / تمدید** | pick a plan, then pay card to card (a photo of the receipt) or online through Zibal |
| **🌐 ثبت آی‌پی** | a mini app that registers the address the phone is on, or type one in |
| **📡 آدرس DNS** | the address to put in a console, phone or router |
| **📶 پینگ بازی‌ها** | each game's ping from the Iranian server right now - green, yellow or red, fastest first |
| **🌍 سرور خروجی** | choose an exit by its ping from the relay, or leave it on automatic - shown once there is more than one |

The bot messages them on its own: at 80% and 95% of the allowance, when it
runs out or the period ends, when a receipt is approved or rejected, and when
the account is activated.

**The free trial.** A new account is offered one trial - 1 GB for 24 hours by
default - which turns the service on at once, so somebody can test it before
paying. It is offered only while the account has never had anything: once the
trial ends, or a plan is bought, it is not offered again. Taking it is recorded
on the account, so it cannot be taken twice, and it shows in the bot's stats.
Set its size, length and speed, or switch it off, in the bot, under
**🛠 مدیریت → 🎁 تست رایگان**.

Buying renews. The allowance becomes the plan's, usage starts from zero and the
period counts from that day. A plan can carry a template, which the account is
moved to.

**Game pings.** Every five minutes the relay times a connection to a few of
each game's domains - the same ones its DNS list routes - and the bot shows the
result: customers see one line per game, the admin sees every host, its
address and its loss, and which relay measured. Nothing is measured through the
exits: the exits carry customers' traffic and are left to do that.

It is the Iranian server's ping, not the customer's: a game's match traffic
goes straight from their own internet to the game, not through the relay. It is
still the best guide to which games answer well from Iran, and which Iran
filters outright. TCP connections are timed rather than ICMP pings, because
many game servers ignore ping; names are looked up at public resolvers, not the
relay's own DNS.

### What the operator can do

Under **🛠 مدیریت**:

- **Receipts** - each new one arrives with its photo and approve and reject
  buttons. Approving applies the plan it was sent for. A receipt approved in the
  admin panel has its plan applied too.
- **Customers** - find one by name, id, Telegram id or address; set the
  allowance, days and speed, apply a plan, change template, reset usage, suspend.
- **Plans** - create, edit, stop selling, delete.
- **Free trial** - its size, length and speed, or switch it off; and how many
  have taken one.
- **Payment methods** - the card number and its holder, the Zibal merchant ID.
- **Stats** - customers by status, receipts waiting, sales over 30 days, and each
  server's health.
- **Pings** - each game's hosts as the relay last measured them: address, time,
  loss, and which Iran filters.
- **Exits** - add, rename, switch off or delete extra exits, and see each one's
  ping and how many chose it.
- **Broadcast** - one message to everybody who has started the bot, after a
  preview.

### The mini app and online payment

Both are pages on the relay, because each needs something only the relay has:
the customer's real address, and an Iranian server for Zibal to answer and
send the customer back to. So both need the relay to have a domain and a
certificate, the same as its customer panel. The relay tells the exit where its
pages are on every sync; until one with a domain has synced, the bot offers
only typing an address and paying card to card.

- **The mini app** sees whatever address the phone is using. With a VPN on, that
  is the VPN's - the page says to turn it off first.
- **Zibal** has to accept the relay's return address: register the relay's
  domain, which the bot shows under payment methods, as your website in the
  Zibal panel. A payment is confirmed with Zibal from the relay before
  anything is recorded, only against the order it was started for, and only
  for its full price. Prices are in toman; Zibal is asked for the same in rial.

### The look of it

The panels and the bot are dressed as **Fasty DNS**: near-black `#07080A`,
signal green `#C7F000`, 1px `#23272E` lines, no rounded corners and no
shadows - depth comes from the surface value and the line. Space Grotesk sets
the text, JetBrains Mono every numeral, address and unit, which is the
system's strictest rule.

Both faces are **carried inside `doctor-dns.sh`** and served by the panels
themselves, from `/usr/local/share/smart-dns/fonts`. Google Fonts is blocked
in Iran, and a page that cannot fetch its font draws in whatever the device
happens to have. They hold Latin and numerals only - about 50 KB of the
installer between them - and Persian text falls through to the device's own
face.

The mark is drawn in the page as SVG rather than fetched, so it costs no
request and cannot go missing. `assets/fonts/` holds the two faces as base64;
the brand bundle they came from is not in this repository.

## How it is built

`doctor-dns.sh` is generated, not hand-edited. Everything lives in
`templates/`, `common/` and `domains/`; `tools/installer-logic.sh` is the
script's logic, and `tools/build-installer.py` staples them together:

```sh
python3 tools/build-installer.py   # rewrites doctor-dns.sh
bash -n doctor-dns.sh              # it stays valid bash
python3 tools/test-websignup.py    # …and so on for the rest
```

Payloads sit below `exit 0` with every line `#`-prefixed, which is what keeps
the whole file valid bash — so `bash -n` genuinely checks it, and a reviewer
can read every config they are about to run as root.

## Shape of a deployment

One database serves every relay. That is what makes a customer's allowance
mean one thing across the service rather than one thing per machine.

```
  exit node                          relay(s)
  ┌──────────────────────┐          ┌──────────────────────┐
  │ smartdns-panel       │ ◄─────── │ smartdns-sync        │
  │  sqlite + sync API   │   30s    │  usage up,           │
  │                      │ ───────► │  allowlist down      │
  │ smartdns-admin       │          │                      │
  │  operator's panel    │          │ customer's panel     │
  └──────────────────────┘          └──────────────────────┘
```

The relay always dials out. It is the machine in the harder network position,
and this way it needs no new inbound port.

The customer's panel lives on the relay because the point of it is to learn
the customer's address, and only the relay sees the address they actually
reach the service from.

## Known limits

- **Upload is not shaped.** Only the download direction is capped. Policing
  ingress needs an ifb device and drops rather than queues, for a service
  whose traffic is overwhelmingly inbound.
- **A relay without a certificate has no customer panel.** That page asks for
  a password, and nothing here asks for a password over plain HTTP — so it is
  not served at all rather than served unsafely. Nobody can sign up or
  register an address on such a relay until it is given a domain.
- **The web page has no trial.** Signing up there gets an account and
  somewhere to send a receipt — no traffic — until a plan is bought or an
  operator gives one. The free trial is offered in the Telegram bot only.
- **The trial is one per Telegram account, not one per person.** Somebody who
  opens a second Telegram account can take another. What limits that is the
  address: an address registered to one account cannot be registered to
  another, so a second trial is of no use on the same connection.
- **Plans are sold only in the bot.** The web page takes a receipt but cannot
  pick a plan or pay online; an operator approving that receipt sets the
  allowance by hand.
- **With several relays, the bot links to one.** The mini app and the payment
  page are on whichever relay with a domain synced last.
- **The mini app has not been tried on every Telegram client.** It reads its
  launch data from the page's address rather than from Telegram's script,
  which is filtered in Iran; typing the address in the bot always works.
- **Xbox downloads stall** regardless of whether they are routed. Measured,
  not solved.
- **Traffic costs double.** One customer gigabyte is about two on the relay
  and two on the exit — measured, and worth knowing before pricing anything.

## Contributors

- [Armin Toranj](https://github.com/arminandtoo) — `@arminandtoo`

## Credits

- **[BackPack](https://github.com/AminMGMT/BackPack)**, by **Amin Mohammadi**
  ([@AminMGMT](https://github.com/AminMGMT)), carries the optional tunnel
  between the relay and the exit. It is his work, released under the AGPL-3.0:
  this project only downloads his own unmodified releases, checks them against
  a pinned hash, and runs them. Thank you, Amin.
- The exit's nginx configuration started from
  [rohammosalli/smart-dns](https://github.com/rohammosalli/smart-dns).

---

<div align="center">

## ☕ Support this project

**It is free, and it stays free.**

Support open source softwares❤️<br>
Long live free software🕊<br>
Long live free internet🌐

</div>

<div align="center">

| | |
|:--|:--|
| **TON** | `UQAh8oTWt8ec-q4I1zxga1sUYmKmvcQKGDYwspDrsGmUlQKI` |
| **Tether — BEP20** | `0x8aE738721Ca6Fd9a8a375Df3AC4A144ed5695355` |
| **Tether — TRON (TRC20)** | `TPiyEnb41qTZz8eM6eqnRwXbPXBZCNS1pm` |

</div>
<a href="https://coffeebede.com/agentmehdi47"><img class="img-fluid" src="https://coffeebede.ir/DashboardTemplateV2/app-assets/images/banner/default-yellow.svg" /></a>
## Licence

MIT. See [LICENSE](LICENSE).

The domain list is assembled from public sources and from testing; it is not
exhaustive and will drift as services change.
