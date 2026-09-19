#!/usr/bin/env bash
#
# Smart DNS installer - sanction-bypass DNS for Iran, in two halves.
#
#   relay  (inside Iran)  dnsmasq answers a list of blocked domains with its own
#                         address; nginx then carries those connections abroad
#   exit   (outside)      nginx reads the SNI and connects to the real host
#
# Run it on both machines, once each. It asks which side it is on and the
# address of the other. Safe to re-run: configs are backed up, and a step that
# would change nothing does nothing.
#
#   sudo bash doctor-dns.sh              install or update this machine
#   sudo bash doctor-dns.sh --uninstall  put the machine back as it was
#
# HTTPS for the panels is optional and asks for nothing but a domain name. A
# certificate is obtained and renewed automatically, proved over port 80 - so
# the name has to point at the machine and port 80 has to be reachable. On a
# relay that port is forwarded to the exit, so it is borrowed for the twenty
# seconds a challenge takes and given straight back; console downloads through
# it stall for that long and resume.
#
# PANEL_CERT and PANEL_KEY use a certificate you already have instead, and
# CF_API_TOKEN proves the domain over DNS without touching port 80. Neither is
# ever prompted for.
#
# Per-client access control ships with this but starts switched off. The relay
# counts each registered address's traffic from the moment it is installed and
# blocks nobody; `smartdns-acl enforce on` is what closes the door, and it is
# meant to be run once there is a way for users to register an address. Turning
# it on before then locks out everyone, including you.

set -euo pipefail

SELF="${BASH_SOURCE[0]}"
STAMP="$(date +%Y%m%d-%H%M%S)"

# What this file is. Written to the machine once an install finishes, so the
# next run can tell whether it is an upgrade, a re-run, or somebody about to
# put an older version over a newer one by accident.
VERSION="0.9.0"

# What this install did, so uninstall can undo exactly that and nothing more.
# Without it, removal would be guesswork: whether dnsmasq was ours or already
# here, whether nginx.conf had a config worth putting back. Guessing wrong on a
# box that was doing something else first is how an uninstall does damage.
STATE_DIR="/var/lib/smart-dns"
STATE="$STATE_DIR/install-state"

# Backups go here, never beside the original. dnsmasq reads *every* file in
# /etc/dnsmasq.d, so a backup left there is loaded as a second copy of the same
# config and the service refuses to start on "illegal repeated keyword". Found
# the hard way: it took a working relay down on the second run.
BACKUP_DIR="/var/backups/smart-dns"

# ---------------------------------------------------------------- output
if [ -t 1 ]; then
    B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; RD=$'\033[31m'; N=$'\033[0m'
else
    B=""; G=""; Y=""; RD=""; N=""
fi
step() { printf '\n%s==>%s %s%s%s\n' "$G" "$N" "$B" "$*" "$N"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    %s%s%s\n' "$Y" "$*" "$N"; }
die()  { printf '\n%sERROR:%s %s\n\n' "$RD" "$N" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- payloads
# Configs live at the bottom of this file, after exit 0, between markers, with
# every line prefixed by '#' so the whole script stays valid bash. awk copies
# them out and strips that prefix - no shell expansion anywhere, so nginx's
# $variables and dnsmasq's syntax survive untouched.
payload() {
    awk -v name="$1" '
        $0 == "#__BEGIN_" name "__" { on = 1; next }
        $0 == "#__END_"   name "__" { on = 0 }
        on { sub(/^#/, ""); print }
    ' "$SELF"
}

backup_file() {
    [ -f "$1" ] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$1" "$BACKUP_DIR/$(basename "$1").$STAMP"
    info "backed up $1 -> $BACKUP_DIR"
}

# Write payload $1 to file $2, substituting the two addresses. Backs up whatever
# was there, and skips the write when the content is identical so re-runs do not
# churn files or trigger needless restarts. Returns 0 only if it changed.
install_payload() {
    local name="$1" dest="$2" tmp
    tmp="$(mktemp)"
    # MODULE_PATH is filled in here, not with a sed -i afterwards, so that what
    # we compare against the installed file is the finished article. Doing it
    # after the comparison meant every run saw a difference and rewrote
    # nginx.conf - the same needless-restart trap epic-pin fell into. MOD is
    # empty for the payloads written before it is discovered, and none of those
    # contain the placeholder.
    payload "$name" \
        | sed -e "s#__RELAY_IP__#${RELAY_IP}#g" \
              -e "s#__EXIT_IP__#${EXIT_IP}#g" \
              -e "s#__MODULE_PATH__#${MOD:-__MODULE_PATH__}#g" \
              -e "${NO_GOOGLE_V6:+/# google-v6 begin/,/# google-v6 end/d}" \
              -e "s#__EXIT_HTTPS__#${EXIT_HTTPS:-__EXIT_HTTPS__}#g" \
              -e "s#__EXIT_HTTP__#${EXIT_HTTP:-__EXIT_HTTP__}#g" \
              -e "${NO_TUNNEL:+/# tunnel begin/,/# tunnel end/d}" \
              -e "${RELAY_ALLOW:+s#allow ${RELAY_IP};#${RELAY_ALLOW}#g}" \
        > "$tmp"
    [ -s "$tmp" ] || die "payload $name is empty - is this file complete?"
    # Whether this file was ours or already here decides what uninstall does
    # with it: delete, or put the original back. Work it out before writing.
    note_file "$dest"
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"; info "$dest unchanged"; return 1
    fi
    backup_file "$dest"
    mv "$tmp" "$dest"; chmod 644 "$dest"; info "wrote $dest"
    return 0
}

# Set KEY=VALUE in a shell-style config file, replacing the line if it is
# already there and appending it if not. Used for the panel's config, which the
# operator is expected to edit by hand as well.
set_env_key() {
    local file="$1" key="$2" value="$3" tmp
    tmp="$(mktemp)"
    grep -v "^${key}=" "$file" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Record a fact about this install, one "key value" per line.
remember() { mkdir -p "$STATE_DIR"; printf '%s %s\n' "$1" "$2" >> "$STATE"; }
recall()   { [ -f "$STATE" ] && awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print }' "$STATE"; }
# The same, on one line. The membership tests below look for a value with a
# space on either side, so a list separated by newlines would only ever match
# its first entry - which is exactly what went wrong: on the second run every
# file this script had created was reclassified as somebody else's.
recall_flat() { recall "$1" | tr '\n' ' '; }

# Enable a service, but only record it as ours if it was not already enabled.
# Uninstall stops what is on that list, and stopping an nginx that was serving
# somebody's website before we arrived would be a real outage caused by our
# cleanup. Restoring its config is ours to undo; its running state is not.
#
# The second argument names the package that provides the unit. Leave it out
# for units this script writes itself, which are ours by construction.
enable_service() {
    local svc="$1" pkg="${2:-}" was ours=no

    # A second run finds our own services already enabled, so the test at the
    # bottom would decide they belong to someone else and uninstall would leave
    # dnsmasq and coturn running for ever. What *this* run enabled is not the
    # question; what any run of this script enabled is.
    case " ${PREV_SERVICES:-} " in *" $svc "*) ours=yes ;; esac

    # Debian enables dnsmasq and coturn the moment they are unpacked, so by the
    # time we get here the "was it already enabled" test says yes even though
    # the package arrived thirty seconds ago on our own apt-get line. If we
    # installed the package, the service is ours.
    if [ -n "$pkg" ]; then
        case " ${NEW_PACKAGES:-} " in *" $pkg "*) ours=yes ;; esac
    else
        ours=yes
    fi

    was="$(systemctl is-enabled "$svc" 2>/dev/null || true)"
    systemctl enable "$svc" >/dev/null 2>&1 || true
    { [ "$ours" = yes ] || [ "$was" != enabled ]; } && remember services-enabled "$svc"
    return 0
}

# ------------------------------------------------------------------ tunnel
# An optional tunnel between the relay and the exit, carried by BackPack - the
# work of Amin Mohammadi (github.com/AminMGMT/BackPack, AGPL-3.0). Its binary is
# fetched from his own releases when asked for and checked against the hashes
# pinned here - never copied into this project, and never a version nobody here
# has tried.
BACKPACK_VERSION="v1.8.0"
BACKPACK_SHA_amd64="0fca707e413c0ca051fac1bf47a8f5bc870bc54a67866415b75fd93fbd91f9b8"
BACKPACK_SHA_arm64="b93d4b1c76d44e2168a66f7e3e27173b07682d012b3cdf3917f768ea7064a764"
BACKPACK_BIN=/usr/local/lib/smart-dns/backpack
TUNNEL_DIR=/etc/smart-dns/tunnel
TUNNEL_NFT=/etc/nftables.d/40-smartdns-tunnel.conf
# The tunnel's end on the relay, on loopback only: nginx points here, and
# nothing outside the machine can reach either port.
TUNNEL_LOCAL_HTTPS=18443
TUNNEL_LOCAL_HTTP=18080
# Which transports each direction has. A direct tunnel has four; BackPack's
# spoofing carrier is a different kind of tunnel and is not offered.
TUNNEL_REVERSE_TRANSPORTS="stealth wss wssmux tcp tcpmux kcp pck quic ws wsmux xdi udp"
TUNNEL_DIRECT_TRANSPORTS="stealth wss tcp ws"

tunnel_transport_ok() {
    local list="$TUNNEL_REVERSE_TRANSPORTS"
    [ "$1" = direct ] && list="$TUNNEL_DIRECT_TRANSPORTS"
    case " $list " in *" $2 "*) return 0 ;; esac
    return 1
}

# Why a port cannot carry the tunnel, or nothing when it can. The same ports
# the admin panel may not take, and the relay's own besides.
tunnel_port_problem() {
    local p="$1" admin
    case "$p" in *[!0-9]*|"") echo "not a number"; return 0 ;; esac
    { [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; } || { echo "not a port"; return 0; }
    case "$p" in
        22) echo "ssh" ;;
        53) echo "dns" ;;
        80|443) echo "the proxy" ;;
        8443) echo "the sync API and the customer panel" ;;
        8446) echo "the exit's route to Google over IPv6" ;;
        8402) echo "where certificates are proved" ;;
        3478) echo "STUN on the relay" ;;
        "$TUNNEL_LOCAL_HTTPS"|"$TUNNEL_LOCAL_HTTP") echo "the tunnel's own end on the relay" ;;
    esac
    { [ "$p" -ge 5300 ] && [ "$p" -le 5399 ]; } && echo "the templates' resolvers on the relay"
    admin="$(sed -n 's/^ADMIN_PORT=//p' /etc/smart-dns/admin.env 2>/dev/null | head -1 || true)"
    [ -n "$admin" ] && [ "$p" = "$admin" ] && echo "the admin panel"
    return 0
}

# bp-stealth-8444-r: what the exit chose, carried to the relay inside the
# pairing token so the two ends are never set up differently.
parse_tunnel_spec() {
    local s="$1" d
    case "$s" in bp-*-*-[rd]) ;; *) return 1 ;; esac
    s="${s#bp-}"; d="${s##*-}"; s="${s%-*}"
    TUNNEL_PORT="${s##*-}"; TUNNEL_TRANSPORT="${s%-*}"
    if [ "$d" = r ]; then TUNNEL_DIRECTION=reverse; else TUNNEL_DIRECTION=direct; fi
    tunnel_transport_ok "$TUNNEL_DIRECTION" "$TUNNEL_TRANSPORT" || return 1
    [ -z "$(tunnel_port_problem "$TUNNEL_PORT")" ] || return 1
    TUNNEL=backpack
}

# Both ends derive the tunnel's token from the secret they already share, so
# there is nothing new to copy between them.
tunnel_token() { printf 'doctor-dns-tunnel:%s' "$1" | sha256sum | cut -c1-48; }

ask_tunnel() {
    local a list="" i=0 t note
    # What this machine has now, when there is one, is the answer enter gives:
    # asking again with --tunnel and changing only the port should take one
    # line typed, not four.
    local d1=1 d2=1 d3=1
    [ "${CUR_TUNNEL:-}" = backpack ] && d1=2
    [ "${CUR_DIRECTION:-}" = direct ] && d2=2
    printf '\n%sBetween the relay and this exit%s\n\n' "$B" "$N"
    if [ "${CUR_TUNNEL:-}" = backpack ]; then
        printf '  now: BackPack, %s, %s, port %s\n\n' "${CUR_TRANSPORT:-?}" "${CUR_DIRECTION:-?}" "${CUR_PORT:-?}"
    elif [ -n "${CUR_TUNNEL:-}" ]; then
        printf '  now: direct TCP\n\n'
    fi
    printf '  1) direct TCP        as it has always been - nothing extra installed\n'
    printf '  2) BackPack tunnel   hides the names of the sites from filtering on the way\n\n'
    read -r -p "  choice [$d1]: " a
    case "${a:-$d1}" in 1) TUNNEL=off; return 0 ;; 2) TUNNEL=backpack ;; *) die "answer 1 or 2" ;; esac
    printf '\n  Which end dials the other?\n\n'
    printf '  1) reverse   this exit dials the relay - BackPack'"'"'s usual way\n'
    printf '  2) direct    the relay dials this exit - for where connections into Iran do not\n'
    printf '               get through\n\n'
    read -r -p "  choice [$d2]: " a
    case "${a:-$d2}" in 1) TUNNEL_DIRECTION=reverse ;; 2) TUNNEL_DIRECTION=direct ;; *) die "answer 1 or 2" ;; esac
    # What each transport is. How one performs depends on the route, so that is
    # not said here; only the two that did not connect at all in our own test
    # say so.
    printf '\n  Transport:\n\n'
    while IFS='|' read -r t note; do
        tunnel_transport_ok "$TUNNEL_DIRECTION" "$t" || continue
        i=$((i + 1)); list="$list $t"
        [ "$t" = "${CUR_TRANSPORT:-}" ] && d3=$i
        printf '  %2d) %-8s %s\n' "$i" "$t" "$note"
    done <<'NOTES'
stealth|encrypted, looks like random bytes - recommended
wss|looks like an ordinary HTTPS website
wssmux|the same over a few pooled connections
wsmux|websocket, pooled - not encrypted: site names show
ws|websocket - not encrypted: site names show
tcp|plain - not encrypted: site names show
tcpmux|plain and pooled - not encrypted: site names show
kcp|over UDP, for a route that loses packets
pck|for a route where TCP connects, then dies
xdi|inside ping - for where only ping gets through
quic|over UDP - did not connect in our test
udp|raw datagrams, no reliability - did not connect in our test
NOTES
    printf '\n'
    read -r -p "  choice [$d3]: " a
    a="${a:-$d3}"
    case "$a" in *[!0-9]*) die "answer with the number" ;; esac
    # shellcheck disable=SC2086
    TUNNEL_TRANSPORT="$(echo $list | cut -d' ' -f"$a")"
    [ -n "$TUNNEL_TRANSPORT" ] || die "there is no transport number $a"
    while :; do
        read -r -p "  tunnel port [${CUR_PORT:-8444}]: " a
        a="${a:-${CUR_PORT:-8444}}"
        t="$(tunnel_port_problem "$a")"
        [ -z "$t" ] && { TUNNEL_PORT="$a"; break; }
        warn "port $a cannot carry the tunnel: $t - pick another"
    done
    if [ "$TUNNEL_DIRECTION" = reverse ]; then
        info "open port $TUNNEL_PORT to this exit in the relay's firewall, if it has one"
    else
        info "open port $TUNNEL_PORT to the relay in this exit's firewall, if it has one"
    fi
}

# Fetch the pinned BackPack, or take it from BACKPACK_TARBALL. Refuses anything
# whose hash does not match. Returns non-zero, having said why, on failure.
install_backpack() {
    local arch sha tmp
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) warn "BackPack has no build for $(uname -m) in this installer"; return 1 ;;
    esac
    eval "sha=\$BACKPACK_SHA_$arch"
    if [ -x "$BACKPACK_BIN" ] && [ "$(cat "$BACKPACK_BIN.version" 2>/dev/null)" = "$BACKPACK_VERSION $sha" ]; then
        info "BackPack $BACKPACK_VERSION already here"
        return 0
    fi
    tmp="$(mktemp -d)"
    if [ -n "${BACKPACK_TARBALL:-}" ]; then
        cp "$BACKPACK_TARBALL" "$tmp/bp.tgz" || { warn "cannot read $BACKPACK_TARBALL"; rm -rf "$tmp"; return 1; }
    elif ! curl -fsSL -m 300 -o "$tmp/bp.tgz" \
            "https://github.com/AminMGMT/BackPack/releases/download/$BACKPACK_VERSION/backpack_linux_$arch.tar.gz"; then
        warn "could not download BackPack from GitHub. Without internet, fetch"
        warn "backpack_linux_$arch.tar.gz ($BACKPACK_VERSION) elsewhere and run with"
        warn "    BACKPACK_TARBALL=/path/to/it"
        rm -rf "$tmp"; return 1
    fi
    if [ "$(sha256sum "$tmp/bp.tgz" | cut -d' ' -f1)" != "$sha" ]; then
        warn "that BackPack archive does not match the hash pinned for $BACKPACK_VERSION - not installing it"
        rm -rf "$tmp"; return 1
    fi
    tar -xzf "$tmp/bp.tgz" -C "$tmp" 2>/dev/null
    [ -f "$tmp/backpack" ] || { warn "no backpack binary in that archive"; rm -rf "$tmp"; return 1; }
    mkdir -p "$(dirname "$BACKPACK_BIN")"
    note_file "$BACKPACK_BIN"
    note_file "$BACKPACK_BIN.version"
    install -m 755 "$tmp/backpack" "$BACKPACK_BIN"
    printf '%s %s\n' "$BACKPACK_VERSION" "$sha" > "$BACKPACK_BIN.version"
    rm -rf "$tmp"
    info "BackPack $BACKPACK_VERSION installed, its hash checked"
    info "BackPack is the work of Amin Mohammadi - github.com/AminMGMT/BackPack (AGPL-3.0)"
}

# The tunnel's config for this end, on stdout.
tunnel_toml() {
    local token c="" k=""
    token="$(tunnel_token "$1")"
    # wss on the listening end wants a certificate: the machine's own if it has
    # a domain, a self-signed one if not. The other end does not verify it -
    # BackPack proves the token inside the TLS session instead.
    case "$TUNNEL_TRANSPORT" in wss|wssmux)
        if [ -n "${PANEL_DOMAIN:-}" ] && [ -f "/etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem" ]; then
            c="/etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem"; k="/etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem"
        else
            c="$TUNNEL_DIR/tls.crt"; k="$TUNNEL_DIR/tls.key"
            [ -f "$c" ] || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
                -subj "/CN=${PANEL_DOMAIN:-localhost}" -keyout "$k" -out "$c" >/dev/null 2>&1 || true
        fi ;;
    esac
    printf '# written by the doctor dns installer - re-run it to change the tunnel\n'
    if [ "$TUNNEL_DIRECTION" = reverse ] && [ "$ROLE" = relay ]; then
        printf '[server]\nbind_addr = "0.0.0.0:%s"\n' "$TUNNEL_PORT"
        printf 'ports = ["127.0.0.1:%s=443", "127.0.0.1:%s=80"]\n' "$TUNNEL_LOCAL_HTTPS" "$TUNNEL_LOCAL_HTTP"
        [ -n "$c" ] && printf 'tls_cert = "%s"\ntls_key = "%s"\n' "$c" "$k"
    elif [ "$TUNNEL_DIRECTION" = reverse ]; then
        printf '[client]\nremote_addr = "%s:%s"\n' "$RELAY_IP" "$TUNNEL_PORT"
    elif [ "$ROLE" = relay ]; then
        printf '[direct]\nrole = "iran"\naddr = "%s:%s"\n' "$EXIT_IP" "$TUNNEL_PORT"
        printf 'ports = ["127.0.0.1:%s=443", "127.0.0.1:%s=80"]\n' "$TUNNEL_LOCAL_HTTPS" "$TUNNEL_LOCAL_HTTP"
    else
        printf '[direct]\nrole = "kharej"\naddr = "0.0.0.0:%s"\n' "$TUNNEL_PORT"
        [ -n "$c" ] && printf 'tls_cert = "%s"\ntls_key = "%s"\n' "$c" "$k"
    fi
    printf 'transport = "%s"\ntoken = "%s"\n' "$TUNNEL_TRANSPORT" "$token"
    # The reverse engine's own extras: no web panel, no kernel tuning of its
    # own, and a log at the level journald is read at.
    if [ "$TUNNEL_DIRECTION" = reverse ]; then
        printf 'web_port = 0\nskip_optz = true\nlog_level = "info"\n'
    fi
}

# Bring this end of the tunnel to what TUNNEL says, or take it down.
apply_tunnel() {
    local secret="$1" tmp changed=0 peer
    if [ "${TUNNEL:-off}" != backpack ]; then
        if [ -f /etc/systemd/system/smartdns-tunnel.service ]; then
            systemctl disable --now smartdns-tunnel.service >/dev/null 2>&1 || true
            info "no tunnel - the relay reaches the exit directly"
        fi
        # The whole directory: BackPack keeps its metrics beside the config.
        rm -f "$TUNNEL_NFT"
        rm -rf "$TUNNEL_DIR"
        nft delete table inet smartdns_tunnel >/dev/null 2>&1 || true
        return 0
    fi
    step "Tunnel: BackPack $BACKPACK_VERSION - $TUNNEL_TRANSPORT, $TUNNEL_DIRECTION, port $TUNNEL_PORT"
    if [ -z "$secret" ]; then
        warn "no pairing, so no tunnel - the relay reaches the exit directly"
        TUNNEL=off; return 0
    fi
    mkdir -p "$TUNNEL_DIR"; chmod 700 "$TUNNEL_DIR"
    note_file "$TUNNEL_DIR/tunnel.toml"
    tmp="$(mktemp)"
    tunnel_toml "$secret" > "$tmp"
    cmp -s "$tmp" "$TUNNEL_DIR/tunnel.toml" || changed=1
    install -m 600 "$tmp" "$TUNNEL_DIR/tunnel.toml"; rm -f "$tmp"
    # The end that listens lets the other machine in and nobody else. Loaded
    # by the service itself as well, so it holds on a machine whose nftables
    # service does not read /etc/nftables.d.
    if { [ "$ROLE" = relay ] && [ "$TUNNEL_DIRECTION" = reverse ]; } \
       || { [ "$ROLE" = exit ] && [ "$TUNNEL_DIRECTION" = direct ]; }; then
        if [ "$ROLE" = relay ]; then peer="$EXIT_IP"; else peer="$RELAY_IP"; fi
        mkdir -p /etc/nftables.d
        note_file "$TUNNEL_NFT"
        cat > "$TUNNEL_NFT" <<EOF
# written by the doctor dns installer: the tunnel's port answers $peer only
table inet smartdns_tunnel
delete table inet smartdns_tunnel
table inet smartdns_tunnel {
    chain input {
        type filter hook input priority -5 ; policy accept ;
        tcp dport $TUNNEL_PORT ip saddr != $peer drop
        udp dport $TUNNEL_PORT ip saddr != $peer drop
        meta nfproto ipv6 tcp dport $TUNNEL_PORT drop
        meta nfproto ipv6 udp dport $TUNNEL_PORT drop
    }
}
EOF
        if nft -f "$TUNNEL_NFT" 2>/dev/null; then info "port $TUNNEL_PORT answers $peer only"
        else warn "could not load the tunnel's firewall rule - port $TUNNEL_PORT is open to all"; fi
    else
        rm -f "$TUNNEL_NFT"
        nft delete table inet smartdns_tunnel >/dev/null 2>&1 || true
    fi
    install_payload TUNNEL_SERVICE /etc/systemd/system/smartdns-tunnel.service && changed=1 || true
    systemctl daemon-reload
    enable_service smartdns-tunnel.service
    if [ "$changed" = 1 ] || ! systemctl is-active --quiet smartdns-tunnel.service; then
        systemctl restart smartdns-tunnel.service
    fi
    sleep 2
    if systemctl is-active --quiet smartdns-tunnel.service; then info "tunnel service running"
    else warn "the tunnel service did not start - journalctl -u smartdns-tunnel"; fi
}

# Classify a file we are about to write. "replaced" means something was already
# there and uninstall should put it back; "created" means it is ours to delete.
# A re-run must not reclassify: once a file has been recorded as replaced, the
# original still belongs to whoever had it first, even though by now the file on
# disk is ours.
note_file() {
    local f="$1"
    case " $(recall_flat files-created) $(recall_flat files-replaced) " in
        *" $f "*) return 0 ;;
    esac
    case " ${PREV_REPLACED:-} " in
        *" $f "*) remember files-replaced "$f"; return 0 ;;
    esac
    # And a file an earlier run created is still ours to delete. Without this
    # the test below sees a file that exists, concludes it belongs to the
    # machine's owner, and uninstall then tries to restore a backup that was
    # never taken - leaving every config we wrote behind for good.
    case " ${PREV_CREATED:-} " in
        *" $f "*) remember files-created "$f"; return 0 ;;
    esac
    if [ -e "$f" ]; then remember files-replaced "$f"
    else remember files-created "$f"; fi
}

# --------------------------------------------------------------- questions?
# Answered before the preflight, because neither one touches the machine and
# neither has any business demanding root. Asking a script what version it is
# and being told to use sudo is the kind of small rudeness that makes people
# stop asking.
case "${1:-}" in
    --version|-V) printf '%s\n' "$VERSION"; exit 0 ;;
    --help|-h)
        printf 'doctor dns %s\n\n' "$VERSION"
        printf 'usage: sudo bash %s [--uninstall | --tunnel]\n\n' "$0"
        printf '  no arguments   install or update this machine\n'
        printf '  --uninstall    put it back as it was\n'
        printf '  --tunnel       choose the tunnel between relay and exit again, then update\n'
        printf '  --version      print the version of this file\n'
        printf '\nenvironment (sudo does not pass these, put them after it):\n'
        printf '  ASSUME_YES=1   take the default for every question\n'
        printf '  ENFORCE=no     leave a relay open to everyone\n'
        printf '  TUNNEL=backpack|off  TUNNEL_TRANSPORT=stealth  TUNNEL_DIRECTION=reverse|direct\n'
        printf '  TUNNEL_PORT=8444     the tunnel between relay and exit, asked on the exit\n'
        printf '  BACKPACK_TARBALL=/path/backpack_linux_amd64.tar.gz   BackPack without GitHub\n'
        exit 0 ;;
esac

# ---------------------------------------------------------------- preflight
[ "$(id -u)" = 0 ] || die "run as root:  sudo bash $0"
[ -r "$SELF" ] && [ -n "$(payload SYSCTL)" ] || die "cannot read my own payloads.
    Download this file and run it directly. Piping it into bash will not work,
    because the configs are stored inside the script itself."
# A download that stopped early is still a runnable script. Everything below
# `exit 0` is a comment, so bash parses half a file quite happily and would
# then set the machine up with configs silently missing - which is worse than
# not running at all. A whole one ends on one exact line the build writes after
# the last payload, and only an exact match will do: a cut that landed just
# after the terminator of a payload in the middle, or half way through one -
# "#__END_ACL_SAVE_S" - passed the looser test this used to be, and went on to
# install with twenty configs missing.
[ "$(tail -n 1 "$SELF")" = "#__DOCTOR_DNS_COMPLETE__" ] || die "this file is incomplete - the
    copy stopped early. Copy doctor-dns.sh to this machine again, from the
    releases of https://github.com/AmirhosseinAshouri/doctor-dns-private" 
command -v apt-get >/dev/null 2>&1 || die "this installer expects Debian or Ubuntu"

# ---------------------------------------------------------------- uninstall
# Undoes exactly what the state file says this script did, and nothing else.
# Anything it is unsure about is left alone and reported, because a leftover
# file is a nuisance while a wrongly deleted one is an outage.
uninstall() {
    [ -f "$STATE" ] || die "no record of an install at $STATE.
    Either this machine was never set up by this script, or the state file is
    gone. Refusing to guess what to remove."

    local role packages
    role="$(recall role)"
    packages="$(recall packages-installed)"

    printf '\n%sAbout to remove the smart DNS from this machine.%s\n\n' "$B" "$N"
    printf '    installed as : %s on %s\n' "$role" "$(recall installed-at)"
    printf '    will restore : nginx config, and stop the services set up here\n'
    printf '    will delete  : the config files, helper commands and timers added\n'
    if [ -n "$packages" ]; then
        printf '    will NOT remove these packages, in case something else needs them:\n'
        printf '                   %s\n' "$packages"
    fi
    printf '    backups kept : %s\n\n' "$BACKUP_DIR"
    if [ -z "${ASSUME_YES:-}" ]; then
        read -r -p "  proceed? [y/N]: " ok
        case "$ok" in y|Y|yes) ;; *) die "cancelled" ;; esac
    fi

    step "Stopping services"
    local svc
    for svc in $(recall services-enabled); do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" >/dev/null 2>&1 || true
        info "stopped and disabled $svc"
    done

    step "Removing files this install created"
    local f
    for f in $(recall files-created); do
        if [ -e "$f" ]; then rm -f "$f"; info "removed $f"; fi
    done

    step "Restoring files this install replaced"
    for f in $(recall files-replaced); do
        # The oldest backup is the state the machine was in before we touched
        # it; later ones are just our own edits over time.
        local original
        # `|| true` is load-bearing. Under `set -e` with pipefail, a glob that
        # matches nothing makes ls exit non-zero and takes the whole uninstall
        # down without a word, halfway through - which is precisely how the
        # missing carry-over below first showed itself.
        original="$(ls -1 "$BACKUP_DIR/$(basename "$f")".* 2>/dev/null | head -1 || true)"
        if [ -n "$original" ] && [ -f "$original" ]; then
            cp -a "$original" "$f"; info "restored $f from $(basename "$original")"
        else
            warn "no backup found for $f - left as it is"
        fi
    done

    step "Swap"
    # Only a swap file this script created, and only if it is still the one
    # recorded - never a swap file that was already on the machine.
    if [ -n "$(recall swapfile)" ] && [ -f /swapfile ]; then
        swapoff /swapfile 2>/dev/null || true
        sed -i '\#^/swapfile #d' /etc/fstab 2>/dev/null || true
        rm -f /swapfile
        info "removed the swap file this installer created"
    fi

    step "Removing the firewall table"
    export PATH="$PATH:/usr/sbin"
    if nft list table inet smartdns >/dev/null 2>&1; then
        nft delete table inet smartdns; info "removed the nftables table"
    fi
    if nft list table inet smartdns_tunnel >/dev/null 2>&1; then
        nft delete table inet smartdns_tunnel; info "removed the tunnel's firewall table"
    fi
    if nft list table inet smartdns_api >/dev/null 2>&1; then
        nft delete table inet smartdns_api; info "removed the sync API's firewall table"
    fi
    # 10- is recorded in the state file and goes with the other created files.
    # 20- and 30- are not: smartdns-acl writes them at runtime, long after the
    # install, so nothing recorded them. The allowlist in 20- is worth keeping,
    # so it moves to the backups rather than being deleted - reinstalling and
    # discovering every customer's registered address is gone would be a poor
    # way to learn that uninstall is destructive.
    if [ -f /etc/nftables.d/20-smartdns-state.conf ]; then
        backup_file /etc/nftables.d/20-smartdns-state.conf
        rm -f /etc/nftables.d/20-smartdns-state.conf
        info "allowlist kept in $BACKUP_DIR"
    fi
    rm -f /etc/nftables.d/30-smartdns-enforce.conf
    rm -f /etc/nftables.d/smartdns.conf

    step "Panel"
    # /etc/smart-dns holds the bot token, the shared secret and the sync
    # certificate. Deleting them outright would mean re-pairing every relay
    # after an uninstall that was only meant to move things around, so they go
    # to the backups instead.
    if [ -d /etc/smart-dns ]; then
        mkdir -p "$BACKUP_DIR"
        cp -a /etc/smart-dns "$BACKUP_DIR/smart-dns-config.$STAMP"
        rm -rf /etc/smart-dns
        info "credentials moved to $BACKUP_DIR/smart-dns-config.$STAMP"
    fi
    # The database is the customers, their balances and their usage. It is
    # never deleted by an uninstall, and it is not moved either, so that
    # reinstalling on the same machine simply picks it up again.
    if [ -f "$STATE_DIR/panel.db" ]; then
        info "database left where it is: $STATE_DIR/panel.db"
    fi

    step "Restarting what is left"
    systemctl daemon-reload
    # nginx is only left running if it was already enabled before we arrived,
    # i.e. it is not on the list we just disabled. In that case it now has its
    # original config back and should be put back into service.
    case " $(recall_flat services-enabled) " in
        *" nginx "*) info "nginx was installed here by this script - left stopped" ;;
        *)
            if nginx -t >/dev/null 2>&1; then
                systemctl restart nginx; info "nginx restarted with its original config"
            else
                warn "the restored nginx config does not parse - nginx left alone"
            fi ;;
    esac

    rm -f "$STATE"
    # The version note goes with the state it describes. Left behind, it would
    # tell a later install that this machine already runs a version whose
    # files are no longer here, and that install would skip its own upgrade
    # question on the strength of it.
    rm -f "$STATE_DIR/version"
    # Only if nothing else put anything there; never blow away a
    # directory a later stage of this project may be using.
    rmdir "$STATE_DIR" 2>/dev/null || true
    printf '\n%sRemoved.%s Backups are still in %s if you want anything back.\n\n' "$G" "$N" "$BACKUP_DIR"
    if [ -n "$packages" ]; then
        printf '    To also remove the packages it installed:\n\n'
        printf '        apt-get purge %s\n\n' "$packages"
    fi
    exit 0
}

# --version and --help were answered above, before the preflight.
case "${1:-}" in
    --uninstall|-u|uninstall) uninstall ;;
    # Asked on the exit, carried to the relay by the pairing token - see the
    # tunnel section below.
    --tunnel|tunnel) ASK_TUNNEL=1 ;;
    "") ;;
    *) die "unknown argument: $1  (try --help)" ;;
esac

# ---------------------------------------------------------------- version
# Nothing below has touched the machine yet, and the answer here decides
# whether anything will. Two cases are worth stopping for: an upgrade, which
# the operator should know is happening rather than discover afterwards, and
# the reverse - an older file run over a newer install, which is nearly always
# somebody re-running a download they still had lying around.
VERSION_FILE="$STATE_DIR/version"
INSTALLED_VERSION=""
[ -f "$VERSION_FILE" ] && INSTALLED_VERSION="$(head -1 "$VERSION_FILE" | tr -d "[:space:]")" || true

# The customer database, the settings, the sync secret and any certificate all
# live outside the files this script writes, and every payload it does write is
# backed up before it is replaced. So an upgrade keeps them - but "keeps them"
# is a promise worth a copy behind it, taken before anything starts.
snapshot_db() {
    local db="$STATE_DIR/panel.db" out
    [ -f "$db" ] || return 0
    mkdir -p "$BACKUP_DIR"
    out="$BACKUP_DIR/panel.db.$STAMP"
    # VACUUM INTO, not cp: the panel keeps a write-ahead log beside the file,
    # so a plain copy of the file alone can be a database missing its newest
    # rows. Falls back to cp where sqlite is too old to know the statement.
    if python3 - "$db" "$out" <<'PY' 2>/dev/null
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("VACUUM INTO ?", (sys.argv[2],))
db.close()
PY
    then
        info "database copied to $out"
    elif cp -a "$db" "$out" 2>/dev/null; then
        warn "database copied to $out (plain copy - sqlite here is old)"
    else
        die "could not copy the database at $db. Fix that before upgrading."
    fi
}

if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" != "$VERSION" ]; then
    older="$(printf '%s\n%s\n' "$INSTALLED_VERSION" "$VERSION" | sort -V | head -1)"
    printf '\n%sVersion%s\n\n' "$B" "$N"
    info "installed on this machine:  $INSTALLED_VERSION"
    info "this file:                  $VERSION"
    printf '\n'
    if [ "$older" = "$VERSION" ]; then
        warn "this file is OLDER than what is installed."
        warn "installing it will put old configs over new ones, and this"
        warn "script has no way to undo what a later version did."
        warn "the newest is in the releases of github.com/AmirhosseinAshouri/doctor-dns-private"
        answer=n
    else
        warn "this will upgrade this machine from $INSTALLED_VERSION to $VERSION."
        answer=y
    fi
    warn "your customers, settings, certificates and allowlist are kept."
    printf '\n'
    if [ -z "${ASSUME_YES:-}" ]; then
        read -r -p "  go ahead? [$answer]: " reply
        # An answer piped in from a file written on Windows arrives with
        # a carriage return attached, and a "y" with one glued on
        # matches nothing below.
        reply="$(printf '%s' "$reply" | tr -d '\r')"
        reply="${reply:-$answer}"
    else
        reply="$answer"
        info "ASSUME_YES - taking '$answer'"
    fi
    case "$reply" in
        y|Y|yes|YES) ;;
        *) printf '\n    Nothing was changed.\n\n'; exit 0 ;;
    esac
    snapshot_db
elif [ -n "$INSTALLED_VERSION" ]; then
    info "already at $VERSION - re-running to check and repair"
fi

# An upgrade asks nothing the machine already knows. Every answer the first
# install was given is still here: the state file records the role and both
# addresses on every run, and the domain sits in the config the panel serves
# from. So an upgrade reads them back, keeps the one-time choices - swap, BBR -
# exactly as they are, and the only question it has is the one above: whether
# to install this version at all. It used to walk the whole questionnaire
# again, addresses and all, as if the machine had never been set up.
UPGRADE=""
if [ -n "$INSTALLED_VERSION" ]; then
    UPGRADE=1
    was() { recall "$1" 2>/dev/null | tail -1 || true; }
    ROLE="${ROLE:-$(was role)}"
    if [ -z "$ROLE" ]; then
        if [ -f /etc/smart-dns/sync.env ]; then ROLE=relay
        elif [ -f /etc/smart-dns/panel.env ]; then ROLE=exit
        elif [ -f /etc/smart-dns/exit.env ]; then ROLE=extra
        fi
    fi
    if [ "$ROLE" = relay ]; then
        PEER_IP="${PEER_IP:-$(was exit-ip)}"
        SELF_IP="${SELF_IP:-$(was relay-ip)}"
        # Older state files, or none: the relay's own config has both.
        [ -n "$PEER_IP" ] || PEER_IP="$(sed -n 's/^PANEL_HOST=//p' /etc/smart-dns/sync.env 2>/dev/null | head -1 || true)"
        [ -n "$SELF_IP" ] || SELF_IP="$(sed -n 's/^SELF_IP=//p' /etc/smart-dns/sync.env 2>/dev/null | head -1 || true)"
    elif [ "$ROLE" = exit ]; then
        PEER_IP="${PEER_IP:-$(was relay-ip)}"
        SELF_IP="${SELF_IP:-$(was exit-ip)}"
        # panel.env holds every relay this exit serves, comma separated. Any of
        # them will do here: it is already on the list, so nothing is added.
        [ -n "$PEER_IP" ] || PEER_IP="$(sed -n 's/^RELAY_IP=//p' /etc/smart-dns/panel.env 2>/dev/null | head -1 | cut -d, -f1 || true)"
    elif [ "$ROLE" = extra ]; then
        # Every relay this exit carries for, comma separated, and its own
        # address - kept in exit.env, since the state file records only one.
        [ -n "$PEER_IP" ] || PEER_IP="$(sed -n 's/^RELAY_IP=//p' /etc/smart-dns/exit.env 2>/dev/null | head -1 || true)"
        [ -n "$SELF_IP" ] || SELF_IP="$(sed -n 's/^SELF_IP=//p' /etc/smart-dns/exit.env 2>/dev/null | head -1 || true)"
    fi
    PANEL_DOMAIN="${PANEL_DOMAIN:-$(was panel-domain)}"
    info "upgrading this ${ROLE:-machine} in place - nothing to answer"
fi

# ---------------------------------------------------------------- questions
valid_ip() {
    local ip="$1" part
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a part <<< "$ip"
    for n in "${part[@]}"; do [ "$n" -le 255 ] || return 1; done
}

ROLE="${ROLE:-}"; PEER_IP="${PEER_IP:-}"; SELF_IP="${SELF_IP:-}"

if [ -z "$ROLE" ]; then
    printf '\n%sWhich side is this machine?%s\n\n' "$B" "$N"
    printf '  1) relay       - the server inside Iran, the one clients point their DNS at\n'
    printf '  2) exit        - the server abroad, which reaches the blocked sites, and\n'
    printf '                   keeps the database, the admin panel and the bot\n'
    printf '  3) extra exit  - another server abroad that only carries traffic; add it\n'
    printf '                   in the bot afterwards and customers can choose it\n\n'
    while :; do
        read -r -p "  choice [1/2/3]: " answer
        case "$answer" in
            1|relay) ROLE=relay; break ;;
            2|exit)  ROLE=exit;  break ;;
            3|extra) ROLE=extra; break ;;
            *) warn "answer 1, 2 or 3" ;;
        esac
    done
fi
case "$ROLE" in relay|exit|extra) ;; *) die "ROLE must be relay, exit or extra" ;; esac

if [ -z "$PEER_IP" ]; then
    printf '\n'
    if [ "$ROLE" = relay ]; then
        read -r -p "  public address of the EXIT server abroad: " PEER_IP
    elif [ "$ROLE" = extra ]; then
        read -r -p "  public address of the RELAY server in Iran (several: comma separated): " PEER_IP
    else
        read -r -p "  public address of the RELAY server in Iran: " PEER_IP
    fi
fi
RELAY_ALLOW=""
if [ "$ROLE" = extra ]; then
    # An extra exit may carry traffic for several relays. Every one of them is
    # let in, and nobody else, so it is not an open proxy either.
    PEER_IP="$(printf '%s' "$PEER_IP" | tr -d ' ')"
    for ip in $(printf '%s' "$PEER_IP" | tr ',' ' '); do
        valid_ip "$ip" || die "'$ip' is not an IPv4 address"
        RELAY_ALLOW="${RELAY_ALLOW:+$RELAY_ALLOW }allow $ip;"
    done
    [ -n "$RELAY_ALLOW" ] || die "an extra exit needs the address of at least one relay"
else
    valid_ip "$PEER_IP" || die "'$PEER_IP' is not an IPv4 address"
fi

if [ -z "$SELF_IP" ]; then
    guess="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    printf '\n'
    read -r -p "  public address of THIS server [${guess}]: " SELF_IP
    SELF_IP="${SELF_IP:-$guess}"
fi
valid_ip "$SELF_IP" || die "'$SELF_IP' is not an IPv4 address"
[ "$SELF_IP" != "$PEER_IP" ] || die "both addresses are the same"

if [ "$ROLE" = relay ]; then
    RELAY_IP="$SELF_IP"; EXIT_IP="$PEER_IP"
else
    RELAY_IP="${PEER_IP%%,*}"; EXIT_IP="$SELF_IP"
fi

# ------------------------------------------------------------------ panel
# The panel is optional. Someone who only wants the bypass can leave these
# blank and still get a working pair; the questions are asked here rather than
# halfway through the install so that the whole thing runs unattended after
# this point.
#
# The panel lives on the exit node: it holds the database every relay syncs to,
# and one database is what makes a customer's allowance mean the same thing on
# all of them. The exit builds it unasked; the relay asks for the pairing token
# the exit prints at the end of its own install.
if [ "$ROLE" = relay ] && [ -z "${SYNC_TOKEN:-}" ] && [ -z "${ASSUME_YES:-}" ] && [ -z "$UPGRADE" ]; then
    printf '\n%sPanel%s (optional - press enter to skip)\n\n' "$B" "$N"
    printf '  The exit server prints a pairing token at the end of its install.\n'
    read -r -p "  pairing token: " SYNC_TOKEN
fi
# ------------------------------------------------------------------- TLS
# Optional, like the panel. Without it the claim link is plain http, which
# works but sends the registration token in the clear - anyone on the path can
# take it and register their own address against the user's account.
if [ -z "${PANEL_DOMAIN:-}" ] && [ -z "${ASSUME_YES:-}" ] && [ -z "$UPGRADE" ] \
   && [ "$ROLE" != extra ]; then
    printf '\n%sHTTPS%s (optional - press enter to skip)\n\n' "$B" "$N"
    if [ "$ROLE" = relay ]; then
        printf '  A name pointing at this machine, for the page users open to\n'
        printf '  register their address.\n'
    else
        printf '  A name pointing at this machine, for the admin panel.\n'
    fi
    read -r -p "  domain: " PANEL_DOMAIN
    # Nothing else is asked. The certificate is obtained automatically and the
    # only thing that proves anything is the domain itself - no DNS token, no
    # account, nothing to hand over.
    if [ -n "$PANEL_DOMAIN" ]; then
        printf '\n  A certificate will be obtained for that name automatically.\n'
        printf '  Point the record at this machine first and leave port 80\n'
        printf '  reachable from the internet - that is how it is checked.\n'
    fi
fi

# ------------------------------------------------------------------ tunnel
# How the relay reaches the exit: straight, as it always has, or through a
# BackPack tunnel that hides the names of the sites from filtering on the way.
# The exit is asked, because it is installed first; the relay learns the
# answer from the pairing token, so the two ends cannot disagree. A re-run
# keeps whatever this machine was set up with.
TUNNEL="${TUNNEL:-}"
TUNNEL_SPEC=""
TUNNEL_OUT=""
env_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1 || true; }
# --tunnel: ask again on a machine that is already set up. The exit shows the
# menu with what it has now as the defaults; the relay asks for the exit's new
# pairing token, which carries the answer.
# An extra exit has no tunnel: that runs between a relay and its main exit.
if [ -n "${ASK_TUNNEL:-}" ] && [ -z "$TUNNEL" ] && [ "$ROLE" != extra ]; then
    if [ "$ROLE" = exit ]; then
        CUR_TUNNEL="$(env_get /etc/smart-dns/panel.env TUNNEL)"
        CUR_TRANSPORT="$(env_get /etc/smart-dns/panel.env TUNNEL_TRANSPORT)"
        CUR_DIRECTION="$(env_get /etc/smart-dns/panel.env TUNNEL_DIRECTION)"
        CUR_PORT="$(env_get /etc/smart-dns/panel.env TUNNEL_PORT)"
        ask_tunnel
    elif [ -z "${SYNC_TOKEN:-}" ]; then
        printf '\n%sTunnel%s\n\n' "$B" "$N"
        printf '  Run the installer with --tunnel on the exit first. It prints a new\n'
        printf '  pairing token that carries its answer: paste it here, or press enter\n'
        printf '  to keep the tunnel this relay has now.\n\n'
        read -r -p "  pairing token: " SYNC_TOKEN
    fi
fi
if [ -z "$TUNNEL" ]; then
    if [ "$ROLE" = exit ] && [ -n "$(env_get /etc/smart-dns/panel.env TUNNEL)" ]; then
        TUNNEL="$(env_get /etc/smart-dns/panel.env TUNNEL)"
        TUNNEL_TRANSPORT="${TUNNEL_TRANSPORT:-$(env_get /etc/smart-dns/panel.env TUNNEL_TRANSPORT)}"
        TUNNEL_DIRECTION="${TUNNEL_DIRECTION:-$(env_get /etc/smart-dns/panel.env TUNNEL_DIRECTION)}"
        TUNNEL_PORT="${TUNNEL_PORT:-$(env_get /etc/smart-dns/panel.env TUNNEL_PORT)}"
    elif [ "$ROLE" = relay ]; then
        spec="$(printf '%s' "${SYNC_TOKEN:-}" | cut -s -d. -f3)"
        if [ -n "$spec" ]; then
            parse_tunnel_spec "$spec" || die "the tunnel part of the pairing token, '$spec', is not one this installer knows.
    Install the exit and the relay from the same version of this file."
        elif [ -n "${SYNC_TOKEN:-}" ]; then
            TUNNEL=off          # a two-part token: the exit has no tunnel
        elif [ -n "$(env_get /etc/smart-dns/sync.env TUNNEL)" ]; then
            TUNNEL="$(env_get /etc/smart-dns/sync.env TUNNEL)"
            TUNNEL_TRANSPORT="${TUNNEL_TRANSPORT:-$(env_get /etc/smart-dns/sync.env TUNNEL_TRANSPORT)}"
            TUNNEL_DIRECTION="${TUNNEL_DIRECTION:-$(env_get /etc/smart-dns/sync.env TUNNEL_DIRECTION)}"
            TUNNEL_PORT="${TUNNEL_PORT:-$(env_get /etc/smart-dns/sync.env TUNNEL_PORT)}"
        fi
    fi
fi
if [ "$ROLE" = exit ] && [ -z "$TUNNEL" ] && [ -z "${ASSUME_YES:-}" ] && [ -z "$UPGRADE" ]; then
    ask_tunnel
fi
case "${TUNNEL:-off}" in
    off|no|direct|"") TUNNEL=off ;;
    backpack|on|yes) TUNNEL=backpack ;;
    *) die "TUNNEL must be backpack or off" ;;
esac
if [ "$TUNNEL" = backpack ]; then
    TUNNEL_DIRECTION="${TUNNEL_DIRECTION:-reverse}"
    TUNNEL_TRANSPORT="${TUNNEL_TRANSPORT:-stealth}"
    TUNNEL_PORT="${TUNNEL_PORT:-8444}"
    case "$TUNNEL_DIRECTION" in reverse|direct) ;; *) die "TUNNEL_DIRECTION must be reverse or direct" ;; esac
    tunnel_transport_ok "$TUNNEL_DIRECTION" "$TUNNEL_TRANSPORT" \
        || die "BackPack's $TUNNEL_DIRECTION tunnel has no transport called '$TUNNEL_TRANSPORT'"
    why="$(tunnel_port_problem "$TUNNEL_PORT")"
    [ -z "$why" ] || die "port $TUNNEL_PORT cannot carry the tunnel: $why"
    # The tunnel runs between this relay and its own exit, on a secret only
    # that exit knows - a relay whose panel is on another machine has none.
    if [ "$ROLE" = relay ] && [ -n "${PANEL_IP:-}" ] && [ "$PANEL_IP" != "$EXIT_IP" ]; then
        warn "the panel is on $PANEL_IP, not on this relay's exit - no tunnel"
        TUNNEL=off
    fi
fi
[ "$TUNNEL" = backpack ] && TUNNEL_SPEC="bp-$TUNNEL_TRANSPORT-$TUNNEL_PORT-$(printf '%.1s' "$TUNNEL_DIRECTION")"
if [ "$TUNNEL" = backpack ]; then
    TUNNEL_OUT="BackPack, $TUNNEL_TRANSPORT, $TUNNEL_DIRECTION, port $TUNNEL_PORT"
else
    TUNNEL_OUT="none - the relay reaches the exit directly"
fi

printf '\n%sAbout to configure:%s\n' "$B" "$N"
printf '    role   : %s\n    relay  : %s\n    exit   : %s\n    tunnel : %s\n\n' "$ROLE" "$RELAY_IP" "$EXIT_IP" "$TUNNEL_OUT"
if [ -z "${ASSUME_YES:-}" ] && [ -z "$UPGRADE" ]; then
    read -r -p "  proceed? [y/N]: " ok
    case "$ok" in y|Y|yes) ;; *) die "cancelled" ;; esac
fi

export DEBIAN_FRONTEND=noninteractive
NGINX_CHANGED=0
DNSMASQ_CHANGED=0

# What the run has to tell the operator at the end. Empty here so that the
# summary can read them plainly under `set -u`, whichever paths ran. One of
# these was left unset when the customer panel stopped being served without a
# certificate, and the install died on its very last line - after doing all of
# its work, and before recording that it had.
ADMIN_URL_OUT=""
ADMIN_PASS_OUT=""
SYNC_TOKEN_OUT=""
USER_PANEL_OUT=""
ENFORCE_OUT=""

# Start the record over, but keep what an earlier install already knew: which
# packages were new and which files existed before we ever touched them. Those
# facts are only true the first time, and losing them would make a later
# uninstall unable to tell "we added this" from "this was already here".
mkdir -p "$STATE_DIR"
# Everything an earlier run recorded, read before the state file is rewritten.
# The record has to survive re-installation: by the second run our own files
# exist and our own services are enabled, so a fresh look at the machine can no
# longer tell our work from the owner's.
PREV_PACKAGES="$(recall_flat packages-installed || true)"
PREV_REPLACED="$(recall_flat files-replaced || true)"
PREV_CREATED="$(recall_flat files-created || true)"
PREV_SERVICES="$(recall_flat services-enabled || true)"
: > "$STATE"
remember role "$ROLE"
remember relay-ip "$RELAY_IP"
remember exit-ip "$EXIT_IP"
remember installed-at "$(date -Is)"

# ---------------------------------------------------------------- packages
step "Installing packages"
if [ "$ROLE" = relay ]; then
    WANT="nginx libnginx-mod-stream dnsmasq coturn nftables dnsutils python3 curl"
else
    # nftables for the rule that keeps strangers off the sync API.
    WANT="nginx libnginx-mod-stream dnsutils curl python3 openssl nftables"
fi
# Note what was missing beforehand, so uninstall can name exactly what this
# script added rather than offering to purge nginx from a web server.
if [ -n "$PREV_PACKAGES" ]; then
    NEW_PACKAGES="$(echo "$PREV_PACKAGES" | xargs || true)"
else
    NEW_PACKAGES=""
    for pkg in $WANT; do
        dpkg -s "$pkg" >/dev/null 2>&1 || NEW_PACKAGES="$NEW_PACKAGES $pkg"
    done
    NEW_PACKAGES="$(echo "$NEW_PACKAGES" | xargs || true)"
fi
[ -n "$NEW_PACKAGES" ] && remember packages-installed "$NEW_PACKAGES"
# Only what is missing, and apt is not touched at all when nothing is. It used
# to run apt-get update and reinstall the whole list on every run, which made
# an upgrade slow and quietly upgraded the operator's nginx along the way -
# neither of which an upgrade of this service was asked to do. dpkg-query, not
# dpkg -s: a package removed but not purged still answers dpkg -s happily.
missing=""
for pkg in $WANT; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || missing="$missing $pkg"
done
if [ -n "$missing" ]; then
    apt-get update -qq
    # shellcheck disable=SC2086
    apt-get install -y -qq $missing >/dev/null
    info "installed:$missing"
else
    info "all present"
fi

# ---------------------------------------------------------------- kernel
# ------------------------------------------------------------------- swap
# Off unless asked for: SWAP_GB=2 on the command line, or answer the prompt.
# Worth having on a small box - nginx under a console download opens a lot of
# connections at once, and being killed for it is worse than being slow - but
# it is the operator's disk, so it is never created behind their back.
HAVE_SWAP="$(free -m | awk '/Swap/{print $2}')"
if [ -z "${SWAP_GB:-}" ] && [ -z "${ASSUME_YES:-}" ] && [ -z "$UPGRADE" ]; then
    if [ "${HAVE_SWAP:-0}" = 0 ]; then
        printf '\n%sThis machine has no swap.%s\n\n' "$B" "$N"
        read -r -p "  create a swap file? size in GB, or enter to skip: " SWAP_GB
    else
        # Say so rather than skipping in silence. An operator who expected a
        # question and got nothing cannot tell "already handled" from "the
        # installer forgot", and will go looking - which is exactly what
        # happened the first time somebody ran this on a machine that had swap.
        step "Swap"
        info "already has ${HAVE_SWAP} MB - leaving it alone"
    fi
fi
if [ -n "${SWAP_GB:-}" ] && [ "${SWAP_GB}" != 0 ]; then
    step "Swap file"
    case "$SWAP_GB" in
        *[!0-9]*|"") die "SWAP_GB must be a whole number of gigabytes" ;;
    esac
    if [ -f /swapfile ]; then
        info "/swapfile already exists - leaving it alone"
    else
        avail="$(df --output=avail -BG / | tail -1 | tr -dc '0-9')"
        [ "${avail:-0}" -gt "$((SWAP_GB + 2))" ] \
            || die "only ${avail}G free on / - not creating a ${SWAP_GB}G swap file"
        # fallocate can produce a sparse file, which the kernel refuses to swap
        # to. dd is slower and correct.
        dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB * 1024)) status=none
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        note_file /swapfile
        grep -q '^/swapfile ' /etc/fstab 2>/dev/null \
            || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        remember swapfile "/swapfile"
        info "created and enabled ${SWAP_GB}G of swap"
    fi
fi

step "Kernel tuning for the long-RTT link"
install_payload SYSCTL /etc/sysctl.d/99-smartdns-tuning.conf || true
sysctl -p /etc/sysctl.d/99-smartdns-tuning.conf >/dev/null 2>&1 || true

BBR_FILE=/etc/sysctl.d/99-smartdns-bbr.conf
# Congestion control is machine-wide: it changes every connection on the box,
# including services that have nothing to do with this one. So it is asked for
# rather than assumed. On a non-interactive run the existing choice stands,
# which means an upgrade never silently changes how a working server behaves.
if [ -z "${ENABLE_BBR:-}" ]; then
    if [ -n "${ASSUME_YES:-}" ] || [ -n "$UPGRADE" ]; then
        # Keep whatever the machine is already doing. The running value matters
        # as much as the file: earlier versions set bbr from the main tuning
        # file, so on those machines there is no bbr file to find, and deciding
        # by the file alone would leave the kernel on bbr now and drop it at
        # the next reboot - a change nobody asked for, appearing days later.
        if [ -f "$BBR_FILE" ] || \
           [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ]; then
            ENABLE_BBR=yes
        else
            ENABLE_BBR=no
        fi
    else
        printf '\n    %sBBR congestion control%s\n' "$B" "$N"
        printf '    Paces by measured bandwidth instead of backing off on loss.\n'
        printf '    On a %s ms link it is worth a great deal, but it affects every\n' "90"
        printf '    connection on this machine, not only this service.\n\n'
        read -r -p "    enable BBR? [Y/n]: " answer
        case "$answer" in n|N|no) ENABLE_BBR=no ;; *) ENABLE_BBR=yes ;; esac
    fi
fi
case "$ENABLE_BBR" in
    yes|y|1|true)
        install_payload SYSCTL_BBR "$BBR_FILE" || true
        sysctl -p "$BBR_FILE" >/dev/null 2>&1 || true
        ;;
    no|n|0|false)
        rm -f "$BBR_FILE"
        if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ]; then
            # Only fall back to the kernel default if nothing else on the
            # machine asks for bbr. Someone who set it themselves, in their own
            # file, keeps it - they did not ask this installer to decide.
            if grep -rqs 'tcp_congestion_control' /etc/sysctl.conf /etc/sysctl.d 2>/dev/null; then
                info "BBR left on - another config on this machine sets it"
            else
                sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
                sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
                info "BBR turned off"
            fi
        fi
        ;;
esac
info "congestion=$(sysctl -n net.ipv4.tcp_congestion_control) qdisc=$(sysctl -n net.core.default_qdisc)"

# ---------------------------------------------------------------- nginx
step "nginx"
MOD="$(find /usr/lib/nginx/modules -name ngx_stream_module.so 2>/dev/null | head -1)"
[ -n "$MOD" ] || die "the nginx stream module is missing - libnginx-mod-stream did not install"
info "stream module: $MOD"
# Google refuses Gemini and its other AI services to some exits' IPv4 addresses
# and serves the same pages to the same machine over IPv6, so where the exit
# has working IPv6, Google's own names leave over it. That needs a resolver
# that can be told to ask for AAAA records only, which nginx has from 1.23.1 -
# older, or without IPv6, the block is left out and nothing changes.
NO_GOOGLE_V6=1
if [ "$ROLE" != relay ]; then
    ngv="$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')"
    if [ "$(printf '%s\n%s\n' 1.23.1 "${ngv:-0}" | sort -V | head -1)" = 1.23.1 ] \
       && curl -6 -s -o /dev/null -m 10 https://www.google.com/ 2>/dev/null; then
        NO_GOOGLE_V6=""
        info "Google's own names leave over IPv6 (Gemini is refused to some exits' IPv4)"
    else
        info "no working IPv6 here, or nginx older than 1.23.1 - Google leaves over IPv4"
    fi
fi
# The tunnel's binary comes before nginx, so that a download that fails
# leaves this run on the direct path rather than with nginx pointed at a
# tunnel that will never be there.
if [ "$TUNNEL" = backpack ] && ! install_backpack; then
    warn "no tunnel this run - the relay reaches the exit directly"
    TUNNEL=off; TUNNEL_SPEC=""; TUNNEL_OUT="none - BackPack could not be installed"
fi
if [ "$ROLE" = relay ] && [ "$TUNNEL" = backpack ]; then
    NO_TUNNEL=""; EXIT_HTTPS=to_exit_https; EXIT_HTTP=to_exit_http
else
    NO_TUNNEL=1; EXIT_HTTPS="$EXIT_IP:443"; EXIT_HTTP="$EXIT_IP:80"
fi
if [ "$ROLE" = relay ]; then
    # The map of which exit each customer leaves by, which nginx.conf includes.
    # smartdns-sync keeps it from here on. Written now with only the default,
    # so nginx has something to load, and again whenever the default itself
    # changes - a tunnel switched on or off - which the sync then fills back in
    # within a minute.
    note_file /etc/nginx/smartdns-exits.conf
    if ! grep -qsF "default ${EXIT_HTTPS};" /etc/nginx/smartdns-exits.conf; then
        printf '# written by the installer; smartdns-sync keeps it from here\nmap $remote_addr $smartdns_exit_https {\n    default %s;\n}\nmap $remote_addr $smartdns_exit_http {\n    default %s;\n}\n' \
            "$EXIT_HTTPS" "$EXIT_HTTP" > /etc/nginx/smartdns-exits.conf
        NGINX_CHANGED=1
    fi
    install_payload RELAY_NGINX /etc/nginx/nginx.conf && NGINX_CHANGED=1 || true
else
    install_payload EXIT_NGINX /etc/nginx/nginx.conf && NGINX_CHANGED=1 || true
fi
nginx -t || die "nginx rejected the config; the previous one is in $BACKUP_DIR"
enable_service nginx nginx

# ---------------------------------------------------------------- relay only
if [ "$ROLE" = relay ]; then

    step "dnsmasq: the routed domain list"
    note_file /etc/dnsmasq.d/smart-dns.conf
    tmp="$(mktemp)"
    {
        # No timestamp in here. It would make the file differ on every run, so
        # every run would rewrite it and restart dnsmasq for no reason.
        printf '# generated by the smart-dns installer - do not edit by hand\n'
        printf 'no-resolv\nserver=1.1.1.1\nserver=8.8.8.8\nserver=9.9.9.9\n'
        printf 'cache-size=10000\ndomain-needed\nbogus-priv\nno-hosts\n'
        printf 'bind-interfaces\nlisten-address=127.0.0.1,%s\n\n' "$RELAY_IP"
        printf '# domains answered with this relay, so the traffic leaves via the exit\n'
        payload DOMAINS | while read -r d; do
            [ -n "$d" ] && printf 'address=/%s/%s\n' "$d" "$RELAY_IP"
        done
    } > "$tmp"
    if [ -f /etc/dnsmasq.d/smart-dns.conf ] && cmp -s "$tmp" /etc/dnsmasq.d/smart-dns.conf; then
        rm -f "$tmp"; info "unchanged ($(grep -c '^address=' /etc/dnsmasq.d/smart-dns.conf) domains)"
    else
        backup_file /etc/dnsmasq.d/smart-dns.conf
        mv "$tmp" /etc/dnsmasq.d/smart-dns.conf; chmod 644 /etc/dnsmasq.d/smart-dns.conf
        info "wrote $(grep -c '^address=' /etc/dnsmasq.d/smart-dns.conf) domains"
        DNSMASQ_CHANGED=1
    fi

    step "dnsmasq: names that must NOT be routed"
    install_payload BYPASS /etc/dnsmasq.d/bypass.conf && DNSMASQ_CHANGED=1 || true
    rm -f /etc/dnsmasq.d/ea-bypass.conf   # superseded filename from an earlier build

    step "dnsmasq: stop AAAA answers routing clients around us"
    install_payload NO_AAAA /etc/dnsmasq.d/no-aaaa.conf && DNSMASQ_CHANGED=1 || true

    dnsmasq --test -C /etc/dnsmasq.conf || die "dnsmasq rejected the config"
    enable_service dnsmasq dnsmasq

    step "STUN server, so consoles can still detect their NAT"
    install_payload TURNSERVER /etc/turnserver.conf || true
    grep -q '^TURNSERVER_ENABLED=1' /etc/default/coturn 2>/dev/null \
        || echo 'TURNSERVER_ENABLED=1' >> /etc/default/coturn
    enable_service coturn coturn
    systemctl restart coturn || warn "coturn did not start; STUN will be unavailable"

    step "Firewall: rate limit, access control and traffic accounting"
    export PATH="$PATH:/usr/sbin"
    mkdir -p /etc/nftables.d
    # An earlier version of this installer built the table with a series of
    # `nft add` commands and dumped the result here. That file is a complete
    # table definition, so leaving it in place would load a second copy of
    # every chain alongside the one below.
    if [ -f /etc/nftables.d/smartdns.conf ]; then
        backup_file /etc/nftables.d/smartdns.conf
        rm -f /etc/nftables.d/smartdns.conf
        info "removed the ruleset from the previous layout"
    fi
    grep -q 'nftables.d' /etc/nftables.conf 2>/dev/null \
        || echo 'include "/etc/nftables.d/*.conf"' >> /etc/nftables.conf

    install_payload NFTABLES /etc/nftables.d/10-smartdns.conf && NFT_CHANGED=1 || NFT_CHANGED=0
    # Reload only when the structure actually changed, or when the table is
    # missing entirely. Loading it on every run would append a duplicate of
    # every rule; rebuilding the table on every run would throw away the
    # allowlist and everybody's usage along with it.
    if [ "$NFT_CHANGED" = 1 ] || ! nft list table inet smartdns >/dev/null 2>&1; then
        [ -x /usr/local/bin/smartdns-acl ] && /usr/local/bin/smartdns-acl save 2>/dev/null
        nft delete table inet smartdns 2>/dev/null || true
        nft -f /etc/nftables.d/10-smartdns.conf || die "nft rejected the ruleset"
        # Structure first, then whoever was registered before it, then the
        # access rules if this machine had them switched on.
        [ -f /etc/nftables.d/20-smartdns-state.conf ] \
            && { nft -f /etc/nftables.d/20-smartdns-state.conf || warn "could not restore the allowlist"; }
        [ -f /etc/nftables.d/30-smartdns-enforce.conf ] \
            && { nft -f /etc/nftables.d/30-smartdns-enforce.conf || warn "could not restore the access rules"; }
        info "ruleset loaded"
    else
        info "ruleset already current"
    fi
    enable_service nftables nftables

    step "smartdns-acl command, for access control and usage"
    note_file /usr/local/bin/smartdns-acl
    payload SMARTDNS_ACL > /usr/local/bin/smartdns-acl
    chmod +x /usr/local/bin/smartdns-acl
    install_payload ACL_SAVE_SERVICE /etc/systemd/system/smartdns-acl-save.service || true
    install_payload ACL_SAVE_TIMER   /etc/systemd/system/smartdns-acl-save.timer   || true
    systemctl daemon-reload
    enable_service smartdns-acl-save.timer
    systemctl start smartdns-acl-save.timer 2>/dev/null || true
    # Counting starts now; blocking does not. Nobody has registered an address
    # yet, so switching enforcement on at this point would cut off every user
    # of the relay, including whoever is running this.
    info "counting usage - nothing is blocked yet"

    step "smartdns-shape command, for per-customer speed limits"
    note_file /usr/local/bin/smartdns-shape
    payload SMARTDNS_SHAPE > /usr/local/bin/smartdns-shape
    chmod +x /usr/local/bin/smartdns-shape
    # Nothing is shaped until a customer is actually given a limit; the sync
    # agent calls this when the panel says somebody has one.
    if ! modprobe sch_htb 2>/dev/null; then
        warn "this kernel has no htb - speed limits will not work here"
    fi
    info "no limits set - customers run at line rate until you set one"

    step "smartdns command"
    note_file /usr/local/bin/smartdns
    payload SMARTDNS | sed "s#__RELAY_IP__#${RELAY_IP}#g" > /usr/local/bin/smartdns
    chmod +x /usr/local/bin/smartdns
    info "try: smartdns status"

    step "smartdns-rules command, for what each template does with a domain"
    note_file /usr/local/bin/smartdns-rules
    payload SMARTDNS_RULES > /usr/local/bin/smartdns-rules
    chmod +x /usr/local/bin/smartdns-rules
    info "try: smartdns-rules check gemini.google.com"

    step "smartdns-watch command, for the names a customer asks for"
    note_file /usr/local/bin/smartdns-watch
    payload SMARTDNS_WATCH > /usr/local/bin/smartdns-watch
    chmod +x /usr/local/bin/smartdns-watch
    info "try: smartdns-watch <username or address>"

    step "epic-pin, keeping Epic's backend on addresses that answer from here"
    # epic-pins.conf is written later by epic-pin itself, but it is ours either
    # way and uninstall needs to know to take it with us.
    for f in /usr/local/bin/epic-pin \
             /etc/systemd/system/epic-pin.service \
             /etc/systemd/system/epic-pin.timer \
             /etc/dnsmasq.d/epic-pins.conf
    do
        note_file "$f"
    done
    payload EPIC_PIN > /usr/local/bin/epic-pin
    chmod +x /usr/local/bin/epic-pin
    payload EPIC_PIN_SERVICE > /etc/systemd/system/epic-pin.service
    payload EPIC_PIN_TIMER   > /etc/systemd/system/epic-pin.timer
    systemctl daemon-reload
    enable_service epic-pin.timer
    systemctl start epic-pin.timer  >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------- TLS
# A machine that already has a domain keeps it, even when this run was not
# told one. Everything below is gated on PANEL_DOMAIN - the certificate, its
# renewal timer, the admin panel and its restart - so an upgrade that did not
# repeat the domain skipped all of it and still ended by announcing a
# successful upgrade. The operator is then left on the previous version of the
# one page they actually use, with nothing said. That is not hypothetical: it
# happened here, and the symptom was an admin panel showing a stale service
# catalogue and a stale warning under every group in it.
#
# The state file is no help - it is truncated at the start of every run - so
# the answer has to come from something the machine keeps for its own sake.
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
if [ -z "$PANEL_DOMAIN" ]; then
    if [ -f /etc/smart-dns/sync.env ]; then
        PANEL_DOMAIN="$(sed -n 's/^PANEL_DOMAIN=//p' /etc/smart-dns/sync.env \
                        | head -1 || true)"
    fi
    # The exit keeps no sync.env. Its admin.env records where the certificate
    # is, and that path is /etc/letsencrypt/live/<domain>/fullchain.pem.
    if [ -z "$PANEL_DOMAIN" ] && [ -f /etc/smart-dns/admin.env ]; then
        PANEL_DOMAIN="$(sed -n \
            's#^ADMIN_CERT=/etc/letsencrypt/live/\([^/]*\)/.*#\1#p' \
            /etc/smart-dns/admin.env | head -1 || true)"
    fi
    if [ -n "$PANEL_DOMAIN" ]; then
        info "keeping the domain this machine already has: $PANEL_DOMAIN"
    fi
fi

# The helper goes on every machine, domain or no domain. Without one this run
# installs no certificate - but the summary at the end tells the operator to
# come back and run this command once they have a name, and a command that is
# only installed when it is not needed is not much of an instruction.
payload CERT > /usr/local/bin/smartdns-cert
chmod +x /usr/local/bin/smartdns-cert
note_file /usr/local/bin/smartdns-cert
payload SMARTDNS_LOGS > /usr/local/bin/smartdns-logs
chmod +x /usr/local/bin/smartdns-logs
note_file /usr/local/bin/smartdns-logs
payload SMARTDNS_RESTART > /usr/local/bin/smartdns-restart
chmod +x /usr/local/bin/smartdns-restart
note_file /usr/local/bin/smartdns-restart
# On either side, tunnel or none: status says there is none, which is itself
# the answer somebody asking wants.
payload SMARTDNS_TUNNEL > /usr/local/bin/smartdns-tunnel
chmod +x /usr/local/bin/smartdns-tunnel
note_file /usr/local/bin/smartdns-tunnel
payload SMARTDNS_MENU > /usr/local/bin/smartdns-menu
chmod +x /usr/local/bin/smartdns-menu
note_file /usr/local/bin/smartdns-menu
install_payload CERT_SERVICE /etc/systemd/system/smartdns-cert.service || true
install_payload CERT_TIMER   /etc/systemd/system/smartdns-cert.timer   || true
systemctl daemon-reload

if [ -n "${PANEL_DOMAIN:-}" ]; then
    step "HTTPS certificate for $PANEL_DOMAIN"
    CERT_PKGS="certbot"
    [ -f /etc/smart-dns/cloudflare.ini ] && CERT_PKGS="$CERT_PKGS python3-certbot-dns-cloudflare"
    for pkg in $([ -z "${PANEL_CERT:-}" ] && echo $CERT_PKGS); do
        dpkg -s "$pkg" >/dev/null 2>&1 || {
            apt-get install -y -qq "$pkg" >/dev/null 2>&1 || die "could not install $pkg"
            NEW_PACKAGES="$NEW_PACKAGES $pkg"
            remember packages-installed "$pkg"
        }
    done

    mkdir -p /etc/smart-dns; chmod 700 /etc/smart-dns

    # A certificate the operator obtained themselves. Recorded and used as-is;
    # keeping it renewed is then their business, which is the trade they made
    # by not handing over a DNS token.
    if [ -n "${PANEL_CERT:-}" ]; then
        [ -f "$PANEL_CERT" ] || die "no certificate at $PANEL_CERT"
        [ -f "${PANEL_KEY:-}" ] || die "no private key at ${PANEL_KEY:-<not given>}"
        CERT_PATH="$PANEL_CERT"; KEY_PATH="$PANEL_KEY"
        info "using the certificate you supplied"
        # Nothing here renews it, so say how long it has. A panel that stops
        # answering in two months with no warning is a bad way to find out.
        if openssl x509 -checkend $((30 * 86400)) -noout -in "$CERT_PATH" >/dev/null 2>&1; then
            info "valid until $(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)"
        else
            warn "this certificate expires within 30 days - nothing here renews it"
        fi
    else
        # certbot's own. It proves the domain over port 80 by default, which
        # needs nothing from the operator but a record pointing here. A token
        # left in cloudflare.ini switches it to DNS instead, but nothing asks
        # for one and nothing needs one.
        if [ -n "${CF_API_TOKEN:-}" ]; then
            umask 077
            printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" \
                > /etc/smart-dns/cloudflare.ini
            umask 022
            chmod 600 /etc/smart-dns/cloudflare.ini
        fi
        CERT_PATH="/etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem"
        KEY_PATH="/etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem"
    fi

    if [ -z "${PANEL_CERT:-}" ]; then
        /usr/local/bin/smartdns-cert "$PANEL_DOMAIN" || die "could not get a certificate"
        # Only once there is something to renew. A timer running against no
        # certificate is a unit that wakes twice a day to do nothing.
        enable_service smartdns-cert.timer
        systemctl start smartdns-cert.timer 2>/dev/null || true
    fi
    [ -f "$CERT_PATH" ] || die "still no certificate at $CERT_PATH"
    remember panel-domain "$PANEL_DOMAIN"
fi

# ----------------------------------------------------------------- panel
if [ "$ROLE" = exit ]; then
    step "Panel: database and sync API"
    mkdir -p /etc/smart-dns; chmod 700 /etc/smart-dns

    # The relay authenticates this machine by the fingerprint of this
    # certificate, so it must survive re-runs: generating a new one would
    # silently break the pairing and the relay would refuse to talk.
    if [ ! -f /etc/smart-dns/sync.key ]; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=smartdns-sync" \
            -keyout /etc/smart-dns/sync.key -out /etc/smart-dns/sync.crt \
            >/dev/null 2>&1 || die "could not generate the sync certificate"
        chmod 600 /etc/smart-dns/sync.key
        info "generated the sync certificate"
    fi
    # Same for the shared secret. Re-running the installer must not unpair a
    # relay that is working.
    # `|| true` again: on the first install panel.env does not exist, sed exits
    # non-zero, and under `set -e` with pipefail that ends the installer right
    # here without printing anything.
    SYNC_SECRET="$(sed -n 's/^SYNC_SECRET=//p' /etc/smart-dns/panel.env 2>/dev/null | head -1 || true)"
    [ -n "$SYNC_SECRET" ] || SYNC_SECRET="$(openssl rand -hex 24)"

    umask 077
    if [ ! -f /etc/smart-dns/panel.env ]; then
        cat > /etc/smart-dns/panel.env <<EOF
# Secrets and panel settings. Not in git and not in the installer: this file is
# written at install time and is readable only by root.
SYNC_SECRET=$SYNC_SECRET
RELAY_IP=$RELAY_IP
EOF
    else
        # Merge rather than rewrite. An earlier version of this rewrote the
        # whole file on every run, which silently undid the operator's own
        # settings - a second relay added to RELAY_IP, a CLAIM_HOST - and the
        # only symptom was the other relay suddenly getting 401s.
        # RELAY_IP is a list, and this relay may already be on it or may be a
        # new one joining. Adding is right; replacing would unpair the others.
        current_relays="$(sed -n 's/^RELAY_IP=//p' /etc/smart-dns/panel.env | head -1 || true)"
        case ",${current_relays}," in
            *",$RELAY_IP,"*) ;;
            *) set_env_key /etc/smart-dns/panel.env RELAY_IP \
                   "${current_relays:+$current_relays,}$RELAY_IP"
               info "added $RELAY_IP to the relays this panel serves" ;;
        esac
    fi
    # What a re-run or an upgrade keeps, unasked.
    set_env_key /etc/smart-dns/panel.env TUNNEL "$TUNNEL"
    set_env_key /etc/smart-dns/panel.env TUNNEL_TRANSPORT "${TUNNEL_TRANSPORT:-}"
    set_env_key /etc/smart-dns/panel.env TUNNEL_DIRECTION "${TUNNEL_DIRECTION:-}"
    set_env_key /etc/smart-dns/panel.env TUNNEL_PORT "${TUNNEL_PORT:-}"
    umask 022
    chmod 600 /etc/smart-dns/panel.env

    payload PANEL > /usr/local/bin/smartdns-panel
    chmod +x /usr/local/bin/smartdns-panel
    note_file /usr/local/bin/smartdns-panel
    # The service catalogue: which brands exist, and which domains are in each
    # group. Shipped as a file so it is versioned with the code rather than
    # migrated into the database.
    mkdir -p /usr/local/share/smart-dns
    note_file /usr/local/share/smart-dns/services.json
    payload SERVICES > /usr/local/share/smart-dns/services.json
    # Only the relays reach the sync API. The panel's service runs this before
    # every start, so a relay added to RELAY_IP by hand is let in the next time
    # the panel restarts - exactly when the panel itself would let it in.
    note_file /usr/local/bin/smartdns-api-guard
    payload SMARTDNS_API_GUARD > /usr/local/bin/smartdns-api-guard
    chmod +x /usr/local/bin/smartdns-api-guard
    install_payload PANEL_SERVICE /etc/systemd/system/smartdns-panel.service || true
    systemctl daemon-reload
    enable_service smartdns-panel.service
    systemctl restart smartdns-panel.service
    sleep 2
    if systemctl is-active --quiet smartdns-panel.service; then
        info "sync API is up on :8443"
    else
        warn "the panel did not start - journalctl -u smartdns-panel"
    fi
    if nft list table inet smartdns_api >/dev/null 2>&1; then
        info "port 8443 answers the relays only: $(sed -n 's/^RELAY_IP=//p' /etc/smart-dns/panel.env | head -1)"
    else
        warn "port 8443 could not be closed to strangers - the panel still refuses them itself"
    fi

    # ---- telegram bot ----------------------------------------------------
    # On every exit, and idle until it has a token - from the admin panel's
    # settings, or `smartdns-bot token` - so turning it on later needs no
    # re-run. It listens on nothing: it only ever dials out to Telegram.
    step "Telegram bot"
    payload BOT > /usr/local/bin/smartdns-bot
    chmod +x /usr/local/bin/smartdns-bot
    note_file /usr/local/bin/smartdns-bot
    install_payload BOT_SERVICE /etc/systemd/system/smartdns-bot.service || true
    systemctl daemon-reload
    enable_service smartdns-bot.service
    systemctl restart smartdns-bot.service
    sleep 1
    if systemctl is-active --quiet smartdns-bot.service; then
        info "bot service running - give it a token in the admin panel's settings, or: smartdns-bot token"
    else
        warn "the bot did not start - journalctl -u smartdns-bot"
    fi

    # ---- admin web panel -------------------------------------------------
    if [ -n "${PANEL_DOMAIN:-}" ]; then
        step "Admin web panel"
        payload ADMIN > /usr/local/bin/smartdns-admin
        chmod +x /usr/local/bin/smartdns-admin
        note_file /usr/local/bin/smartdns-admin
        install_payload ADMIN_SERVICE /etc/systemd/system/smartdns-admin.service || true

        payload SMARTDNS_ACCESS > /usr/local/bin/smartdns-access
        chmod +x /usr/local/bin/smartdns-access
        note_file /usr/local/bin/smartdns-access

        # Generated once and kept. Regenerating on every run would move the URL
        # and change the password under the operator each time they upgraded.
        if [ ! -f /etc/smart-dns/admin.env ]; then
            # Asked for, not assumed. The port is the operator's firewall to
            # think about, and a password they chose is one they will still
            # have tomorrow - a generated one gets pasted somewhere careless
            # or lost. Both have answers, so pressing enter is fine.
            if [ -z "${ASSUME_YES:-}" ]; then
                printf '\n%sAdmin panel%s\n\n' "$B" "$N"
                if [ -z "${ADMIN_PORT:-}" ]; then
                    # Said before the question rather than after a rejected
                    # answer: an operator who has already typed 443 has
                    # usually also written it into a firewall rule.
                    warn "these ports are taken - do not pick one of them:"
                    warn "    22    ssh"
                    warn "    53    dns"
                    warn "    80    the proxy, and how certificates are proved"
                    warn "   443    the proxy"
                    warn "  8443    the sync API the relays connect to"
                    warn "  8446    the exit's own route to Google over IPv6"
                    warn "on a relay, 3478 is taken as well."
                    warn "pick anything else, and open it in your firewall."
                    printf '\n'
                    read -r -p "  port to serve it on [9443]: " ADMIN_PORT
                fi
                if [ -z "${ADMIN_PASS:-}" ]; then
                    printf '  password [enter for a generated one]: '
                    read -rs ADMIN_PASS; printf '\n'
                    if [ -n "$ADMIN_PASS" ]; then
                        printf '  again: '
                        read -rs ADMIN_PASS2; printf '\n'
                        [ "$ADMIN_PASS" = "$ADMIN_PASS2" ] \
                            || die "the two passwords did not match"
                        [ "${#ADMIN_PASS}" -ge 8 ] \
                            || die "use a password of 8 characters or more"
                    fi
                fi
            fi
            ADMIN_PORT="${ADMIN_PORT:-9443}"
            case "$ADMIN_PORT" in
                *[!0-9]*|"") die "the admin port must be a number" ;;
                22) die "port 22 is ssh" ;;
                8443) die "port 8443 is the sync API the relays connect to" ;;
                8446) die "port 8446 is the exit's own route to Google over IPv6" ;;
                53|80|443) die "port $ADMIN_PORT is the service's own - pick
    another. 22, 53, 80, 443, 8443 and 8446 are all taken." ;;
                "${TUNNEL_PORT:-none}") die "port $ADMIN_PORT carries the tunnel - pick another" ;;
            esac
            # The path stays generated. Nobody types it from memory, and an
            # operator asked to invent one invents a guessable one.
            [ -n "${ADMIN_PASS:-}" ] \
                || ADMIN_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
            ADMIN_SALT="$(openssl rand -hex 16)"
            ADMIN_HASH="$(ADMIN_PASS="$ADMIN_PASS" ADMIN_SALT="$ADMIN_SALT" python3 -c '
import hashlib, os
print(hashlib.pbkdf2_hmac("sha256", os.environ["ADMIN_PASS"].encode(),
                          bytes.fromhex(os.environ["ADMIN_SALT"]), 200000).hex())')"
            ADMIN_PATH_GEN="$(openssl rand -hex 12)"
            umask 077
            cat > /etc/smart-dns/admin.env <<EOF
# Written once at install. The password itself is not stored - only a salted
# hash - so a forgotten password is replaced, never recovered.
ADMIN_PORT=$ADMIN_PORT
ADMIN_PATH=$ADMIN_PATH_GEN
ADMIN_SALT=$ADMIN_SALT
ADMIN_HASH=$ADMIN_HASH
ADMIN_CERT=$CERT_PATH
ADMIN_KEY=$KEY_PATH
EOF
            umask 022
            chmod 600 /etc/smart-dns/admin.env
            ADMIN_URL_OUT="https://$PANEL_DOMAIN:$ADMIN_PORT/$ADMIN_PATH_GEN/"
            ADMIN_PASS_OUT="$ADMIN_PASS"
        else
            info "keeping the admin URL and password already set up here"
            info "change them with: smartdns-access"
        fi
        systemctl daemon-reload
        enable_service smartdns-admin.service
        systemctl restart smartdns-admin.service
        sleep 2
        if systemctl is-active --quiet smartdns-admin.service; then
            info "admin panel running"
        else
            warn "the admin panel did not start - journalctl -u smartdns-admin"
        fi
    fi

    FP="$(openssl x509 -in /etc/smart-dns/sync.crt -noout -fingerprint -sha256 \
          | cut -d= -f2 | tr -d ':' | tr 'A-Z' 'a-z')"
    # A third part when there is a tunnel, so the relay sets up the same one.
    SYNC_TOKEN_OUT="$SYNC_SECRET.$FP${TUNNEL_SPEC:+.$TUNNEL_SPEC}"
fi

# A relay that is already paired keeps its pairing. Requiring the token again
# on every run meant an upgrade run without it skipped this whole section and
# silently left the old agent in place - the machine kept syncing, so nothing
# looked wrong, while the new code never arrived.
# ------------------------------------------------------------- extra exit
# A server that carries traffic and nothing else: no database, no admin
# panel, no bot - the main exit keeps those, and learns of this one when it is
# added in the bot. What is kept here is only what a re-run needs to know what
# this machine is, and which relays it lets in.
if [ "$ROLE" = extra ]; then
    step "Extra exit"
    mkdir -p /etc/smart-dns; chmod 700 /etc/smart-dns
    note_file /etc/smart-dns/exit.env
    umask 077
    printf 'RELAY_IP=%s\nSELF_IP=%s\n' "$PEER_IP" "$SELF_IP" > /etc/smart-dns/exit.env
    umask 022
    info "carries traffic for $PEER_IP and nobody else"
fi

if [ "$ROLE" = relay ] && [ -z "${SYNC_TOKEN:-}" ] && [ -f /etc/smart-dns/sync.env ]; then
    SYNC_TOKEN="$(sed -n 's/^SYNC_SECRET=//p' /etc/smart-dns/sync.env | head -1 || true).$(sed -n 's/^SYNC_FINGERPRINT=//p' /etc/smart-dns/sync.env | head -1 || true)"
    PANEL_IP="${PANEL_IP:-$(sed -n 's/^PANEL_HOST=//p' /etc/smart-dns/sync.env | head -1 || true)}"
    KEEP_PAIRING=1
fi

if [ "$ROLE" = relay ] && [ -n "${SYNC_TOKEN:-}" ]; then
    step "Panel: sync agent and claim page"
    # secret.fingerprint - one string for the user to copy, carrying both the
    # shared secret and the certificate to pin. Splitting them into two
    # questions only creates a chance to paste one and forget the other.
    # The third part, when there is one, is the tunnel, read further up.
    SECRET="$(printf '%s' "$SYNC_TOKEN" | cut -d. -f1)"
    FINGER="$(printf '%s' "$SYNC_TOKEN" | cut -s -d. -f2)"
    [ -n "$SECRET" ] && [ -n "$FINGER" ] && [ "$SECRET" != "$FINGER" ] \
        || die "that does not look like a pairing token.
    It is the whole 'secret.fingerprint' line the exit server printed."
    case "$FINGER" in
        *[!0-9a-f]*|"") die "the fingerprint half of the token is not hexadecimal" ;;
    esac
    [ -n "${KEEP_PAIRING:-}" ] && info "keeping the pairing already on this machine"

    # Usually the panel lives on this relay's own exit, but it need not: one
    # database can serve several relay/exit pairs, and one database is what
    # makes a customer's allowance mean the same thing on all of them.
    # PANEL_IP names the machine running the panel when it is a different one.
    PANEL_HOST="${PANEL_IP:-$EXIT_IP}"
    valid_ip "$PANEL_HOST" || die "PANEL_IP '$PANEL_HOST' is not an IPv4 address"

    mkdir -p /etc/smart-dns; chmod 700 /etc/smart-dns
    # Recover the domain this relay already serves its panel on, if this run
    # was not told one. Without this, re-running the installer and pressing
    # enter at the domain prompt blanked PANEL_DOMAIN, and the customer panel
    # silently dropped from https to plain http - which also switches sign-up
    # off. The same trap that once rewrote panel.env on the exit.
    if [ -z "${PANEL_DOMAIN:-}" ] && [ -f /etc/smart-dns/sync.env ]; then
        PANEL_DOMAIN="$(sed -n 's/^PANEL_DOMAIN=//p' /etc/smart-dns/sync.env | head -1 || true)"
        [ -n "$PANEL_DOMAIN" ] && info "keeping the panel domain already set: $PANEL_DOMAIN"
    fi
    umask 077
    if [ ! -f /etc/smart-dns/sync.env ]; then
        cat > /etc/smart-dns/sync.env <<EOF
PANEL_HOST=$PANEL_HOST
SYNC_SECRET=$SECRET
SYNC_FINGERPRINT=$FINGER
SELF_IP=$RELAY_IP
PANEL_DOMAIN=${PANEL_DOMAIN:-}
EOF
    else
        # Merge, so anything the operator added by hand survives an upgrade.
        set_env_key /etc/smart-dns/sync.env PANEL_HOST "$PANEL_HOST"
        set_env_key /etc/smart-dns/sync.env SYNC_SECRET "$SECRET"
        set_env_key /etc/smart-dns/sync.env SYNC_FINGERPRINT "$FINGER"
        set_env_key /etc/smart-dns/sync.env SELF_IP "$RELAY_IP"
        set_env_key /etc/smart-dns/sync.env PANEL_DOMAIN "${PANEL_DOMAIN:-}"
    fi
    set_env_key /etc/smart-dns/sync.env TUNNEL "$TUNNEL"
    # The exit every customer leaves by unless they are on an extra one, and
    # the backup for all of those.
    set_env_key /etc/smart-dns/sync.env EXIT_IP "$EXIT_IP"
    set_env_key /etc/smart-dns/sync.env TUNNEL_TRANSPORT "${TUNNEL_TRANSPORT:-}"
    set_env_key /etc/smart-dns/sync.env TUNNEL_DIRECTION "${TUNNEL_DIRECTION:-}"
    set_env_key /etc/smart-dns/sync.env TUNNEL_PORT "${TUNNEL_PORT:-}"
    umask 022
    chmod 600 /etc/smart-dns/sync.env

    payload SYNC > /usr/local/bin/smartdns-sync
    chmod +x /usr/local/bin/smartdns-sync
    note_file /usr/local/bin/smartdns-sync
    # A systemd template, one instance per service profile. The instances
    # themselves are started and stopped by the sync agent as the panel adds
    # and retires templates, so nothing here is enabled.
    install_payload DNS_PROFILE_UNIT /etc/systemd/system/smartdns-dns@.service || true
    mkdir -p /etc/smartdns-profiles
    install_payload SYNC_SERVICE /etc/systemd/system/smartdns-sync.service || true
    systemctl daemon-reload
    enable_service smartdns-sync.service
    systemctl restart smartdns-sync.service
    sleep 3
    # Where the customer's panel ended up, for the summary at the end. It is
    # served over TLS or not at all - it asks for a password, and there is no
    # safe way to do that in the clear - so a relay with no certificate has no
    # panel and nothing to print. 8443 sits outside the gated ports on purpose,
    # so somebody whose address changed can still reach the page that fixes it.
    if [ -n "${PANEL_DOMAIN:-}" ]; then
        USER_PANEL_OUT="https://$PANEL_DOMAIN:8443/"
    fi
    # Closed from the moment it is installed. This used to wait for the first
    # customer to register before shutting the door, on the reasoning that
    # enforcing against an empty allowlist cuts everyone off - but on a fresh
    # relay there is nobody to cut off, and what "waiting" really means is a
    # relay that anybody who learns its address can use for free, for as long
    # as it takes somebody to notice.
    #
    # Nothing here is at risk from it. SSH is never gated, the customer panel
    # is on a port the gate does not touch, and the certificate challenge is
    # redirected in prerouting so it reaches certbot before the gate ever sees
    # a packet on 80.
    rm -f /etc/smart-dns/auto-enforce
    if [ "${ENFORCE:-yes}" = no ]; then
        info "ENFORCE=no - this relay is open to everyone until you close it:"
        info "    smartdns-acl enforce on"
    elif smartdns-acl enforce on --yes --allow-empty >/dev/null 2>&1; then
        ENFORCE_OUT=1
        info "access control is on - only registered addresses get through"
    else
        warn "could not switch access control on - this relay is open."
        warn "close it by hand once you have looked:  smartdns-acl enforce on"
    fi
    if systemctl is-active --quiet smartdns-sync.service; then
        info "syncing with the panel at $PANEL_HOST every 30s"
        if [ -n "$USER_PANEL_OUT" ]; then
            info "customer panel on $USER_PANEL_OUT"
        else
            warn "no certificate, so no customer panel - see the end of this run"
        fi
    else
        warn "the sync agent did not start - journalctl -u smartdns-sync"
    fi
fi

# ---------------------------------------------------------------- tunnel
if [ "$ROLE" = exit ]; then apply_tunnel "${SYNC_SECRET:-}"; else apply_tunnel "${SECRET:-}"; fi

# ---------------------------------------------------------------- start
step "Starting services"
if [ "$NGINX_CHANGED" = 1 ]; then systemctl restart nginx
else systemctl reload nginx 2>/dev/null || systemctl start nginx; fi
if [ "$ROLE" = relay ]; then
    if [ "$DNSMASQ_CHANGED" = 1 ]; then systemctl restart dnsmasq
    else systemctl start dnsmasq 2>/dev/null || true; fi
    /usr/local/bin/epic-pin || warn "epic-pin failed this run; the timer will retry"
fi

# ---------------------------------------------------------------- verify
step "Checking"
fail=0
check() {
    if [ "$2" = "$3" ]; then printf '    %s.%s %s\n' "$G" "$N" "$1"
    else printf '    %sx%s %s  (got: %s)\n' "$RD" "$N" "$1" "$2"; fail=1; fi
}
check "nginx running" "$(systemctl is-active nginx)" active
if [ "$ROLE" = relay ]; then
    check "dnsmasq running" "$(systemctl is-active dnsmasq)" active
    check "coturn running"  "$(systemctl is-active coturn)"  active
    check "a routed domain resolves to this relay" \
          "$(dig +short +time=3 @127.0.0.1 github.com A 2>/dev/null | tail -1)" "$RELAY_IP"
    check "no IPv6 answers leak around the relay" \
          "$(dig +short +time=3 @127.0.0.1 github.com AAAA 2>/dev/null | grep -c ':' || true)" "0"
    # Two things, not one. A domain we do not route has to answer, and has to
    # answer with somebody else's address. Counting its records was wrong:
    # example.com has more than one, and how many is not ours to assert.
    unrouted="$(dig +short +time=3 @127.0.0.1 example.com A 2>/dev/null)"
    check "an unrouted domain still resolves" \
          "$([ -n "$unrouted" ] && echo yes || echo no)" "yes"
    # example.com is the sentinel because it is stable and nobody needs it
    # bypassed - but an operator can add anything to their own routed list, so
    # a failure here is as likely to mean "you added this on purpose" as it is
    # to mean something is wrong. Say which name it used, so the answer is in
    # the message rather than in a debugging session.
    if [ "$(printf '%s\n' "$unrouted" | grep -c "^${RELAY_IP}$" || true)" != 0 ]; then
        warn "example.com resolves to this relay, so it is being routed."
        warn "That is only a problem if you did not mean it - check with:"
        warn "    grep -rn example.com /etc/dnsmasq.d/"
    fi
    check "an unrouted domain is not pointed at this relay" \
          "$(printf '%s\n' "$unrouted" | grep -c "^${RELAY_IP}$" || true)" "0"
    check "a site loads through the full chain" \
          "$(curl -sS -o /dev/null -m 25 --resolve "github.com:443:${RELAY_IP}" -w '%{http_code}' https://github.com/ 2>/dev/null || echo 000)" "200"
    # The API the relay syncs with, reached the way smartdns-sync reaches it -
    # by address, with a name in the handshake - but with a GET, which the API
    # refuses as 501 without looking at any secret, so this proves the path
    # and leaves no "wrong secret" warning in the exit's log. A relay whose
    # sync could not get through used to pass every check here and then fail
    # in the customer's panel instead.
    check "the exit's sync API answers this relay" \
          "$(curl -sk -o /dev/null -m 20 --resolve "${PANEL_DOMAIN:-sync.example.com}:8443:${EXIT_IP}" -w '%{http_code}' "https://${PANEL_DOMAIN:-sync.example.com}:8443/" 2>/dev/null || true)" "501"
fi
if [ "$TUNNEL" = backpack ]; then
    check "the tunnel service is running" "$(systemctl is-active smartdns-tunnel.service)" active
    if [ "$ROLE" = relay ]; then
        # Straight at the tunnel's own end, so that the fallback in nginx
        # cannot pass this for it. The far end may still be dialling in.
        tun=000
        for i in $(seq 1 20); do
            tun="$(curl -s -o /dev/null -m 8 --connect-to "github.com:443:127.0.0.1:$TUNNEL_LOCAL_HTTPS" \
                   -w '%{http_code}' https://github.com/ 2>/dev/null || true)"
            [ "$tun" = 200 ] && break
            sleep 3
        done
        check "a site loads through the tunnel" "$tun" 200
        [ "$tun" = 200 ] || warn "customers still get through - nginx falls back to the direct path -
    but the tunnel is not carrying them. Is port $TUNNEL_PORT open between the two
    machines? Or try another transport: re-run the installer on the exit."
    fi
fi

printf '\n'
if [ "$fail" = 0 ]; then
    # Written here and nowhere earlier: a run that died half way through has
    # not installed this version, and recording it would tell the next run
    # there was nothing left to do.
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$VERSION" > "$VERSION_FILE"
    printf '%s%s is installed and working, version %s.%s\n' \
           "$G" "$ROLE" "$VERSION" "$N"
else
    printf '%sSomething is off - see the failures above.%s\n' "$Y" "$N"
fi

if [ "$ROLE" = relay ]; then
    printf '
    Point your devices at this address for DNS:

        %s

    Set it as both primary and secondary. A different secondary is worse than
    none: the device will sometimes use it and quietly skip the bypass.

    Manage the list with:  smartdns status | list | add | del | bypass

' "$RELAY_IP"
elif [ "$ROLE" = extra ]; then
    printf '
    This extra exit carries traffic for %s and accepts nothing else.
    Add it in the Telegram bot, under 🛠 مدیریت -> 🌍 خروجی‌ها -> ➕:

        a name | %s

    Customers can then choose it, or be put on it automatically whenever it
    has the lowest ping from their relay. Upgrade the relay to this version
    first, if you have not - it needs to know its own exit to fall back to.

' "$PEER_IP" "$SELF_IP"
else
    printf '
    This exit only accepts connections from %s, so it is not an open proxy.
    Run the installer on the relay next, if you have not already.

' "$RELAY_IP"
fi

if [ -n "$ENFORCE_OUT" ]; then
    printf '    %sAccess control is on%s - only addresses registered in the panel get
    DNS, HTTP and HTTPS through this relay. Nobody is registered yet, so right
    now that is nobody: sign a customer up, give them a plan, and let them
    register their address from the customer panel.

    SSH is never gated, and the customer panel is on a port the gate does not
    touch - so a wrong allowlist cannot lock you out of either.

        smartdns-acl list               who is allowed, and what they have used
        smartdns-acl enforce status     which way the door is
        smartdns-acl enforce off        open it to everyone

' "$B" "$N"
fi

if [ -n "$USER_PANEL_OUT" ]; then
    printf '    %sCustomer panel%s - where people sign up, register the address the
    service works on, see what is left of their allowance, and send a payment
    receipt. It also shows them the DNS address to enter.

        %s

' "$B" "$N" "$USER_PANEL_OUT"
fi

if [ "$ROLE" = relay ] && [ -z "${PANEL_DOMAIN:-}" ]; then
    printf '    %sThere is no customer panel on this relay%s, because it has no
    certificate. That page asks for a password, and nothing asks for a
    password over plain http here - so it is not served at all rather than
    served unsafely. Nobody can sign up or register an address until you
    give this machine a domain:

        smartdns-cert panel.example.com

    then put PANEL_DOMAIN in /etc/smart-dns/sync.env and restart
    smartdns-sync.

' "$Y" "$N"
fi

if [ -n "$ADMIN_URL_OUT" ]; then
    printf '    %sAdmin panel%s - shown once. Only a hash of the password is stored,
    so it can be replaced but never read back. Write it down now.

        %s
        password: %s

' "$B" "$N" "$ADMIN_URL_OUT" "$ADMIN_PASS_OUT"
fi

if [ "$TUNNEL" = backpack ]; then
    printf '    %sTunnel%s - %s. The relay'"'"'s nginx goes through it, and
    straight to the exit only while it is down. Its log is in smartdns-logs.

' "$B" "$N" "$TUNNEL_OUT"
fi

if [ -n "$SYNC_TOKEN_OUT" ]; then
    printf '    %sPairing token%s - run the installer on the relay and paste this when
    it asks. It carries both the shared secret and the fingerprint of this
    machine'"'"'s certificate, so the relay will talk to this server and no other.

        %s

' "$B" "$N" "$SYNC_TOKEN_OUT"
fi

# The tunnel was asked again here: the relay has not heard yet, and it will not
# until it is given the token above.
if [ -n "${ASK_TUNNEL:-}" ] && [ "$ROLE" = exit ]; then
    printf '    %sNow the relay%s: run the installer there with --tunnel and paste the\n' "$Y" "$N"
    printf '    pairing token above. Until then it goes straight to this exit.\n\n'
fi

printf '    Every command there is, in one menu:  %ssudo smartdns-menu%s\n\n' "$B" "$N"

exit 0
