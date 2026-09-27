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
VERSION="0.12.0"

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
    { [ "$p" -ge 18500 ] && [ "$p" -le 18599 ]; } && echo "the relay's ends of the extra exits' tunnels"
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

# An extra exit's tunnel. Shorter than the pair's: the relay always dials an
# extra exit, so there is no direction to choose and no port to open on the
# relay - only what to speak, and on which port this machine listens.
ask_exit_tunnel() {
    local a t i=0 why
    printf '\n%sTunnel between the relay and this exit%s (optional)\n\n' "$B" "$N"
    printf '  Plain TCP is the fastest path and shows the name of every site on the\n'
    printf '  way. A tunnel hides them, which some routes into Iran need.\n\n'
    printf '  1) no tunnel - plain TCP\n'
    printf '  2) BackPack tunnel\n\n'
    read -r -p "  choice [1/2] [1]: " a
    case "${a:-1}" in
        2|backpack|tunnel) ;;
        *) TUNNEL=off; return 0 ;;
    esac
    TUNNEL=backpack
    TUNNEL_DIRECTION=direct
    printf '\n  Which transport? stealth is encrypted and looks like random bytes;\n'
    printf '  wss looks like an ordinary HTTPS site; tcp and ws are not encrypted,\n'
    printf '  so the names still show. Try one or two - it depends on the route.\n\n'
    for t in $TUNNEL_DIRECT_TRANSPORTS; do
        i=$((i + 1)); printf '  %d) %s\n' "$i" "$t"
    done
    printf '\n'
    read -r -p "  choice [1]: " a
    i=0
    TUNNEL_TRANSPORT=stealth
    for t in $TUNNEL_DIRECT_TRANSPORTS; do
        i=$((i + 1)); [ "${a:-1}" = "$i" ] && TUNNEL_TRANSPORT="$t"
    done
    while :; do
        printf '\n'
        read -r -p "  port the relay dials on this machine [8444]: " a
        a="${a:-8444}"
        why="$(tunnel_port_problem "$a")"
        [ -z "$why" ] && { TUNNEL_PORT="$a"; break; }
        warn "port $a cannot carry the tunnel: $why"
    done
    info "open port $TUNNEL_PORT to the relay in this machine's firewall, if it has one"
}

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
    # The per-exit tunnels are started by the sync agent, not by this script,
    # so they are not on the list below.
    for svc in $(systemctl list-units --plain --no-legend 'smartdns-tunnel@*' 2>/dev/null | awk '{print $1}'); do
        systemctl disable --now "$svc" >/dev/null 2>&1 || true
    done
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
# An extra exit keeps its own: the relay learns it from the line printed at the
# end of this run, which the operator pastes into the bot with the exit.
if [ "$ROLE" = extra ]; then
    if [ -z "$TUNNEL" ] && [ -f /etc/smart-dns/exit.env ]; then
        TUNNEL="$(env_get /etc/smart-dns/exit.env TUNNEL)"
        TUNNEL_TRANSPORT="${TUNNEL_TRANSPORT:-$(env_get /etc/smart-dns/exit.env TUNNEL_TRANSPORT)}"
        TUNNEL_PORT="${TUNNEL_PORT:-$(env_get /etc/smart-dns/exit.env TUNNEL_PORT)}"
        TUNNEL_SECRET="${TUNNEL_SECRET:-$(env_get /etc/smart-dns/exit.env TUNNEL_SECRET)}"
    fi
    if [ -z "$TUNNEL" ] && [ -z "${ASSUME_YES:-}" ] && [ -z "$UPGRADE" ]; then
        ask_exit_tunnel
    fi
    [ "${TUNNEL:-off}" = backpack ] && TUNNEL_DIRECTION=direct
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
EXIT_TUNNEL_OUT=""
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

# ---------------------------------------------------------------- fonts
# The two faces the panels are drawn in, carried in this file and served by the
# panels themselves. Google Fonts is blocked in Iran, so a panel that fetched
# them would draw in whatever the device happened to have - and on an operator's
# phone in Iran that is not the brand at all. Latin and numerals only: Persian
# text falls through to the device's own face. An extra exit has no panel.
if [ "$ROLE" != extra ]; then
    step "Panel fonts"
    mkdir -p /usr/local/share/smart-dns/fonts
    for face in space:FONT_SPACE mono:FONT_MONO; do
        dest="/usr/local/share/smart-dns/fonts/${face%%:*}.woff2"
        note_file "$dest"
        payload "${face#*:}" | base64 -d > "$dest" 2>/dev/null \
            || warn "could not write $dest - the panels will fall back to the device's fonts"
        chmod 644 "$dest" 2>/dev/null || true
    done
    info "panel fonts in /usr/local/share/smart-dns/fonts"
fi

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

    # Its own tunnel, when it was asked for. The relay dials this machine, so
    # this end listens and the port answers the relays and nobody else. The
    # secret is this exit's alone - there is no pairing here to derive one
    # from - and it is kept so a re-run does not invalidate what the panel has.
    if [ "${TUNNEL:-off}" = backpack ] && install_backpack; then
        step "Tunnel: BackPack $BACKPACK_VERSION - $TUNNEL_TRANSPORT, port $TUNNEL_PORT"
        [ -n "${TUNNEL_SECRET:-}" ] || TUNNEL_SECRET="$(openssl rand -hex 24)"
        mkdir -p "$TUNNEL_DIR"; chmod 700 "$TUNNEL_DIR"
        note_file "$TUNNEL_DIR/tunnel.toml"
        tmp="$(mktemp)"
        {
            printf '# written by the Fasty DNS installer - re-run it to change the tunnel\n'
            printf '[direct]\nrole = "kharej"\naddr = "0.0.0.0:%s"\n' "$TUNNEL_PORT"
            if [ "$TUNNEL_TRANSPORT" = wss ]; then
                [ -f "$TUNNEL_DIR/tls.crt" ] || openssl req -x509 -newkey rsa:2048 -nodes \
                    -days 3650 -subj "/CN=localhost" -keyout "$TUNNEL_DIR/tls.key" \
                    -out "$TUNNEL_DIR/tls.crt" >/dev/null 2>&1 || true
                printf 'tls_cert = "%s"\ntls_key = "%s"\n' "$TUNNEL_DIR/tls.crt" "$TUNNEL_DIR/tls.key"
            fi
            printf 'transport = "%s"\ntoken = "%s"\n' "$TUNNEL_TRANSPORT" "$TUNNEL_SECRET"
        } > "$tmp"
        install -m 600 "$tmp" "$TUNNEL_DIR/tunnel.toml"; rm -f "$tmp"
        mkdir -p /etc/nftables.d
        note_file "$TUNNEL_NFT"
        cat > "$TUNNEL_NFT" <<EOF
# written by the Fasty DNS installer: the tunnel's port answers the relays only
table inet smartdns_tunnel
delete table inet smartdns_tunnel
table inet smartdns_tunnel {
    chain input {
        type filter hook input priority -5 ; policy accept ;
        tcp dport $TUNNEL_PORT ip saddr != { $PEER_IP } drop
        udp dport $TUNNEL_PORT ip saddr != { $PEER_IP } drop
        meta nfproto ipv6 tcp dport $TUNNEL_PORT drop
        meta nfproto ipv6 udp dport $TUNNEL_PORT drop
    }
}
EOF
        if nft -f "$TUNNEL_NFT" 2>/dev/null; then info "port $TUNNEL_PORT answers $PEER_IP only"
        else warn "could not load the tunnel's firewall rule - port $TUNNEL_PORT is open to all"; fi
        install_payload TUNNEL_SERVICE /etc/systemd/system/smartdns-tunnel.service || true
        systemctl daemon-reload
        enable_service smartdns-tunnel.service
        systemctl restart smartdns-tunnel.service
        sleep 2
        if systemctl is-active --quiet smartdns-tunnel.service; then
            info "tunnel listening on port $TUNNEL_PORT"
        else
            warn "the tunnel did not start - journalctl -u smartdns-tunnel"
            TUNNEL=off
        fi
    else
        [ "${TUNNEL:-off}" = backpack ] && { warn "no tunnel this run - the relay will reach this exit directly"; TUNNEL=off; }
        systemctl disable --now smartdns-tunnel.service >/dev/null 2>&1 || true
        rm -f "$TUNNEL_NFT"
        rm -rf "$TUNNEL_DIR"
        nft delete table inet smartdns_tunnel >/dev/null 2>&1 || true
    fi
    umask 077
    set_env_key /etc/smart-dns/exit.env TUNNEL "${TUNNEL:-off}"
    set_env_key /etc/smart-dns/exit.env TUNNEL_TRANSPORT "${TUNNEL_TRANSPORT:-}"
    set_env_key /etc/smart-dns/exit.env TUNNEL_PORT "${TUNNEL_PORT:-}"
    set_env_key /etc/smart-dns/exit.env TUNNEL_SECRET "${TUNNEL_SECRET:-}"
    umask 022
    chmod 600 /etc/smart-dns/exit.env
    [ "${TUNNEL:-off}" = backpack ] \
        && EXIT_TUNNEL_OUT="bp-$TUNNEL_TRANSPORT-$TUNNEL_PORT-d.$TUNNEL_SECRET"
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
    # One instance per extra exit that has a tunnel; the sync agent starts and
    # stops them as the panel's list of exits changes, so none is enabled here.
    install_payload TUNNEL_EXIT_SERVICE /etc/systemd/system/smartdns-tunnel@.service || true
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
# An extra exit's tunnel is set up in its own section above, with its own
# secret: it has no pairing to derive one from.
if [ "$ROLE" = extra ]; then :
elif [ "$ROLE" = exit ]; then apply_tunnel "${SYNC_SECRET:-}"
else apply_tunnel "${SECRET:-}"; fi

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
elif [ "$ROLE" = extra ] && [ -n "$EXIT_TUNNEL_OUT" ]; then
    printf '
    This extra exit carries traffic for %s and accepts nothing else, through a
    %s tunnel on port %s that the relay dials.
    Add it in the Telegram bot, under 🛠 مدیریت -> 🌍 خروجی‌ها -> ➕, with the
    tunnel line on the end:

        a name | %s | %s

    The relay needs BackPack for it: if it has never had a tunnel of its own,
    run the installer there once with --tunnel. Without it the relay reaches
    this exit directly and says so in its log.

' "$PEER_IP" "$TUNNEL_TRANSPORT" "$TUNNEL_PORT" "$SELF_IP" "$EXIT_TUNNEL_OUT"
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

# ====================================================================
# Config payloads. Everything below is data, never executed.
# ====================================================================

#__BEGIN_SYSCTL__
## /etc/sysctl.d/99-smartdns-tuning.conf
##
## Tuning for a relay whose upstream leg is a 90 ms Iran -> Frankfurt hop.
## The RTT itself cannot be reduced - a traceroute shows one clean hop from the
## Iranian edge to DE-CIX Frankfurt at 89 ms, with 0% loss and 0.4 ms jitter,
## and every other exit region measured from this box is the same or worse
## (UAE 110 ms, Mumbai 203 ms). What is left to win is throughput, which the
## stock settings throttle badly at this bandwidth-delay product.
#
## Congestion control is NOT set here. BBR helps this workload a great deal, but
## it changes how every connection on the machine behaves, including services
## that have nothing to do with this one - so it is asked for rather than
## assumed, and lives in its own file the installer writes only on request.
#
## At 90 ms RTT a socket needs ~11 MB in flight to fill a 1 Gbit/s path. The
## stock 4 MB write buffer caps a single stream well below that.
#net.core.rmem_max = 33554432
#net.core.wmem_max = 33554432
#net.ipv4.tcp_rmem = 4096 131072 33554432
#net.ipv4.tcp_wmem = 4096 65536 33554432
#
## A relay's connections go idle between bursts. Restarting slow start each time
## costs several RTTs - at 90 ms that is very visible on page loads.
#net.ipv4.tcp_slow_start_after_idle = 0
#
## Find the real path MTU instead of stalling on a black-holed ICMP.
#net.ipv4.tcp_mtu_probing = 1
#
## Saves one full RTT on connection setup where both ends support it.
#net.ipv4.tcp_fastopen = 3
#
## Accept queues sized for many short-lived proxied connections.
#net.core.netdev_max_backlog = 16384
#net.core.somaxconn = 8192
#net.ipv4.tcp_max_syn_backlog = 8192
#net.ipv4.tcp_fin_timeout = 15
#net.ipv4.tcp_tw_reuse = 1
#__END_SYSCTL__

#__BEGIN_SYSCTL_BBR__
## /etc/sysctl.d/99-smartdns-bbr.conf
##
## Written only when the operator asks for it, because congestion control is
## machine-wide: it changes every connection on the box, not just this service's.
##
## For this workload it is the single most useful setting there is. The upstream
## leg is a 90 ms Iran -> Frankfurt hop, and the stock algorithm reads loss as
## congestion and backs off - on a long fat pipe that leaves most of the
## capacity unused. BBR paces by measured bandwidth instead, and fq is the
## queueing discipline it expects.
##
## Remove this file and reboot, or re-run the installer and answer no, to go
## back to the kernel default.
#net.core.default_qdisc = fq
#net.ipv4.tcp_congestion_control = bbr
#__END_SYSCTL_BBR__

#__BEGIN_BYPASS__
## /etc/dnsmasq.d/bypass.conf
##
## Names that must NOT be hijacked, even though a parent domain is routed.
## dnsmasq resolves by longest match, so these win over address=/<parent>/...
##
## Two separate reasons a name lands here. Both were found in real packet
## captures, and each cost a broken game before it was understood.
##
## 1. The service is not on TCP 443. The relay listens only on 80 and 443, so
##    pointing such a name at it makes the client fire SYNs into a void and retry
##    forever. EA's game stack is full of these:
##
##      gosredirector.ea.com   TCP 42130 / 42230   game-server redirector
##      blaze.ea.com           TCP 15000-15100     the actual game servers
##      gameservices.ea.com    TCP 10010, 11000    QoS coordinator, match stats
##      tnt-ea.com             TCP 8095            realtime messaging
##
## 2. The service is reachable from Iran anyway, and routing it costs something.
##    ps5.np.playstation.net is the console's STUN server as well as a PSN API
##    host, and it answers fine from an Iranian address - routing it sent NAT
##    detection to our own single-homed coturn instead of Sony's pair, which
##    cannot classify the NAT properly. Only gst.prod.dl.playstation.net actually
##    needs the exit (it does not complete TLS from Iran at all); the rest of
##    prod.dl and the playstation.com API stay routed with it.
##
##      np.playstation.net      ps5.np - STUN + PSN API
##      np.dl.playstation.net   envelope2, uef, gs-sec.ww
##
##    The same reasoning was tried for Epic's backend and reverted - see below -
##    so verify per-name rather than assuming the rule generalises.
##
##    Epic's game backend is the other case, and the important one. Fortnite gets
##    into a match when ol.epicgames.com and friends resolve directly, and does
##    not when they are routed - matchmaking has to come from the same address the
##    console later plays from, or the game server ignores the gameplay packets.
##
##    I reverted this once on the strength of a capture that seemed to disprove
##    it. The capture was confounded: the bypass had left the console on an Epic
##    address that is unreachable from Iran, so the test failed for an unrelated
##    reason. Epic round-robins each name across many addresses and a few are
##    dead from here - one in thirty-three when sampled - which is why Fortnite
##    worked on some attempts and not others. epic-pin handles that by probing
##    each address and pinning only the ones that answer.
##
##      ol.epicgames.com                   account, fortnite, datarouter, fngw
##      ogs.live.on.epicgames.com          habanero, discovery
##      edea.live.use1a.on.epicgames.com   prm-dialogue
##
##    Still routed on purpose: epicgames.com itself (www and store are 403 from
##    Iran), cdn2.unrealengine.com and cdn-0001.qstv.on.epicgames.com.
##
##    core.windows.net is a third kind again: routing it is *demonstrably* broken.
##    A ClientHello for any *.core.windows.net name arrives at the exit with the SNI
##    missing - nginx logged sni="-" and dropped it - while an equally long test
##    hostname and every other domain came through intact. Something on the
##    Iran->exit leg mangles those particular handshakes. The same host answers 400
##    when reached directly from the relay, so direct beats routed here.
##
## Add more with:  smartdns bypass <domain>
#
#server=/gosredirector.ea.com/1.1.1.1
#server=/gosredirector.ea.com/8.8.8.8
#server=/blaze.ea.com/1.1.1.1
#server=/blaze.ea.com/8.8.8.8
#server=/gameservices.ea.com/1.1.1.1
#server=/gameservices.ea.com/8.8.8.8
#server=/tnt-ea.com/1.1.1.1
#server=/tnt-ea.com/8.8.8.8
#server=/np.playstation.net/1.1.1.1
#server=/np.playstation.net/8.8.8.8
#server=/np.dl.playstation.net/1.1.1.1
#server=/np.dl.playstation.net/8.8.8.8
#server=/ol.epicgames.com/1.1.1.1
#server=/ol.epicgames.com/8.8.8.8
#server=/ogs.live.on.epicgames.com/1.1.1.1
#server=/ogs.live.on.epicgames.com/8.8.8.8
#server=/edea.live.use1a.on.epicgames.com/1.1.1.1
#server=/edea.live.use1a.on.epicgames.com/8.8.8.8
#server=/core.windows.net/1.1.1.1
#server=/core.windows.net/8.8.8.8
#__END_BYPASS__

#__BEGIN_NO_AAAA__
## /etc/dnsmasq.d/no-aaaa.conf
##
## The relay and the exit are IPv4-only: nginx proxies over IPv4 and every
## address= record is an IPv4 address. But dnsmasq's address= only answers A
## queries - AAAA is forwarded upstream untouched. A dual-stack client therefore
## asks AAAA, gets the service's real IPv6 address, and connects straight to it,
## walking around the proxy entirely. Every routed domain leaks this way.
##
## The Xbox found it. catalog.gamepass.com answered A with the relay and AAAA with
## real Akamai addresses (2a02:26f0:3500:...), so the console went over IPv6, never
## touched us, and its game library never loaded. Its DNS log showed the giveaway:
##
##   query[AAAA] titlestorage.xboxlive.com  -> forwarded to 1.1.1.1 -> CNAME
##   query[A]    titlestorage.xboxlive.com  -> config is <relay>
##
## Answering NODATA for AAAA makes clients fall back cleanly to IPv4, which is the
## only path this setup can carry. It is global rather than per-domain on purpose:
## any AAAA we hand out is a route around our own proxy, whatever the name.
#filter-AAAA
#__END_NO_AAAA__

#__BEGIN_EXIT_NGINX__
## Smart DNS exit node (abroad) - nginx.conf
## Based on https://github.com/rohammosalli/smart-dns/blob/master/nginx.conf
#worker_processes  auto;
#
## Each proxied stream connection holds two descriptors, client side and
## upstream side, so the effective ceiling is half this number. The default soft
## limit is 1024, which caps the box at ~500 concurrent connections no matter
## what worker_connections says - a PS5 game download opens far more than that in
## parallel and the surplus gets reset mid-transfer.
#worker_rlimit_nofile 65535;
#load_module /usr/lib/nginx/modules/ngx_stream_module.so;
#
#events {
#    worker_connections  15000;
#    multi_accept off;
#}
#
#http {
#    access_log off;
#    resolver 1.1.1.1 ipv6=off;
#    resolver_timeout 5s;
#
#    # Console download CDNs are served over plain HTTP. Both Sony and Microsoft
#    # put theirs on Akamai's HTTP-only network:
#    #
#    #   gst.prod.dl.playstation.net -> ... -> ...edgesuite.net
#    #   assets1.xboxlive.com        -> ... -> ...edgesuite.net
#    #
#    # Those edges answer port 443 with a generic a248.e.akamai.net certificate
#    # that names no console host at all. Redirecting port 80 to https, as this
#    # file used to, therefore sent the console to a certificate it correctly
#    # refused. On the PS5 that was eight TLS alerts and a dead download; on the
#    # Xbox it was a download that never started at all, with the console
#    # re-resolving assets1.xboxlive.com dozens of times a minute.
#    #
#    # Forward these over HTTP instead of redirecting. Scoped to the console
#    # domains deliberately: the relay's port 80 is open to the internet, and a
#    # forward proxy that accepted any Host would be an open proxy.
#    server {
#        listen 80;
#        listen [::]:80;
#        server_name ~^.*\.(playstation\.(net|com)|xboxlive\.com|gamepass\.com)$;
#        allow __RELAY_IP__;
#        # The tunnel, when there is one: its end on this machine hands each
#        # connection to nginx from loopback. Nothing else can arrive from here.
#        allow 127.0.0.1;
#        deny all;
#
#        location / {
#            proxy_pass http://$http_host$request_uri;
#            proxy_set_header Host $http_host;
#            proxy_http_version 1.1;
#            proxy_set_header Connection "";
#            # Game data is large and range-requested; buffering it here would
#            # add latency for no gain.
#            proxy_buffering off;
#            proxy_request_buffering off;
#            proxy_connect_timeout 10s;
#            proxy_send_timeout 10m;
#            proxy_read_timeout 10m;
#
#            # Not every host under these domains actually serves plain HTTP -
#            # packages.xboxlive.com does not, and proxying it produced a 504
#            # where it used to get a clean redirect. Fall back to the old
#            # behaviour when the upstream cannot be reached over HTTP, so this
#            # can only help and never takes something away.
#            proxy_intercept_errors on;
#            error_page 502 504 = @https_redirect;
#        }
#
#        location @https_redirect {
#            return 301 https://$http_host$request_uri;
#        }
#    }
#
#    # Everything else keeps the old behaviour.
#    server {
#        listen 80 default_server;
#        listen [::]:80 default_server;
#        server_name _;
#        return 301 https://$host$request_uri;
#    }
#}
#
#stream {
#    # A TLS client should never send a bare IP as SNI. When one does, blindly
#    # forwarding to $ssl_preread_server_name:443 sends the session straight back
#    # at the relay, which forwards it here again - an infinite loop that pins
#    # both boxes. Blackhole those, and empty SNI, into an unresolvable upstream
#    # so the session is dropped instead.
#    map $ssl_preread_server_name $target {
#        default                 $ssl_preread_server_name;
#        ""                      "";
#        ~^[0-9.]+$              "";
#        ~^\[?[0-9a-fA-F:]+\]?$  "";
#    }
#
#    # Where each name is sent from here. Everything leaves over IPv4, as it
#    # always has. A blackholed $target is still ":443", which nginx cannot
#    # resolve, so those sessions are still dropped rather than looped.
#    map $target $upstream {
#        default  $target:443;
#        # google-v6 begin
#        # Google's own names go to the hop below, which reaches them over IPv6.
#        # Google refuses Gemini, AI Studio, NotebookLM and Labs to some exits'
#        # IPv4 addresses: 403 over IPv4 and the real page over IPv6, from the
#        # same machine a second apart - most likely because it has come to
#        # place that address in a sanctioned country. Only Google's names,
#        # because most of the rest of the list has no IPv6 at all. The
#        # installer leaves this out on an exit without working IPv6.
#        ~(^|\.)(google\.com|googleapis\.com|gstatic\.com|googleusercontent\.com|google|withgoogle\.com|googlevideo\.com|ggpht\.com|gvt1\.com)$  127.0.0.1:8446;
#        # google-v6 end
#    }
#
#    # Only the Iran relay may use this proxy. Prevents open-proxy abuse.
#    server {
#        resolver 1.1.1.1 ipv6=off;
#        listen 443;
#        allow __RELAY_IP__;
#        # The tunnel, when there is one: its end on this machine hands each
#        # connection to nginx from loopback. Nothing else can arrive from here.
#        allow 127.0.0.1;
#        deny all;
#        ssl_preread on;
#        proxy_connect_timeout 10s;
#        proxy_pass $upstream;
#    }
#    # google-v6 begin
#
#    # The IPv6 hop: the same pass-through, asking the resolver for AAAA
#    # records only. On loopback, so nothing outside this machine reaches it;
#    # 8446 is on the list of ports the admin panel may not take.
#    server {
#        listen 127.0.0.1:8446;
#        resolver 1.1.1.1 ipv4=off;
#        ssl_preread on;
#        proxy_connect_timeout 10s;
#        proxy_pass $ssl_preread_server_name:443;
#    }
#    # google-v6 end
#}
#__END_EXIT_NGINX__

#__BEGIN_RELAY_NGINX__
## Smart DNS relay (inside Iran) -> exit node abroad
#worker_processes  auto;
#
## Each proxied stream connection holds two descriptors, client side and
## upstream side, so the effective ceiling is half this number. The default soft
## limit is 1024, which caps the box at ~500 concurrent connections no matter
## what worker_connections says - a PS5 game download opens far more than that in
## parallel and the surplus gets reset mid-transfer.
#worker_rlimit_nofile 65535;
#load_module __MODULE_PATH__;
#
#events {
#    worker_connections  15000;
#    multi_accept off;
#}
#
#stream {
#    # tunnel begin
#    # With a tunnel, its end on this machine is the way to the exit, and the
#    # exit's own address is only the fallback: nginx turns to a backup server
#    # when the first refuses, which is what the tunnel's local port does while
#    # the tunnel is down. Without one, this block is not here at all.
#    upstream to_exit_https {
#        server 127.0.0.1:18443;
#        server __EXIT_IP__:443 backup;
#    }
#    upstream to_exit_http {
#        server 127.0.0.1:18080;
#        server __EXIT_IP__:80 backup;
#    }
#    # tunnel end
#
#    # Which exit each customer's connections leave by. The installer writes
#    # it with nothing but the default - the exit above - and smartdns-sync
#    # rewrites it from the exits the panel lists and the one each customer is
#    # on: a map on their address, and one upstream per extra exit with this
#    # relay's own exit as its backup. An address not in it takes the default,
#    # which is everybody until the first sync, and everybody on a relay with
#    # one exit. A file of its own, so rewriting it never touches this one.
#    include /etc/nginx/smartdns-exits.conf;
#
#    server {
#        listen 443;
#        proxy_connect_timeout 10s;
#        proxy_timeout 10m;
#        proxy_pass $smartdns_exit_https;
#    }
#
#    # Port 80 is forwarded rather than answered. It used to return a 301 to
#    # https here, which broke PlayStation downloads: their CDN is HTTP-only and
#    # serves a mismatched certificate on 443, so the console followed our
#    # redirect straight into a TLS failure. The exit decides what to do with
#    # each Host now - proxying playstation traffic, redirecting the rest.
#    server {
#        listen 80;
#        proxy_connect_timeout 10s;
#        proxy_timeout 10m;
#        proxy_pass $smartdns_exit_http;
#    }
#}
#__END_RELAY_NGINX__

#__BEGIN_TURNSERVER__
## /etc/turnserver.conf  -  STUN only, no TURN relaying
##
## Why this exists: the relay answers *.playstation.net with its own address, and
## ps5.np.playstation.net is the PS5's STUN server. A capture showed the console
## sending eight STUN Binding Requests to the relay and getting nothing back, so
## NAT type detection failed outright - which hurts FUT matchmaking more than any
## amount of ping tuning.
##
## The console sends those Binding Requests over UDP straight to the relay, not
## through the nginx proxy, so the relay genuinely observes the console's real
## public address and can answer correctly. Serving STUN here is the honest fix;
## it keeps PSN's HTTPS traffic on the routed path so sign-in still works.
##
## stun-only is the important line. Without it coturn would also offer TURN
## relaying, and with no-auth that is an open relay for anyone on the internet.
#
#listening-port=3478
#listening-ip=__RELAY_IP__
#external-ip=__RELAY_IP__
#
## Serve STUN Binding only. No allocations, ever.
#stun-only
#no-auth
#
## Nothing here needs TLS, and offering it only widens the surface.
#no-tls
#no-dtls
#no-cli
#
## No alt-listening-port: full RFC 3489 NAT classification needs a second public
## IP for the change-IP test, and this box has one. coturn will not bind the alt
## port on a single-homed host, so setting it just looks configured without being
## so. The console therefore learns its mapping but cannot classify the cone type,
## which lands it on NAT Type 2 (moderate) - the fix here is getting an answer at
## all instead of eight timeouts, and Type 2 plays online fine.
#
#no-multicast-peers
#no-loopback-peers
#fingerprint
#simple-log
#__END_TURNSERVER__

#__BEGIN_SMARTDNS__
##!/bin/bash
## smartdns - manage the sanction-bypass domain list
## usage: smartdns add|del|list|find|test|status [domain ...]
#set -euo pipefail
#
#CONF=/etc/dnsmasq.d/smart-dns.conf
#BYPASS=/etc/dnsmasq.d/bypass.conf
#IP=__RELAY_IP__
#
#need_root() { [ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }; }
#
#case "${1:-}" in
#  add)
#    need_root; shift
#    [ $# -gt 0 ] || { echo "usage: smartdns add <domain> [domain ...]"; exit 1; }
#    for d in "$@"; do
#      d=$(echo "$d" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*##; s/^\.//')
#      if grep -qxF "address=/$d/$IP" "$CONF"; then
#        echo "already present: $d"
#      else
#        echo "address=/$d/$IP" >> "$CONF"
#        echo "added: $d"
#      fi
#    done
#    dnsmasq --test -C /etc/dnsmasq.conf && systemctl restart dnsmasq && echo "dnsmasq reloaded"
#    ;;
#  del|rm)
#    need_root; shift
#    [ $# -gt 0 ] || { echo "usage: smartdns del <domain> [domain ...]"; exit 1; }
#    for d in "$@"; do
#      d=$(echo "$d" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*##; s/^\.//')
#      if grep -qxF "address=/$d/$IP" "$CONF"; then
#        sed -i "\#^address=/$d/$IP\$#d" "$CONF"
#        echo "removed: $d"
#      else
#        echo "not found: $d"
#      fi
#    done
#    systemctl restart dnsmasq && echo "dnsmasq reloaded"
#    ;;
#  bypass)
#    # exclude a subdomain from the hijack - for services that do NOT run on 443
#    # (e.g. EA's gosredirector uses TCP 42130/42230, hijacking it kills FC 25)
#    need_root; shift
#    [ $# -gt 0 ] || { echo "usage: smartdns bypass <domain> [domain ...]"; exit 1; }
#    for d in "$@"; do
#      d=$(echo "$d" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*##; s/^\.//')
#      if grep -qxF "server=/$d/1.1.1.1" "$BYPASS"; then
#        echo "already bypassed: $d"
#      else
#        printf 'server=/%s/1.1.1.1
#server=/%s/8.8.8.8
#' "$d" "$d" >> "$BYPASS"
#        echo "bypassed (resolves to its real IP now): $d"
#      fi
#    done
#    dnsmasq --test -C /etc/dnsmasq.conf && systemctl restart dnsmasq && echo "dnsmasq reloaded"
#    ;;
#  unbypass)
#    need_root; shift
#    for d in "$@"; do
#      d=$(echo "$d" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*##; s/^\.//')
#      sed -i "\#^server=/$d/#d" "$BYPASS" && echo "un-bypassed: $d"
#    done
#    systemctl restart dnsmasq && echo "dnsmasq reloaded"
#    ;;
#  list)
#    grep '^address=' "$CONF" | sed -E 's#^address=/([^/]+)/.*#\1#' | sort
#    ;;
#  find)
#    shift; grep -i "${1:-}" "$CONF" || echo "no match"
#    ;;
#  test)
#    shift
#    for d in "$@"; do
#      got=$(dig +short +time=5 @127.0.0.1 "$d" A | tr '\n' ' ')
#      if [ "$(echo "$got" | awk '{print $1}')" = "$IP" ]; then
#        printf "%-30s ROUTED   (%s)\n" "$d" "$got"
#      else
#        printf "%-30s direct   (%s)\n" "$d" "$got"
#      fi
#    done
#    ;;
#  status|"")
#    echo "domains routed : $(grep -c '^address=' "$CONF")"
#    echo "bypassed       : $(grep -c '^server=' "$BYPASS" 2>/dev/null || echo 0) rules"
#    echo "dnsmasq        : $(systemctl is-active dnsmasq) / $(systemctl is-enabled dnsmasq)"
#    echo "nginx          : $(systemctl is-active nginx) / $(systemctl is-enabled nginx)"
#    echo "relay target   : $(grep -oE 'proxy_pass [0-9.]+:443' /etc/nginx/nginx.conf | awk '{print $2}')"
#    echo
#    echo "listeners:"
#    ss -tulnp | grep -E ':53 |:80 |:443 ' | awk '{print "  " $1, $5, $NF}'
#    ;;
#  *)
#    echo "usage: smartdns {add|del|bypass|unbypass|list|find|test|status} [domain ...]"
#    exit 1
#    ;;
#esac
#__END_SMARTDNS__

#__BEGIN_NFTABLES__
## Smart DNS relay - access control and per-client traffic accounting.
##
## This file is the structure only: the table, its chains and its empty sets.
## The contents - which addresses are allowed and how much each has used - live
## in 20-smartdns-state.conf, written by `smartdns-acl save`. Keeping them apart
## means the installer can rewrite this file on every upgrade without losing
## anybody's allowance, and means a human can read the policy without wading
## through a few hundred counters.
##
## Nothing here blocks anything. Enforcement is a separate file again,
## 30-smartdns-enforce.conf, which exists only after `smartdns-acl enforce on`.
#
#table inet smartdns {
#    # The allowlist. Managed with `smartdns-acl add|del`, and from stage 2
#    # onwards by the panel's sync service. Each element carries the owner's
#    # name as an nftables comment, so the kernel's own copy is readable
#    # without consulting a database.
#    set allowed {
#        type ipv4_addr
#    }
#
#    # Per-client byte counters, one set per direction, both keyed on the
#    # client address.
#    #
#    # The update rules below match `ip saddr @allowed` first, so these sets
#    # only ever see addresses that are already registered. That is deliberate:
#    # a dynamic set that accepted every source would fill with the port scans
#    # this box gets around the clock, and the size cap would eventually start
#    # dropping real users' entries. Bounded by the customer count instead.
#    set up {
#        type ipv4_addr
#        flags dynamic
#        counter
#    }
#    set down {
#        type ipv4_addr
#        flags dynamic
#        counter
#    }
#
#    # Which shaping class each client belongs to, as a packet mark. Empty
#    # until somebody is given a speed limit; managed by `smartdns-shape`.
#    #
#    # The mark is the customer's account number, and tc has one class per
#    # mark. Marking here rather than matching addresses in tc keeps the
#    # address list in one place - this table - and makes the tc side a fixed
#    # set of rules that only changes when a customer's speed does.
#    map speed {
#        type ipv4_addr : mark
#    }
#
#    # Marks what we are about to send a client, so the queueing discipline on
#    # the way out can put it in that customer's class.
#    #
#    # The output hook, not postrouting: this box is a proxy, not a router, so
#    # every packet a customer receives is generated locally by nginx or
#    # dnsmasq. An address missing from the map is a lookup miss, which ends
#    # this rule and leaves the packet unmarked and unshaped.
#    chain shape {
#        type filter hook output priority mangle ; policy accept ;
#        meta mark set ip daddr map @speed
#    }
#
#    # Enforcement lands here. Empty unless `smartdns-acl enforce on` has been
#    # run. It sits at priority -10, ahead of the counting chains, so blocked
#    # packets are not billed to anyone.
#    chain gate {
#        type filter hook input priority -10 ; policy accept ;
#    }
#
#    # What the client sends us: DNS queries, and the TLS/HTTP requests it
#    # opens against the relay. Filtering on the service ports keeps our own
#    # SSH sessions and the box's housekeeping out of the customer's bill.
#    chain count_in {
#        type filter hook input priority 10 ; policy accept ;
#        ip saddr @allowed udp dport 53 update @up { ip saddr counter }
#        ip saddr @allowed tcp dport { 53, 80, 443 } update @up { ip saddr counter }
#    }
#
#    # What we send back. nginx talks to the exit node as a local process, from
#    # this same hook, but the exit's address is not in @allowed so that traffic
#    # is not counted - otherwise every byte would be billed twice.
#    chain count_out {
#        type filter hook output priority 10 ; policy accept ;
#        ip daddr @allowed udp sport 53 update @down { ip daddr counter }
#        ip daddr @allowed tcp sport { 53, 80, 443 } update @down { ip daddr counter }
#    }
#
#    # Amplification defence, unchanged. An open resolver is worth roughly its
#    # bandwidth to whoever finds it, and this box is easy to find.
#    chain input {
#        type filter hook input priority 0 ; policy accept ;
#        udp dport 53 meter dnsflood { ip saddr limit rate over 40/second burst 80 packets } drop
#    }
#}
#__END_NFTABLES__

#__BEGIN_SMARTDNS_ACL__
##!/bin/bash
## smartdns-acl - who may use this relay, and how much they have used
##
## usage: smartdns-acl add <ip> [name]     register an address
##        smartdns-acl del <ip>            unregister it
##        smartdns-acl list                everyone, with usage
##        smartdns-acl usage <ip>          one address
##        smartdns-acl reset <ip>|--all    zero the counters
##        smartdns-acl enforce on|off|status
##          --yes          do not ask for confirmation
##          --allow-empty  close it with nobody registered (the installer)
##        smartdns-acl save                persist to disk now
##
## Add --json to list or usage for output meant for the panel rather than a
## person. The panel will call this rather than touching nftables itself, so
## that there is one place where the rules about what is legal live.
#set -uo pipefail
#export PATH="$PATH:/usr/sbin:/sbin"
#
#TABLE="inet smartdns"
## Field separator for dump(). Deliberately not a tab: bash counts tabs as IFS
## whitespace, so a row whose name is empty collapses two separators into one
## and every column after it shifts left by one. That turned an unnamed address
## into a name of "0" and a byte count of "", which is how it was found.
#SEP=$'\x1f'
#STATE=/etc/nftables.d/20-smartdns-state.conf
#ENFORCE=/etc/nftables.d/30-smartdns-enforce.conf
## "Close this relay as soon as there is somebody to allow." The installer no
## longer writes it - it closes the relay itself - but relays installed before
## that still carry one, and the sync agent still acts on it, so `enforce off`
## has to keep clearing it. Opening a relay by hand and having a background
## agent shut it again half a minute later would be its own bug.
#AUTO=/etc/smart-dns/auto-enforce
#
#R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
#[ -t 1 ] || { R=; G=; Y=; N=; }
#
#die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
#root() { [ "$(id -u)" = 0 ] || die "run as root"; }
#
#have_table() { nft list table $TABLE >/dev/null 2>&1; }
#
#valid_ip() {
#    local ip="${1:-}" o n=0
#    case "$ip" in ""|*[!0-9.]*|*..*|.*|*.) return 1 ;; esac
#    for o in ${ip//./ }; do
#        [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] || return 1
#        n=$((n + 1))
#    done
#    [ "$n" = 4 ]
#}
#
## Everything that reads the ruleset goes through nft's JSON output and python,
## never through awk on the human-readable format. That format wraps long
## element lists at whatever width it feels like - which is exactly the sort of
## thing that works on a test box with three users and quietly mangles the
## fiftieth.
#dump() {
#    nft -j list table $TABLE 2>/dev/null | python3 -c '
#import json, sys
#
#def elements(doc, name):
#    for item in doc.get("nftables", []):
#        s = item.get("set")
#        if s and s.get("name") == name:
#            return s.get("elem", []) or []
#    return []
#
#def walk(elems):
#    # An element is a bare value until it carries a comment or a counter, at
#    # which point nft wraps it in {"elem": {...}}. Flatten both shapes.
#    out = {}
#    for e in elems:
#        val, comment, byts = e, "", 0
#        if isinstance(e, dict) and "elem" in e:
#            inner = e["elem"]
#            val = inner.get("val", "")
#            comment = inner.get("comment") or ""
#            byts = (inner.get("counter") or {}).get("bytes", 0)
#        if isinstance(val, dict):
#            val = val.get("prefix", {}).get("addr", "")
#        out[str(val)] = (comment, byts)
#    return out
#
#doc = json.load(sys.stdin)
#allowed = walk(elements(doc, "allowed"))
#up      = walk(elements(doc, "up"))
#down    = walk(elements(doc, "down"))
#for ip in sorted(allowed, key=lambda a: [int(p) for p in a.split(".")]):
#    print("%s\x1f%s\x1f%d\x1f%d" % (ip, allowed[ip][0],
#                                    up.get(ip, ("", 0))[1], down.get(ip, ("", 0))[1]))
#'
#}
#
#human() {
#    python3 -c '
#import sys
#n = float(sys.argv[1])
#for unit in ("B", "KB", "MB", "GB", "TB"):
#    if n < 1024 or unit == "TB":
#        print(("%d %s" if unit == "B" else "%.2f %s") % (n, unit))
#        break
#    n /= 1024
#' "$1"
#}
#
#save() {
#    root; have_table || die "the smartdns table is not loaded"
#    mkdir -p /etc/nftables.d
#    local tmp ip name u d
#    tmp="$(mktemp)"
#    {
#        echo "# Written by smartdns-acl. Do not edit by hand - it is"
#        echo "# regenerated from the running ruleset every few minutes."
#        echo "# Registered addresses and their usage as of $(date -Is)."
#        echo
#        while IFS="$SEP" read -r ip name u d; do
#            [ -n "$ip" ] || continue
#            if [ -n "$name" ]; then
#                printf 'add element inet smartdns allowed { %s comment "%s" }\n' "$ip" "$name"
#            else
#                printf 'add element inet smartdns allowed { %s }\n' "$ip"
#            fi
#            # Packet counts are not restored. Only bytes are billed, and
#            # carrying a packet count across a reboot buys nothing.
#            printf 'add element inet smartdns up { %s counter packets 0 bytes %s }\n' "$ip" "$u"
#            printf 'add element inet smartdns down { %s counter packets 0 bytes %s }\n' "$ip" "$d"
#        done < <(dump)
#    } > "$tmp"
#    # The sets already exist, so -c on a file of `add element` really does
#    # validate what we are about to leave behind for the next boot.
#    if nft -c -f "$tmp" >/dev/null 2>&1; then
#        mv "$tmp" "$STATE"; chmod 644 "$STATE"
#    else
#        rm -f "$tmp"; die "the generated state file does not parse - not saving"
#    fi
#}
#
#registered() { dump | cut -d"$SEP" -f1 | grep -qxF "$1"; }
#
#case "${1:-}" in
#
#add)
#    root; shift
#    ip="${1:-}"; name="${2:-}"
#    valid_ip "$ip" || die "not an IPv4 address: ${ip:-<missing>}"
#    have_table || die "the smartdns table is not loaded; run the installer"
#    case "$name" in *'"'*|*'\'*) die "a name cannot contain a quote or a backslash" ;; esac
#    registered "$ip" && die "$ip is already registered"
#    if [ -n "$name" ]; then
#        nft add element $TABLE allowed "{ $ip comment \"$name\" }" || die "nft refused the address"
#    else
#        nft add element $TABLE allowed "{ $ip }" || die "nft refused the address"
#    fi
#    # Seed both counters so the address appears in `list` before it has sent
#    # a single packet. Without this a freshly added user looks like a failure.
#    nft add element $TABLE up   "{ $ip counter packets 0 bytes 0 }" 2>/dev/null
#    nft add element $TABLE down "{ $ip counter packets 0 bytes 0 }" 2>/dev/null
#    save
#    printf '%sadded%s %s%s\n' "$G" "$N" "$ip" "${name:+  ($name)}"
#    ;;
#
#del|rm|remove)
#    root; shift
#    ip="${1:-}"
#    valid_ip "$ip" || die "not an IPv4 address: ${ip:-<missing>}"
#    have_table || die "the smartdns table is not loaded"
#    registered "$ip" || die "$ip is not registered"
#    nft delete element $TABLE allowed "{ $ip }" || die "nft refused the removal"
#    nft delete element $TABLE up   "{ $ip }" 2>/dev/null
#    nft delete element $TABLE down "{ $ip }" 2>/dev/null
#    save
#    printf '%sremoved%s %s\n' "$G" "$N" "$ip"
#    ;;
#
#list|ls)
#    have_table || die "the smartdns table is not loaded"
#    if [ "${2:-}" = --json ]; then
#        dump | python3 -c '
#import json, sys
#rows = []
#for line in sys.stdin:
#    if not line.strip():
#        continue
#    ip, name, u, d = line.rstrip("\n").split("\x1f")
#    rows.append({"ip": ip, "name": name, "up": int(u), "down": int(d),
#                 "total": int(u) + int(d)})
#print(json.dumps(rows))
#'
#        exit 0
#    fi
#    rows="$(dump)"
#    if [ -z "$rows" ]; then
#        echo "no addresses registered yet - add one with: smartdns-acl add <ip> [name]"
#        exit 0
#    fi
#    printf '%-16s %-16s %12s %12s %12s\n' ADDRESS NAME UP DOWN TOTAL
#    while IFS="$SEP" read -r ip name u d; do
#        printf '%-16s %-16s %12s %12s %12s\n' \
#            "$ip" "${name:--}" "$(human "$u")" "$(human "$d")" "$(human $((u + d)))"
#    done <<< "$rows"
#    ;;
#
#usage)
#    have_table || die "the smartdns table is not loaded"
#    ip="${2:-}"
#    valid_ip "$ip" || die "not an IPv4 address: ${ip:-<missing>}"
#    registered "$ip" || die "$ip is not registered"
#    # Field-exact, not a substring: grepping for "1.2.3.4" would also find
#    # the row belonging to 11.2.3.4.
#    IFS="$SEP" read -r _ name u d < <(dump | awk -F"$SEP" -v a="$ip" '$1 == a')
#    if [ "${3:-}" = --json ]; then
#        printf '{"ip":"%s","name":"%s","up":%s,"down":%s,"total":%s}\n' \
#            "$ip" "$name" "$u" "$d" "$((u + d))"
#    else
#        printf '%s%s\n' "$ip" "${name:+  ($name)}"
#        printf '    up    %s\n' "$(human "$u")"
#        printf '    down  %s\n' "$(human "$d")"
#        printf '    total %s\n' "$(human $((u + d)))"
#    fi
#    ;;
#
#reset)
#    root; shift
#    have_table || die "the smartdns table is not loaded"
#    if [ "${1:-}" = --all ]; then
#        targets="$(dump | cut -d"$SEP" -f1)"
#    else
#        valid_ip "${1:-}" || die "usage: smartdns-acl reset <ip>|--all"
#        registered "$1" || die "$1 is not registered"
#        targets="$1"
#    fi
#    for ip in $targets; do
#        for s in up down; do
#            nft delete element $TABLE "$s" "{ $ip }" 2>/dev/null
#            nft add element $TABLE "$s" "{ $ip counter packets 0 bytes 0 }" 2>/dev/null
#        done
#        printf '%sreset%s %s\n' "$G" "$N" "$ip"
#    done
#    save
#    ;;
#
#enforce)
#    have_table || die "the smartdns table is not loaded"
#    case "${2:-status}" in
#    on)
#        root
#        count="$(dump | grep -c . )"
#        yes=no; empty=no
#        for flag in "$@"; do
#            case "$flag" in
#                --yes) yes=yes ;;
#                --allow-empty) empty=yes ;;
#            esac
#        done
#        # Switching this on with an empty allowlist cuts off every user of the
#        # service at once. For somebody typing it at a terminal that is almost
#        # always a mistake, and one that feels irreversible from the far end of
#        # a broken connection - so it refuses.
#        #
#        # The installer passes --allow-empty, because there it is not a
#        # mistake: a relay being installed has no users to cut off, and the
#        # list being empty is exactly why it has to be closed. Left open, it is
#        # a relay anybody who learns its address can use for free.
#        if [ "$count" -eq 0 ] && [ "$empty" != yes ]; then
#            die "the allowlist is empty - everyone would be cut off.
#    Register at least your own address first:  smartdns-acl add <your ip> me"
#        fi
#        if [ "$yes" != yes ] && [ -t 0 ]; then
#            printf '%s%s address(es) registered.%s Everyone else loses DNS, HTTP\n' "$Y" "$count" "$N"
#            printf 'and HTTPS through this relay immediately. SSH is not affected.\n'
#            printf 'Continue? [y/N] '
#            read -r ans
#            case "$ans" in y|Y|yes) ;; *) echo "cancelled"; exit 1 ;; esac
#        fi
#        mkdir -p /etc/nftables.d
#        cat > "$ENFORCE" <<'RULES'
## Access control, switched on by `smartdns-acl enforce on`.
## Delete this file, or run `smartdns-acl enforce off`, to open the relay again.
## There is deliberately no rule for SSH: getting the allowlist wrong must never
## cost you access to the machine.
#
## The machine talks to its own resolver: epic-pin probes it every ten minutes,
## and the installer's checks query it directly. Neither is a customer and
## neither is in the allowlist, so without this line switching enforcement on
## would quietly break both.
#add rule inet smartdns gate iif "lo" accept
#
#add rule inet smartdns gate ip saddr != @allowed udp dport 53 drop
#add rule inet smartdns gate ip saddr != @allowed tcp dport { 53, 80, 443 } drop
#RULES
#        nft flush chain $TABLE gate
#        nft -f "$ENFORCE" || { rm -f "$ENFORCE"; die "nft refused the rules; nothing changed"; }
#        if [ "$count" -eq 0 ]; then
#            printf '%senforcing%s - nobody may use this relay yet.\n' "$G" "$N"
#            printf 'Addresses are let in as customers register them.\n'
#        else
#            printf '%senforcing%s - %s address(es) may use this relay\n' \
#                   "$G" "$N" "$count"
#        fi
#        ;;
#    off)
#        root
#        nft flush chain $TABLE gate
#        rm -f "$ENFORCE"
#        # Also cancel the installer's standing instruction to close the relay
#        # once somebody registers. Opening it by hand and having a background
#        # agent shut it again half a minute later would be its own bug.
#        if [ -f "$AUTO" ]; then
#            rm -f "$AUTO"
#            printf 'automatic enforcement cancelled too\n'
#        fi
#        printf '%sopen%s - nothing is being blocked\n' "$Y" "$N"
#        ;;
#    status)
#        if nft list chain $TABLE gate 2>/dev/null | grep -q drop; then
#            printf 'enforcing - %s address(es) allowed\n' "$(dump | grep -c .)"
#        else
#            printf 'open - counting only, nothing is blocked\n'
#        fi
#        ;;
#    *) die "usage: smartdns-acl enforce on|off|status" ;;
#    esac
#    ;;
#
#save)
#    save; echo "saved to $STATE"
#    ;;
#
#*)
#    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
#    exit 1
#    ;;
#esac
#__END_SMARTDNS_ACL__

#__BEGIN_SMARTDNS_SHAPE__
##!/usr/bin/env python3
#"""smartdns-shape - per-customer download speed limits on the relay.
#
#usage: smartdns-shape apply      read the wanted state as JSON on stdin
#       smartdns-shape list       show what is in force
#       smartdns-shape off        remove all shaping, leaving traffic alone
#
#The wanted state is a list of {"ip", "mark", "kbps"}. kbps is kilobits per
#second; a customer with no limit is simply absent from it.
#
#Why this shape and not another
#------------------------------
#Only the download direction is shaped - what the relay sends to the customer.
#That is the direction a customer notices, and on this box it is also the easy
#one: the relay is a proxy rather than a router, so every packet a customer
#receives is generated locally and leaves through one interface, where a
#queueing discipline can see it. Shaping the upload direction would mean
#policing on ingress through an ifb device, which drops rather than queues and
#buys very little for a service whose traffic is overwhelmingly inbound.
#
#htb, not a rate limit in nftables. nftables can drop above a rate, and drops
#are not shaping: TCP reacts to loss by collapsing its window, so a customer
#capped that way gets a connection that stalls and lurches rather than one that
#runs steadily a little slower. htb queues instead, and hands each class to
#fq_codel so a customer's own bulk download cannot drown out their own game.
#
#The address list stays in nftables, not here. nftables marks each packet with
#the customer's account number and tc matches the mark, so the tc side is a
#fixed set of rules that changes only when somebody's speed changes - and the
#question "which addresses does this box know about" keeps exactly one answer.
#"""
#import json
#import re
#import subprocess
#import sys
#
## Root class: the ceiling every customer class hangs under. Deliberately far
## above any real link speed, because it is not a limit - it is the parent htb
## needs, and setting it near the true line rate would cap customers who have
## no limit of their own.
#ROOT_RATE = "10gbit"
#
## Where unmarked traffic goes: everything that is not a shaped customer,
## including our own ssh session and the sync agent. Unshaped on purpose.
#DEFAULT_MINOR = 0xFFFF
#
## Customer classes live above this, never at it. The mark identifies the
## customer everywhere else - in the nftables map and as the fw filter's handle
## - but it cannot be the class minor as well, because minor 1 is the root
## class every customer class hangs under and 1: is the root qdisc's own
## handle. The first customer ever shaped has mark 1, so both collided at once:
## `tc qdisc replace ... parent 1:1 handle 1: fq_codel` was refused every
## thirty seconds, and the class that did get created replaced the root class,
## quietly capping the whole relay at that one customer's speed.
#CLASS_BASE = 0x100
#
## Marks are account numbers, and this one is taken by the default class.
#MAX_MARK = DEFAULT_MINOR - CLASS_BASE - 1
#
#TABLE = "inet smartdns"
#MAP = "speed"
#
#R = "\033[31m"; G = "\033[32m"; Y = "\033[33m"; N = "\033[0m"
#if not sys.stdout.isatty():
#    R = G = Y = N = ""
#
#
#def die(msg):
#    sys.stderr.write("%serror:%s %s\n" % (R, N, msg))
#    raise SystemExit(1)
#
#
#def run(*args, **kw):
#    return subprocess.run(list(args), capture_output=True, text=True,
#                          timeout=kw.get("timeout", 30))
#
#
#def tc(*args, check=True):
#    r = run("tc", *args)
#    if check and r.returncode != 0:
#        die("tc %s: %s" % (" ".join(args), r.stderr.strip()))
#    return r
#
#
#def nft(*args, check=True):
#    r = run("nft", *args)
#    if check and r.returncode != 0:
#        die("nft %s: %s" % (" ".join(args), r.stderr.strip()))
#    return r
#
#
#def wan():
#    """The interface customer traffic leaves by - the default route's."""
#    r = run("ip", "-o", "route", "get", "1.1.1.1")
#    if r.returncode != 0:
#        die("cannot work out which interface to shape: %s" % r.stderr.strip())
#    fields = r.stdout.split()
#    if "dev" not in fields:
#        die("no device in: %s" % r.stdout.strip())
#    return fields[fields.index("dev") + 1]
#
#
## ------------------------------------------------------------------- state
#RATE_RE = re.compile(r"\brate\s+(\d+(?:\.\d+)?)([KMGT]?)bit", re.I)
#CLASS_RE = re.compile(r"^class\s+htb\s+1:([0-9a-f]+)\b", re.I)
#SCALE = {"": 0.001, "K": 1, "M": 1000, "G": 1000000, "T": 1000000000}
#
#
#def current_classes(dev):
#    """{minor: rate in kbit} for the customer classes that exist now.
#
#    Two output formats, because `tc -j` is not honoured everywhere: iproute2
#    6.1 emits JSON for `qdisc show` but silently prints the plain text format
#    for `class show`, which json.loads then chokes on. Rather than pin a
#    version, read whichever came back - the text format has been stable for
#    twenty years and is trivial to parse.
#    """
#    r = tc("-j", "class", "show", "dev", dev, check=False)
#    if r.returncode != 0 or not r.stdout.strip():
#        return {}
#    out = {}
#    text = r.stdout.lstrip()
#    if text.startswith("["):
#        for c in json.loads(text):
#            handle = c.get("handle", "")
#            major, _, minor = handle.partition(":")
#            if major != "1" or not minor:
#                continue
#            m = int(minor, 16)
#            if m > CLASS_BASE and m != DEFAULT_MINOR:
#                # Keyed by mark, so the caller compares like with like.
#                out[m - CLASS_BASE] = int(c.get("rate", 0)) // 1000
#        return out
#    for line in text.splitlines():
#        hit = CLASS_RE.match(line.strip())
#        if not hit:
#            continue
#        m = int(hit.group(1), 16)
#        if m <= CLASS_BASE or m == DEFAULT_MINOR:
#            continue
#        rate = RATE_RE.search(line)
#        out[m - CLASS_BASE] = (int(float(rate.group(1)) * SCALE[rate.group(2).upper()])
#                               if rate else 0)
#    return out
#
#
#def ensure_root(dev):
#    """Put the htb root in place if it is not there already.
#
#    Replacing it when it already exists would throw away every customer class
#    on a run that was meant to change one of them, so this checks first.
#    """
#    r = tc("-j", "qdisc", "show", "dev", dev, check=False)
#    have_htb = False
#    if r.returncode == 0 and r.stdout.strip():
#        have_htb = any(q.get("kind") == "htb" and q.get("handle") == "1:"
#                       for q in json.loads(r.stdout))
#    if have_htb:
#        return False
#    tc("qdisc", "replace", "dev", dev, "root", "handle", "1:",
#       "htb", "default", format(DEFAULT_MINOR, "x"))
#    tc("class", "replace", "dev", dev, "parent", "1:", "classid", "1:1",
#       "htb", "rate", ROOT_RATE, "ceil", ROOT_RATE)
#    tc("class", "replace", "dev", dev, "parent", "1:1",
#       "classid", "1:%x" % DEFAULT_MINOR,
#       "htb", "rate", ROOT_RATE, "ceil", ROOT_RATE)
#    tc("qdisc", "replace", "dev", dev, "parent", "1:%x" % DEFAULT_MINOR,
#       "handle", "%x:" % DEFAULT_MINOR, "fq_codel")
#    return True
#
#
#def minor_for(mark):
#    """The class minor a mark gets. Never 1, never DEFAULT_MINOR."""
#    return CLASS_BASE + mark
#
#
#def add_class(dev, mark, kbps):
#    rate = "%dkbit" % kbps
#    minor = minor_for(mark)
#    tc("class", "replace", "dev", dev, "parent", "1:1",
#       "classid", "1:%x" % minor, "htb", "rate", rate, "ceil", rate,
#       # A burst of roughly a tenth of a second, so a limit reads as a steady
#       # speed rather than as a stutter, without letting a customer bank
#       # seconds of idle time into a spike the operator pays for.
#       "burst", "%dkbit" % max(15, kbps // 10))
#    tc("qdisc", "replace", "dev", dev, "parent", "1:%x" % minor,
#       "handle", "%x:" % minor, "fq_codel")
#    # The filter is keyed on the mark, so re-adding an identical one would
#    # stack duplicates. Delete first, ignore the failure when there is none.
#    tc("filter", "del", "dev", dev, "parent", "1:", "protocol", "ip",
#       "prio", "1", "handle", str(mark), "fw", check=False)
#    tc("filter", "add", "dev", dev, "parent", "1:", "protocol", "ip",
#       "prio", "1", "handle", str(mark), "fw", "flowid", "1:%x" % minor)
#
#
#def drop_class(dev, mark):
#    minor = minor_for(mark)
#    tc("filter", "del", "dev", dev, "parent", "1:", "protocol", "ip",
#       "prio", "1", "handle", str(mark), "fw", check=False)
#    tc("qdisc", "del", "dev", dev, "parent", "1:%x" % minor, check=False)
#    tc("class", "del", "dev", dev, "parent", "1:1",
#       "classid", "1:%x" % minor, check=False)
#
#
#def set_map(wanted):
#    """Replace the address-to-mark map in one step.
#
#    Flush and refill rather than working out the difference: the map is at
#    most a few hundred entries, and a customer must never be briefly missing
#    from it because their speed changed.
#    """
#    nft("flush", "map", *TABLE.split(), MAP)
#    if not wanted:
#        return
#    elements = ", ".join("%s : %d" % (w["ip"], w["mark"]) for w in wanted)
#    nft("add", "element", *TABLE.split(), MAP, "{ %s }" % elements)
#
#
## ------------------------------------------------------------------ verbs
#def apply_wanted(wanted):
#    dev = wan()
#    seen = set()
#    clean = []
#    for w in wanted:
#        try:
#            mark, kbps = int(w["mark"]), int(w["kbps"])
#        except (KeyError, TypeError, ValueError):
#            die("bad entry: %r" % (w,))
#        if not 1 <= mark <= MAX_MARK:
#            die("mark %d is outside 1..%d" % (mark, MAX_MARK))
#        if mark in seen:
#            die("mark %d appears twice" % mark)
#        if kbps <= 0:
#            continue                     # no limit means no class
#        seen.add(mark)
#        clean.append({"ip": w["ip"], "mark": mark, "kbps": kbps})
#
#    if not clean:
#        # Nobody is limited, so leave the interface as the kernel set it up.
#        # htb replaces the multi-queue root, which costs a little throughput on
#        # a busy relay - not much, but not worth paying to shape nobody.
#        return teardown(dev, "no speed limits set")
#
#    built = ensure_root(dev)
#    have = current_classes(dev)
#    want = {w["mark"]: w["kbps"] for w in clean}
#
#    added = changed = removed = 0
#    for mark, kbps in sorted(want.items()):
#        if mark not in have:
#            added += 1
#        elif have[mark] != kbps:
#            changed += 1
#        else:
#            continue
#        add_class(dev, mark, kbps)
#    for mark in sorted(set(have) - set(want)):
#        drop_class(dev, mark)
#        removed += 1
#
#    set_map(clean)
#    if built or added or changed or removed:
#        print("shaping on %s: %d limited (+%d ~%d -%d)%s"
#              % (dev, len(clean), added, changed, removed,
#                 " [root created]" if built else ""))
#    return 0
#
#
#def show():
#    dev = wan()
#    have = current_classes(dev)
#    r = nft("-j", "list", "map", *TABLE.split(), MAP, check=False)
#    by_mark = {}
#    if r.returncode == 0 and r.stdout.strip():
#        for item in json.loads(r.stdout).get("nftables", []):
#            for e in (item.get("map", {}).get("elem") or []):
#                if isinstance(e, list) and len(e) == 2:
#                    by_mark[int(e[1])] = e[0]
#    if not have:
#        print("no speed limits in force on %s" % dev)
#        return 0
#    print("%-16s %-8s %s" % ("ADDRESS", "MARK", "LIMIT"))
#    for mark in sorted(have):
#        kbps = have[mark]
#        speed = ("%.1f Mbit/s" % (kbps / 1000.0)) if kbps >= 1000 \
#            else "%d kbit/s" % kbps
#        print("%-16s %-8d %s" % (by_mark.get(mark, "?"), mark, speed))
#    return 0
#
#
#def teardown(dev, why):
#    """Put the interface back the way the kernel had it.
#
#    Only says anything when there was something to remove, so the sync agent
#    calling this on a relay that has never shaped anybody stays quiet.
#    """
#    had = current_classes(dev)
#    for mark in had:
#        drop_class(dev, mark)
#    if had:
#        tc("qdisc", "del", "dev", dev, "root", check=False)
#    nft("flush", "map", *TABLE.split(), MAP, check=False)
#    if had:
#        print("%s on %s: %d class(es) removed" % (why, dev, len(had)))
#    return 0
#
#
#def off():
#    dev = wan()
#    teardown(dev, "shaping removed")
#    # Unconditionally here, unlike the reconciling path: `off` is a person
#    # asking for the root to go, whether or not any class is left.
#    tc("qdisc", "del", "dev", dev, "root", check=False)
#    print("shaping off on %s" % dev)
#    return 0
#
#
#def main():
#    verb = sys.argv[1] if len(sys.argv) > 1 else ""
#    if verb == "apply":
#        try:
#            wanted = json.loads(sys.stdin.read() or "[]")
#        except ValueError as e:
#            die("stdin is not valid json: %s" % e)
#        if not isinstance(wanted, list):
#            die("expected a list of {ip, mark, kbps}")
#        return apply_wanted(wanted)
#    if verb == "list":
#        return show()
#    if verb == "off":
#        return off()
#    sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
#    return 1
#
#
#if __name__ == "__main__":
#    raise SystemExit(main())
#__END_SMARTDNS_SHAPE__

#__BEGIN_ACL_SAVE_SERVICE__
#[Unit]
#Description=Persist smart DNS allowlist and traffic counters
#After=nftables.service
#
#[Service]
## A plain oneshot on purpose. With RemainAfterExit=yes the unit would stay
## active after its first run and every later trigger from the timer would be
## silently skipped - the counters would then be written exactly once, at boot.
#Type=oneshot
#ExecStart=/usr/local/bin/smartdns-acl save
#__END_ACL_SAVE_SERVICE__

#__BEGIN_ACL_SAVE_TIMER__
#[Unit]
#Description=Persist smart DNS counters every few minutes
#
#[Timer]
## Counters live in the kernel. An unclean shutdown loses whatever has not
## been written out, so the window is kept short enough that nobody can burn
## a meaningful amount of quota inside it.
#OnBootSec=3min
#OnUnitActiveSec=5min
#
#[Install]
#WantedBy=timers.target
#__END_ACL_SAVE_TIMER__

#__BEGIN_PANEL__
##!/usr/bin/env python3
#"""smartdns-panel - the database behind the relays, and the API they sync to.
#
#This runs on the exit node, not on the relay. The relay connects out to this
#API every half minute to hand over per-address usage and collect the list of
#addresses it should allow, which resolver each is on, and what speed each is
#capped at. The relay always initiates: it is the machine in the harder network
#position, and this way it needs no new inbound port.
#
#One database serves every relay. That is what makes a customer's allowance
#mean one thing across the whole service rather than one thing per machine.
#
#There was a Telegram bot in this process, and it went: its messages reached a
#shrinking minority while the panel on each relay did the same work for
#everybody. It is back as smartdns-bot, a process of its own, so a Telegram
#outage or a bug in a chat handler cannot take the sync API down with it. That
#process loads this file for the rules defined here - what a plan does to an
#account, how a payment is settled, who is told what - so there is one copy of
#them. Messages are queued in the outbox table; nothing in this process talks
#to Telegram.
#
#Only the standard library is used, so the installer stays a single file with
#no pip step.
#"""
#
#import base64
#import hashlib
#import hmac
#import html
#import http.server
#import json
#import os
#import re
#import secrets
#import signal
#import shutil
#import sqlite3
#import ssl
#import sys
#import threading
#import time
#import traceback
#import unicodedata
#import urllib.error
#import urllib.parse
#import urllib.request
#from datetime import datetime, timedelta, timezone
#
#CONFIG = "/etc/smart-dns/panel.env"
#DB = "/var/lib/smart-dns/panel.db"
#CERT = "/etc/smart-dns/sync.crt"
#KEY = "/etc/smart-dns/sync.key"
#API_PORT = 8443
#
#SCHEMA = """
#CREATE TABLE IF NOT EXISTS users (
#    id             INTEGER PRIMARY KEY,
#    -- Null for an account opened on the web panel. Telegram is one way in, not
#    -- the only one. UNIQUE still holds where it matters: sqlite allows many
#    -- nulls in a unique column, which is the behaviour wanted here.
#    telegram_id    INTEGER UNIQUE,
#    -- How a web account signs in. Nothing verifies it - there is no SMS
#    -- gateway - so it names an account and lets a card receipt be matched to
#    -- one. It is not evidence about who holds the line.
#    phone          TEXT UNIQUE,
#    password_hash  TEXT,
#    password_salt  TEXT,
#    username       TEXT,
#    first_name     TEXT,
#    created_at     TEXT NOT NULL,
#    status         TEXT NOT NULL DEFAULT 'active',
#    -- 0 means unlimited. Quota is counted in bytes, on the wire, both
#    -- directions, which is what the kernel counters actually measure.
#    quota_bytes    INTEGER NOT NULL DEFAULT 0,
#    quota_mode     TEXT NOT NULL DEFAULT 'monthly',
#    quota_reset_at TEXT,
#    used_bytes     INTEGER NOT NULL DEFAULT 0,
#    max_ips        INTEGER NOT NULL DEFAULT 1,
#    wallet         INTEGER NOT NULL DEFAULT 0,
#    -- Download limit in kilobits per second, 0 for no limit. The relay turns
#    -- this into one htb class per customer; the number lives here because the
#    -- relay must be able to be rebuilt from nothing but a sync.
#    speed_kbps     INTEGER NOT NULL DEFAULT 0,
#    -- When this account stops working regardless of how much is left. Set for
#    -- the trial; null for a paid account, which ends when its quota does.
#    expires_at     TEXT
#);
#
#-- One row per registered address. UNIQUE(ip) is deliberate: without it a
#-- second account could register an address someone else is already paying
#-- for and ride along free.
#CREATE TABLE IF NOT EXISTS ips (
#    id           INTEGER PRIMARY KEY,
#    user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
#    ip           TEXT NOT NULL UNIQUE,
#    added_at     TEXT NOT NULL,
#    -- The last raw counter this address reported. Usage is the growth of that
#    -- number, so a user who changes address keeps the total they had built up.
#    last_counter INTEGER NOT NULL DEFAULT 0
#);
#
#-- A customer's claim that they paid, and the photograph of the slip.
#--
#-- The image is a blob rather than a file beside the database, so that one
#-- backup is the whole story and a restore brings the pending ones back with
#-- everything else. It does not grow without bound: the image is dropped the
#-- moment the operator decides, leaving the row as the record.
#CREATE TABLE IF NOT EXISTS transactions (
#    id           INTEGER PRIMARY KEY,
#    user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
#    amount       INTEGER NOT NULL,
#    kind         TEXT NOT NULL,
#    receipt      TEXT,
#    receipt_blob BLOB,
#    receipt_type TEXT,
#    note         TEXT,
#    status       TEXT NOT NULL DEFAULT 'pending',
#    created_at   TEXT NOT NULL,
#    decided_at   TEXT
#);
#
#-- The operator's own browser sessions for the admin panel. In the database
#-- rather than in that process's memory, because it restarts on every upgrade
#-- and whenever its port or path changes - and being signed out by a restart
#-- left the operator staring at the same bare 404 a stranger gets.
#CREATE TABLE IF NOT EXISTS admin_sessions (
#    token      TEXT PRIMARY KEY,
#    expires_at TEXT NOT NULL
#);
#
#CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
#CREATE INDEX IF NOT EXISTS ips_user ON ips(user_id);
#
#-- A template is a named set of service groups that route through the relay.
#-- Customers are assigned one; they do not get an arbitrary per-customer
#-- combination, because each distinct combination costs a dnsmasq instance on
#-- every relay and the count has to stay small enough to run. Templates make
#-- that limit a product decision - how many plans do you sell - rather than an
#-- accident waiting to happen.
#CREATE TABLE IF NOT EXISTS templates (
#    id         INTEGER PRIMARY KEY,
#    name       TEXT UNIQUE NOT NULL,
#    is_default INTEGER NOT NULL DEFAULT 0,
#    created_at TEXT NOT NULL
#);
#
#-- One row per group the template routes. A group absent from here is bypassed
#-- for that template: resolved to its real address so the client reaches it
#-- directly, costing the operator nothing and the customer some speed.
#CREATE TABLE IF NOT EXISTS template_services (
#    template_id INTEGER NOT NULL REFERENCES templates(id) ON DELETE CASCADE,
#    service_key TEXT NOT NULL,
#    group_key   TEXT NOT NULL,
#    PRIMARY KEY (template_id, service_key, group_key)
#);
#
#-- Single domains switched off inside a group the template otherwise routes.
#--
#-- Recorded as exceptions rather than as the full list of what is routed, so
#-- that a group means "everything in this group" and keeps meaning it when the
#-- catalogue grows. A domain added to Spotify next month starts routing for
#-- every template that routes Spotify - which is what an operator who ticked
#-- Spotify asked for - while the handful they deliberately switched off stay
#-- off. No domain is in two groups, so the domain alone identifies the row.
#CREATE TABLE IF NOT EXISTS template_domains_off (
#    template_id INTEGER NOT NULL REFERENCES templates(id) ON DELETE CASCADE,
#    domain      TEXT NOT NULL,
#    PRIMARY KEY (template_id, domain)
#);
#
#-- Browser sessions for the user panel. The relay serves the pages but keeps
#-- no state: it holds the cookie and asks here who it belongs to, so a relay
#-- being rebuilt does not log everybody out, and a second relay serves the same
#-- session without anything being shared between them.
#CREATE TABLE IF NOT EXISTS panel_sessions (
#    token      TEXT PRIMARY KEY,
#    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
#    created_at TEXT NOT NULL,
#    expires_at TEXT NOT NULL
#);
#
#-- Where each address's counter stood at the last sync, per relay.
#--
#-- Per relay, not per address. Every relay reports its own counter for the same
#-- customer, and one shared figure makes them overwrite each other: the relay
#-- reporting the smaller number looks like a counter reset, the next relay's
#-- larger number then looks like fresh traffic, and the same bytes are charged
#-- again every cycle. Two relays turned 52 GB of real usage into 12.6 TB in a
#-- day. Invisible with a single relay, which is why it survived until there
#-- were two.
#CREATE TABLE IF NOT EXISTS ip_counters (
#    ip           TEXT NOT NULL,
#    relay        TEXT NOT NULL,
#    last_counter INTEGER NOT NULL DEFAULT 0,
#    PRIMARY KEY (ip, relay)
#);
#
#-- Domains the operator added themselves, on top of the list that ships with
#-- the installer. Kept here rather than edited on each relay so that one entry
#-- reaches every relay, and survives a relay being rebuilt from scratch.
#CREATE TABLE IF NOT EXISTS custom_domains (
#    domain   TEXT PRIMARY KEY,
#    note     TEXT,
#    added_at TEXT NOT NULL
#);
#
#-- Host health, one row per sample per machine. Written every thirty seconds
#-- by whatever reports it, and pruned to a day, which at that rate is a few
#-- thousand rows per host - small enough to keep in the same database rather
#-- than standing up something separate to hold it.
#CREATE TABLE IF NOT EXISTS metrics (
#    id         INTEGER PRIMARY KEY,
#    host       TEXT NOT NULL,
#    at         TEXT NOT NULL,
#    cpu        REAL,
#    load       REAL,
#    mem_used   INTEGER,
#    mem_total  INTEGER,
#    swap_used  INTEGER,
#    swap_total INTEGER,
#    disk_used  INTEGER,
#    disk_total INTEGER,
#    rx_bps     INTEGER,
#    tx_bps     INTEGER,
#    uptime     INTEGER
#);
#CREATE INDEX IF NOT EXISTS metrics_host_at ON metrics(host, at);
#
#-- What a customer can buy in the bot. A plan is a price and what it sets on the
#-- account once paid for: an allowance, a period starting that day, a speed and,
#-- optionally, a template. Deleting a plan that was ever sold only stops its
#-- sale, so a payment already made can still be settled against it.
#CREATE TABLE IF NOT EXISTS plans (
#    id          INTEGER PRIMARY KEY,
#    name        TEXT NOT NULL,
#    quota_gb    REAL NOT NULL DEFAULT 0,
#    days        INTEGER NOT NULL DEFAULT 30,
#    speed_mbps  REAL NOT NULL DEFAULT 0,
#    price       INTEGER NOT NULL DEFAULT 0,
#    template_id INTEGER REFERENCES templates(id) ON DELETE SET NULL,
#    active      INTEGER NOT NULL DEFAULT 1,
#    created_at  TEXT NOT NULL
#);
#
#-- Telegram messages waiting for smartdns-bot to deliver. Whichever process
#-- decides something a customer should hear about - a quota pass here, a
#-- receipt approved in the admin panel - leaves a row, and the bot sends it. A
#-- table rather than a call, because those processes never talk to Telegram,
#-- and a message queued while the bot is down is still sent once it is back.
#CREATE TABLE IF NOT EXISTS outbox (
#    id         INTEGER PRIMARY KEY,
#    chat_id    INTEGER NOT NULL,
#    text       TEXT NOT NULL,
#    created_at TEXT NOT NULL,
#    sent_at    TEXT,
#    attempts   INTEGER NOT NULL DEFAULT 0
#);
#CREATE INDEX IF NOT EXISTS outbox_unsent ON outbox(sent_at, id);
#
#-- Extra exits: servers abroad, installed as "extra exit", that carry traffic
#-- and nothing else - no database, no bot. The main exit is not a row: it is
#-- whichever one each relay was installed with, id 0 wherever an exit is named.
#-- A customer picks one in the bot, or is put on the one with the lowest ping.
#CREATE TABLE IF NOT EXISTS exits (
#    id         INTEGER PRIMARY KEY,
#    name       TEXT NOT NULL,
#    ip         TEXT NOT NULL UNIQUE,
#    active     INTEGER NOT NULL DEFAULT 1,
#    created_at TEXT NOT NULL
#);
#"""
#
#METRIC_FIELDS = ("cpu", "load", "mem_used", "mem_total", "swap_used",
#                 "swap_total", "disk_used", "disk_total", "rx_bps", "tx_bps",
#                 "uptime")
#
## How long health samples are kept. A day is enough to answer "was it the
## server?" about something that happened this morning, and short enough that
## the table never becomes the largest thing in the database.
#METRICS_KEEP_HOURS = 24
#
## Columns added after the first release. sqlite has no ADD COLUMN IF NOT
## EXISTS, so these are applied only when the column is genuinely missing.
#MIGRATIONS = [
#    # Which warning thresholds this user has already been told about, so a
#    # sync every thirty seconds does not send the same warning a hundred times.
#    ("users", "warned", "INTEGER NOT NULL DEFAULT 0"),
#    # Null means the default template, so existing accounts keep working
#    # unchanged when this arrives.
#    ("users", "template_id", "INTEGER REFERENCES templates(id)"),
#    # Web signup. Added by ALTER on databases that predate it; the UNIQUE on
#    # phone lives in the index below, because ADD COLUMN cannot carry one.
#    ("users", "phone", "TEXT"),
#    ("users", "password_hash", "TEXT"),
#    ("users", "password_salt", "TEXT"),
#    # Download limit in kilobits per second; 0 means no limit, which is what
#    # every account that predates this gets.
#    ("users", "speed_kbps", "INTEGER NOT NULL DEFAULT 0"),
#    ("users", "expires_at", "TEXT"),
#    ("transactions", "receipt_blob", "BLOB"),
#    ("transactions", "receipt_type", "TEXT"),
#    ("transactions", "note", "TEXT"),
#    # What a payment was for, and how an online one is found again: the token
#    # in the link the bot hands out, and Zibal's own track id for it.
#    ("transactions", "plan_id", "INTEGER REFERENCES plans(id)"),
#    ("transactions", "pay_token", "TEXT"),
#    ("transactions", "authority", "TEXT"),
#    ("transactions", "ref_id", "TEXT"),
#    # Whether a decision has been carried out - the plan applied, the customer
#    # told - and whether the bot's admins have been shown the receipt. Both
#    # default to done, so rows from before the bot are neither applied again
#    # nor forwarded; code that creates work sets them to 0.
#    ("transactions", "settled", "INTEGER NOT NULL DEFAULT 1"),
#    ("transactions", "admin_notified", "INTEGER NOT NULL DEFAULT 1"),
#    # When this account took the one free trial it gets. Null is "never",
#    # which is what every account that predates the trial gets - so nobody
#    # is refused one because of when they signed up.
#    ("users", "trial_at", "TEXT"),
#    # Which exit this account's traffic leaves by: null is automatic - the
#    # one with the lowest ping from the relay - 0 the main exit, and anything
#    # else an extra exit's id.
#    ("users", "exit_id", "INTEGER"),
#    # An extra exit's tunnel, as its own installer printed it: BackPack's
#    # transport and port, and the token both ends prove themselves with. Null
#    # on an exit the relay reaches directly, which is every exit until one is
#    # given a tunnel.
#    ("exits", "tunnel_transport", "TEXT"),
#    ("exits", "tunnel_port", "INTEGER"),
#    ("exits", "tunnel_token", "TEXT"),
#]
#
## Indexes that have to exist whether the table was created by SCHEMA or grown
## by MIGRATIONS. A unique index and a UNIQUE column constraint are the same
## thing to sqlite, so this makes both paths end up identical.
#INDEXES = [
#    "CREATE UNIQUE INDEX IF NOT EXISTS users_phone ON users(phone)",
#    # What a customer signs in with. The column predates this - it held the
#    # Telegram handle - and sqlite cannot add UNIQUE to a column that is
#    # already there, so the constraint arrives as an index instead. Nulls do
#    # not collide in a unique index, which is what accounts that never had one
#    # need.
#    "CREATE UNIQUE INDEX IF NOT EXISTS users_username ON users(username)",
#    "CREATE UNIQUE INDEX IF NOT EXISTS transactions_pay_token ON transactions(pay_token)",
#]
#
## Where the installer puts the service catalogue - which brands exist, which
## groups each has, and which domains are in each group.
#SERVICES_FILE = "/usr/local/share/smart-dns/services.json"
#
## Ceiling on distinct templates actually in use. Each one is a dnsmasq
## instance on every relay, with its own cache and its own port, so this is a
## real resource limit rather than a preference. Eight plans is more than any
## of this is likely to need; the panel refuses to exceed it rather than
## quietly starting a ninth resolver on every machine.
#MAX_TEMPLATES = 8
#
#MB = 1024 ** 2
#GB = 1024 ** 3
#
## A photograph of a bank slip. Generous for a phone camera, small enough that
## a few pending ones cannot bloat the database or a backup.
#MAX_RECEIPT = 4 * MB
#
## What the service is called and what a new account gets. Kept in the database
## rather than in this file, so changing either is an edit in the admin panel
## rather than a redeploy to every machine.
#DEFAULT_SETTINGS = {
#    "plan_bytes": str(2 * GB),
#    "plan_days": "30",
#    # The free trial, offered in the bot to an account that has never had
#    # anything. One per Telegram account, recorded in users.trial_at. The
#    # operator sets these from the bot; "trial_on" empty switches it off, and
#    # so does a length of zero.
#    "trial_on": "1",
#    "trial_gb": "1",
#    "trial_hours": "24",
#    "trial_mbps": "0",
#}
#
## Fractions of the quota at which the user is warned, and the bit each one
## sets in users.warned.
#THRESHOLDS = [(0.80, 1), (0.95, 2)]
#
#IPV4 = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")
#
#
#class Throttle:
#    """Counts recent attempts per key, in memory.
#
#    The panel is one process, so a dict is the whole implementation. Losing the
#    counts on restart is acceptable: this exists to make guessing slow, and a
#    restart is not something an attacker can cause.
#    """
#
#    def __init__(self):
#        self.lock = threading.Lock()
#        self.hits = {}
#
#    def _prune(self, key, window):
#        cutoff = time.time() - window
#        kept = [t for t in self.hits.get(key, []) if t > cutoff]
#        if kept:
#            self.hits[key] = kept
#        else:
#            self.hits.pop(key, None)
#        return kept
#
#    def check(self, key, limit, window):
#        """(allowed, seconds until the oldest attempt falls out of the window)"""
#        with self.lock:
#            kept = self._prune(key, window)
#            if len(kept) < limit:
#                return True, 0
#            return False, int(window - (time.time() - kept[0])) + 1
#
#    def hit(self, key):
#        with self.lock:
#            self.hits.setdefault(key, []).append(time.time())
#
#    def clear(self, key):
#        with self.lock:
#            self.hits.pop(key, None)
#
#
#THROTTLE = Throttle()
#
#
#def now():
#    return datetime.now(timezone.utc).isoformat(timespec="seconds")
#
#
#def parse_ts(s):
#    """Parse a stored timestamp as an aware UTC datetime, or None.
#
#    Everything this program writes carries an offset, but the database is also
#    edited by hand and by admin scripts, and sqlite's own datetime() produces a
#    naive string. Comparing one of those against an aware value raises, which
#    is how the whole quota pass once died on every sync. Assume UTC when no
#    offset is given, since that is what every writer here means.
#    """
#    if not s:
#        return None
#    try:
#        t = datetime.fromisoformat(s)
#    except ValueError:
#        return None
#    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)
#
#
#def valid_ip(s):
#    m = IPV4.match(s or "")
#    return bool(m) and all(0 <= int(p) <= 255 for p in m.groups())
#
#
#def normal_phone(s):
#    """Reduce an Iranian mobile number to one canonical form, or return "".
#
#    People type the same number four ways - 0912…, 912…, +98912…, ۰۹۱۲… - and
#    all four have to collide, or one person ends up with four accounts and the
#    operator cannot match a card receipt to any of them.
#    """
#    digits = ""
#    for ch in (s or "").strip():
#        if ch.isdigit():
#            # Persian and Arabic-Indic digits: unicodedata.digit maps both.
#            digits += str(unicodedata.digit(ch))
#    if digits.startswith("0098"):
#        digits = digits[4:]
#    elif digits.startswith("98") and len(digits) == 12:
#        digits = digits[2:]
#    elif digits.startswith("0"):
#        digits = digits[1:]
#    # 9xxxxxxxxx - a mobile number without the leading zero.
#    if len(digits) == 10 and digits.startswith("9"):
#        return "0" + digits
#    return ""
#
#
#def normal_username(s):
#    """Reduce a username to one canonical form, or return "".
#
#    Lowercased, because somebody who signs up as Ali and comes back as ali is
#    the same person and must not be able to become two accounts - nor be told
#    their own name is taken. Letters, digits, dot, dash and underscore only:
#    this ends up in log lines and in the operator's panel, and a name carrying
#    spaces or control characters is a nuisance in both.
#    """
#    v = (s or "").strip().lower()
#    if not re.fullmatch(r"[a-z0-9._-]{3,32}", v):
#        return ""
#    # A name that is only punctuation is not a name.
#    if not any(c.isalnum() for c in v):
#        return ""
#    return v
#
#
#def hash_password(password, salt):
#    # Same cost as the admin panel: slow enough that a stolen database is not
#    # a list of passwords, fast enough that signing in is not noticeable.
#    return hashlib.pbkdf2_hmac(
#        "sha256", (password or "").encode(), bytes.fromhex(salt), 200_000).hex()
#
#
#def check_password(user, password):
#    if not user["password_hash"] or not user["password_salt"]:
#        return False
#    return hmac.compare_digest(
#        hash_password(password, user["password_salt"]), user["password_hash"])
#
#
#def human(n):
#    n = float(n)
#    for unit in ("B", "KB", "MB", "GB", "TB"):
#        if n < 1024 or unit == "TB":
#            return ("%d %s" if unit == "B" else "%.2f %s") % (n, unit)
#        n /= 1024
#
#
#DOMAIN_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+"
#                       r"[a-z]{2,63}$")
#
## Names that must never be routed to the relay. localhost and the internal
## suffixes would break name resolution on the machine itself. Telegram stays on
## the list because customers reach support through it and a relay answering for
## t.me would break that for everyone behind it.
#FORBIDDEN = ("localhost", "local", "internal", "arpa", "telegram.org",
#             "t.me", "telegram.me")
#
#
#def clean_domain(raw):
#    """Normalise what someone typed into a domain, or explain why it is not.
#
#    Accepts what people actually paste - a full URL, a trailing slash, capital
#    letters, a leading dot or www - because rejecting those teaches nothing and
#    just costs a round trip.
#    """
#    d = (raw or "").strip().lower()
#    d = re.sub(r"^[a-z]+://", "", d)      # scheme
#    d = d.split("/")[0].split("?")[0]     # path, query
#    d = d.split("@")[-1]                  # someone pasting an email
#    d = d.split(":")[0]                   # port
#    d = d.strip(".")
#    if not d:
#        raise ValueError("خالی است")
#    if not DOMAIN_RE.match(d):
#        raise ValueError("قالب دامنه درست نیست")
#    if any(d == f or d.endswith("." + f) for f in FORBIDDEN):
#        raise ValueError("این دامنه را نمی‌شود مسیر داد")
#    if d.count(".") == 1 and len(d.split(".")[0]) <= 2:
#        raise ValueError("خیلی کلی است - دامنهٔ کامل بدهید")
#    return d
#
#
#def inspect_backup(path):
#    """Check a file really is one of our backups, and say what is in it.
#
#    Raises rather than returning a verdict, because every caller wants to stop.
#    A file that opens as sqlite is not enough: someone's unrelated database
#    would pass that and then replace every customer with nothing.
#    """
#    db = sqlite3.connect(path)
#    try:
#        status = db.execute("PRAGMA integrity_check").fetchone()[0]
#        if status != "ok":
#            raise ValueError("integrity check failed: %s" % status)
#        have = {r[0] for r in db.execute(
#            "SELECT name FROM sqlite_master WHERE type = 'table'")}
#        missing = {"users", "ips", "templates", "settings"} - have
#        if missing:
#            raise ValueError("not a panel backup - missing %s"
#                             % ", ".join(sorted(missing)))
#        return {t: db.execute("SELECT count(*) FROM " + t).fetchone()[0]
#                for t in ("users", "ips", "templates", "transactions")}
#    finally:
#        db.close()
#
#
## The operator's own domains, presented as a service so a template can include
## or exclude them like any brand. Its domain list lives in the database rather
## than the catalogue file, so it is filled in at use rather than shipped.
#CUSTOM_SERVICE = {"key": "custom", "label": "دامنه‌های دلخواه شما",
#                  "groups": [{"key": "main", "label": "همه", "domains": []}]}
#
#
#def load_catalogue():
#    """The service catalogue the installer dropped alongside this script.
#
#    Shipped as a file rather than kept in the database so that it is versioned
#    with the code: adding a brand is an upgrade, not a migration, and every
#    relay and panel agrees on what "playstation.download" means.
#    """
#    try:
#        with io_open(SERVICES_FILE) as fh:
#            return json.load(fh).get("services", [])
#    except Exception as e:
#        log(ERROR, "no service catalogue at %s: %s" % (SERVICES_FILE, e))
#        return []
#
#
#def io_open(path):
#    return open(path, encoding="utf-8")
#
#
#def load_config():
#    cfg = {}
#    with open(CONFIG) as fh:
#        for line in fh:
#            line = line.strip()
#            if not line or line.startswith("#") or "=" not in line:
#                continue
#            k, v = line.split("=", 1)
#            cfg[k.strip()] = v.strip().strip('"').strip("'")
#    for required in ("SYNC_SECRET", "RELAY_IP"):
#        if not cfg.get(required):
#            sys.exit("%s: %s is missing" % (CONFIG, required))
#    return cfg
#
#
## --------------------------------------------------------------- database
#def relax_telegram_id(db, path):
#    """Drop the NOT NULL from users.telegram_id on databases that predate web
#    signup.
#
#    sqlite cannot alter a column constraint, so the table has to be rebuilt.
#    The new definition is not written out here - it is the existing one with
#    that one phrase removed - so any column added by a later MIGRATIONS entry
#    survives without this function knowing it exists.
#
#    A copy of the database is taken first. This runs at startup, before the bot
#    is polling and before any relay can reach the API, and if it goes wrong the
#    operator has the file it went wrong on.
#    """
#    row = db.execute("SELECT sql FROM sqlite_master"
#                     " WHERE type = 'table' AND name = 'users'").fetchone()
#    if not row:
#        return
#    old = row[0]
#    new = re.sub(r"(telegram_id\s+INTEGER\s+UNIQUE)\s+NOT\s+NULL", r"\1",
#                 old, flags=re.I)
#    if new == old:
#        return                      # already nullable, nothing to do
#
#    backup = "%s.pre-websignup" % path
#    db.commit()                     # VACUUM cannot run inside a transaction
#    if not os.path.exists(backup):
#        db.execute("VACUUM INTO ?", (backup,))
#    print("migrating users: telegram_id may now be null (backup: %s)" % backup,
#          flush=True)
#
#    new = re.sub(r"^\s*CREATE\s+TABLE\s+(IF\s+NOT\s+EXISTS\s+)?[\"'`\[]?users[\"'`\]]?",
#                 "CREATE TABLE users_new", new, count=1, flags=re.I)
#    cols = [r[1] for r in db.execute("PRAGMA table_info(users)")]
#    names = ", ".join('"%s"' % c for c in cols)
#
#    # Foreign keys off for the swap: ips, claims, transactions and
#    # panel_sessions all point at users(id), and dropping the table underneath
#    # them with enforcement on would either fail or take their rows with it.
#    # It cannot be toggled inside a transaction, hence the order here.
#    db.execute("PRAGMA foreign_keys = OFF")
#    try:
#        db.execute("BEGIN")
#        db.execute(new)
#        db.execute("INSERT INTO users_new (%s) SELECT %s FROM users" % (names, names))
#        db.execute("DROP TABLE users")
#        db.execute("ALTER TABLE users_new RENAME TO users")
#        db.execute("COMMIT")
#    except Exception:
#        db.execute("ROLLBACK")
#        db.execute("PRAGMA foreign_keys = ON")
#        raise
#    broken = db.execute("PRAGMA foreign_key_check").fetchall()
#    db.execute("PRAGMA foreign_keys = ON")
#    if broken:
#        raise RuntimeError("migration left %d dangling references - the "
#                           "database before it is at %s" % (len(broken), backup))
#
#
#class Store:
#    """All database access, with one lock around it.
#
#    Two threads touch the database - the Telegram loop and the sync API - and
#    sqlite3 connections are not safe to share across threads. One connection
#    guarded by a lock is simpler to reason about than a pool, and at this size
#    there is nothing to gain from the pool.
#    """
#
#    def __init__(self, path):
#        self.lock = threading.Lock()
#        self.db = sqlite3.connect(path, check_same_thread=False)
#        self.db.row_factory = sqlite3.Row
#        self.db.execute("PRAGMA foreign_keys = ON")
#        self.db.execute("PRAGMA journal_mode = WAL")
#        with self.lock:
#            self.db.executescript(SCHEMA)
#            relax_telegram_id(self.db, path)
#            for table, column, spec in MIGRATIONS:
#                have = {r[1] for r in self.db.execute("PRAGMA table_info(%s)" % table)}
#                if column not in have:
#                    self.db.execute(
#                        "ALTER TABLE %s ADD COLUMN %s %s" % (table, column, spec)
#                    )
#            for statement in INDEXES:
#                self.db.execute(statement)
#            for key, value in DEFAULT_SETTINGS.items():
#                self.db.execute(
#                    "INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)",
#                    (key, value),
#                )
#            self.db.commit()
#
#    def setting(self, key, default=""):
#        row = self.one("SELECT value FROM settings WHERE key = ?", (key,))
#        return row["value"] if row else default
#
#    def set_setting(self, key, value):
#        self.run(
#            "INSERT INTO settings (key, value) VALUES (?, ?)"
#            " ON CONFLICT(key) DO UPDATE SET value = excluded.value",
#            (key, str(value)),
#        )
#
#    def q(self, sql, args=()):
#        with self.lock:
#            return self.db.execute(sql, args).fetchall()
#
#    def one(self, sql, args=()):
#        rows = self.q(sql, args)
#        return rows[0] if rows else None
#
#    def run(self, sql, args=()):
#        with self.lock:
#            cur = self.db.execute(sql, args)
#            self.db.commit()
#            return cur
#
#    def user_by_telegram(self, tg_id):
#        return self.one("SELECT * FROM users WHERE telegram_id = ?", (tg_id,))
#
#    # A new account starts with nothing and is not connected: 'pending' keeps
#    # it out of the allowed list, which is what "no trial" has to mean, and
#    # the operator turns it on by giving it a quota.
#    #
#    # Not quota_bytes = 0 on an active account, which is the trap here: zero
#    # means unlimited everywhere in this file, so the account that was meant
#    # to get nothing would get everything. The status is what decides.
#    def create_user(self, tg_id, username, first_name):
#        self.run(
#            "INSERT OR IGNORE INTO users"
#            " (telegram_id, username, first_name, created_at, status,"
#            "  quota_bytes, quota_mode, quota_reset_at, expires_at)"
#            " VALUES (?, ?, ?, ?, 'pending', 0, 'oneoff', NULL, NULL)",
#            (tg_id, username, first_name, now()),
#        )
#        return self.user_by_telegram(tg_id)
#
#    def user_by_phone(self, phone):
#        return self.one("SELECT * FROM users WHERE phone = ?", (phone,))
#
#    def user_by_username(self, username):
#        return self.one("SELECT * FROM users WHERE username = ?", (username,))
#
#    def create_web_user(self, username, first_name, password):
#        """Open an account from the web panel, with no Telegram behind it.
#
#        It starts with nothing, the same as one opened any other way - the way
#        in should not decide what you get. Signing up gets you an account, a
#        password and somewhere to send a receipt; it does not get you any
#        traffic until an operator says so.
#        """
#        salt = secrets.token_hex(16)
#        self.run(
#            "INSERT INTO users"
#            " (telegram_id, username, password_hash, password_salt, first_name,"
#            "  created_at, status, quota_bytes, quota_mode, quota_reset_at,"
#            "  expires_at)"
#            " VALUES (NULL, ?, ?, ?, ?, ?, 'pending', 0, 'oneoff', NULL, NULL)",
#            (username, hash_password(password, salt), salt, first_name, now()),
#        )
#        return self.user_by_username(username)
#
#    def set_password(self, user_id, password):
#        salt = secrets.token_hex(16)
#        self.run("UPDATE users SET password_hash = ?, password_salt = ?"
#                 " WHERE id = ?", (hash_password(password, salt), salt, user_id))
#
#    def open_session(self, user_id, days=30):
#        token = secrets.token_urlsafe(32)
#        self.run(
#            "INSERT INTO panel_sessions (token, user_id, created_at, expires_at)"
#            " VALUES (?, ?, ?, ?)",
#            (token, user_id, now(),
#             (datetime.now(timezone.utc) + timedelta(days=days)).isoformat(
#                 timespec="seconds")))
#        return token
#
#    def user_ips(self, user_id):
#        return self.q("SELECT * FROM ips WHERE user_id = ? ORDER BY added_at", (user_id,))
#
#    def claim_ip(self, user_id, ip):
#        """Register an address to an account: from the relay's page, from the
#        bot's mini app, or typed into the bot.
#
#        One active address per account, with as many changes as they like.
#        Replacing rather than adding is what makes that true.
#        """
#        owner = self.one("SELECT user_id FROM ips WHERE ip = ?", (ip,))
#        if owner and owner["user_id"] != user_id:
#            return {"ok": False, "message": "این آی‌پی به حساب دیگری ثبت شده است"}
#        user = self.one("SELECT * FROM users WHERE id = ?", (user_id,))
#        if not user:
#            return {"ok": False, "message": "حساب پیدا نشد"}
#        existing = self.user_ips(user_id)
#        if existing and len(existing) >= user["max_ips"]:
#            for old in existing[: len(existing) - user["max_ips"] + 1]:
#                self.run("DELETE FROM ips WHERE id = ?", (old["id"],))
#        self.run(
#            "INSERT OR REPLACE INTO ips (user_id, ip, added_at) VALUES (?, ?, ?)",
#            (user_id, ip, now()))
#        return {"ok": True, "message": "آی‌پی %s ثبت شد" % ip}
#
#    def note_pings(self, relay, pings):
#        """Keep the latest game pings a relay measured, one entry per relay.
#
#        What comes in is checked field by field and kept small: it is shown to
#        customers in the bot, and a relay is trusted to report its own numbers,
#        not to write arbitrary text into their chats.
#        """
#        if not isinstance(pings, dict) or not pings:
#            return
#        games = {}
#        for key, v in list(pings.items())[:64]:
#            if not (isinstance(key, str) and re.fullmatch(r"[a-z0-9_-]{1,32}", key)
#                    and isinstance(v, dict)):
#                continue
#            hosts = []
#            for h in (v.get("hosts") or [])[:16]:
#                if not isinstance(h, dict):
#                    continue
#                ms, loss = h.get("ms"), h.get("loss")
#                hosts.append({
#                    "host": str(h.get("host") or "")[:253],
#                    "ip": h["ip"] if isinstance(h.get("ip"), str) and valid_ip(h["ip"]) else "",
#                    "ms": float(ms) if isinstance(ms, (int, float)) and 0 <= ms < 60000 else None,
#                    "loss": float(loss) if isinstance(loss, (int, float)) and 0 <= loss <= 1 else 1.0,
#                    "state": str(h.get("state") or "")[:16]})
#            games[key] = {"label": str(v.get("label") or key)[:40], "hosts": hosts}
#        if not games:
#            return
#        every = relay_pings(self)
#        every[relay] = {"at": now(), "games": games}
#        self.set_setting("relay_pings", json.dumps(every, ensure_ascii=False))
#
#    def active_exits(self):
#        return self.q("SELECT * FROM exits WHERE active = 1 ORDER BY id")
#
#    def note_exit_pings(self, relay, pings):
#        """Keep how fast each exit answered one relay, the latest round only."""
#        if not isinstance(pings, dict) or not pings:
#            return
#        clean = {}
#        for eid, p in list(pings.items())[:64]:
#            if not (isinstance(eid, str) and eid.isdigit() and isinstance(p, dict)):
#                continue
#            ms, loss = p.get("ms"), p.get("loss")
#            clean[eid] = {
#                "ms": float(ms) if isinstance(ms, (int, float)) and 0 <= ms < 60000 else None,
#                "loss": float(loss) if isinstance(loss, (int, float)) and 0 <= loss <= 1 else 1.0}
#        if not clean:
#            return
#        every = exit_pings(self)
#        every[relay] = {"at": now(), "exits": clean}
#        self.set_setting("relay_exit_pings", json.dumps(every))
#
#    def note_relay(self, panel, dns):
#        """Remember where a relay's customer pages are, and its DNS address.
#
#        The bot runs here but links customers to the relay - the mini app that
#        registers an address and the payment page both live there - and tells
#        them which DNS address to type in. The relay reports both on every
#        sync. With several relays the last to sync wins, which is fine while
#        they are interchangeable. Written only when it changes, because this
#        runs every thirty seconds per relay.
#        """
#        if (isinstance(panel, str)
#                and re.fullmatch(r"https://[A-Za-z0-9.-]{1,253}(:\d{1,5})?", panel)
#                and self.setting("relay_panel") != panel):
#            self.set_setting("relay_panel", panel)
#        if isinstance(dns, str) and valid_ip(dns) and self.setting("relay_dns") != dns:
#            self.set_setting("relay_dns", dns)
#
#    def allowed(self):
#        return self.q(
#            "SELECT i.ip AS ip, u.id AS uid FROM ips i JOIN users u ON u.id = i.user_id"
#            " WHERE u.status = 'active'"
#        )
#
#    # ----------------------------------------------------------- templates
#    def ensure_default_template(self, catalogue):
#        """Create the all-services template if there is none.
#
#        Everything routes in it, which is exactly how the service behaved
#        before templates existed - so an upgrade changes nothing until an
#        admin decides otherwise.
#        """
#        row = self.one("SELECT * FROM templates WHERE is_default = 1")
#        if row:
#            return row
#        cur = self.run(
#            "INSERT INTO templates (name, is_default, created_at) VALUES (?, 1, ?)",
#            ("کامل", now()))
#        tid = cur.lastrowid
#        for svc in catalogue:
#            for grp in svc["groups"]:
#                # Opt-in groups are left out here too. The default template
#                # ignores these rows while it is the default, but it stops
#                # being special the moment somebody makes another one the
#                # default - and it should not carry a tick nobody made.
#                if grp.get("opt_in"):
#                    continue
#                self.run(
#                    "INSERT OR IGNORE INTO template_services"
#                    " (template_id, service_key, group_key) VALUES (?, ?, ?)",
#                    (tid, svc["key"], grp["key"]))
#        return self.one("SELECT * FROM templates WHERE id = ?", (tid,))
#
#    def template_groups(self, template_id):
#        return {(r["service_key"], r["group_key"]) for r in self.q(
#            "SELECT service_key, group_key FROM template_services WHERE template_id = ?",
#            (template_id,))}
#
#    def routed_for(self, template_id, catalogue):
#        """Domains this template DOES route, for the relay to hijack.
#
#        The relay writes these as address= rules in the profile's own
#        resolver, rather than inheriting the shared hijack list and taking
#        names back out of it with server= rules. Subtraction cannot work
#        here: both rules would name the same host, dnsmasq's longest match
#        ties, and address= wins - so every un-tick of an ordinary domain was
#        silently ignored. What a profile must not route, it must simply not
#        be told about.
#
#        The custom service is excluded: those domains reach the relay by a
#        different route, and apply_custom_domains writes them per profile.
#        """
#        routed = self.template_groups(template_id)
#        off = self.template_domains_off(template_id)
#        is_default = bool(self.one(
#            "SELECT is_default FROM templates WHERE id = ?",
#            (template_id,))["is_default"])
#        out = []
#        for svc in catalogue:
#            if svc["key"] == "custom":
#                continue
#            for grp in svc["groups"]:
#                # The default template means "everything, now and later", and
#                # the one exception is a group nobody has opted in to.
#                if is_default:
#                    if not grp.get("opt_in"):
#                        out.extend(grp["domains"])
#                    continue
#                if (svc["key"], grp["key"]) in routed:
#                    out.extend(d for d in grp["domains"] if d not in off)
#        return sorted(set(out))
#
#    def bypass_for(self, template_id, catalogue):
#        """Domains this template does NOT route, so the relay resolves them
#        normally and the client goes straight to them."""
#        # The default template means "everything", and has to keep meaning it
#        # as the catalogue grows. Reading its rows would freeze it at whatever
#        # existed the day it was created, so a brand added in a later upgrade
#        # would silently stop routing for every customer on the default plan -
#        # a service quietly getting worse with no change anybody made.
#        #
#        # "Everything" stops at the opt-in groups. Those exist so an operator
#        # can see them and decide; routing one by default would be deciding
#        # for them, in the one direction that breaks something.
#        row = self.one("SELECT is_default FROM templates WHERE id = ?", (template_id,))
#        if row and row["is_default"]:
#            return sorted({d for svc in catalogue for grp in svc["groups"]
#                           if grp.get("opt_in") for d in grp["domains"]})
#        routed = self.template_groups(template_id)
#        off = self.template_domains_off(template_id)
#        out = []
#        for svc in catalogue:
#            # Custom domains are never bypassed by rule - see routes_custom.
#            if svc["key"] == "custom":
#                continue
#            for grp in svc["groups"]:
#                if (svc["key"], grp["key"]) not in routed:
#                    out.extend(grp["domains"])
#                else:
#                    # The group is routed, minus whatever was switched off
#                    # inside it one domain at a time.
#                    out.extend(d for d in grp["domains"] if d in off)
#        return sorted(set(out))
#
#    def template_domains_off(self, template_id):
#        return {r["domain"] for r in self.q(
#            "SELECT domain FROM template_domains_off WHERE template_id = ?",
#            (template_id,))}
#
#    def profiles(self, catalogue, default_id):
#        """The templates actually in use, and who is on each.
#
#        Only templates with at least one active registered address become
#        profiles: an unused template costs a resolver on every relay for
#        nobody's benefit.
#        """
#        rows = self.q(
#            "SELECT i.ip AS ip, u.id AS uid, u.speed_kbps AS kbps,"
#            " COALESCE(u.template_id, ?) AS tid,"
#            " COALESCE(u.username, '') AS uname"
#            " FROM ips i JOIN users u ON u.id = i.user_id"
#            " WHERE u.status = 'active'", (default_id,))
#        by_ip = {}
#        used = set()
#        for r in rows:
#            tid = r["tid"] if self.one(
#                "SELECT 1 FROM templates WHERE id = ?", (r["tid"],)) else default_id
#            # The username travels so smartdns-watch on a relay can take one
#            # where an address would do.
#            by_ip[r["ip"]] = {"uid": r["uid"], "tid": tid,
#                              "kbps": r["kbps"] or 0, "user": r["uname"]}
#            used.add(tid)
#        custom = self.custom_domains()
#        profiles = {}
#        for tid in used:
#            # The default routes everything, which is what the relay's main
#            # resolver already does - it needs no instance of its own.
#            if tid == default_id:
#                continue
#            profiles[str(tid)] = {
#                # What this template routes, said positively. The relay used
#                # to inherit the shared hijack list and subtract from it with
#                # server= rules, which dnsmasq resolved the other way whenever
#                # both named the same host - so an un-ticked service kept
#                # routing and nothing said otherwise.
#                "routed": self.routed_for(tid, catalogue),
#                # Still sent: names whose parent this template routes have to
#                # be taken back out, and there the subtraction does work,
#                # because the profile's rule is the longer one.
#                "bypass": self.bypass_for(tid, catalogue),
#                # Listed positively, not by omission: the relay writes these
#                # into this profile's own config, and a template that does not
#                # route them simply has no rule for them anywhere. One of them
#                # switched off inside the template is left out the same way.
#                "custom": [d for d in custom
#                           if d not in self.template_domains_off(tid)]
#                          if self.routes_custom(tid) else [],
#                # Whether this profile still wants epic-pin's work. Those pins
#                # name exact hosts, so they beat any rule that routes the
#                # parent domain - which means a template that has ticked the
#                # backend group would tick it and see nothing happen. The
#                # relay leaves the pins out of a profile that asked to route
#                # them, and keeps them everywhere else.
#                "pins": ("bypass", "epic") not in self.template_groups(tid),
#            }
#        return by_ip, profiles
#
#    def custom_domains(self):
#        return [r["domain"] for r in self.q(
#            "SELECT domain FROM custom_domains ORDER BY domain")]
#
#    def template_names(self):
#        """Every template's name by id, and which is the default - so the
#        relay's own tools can say "test" where its resolvers only know "2"."""
#        rows = self.q("SELECT id, name, is_default FROM templates")
#        return {"default": next((r["id"] for r in rows if r["is_default"]), None),
#                "names": {str(r["id"]): r["name"] for r in rows}}
#
#    def routes_custom(self, template_id):
#        """Whether this template routes the operator's own domains.
#
#        These cannot be handled the way catalogue services are. A service is
#        un-routed by adding a more specific `server=` rule that out-matches the
#        broad `address=` hijacking its parent - but a custom domain's two rules
#        name exactly the same host, and dnsmasq picks the address= one. Tested,
#        not assumed. So rather than un-routing them per template, they are
#        written only into the resolvers of templates that do route them.
#        """
#        row = self.one("SELECT is_default FROM templates WHERE id = ?", (template_id,))
#        if row and row["is_default"]:
#            return True
#        return ("custom", "main") in self.template_groups(template_id)
#
#    def backup(self):
#        """A consistent copy of the database, minus the metrics.
#
#        VACUUM INTO rather than copying the file: sqlite is in WAL mode, so the
#        file on disk is not the whole story and copying it while the bot is
#        writing can produce something that will not open. VACUUM INTO takes a
#        proper snapshot with the database still running.
#
#        Health samples are dropped from the copy. They are the bulk of the rows
#        and none of the value - what matters in a restore is who the customers
#        are, what they bought and what they have used.
#        """
#        path = "/tmp/smartdns-backup-%s.db" % datetime.now(timezone.utc).strftime(
#            "%Y%m%d-%H%M%S")
#        with self.lock:
#            self.db.execute("VACUUM INTO ?", (path,))
#        copy = sqlite3.connect(path)
#        copy.execute("DELETE FROM metrics")
#        copy.commit()
#        copy.execute("VACUUM")
#        copy.close()
#        return path
#
#    def restore(self, path):
#        """Put a checked backup in place of the live database.
#
#        The current database is kept, not deleted: a restore is exactly the
#        moment somebody discovers they restored the wrong file, and having the
#        previous state one move away is the difference between an inconvenience
#        and losing every customer.
#
#        The candidate has to be staged beside the database, not in /tmp.
#        rename() cannot cross a mount point, and the unit sets PrivateTmp, so
#        /tmp is one - a restore from there fails with EXDEV at the last step,
#        after the safety copy has been taken and the connection closed.
#        """
#        if os.path.dirname(os.path.abspath(path)) != os.path.dirname(DB):
#            staged = os.path.join(os.path.dirname(DB),
#                                  ".restore-%s.db" % secrets.token_hex(6))
#            shutil.copyfile(path, staged)
#            os.unlink(path)
#            path = staged
#        keep = "%s.before-restore-%s" % (
#            DB, datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S"))
#        with self.lock:
#            self.db.execute("VACUUM INTO ?", (keep,))
#            self.db.close()
#        os.replace(path, DB)
#        # A stale write-ahead log next to a different database is how a restore
#        # turns into corruption. The backup is a complete snapshot, so there is
#        # nothing in these worth keeping.
#        for suffix in ("-wal", "-shm"):
#            try:
#                os.unlink(DB + suffix)
#            except OSError:
#                pass
#        return keep
#
#    def record_metrics(self, host, sample):
#        if not isinstance(sample, dict) or "error" in sample:
#            return
#        cols = [f for f in METRIC_FIELDS if sample.get(f) is not None]
#        # An empty sample builds "INSERT INTO metrics (host, at, ) VALUES ..",
#        # which sqlite rejects and which took the whole sync request down with
#        # it - a relay running an older agent sends no metrics at all, and that
#        # must not stop its usage being counted.
#        if not cols:
#            return
#        self.run(
#            "INSERT INTO metrics (host, at, %s) VALUES (?, ?, %s)"
#            % (", ".join(cols), ", ".join("?" * len(cols))),
#            [host, now()] + [sample[c] for c in cols],
#        )
#
#    def prune_metrics(self):
#        self.run(
#            "DELETE FROM metrics WHERE at < ?",
#            ((datetime.now(timezone.utc)
#              - timedelta(hours=METRICS_KEEP_HOURS)).isoformat(timespec="seconds"),))
#
#    def latest_metrics(self):
#        """Newest sample per host."""
#        return self.q(
#            "SELECT m.* FROM metrics m JOIN ("
#            "  SELECT host, MAX(at) AS at FROM metrics GROUP BY host"
#            ") last ON last.host = m.host AND last.at = m.at"
#        )
#
#    def fold_counters(self, relay, counters):
#        """Turn raw per-address counters into per-user usage.
#
#        The kernel counts bytes per address since the element was created. What
#        a bill needs is bytes per user, across whatever addresses they have had.
#        So take the growth since last time rather than the absolute number, and
#        add it to the user's running total.
#
#        The previous reading is kept per relay - see ip_counters. Sharing one
#        figure between relays bills the same bytes over and over.
#        """
#        touched = {}
#        with self.lock:
#            for ip, total in counters.items():
#                row = self.db.execute(
#                    "SELECT id, user_id FROM ips WHERE ip = ?", (ip,)).fetchone()
#                if row is None:
#                    continue
#                prev = self.db.execute(
#                    "SELECT last_counter FROM ip_counters WHERE ip = ? AND relay = ?",
#                    (ip, relay)).fetchone()
#                # A counter that went backwards means it was reset - a reboot
#                # restoring an older saved value, or the address being
#                # re-added. Whatever is there now is the growth.
#                delta = total - (prev["last_counter"] if prev else 0)
#                if delta < 0:
#                    delta = total
#                if delta:
#                    self.db.execute(
#                        "UPDATE users SET used_bytes = used_bytes + ? WHERE id = ?",
#                        (delta, row["user_id"]),
#                    )
#                    touched[row["user_id"]] = touched.get(row["user_id"], 0) + delta
#                self.db.execute(
#                    "INSERT INTO ip_counters (ip, relay, last_counter)"
#                    " VALUES (?, ?, ?) ON CONFLICT(ip, relay)"
#                    " DO UPDATE SET last_counter = excluded.last_counter",
#                    (ip, relay, total))
#            self.db.commit()
#        return touched
#
#
## ----------------------------------------------------------------- health
#class Health:
#    """This machine's own metrics, read straight out of /proc.
#
#    A near-copy of the same class in smartdns-sync. They are duplicated on
#    purpose: each program is extracted from the installer as a single
#    self-contained file, so a shared module would mean a third payload and a
#    third thing to keep in step.
#    """
#
#    def __init__(self):
#        self.cpu = None
#        self.net = None
#
#    @staticmethod
#    def _meminfo():
#        out = {}
#        with open("/proc/meminfo") as fh:
#            for line in fh:
#                k, _, v = line.partition(":")
#                out[k] = int(v.split()[0]) * 1024
#        return out
#
#    def _cpu_percent(self):
#        with open("/proc/stat") as fh:
#            parts = [int(x) for x in fh.readline().split()[1:]]
#        idle, total = parts[3] + parts[4], sum(parts)
#        prev, self.cpu = self.cpu, (idle, total)
#        if not prev:
#            return None
#        d_total = total - prev[1]
#        if d_total <= 0:
#            return None
#        return round(100.0 * (1 - (idle - prev[0]) / d_total), 1)
#
#    def _net_rates(self):
#        rx = tx = 0
#        with open("/proc/net/dev") as fh:
#            for line in fh.readlines()[2:]:
#                name, _, rest = line.partition(":")
#                if name.strip() == "lo":
#                    continue
#                f = rest.split()
#                rx += int(f[0]); tx += int(f[8])
#        stamp = time.time()
#        prev, self.net = self.net, (rx, tx, stamp)
#        if not prev:
#            return None, None
#        dt = stamp - prev[2]
#        if dt <= 0:
#            return None, None
#        return int((rx - prev[0]) / dt), int((tx - prev[1]) / dt)
#
#    def sample(self):
#        m = self._meminfo()
#        rx, tx = self._net_rates()
#        st = os.statvfs("/")
#        with open("/proc/uptime") as fh:
#            uptime = int(float(fh.readline().split()[0]))
#        with open("/proc/loadavg") as fh:
#            load = float(fh.readline().split()[0])
#        swap_total = m.get("SwapTotal", 0)
#        return {
#            "cpu": self._cpu_percent(),
#            "load": load,
#            "mem_total": m.get("MemTotal", 0),
#            "mem_used": m.get("MemTotal", 0) - m.get("MemAvailable", 0),
#            "swap_total": swap_total,
#            "swap_used": swap_total - m.get("SwapFree", 0) if swap_total else 0,
#            "disk_total": st.f_blocks * st.f_frsize,
#            "disk_used": (st.f_blocks - st.f_bfree) * st.f_frsize,
#            "rx_bps": rx,
#            "tx_bps": tx,
#            "uptime": uptime,
#        }
#
#
## ------------------------------------------------------- plans and payments
## What an account is told, queued for smartdns-bot. Only an account with a
## Telegram behind it hears anything; the rest see the same news on the relay's
## page, which reads the same columns.
#MSG_EXPIRED = ("⏳ دورهٔ سرویس شما تمام شد و سرویس قطع است.\n"
#               "برای تمدید، از «🛒 خرید / تمدید» یک پلن بخرید.")
#MSG_OVER_QUOTA = ("⛔️ حجم سرویس شما تمام شد و سرویس قطع است.\n"
#                  "برای ادامه، از «🛒 خرید / تمدید» یک پلن بخرید.")
#MSG_ACTIVATED = ("✅ حساب شما فعال شد.\n"
#                 "اگر هنوز آی‌پی اینترنتتان را ثبت نکرده‌اید، از «🌐 ثبت آی‌پی» ثبتش کنید.")
#
## How long a payment link stays good. Long enough to go and find a card and
## come back; short enough that an old link cannot buy at an old price.
#PAY_LINK_HOURS = 24
#
## How old a mini app's signed launch data may be. It is signed when the app
## opens and used seconds later; an hour forgives a phone left on the page.
#INIT_DATA_MAX_AGE = 3600
#
#
#def human_fa(n):
#    n = float(n or 0)
#    for unit in ("بایت", "کیلوبایت", "مگابایت", "گیگابایت", "ترابایت"):
#        if n < 1024 or unit == "ترابایت":
#            return ("%d %s" if unit == "بایت" else "%.2f %s") % (n, unit)
#        n /= 1024
#
#
#def toman(n):
#    return "%s تومان" % format(int(n or 0), ",")
#
#
#def user_label(user):
#    name = user["first_name"] or user["username"] or user["phone"] or ""
#    return ("%s (#%d)" % (name, user["id"])) if name else "#%d" % user["id"]
#
#
#def plan_summary(plan):
#    gb = float(plan["quota_gb"] or 0)
#    parts = [plan["name"],
#             ("%g گیگ" % gb) if gb else "حجم نامحدود",
#             ("%d روز" % plan["days"]) if plan["days"] else "بدون محدودیت زمان"]
#    if plan["speed_mbps"]:
#        parts.append("%g مگابیت" % float(plan["speed_mbps"]))
#    parts.append(toman(plan["price"]))
#    return " · ".join(parts)
#
#
#def queue_message(store, chat_id, text):
#    if chat_id:
#        store.run("INSERT INTO outbox (chat_id, text, created_at) VALUES (?, ?, ?)",
#                  (int(chat_id), text, now()))
#
#
#def tell_user(store, user, text):
#    queue_message(store, user["telegram_id"], text)
#
#
#def bot_admins(store):
#    """The Telegram chats allowed into the bot's admin menu."""
#    return [int(x) for x in store.setting("bot_admins", "").split(",")
#            if re.fullmatch(r"\s*-?\d{1,20}\s*", x)]
#
#
#def tell_admins(store, text):
#    for chat in bot_admins(store):
#        queue_message(store, chat, text)
#
#
#def new_admin_code(store, hours=24):
#    """A one-time code that makes whoever sends it to the bot its admin.
#
#    Shown in the admin panel, or printed by `smartdns-bot code`, only to
#    somebody who has already proved they run this machine - which is what makes
#    eight hex digits for a day enough.
#    """
#    code = secrets.token_hex(4)
#    until = (datetime.now(timezone.utc) + timedelta(hours=hours)).isoformat(
#        timespec="seconds")
#    store.set_setting("bot_admin_code", "%s|%s" % (code, until))
#    return code
#
#
#def telegram_init_data(token, raw, max_age=None):
#    """The Telegram user a mini app was opened by, or None.
#
#    Telegram signs what it hands a mini app with a key derived from the bot's
#    token: HMAC-SHA256 of the token keyed with "WebAppData", then HMAC-SHA256
#    of every other field, sorted and joined as key=value lines. A match proves
#    the data came from Telegram for this bot; auth_date keeps an old copy from
#    being replayed.
#    """
#    if not token or not raw:
#        return None
#    try:
#        pairs = urllib.parse.parse_qsl(raw, keep_blank_values=True,
#                                       strict_parsing=True)
#    except ValueError:
#        return None
#    fields = dict(pairs)
#    given = fields.pop("hash", "")
#    # A repeated field is not something Telegram sends, and would let the
#    # checked value and the used value differ.
#    if not given or len(pairs) != len(fields) + 1:
#        return None
#    check = "\n".join("%s=%s" % (k, fields[k]) for k in sorted(fields))
#    secret = hmac.new(b"WebAppData", token.encode(), hashlib.sha256).digest()
#    want = hmac.new(secret, check.encode(), hashlib.sha256).hexdigest()
#    if not hmac.compare_digest(want, given.lower()):
#        return None
#    try:
#        age = time.time() - int(fields.get("auth_date", ""))
#        user = json.loads(fields.get("user", ""))
#        int(user["id"])
#    except (ValueError, KeyError, TypeError):
#        return None
#    if age > (INIT_DATA_MAX_AGE if max_age is None else max_age) or age < -300:
#        return None
#    return user
#
#
## ------------------------------------------------------------- game pings
## The catalogue's games, whose domains the relays ping so that customers can see
## how each game's servers answer from Iran. The relay pings, not this machine:
## this one is abroad, and its ping says nothing about an Iranian line.
#GAME_SERVICES = ("playstation", "xbox", "nintendo", "steam", "epic", "ea", "blizzard",
#                 "ubisoft", "riot", "rockstar", "bethesda", "gog", "roblox", "minecraft")
#PING_HOSTS_PER_GAME = 4
## Older than this and the bot says so: the relay measures every five minutes,
## so a quarter of an hour without news means it has stopped.
#PING_STALE_MINUTES = 15
#
#
#def ping_targets(catalogue):
#    """What each relay should ping: {service: {"label", "hosts"}}.
#
#    Taken from the catalogue rather than kept as a list of its own, so a game
#    added to it is pinged too. A few domains per game, not all of them.
#    """
#    out = {}
#    for svc in catalogue or []:
#        if svc.get("key") not in GAME_SERVICES:
#            continue
#        hosts = []
#        for grp in svc.get("groups") or []:
#            for d in grp.get("domains") or []:
#                if d not in hosts:
#                    hosts.append(d)
#        if hosts:
#            out[svc["key"]] = {"label": svc.get("label") or svc["key"],
#                               "hosts": hosts[:PING_HOSTS_PER_GAME]}
#    return out
#
#
#def relay_pings(store):
#    """{relay address: {"at": when, "games": {...}}}, the latest from each."""
#    try:
#        every = json.loads(store.setting("relay_pings", "") or "{}")
#    except ValueError:
#        return {}
#    return every if isinstance(every, dict) else {}
#
#
## ------------------------------------------------------------------ exits
## What an extra exit's installer prints when it is given a tunnel, and what the
## operator pastes into the bot: BackPack's transport and port, the direction
## (always d - the relay dials an extra exit), and the token the two ends prove
## themselves with. One line, so the two ends cannot be set up differently.
#EXIT_TUNNEL_TRANSPORTS = ("stealth", "wss", "tcp", "ws")
#EXIT_TUNNEL_RE = re.compile(r"^bp-([a-z]{2,10})-(\d{1,5})-d\.([0-9a-f]{16,64})$")
#
#
#def parse_exit_tunnel(line):
#    """(transport, port, token) from an extra exit's tunnel line, or None."""
#    m = EXIT_TUNNEL_RE.match((line or "").strip())
#    if not m:
#        return None
#    transport, port, token = m.group(1), int(m.group(2)), m.group(3)
#    if transport not in EXIT_TUNNEL_TRANSPORTS or not 1 <= port <= 65535:
#        return None
#    return transport, port, token
#
#
#def main_exit_name(store):
#    return store.setting("main_exit_name", "") or "سرور اصلی"
#
#
#def exit_pings(store):
#    """{relay: {"at", "exits": {id: {"ms", "loss"}}}}, the latest from each."""
#    try:
#        every = json.loads(store.setting("relay_exit_pings", "") or "{}")
#    except ValueError:
#        return {}
#    return every if isinstance(every, dict) else {}
#
#
#def fresh_exit_pings(store, relay=None):
#    """{exit id: fastest ms} from recent rounds - one relay's, or the best of all.
#
#    A round older than PING_STALE_MINUTES says nothing about now, and choosing
#    an exit on it could put everybody on one that has since gone quiet."""
#    stamp = datetime.now(timezone.utc)
#    out = {}
#    for r, entry in exit_pings(store).items():
#        if (relay is not None and r != relay) or not isinstance(entry, dict):
#            continue
#        seen = parse_ts(entry.get("at"))
#        if not seen or (stamp - seen).total_seconds() > PING_STALE_MINUTES * 60:
#            continue
#        for eid, p in (entry.get("exits") or {}).items():
#            ms = p.get("ms") if isinstance(p, dict) else None
#            if isinstance(ms, (int, float)) and (eid not in out or ms < out[eid]):
#                out[eid] = ms
#    return out
#
#
#def resolve_exit(choice, measured, active):
#    """The exit an account's traffic takes, as its id in text - "0" the main.
#
#    The account's own choice while that exit is active. Otherwise - automatic,
#    or a choice that has since been switched off - the fastest exit measured,
#    and the main exit when nothing has been."""
#    if choice is not None and (choice == 0 or str(choice) in active):
#        return str(choice)
#    best, best_ms = "0", None
#    for eid in ["0"] + sorted(active, key=int):
#        ms = measured.get(eid)
#        if isinstance(ms, (int, float)) and (best_ms is None or ms < best_ms):
#            best, best_ms = eid, ms
#    return best
#
#
#def trial_settings(store):
#    return {"on": store.setting("trial_on", "1") == "1",
#            "gb": float(store.setting("trial_gb", "1") or 0),
#            "hours": float(store.setting("trial_hours", "24") or 0),
#            "mbps": float(store.setting("trial_mbps", "0") or 0)}
#
#
#def trial_summary(store):
#    t = trial_settings(store)
#    parts = [("%g گیگ" % t["gb"]) if t["gb"] else "حجم نامحدود", "%g ساعت" % t["hours"]]
#    if t["mbps"]:
#        parts.append("%g مگابیت" % t["mbps"])
#    return " · ".join(parts)
#
#
#def trial_reason(store, user):
#    """Why this account cannot take the free trial, or "" if it can.
#
#    A reason rather than a yes or no, because every caller wants to say what
#    the matter is. Only an account that has never had anything is offered one:
#    a customer whose plan has run out is asked to buy, not given another
#    trial.
#    """
#    t = trial_settings(store)
#    if not t["on"] or t["hours"] <= 0:
#        return "تست رایگان الان فعال نیست"
#    if not user["telegram_id"]:
#        return "تست رایگان فقط از داخل ربات تلگرام گرفته می‌شود"
#    if user["trial_at"]:
#        return "تست رایگان این حساب قبلاً گرفته شده"
#    if user["status"] == "suspended":
#        return "این حساب مسدود است"
#    if user["status"] != "pending":
#        return "تست رایگان فقط برای حسابی است که هنوز پلنی نداشته"
#    return ""
#
#
#def grant_trial(store, user_id):
#    """Hand out the one free trial an account gets: (ok, why not).
#
#    One statement does the giving and the recording, and only while trial_at is
#    still null, so two taps a moment apart cannot take two trials - the second
#    changes no rows and is told so.
#    """
#    user = store.one("SELECT * FROM users WHERE id = ?", (user_id,))
#    if not user:
#        return False, "حساب پیدا نشد"
#    reason = trial_reason(store, user)
#    if reason:
#        return False, reason
#    t = trial_settings(store)
#    ends = (datetime.now(timezone.utc) + timedelta(hours=t["hours"])).isoformat(
#        timespec="seconds")
#    stamp = now()
#    changed = store.run(
#        "UPDATE users SET quota_bytes = ?, used_bytes = 0, warned = 0, speed_kbps = ?,"
#        " quota_mode = 'oneoff', quota_reset_at = NULL, expires_at = ?,"
#        " status = 'active', trial_at = ?"
#        " WHERE id = ? AND trial_at IS NULL AND status = 'pending'",
#        (int(t["gb"] * GB), int(t["mbps"] * 1000), ends, stamp, user_id)).rowcount
#    if changed != 1:
#        return False, "تست رایگان این حساب قبلاً گرفته شده"
#    # Recorded like a payment of nothing, so the trials show up beside the
#    # sales rather than only as a date on the account.
#    store.run(
#        "INSERT INTO transactions (user_id, amount, kind, status, note, created_at,"
#        " decided_at) VALUES (?, 0, 'trial', 'approved', 'trial', ?, ?)",
#        (user_id, stamp, stamp))
#    print("trial: user %d, %s until %s" % (user_id, trial_summary(store), ends), flush=True)
#    return True, ""
#
#
#def apply_plan(store, user_id, plan):
#    """Give an account what a plan says, from now.
#
#    Buying is renewing: the allowance is replaced rather than added to, usage
#    starts again from zero and the period is counted from today - the same as
#    an operator opening the row and typing the plan in. A suspended account
#    stays suspended: paying does not overrule a decision to block somebody. A
#    plan with no template leaves the account's template alone.
#    """
#    days = int(plan["days"] or 0)
#    ends = ((datetime.now(timezone.utc) + timedelta(days=days)).isoformat(
#        timespec="seconds") if days > 0 else None)
#    store.run(
#        "UPDATE users SET quota_bytes = ?, used_bytes = 0, warned = 0,"
#        " speed_kbps = ?, quota_mode = 'oneoff', quota_reset_at = NULL,"
#        " expires_at = ?, template_id = COALESCE(?, template_id),"
#        " status = CASE WHEN status = 'suspended' THEN status ELSE 'active' END"
#        " WHERE id = ?",
#        (int(float(plan["quota_gb"] or 0) * GB),
#         int(float(plan["speed_mbps"] or 0) * 1000), ends,
#         plan["template_id"], user_id))
#
#
#def settle_transactions(store):
#    """Carry out payment decisions nobody has acted on yet.
#
#    A receipt approved in the admin panel or the bot, or a payment the relay
#    has had Zibal confirm, is marked settled = 0; this applies its plan and
#    tells the customer. Both this process, after every sync, and smartdns-bot
#    run it, so a decision takes effect within seconds when the bot is up and
#    within a sync when it is not.
#    """
#    rows = store.q(
#        "SELECT t.*, p.name AS plan_name, p.quota_gb, p.days, p.speed_mbps,"
#        " p.template_id FROM transactions t LEFT JOIN plans p ON p.id = t.plan_id"
#        " WHERE t.settled = 0 AND t.status IN ('approved', 'rejected')"
#        " ORDER BY t.id")
#    for t in rows:
#        # Claimed and carried out as two steps, claim first: whichever process
#        # claims a row does it, once. A crash in between leaves it unapplied
#        # and logged, which an operator can see and fix; applying it twice
#        # would silently reset somebody's usage a second time.
#        if store.run("UPDATE transactions SET settled = 1 WHERE id = ? AND settled = 0",
#                     (t["id"],)).rowcount != 1:
#            continue
#        user = store.one("SELECT * FROM users WHERE id = ?", (t["user_id"],))
#        if not user:
#            continue
#        if t["status"] == "rejected":
#            tell_user(store, user, "❌ رسید پرداخت شما رد شد.\nاگر فکر می‌کنید اشتباهی "
#                                   "شده، رسید درست را دوباره بفرستید یا با پشتیبانی "
#                                   "تماس بگیرید.")
#        elif t["plan_name"] is not None:
#            apply_plan(store, user["id"], t)
#            print("plan applied: user %d, %s, transaction %d"
#                  % (user["id"], t["plan_name"], t["id"]), flush=True)
#            tell_user(store, user, "✅ پرداخت شما تأیید شد و پلن «%s» فعال شد.\n"
#                                   "اگر آی‌پی‌تان را ثبت نکرده‌اید، از «🌐 ثبت آی‌پی» "
#                                   "ثبتش کنید." % t["plan_name"])
#        else:
#            tell_user(store, user, "✅ رسید پرداخت شما تأیید شد. حسابتان به‌زودی "
#                                   "شارژ می‌شود.")
#
#
## What an operator does to one account from the bot. The admin panel's forms do
## the same; that panel keeps its own copy rather than importing this file, so a
## change to what these mean has to be made in both.
#def activate_if_pending(store, user_id):
#    if store.run("UPDATE users SET status = 'active' WHERE id = ? AND status = 'pending'",
#                 (user_id,)).rowcount:
#        tell_user(store, store.one("SELECT * FROM users WHERE id = ?", (user_id,)),
#                  MSG_ACTIVATED)
#        return True
#    return False
#
#
#def set_user_quota(store, user_id, gb):
#    store.run("UPDATE users SET quota_bytes = ?, warned = 0,"
#              " status = CASE WHEN status = 'over_quota' THEN 'active' ELSE status END"
#              " WHERE id = ?", (int(float(gb) * GB), user_id))
#    return activate_if_pending(store, user_id)
#
#
#def set_user_days(store, user_id, days):
#    days = float(days)
#    if days == 0:
#        store.run("UPDATE users SET expires_at = NULL, quota_reset_at = NULL,"
#                  " quota_mode = 'oneoff', status = CASE WHEN status = 'expired'"
#                  " THEN 'active' ELSE status END WHERE id = ?", (user_id,))
#    else:
#        stamp = (datetime.now(timezone.utc) + timedelta(days=days)).isoformat(
#            timespec="seconds")
#        row = store.one("SELECT quota_mode FROM users WHERE id = ?", (user_id,))
#        if row and row["quota_mode"] == "monthly":
#            store.run("UPDATE users SET quota_reset_at = ? WHERE id = ?",
#                      (stamp, user_id))
#        else:
#            store.run("UPDATE users SET expires_at = ?, status = CASE WHEN"
#                      " status = 'expired' THEN 'active' ELSE status END"
#                      " WHERE id = ?", (stamp, user_id))
#    return activate_if_pending(store, user_id)
#
#
#def set_user_speed(store, user_id, mbps):
#    store.run("UPDATE users SET speed_kbps = ? WHERE id = ?",
#              (int(float(mbps) * 1000), user_id))
#
#
#def set_user_status(store, user_id, to):
#    if to not in ("active", "suspended"):
#        raise ValueError("no such status: %r" % to)
#    store.run("UPDATE users SET status = ?, warned = CASE WHEN ? = 'active'"
#              " THEN 0 ELSE warned END WHERE id = ?", (to, to, user_id))
#
#
#def reset_user_usage(store, user_id):
#    store.run("UPDATE users SET used_bytes = 0, warned = 0,"
#              " status = CASE WHEN status = 'over_quota' THEN 'active'"
#              " ELSE status END WHERE id = ?", (user_id,))
#
#
## ------------------------------------------------------------------ quota
#def enforce_quotas(store):
#    """Reset, warn and cut off. Called after every sync.
#
#    Cutting off is a status change and nothing more. The relay learns about it
#    on its next sync, when the address stops appearing in the allowed list and
#    smartdns-acl removes it from the kernel. Nothing here touches a firewall
#    directly - one place decides who may connect, and it is the database.
#
#    The warning thresholds are recorded in users.warned, which the customer's
#    own panel page reads - that reaches everybody. An account with a Telegram
#    behind it is also sent a message, queued here and delivered by
#    smartdns-bot; nothing in this process talks to Telegram.
#    """
#    stamp = datetime.now(timezone.utc)
#    for u in store.q("SELECT * FROM users"):
#        quota, used = u["quota_bytes"], u["used_bytes"]
#
#        # A trial ends on its date whether or not the allowance ran out, so
#        # this comes before anything to do with bytes. Checked for every
#        # account, but only the trial sets a date - a paid account ends when
#        # its quota does.
#        due = parse_ts(u["expires_at"])
#        if due and stamp >= due:
#            if u["status"] == "active":
#                store.run("UPDATE users SET status = 'expired' WHERE id = ?",
#                          (u["id"],))
#                print("expired: user %d after %s" % (u["id"], human(used)),
#                      flush=True)
#                tell_user(store, u, MSG_EXPIRED)
#            continue
#
#        # Monthly plans roll over on their own date rather than on the 1st, so
#        # a user who joins on the 20th gets a full month.
#        if u["quota_mode"] == "monthly" and u["quota_reset_at"]:
#            due = parse_ts(u["quota_reset_at"])
#            if due and stamp >= due:
#                days = int(store.setting("plan_days", "30") or 30)
#                store.run(
#                    "UPDATE users SET used_bytes = 0, warned = 0,"
#                    " status = CASE WHEN status = 'over_quota' THEN 'active' ELSE status END,"
#                    " quota_reset_at = ? WHERE id = ?",
#                    ((stamp + timedelta(days=days)).isoformat(timespec="seconds"), u["id"]),
#                )
#                continue
#
#        if not quota:            # unlimited
#            continue
#
#        if used >= quota and u["status"] == "active":
#            store.run("UPDATE users SET status = 'over_quota' WHERE id = ?", (u["id"],))
#            print("over quota: user %d at %s of %s"
#                  % (u["id"], human(used), human(quota)), flush=True)
#            tell_user(store, u, MSG_OVER_QUOTA)
#            continue
#
#        # Record each threshold as it is crossed, once. The bit is what makes
#        # it once - a sync runs every thirty seconds - and it is what the
#        # customer's own page reads to decide whether to warn them.
#        crossed = [(fraction, bit) for fraction, bit in THRESHOLDS
#                   if used >= quota * fraction and not (u["warned"] & bit)]
#        for fraction, bit in crossed:
#            store.run("UPDATE users SET warned = warned | ? WHERE id = ?",
#                      (bit, u["id"]))
#        # One message for the highest line crossed, not one per line: usage
#        # that jumps past 80% and 95% in one sync is one piece of news.
#        if crossed:
#            tell_user(store, u, "⚠️ %d٪ حجم سرویس شما مصرف شده — %s مانده.\n"
#                                "برای تمدید از «🛒 خرید / تمدید» استفاده کنید."
#                      % (int(crossed[-1][0] * 100), human_fa(max(0, quota - used))))
#
#    # Decisions made since the last pass - a receipt approved in the admin
#    # panel, a payment the relay verified - take effect here if smartdns-bot
#    # has not already carried them out.
#    settle_transactions(store)
#
#
## ------------------------------------------------------------------ logging
## journald reads a leading <N> on a line as its syslog level. Warnings and
## errors carry one, so `journalctl -p warning` - which is what
## `smartdns-logs -e` runs - shows exactly the problems. Ordinary lines stay
## unmarked and land at info, as they always did. Before this everything
## landed at info, stderr included, and a failure looked like a heartbeat.
#INFO, WARN, ERROR = 6, 4, 3
## The visitor went away, or never finished saying hello. Not a fault here.
#GONE = (ConnectionError, TimeoutError, ssl.SSLError)
#
#
#def log(level, msg):
#    tag = "<%d>" % level if level < INFO else ""
#    for line in str(msg).splitlines() or [""]:
#        print(tag + line, flush=True)
#
#
#def log_exception(what):
#    """An error with its traceback, every line at error level. journald makes
#    each line its own entry, and at info all but the first would be lost
#    among the ordinary ones."""
#    log(ERROR, "%s\n%s" % (what, traceback.format_exc().rstrip()))
#
#
#def log_access(h, prefix, code, path, who=""):
#    """One line for one request: what was asked, the answer, how long it took
#    and who asked. Server errors at error level; everything else is info."""
#    try:
#        code = int(code)
#    except (TypeError, ValueError):
#        code = 0
#    ms = (time.monotonic() - getattr(h, "_t0", time.monotonic())) * 1000
#    # 501 is a scanner's GET to a POST-only port: the visitor's mistake.
#    log(ERROR if code >= 500 and code != 501 else INFO, "%s %s %s %d %dms from %s%s" % (
#        prefix, getattr(h, "command", None) or "-", path, code, ms,
#        h.client_address[0], " " + who if who else ""))
#
#
## How long a visitor may take over the TLS handshake, and then how long any one
## read or write may stall. Per operation, so a receipt crawling up from a
## relay that keeps moving is never cut off, while a quiet connection is let go.
#HANDSHAKE_TIMEOUT = 10
#IO_TIMEOUT = 30
#
#
#class TLSServer(http.server.ThreadingHTTPServer):
#    """TLS per connection, under a deadline - never on the listening socket.
#
#    Wrapping the listening socket runs every visitor's handshake inside
#    accept(), on the one thread that accepts for all of them and with no
#    timeout, so a single connection that opens and then says nothing freezes
#    the server for everybody until it goes away. The customer panel froze
#    exactly that way in production, and this server was built the same way -
#    here it would have been worse: this port is public, the relay check comes
#    after the handshake, and while it hung no relay could sync, so nobody new
#    was let in and nobody whose time ran out was cut off. Here accept() only
#    accepts; a stalled visitor stalls only its own thread.
#
#    ctx=None serves plain http. That is for tests - serve_api never does.
#    """
#    daemon_threads = True
#
#    def __init__(self, addr, handler, ctx):
#        self.ctx = ctx
#        super().__init__(addr, handler)
#
#    def finish_request(self, request, client_address):
#        if self.ctx is None:
#            return super().finish_request(request, client_address)
#        request.settimeout(HANDSHAKE_TIMEOUT)
#        try:
#            tls = self.ctx.wrap_socket(request, server_side=True)
#        except (ssl.SSLError, OSError):
#            return      # a scanner, or plain http to an https port
#        try:
#            tls.settimeout(IO_TIMEOUT)
#            self.RequestHandlerClass(tls, client_address, self)
#        except (ssl.SSLError, OSError):
#            pass
#        finally:
#            try:
#                tls.close()
#            except OSError:
#                pass
#
#    def handle_error(self, request, client_address):
#        # Whatever a handler did not catch, with its traceback, at error
#        # level. http.server's default prints it at info, where nobody looks.
#        if isinstance(sys.exc_info()[1], GONE):
#            return
#        log_exception("request from %s failed" % client_address[0])
#
#
## --------------------------------------------------------------- sync API
#class API(http.server.BaseHTTPRequestHandler):
#    server_version = "smartdns"
#    store = None
#    secret = None
#    relays = ()
#    tg = None
#
#    def log_message(self, fmt, *args):
#        # http.server's own notes - a malformed request, a timeout. The access
#        # line is log_request below.
#        log(INFO, "api %s from %s" % (fmt % args, self.client_address[0]))
#
#    def parse_request(self):
#        self._t0 = time.monotonic()
#        return super().parse_request()
#
#    def log_request(self, code="-", size="-"):
#        """One line per request, except the heartbeat: every relay syncs every
#        thirty seconds, and a line for each would bury everything else. A sync
#        is logged when it fails or crawls."""
#        path = urllib.parse.urlparse(getattr(self, "path", "") or "").path[:120]
#        took = time.monotonic() - getattr(self, "_t0", time.monotonic())
#        try:
#            fine = int(code) == 200
#        except (TypeError, ValueError):
#            fine = False
#        if path == "/sync" and fine and took < 2:
#            return
#        log_access(self, "api", code, path, getattr(self, "_who", ""))
#
#    def reply(self, code, obj):
#        body = json.dumps(obj).encode()
#        self.send_response(code)
#        self.send_header("Content-Type", "application/json")
#        self.send_header("Content-Length", str(len(body)))
#        self.end_headers()
#        self.wfile.write(body)
#
#    def authorised(self):
#        # This port is reachable from the whole internet, so the bearer token
#        # is not the only thing standing in front of the database. Only the
#        # relays this exit is paired with may talk to it at all - a scanner
#        # that finds the port gets nothing to guess against.
#        if self.client_address[0] not in self.relays:
#            return False
#        given = self.headers.get("Authorization", "")
#        want = "Bearer " + self.secret
#        # Constant time, so the comparison cannot be used to guess the secret
#        # one character at a time.
#        if hmac.compare_digest(given, want):
#            return True
#        # One of our own relays with the wrong secret is a broken pairing,
#        # not a scanner, and nothing works on that relay until it is fixed.
#        # Strangers get only their request line.
#        log(WARN, "api: %s is a paired relay but sent the wrong secret - its "
#            "SYNC_SECRET does not match this panel's" % self.client_address[0])
#        return False
#
#    def do_POST(self):
#        if not self.authorised():
#            return self.reply(401, {"error": "unauthorised"})
#        try:
#            length = int(self.headers.get("Content-Length", 0))
#            # Base64 inflates by a third, and the largest thing a relay sends
#            # is a receipt. Anything past that is refused unread rather than
#            # buffered.
#            if length > 8 * MB:
#                return self.reply(413, {"error": "too large"})
#            body = json.loads(self.rfile.read(length) or b"{}")
#        except Exception:
#            return self.reply(400, {"error": "bad json"})
#
#        if self.path == "/sync":
#            counters = body.get("counters") or {}
#            clean = {
#                ip: int(v) for ip, v in counters.items() if valid_ip(ip) and int(v) >= 0
#            }
#            self.store.fold_counters(self.client_address[0], clean)
#            # The relay names itself by the address it connected from, so a
#            # second relay appears on its own without any configuration.
#            self.store.record_metrics(self.client_address[0], body.get("host") or {})
#            self.store.note_relay(body.get("panel"), body.get("dns"))
#            self.store.note_pings(self.client_address[0], body.get("pings"))
#            self.store.note_exit_pings(self.client_address[0], body.get("exit_pings"))
#            # Quotas are evaluated here, on fresh numbers, so a user who runs
#            # out is off the list this relay is about to be handed.
#            try:
#                enforce_quotas(self.store)
#            except Exception as e:
#                log_exception("quota pass failed: %r" % e)
#            by_ip, profiles = self.store.profiles(CATALOGUE, DEFAULT_TEMPLATE[0])
#            # The label goes into the nftables element as a comment, so that
#            # `smartdns-acl list` on the relay is readable without the
#            # database in front of you. The profile tells the relay which
#            # resolver this address should be pointed at.
#            # uid travels as well as the label built from it: the relay uses
#            # it as the shaping mark, and parsing it back out of "u12" would
#            # be a second place that has to agree about the format.
#            allowed = [{"ip": ip, "name": "u%d" % v["uid"], "uid": v["uid"],
#                        "kbps": v["kbps"], "user": v.get("user", ""),
#                        "profile": str(v["tid"]) if str(v["tid"]) in profiles else ""}
#                       for ip, v in sorted(by_ip.items())]
#            # Which exit each address leaves by, from this relay: the
#            # account's own choice, or the fastest this relay measured. The
#            # relay turns it into an nginx map. With no extra exits nothing is
#            # sent, and every address takes the relay's own exit.
#            exits = {}
#            for r in self.store.active_exits():
#                e = {"name": r["name"], "ip": r["ip"]}
#                # The tunnel travels with the exit: the relay dials it, and
#                # this is the only place the two ends' settings come from.
#                if r["tunnel_transport"] and r["tunnel_port"] and r["tunnel_token"]:
#                    e["tunnel"] = {"transport": r["tunnel_transport"],
#                                   "port": int(r["tunnel_port"]),
#                                   "token": r["tunnel_token"]}
#                exits[str(r["id"])] = e
#            if exits:
#                measured = fresh_exit_pings(self.store, self.client_address[0])
#                choices = {r["id"]: r["exit_id"] for r in self.store.q(
#                    "SELECT id, exit_id FROM users WHERE status = 'active'")}
#                for a in allowed:
#                    a["exit"] = resolve_exit(choices.get(a["uid"]), measured, exits)
#            extra = [r["domain"] for r in self.store.q(
#                "SELECT domain FROM custom_domains ORDER BY domain")]
#            return self.reply(200, {"allowed": allowed, "profiles": profiles,
#                                    "extra_domains": extra,
#                                    "templates": self.store.template_names(),
#                                    "ping_targets": ping_targets(CATALOGUE),
#                                    "exits": exits,
#                                    })
#
#        # ---- user panel, served by the relay on the customer's behalf ----
#        if self.path == "/user-info":
#            return self.reply(200, self.do_user_info(body))
#        if self.path == "/user-claim":
#            return self.reply(200, self.do_user_claim(body))
#        if self.path == "/user-signup":
#            return self.reply(200, self.do_user_signup(body))
#        if self.path == "/user-password-login":
#            return self.reply(200, self.do_user_password_login(body))
#        if self.path == "/user-receipt":
#            return self.reply(200, self.do_user_receipt(body))
#        if self.path == "/user-password":
#            return self.reply(200, self.do_user_password(body))
#
#        # ---- the bot's mini app and online payment, served by the relay ----
#        if self.path == "/tg-claim":
#            return self.reply(200, self.do_tg_claim(body))
#        if self.path == "/pay-order":
#            return self.reply(200, self.do_pay_order(body))
#        if self.path == "/pay-started":
#            return self.reply(200, self.do_pay_started(body))
#        if self.path == "/pay-verified":
#            return self.reply(200, self.do_pay_verified(body))
#
#        return self.reply(404, {"error": "no such endpoint"})
#
#    # ---- user panel ------------------------------------------------------
#    def _session_user(self, token):
#        row = self.store.one(
#            "SELECT u.* FROM panel_sessions s JOIN users u ON u.id = s.user_id"
#            " WHERE s.token = ? AND s.expires_at > ?", (token or "", now()))
#        if row:
#            # Named on the request line: which customer, never the session.
#            self._who = "user #%d" % row["id"]
#        return row
#
#    def do_user_signup(self, body):
#        """Open an account from the panel, with no Telegram in the way.
#
#        The address is not registered here. Signing up and pointing the service
#        at a connection are two different decisions - somebody may well sign up
#        on mobile data and only afterwards go and register the home line - so
#        the next page asks, showing the address it can see.
#        """
#        ip = body.get("ip", "")
#        ok, wait = THROTTLE.check("signup:%s" % ip, limit=4, window=3600)
#        if not ok:
#            return {"ok": False, "message":
#                    "تعداد ثبت‌نام از این اینترنت زیاد بوده. %d دقیقه دیگر."
#                    % max(1, wait // 60)}
#
#        username = normal_username(body.get("username"))
#        if not username:
#            return {"ok": False, "message":
#                    "نام کاربری باید ۳ تا ۳۲ نویسه باشد — حروف انگلیسی، عدد،"
#                    " و . _ -"}
#        password = body.get("password") or ""
#        if len(password) < 8:
#            return {"ok": False, "message": "رمز باید دست‌کم ۸ نویسه باشد"}
#        name = (body.get("name") or "").strip()[:60]
#
#        if self.store.user_by_username(username):
#            return {"ok": False,
#                    "message": "این نام کاربری قبلاً گرفته شده. یکی دیگر"
#                               " بنویسید یا وارد شوید"}
#        try:
#            user = self.store.create_web_user(username, name, password)
#        except sqlite3.IntegrityError:
#            # Two signups claiming the same name in the same instant. The
#            # unique index is what actually decides between them; this only
#            # turns its answer into a sentence.
#            return {"ok": False,
#                    "message": "این نام کاربری قبلاً گرفته شده. یکی دیگر"
#                               " بنویسید یا وارد شوید"}
#        THROTTLE.hit("signup:%s" % ip)
#        print("web signup: %s (#%d) from %s" % (username, user["id"], ip), flush=True)
#        return {"ok": True, "session": self.store.open_session(user["id"]),
#                "message": "حساب ساخته شد"}
#
#    def do_user_password_login(self, body):
#        ip = body.get("ip", "")
#        ok, wait = THROTTLE.check("login:%s" % ip, limit=8, window=900)
#        if not ok:
#            log(WARN, "api login throttled for %s: too many failed attempts" % ip)
#            return {"ok": False, "message":
#                    "تلاش زیاد بوده. %d دقیقه دیگر امتحان کنید."
#                    % max(1, wait // 60)}
#
#        username = normal_username(body.get("username"))
#        user = self.store.user_by_username(username) if username else None
#        # One message for an unknown name and a wrong password. Two different
#        # messages tell anybody who asks which names have accounts.
#        if not user or not check_password(user, body.get("password") or ""):
#            THROTTLE.hit("login:%s" % ip)
#            # The name tried and where from - enough to answer "I can't get
#            # in". Never the password.
#            log(INFO, "api login failed for %r from %s" % (username, ip))
#            return {"ok": False, "message": "نام کاربری یا رمز درست نیست"}
#        THROTTLE.clear("login:%s" % ip)
#        self._who = "user #%d" % user["id"]
#        log(INFO, "api login: user #%d (%s) from %s" % (user["id"], username, ip))
#        return {"ok": True, "session": self.store.open_session(user["id"])}
#
#    def do_user_password(self, body):
#        """Let a customer change their own password.
#
#        The current one is required even though the session already proves
#        who they are. A session can be a borrowed phone or a browser left
#        open; asking for the password again means possession of the session
#        is not enough to take the account away from its owner.
#        """
#        user = self._session_user(body.get("session"))
#        if not user:
#            return {"ok": False, "message": "نشست معتبر نیست"}
#        if not user["password_hash"]:
#            return {"ok": False,
#                    "message": "این حساب رمز ندارد؛ با پشتیبانی تماس بگیرید"}
#        if not check_password(user, body.get("current") or ""):
#            # Same throttle as signing in: this is a password guess like any
#            # other, and a stolen session should not buy unlimited attempts.
#            ok, wait = THROTTLE.check("pw:%d" % user["id"], limit=8, window=900)
#            if not ok:
#                return {"ok": False, "message":
#                        "تلاش زیاد بوده. %d دقیقه دیگر." % max(1, wait // 60)}
#            THROTTLE.hit("pw:%d" % user["id"])
#            return {"ok": False, "message": "رمز فعلی درست نیست"}
#
#        new = body.get("new") or ""
#        if len(new) < 8:
#            return {"ok": False, "message": "رمز تازه باید دست‌کم ۸ نویسه باشد"}
#        if new == (body.get("current") or ""):
#            return {"ok": False, "message": "رمز تازه با رمز فعلی یکی است"}
#
#        self.store.set_password(user["id"], new)
#        THROTTLE.clear("pw:%d" % user["id"])
#        # Every other session ends. Changing a password is what somebody does
#        # when they think another person has their account, so leaving that
#        # person signed in would defeat the whole exercise.
#        kept = body.get("session")
#        self.store.run(
#            "DELETE FROM panel_sessions WHERE user_id = ? AND token != ?",
#            (user["id"], kept))
#        print("password changed for user %d" % user["id"], flush=True)
#        return {"ok": True,
#                "message": "رمز عوض شد. اگر جای دیگری وارد بودید، خارج شدید"}
#
#    def do_user_receipt(self, body):
#        """Store a photograph of a payment slip against the customer.
#
#        The relay reads the upload and passes the bytes here base64-encoded,
#        so the image lands in the same database as everything else and one
#        backup covers it. Nothing about the account changes: this records a
#        claim, and the operator decides what it is worth.
#        """
#        user = self._session_user(body.get("session"))
#        if not user:
#            return {"ok": False, "message": "نشست معتبر نیست"}
#
#        kind = (body.get("content_type") or "").split(";")[0].strip().lower()
#        if kind not in ("image/jpeg", "image/png", "image/webp", "application/pdf"):
#            return {"ok": False,
#                    "message": "فقط عکس (JPG، PNG، WEBP) یا PDF قبول می‌شود"}
#        try:
#            blob = base64.b64decode(body.get("data") or "", validate=True)
#        except Exception:
#            return {"ok": False, "message": "فایل خراب بود، دوباره بفرستید"}
#        if not blob:
#            return {"ok": False, "message": "فایل خالی بود"}
#        if len(blob) > MAX_RECEIPT:
#            return {"ok": False, "message": "فایل بزرگ‌تر از %s است"
#                    % human(MAX_RECEIPT)}
#
#        # One pending receipt per customer. A second one replaces the first
#        # rather than queueing: somebody who sends three photographs of the
#        # same slip means the last one, and the operator should not have to
#        # work out which.
#        self.store.run(
#            "DELETE FROM transactions WHERE user_id = ? AND status = 'pending'",
#            (user["id"],))
#        try:
#            amount = max(0, int(body.get("amount") or 0))
#        except (TypeError, ValueError):
#            amount = 0
#        self.store.run(
#            "INSERT INTO transactions"
#            " (user_id, amount, kind, receipt_blob, receipt_type, note,"
#            "  status, created_at, admin_notified)"
#            " VALUES (?, ?, 'card', ?, ?, ?, 'pending', ?, 0)",
#            (user["id"], amount, blob, kind,
#             (body.get("note") or "").strip()[:200], now()))
#        print("receipt from user %d: %s, %s"
#              % (user["id"], kind, human(len(blob))), flush=True)
#        return {"ok": True,
#                "message": "رسید فرستاده شد. پس از بررسی حسابتان شارژ می‌شود"}
#
#    def do_user_claim(self, body):
#        """Register the address the browser is coming from, for a user who is
#        already signed in - the 'my address changed' button."""
#        user = self._session_user(body.get("session"))
#        if not user:
#            return {"ok": False, "message": "نشست معتبر نیست"}
#        ip = body.get("ip", "")
#        if not valid_ip(ip):
#            return {"ok": False, "message": "آی‌پی نامعتبر"}
#        return self.do_claim_register(user["id"], ip)
#
#    def do_claim_register(self, user_id, ip):
#        return self.store.claim_ip(user_id, ip)
#
#    def do_user_info(self, body):
#        user = self._session_user(body.get("session"))
#        if not user:
#            return {"ok": False, "message": "نشست معتبر نیست"}
#        ips = self.store.user_ips(user["id"])
#        tpl = self.store.one("SELECT name FROM templates WHERE id = ?",
#                             (user["template_id"],)) if user["template_id"] else None
#        if not tpl:
#            tpl = self.store.one("SELECT name FROM templates WHERE is_default = 1")
#        return {
#            "ok": True,
#            "name": user["first_name"] or user["username"] or "",
#            "telegram_id": user["telegram_id"],
#            "ip": ips[0]["ip"] if ips else None,
#            "used": user["used_bytes"],
#            "quota": user["quota_bytes"],
#            "status": user["status"],
#            "wallet": user["wallet"],
#            "plan": tpl["name"] if tpl else "",
#            "renews": (user["quota_reset_at"] or "")[:10],
#            "expires": (user["expires_at"] or "")[:10],
#            "speed_kbps": user["speed_kbps"] or 0,
#            # Which warning thresholds this account has crossed. The relay's
#            # page turns this into the banner the bot used to send.
#            "warned": user["warned"] or 0,
#            "seen_ip": body.get("ip", ""),
#        }
#
#    # ---- the bot's mini app and online payment ---------------------------
#    def do_tg_claim(self, body):
#        """Register the address a mini app was opened from.
#
#        The relay supplies the address - it is the only machine that sees the
#        customer's real one - and the launch data Telegram signed, which only
#        this side can check, because only this side has the bot's token.
#        """
#        tg = telegram_init_data(self.store.setting("bot_token"),
#                                body.get("init_data") or "")
#        if not tg:
#            return {"ok": False, "message": "این صفحه را از داخل ربات باز کنید"}
#        user = self.store.user_by_telegram(int(tg["id"]))
#        if not user:
#            return {"ok": False, "message": "اول ربات را استارت کنید"}
#        self._who = "user #%d" % user["id"]
#        ip = body.get("ip", "")
#        if not valid_ip(ip):
#            return {"ok": False, "message": "آی‌پی نامعتبر"}
#        res = self.store.claim_ip(user["id"], ip)
#        if res.get("ok"):
#            tell_user(self.store, user, "🌐 آی‌پی %s برای حساب شما ثبت شد." % ip)
#        return res
#
#    def _order(self, body):
#        token = body.get("token") or ""
#        if not re.fullmatch(r"[A-Za-z0-9_-]{16,64}", token):
#            return None
#        return self.store.one(
#            "SELECT t.*, p.name AS plan_name FROM transactions t"
#            " LEFT JOIN plans p ON p.id = t.plan_id"
#            " WHERE t.pay_token = ? AND t.kind = 'zibal'", (token,))
#
#    def do_pay_order(self, body):
#        """What the relay needs to send a customer to Zibal, or why not."""
#        t = self._order(body)
#        if not t:
#            return {"ok": False, "message": "این لینک پرداخت معتبر نیست"}
#        self._who = "user #%d" % t["user_id"]
#        if t["status"] == "approved":
#            return {"ok": False, "paid": True,
#                    "message": "این سفارش پرداخت شده و پلنش فعال است"}
#        born = parse_ts(t["created_at"])
#        expired = (not born or datetime.now(timezone.utc) - born
#                   > timedelta(hours=PAY_LINK_HOURS))
#        # Somebody already at the gateway when the link runs out is let back
#        # in: they may well have paid, and that has to be recorded.
#        if t["status"] != "started" or (
#                expired and not (body.get("returning") and t["authority"])):
#            return {"ok": False, "message": "این لینک پرداخت منقضی شده؛ از ربات "
#                                           "دوباره اقدام کنید"}
#        merchant = self.store.setting("zibal_merchant")
#        if not merchant:
#            return {"ok": False, "message": "پرداخت آنلاین الان فعال نیست"}
#        return {"ok": True, "amount": int(t["amount"]), "merchant": merchant,
#                "authority": t["authority"] or "",
#                "description": "Fasty DNS - %s" % (t["plan_name"] or "plan")}
#
#    def do_pay_started(self, body):
#        t = self._order(body)
#        authority = body.get("authority") or ""
#        if (not t or t["status"] != "started"
#                or not re.fullmatch(r"\d{4,20}", authority)):
#            return {"ok": False, "message": "این سفارش شروع نشد"}
#        self.store.run("UPDATE transactions SET authority = ?"
#                       " WHERE id = ? AND status = 'started'", (authority, t["id"]))
#        return {"ok": True}
#
#    def do_pay_verified(self, body):
#        """The relay has had Zibal confirm a payment, for the order's full
#        amount: settle it.
#
#        The track id must be the one recorded for this order when the customer
#        was sent to pay. Zibal verifies any payment made to this merchant, so
#        without that check one real payment could be presented again against a
#        second order.
#        """
#        t = self._order(body)
#        if not t:
#            return {"ok": False, "message": "این لینک پرداخت معتبر نیست"}
#        self._who = "user #%d" % t["user_id"]
#        if t["status"] == "approved":
#            return {"ok": True, "message": "پرداخت شما ثبت شده و پلن فعال است"}
#        given = body.get("authority") or ""
#        if (t["status"] != "started" or not t["authority"]
#                or not hmac.compare_digest(t["authority"], given)):
#            return {"ok": False, "message": "این پرداخت با سفارش جور نیست"}
#        ref = str(body.get("ref_id") or "")[:40]
#        card = str(body.get("card_pan") or "")[:32]
#        cur = self.store.run(
#            "UPDATE transactions SET status = 'approved', decided_at = ?,"
#            " ref_id = ?, note = ?, settled = 0"
#            " WHERE id = ? AND status = 'started'",
#            (now(), ref, ("zibal %s" % card).strip(), t["id"]))
#        if cur.rowcount == 1:
#            settle_transactions(self.store)
#            print("online payment: user %d, %d toman, ref %s"
#                  % (t["user_id"], t["amount"], ref), flush=True)
#            user = self.store.one("SELECT * FROM users WHERE id = ?", (t["user_id"],))
#            if user:
#                tell_admins(self.store,
#                            "💰 پرداخت آنلاین\nکاربر: %s\nپلن: %s\nمبلغ: %s\n"
#                            "کد پیگیری: %s" % (user_label(user), t["plan_name"] or "-",
#                                               toman(t["amount"]), ref or "-"))
#        return {"ok": True, "message": "پرداخت انجام شد و پلن شما فعال شد"}
#
#
#def serve_api(cfg, store):
#    API.store = store
#    API.secret = cfg["SYNC_SECRET"]
#    # Comma separated, so one exit can serve several relays.
#    API.relays = tuple(x.strip() for x in cfg["RELAY_IP"].split(",") if x.strip())
#    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
#    ctx.load_cert_chain(CERT, KEY)
#    make_api_server(ctx).serve_forever()
#
#
#def make_api_server(ctx, port=None):
#    return TLSServer(("0.0.0.0", API_PORT if port is None else port), API, ctx)
#
#
#def watch_self(store):
#    """Sample this machine's own health.
#
#    The relays report theirs on the sync request, but nothing syncs *to* the
#    exit, so without this the machine running the panel would be the one host
#    missing from the panel.
#    """
#    health = Health()
#    while True:
#        try:
#            store.record_metrics("exit", health.sample())
#            store.prune_metrics()
#        except Exception as e:
#            log(WARN, "self health failed: %r" % e)
#        time.sleep(30)
#
#
#CATALOGUE = []
## A one-element list so the API thread sees updates without a global statement.
#DEFAULT_TEMPLATE = [0]
#
#
#def main():
#    global CATALOGUE
#    cfg = load_config()
#    os.makedirs(os.path.dirname(DB), exist_ok=True)
#    store = Store(DB)
#    CATALOGUE = load_catalogue() + [CUSTOM_SERVICE]
#    DEFAULT_TEMPLATE[0] = store.ensure_default_template(CATALOGUE)["id"]
#    print("catalogue: %d services, default template #%d"
#          % (len(CATALOGUE), DEFAULT_TEMPLATE[0]), flush=True)
#
#    threading.Thread(target=watch_self, args=(store,), daemon=True).start()
#
#    def bye(*_):
#        sys.exit(0)
#
#    signal.signal(signal.SIGTERM, bye)
#    signal.signal(signal.SIGINT, bye)
#    print("panel up: api on :%d" % API_PORT, flush=True)
#    # In the foreground now. The Telegram loop used to be what kept this
#    # process alive and the API rode along on a daemon thread behind it; with
#    # the bot gone the API is the whole job, so it holds the process itself.
#    serve_api(cfg, store)
#
#
#if __name__ == "__main__":
#    main()
#__END_PANEL__

#__BEGIN_PANEL_SERVICE__
#[Unit]
#Description=Smart DNS panel - database and sync API for the relays
#After=network-online.target
#Wants=network-online.target
#
#[Service]
#Type=simple
## Only the relays reach port 8443, from the RELAY_IP this panel reads. The +
## runs it outside the sandbox below, which firewall rules need; the - lets the
## panel start even where there is no nft.
#ExecStartPre=-+/usr/local/bin/smartdns-api-guard
#ExecStart=/usr/local/bin/smartdns-panel
#Restart=always
#RestartSec=10
## Secrets live in panel.env, not in the unit and not in the script, because
## this repository is public. The Telegram bot's token is the exception: it is
## in the database, set from the admin panel, and read by smartdns-bot.
#EnvironmentFile=-/etc/smart-dns/panel.env
#NoNewPrivileges=yes
#ProtectSystem=strict
#ProtectHome=yes
#PrivateTmp=yes
#ReadWritePaths=/var/lib/smart-dns
#
#[Install]
#WantedBy=multi-user.target
#__END_PANEL_SERVICE__

#__BEGIN_SYNC__
##!/usr/bin/env python3
#"""smartdns-sync - the relay's half of the panel.
#
#Two jobs, one process:
#
#  * every 30 seconds, hand the exit node this relay's per-address byte
#    counters and take back who is allowed, on which resolver, at what speed
#  * serve the customer's panel - signing up, signing in, registering an
#    address, and seeing what is left of an allowance
#
#The panel has to live on the relay rather than on the exit, because the whole
#point of it is to learn the customer's address, and the only address that
#matters is the one they reach the service from. A page served in Frankfurt
#would see whatever their browser came out of.
#
#It listens outside the gated ports on purpose. The access control gate covers
#53, 80 and 443, so somebody whose address changed is cut off from the service
#but can still reach the one page that fixes it. Putting the panel on a gated
#port would have locked them out of the thing that unlocks them.
#
#The relay always dials out; nothing dials in. Standard library only.
#
#PANEL_HOST is not necessarily this relay's own exit node. The panel is a
#control plane: one database serves several relay/exit pairs, and each relay
#still carries its own traffic through its own exit.
#"""
#
#import base64
#import concurrent.futures
#import hashlib
#import hmac
#import html
#import http.client
#import http.cookies
#import http.server
#import ipaddress
#import json
#import os
#import re
#import socket
#import ssl
#import struct
#import subprocess
#import sys
#import threading
#import time
#import traceback
#import urllib.error
#import urllib.parse
#import urllib.request
#
#CONFIG = "/etc/smart-dns/sync.env"
#ACL = "/usr/local/bin/smartdns-acl"
#SHAPE = "/usr/local/bin/smartdns-shape"
#INTERVAL = 30
## The customer-facing panel, and the only port it is ever served on. Outside
## the gated ports (53, 80, 443) on purpose: somebody whose address changed is
## cut off from the service but must still be able to reach the one page that
## fixes it.
#PANEL_TLS_PORT = 8443
## Where the installer puts the panel's two faces.
#FONT_DIR = "/usr/local/share/smart-dns/fonts"
#
## A photograph of a bank slip, from a phone camera. The exit refuses anything
## past four megabytes, so there is no point carrying more than that up to it.
#MAX_RECEIPT = 4 * 1024 * 1024
#
## Zibal, called from here rather than from the exit: an Iranian gateway
## answers an Iranian server, and the customer's browser has to come back to one.
#ZIBAL = "https://gateway.zibal.ir"
#
#
#def load_config():
#    cfg = {}
#    with open(CONFIG) as fh:
#        for line in fh:
#            line = line.strip()
#            if not line or line.startswith("#") or "=" not in line:
#                continue
#            k, v = line.split("=", 1)
#            cfg[k.strip()] = v.strip().strip('"').strip("'")
#    for required in ("PANEL_HOST", "SYNC_SECRET", "SYNC_FINGERPRINT", "SELF_IP"):
#        if not cfg.get(required):
#            sys.exit("%s: %s is missing" % (CONFIG, required))
#    return cfg
#
#
#CFG = None
#
#
## ------------------------------------------------------------------ logging
## journald reads a leading <N> on a line as its syslog level. Warnings and
## errors carry one, so `journalctl -p warning` - which is what
## `smartdns-logs -e` runs - shows exactly the problems. Ordinary lines stay
## unmarked and land at info, as they always did. Before this everything
## landed at info, stderr included, and a failure looked like a heartbeat.
#INFO, WARN, ERROR = 6, 4, 3
## The visitor went away, or never finished saying hello. Not a fault here.
#GONE = (ConnectionError, TimeoutError, ssl.SSLError)
#
#
#def log(level, msg):
#    tag = "<%d>" % level if level < INFO else ""
#    for line in str(msg).splitlines() or [""]:
#        print(tag + line, flush=True)
#
#
#def log_exception(what):
#    """An error with its traceback, every line at error level. journald makes
#    each line its own entry, and at info all but the first would be lost
#    among the ordinary ones."""
#    log(ERROR, "%s\n%s" % (what, traceback.format_exc().rstrip()))
#
#
#def log_access(h, prefix, code, path, who=""):
#    """One line for one request: what was asked, the answer, how long it took
#    and who asked. Server errors at error level; everything else is info."""
#    try:
#        code = int(code)
#    except (TypeError, ValueError):
#        code = 0
#    ms = (time.monotonic() - getattr(h, "_t0", time.monotonic())) * 1000
#    # 501 is a scanner's GET to a POST-only port: the visitor's mistake.
#    log(ERROR if code >= 500 and code != 501 else INFO, "%s %s %s %d %dms from %s%s" % (
#        prefix, getattr(h, "command", None) or "-", path, code, ms,
#        h.client_address[0], " " + who if who else ""))
#
#
#def sync_sni():
#    """The name to put in the TLS handshake with the exit, which has none.
#
#    The relay dials the exit by address, and Python sends no name in TLS for
#    an address. Filtering between Iran and some exits resets exactly those
#    handshakes: measured from a live relay to a Hetzner exit, a handshake with
#    no name was reset every time, and one carrying any name at all - the
#    relay's own domain, sync.example.com, smartdns.invalid - got through every
#    time. From outside Iran both worked. Sync and the customer panel both went
#    down with "connection reset by peer" while the proxy on 443, which always
#    carries the customer's name, was fine.
#
#    The name decides nothing here: the exit's certificate is checked against
#    its fingerprint, not against a name. So it is the operator's own domain
#    when there is one, a harmless placeholder when there is not, and SYNC_SNI
#    in sync.env if a network ever needs something else.
#    """
#    return (CFG.get("SYNC_SNI") or CFG.get("PANEL_DOMAIN")
#            or "sync.example.com")
#
#
#class NamedHTTPS(http.client.HTTPSConnection):
#    """HTTPS to an address, with a name in the handshake anyway."""
#
#    def __init__(self, host, port, sni, **kw):
#        super().__init__(host, port, **kw)
#        self.sni = sni
#
#    def connect(self):
#        http.client.HTTPConnection.connect(self)       # the TCP part only
#        self.sock = self._context.wrap_socket(self.sock, server_hostname=self.sni)
#
#
#def post(path, payload):
#    """POST JSON to the exit's API, pinned to its certificate.
#
#    The exit's certificate is self-signed - there is no domain on it and no CA
#    to check it against - so ordinary verification is turned off and replaced
#    with a fingerprint comparison. That is stricter than a public CA would be,
#    not weaker: exactly one certificate is accepted, and the secret is never
#    sent until it matches.
#    """
#    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
#    ctx.check_hostname = False
#    ctx.verify_mode = ssl.CERT_NONE
#    conn = NamedHTTPS(CFG["PANEL_HOST"], 8443, sync_sni(), timeout=25, context=ctx)
#    try:
#        conn.connect()
#        seen = hashlib.sha256(conn.sock.getpeercert(binary_form=True)).hexdigest()
#        if not hmac.compare_digest(seen, CFG["SYNC_FINGERPRINT"].lower()):
#            raise RuntimeError(
#                "certificate fingerprint mismatch - refusing to send anything.\n"
#                "  expected %s\n  got      %s" % (CFG["SYNC_FINGERPRINT"], seen)
#            )
#        body = json.dumps(payload)
#        conn.request(
#            "POST", path, body,
#            {"Content-Type": "application/json",
#             "Authorization": "Bearer " + CFG["SYNC_SECRET"]},
#        )
#        res = conn.getresponse()
#        data = json.loads(res.read() or b"{}")
#        if res.status != 200:
#            raise RuntimeError("exit returned %d: %s" % (res.status, data))
#        return data
#    finally:
#        conn.close()
#
#
## ------------------------------------------------------------------ health
#class Health:
#    """Host metrics, read straight out of /proc.
#
#    CPU and network are rates, which means they only exist relative to a
#    previous reading - so the first sample after start reports no rate rather
#    than a meaningless one computed against zero. The sync loop runs every
#    thirty seconds, which is the interval these end up averaged over.
#    """
#
#    def __init__(self):
#        self.cpu = None
#        self.net = None
#
#    @staticmethod
#    def _meminfo():
#        out = {}
#        with open("/proc/meminfo") as fh:
#            for line in fh:
#                k, _, v = line.partition(":")
#                out[k] = int(v.split()[0]) * 1024      # kB -> bytes
#        return out
#
#    def _cpu_percent(self):
#        with open("/proc/stat") as fh:
#            parts = [int(x) for x in fh.readline().split()[1:]]
#        idle, total = parts[3] + parts[4], sum(parts)
#        prev, self.cpu = self.cpu, (idle, total)
#        if not prev:
#            return None
#        d_total = total - prev[1]
#        if d_total <= 0:
#            return None
#        return round(100.0 * (1 - (idle - prev[0]) / d_total), 1)
#
#    def _net_rates(self):
#        rx = tx = 0
#        with open("/proc/net/dev") as fh:
#            for line in fh.readlines()[2:]:
#                name, _, rest = line.partition(":")
#                if name.strip() == "lo":
#                    continue
#                f = rest.split()
#                rx += int(f[0]); tx += int(f[8])
#        now = time.time()
#        prev, self.net = self.net, (rx, tx, now)
#        if not prev:
#            return None, None
#        dt = now - prev[2]
#        if dt <= 0:
#            return None, None
#        return int((rx - prev[0]) / dt), int((tx - prev[1]) / dt)
#
#    def sample(self):
#        m = self._meminfo()
#        rx, tx = self._net_rates()
#        st = os.statvfs("/")
#        with open("/proc/uptime") as fh:
#            uptime = int(float(fh.readline().split()[0]))
#        with open("/proc/loadavg") as fh:
#            load = float(fh.readline().split()[0])
#        swap_total = m.get("SwapTotal", 0)
#        return {
#            "cpu": self._cpu_percent(),
#            "load": load,
#            "mem_total": m.get("MemTotal", 0),
#            # MemAvailable is what the kernel thinks is really obtainable, which
#            # is the number that matters; MemFree ignores reclaimable cache and
#            # makes a healthy box look nearly out of memory.
#            "mem_used": m.get("MemTotal", 0) - m.get("MemAvailable", 0),
#            # Reported as zero-total when the host has no swap, so the panel can
#            # leave the row out rather than drawing an empty gauge.
#            "swap_total": swap_total,
#            "swap_used": swap_total - m.get("SwapFree", 0) if swap_total else 0,
#            "disk_total": st.f_blocks * st.f_frsize,
#            "disk_used": (st.f_blocks - st.f_bfree) * st.f_frsize,
#            "rx_bps": rx,
#            "tx_bps": tx,
#            "uptime": uptime,
#        }
#
#
## ---------------------------------------------------------------- profiles
#PROFILE_DIR = "/etc/smartdns-profiles"
#PROFILE_BASE_PORT = 5300
#NAT_TABLE = "smartdns_nat"
#
#
#def sh(*args):
#    return subprocess.run(list(args), capture_output=True, text=True, timeout=60)
#
#
#def nft(*args):
#    return sh("/usr/sbin/nft", *args)
#
#
#CUSTOM_CONF = "/etc/dnsmasq.d/50-smartdns-custom.conf"
## The names the installer keeps out of the hijack: EA's game servers, the
## console STUN hosts, Epic's backend, core.windows.net. The main resolver
## reads this file and always will; the profiles must not, because whether
## each of those is routed is now a tick in a template, and a rule sitting in
## a shared file would outrank the tick.
#BYPASS_CONF = "/etc/dnsmasq.d/bypass.conf"
## The hijack list itself - every domain the service routes. The resolver on
## :53 reads it and always will: that one serves the default template, which
## means "everything". The profiles must not, because which of those names a
## template routes is a tick in the panel, and a rule in a file every resolver
## reads cannot be taken back by a rule in one that does not. Both would name
## the same host, dnsmasq's longest match would tie, and address= would win.
#HIJACK_CONF = "/etc/dnsmasq.d/smart-dns.conf"
## What the profile resolvers read instead of /etc/dnsmasq.d. Same files, minus
## the ones decided per template - a profile that does not route something must
## not find a rule for it at all.
#BASE_DIR = "/etc/smartdns-base"
## The main resolver's config directory. A name rather than a literal so a test
## can lay a relay out somewhere else.
#DNSMASQ_D = "/etc/dnsmasq.d"
#
#
#EPIC_PINS = "/etc/dnsmasq.d/epic-pins.conf"
#
## The templates' names, as the panel knows them. Only smartdns-rules reads this
## - the resolvers go by number - but "test" means something to an operator
## where "profile 2" does not.
#TEMPLATE_NAMES = "/var/lib/smart-dns/templates.json"
#
#
#def save_template_names(info):
#    """Keep the names the panel sent. Returns whether the file changed."""
#    if not isinstance(info, dict) or not isinstance(info.get("names"), dict):
#        return False      # an older panel, which does not send them
#    text = json.dumps({"default": info.get("default"), "names": info["names"]},
#                      ensure_ascii=False, sort_keys=True) + "\n"
#    try:
#        with open(TEMPLATE_NAMES, encoding="utf-8") as fh:
#            if fh.read() == text:
#                return False
#    except OSError:
#        pass
#    os.makedirs(os.path.dirname(TEMPLATE_NAMES), exist_ok=True)
#    tmp = TEMPLATE_NAMES + ".tmp"
#    with open(tmp, "w", encoding="utf-8") as fh:
#        fh.write(text)
#    os.replace(tmp, TEMPLATE_NAMES)
#    return True
#
#
## Who each allowed address belongs to, as the panel knows them. Only
## smartdns-watch reads it, to take a username where an address would do.
#USER_NAMES = "/var/lib/smart-dns/users.json"
#
#
#def save_user_names(allowed):
#    """Keep who each allowed address belongs to. Returns whether it changed.
#
#    Readable by root alone: it ties usernames to home addresses.
#    """
#    rows = {a["ip"]: {"label": a.get("name", ""), "user": a.get("user", "")}
#            for a in allowed or [] if isinstance(a, dict) and a.get("ip")}
#    text = json.dumps(rows, ensure_ascii=False, sort_keys=True) + "\n"
#    try:
#        with open(USER_NAMES, encoding="utf-8") as fh:
#            if fh.read() == text:
#                return False
#    except OSError:
#        pass
#    os.makedirs(os.path.dirname(USER_NAMES), exist_ok=True)
#    tmp = USER_NAMES + ".tmp"
#    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
#    with os.fdopen(fd, "w", encoding="utf-8") as fh:
#        fh.write(text)
#    os.replace(tmp, USER_NAMES)
#    return True
#
#
#def epic_pin_lines():
#    """epic-pin's rules, to be written into the profiles that still want them.
#
#    Read rather than symlinked, because they are the one thing a profile may
#    need to be without: they name exact hosts, so they outrank any rule that
#    routes the parent domain, and a template that has chosen to route Epic's
#    backend has to be able to actually do it.
#    """
#    try:
#        with open(EPIC_PINS) as fh:
#            return [l.rstrip("\n") for l in fh
#                    if l.startswith("address=") or l.startswith("server=")]
#    except OSError:
#        return []
#
#
#def sync_base_dir():
#    """Keep BASE_DIR mirroring /etc/dnsmasq.d, minus two files.
#
#    Symlinks rather than copies, so `smartdns add` still reaches every
#    resolver on the machine without knowing this directory exists. Three files
#    are left out - the operator's own domains, epic-pin's pins, and the
#    bypass list - because each is decided per template, and absence is the
#    only mechanism that works when the rules would otherwise name the same
#    host. The panel sends every bypass this profile needs, so nothing is lost
#    by not linking the file.
#    """
#    os.makedirs(BASE_DIR, exist_ok=True)
#    want = {f for f in os.listdir(DNSMASQ_D)
#            if f.endswith(".conf")
#            and f not in (os.path.basename(CUSTOM_CONF),
#                          os.path.basename(EPIC_PINS),
#                          os.path.basename(BYPASS_CONF),
#                          os.path.basename(HIJACK_CONF))}
#    have = set(os.listdir(BASE_DIR))
#    changed = False
#    for f in want - have:
#        os.symlink(os.path.join(DNSMASQ_D, f), os.path.join(BASE_DIR, f))
#        changed = True
#    for f in have - want:
#        os.unlink(os.path.join(BASE_DIR, f))
#        changed = True
#    return changed
#
#
#RULE_LINE = re.compile(r"^(address|server|local)=/(.+)/([^/]*)$")
#
#
#def base_settings():
#    """The main resolver's settings, less its rules, for the profiles to share.
#
#    They sit in the same file as the hijack list - the upstream servers,
#    no-resolv, the cache, the addresses to listen on - and that is a file the
#    profiles must not read. Leaving it out took the settings with it: a
#    template's resolver fell back to /etc/resolv.conf for its upstreams and to
#    dnsmasq's default cache of 150 names, over the slowest link there is. So
#    the settings are copied across and only the rules stay behind.
#    """
#    try:
#        with open(HIJACK_CONF) as fh:
#            lines = [l.strip() for l in fh]
#    except OSError:
#        return []
#    return [l for l in lines
#            if l and not l.startswith("#") and not RULE_LINE.match(l)]
#
#
#def rule_sets(text, me):
#    """What one resolver's config routes, bypasses and pins, as sets."""
#    out = {"routes": set(), "bypasses": set(), "pins": set()}
#    for line in (text or "").splitlines():
#        m = RULE_LINE.match(line.strip())
#        if not m:
#            continue
#        kind, domains, target = m.groups()
#        for d in filter(None, domains.split("/")):
#            if kind != "address":
#                out["bypasses"].add(d)
#            elif target == me:
#                out["routes"].add(d)
#            else:
#                # With its address, so a pin moving somewhere new shows up as
#                # the change it is rather than as nothing.
#                out["pins"].add("%s=%s" % (d, target))
#    return out
#
#
#def signed(names, sign, limit=15):
#    out = [sign + n for n in names[:limit]]
#    if len(names) > limit:
#        out.append("(%s%d more)" % (sign, len(names) - limit))
#    return out
#
#
#def describe_change(old_text, new_text, me):
#    """What changed between two versions of a resolver's rules, in one line:
#    each name that started or stopped being routed, bypassed or pinned.
#
#    This is the record of why a name went where it went. A count said that
#    something changed; it could not say that gemini.google.com stopped going
#    through the relay at 14:02, which is the question an operator is asking.
#    """
#    new = rule_sets(new_text, me)
#    if old_text is None:
#        return "routes %d, bypasses %d, pins %d" % (
#            len(new["routes"]), len(new["bypasses"]), len(new["pins"]))
#    old = rule_sets(old_text, me)
#    parts = []
#    for key in ("routes", "bypasses", "pins"):
#        plus, minus = sorted(new[key] - old[key]), sorted(old[key] - new[key])
#        if plus or minus:
#            parts.append("%s %s" % (key, " ".join(signed(plus, "+") + signed(minus, "-"))))
#    return "; ".join(parts) or "settings only"
#
#
#def template_label(key, names):
#    name = (names or {}).get(str(key))
#    return "template %s (%s)" % (key, name) if name else "template %s" % key
#
#
#def apply_custom_domains(domains):
#    """Route the domains the operator added in the panel.
#
#    Written into /etc/dnsmasq.d, which every resolver on this machine reads -
#    the main one and each profile - so one entry in the panel reaches every
#    plan. Returns whether anything changed, because dnsmasq cannot reload its
#    config: it has to be restarted, and restarting it on every sync would be a
#    DNS outage twice a minute.
#    """
#    self_ip = CFG.get("SELF_IP") or ""
#    body = ["# Domains added by the operator in the panel. Generated by",
#            "# smartdns-sync from the panel's database - edit it there, not here."]
#    body += ["address=/%s/%s" % (d, self_ip) for d in sorted(set(domains))]
#    text = "\n".join(body) + "\n"
#
#    current = None
#    if os.path.exists(CUSTOM_CONF):
#        with open(CUSTOM_CONF) as fh:
#            current = fh.read()
#    if current == text or (not domains and current is None):
#        return False
#
#    with open(CUSTOM_CONF, "w") as fh:
#        fh.write(text)
#    # Check before restarting. A bad line here takes DNS down for everyone on
#    # this relay, and dnsmasq refuses to start rather than skipping it.
#    if sh("/usr/sbin/dnsmasq", "--test", "-C", "/etc/dnsmasq.conf").returncode != 0:
#        if current is None:
#            os.unlink(CUSTOM_CONF)
#        else:
#            with open(CUSTOM_CONF, "w") as fh:
#                fh.write(current)
#        log(ERROR, "custom domains rejected by dnsmasq - reverted")
#        return False
#    sh("systemctl", "restart", "dnsmasq")
#    old, new = rule_sets(current, self_ip)["routes"], set(domains)
#    print("custom domains: %s (now %d)"
#          % (" ".join(signed(sorted(new - old), "+") + signed(sorted(old - new), "-"))
#             or "rewritten", len(new)), flush=True)
#    return True
#
#
#KNOWN_NAMES = {}
#
#
#def apply_profiles(profiles, assignment, restart=False, names=None):
#    """Give each template its own resolver, and point each address at one.
#
#    dnsmasq cannot answer differently per client, so the split is done with one
#    instance per profile on its own port plus an nftables redirect keyed on the
#    source address. Customers all use the same DNS address; the kernel decides
#    which instance actually answers them.
#
#    A profile whose template routes everything gets no instance: that is what
#    the main resolver on port 53 already does, and every address not named in a
#    redirect falls through to it.
#    """
#    # A name outlives its template in the log: one deleted in the panel is no
#    # longer in what the panel sends, but its retirement should still say which.
#    KNOWN_NAMES.update(names or {})
#    names = KNOWN_NAMES
#    os.makedirs(PROFILE_DIR, exist_ok=True)
#    if sync_base_dir():
#        restart = True
#    ports = {}
#    for i, key in enumerate(sorted(profiles)):
#        ports[key] = PROFILE_BASE_PORT + i
#
#    # Read once: every profile that wants them gets the same lines.
#    epic_pins = epic_pin_lines()
#    settings = base_settings()
#
#    wanted_units = set()
#    for key, spec in sorted(profiles.items()):
#        port = ports[key]
#        body = ["# generated by smartdns-sync - do not edit",
#                "port=%d" % port]
#        body += settings
#        # The operator's own domains, listed only for templates that route
#        # them. They cannot be un-routed by rule the way a service can: both
#        # rules would name the same host and dnsmasq prefers the address= one.
#        # So absence is the mechanism, which is why this resolver reads
#        # BASE_DIR rather than /etc/dnsmasq.d.
#        # What this template routes, written here rather than inherited.
#        # Everything not in this list simply has no rule in this resolver, so
#        # it resolves normally and the client goes straight to it - which is
#        # what an un-ticked service is supposed to mean.
#        me = CFG.get("SELF_IP") or ""
#        body += ["address=/%s/%s" % (d, me)
#                 for d in sorted(set(spec.get("routed") or []))]
#        body += ["address=/%s/%s" % (d, me)
#                 for d in sorted(set(spec.get("custom") or []))]
#        # Names whose parent this profile routes, that it must not route
#        # itself - gosredirector.ea.com under a routed ea.com, say. Here the
#        # subtraction does work: the profile's rule names a longer host than
#        # the one hijacking the parent, so longest match prefers it.
#        body += ["server=/%s/1.1.1.1" % d for d in spec.get("bypass", [])]
#        # Epic's pins, unless this template asked to route that backend. They
#        # come last and are address= rules, so where they appear they win -
#        # which is the point: a bypass sends the name to a public resolver,
#        # while a pin sends it to an address checked to answer from here.
#        if spec.get("pins", True):
#            body += epic_pins
#        conf = os.path.join(PROFILE_DIR, "%s.conf" % key)
#        text = "\n".join(body) + "\n"
#        old = None
#        if os.path.exists(conf):
#            with open(conf) as fh:
#                old = fh.read()
#        changed = old != text
#        if changed:
#            with open(conf, "w") as fh:
#                fh.write(text)
#        unit = "smartdns-dns@%s" % key
#        wanted_units.add(unit)
#        active = sh("systemctl", "is-active", unit).stdout.strip() == "active"
#        # `restart` is set when the shared /etc/dnsmasq.d changed underneath
#        # us: these instances read it too, and dnsmasq only picks up config at
#        # startup, so without this a new domain would reach the default plan
#        # and silently miss everybody on a template.
#        if changed or not active or restart:
#            sh("systemctl", "restart", unit)
#            why = (describe_change(old, text, me) if changed
#                   else "was not running" if not active
#                   else "shared config changed")
#            print("%s on port %d restarted - %s"
#                  % (template_label(key, names), port, why), flush=True)
#
#    # Stop resolvers for profiles nobody is on any more, and delete their
#    # config, so a template an admin removed does not linger as a process.
#    running = sh("systemctl", "list-units", "--no-legend", "--plain",
#                 "smartdns-dns@*.service").stdout
#    for line in running.splitlines():
#        unit = line.split()[0].replace(".service", "") if line.split() else ""
#        if unit and unit not in wanted_units:
#            sh("systemctl", "stop", unit)
#            key = unit.split("@", 1)[1]
#            try:
#                os.remove(os.path.join(PROFILE_DIR, "%s.conf" % key))
#            except OSError:
#                pass
#            print("%s retired - nobody is on it" % template_label(key, names),
#                  flush=True)
#
#    apply_redirects(ports, assignment, names)
#
#
## Who was on which template at the last sync, so a move is logged once rather
## than every thirty seconds. None until the first pass has looked.
#LAST_ASSIGNMENT = None
#
#
#def apply_redirects(ports, assignment, names=None):
#    """Point each address at its profile's resolver, with one nftables set per
#    profile and a redirect rule per set."""
#    global LAST_ASSIGNMENT
#    if nft("list", "table", "ip", NAT_TABLE).returncode != 0:
#        nft("add", "table", "ip", NAT_TABLE)
#    nft("add", "chain", "ip", NAT_TABLE, "pre",
#        "{ type nat hook prerouting priority dstnat ; policy accept ; }")
#    # Rebuilt from scratch each time rather than diffed: the whole chain is a
#    # handful of rules, and a rule left behind here would send a customer to
#    # the wrong resolver silently.
#    nft("flush", "chain", "ip", NAT_TABLE, "pre")
#
#    for key, port in sorted(ports.items()):
#        setname = "prof_%s" % key
#        nft("add", "set", "ip", NAT_TABLE, setname, "{ type ipv4_addr ; }")
#        nft("flush", "set", "ip", NAT_TABLE, setname)
#        members = [ip for ip, prof in assignment.items() if prof == key]
#        if members:
#            nft("add", "element", "ip", NAT_TABLE, setname,
#                "{ %s }" % ", ".join(members))
#            nft("add", "rule", "ip", NAT_TABLE, "pre",
#                "ip saddr @%s udp dport 53 redirect to :%d" % (setname, port))
#            nft("add", "rule", "ip", NAT_TABLE, "pre",
#                "ip saddr @%s tcp dport 53 redirect to :%d" % (setname, port))
#
#    # Sets no rule points at any more - a template that lost its last customer.
#    # Harmless left behind, but misleading: they go on listing addresses that
#    # the default resolver is really answering.
#    # The whole table, not `list sets ip <table>`: nft takes only a family
#    # there, refuses the table name, and the cleanup silently did nothing.
#    listed = nft("list", "table", "ip", NAT_TABLE)
#    for setname in re.findall(r"set (prof_\S+) \{", listed.stdout or ""):
#        if setname[len("prof_"):] not in ports:
#            nft("delete", "set", "ip", NAT_TABLE, setname)
#
#    now = {ip: prof for ip, prof in assignment.items() if prof in ports}
#    if LAST_ASSIGNMENT is not None:
#        for ip in sorted(set(now) | set(LAST_ASSIGNMENT)):
#            was, got = LAST_ASSIGNMENT.get(ip), now.get(ip)
#            if was == got:
#                continue
#            if got:
#                print("%s now on %s" % (ip, template_label(got, names)), flush=True)
#            else:
#                print("%s left %s" % (ip, template_label(was, names)), flush=True)
#    LAST_ASSIGNMENT = now
#
#
#def acl(*args):
#    return subprocess.run(
#        [ACL] + list(args), capture_output=True, text=True, timeout=30
#    )
#
#
#def current_state():
#    out = acl("list", "--json")
#    if out.returncode != 0:
#        raise RuntimeError("smartdns-acl list failed: %s" % out.stderr.strip())
#    return json.loads(out.stdout or "[]")
#
#
#HEALTH = Health()
#
## What the shaper was last told. Speeds change about as often as somebody buys
## a plan, and re-running tc every thirty seconds for no reason would be thirty
## subprocesses a minute to arrive at the state already in the kernel.
#SHAPED = None
#
#
#def apply_speeds(allowed):
#    """Hand the wanted speed limits to smartdns-shape, when they have changed.
#
#    A customer with no limit is left out entirely rather than sent as zero, so
#    the shaper's job is exactly "these are the limited ones" and an account
#    going back to unlimited removes its class rather than setting it huge.
#    """
#    global SHAPED
#    wanted = sorted(
#        ({"ip": a["ip"], "mark": int(a["uid"]), "kbps": int(a.get("kbps") or 0)}
#         for a in allowed if a.get("uid") and int(a.get("kbps") or 0) > 0),
#        key=lambda w: w["mark"])
#    if wanted == SHAPED:
#        return
#    if not os.path.exists(SHAPE):
#        # An older relay that has not been upgraded yet. Say so once rather
#        # than every half minute, and carry on - unshaped is the old
#        # behaviour, not a broken one.
#        if SHAPED is None:
#            log(WARN, "%s is missing - speed limits will not be applied" % SHAPE)
#        SHAPED = wanted
#        return
#    r = subprocess.run([SHAPE, "apply"], input=json.dumps(wanted),
#                       capture_output=True, text=True, timeout=60)
#    if r.returncode != 0:
#        # Leave SHAPED alone so the next pass tries again.
#        log(ERROR, "shaping failed: %s" % r.stderr.strip())
#        return
#    if r.stdout.strip():
#        print(r.stdout.strip(), flush=True)
#    SHAPED = wanted
#
#
#AUTO_ENFORCE = "/etc/smart-dns/auto-enforce"
#
#
#def close_relay_when_ready(allowed_count):
#    """Switch access control on once there is somebody to allow.
#
#    The installer cannot make this call itself: a relay is installed before it
#    has a single registered address, and enforcing against an empty allowlist
#    cuts off everyone including the operator. So the installer leaves a note
#    saying what it wants, and this closes the door at the first sync that
#    brings an address.
#
#    Runs once. `smartdns-acl enforce off` deletes the note, so an operator who
#    deliberately opens the relay does not find it shut again thirty seconds
#    later.
#    """
#    if allowed_count <= 0 or not os.path.exists(AUTO_ENFORCE):
#        return
#    state = subprocess.run([ACL, "enforce", "status"], capture_output=True,
#                           text=True, timeout=30)
#    if "enforcing" in (state.stdout or ""):
#        os.unlink(AUTO_ENFORCE)      # already closed; nothing left to do
#        return
#    r = subprocess.run([ACL, "enforce", "on", "--yes"], capture_output=True,
#                       text=True, timeout=30)
#    if r.returncode != 0:
#        # Most likely the allowlist is still empty in the kernel because this
#        # is the pass that is about to fill it. Leave the note and try again
#        # on the next sync rather than reporting a problem that is not one.
#        return
#    os.unlink(AUTO_ENFORCE)
#    print("access control on: %d address(es) may use this relay"
#          % allowed_count, flush=True)
#
#
## ---------------------------------------------------------------- game pings
## How the games' servers answer from this relay, for the Telegram bot to show:
## a TCP connection to each game's domains, timed. TCP rather than ICMP, because
## many game servers ignore ping, and a connection is what a game makes anyway.
##
## Names are asked of public resolvers directly, never of this machine's own
## dnsmasq: that answers every routed name with this relay's address, and a
## ping to ourselves says nothing. The exit says which domains, on every sync.
#PING_EVERY = 300
#PING_TRIES = 3
#PING_TIMEOUT = 2.0
#PING_PORTS = (443, 80)
#PING_RESOLVERS = ("1.1.1.1", "8.8.8.8")
#DNS_PORT = 53
## The address Iran's filtering hands out for a name it blocks. Such a name is
## reported as filtered and never connected to.
#FILTERED_PREFIX = "10.10.34."
#PING_TARGETS = {}       # what to ping, from the exit
#PINGS = {}              # the last round, until the next sync takes it
#PING_LOCK = threading.Lock()
#
#
#def _skip_name(data, pos):
#    while pos < len(data):
#        n = data[pos]
#        if n == 0:
#            return pos + 1
#        if n & 0xC0 == 0xC0:
#            return pos + 2
#        pos += n + 1
#    return pos
#
#
#def _first_a(data, qid):
#    """The first A record in a DNS answer, or None."""
#    if len(data) < 12:
#        return None
#    rid, flags, qd, an = struct.unpack(">HHHH", data[:8])
#    if rid != qid or flags & 0x000F:
#        return None
#    pos = 12
#    for _ in range(qd):
#        pos = _skip_name(data, pos) + 4
#    for _ in range(an):
#        pos = _skip_name(data, pos)
#        if pos + 10 > len(data):
#            return None
#        rtype, _cls, _ttl, rdlen = struct.unpack(">HHIH", data[pos:pos + 10])
#        pos += 10
#        if rtype == 1 and rdlen == 4:
#            return socket.inet_ntoa(data[pos:pos + 4])
#        pos += rdlen
#    return None
#
#
#def resolve_a(name):
#    """(IPv4 address, "ok" | "filtered") for a name, or (None, "no-dns")."""
#    try:
#        qname = b"".join(bytes([len(p)]) + p.encode("ascii")
#                         for p in name.rstrip(".").split(".")) + b"\x00"
#    except (UnicodeEncodeError, ValueError):
#        return None, "no-dns"
#    for server in PING_RESOLVERS:
#        qid = int.from_bytes(os.urandom(2), "big")
#        packet = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0) + qname + struct.pack(">HH", 1, 1)
#        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
#        sock.settimeout(PING_TIMEOUT)
#        try:
#            sock.sendto(packet, (server, DNS_PORT))
#            data, _ = sock.recvfrom(4096)
#        except OSError:
#            continue
#        finally:
#            sock.close()
#        ip = _first_a(data, qid)
#        if ip:
#            return ip, ("filtered" if ip.startswith(FILTERED_PREFIX) else "ok")
#    return None, "no-dns"
#
#
#def time_host(ip):
#    """(median milliseconds, loss 0-1) for TCP connections to ip, on the first
#    port in PING_PORTS that answers at all; (None, 1.0) if none does."""
#    for port in PING_PORTS:
#        times = []
#        for _ in range(PING_TRIES):
#            t0 = time.monotonic()
#            try:
#                socket.create_connection((ip, port), timeout=PING_TIMEOUT).close()
#                times.append((time.monotonic() - t0) * 1000)
#            except OSError:
#                pass
#        if times:
#            times.sort()
#            return round(times[len(times) // 2], 1), round(1 - len(times) / float(PING_TRIES), 2)
#    return None, 1.0
#
#
#def ping_round(targets):
#    """Ping every target host, in parallel: {service: {"label", "hosts": [...]}}."""
#    jobs = [(key, info.get("label") or key, host)
#            for key, info in targets.items() if isinstance(info, dict)
#            for host in (info.get("hosts") or [])[:8] if isinstance(host, str)]
#
#    def one(job):
#        key, label, host = job
#        ip, state = resolve_a(host)
#        if not ip or state == "filtered":
#            return key, label, {"host": host, "ip": ip or "", "ms": None,
#                                "loss": 1.0, "state": state}
#        ms, loss = time_host(ip)
#        return key, label, {"host": host, "ip": ip, "ms": ms, "loss": loss,
#                            "state": "ok" if ms is not None else "no-answer"}
#
#    out = {}
#    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
#        for key, label, res in pool.map(one, jobs):
#            out.setdefault(key, {"label": label, "hosts": []})["hosts"].append(res)
#    return out
#
#
#def note_ping_targets(targets):
#    if isinstance(targets, dict):
#        with PING_LOCK:
#            PING_TARGETS.clear()
#            PING_TARGETS.update({k: v for k, v in targets.items() if isinstance(v, dict)})
#
#
#def take_pings():
#    """The last round, once: a round is reported on the sync after it ends,
#    not on every sync, so the exit writes it down every five minutes rather
#    than every thirty seconds."""
#    with PING_LOCK:
#        out = dict(PINGS)
#        PINGS.clear()
#    return out
#
#
#def ping_loop():
#    while True:
#        with PING_LOCK:
#            targets = dict(PING_TARGETS)
#            exits = dict(EXIT_TARGETS)
#            ready = SYNCED[0]
#        if not ready:
#            time.sleep(10)          # the first sync has not said what yet
#            continue
#        try:
#            result = ping_round(targets) if targets else {}
#            with PING_LOCK:
#                PINGS.clear()
#                PINGS.update(result)
#        except Exception as e:
#            log(WARN, "game pings failed: %s" % e)
#        try:
#            measured = ping_exits(exits)
#            with PING_LOCK:
#                EXIT_PINGS.clear()
#                EXIT_PINGS.update(measured)
#        except Exception as e:
#            log(WARN, "exit pings failed: %s" % e)
#        time.sleep(PING_EVERY)
#
#
## ------------------------------------------------------------------ exits
## Several exits: the one this relay was installed with - "0" everywhere, the
## default, and the backup for every other - and any extra ones the panel lists,
## servers abroad that carry traffic and nothing else. nginx sends each
## customer's connections to their exit by a map on their address, kept in a
## file of its own so that rewriting it never touches nginx.conf.
#EXITS_CONF = "/etc/nginx/smartdns-exits.conf"
## An extra exit may be reached through a tunnel of its own, which this relay
## dials. One BackPack client per exit, its config beside the main tunnel's and
## its ports on loopback, where nginx sends that exit's customers.
#BACKPACK_BIN = "/usr/local/lib/smart-dns/backpack"
#TUNNEL_DIR = "/etc/smart-dns/tunnel"
#EXIT_TUNNEL_TRANSPORTS = ("stealth", "wss", "tcp", "ws")
## 18500 up, in pairs: the installer keeps this range off every other list, and
## the main tunnel's own ports (18443, 18080) are outside it.
#EXIT_TUNNEL_BASE = 18500
#EXIT_TUNNEL_SLOTS = 50
#EXIT_TARGETS = {}       # id -> {"name", "ip"}: the extra exits, from the panel
#EXIT_PINGS = {}         # the last round's exit pings, until the next sync
#SYNCED = [False]        # whether the panel has answered once, since start
#
#
#def clean_exits(exits):
#    """The panel's list of extra exits, keeping only what nginx and BackPack
#    can be given: a real address, and a tunnel only if all of it is there."""
#    out = {}
#    if not isinstance(exits, dict):
#        return out
#    for eid, e in exits.items():
#        if not (isinstance(eid, str) and eid.isdigit() and eid != "0" and isinstance(e, dict)):
#            continue
#        try:
#            if not ipaddress.IPv4Address(e.get("ip")).is_global:
#                continue
#        except (ValueError, TypeError):
#            continue
#        kept = {"name": str(e.get("name") or eid)[:40], "ip": str(e["ip"])}
#        t = e.get("tunnel")
#        if isinstance(t, dict):
#            transport, port, token = t.get("transport"), t.get("port"), t.get("token")
#            if (transport in EXIT_TUNNEL_TRANSPORTS and isinstance(port, int)
#                    and 1 <= port <= 65535
#                    and isinstance(token, str) and re.fullmatch(r"[0-9a-f]{16,64}", token)):
#                kept["tunnel"] = {"transport": transport, "port": port, "token": token}
#        out[eid] = kept
#    return out
#
#
#def note_exit_targets(exits):
#    clean = clean_exits(exits)
#    with PING_LOCK:
#        EXIT_TARGETS.clear()
#        EXIT_TARGETS.update(clean)
#        SYNCED[0] = True
#    return clean
#
#
#def take_exit_pings():
#    with PING_LOCK:
#        out = dict(EXIT_PINGS)
#        EXIT_PINGS.clear()
#    return out
#
#
#def ping_exits(exits):
#    """Time a connection from here to every exit: {id: {"ms", "loss"}}.
#
#    The leg this relay adds to every customer connection, so it is the number
#    that decides which exit is fastest. An exit's nginx lets this relay in and
#    nobody else, so the handshake answers."""
#    jobs = {}
#    if (CFG or {}).get("EXIT_IP"):
#        jobs["0"] = CFG["EXIT_IP"]
#    jobs.update({eid: e["ip"] for eid, e in exits.items()})
#    out = {}
#    if not jobs:
#        return out
#    keys = list(jobs)
#    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
#        for eid, (ms, loss) in zip(keys, pool.map(time_host, [jobs[k] for k in keys])):
#            out[eid] = {"ms": ms, "loss": loss}
#    return out
#
#
#def exit_tunnel_ports(exits):
#    """Which loopback ports each tunnelled exit is reached on.
#
#    Handed out by position rather than by id, so they stay inside the range
#    the installer keeps free. The configs and the nginx map are written from
#    this same map in one pass, so a port that moves moves in both.
#    """
#    ports = {}
#    for i, eid in enumerate(sorted([e for e in exits if exits[e].get("tunnel")], key=int)):
#        if i >= EXIT_TUNNEL_SLOTS:
#            log(WARN, "exits: no tunnel port left for exit %s - it is reached directly" % eid)
#            break
#        ports[eid] = (EXIT_TUNNEL_BASE + i * 2, EXIT_TUNNEL_BASE + i * 2 + 1)
#    return ports
#
#
#def exit_tunnel_toml(exit_, ports):
#    """BackPack's config for this relay's end: it dials the exit and offers the
#    two ports nginx sends that exit's customers to."""
#    t = exit_["tunnel"]
#    return ("# written by smartdns-sync - the relay's end of %s's tunnel\n"
#            "[direct]\nrole = \"iran\"\naddr = \"%s:%d\"\n"
#            "ports = [\"127.0.0.1:%d=443\", \"127.0.0.1:%d=80\"]\n"
#            "transport = \"%s\"\ntoken = \"%s\"\n"
#            % (exit_["name"], exit_["ip"], t["port"], ports[0], ports[1],
#               t["transport"], t["token"]))
#
#
#def apply_exit_tunnels(exits):
#    """One BackPack client per tunnelled exit: {exit id: (https, http)} for the
#    ones actually running, so the nginx map can point at them.
#
#    Nothing is downloaded here. BackPack arrives with the installer, and a
#    relay that has never been given a tunnel does not have it - such an exit is
#    reached directly and the operator is told what to run."""
#    want = exit_tunnel_ports(exits)
#    if want and not os.path.exists(BACKPACK_BIN):
#        log(WARN, "exits: %d exit(s) ask for a tunnel but BackPack is not on this relay - "
#                  "they are reached directly. Run the installer here with --tunnel to fetch it."
#            % len(want))
#        want = {}
#    os.makedirs(TUNNEL_DIR, exist_ok=True)
#    running = {}
#    for eid, ports in sorted(want.items(), key=lambda kv: int(kv[0])):
#        conf = os.path.join(TUNNEL_DIR, "exit-%s.toml" % eid)
#        text = exit_tunnel_toml(exits[eid], ports)
#        try:
#            with open(conf) as fh:
#                have = fh.read()
#        except OSError:
#            have = None
#        if have != text:
#            with open(conf + ".tmp", "w") as fh:
#                fh.write(text)
#            os.chmod(conf + ".tmp", 0o600)
#            os.replace(conf + ".tmp", conf)
#        unit = "smartdns-tunnel@exit-%s.service" % eid
#        active = sh("systemctl", "is-active", "--quiet", unit).returncode == 0
#        if have != text or not active:
#            sh("systemctl", "enable", unit)
#            sh("systemctl", "restart", unit)
#            log(INFO, "exits: tunnel to %s (%s, port %d) on 127.0.0.1:%d"
#                % (exits[eid]["name"], exits[eid]["tunnel"]["transport"],
#                   exits[eid]["tunnel"]["port"], ports[0]))
#        running[eid] = ports
#    # Exits that lost their tunnel, or went away entirely.
#    for name in sorted(os.listdir(TUNNEL_DIR)):
#        if not (name.startswith("exit-") and name.endswith(".toml")):
#            continue
#        eid = name[len("exit-"):-len(".toml")]
#        if eid in running:
#            continue
#        sh("systemctl", "disable", "--now", "smartdns-tunnel@exit-%s.service" % eid)
#        os.remove(os.path.join(TUNNEL_DIR, name))
#        log(INFO, "exits: tunnel to exit %s stopped" % eid)
#    return running
#
#
#def default_exit():
#    """(https, http) targets for everybody not on an extra exit: the tunnel's
#    upstreams when there is one - they fall back to the exit by themselves -
#    and the exit's own address when there is not."""
#    if (CFG or {}).get("TUNNEL") == "backpack":
#        return "to_exit_https", "to_exit_http"
#    ip = (CFG or {}).get("EXIT_IP", "")
#    return "%s:443" % ip, "%s:80" % ip
#
#
#def exits_conf(exits, assignment, tunnels=None):
#    """The nginx include: a map per protocol, and an upstream per extra exit.
#
#    A tunnelled exit is reached at its end of the tunnel on loopback, and falls
#    back to the same exit without the tunnel before it falls back to this
#    relay's own exit - a customer keeps the exit they chose for as long as it
#    answers at all."""
#    https, http = default_exit()
#    main = (CFG or {}).get("EXIT_IP", "")
#    lines = ["# written by smartdns-sync whenever it changes - edits here are lost", ""]
#    for proto, default in (("https", https), ("http", http)):
#        lines.append("map $remote_addr $smartdns_exit_%s {" % proto)
#        lines.append("    default %s;" % default)
#        for ip, eid in sorted(assignment.items()):
#            if eid in exits:
#                lines.append("    %s exit_%s_%s;" % (ip, eid, proto))
#        lines.append("}")
#    tunnels = tunnels or {}
#    for eid in sorted(exits, key=int):
#        for i, (proto, port) in enumerate((("https", 443), ("http", 80))):
#            lines.append("upstream exit_%s_%s {" % (eid, proto))
#            if eid in tunnels:
#                lines.append("    server 127.0.0.1:%d;" % tunnels[eid][i])
#                lines.append("    server %s:%d backup;" % (exits[eid]["ip"], port))
#            else:
#                lines.append("    server %s:%d;" % (exits[eid]["ip"], port))
#            if main and main != exits[eid]["ip"]:
#                lines.append("    server %s:%d backup;" % (main, port))
#            lines.append("}")
#    return "\n".join(lines) + "\n"
#
#
#def _write_exits(text):
#    tmp = EXITS_CONF + ".tmp"
#    with open(tmp, "w") as fh:
#        fh.write(text)
#    os.replace(tmp, EXITS_CONF)
#
#
#def apply_exits(exits, assignment, tunnels=None):
#    """Point each address at its exit: rewrite the map and reload nginx - only
#    when it has changed, and only if nginx accepts it."""
#    if not (CFG or {}).get("EXIT_IP"):
#        # Installed by a version from before several exits; the next run of
#        # the installer on this relay records its exit, and this starts then.
#        return False
#    chosen = {}
#    for ip, eid in assignment.items():
#        try:
#            ipaddress.IPv4Address(ip)
#        except (ValueError, TypeError):
#            continue
#        if eid in exits:
#            chosen[ip] = eid
#    want = exits_conf(exits, chosen, tunnels)
#    try:
#        with open(EXITS_CONF) as fh:
#            have = fh.read()
#    except OSError:
#        have = None
#    if want == have:
#        return False
#    _write_exits(want)
#    test = sh("nginx", "-t")
#    if test.returncode != 0:
#        if have is not None:
#            _write_exits(have)
#        log(ERROR, "exits: nginx refused the new map, so the old one stays:\n%s"
#            % (test.stderr or "").strip()[-400:])
#        return False
#    r = sh("systemctl", "reload", "nginx")
#    if r.returncode != 0:
#        log(ERROR, "exits: nginx did not reload: %s" % (r.stderr or "").strip()[-200:])
#        return False
#    log(INFO, "exits: %d extra, %d addresses on one of them" % (len(exits), len(chosen)))
#    return True
#
#
#def sync_once():
#    rows = current_state()
#    counters = {r["ip"]: r["total"] for r in rows}
#    # Metrics ride along on a request that was happening anyway - no second
#    # connection, no second schedule, and they arrive stamped with the same
#    # moment as the usage they sit beside.
#    try:
#        host = HEALTH.sample()
#    except Exception as e:
#        host = {"error": str(e)}
#    report = {"counters": counters, "host": host,
#              # Where the bot on the exit should send customers: the mini app
#              # and the payment page are served by this panel, and the DNS
#              # address they type in is this machine's.
#              "dns": CFG.get("SELF_IP", "")}
#    if CFG.get("PANEL_DOMAIN"):
#        report["panel"] = "https://%s:%d" % (CFG["PANEL_DOMAIN"], PANEL_TLS_PORT)
#    pings = take_pings()
#    if pings:
#        report["pings"] = pings
#    exit_pings = take_exit_pings()
#    if exit_pings:
#        report["exit_pings"] = exit_pings
#    answer = post("/sync", report)
#    note_ping_targets(answer.get("ping_targets"))
#    exits = note_exit_targets(answer.get("exits"))
#    try:
#        save_template_names(answer.get("templates"))
#    except Exception as e:
#        log(WARN, "template names not saved: %s" % e)
#    try:
#        save_user_names(answer.get("allowed"))
#    except Exception as e:
#        log(WARN, "user names not saved: %s" % e)
#
#    names = {a["ip"]: a.get("name", "") for a in answer.get("allowed", [])}
#    want = set(names)
#    have = {r["ip"] for r in rows}
#
#    # Which resolver each address should be answered by. Applied before the
#    # allowlist below, so an address is pointed at the right resolver no later
#    # than the moment it is let in.
#    try:
#        changed = apply_custom_domains(answer.get("extra_domains") or [])
#        assignment = {a["ip"]: a.get("profile", "")
#                      for a in answer.get("allowed", []) if a.get("profile")}
#        apply_profiles(answer.get("profiles") or {}, assignment, restart=changed,
#                       names=(answer.get("templates") or {}).get("names"))
#    except Exception as e:
#        log_exception("profiles failed: %s" % e)
#
#    try:
#        apply_speeds(answer.get("allowed") or [])
#    except Exception as e:
#        log_exception("speeds failed: %s" % e)
#
#    # Which exit each address leaves by - before the allowlist, as the
#    # resolvers and speeds are, so a new address is pointed at its exit no
#    # later than the moment it is let in.
#    try:
#        tunnels = apply_exit_tunnels(exits)
#        apply_exits(exits, {a["ip"]: str(a.get("exit") or "")
#                            for a in answer.get("allowed") or [] if a.get("ip")}, tunnels)
#    except Exception as e:
#        log_exception("exits failed: %s" % e)
#
#    for ip in sorted(want - have):
#        r = acl("add", ip, names[ip]) if names[ip] else acl("add", ip)
#        log(INFO if r.returncode == 0 else ERROR, "added %s%s" % (
#            ip, "" if r.returncode == 0 else " FAILED: " + r.stderr.strip()))
#    for ip in sorted(have - want):
#        r = acl("del", ip)
#        log(INFO if r.returncode == 0 else ERROR, "removed %s%s" % (
#            ip, "" if r.returncode == 0 else " FAILED: " + r.stderr.strip()))
#
#    # After the set is filled, not before: enforcing while the kernel list is
#    # still empty is refused, and would leave the relay open for another cycle.
#    close_relay_when_ready(len(want))
#    return len(want), len(want - have), len(have - want)
#
#
#def sync_loop():
#    fails = 0
#    while True:
#        try:
#            total, added, removed = sync_once()
#            if added or removed:
#                print("sync: %d allowed (+%d -%d)" % (total, added, removed), flush=True)
#            fails = 0
#        except Exception as e:
#            fails += 1
#            # Noisy for the first few, then quiet: if the exit is down for an
#            # hour the journal should not be mostly this message. The allowlist
#            # already in the kernel keeps working throughout - a sync outage
#            # must never cut off paying users.
#            if fails <= 3 or fails % 20 == 0:
#                # A warning while it could be a blip on the link; an error
#                # once it has gone on long enough to be an outage.
#                log(WARN if fails < 3 else ERROR, "sync failed (%d): %s" % (fails, e))
#        time.sleep(INTERVAL)
#
#
## ------------------------------------------------------------- user panel
#USER_CSS = """
#/* Fasty DNS brand system: void #07080A, signal #C7F000, 1px lines, no radius.
#   The two faces are served by this panel itself - Google Fonts is blocked in
#   Iran, and a page that cannot fetch its font draws in whatever is to hand.
#   Persian text falls through to the device's own face; the Latin and every
#   numeral are the brand's. */
#@font-face{font-family:'Space Grotesk';src:url(/f/space.woff2) format('woff2');
# font-weight:300 700;font-style:normal;font-display:swap}
#@font-face{font-family:'JetBrains Mono';src:url(/f/mono.woff2) format('woff2');
# font-weight:400 800;font-style:normal;font-display:swap}
#:root{--void:#07080A;--surface:#0D0F12;--raised:#14171C;--line:#23272E;
# --line2:#35404A;--dim:#646B76;--muted:#9AA1AC;--text:#EDEFF2;--signal:#C7F000;
# --pressed:#8BA800;--wash:#1F2610;--warn:#FFB020;--warn-wash:#2A2110;
# --fail:#FF4D3D;--fail-wash:#2A1414}
#*{box-sizing:border-box}
#body{margin:0;background:var(--void);color:var(--text);
# font:16px/1.6 'Space Grotesk',Vazirmatn,Tahoma,system-ui,sans-serif;
# display:flex;align-items:center;justify-content:center;min-height:100vh;padding:20px}
#.shell{width:100%;max-width:460px}
#.card{background:var(--surface);border:1px solid var(--line);padding:24px}
#h1{font-size:24px;margin:0 0 4px;font-weight:600;letter-spacing:-.02em}
#.sub{color:var(--muted);font-size:14px;margin-bottom:20px}
#.row{display:flex;justify-content:space-between;align-items:baseline;gap:12px;
# padding:12px 0;border-bottom:1px solid var(--line)}
#.row:last-of-type{border-bottom:0}
#.k{color:var(--dim);font-size:11px;font-family:'JetBrains Mono',ui-monospace,monospace;
# letter-spacing:.16em;text-transform:uppercase}
#.v{font-weight:500}
#code,.num{font-family:'JetBrains Mono',ui-monospace,monospace;font-size:15px;
# color:var(--text);direction:ltr;unicode-bidi:isolate}
#code{background:var(--void);border:1px solid var(--line);padding:2px 8px;font-size:14px}
#.bar{height:6px;background:var(--void);border:1px solid var(--line);margin-top:10px}
#.bar i{display:block;height:100%;background:var(--signal)}
#.bar i.warn{background:var(--warn)}
#.bar i.hot{background:var(--fail)}
#button,a.btn{display:block;width:100%;margin-top:16px;padding:13px 20px;min-height:44px;
# font:inherit;font-weight:600;font-size:15px;text-align:center;text-decoration:none;
# background:var(--signal);color:var(--void);border:0;cursor:pointer;
# transition:background .12s ease-out,border-color .12s ease-out,color .12s ease-out}
#button:hover,a.btn:hover{background:#D9FF3A}
#button:active,a.btn:active{background:var(--pressed)}
#button.ghost,a.btn.ghost{background:transparent;border:1px solid var(--line2);
# color:var(--text);font-weight:500}
#button.ghost:hover,a.btn.ghost:hover{background:transparent;border-color:var(--signal);
# color:var(--signal)}
#label{display:block;color:var(--muted);font-size:13px;margin:14px 0 6px}
#input{width:100%;padding:13px 14px;background:var(--void);color:var(--text);
# border:1px solid var(--line);font:15px/1.4 'JetBrains Mono',ui-monospace,monospace}
#input:focus{outline:0;border-color:var(--signal)}
#.alt{text-align:center;margin-top:18px;font-size:14px;color:var(--muted)}
#.alt a{color:var(--signal);text-decoration:none}
#.big{font-family:'JetBrains Mono',ui-monospace,monospace;font-size:30px;font-weight:500;
# letter-spacing:-.03em;text-align:center;background:var(--void);
# border:1px solid var(--line);padding:18px;color:var(--signal);margin:6px 0 4px;
# direction:ltr;unicode-bidi:isolate}
#.note{color:var(--dim);font-size:13px;line-height:1.7;margin-top:16px}
#.msg{padding:11px 14px;margin-bottom:16px;font-size:14px;border:1px solid var(--line)}
#.msg.good{background:var(--wash);border-color:var(--signal)}
#.msg.err{background:var(--fail-wash);border-color:var(--fail)}
#.msg.warnbox{background:var(--warn-wash);border-color:var(--warn)}
#.icon{font-size:38px;text-align:center;line-height:1;margin-bottom:12px}
#.dns{margin-top:20px;padding:16px;background:var(--void);border:1px solid var(--line)}
#.dns .k{margin-bottom:8px;display:block}
#.dns .big{margin:0}
#.dns .note{margin-top:12px}
#.dns input[type=file]{width:100%;padding:10px;font-size:12px;
# border:1px dashed var(--line2);background:transparent;margin-bottom:4px}
#details.pw{margin-top:16px;border:1px solid var(--line);background:var(--void)}
#details.pw>summary{padding:14px 16px;cursor:pointer;color:var(--muted);font-size:14px;
# list-style:none}
#details.pw>summary::-webkit-details-marker{display:none}
#details.pw>summary::before{content:'▸';margin-left:8px;font-size:11px;color:var(--dim)}
#details.pw[open]>summary::before{content:'▾'}
#details.pw form{padding:0 16px 4px}
#details.pw .note{padding:0 16px 14px;margin-top:8px}
#.ok{color:var(--signal)}.bad{color:var(--fail)}.warn{color:var(--warn)}
#.brand{display:flex;align-items:center;justify-content:center;gap:10px;
# margin:0 0 18px;direction:ltr}
#.brand svg{display:block}
#.brand .name{font-size:22px;font-weight:700;letter-spacing:-.025em;color:var(--text)}
#.brand .dns{font-family:'JetBrains Mono',ui-monospace,monospace;font-size:13px;
# font-weight:500;letter-spacing:.22em;color:var(--muted);margin:0;padding:0;
# background:none;border:0}
#footer{text-align:center;color:var(--dim);font-size:11px;padding:16px 0 0;direction:ltr;
# font-family:'JetBrains Mono',ui-monospace,monospace;letter-spacing:.16em;
# text-transform:uppercase}
#.manual input{text-align:center}
#"""
#
## Where the installer writes the version it installed. Read per page rather
## than once, so it can never disagree with what is on disk.
#VERSION_FILE = "/var/lib/smart-dns/version"
#
#
#def app_version():
#    try:
#        with open(VERSION_FILE) as fh:
#            return fh.read().strip()[:20]
#    except OSError:
#        return ""
#
#
## The mark, drawn rather than fetched: a rounded square in signal with two
## chevrons cut out of it. 44x44 is the brand's own grid.
#MARK = ("<svg viewBox='0 0 44 44' width='%d' height='%d' aria-hidden='true'>"
#        "<rect width='44' height='44' rx='11' fill='#C7F000'/>"
#        "<path d='M12 14 L20 22 L12 30' stroke='#07080A' stroke-width='3.4'"
#        " stroke-linecap='square' fill='none'/>"
#        "<path d='M23 14 L31 22 L23 30' stroke='#07080A' stroke-width='3.4'"
#        " stroke-linecap='square' fill='none'/></svg>")
#FAVICON = ("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 44 44'"
#           "%3E%3Crect width='44' height='44' rx='11' fill='%23C7F000'/%3E%3Cpath d='M12 14"
#           " L20 22 L12 30' stroke='%2307080A' stroke-width='3.4' fill='none'/%3E%3Cpath"
#           " d='M23 14 L31 22 L23 30' stroke='%2307080A' stroke-width='3.4' fill='none'/%3E%3C/svg%3E")
#
#
#def brand_html():
#    return ("<div class='brand'>%s<span class='name'>Fasty</span>"
#            "<span class='dns'>DNS</span></div>" % (MARK % (28, 28)))
#
#
#def footer_html():
#    v = app_version()
#    return "<footer>FASTY DNS%s</footer>" % (" · v" + html.escape(v) if v else "")
#
#
#def brand():
#    """What to call the service on the customer's pages."""
#    return "Fasty DNS"
#
#
#def user_page(inner):
#    return ("""<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
#<meta name="viewport" content="width=device-width,initial-scale=1">
#<title>%s</title><link rel="icon" href="%s"><style>%s</style></head><body>
#<div class="shell">%s<div class="card">%s</div>%s</div></body></html>"""
#            % (html.escape(brand()), FAVICON, USER_CSS, brand_html(), inner,
#               footer_html()))
#
#
## A Persian keyboard types these, and the address box should not care.
#DIGITS = str.maketrans("۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩٫", "01234567890123456789.")
#
#
#def typed_ip(text):
#    """An address the customer typed by hand: (address, "") or ("", why).
#
#    The exit refuses one that belongs to another account, so what is left for
#    here is everything that could never be somebody's internet connection - a
#    private or reserved address, or one of this service's own two machines.
#    """
#    text = (text or "").translate(DIGITS).strip()
#    try:
#        addr = ipaddress.IPv4Address(text)
#    except ValueError:
#        return "", "این آی‌پی درست نیست — چهار عدد با نقطه، مثل 5.123.45.67"
#    if not addr.is_global or addr.is_multicast:
#        return "", ("این آی‌پی عمومی نیست. آی‌پی اینترنت خود را بنویسید، "
#                    "نه آی‌پی داخل شبکهٔ خانه (مثل 192.168...)")
#    if str(addr) in ((CFG or {}).get("SELF_IP"), (CFG or {}).get("PANEL_HOST")):
#        return "", "این آی‌پی مال سرورهای خود سرویس است"
#    return str(addr), ""
#
#
#def landing(banner=""):
#    return (banner +
#            "<div class='icon'>🌐</div><h1>%s</h1>"
#            "<p class='sub'>برای دیدن حساب و ثبت آی‌پی وارد شوید.</p>"
#            "<a class='btn' href='/login'>ورود</a>"
#            "<a class='btn ghost' href='/signup'>ثبت‌نام</a>"
#            "<p class='note'>از همان اینترنتی وارد شوید که می‌خواهید سرویس "
#            "روی آن کار کند — آی‌پی همان اتصال ثبت می‌شود.</p>"
#            % html.escape(brand()))
#
#
#def signup_form(banner=""):
#    return (banner +
#            "<h1>ثبت‌نام</h1><p class='sub'>%s</p>"
#            "<form method='post' action='/signup'>"
#            "<label>نام</label>"
#            "<input name='name' maxlength='60' autocomplete='name'>"
#            "<label>نام کاربری</label>"
#            "<input name='username' required minlength='3' maxlength='32' "
#            "pattern='[A-Za-z0-9._-]{3,32}' placeholder='ali_reza' "
#            "autocapitalize='none' spellcheck='false' "
#            "autocomplete='username'>"
#            "<label>رمز عبور (دست‌کم ۸ نویسه)</label>"
#            "<input name='password' type='password' required minlength='8' "
#            "autocomplete='new-password'>"
#            "<label>تکرار رمز عبور</label>"
#            "<input name='password2' type='password' required minlength='8' "
#            "autocomplete='new-password'>"
#            "<button>ساخت حساب</button></form>"
#            "<p class='note'>نام کاربری همان چیزی است که با آن وارد می‌شوید — "
#            "حروف انگلیسی، عدد، و . _ - ؛ بزرگ و کوچک فرقی ندارد. اگر قبلاً "
#            "کسی گرفته باشدش، پیغام می‌دهد.</p>"
#            "<p class='alt'>حساب دارید؟ <a href='/login'>وارد شوید</a></p>"
#            % html.escape(brand()))
#
#
#def login_form(banner=""):
#    return (banner +
#            "<h1>ورود</h1><p class='sub'>%s</p>"
#            "<form method='post' action='/login'>"
#            "<label>نام کاربری</label>"
#            "<input name='username' required maxlength='32' "
#            "autocapitalize='none' spellcheck='false' "
#            "autocomplete='username'>"
#            "<label>رمز عبور</label>"
#            "<input name='password' type='password' required "
#            "autocomplete='current-password'>"
#            "<button>ورود</button></form>"
#            "<p class='alt'>حساب ندارید؟ <a href='/signup'>ثبت‌نام کنید</a></p>"
#            % html.escape(brand()))
#
#
#def register_ip_page(ip, banner=""):
#    """The step between signing up and having a working service.
#
#    It shows the address rather than registering it quietly, because this is
#    the one thing on the whole panel the customer has to get right: the address
#    seen here is the address that will work, and if they opened the page over
#    mobile data or a VPN it is the wrong one. Naming it gives them the chance
#    to notice.
#    """
#    return (banner +
#            "<div class='icon'>📍</div><h1>ثبت آی‌پی</h1>"
#            "<p class='sub'>سرویس روی همین آی‌پی باز می‌شود.</p>"
#            "<div class='big'>%s</div>"
#            "<form method='post' action='/register-ip'>"
#            "<button>همین آی‌پی را ثبت کن</button></form>"
#            "<p class='note'>اگر این آی‌پی اینترنت خانه یا موبایل شما "
#            "<b>نیست</b> — مثلاً وی‌پی‌ان روشن است یا از اینترنت دیگری وارد "
#            "شده‌اید — آن را ببندید، همین صفحه را تازه کنید و بعد ثبت کنید.</p>"
#            "<p class='note'>آی‌پی خانگی معمولاً ثابت نیست. اگر مودم را ریست "
#            "کردید و سرویس قطع شد، دوباره به همین صفحه بیایید و ثبت کنید.</p>"
#            % html.escape(ip)
#            + manual_ip_box() +
#            "<p class='alt'><a href='/'>فعلاً نه، برو به حساب</a></p>")
#
#
#def manual_ip_box(back=""):
#    """The box for typing an address by hand, here and on the account page.
#
#    Somebody on mobile data who wants the service at home would otherwise have
#    to go home before they could register it. `back` is where a refusal sends
#    them, so they land on the page they typed it on.
#    """
#    hidden = ("<input type='hidden' name='back' value='%s'>" % html.escape(back)
#              if back else "")
#    return ("<div class='dns manual'><div class='k'>ثبت دستی آی‌پی</div>"
#            "<p class='note' style='margin-top:0'>سرویس را برای اینترنت دیگری "
#            "می‌خواهید؟ مثلاً الان با موبایل آمده‌اید ولی سرویس را برای اینترنت "
#            "خانه لازم دارید. آی‌پی آن اینترنت را اینجا بنویسید؛ از صفحهٔ مودم "
#            "یا یک سایت «آی‌پی من چیست» روی همان اینترنت پیدایش می‌کنید.</p>"
#            "<form method='post' action='/register-ip'>%s"
#            "<input name='ip' required maxlength='40' inputmode='decimal' "
#            "placeholder='5.123.45.67' autocomplete='off' spellcheck='false'>"
#            "<button class='ghost'>ثبت این آی‌پی</button></form></div>" % hidden)
#
#
#def account_notice(info):
#    """The warning the bot used to send, on the page instead.
#
#    A message reached only the accounts that had a Telegram behind them, which
#    by the end was a minority. This reaches everybody, and it is on the screen
#    they open when something has stopped working - which is when they look.
#
#    Only the worst applicable one is shown. Three stacked warnings about the
#    same allowance is noise, and the reader stops reading.
#    """
#    status = info.get("status")
#    # First thing a new customer sees, so it says what to do rather than what
#    # is wrong. Nothing is wrong: they have an account, and it is waiting.
#    if status == "pending":
#        return ("<div class='msg warnbox'><b>حساب شما ساخته شد.</b> "
#                "برای فعال شدن سرویس، رسید پرداختتان را از پایین همین صفحه "
#                "بفرستید — بعد از تأیید، پلن برایتان ثبت می‌شود.</div>")
#    if status == "expired":
#        return ("<div class='msg err'><b>دورهٔ شما تمام شد.</b> "
#                "سرویس تا تمدید کار نمی‌کند.</div>")
#    if status == "over_quota":
#        return ("<div class='msg err'><b>سهمیهٔ شما تمام شد.</b> "
#                "سرویس تا شارژ مجدد قطع است.</div>")
#    if status != "active":
#        return "<div class='msg err'>حساب شما غیرفعال است.</div>"
#
#    quota, used = info.get("quota") or 0, info.get("used") or 0
#    if quota:
#        left = max(0, quota - used)
#        # The same thresholds the panel records, read back rather than
#        # recomputed, so the page and the database never disagree about
#        # whether somebody has been warned.
#        if info.get("warned", 0) & 2:
#            return ("<div class='msg err'>بیش از ۹۵٪ سهمیه‌تان مصرف شده — "
#                    "%s مانده.</div>" % human_fa(left))
#        if info.get("warned", 0) & 1:
#            return ("<div class='msg warnbox'>بیش از ۸۰٪ سهمیه‌تان مصرف شده — "
#                    "%s مانده.</div>" % human_fa(left))
#
#    ends = info.get("expires")
#    if ends:
#        return ("<div class='msg warnbox'>دورهٔ شما در <b>%s</b> "
#                "تمام می‌شود.</div>" % html.escape(ends))
#    return ""
#
#
#def dns_box():
#    """The address the customer has to type into their console or router.
#
#    Served by the relay, so it is this machine's own address - not something
#    configured twice and able to disagree. A customer on a second relay is
#    looking at that relay's page and gets that relay's address, which is the
#    one that will work for them.
#
#    Only the first is given. Consoles ask for two, and the honest answer is to
#    repeat this one: a second, different resolver would answer the sanctioned
#    names truthfully and the service would fail intermittently in a way nobody
#    could diagnose.
#    """
#    ip = (CFG or {}).get("SELF_IP", "")
#    if not ip:
#        return ""
#    return ("<div class='dns'><div class='k'>آدرس DNS</div>"
#            "<div class='big'>%s</div>"
#            "<p class='note'>این را در تنظیمات شبکهٔ کنسول، گوشی یا مودم "
#            "به‌عنوان <b>DNS اول</b> بگذارید. اگر DNS دوم هم می‌خواهد، "
#            "<b>همین آدرس</b> را دوباره بنویسید — آدرس دیگری آنجا باعث می‌شود "
#            "سرویس گاهی کار کند و گاهی نه.</p></div>" % html.escape(ip))
#
#
#def human_fa(n):
#    n = float(n or 0)
#    for unit in ("بایت", "کیلوبایت", "مگابایت", "گیگابایت", "ترابایت"):
#        if n < 1024 or unit == "ترابایت":
#            return ("%d %s" if unit == "بایت" else "%.2f %s") % (n, unit)
#        n /= 1024
#
#
## ------------------------------------------------ telegram mini app, payment
## The two pages the Telegram bot links customers to. They are served here, not
## on the exit, because each needs what only this machine has: the customer's
## real address for the mini app, and an Iranian server for Zibal.
#
## Telegram hands a mini app its signed launch data in the URL's fragment. Its
## own script reads it from there too, but that script lives on telegram.org,
## which is filtered in Iran - so this reads the fragment itself, and uses the
## script's copy only if some client happens to have loaded it.
#TG_JS = r"""
#(function () {
#  var raw = "";
#  try { raw = (window.Telegram && Telegram.WebApp && Telegram.WebApp.initData) || ""; }
#  catch (e) {}
#  if (!raw) {
#    var parts = location.hash.replace(/^#/, "").split("&");
#    for (var i = 0; i < parts.length; i++) {
#      if (parts[i].indexOf("tgWebAppData=") === 0) {
#        try { raw = decodeURIComponent(parts[i].slice(13)); } catch (e) {}
#      }
#    }
#  }
#  if (raw) {
#    document.getElementById("d").value = raw;
#    document.getElementById("b").disabled = false;
#    document.getElementById("n").style.display = "none";
#  }
#})();
#"""
#
#
#def tg_page(ip):
#    """The mini app: the address this page was opened from, and one button."""
#    return ("<div class='icon'>🌐</div><h1>ثبت آی‌پی</h1>"
#            "<p class='sub'>آی‌پی اینترنتی که الان با آن وصل هستید:</p>"
#            "<div class='dns'><div class='big'>%s</div></div>"
#            "<div class='msg warnbox'>قبل از ثبت، <b>فیلترشکن (VPN) را خاموش "
#            "کنید</b> و با همان اینترنتی وصل باشید که سرویس باید رویش کار کند "
#            "(وای‌فای خانه یا اینترنت گوشی). اگر آی‌پی بالا مال فیلترشکن است، "
#            "صفحه را ببندید، فیلترشکن را خاموش کنید و دوباره باز کنید.</div>"
#            "<form method='post' action='/tg/claim'>"
#            "<input type='hidden' name='init_data' id='d'>"
#            "<button id='b' disabled>ثبت همین آی‌پی</button></form>"
#            "<p class='note' id='n'>اگر دکمه فعال نشد، این صفحه را از داخل ربات، "
#            "با دکمهٔ «ثبت خودکار آی‌پی»، باز کنید.</p>"
#            "<script>%s</script>" % (html.escape(ip), TG_JS))
#
#
#def pay_page(ok, message, ref=""):
#    """The end of a mini app or payment round: what happened, and back to the bot."""
#    return ("<div class='icon'>%s</div><h1>%s</h1>%s"
#            "<p class='sub'>می‌توانید این صفحه را ببندید و به ربات برگردید.</p>"
#            % ("✅" if ok else "⚠️", html.escape(message or "خطا"),
#               ("<div class='dns'><div class='k'>کد پیگیری</div>"
#                "<div class='big'>%s</div></div>" % html.escape(str(ref))) if ref else ""))
#
#
#def zibal(action, payload):
#    """Call Zibal's v1 payment API - "request" or "verify" - and return its answer.
#
#    A refusal comes back with an HTTP error as often as with a result code, so
#    the body is read either way; an answer that is not JSON is an empty one.
#    Zibal counts in rial, which is its callers' business, not this function's.
#    """
#    req = urllib.request.Request(
#        "%s/v1/%s" % (ZIBAL, action), data=json.dumps(payload).encode(),
#        headers={"Content-Type": "application/json", "Accept": "application/json"})
#    try:
#        with urllib.request.urlopen(req, timeout=20) as res:
#            raw = res.read()
#    except urllib.error.HTTPError as e:
#        raw = e.read()
#    try:
#        answer = json.loads(raw or b"{}")
#    except ValueError:
#        answer = {}
#    return answer if isinstance(answer, dict) else {}
#
#
#class UserPanel(http.server.BaseHTTPRequestHandler):
#    """The page a customer sees.
#
#    It keeps no state of its own. The cookie is handed to the panel on the exit
#    node, which says who it belongs to - so a relay rebuilt from scratch does
#    not log anybody out, and a second relay serves the same session without the
#    two needing to share anything.
#    """
#
#    server_version = "smartdns"
#    protocol_version = "HTTP/1.1"
#
#    def log_message(self, fmt, *args):
#        # http.server's own notes - a malformed request, a timeout. The access
#        # line is log_request below.
#        log(INFO, "panel %s from %s" % (fmt % args, self.client_address[0]))
#
#    def parse_request(self):
#        self._t0 = time.monotonic()
#        return super().parse_request()
#
#    def log_request(self, code="-", size="-"):
#        # The path only. The query carries nothing but the message shown after
#        # a form, or a payment's references on the way back, and the cookie -
#        # the session - is never written anywhere. A payment link's token is
#        # masked as well: it is what opens that order.
#        path = urllib.parse.urlparse(getattr(self, "path", "") or "").path[:120]
#        if path.startswith("/pay/") and path.rstrip("/") != "/pay/back":
#            path = "/pay/…"
#        log_access(self, "panel", code, path)
#
#    def client_ip(self):
#        # The socket, never a header. Trusting X-Forwarded-For here would let
#        # anyone register any address by sending one.
#        return self.client_address[0]
#
#    def send_font(self, name):
#        """One of the two faces the pages are drawn in.
#
#        Served from here because Google Fonts is blocked in Iran. Cached for a
#        year: the files only change when the installer replaces them, and then
#        under the same names, which costs a customer one stale-looking page at
#        worst.
#        """
#        if name not in ("space.woff2", "mono.woff2"):
#            return self.send_html("<h1>404</h1>", 404)
#        try:
#            with open(os.path.join(FONT_DIR, name), "rb") as fh:
#                blob = fh.read()
#        except OSError:
#            return self.send_html("<h1>404</h1>", 404)
#        return self.send(blob, 200, {"Content-Type": "font/woff2",
#                                     "Cache-Control": "public, max-age=31536000, immutable"})
#
#    def send_html(self, body, code=200, headers=None, frame=False):
#        blob = user_page(body).encode("utf-8")
#        # See send(): a clean buffer, so a failed attempt cannot leave half a
#        # status line in front of this one.
#        self._headers_buffer = []
#        self.send_response(code)
#        self.send_header("Content-Type", "text/html; charset=utf-8")
#        self.send_header("Content-Length", str(len(blob)))
#        self.send_header("Cache-Control", "no-store")
#        if frame:
#            # The mini app. Telegram's web client shows it inside a frame of
#            # its own; every other page here refuses to be framed at all.
#            self.send_header("Content-Security-Policy",
#                             "frame-ancestors https://web.telegram.org"
#                             " https://*.telegram.org")
#        else:
#            self.send_header("X-Frame-Options", "DENY")
#        self.send_header("X-Content-Type-Options", "nosniff")
#        for k, v in (headers or {}).items():
#            self.send_header(k, v)
#        self.end_headers()
#        self.wfile.write(blob)
#
#    def session(self):
#        cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
#        return cookie["sdu"].value if "sdu" in cookie else ""
#
#    def upload(self, field):
#        """Pull one file out of a multipart body: (bytes, content type).
#
#        Hand-written because cgi was removed in Python 3.13 and this installer
#        has no pip step. One field is all that is needed, so this only has to
#        find its part and hand back what sits between the blank line and the
#        next boundary.
#        """
#        ctype = self.headers.get("Content-Type") or ""
#        if "boundary=" not in ctype:
#            raise ValueError("فایلی فرستاده نشد")
#        boundary = ctype.split("boundary=", 1)[1].strip().strip('"')
#        want = ('name="%s"' % field).encode("latin-1")
#        for part in getattr(self, "raw_body", b"").split(b"--" + boundary.encode("latin-1")):
#            head, blank, data = part.partition(b"\r\n\r\n")
#            if not blank or want not in head:
#                continue
#            kind = ""
#            for line in head.split(b"\r\n"):
#                if line.lower().startswith(b"content-type:"):
#                    kind = line.split(b":", 1)[1].decode("latin-1").strip()
#            # The trailing CRLF belongs to the delimiter, not the file.
#            return (data[:-2] if data.endswith(b"\r\n") else data), kind
#        raise ValueError("فایلی انتخاب نشده بود")
#
#    def form(self):
#        """Read the POST body. Bounded, because this is a public port in Iran
#        and nothing stops somebody announcing a gigabyte.
#
#        A receipt arrives as multipart and is kept as raw bytes for upload()
#        to pick apart; everything else is a small urlencoded form.
#        """
#        try:
#            length = int(self.headers.get("Content-Length") or 0)
#        except ValueError:
#            return {}
#        if length <= 0:
#            return {}
#        if "multipart/form-data" in (self.headers.get("Content-Type") or ""):
#            if length > MAX_RECEIPT + 64 * 1024:      # the file plus its wrapper
#                self.raw_body = b""
#                return {"too_big": "1"}
#            self.raw_body = self.rfile.read(length)
#            return {}
#        if length > 8192:
#            return {}
#        raw = self.rfile.read(length).decode("utf-8", "replace")
#        return {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}
#
#    def cookie_for(self, session):
#        return ("sdu=%s; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=%d"
#                % (session, 30 * 86400))
#
#    def redirect(self, where, message="", bad=False):
#        if message:
#            where += ("&" if "?" in where else "?") + "m=" + \
#                urllib.parse.quote(message) + ("&e=1" if bad else "")
#        return self.send("", 303, {"Location": where})
#
#    def banner(self):
#        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
#        msg = (q.get("m") or [""])[0]
#        if not msg:
#            return ""
#        return "<div class='msg %s'>%s</div>" % (
#            "err" if q.get("e") else "good", html.escape(msg[:200]))
#
#    # -- the bot's mini app and online payment ----------------------------
#    def tg_claim(self):
#        form = self.form()
#        try:
#            res = post("/tg-claim", {"init_data": form.get("init_data", ""),
#                                     "ip": self.client_ip()})
#        except Exception as e:
#            log(ERROR, "panel: tg-claim failed: %s" % e)
#            res = {"ok": False, "message": "الان نشد، چند دقیقه دیگر"}
#        return self.send_html(pay_page(res.get("ok"), res.get("message")), frame=True)
#
#    def pay_start(self, token):
#        """Open a Zibal payment for an order the bot created, and go there."""
#        try:
#            order = post("/pay-order", {"token": token})
#        except Exception as e:
#            log(ERROR, "panel: pay-order failed: %s" % e)
#            return self.send_html(pay_page(False, "الان نشد، چند دقیقه دیگر"), 502)
#        if not order.get("ok"):
#            return self.send_html(pay_page(bool(order.get("paid")), order.get("message")))
#        back = "https://%s:%d/pay/back?t=%s" % (
#            CFG["PANEL_DOMAIN"], PANEL_TLS_PORT, urllib.parse.quote(token))
#        try:
#            # In rial: Zibal's unit. The service's prices are in toman.
#            res = zibal("request", {
#                "merchant": order["merchant"], "amount": int(order["amount"]) * 10,
#                "callbackUrl": back, "orderId": token,
#                "description": order.get("description") or "Fasty DNS"})
#        except Exception as e:
#            log(ERROR, "panel: zibal unreachable: %s" % e)
#            return self.send_html(pay_page(
#                False, "درگاه پرداخت در دسترس نیست؛ کمی بعد دوباره امتحان کنید"), 502)
#        track = str(res.get("trackId") or "")
#        if res.get("result") != 100 or not re.fullmatch(r"\d{4,20}", track):
#            log(WARN, "panel: zibal refused a payment request: %s %s"
#                % (res.get("result"), str(res.get("message") or "")[:160]))
#            return self.send_html(pay_page(False, "درگاه پرداخت درخواست را نپذیرفت"), 502)
#        try:
#            post("/pay-started", {"token": token, "authority": track})
#        except Exception as e:
#            log(ERROR, "panel: pay-started failed: %s" % e)
#            return self.send_html(pay_page(False, "الان نشد، چند دقیقه دیگر"), 502)
#        return self.send("", 303, {"Location": "%s/start/%s" % (ZIBAL, track)})
#
#    def pay_back(self):
#        """Where Zibal sends the customer back.
#
#        Nothing in the query is believed except which order and which payment
#        it names: the payment is confirmed with Zibal itself, and its amount
#        checked against the order's, before the exit hears of it. Opening this
#        page again is safe - Zibal answers 201 for a payment already verified,
#        and the exit records an order once.
#        """
#        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
#        token = (q.get("t") or [""])[0]
#        track = (q.get("trackId") or [""])[0]
#        if (q.get("success") or [""])[0] != "1":
#            return self.send_html(pay_page(
#                False, "پرداخت انجام نشد یا لغو شد. اگر خواستید، دوباره از ربات اقدام کنید."))
#        try:
#            order = post("/pay-order", {"token": token, "returning": True})
#        except Exception as e:
#            log(ERROR, "panel: pay-order failed: %s" % e)
#            return self.send_html(pay_page(
#                False, "الان نشد. همین صفحه را چند دقیقه بعد دوباره باز کنید."), 502)
#        if not order.get("ok"):
#            return self.send_html(pay_page(bool(order.get("paid")), order.get("message")))
#        if not re.fullmatch(r"\d{4,20}", track) or not hmac.compare_digest(
#                order.get("authority") or "", track):
#            return self.send_html(pay_page(False, "این پرداخت با سفارش جور نیست"))
#        try:
#            res = zibal("verify", {"merchant": order["merchant"], "trackId": int(track)})
#        except Exception as e:
#            log(ERROR, "panel: zibal verify unreachable: %s" % e)
#            return self.send_html(pay_page(
#                False, "تأیید پرداخت الان نشد. همین صفحه را چند دقیقه بعد دوباره باز کنید."), 502)
#        result = res.get("result")
#        paid = (result == 100 and res.get("status", 1) == 1) or result == 201
#        if not paid:
#            log(WARN, "panel: zibal did not verify a payment: %s %s"
#                % (result, str(res.get("message") or "")[:160]))
#            return self.send_html(pay_page(
#                False, "پرداخت تأیید نشد. اگر مبلغی از حسابتان کم شده، درگاه آن را برمی‌گرداند."))
#        # Zibal's verify takes no amount, so this is the one place a payment of
#        # less than the order would show: the amount it reports, in rial,
#        # against the order's price in toman.
#        expected = int(order["amount"]) * 10
#        try:
#            amount = int(res["amount"]) if res.get("amount") is not None else expected
#        except (TypeError, ValueError):
#            amount = -1
#        if amount != expected:
#            log(ERROR, "panel: zibal payment %s is for %s rial, the order is %d - not recorded"
#                % (track, res.get("amount"), expected))
#            return self.send_html(pay_page(
#                False, "مبلغ پرداخت‌شده با سفارش جور نیست؛ با پشتیبانی تماس بگیرید."))
#        ref = str(res.get("refNumber") or "")
#        try:
#            done = post("/pay-verified", {"token": token, "authority": track, "ref_id": ref,
#                                          "card_pan": str(res.get("cardNumber") or "")})
#        except Exception as e:
#            # Paid and confirmed, not yet recorded. Opening this page again
#            # verifies once more - Zibal answers 201 - and records it then.
#            log(ERROR, "panel: pay-verified failed for a confirmed payment (ref %s): %s"
#                % (ref, e))
#            return self.send_html(pay_page(
#                False, "پرداخت انجام شد ولی ثبتش الان نشد. همین صفحه را چند دقیقه بعد "
#                       "دوباره باز کنید.", ref), 502)
#        return self.send_html(pay_page(done.get("ok"), done.get("message"), ref))
#
#    def do_GET(self):
#        path = urllib.parse.urlparse(self.path).path.rstrip("/") or "/"
#
#        if path in ("/signup", "/login"):
#            # Whether a cookie is here decides only whether to offer a way back
#            # to the account, never whether to show the form. Bouncing on the
#            # cookie's mere existence trapped anyone holding an expired one:
#            # they were sent to a page that said their session had ended, on
#            # their way to the page that would have given them a new one.
#            back = ("<p class='alt'><a href='/'>برگشت به حساب</a></p>"
#                    if self.session() else "")
#            return self.send_html(
#                (signup_form(self.banner()) if path == "/signup"
#                 else login_form(self.banner())) + back)
#
#        if path == "/register-ip":
#            if not self.session():
#                return self.redirect("/")
#            return self.send_html(register_ip_page(self.client_ip(), self.banner()))
#
#        if path == "/logout":
#            return self.send("", 303, {"Location": "/",
#                                       "Set-Cookie": "sdu=; Path=/; Max-Age=0"})
#
#        if path.startswith("/f/"):
#            return self.send_font(path[len("/f/"):])
#        if path == "/tg":
#            return self.send_html(tg_page(self.client_ip()), frame=True)
#        if path == "/pay/back":
#            return self.pay_back()
#        if path.startswith("/pay/"):
#            return self.pay_start(path[len("/pay/"):])
#
#        if path != "/":
#            return self.send_html("<div class='icon'>❔</div><h1>صفحه پیدا نشد</h1>", 404)
#        return self.dashboard()
#
#    def send(self, body, code, headers):
#        blob = body.encode() if isinstance(body, str) else body
#        # Nothing reaches the socket until end_headers(), so a send() that
#        # raised part-way through leaves a half-written status line behind.
#        # Clearing the buffer keeps the next response from being appended to
#        # it and handed to the browser as one corrupt reply.
#        self._headers_buffer = []
#        self.send_response(code)
#        self.send_header("Content-Length", str(len(blob)))
#        for k, v in headers.items():
#            self.send_header(k, v)
#        self.end_headers()
#        self.wfile.write(blob)
#
#    def do_POST(self):
#        path = urllib.parse.urlparse(self.path).path.rstrip("/") or "/"
#
#        if path in ("/signup", "/login"):
#            form = self.form()
#            endpoint = "/user-signup" if path == "/signup" else "/user-password-login"
#            payload = {"username": form.get("username", ""),
#                       "password": form.get("password", ""),
#                       "ip": self.client_ip()}
#            if path == "/signup":
#                payload["name"] = form.get("name", "")
#                if form.get("password") != form.get("password2"):
#                    return self.redirect("/signup", "دو رمز یکی نیستند", bad=True)
#            try:
#                res = post(endpoint, payload)
#            except Exception as e:
#                log(ERROR, "panel: %s failed: %s" % (endpoint, e))
#                return self.redirect(path, "الان نشد، چند دقیقه دیگر", bad=True)
#            if not res.get("ok"):
#                return self.redirect(path, res.get("message", "خطا"), bad=True)
#            # Straight to the address page either way. A new account has no
#            # address yet, and somebody signing in from a new connection is
#            # usually signing in precisely because the address changed.
#            return self.send("", 303, {
#                "Location": "/register-ip",
#                "Set-Cookie": self.cookie_for(res["session"])})
#
#        if path == "/password":
#            if not self.session():
#                return self.redirect("/")
#            form = self.form()
#            if form.get("new") != form.get("again"):
#                return self.redirect("/", "دو رمز تازه یکی نیستند", bad=True)
#            try:
#                res = post("/user-password", {
#                    "session": self.session(),
#                    "current": form.get("current", ""),
#                    "new": form.get("new", ""),
#                })
#            except Exception as e:
#                log(ERROR, "panel: password change failed: %s" % e)
#                return self.redirect("/", "الان نشد، چند دقیقه دیگر", bad=True)
#            return self.redirect("/", res.get("message", ""),
#                                 bad=not res.get("ok"))
#
#        if path == "/receipt":
#            if not self.session():
#                return self.redirect("/")
#            form = self.form()
#            if form.get("too_big"):
#                return self.redirect("/", "فایل خیلی بزرگ است", bad=True)
#            try:
#                blob, kind = self.upload("file")
#            except ValueError as e:
#                return self.redirect("/", str(e), bad=True)
#            try:
#                res = post("/user-receipt", {
#                    "session": self.session(),
#                    "content_type": kind,
#                    "data": base64.b64encode(blob).decode("ascii"),
#                })
#            except Exception as e:
#                log(ERROR, "panel: receipt failed: %s" % e)
#                return self.redirect("/", "الان نشد، چند دقیقه دیگر", bad=True)
#            return self.redirect("/", res.get("message", ""),
#                                 bad=not res.get("ok"))
#
#        if path == "/tg/claim":
#            return self.tg_claim()
#
#        if path != "/register-ip":
#            return self.send_html("<h1>404</h1>", 404)
#        # Nothing typed is the button: the address this page is opened from.
#        form = self.form()
#        typed = (form.get("ip") or "").strip()
#        # One of two pages of our own, whatever the form claims.
#        back = "/" if form.get("back") == "/" else "/register-ip"
#        if typed:
#            ip, why = typed_ip(typed)
#            if not ip:
#                return self.redirect(back, why, bad=True)
#            log(INFO, "panel: %s registered %s by hand" % (self.client_ip(), ip))
#        else:
#            ip = self.client_ip()
#        try:
#            res = post("/user-claim", {"session": self.session(), "ip": ip})
#        except Exception as e:
#            log(ERROR, "panel: user-claim failed: %s" % e)
#            res = {"ok": False, "message": "الان نشد"}
#        return self.redirect("/", res.get("message", ""), bad=not res.get("ok"))
#
#    def dashboard(self):
#        token = self.session()
#        if not token:
#            return self.send_html(landing(self.banner()))
#        try:
#            info = post("/user-info", {"session": token, "ip": self.client_ip()})
#        except Exception as e:
#            log(ERROR, "panel: user-info failed: %s" % e)
#            return self.send_html("<div class='icon'>⚠️</div><h1>الان نشد</h1>"
#                                  "<p class='sub'>چند دقیقه دیگر دوباره.</p>", 502)
#        if not info.get("ok"):
#            return self.send_html(
#                "<div class='icon'>🔑</div><h1>نشست منقضی شده</h1>"
#                "<p class='sub'>دوباره <a href='/login'>وارد شوید</a>.</p>",
#                200, {"Set-Cookie": "sdu=; Path=/; Max-Age=0"})
#
#        banner = self.banner()
#
#        used, quota = info["used"], info["quota"]
#        seen = info.get("seen_ip") or self.client_ip()
#        rows = [("پلن", html.escape(info.get("plan") or "-")),
#                ("آی‌پی ثبت‌شده", "<code>%s</code>" % html.escape(info["ip"] or "ثبت نشده")),
#                ("مصرف", human_fa(used))]
#        if quota:
#            rows.append(("سهمیه", human_fa(quota)))
#            rows.append(("باقی‌مانده", human_fa(max(0, quota - used))))
#        else:
#            rows.append(("سهمیه", "نامحدود"))
#        kbps = info.get("speed_kbps") or 0
#        rows.append(("سرعت", ("%g مگابیت بر ثانیه" % (kbps / 1000.0)) if kbps
#                     else "بدون محدودیت"))
#        if info.get("expires"):
#            rows.append(("پایان دوره", info["expires"]))
#        elif info.get("renews"):
#            rows.append(("تمدید", info["renews"]))
#        rows.append(("کیف پول", "%s تومان" % format(info.get("wallet") or 0, ",")))
#        state = {"active": "<span class='ok'>فعال</span>",
#                 "pending": "<span class='warn'>در انتظار فعال‌سازی</span>",
#                 "over_quota": "<span class='warn'>سهمیه تمام شده</span>",
#                 "expired": "<span class='warn'>دورهٔ شما تمام شد</span>"}.get(
#                     info["status"], "<span class='bad'>غیرفعال</span>")
#        rows.append(("وضعیت", state))
#
#        gauge = ""
#        if quota:
#            pct = min(100, int(100.0 * used / quota))
#            cls = "hot" if pct >= 90 else ("warn" if pct >= 75 else "")
#            gauge = ("<div class='bar'><i class='%s' style='width:%d%%'></i></div>"
#                     % (cls, pct))
#
#        body = ["<h1>%s</h1>" % html.escape(info.get("name") or "حساب شما"),
#                "<div class='sub'>%s</div>" % html.escape(brand()),
#                banner, account_notice(info)]
#        for k, v in rows:
#            body.append("<div class='row'><span class='k'>%s</span>"
#                        "<span class='v'>%s</span></div>" % (k, v))
#        body.append(gauge)
#        body.append(dns_box())
#
#        if not info["ip"]:
#            body.append(
#                "<a class='btn' href='/register-ip'>ثبت آی‌پی — سرویس هنوز "
#                "باز نشده</a>"
#                "<p class='note'>تا آی‌پی ثبت نشود سرویس روی اینترنت شما کار "
#                "نمی‌کند.</p>")
#        elif info["ip"] != seen:
#            body.append(
#                "<a class='btn' href='/register-ip'>ثبت آی‌پی فعلی (%s)</a>"
#                "<p class='note'>آی‌پی اینترنت شما با آنچه ثبت شده فرق دارد. "
#                "این دکمه آی‌پی فعلی را جایگزین می‌کند.</p>" % html.escape(seen))
#        else:
#            body.append(
#                "<a class='btn ghost' href='/register-ip'>"
#                "ثبت دوباره همین آی‌پی</a>"
#                "<p class='note'>آی‌پی شما درست ثبت شده. اگر مودم را ریست کردید و "
#                "سرویس قطع شد، همین صفحه را باز کنید و این دکمه را بزنید.</p>")
#        body.append(manual_ip_box("/"))
#        body.append(
#            "<div class='dns'><div class='k'>ارسال رسید پرداخت</div>"
#            "<p class='note' style='margin-top:0'>عکس فیش واریزی را بفرستید تا "
#            "مدیر بررسی کند و حسابتان شارژ شود. عکس یا PDF، حداکثر ۴ مگابایت. "
#            "اگر رسید تازه‌ای بفرستید، جای قبلی را می‌گیرد.</p>"
#            "<form method='post' action='/receipt' enctype='multipart/form-data'>"
#            "<input type='file' name='file' required "
#            "accept='image/jpeg,image/png,image/webp,application/pdf'>"
#            "<button class='ghost'>فرستادن رسید</button></form></div>")
#        body.append(
#            "<details class='pw'><summary>تغییر رمز عبور</summary>"
#            "<form method='post' action='/password'>"
#            "<label>رمز فعلی</label>"
#            "<input name='current' type='password' required "
#            "autocomplete='current-password'>"
#            "<label>رمز تازه (دست‌کم ۸ نویسه)</label>"
#            "<input name='new' type='password' required minlength='8' "
#            "autocomplete='new-password'>"
#            "<label>تکرار رمز تازه</label>"
#            "<input name='again' type='password' required minlength='8' "
#            "autocomplete='new-password'>"
#            "<button class='ghost'>تغییر رمز</button></form>"
#            "<p class='note'>اگر جای دیگری وارد حسابتان باشید، با تغییر رمز "
#            "از آنجا خارج می‌شوید.</p></details>")
#        body.append("<p class='alt'><a href='/logout'>خروج از حساب</a></p>")
#        return self.send_html("".join(body))
#
#
#def main():
#    global CFG
#    CFG = load_config()
#    if not os.path.exists(ACL):
#        sys.exit("%s is missing - run the installer first" % ACL)
#    threading.Thread(target=sync_loop, daemon=True).start()
#    threading.Thread(target=ping_loop, daemon=True).start()
#
#    # Over TLS or not at all. This panel asks for a password and hands back a
#    # session cookie, and there is no version of that which is safe over plain
#    # http on an Iranian ISP. There used to be a second, plain listener that
#    # served a page explaining why the forms were switched off; a port that
#    # serves anything is a port that can be pointed at, so it is gone rather
#    # than harmless.
#    if CFG.get("PANEL_DOMAIN"):
#        serve_panel()
#    else:
#        print("sync up: every %ds to %s - no certificate, so no customer panel"
#              % (INTERVAL, CFG["PANEL_HOST"]), flush=True)
#        while True:
#            time.sleep(3600)
#
#
## How long a visitor may take to finish the TLS handshake, and then how long
## any one read or write may stall once it has. Per operation, not in total: a
## receipt crawling up a slow mobile link keeps making progress and is never
## cut off, while a connection that has simply gone quiet is let go.
#HANDSHAKE_TIMEOUT = 10
#IO_TIMEOUT = 30
#
#
#class PanelServer(http.server.ThreadingHTTPServer):
#    """The customer panel's server, with TLS done per connection.
#
#    It used to wrap the listening socket. That puts every visitor's TLS
#    handshake inside accept(), on the single thread that accepts for all of
#    them, with no timeout - so one phone whose connection dropped half way
#    through a handshake froze the panel for everybody until it went away,
#    which without a timeout could be never. On mobile networks in Iran that is
#    an ordinary event, and it was reported as "I sent my receipt and the page
#    stopped loading".
#
#    Here accept() only ever does accept(). The handshake happens in the
#    connection's own thread, under a deadline, so a stalled visitor stalls
#    only itself.
#    """
#    daemon_threads = True
#
#    def __init__(self, addr, handler, ctx):
#        self.ctx = ctx
#        super().__init__(addr, handler)
#
#    def finish_request(self, request, client_address):
#        if self.ctx is None:      # plain http, for tests only
#            return super().finish_request(request, client_address)
#        request.settimeout(HANDSHAKE_TIMEOUT)
#        try:
#            tls = self.ctx.wrap_socket(request, server_side=True)
#        except (ssl.SSLError, OSError):
#            # A scanner, a dropped phone, somebody speaking plain http to an
#            # https port. Nothing to answer, and nobody else is kept waiting.
#            return
#        try:
#            tls.settimeout(IO_TIMEOUT)
#            self.RequestHandlerClass(tls, client_address, self)
#        except (ssl.SSLError, OSError):
#            pass
#        finally:
#            try:
#                tls.close()
#            except OSError:
#                pass
#
#    def handle_error(self, request, client_address):
#        # Whatever a handler did not catch, with its traceback, at error
#        # level. http.server's default prints it at info, where nobody looks.
#        if isinstance(sys.exc_info()[1], GONE):
#            return
#        log_exception("request from %s failed" % client_address[0])
#
#
#def make_panel_server(ctx, port=None):
#    return PanelServer(("0.0.0.0", PANEL_TLS_PORT if port is None else port),
#                       UserPanel, ctx)
#
#
#def serve_panel():
#    cert = "/etc/letsencrypt/live/%s/fullchain.pem" % CFG["PANEL_DOMAIN"]
#    key = "/etc/letsencrypt/live/%s/privkey.pem" % CFG["PANEL_DOMAIN"]
#    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
#    ctx.load_cert_chain(cert, key)
#    httpd = make_panel_server(ctx)
#    print("sync up: every %ds to %s, panel on https://%s:%d/"
#          % (INTERVAL, CFG["PANEL_HOST"], CFG["PANEL_DOMAIN"], PANEL_TLS_PORT),
#          flush=True)
#    httpd.serve_forever()
#
#
#if __name__ == "__main__":
#    main()
#__END_SYNC__

#__BEGIN_SYNC_SERVICE__
#[Unit]
#Description=Smart DNS relay sync - usage out, allowlist in, claim page
#After=network-online.target nftables.service
#Wants=network-online.target
#
#[Service]
#Type=simple
#ExecStart=/usr/local/bin/smartdns-sync
#Restart=always
#RestartSec=10
## Needs root: it drives smartdns-acl, which talks to nftables.
#NoNewPrivileges=yes
#ProtectHome=yes
#PrivateTmp=yes
#
#[Install]
#WantedBy=multi-user.target
#__END_SYNC_SERVICE__

#__BEGIN_DNS_PROFILE_UNIT__
#[Unit]
#Description=Smart DNS resolver for service template %i
#After=network-online.target
#PartOf=smartdns-sync.service
#
#[Service]
#Type=simple
## /etc/smartdns-base mirrors /etc/dnsmasq.d by symlink, minus the operator's
## custom domains. Sharing by symlink means `smartdns add` and epic-pin still
## reach every resolver; leaving the custom file out is what lets a template
## not route those domains, since they cannot be un-routed by rule.
#ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/dev/null \
#    --conf-dir=/etc/smartdns-base --conf-file=/etc/smartdns-profiles/%i.conf
#Restart=always
#RestartSec=5
#
#[Install]
#WantedBy=multi-user.target
#__END_DNS_PROFILE_UNIT__

#__BEGIN_CERT__
##!/bin/bash
## smartdns-cert - obtain and renew the panel's TLS certificate.
##
## usage: smartdns-cert <domain>        get or renew a certificate
##        smartdns-cert --renew         renew everything due (the timer's job)
##
## Port 80 is the problem this script exists to work around. Let's Encrypt's
## HTTP-01 challenge needs it, and on a relay port 80 is forwarded whole to the
## exit node so that console downloads work: Sony and Microsoft serve game
## packages over plain HTTP from Akamai edges that answer 443 with a certificate
## naming no console host at all. Rebuilding nginx to terminate HTTP and answer
## the challenge itself would put an L7 proxy in the middle of the exact path
## that took a week to get right.
##
## So nginx is not touched. For the twenty seconds a challenge takes, an
## nftables rule sends port 80 to a local certbot instead, and the rule is
## removed afterwards - including when certbot fails, which is what the trap is
## for. A leftover rule would send every console download into a dead port.
##
## The cost is honest: console HTTP downloads stall for those twenty seconds, on
## the day a certificate is issued and again every sixty days. A download that
## stalls resumes; a certificate that expires takes the panel down until someone
## notices.
##
## If /etc/smart-dns/cloudflare.ini exists, DNS-01 is used instead and port 80
## is never touched at all. Nothing here asks for that token - it is only used
## when the operator has deliberately put it there.
#set -uo pipefail
#export PATH="$PATH:/usr/sbin:/sbin"
#
#CF_CONF=/etc/smart-dns/cloudflare.ini
#LIVE=/etc/letsencrypt/live
#ACME_PORT=8402
#NAT_TABLE=smartdns_acme
#
#R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
#[ -t 1 ] || { R=; G=; Y=; N=; }
#die() { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
#
#[ "$(id -u)" = 0 ] || die "run as root"
#
#open_port80() {
#    nft add table ip $NAT_TABLE 2>/dev/null
#    nft add chain ip $NAT_TABLE pre \
#        '{ type nat hook prerouting priority dstnat ; policy accept ; }' 2>/dev/null
#    nft add rule ip $NAT_TABLE pre tcp dport 80 redirect to :$ACME_PORT
#}
#
#close_port80() {
#    nft delete table ip $NAT_TABLE 2>/dev/null
#    return 0
#}
#
#issue() {
#    local domain="$1"
#    if [ -f "$CF_CONF" ]; then
#        # The operator supplied a DNS token, so prove it that way and leave
#        # port 80 alone entirely.
#        certbot certonly --dns-cloudflare \
#            --dns-cloudflare-credentials "$CF_CONF" \
#            --dns-cloudflare-propagation-seconds 30 \
#            --register-unsafely-without-email --agree-tos \
#            --non-interactive --quiet --cert-name "$domain" -d "$domain"
#        return $?
#    fi
#
#    # Always put port 80 back, whatever happens next.
#    trap close_port80 EXIT INT TERM
#    open_port80 || die "could not redirect port 80 for the challenge"
#    certbot certonly --standalone --http-01-port "$ACME_PORT" \
#        --register-unsafely-without-email --agree-tos \
#        --non-interactive --quiet --cert-name "$domain" -d "$domain"
#    local rc=$?
#    close_port80
#    trap - EXIT INT TERM
#    return $rc
#}
#
#case "${1:-}" in
#--renew)
#    # certbot decides what is due, so almost every run does nothing. The
#    # redirect is only opened when something actually needs renewing.
#    if certbot renew --dry-run >/dev/null 2>&1 || true; then :; fi
#    for path in "$LIVE"/*/; do
#        [ -d "$path" ] || continue
#        domain="$(basename "$path")"
#        openssl x509 -checkend $((30 * 86400)) -noout \
#            -in "$path/fullchain.pem" >/dev/null 2>&1 && continue
#        printf 'renewing %s\n' "$domain"
#        issue "$domain" && systemctl reload nginx 2>/dev/null
#    done
#    exit 0
#    ;;
#"")
#    die "usage: smartdns-cert <domain>" ;;
#esac
#
#DOMAIN="$1"
#
## A machine installed without a domain has this script but not certbot - the
## installer only pulls certbot in when it is about to issue something. Since
## the whole point of running this later is that there was no domain at install
## time, "certbot: not found" is the most likely first thing anybody sees here.
#if ! command -v certbot >/dev/null 2>&1; then
#    printf '    installing certbot\n'
#    export DEBIAN_FRONTEND=noninteractive
#    pkgs=certbot
#    [ -f "$CF_CONF" ] && pkgs="$pkgs python3-certbot-dns-cloudflare"
#    apt-get update -qq >/dev/null 2>&1
#    # shellcheck disable=SC2086
#    apt-get install -y -qq $pkgs >/dev/null 2>&1 \
#        || die "could not install certbot:  apt-get install -y $pkgs"
#fi
#
## Already have one with plenty of life left? Do nothing. Let's Encrypt limits
## issuance per domain per week, and re-issuing on every installer run would
## burn that allowance and then fail at the moment it mattered.
#if [ -d "$LIVE/$DOMAIN" ] && openssl x509 -checkend $((30 * 86400)) -noout \
#        -in "$LIVE/$DOMAIN/fullchain.pem" >/dev/null 2>&1; then
#    printf '    certificate for %s is current\n' "$DOMAIN"
#    exit 0
#fi
#
#if [ ! -f "$CF_CONF" ]; then
#    printf '    %sopening port 80 for about twenty seconds%s - console downloads\n' "$Y" "$N"
#    printf '    through this machine will stall until the challenge finishes\n'
#fi
#printf '    getting a certificate for %s\n' "$DOMAIN"
#issue "$DOMAIN" || die "certbot could not get a certificate for $DOMAIN.
#    The name must point at this machine and port 80 must be reachable from the
#    internet - that is how Let's Encrypt checks you control it."
#
#printf '%s    certificate installed:%s %s\n' "$G" "$N" "$LIVE/$DOMAIN/fullchain.pem"
#__END_CERT__

#__BEGIN_CERT_SERVICE__
#[Unit]
#Description=Renew the smart DNS panel certificates
#
#[Service]
#Type=oneshot
#ExecStart=/usr/local/bin/smartdns-cert --renew
#__END_CERT_SERVICE__

#__BEGIN_CERT_TIMER__
#[Unit]
#Description=Twice-daily certificate renewal check
#
#[Timer]
## Twice a day is what Let's Encrypt asks for. certbot itself decides what is
## actually due, so almost every run does nothing; the point is that a
## certificate never gets close to expiring unnoticed.
#OnCalendar=*-*-* 03,15:00:00
#RandomizedDelaySec=3h
#Persistent=true
#
#[Install]
#WantedBy=timers.target
#__END_CERT_TIMER__

#__BEGIN_ADMIN__
##!/usr/bin/env python3
#"""smartdns-admin - the operator's web panel.
#
#A separate process from smartdns-panel, sharing its database. Separate because
#the bot must not go down while this is being restarted, and because a bug in a
#web form should not take the thing that talks to customers with it. sqlite is
#in WAL mode, so two processes writing short transactions is fine.
#
#Three things stand in front of it, and none of them is sufficient alone:
#
#  a port nobody scans for   keeps it out of the way, nothing more
#  a random path prefix      an unguessable URL, not a credential
#  a password               the actual authentication
#
#Security by obscurity is not security, so the password is the real control and
#the other two only reduce how often anyone finds the door at all. Optional
#address locking is available and switched off by default: the operator's home
#address is dynamic, and locking to it would eventually shut them out.
#
#Standard library only, like everything else here, so the installer keeps
#needing no pip step. No CDN either - the pages are opened from Iran, and every
#font and stylesheet host worth using is either blocked or slow.
#"""
#
#import hashlib
#import hmac
#import html
#import http.cookies
#import http.server
#import json
#import os
#import re
#import secrets
#import sqlite3
#import ssl
#import subprocess
#import sys
#import threading
#import time
#import traceback
#import urllib.parse
#from datetime import datetime, timedelta, timezone
#
#CONFIG = "/etc/smart-dns/admin.env"
#DB = "/var/lib/smart-dns/panel.db"
#SERVICES_FILE = "/usr/local/share/smart-dns/services.json"
#
#GB = 1024 ** 3
#SESSION_HOURS = 12
## Failed logins allowed from one address before it is made to wait. A password
## is the real defence, so this only has to make guessing slow rather than
## impossible.
#MAX_TRIES = 8
#LOCKOUT_SECONDS = 900
## The database is small - a few hundred kilobytes - so this is a ceiling on
## nonsense rather than a real limit on backups.
#MAX_UPLOAD = 64 * 1024 * 1024
## Where the installer puts the panel's two faces.
#FONT_DIR = "/usr/local/share/smart-dns/fonts"
#
#
#def systemctl(*args):
#    """Nudge a unit, without letting a failure here become a traceback.
#
#    Used either side of a restore. If systemd is not reachable the restore
#    itself has still happened and the operator can restart by hand, so this
#    reports and carries on rather than raising.
#    """
#    try:
#        r = subprocess.run(["systemctl"] + list(args), capture_output=True,
#                           text=True, timeout=30)
#        if r.returncode != 0:
#            log(WARN, "systemctl %s: %s" % (" ".join(args), r.stderr.strip()))
#        return r.returncode == 0
#    except Exception as e:
#        log(WARN, "systemctl %s failed: %r" % (" ".join(args), e))
#        return False
#
#
#def now():
#    return datetime.now(timezone.utc).isoformat(timespec="seconds")
#
#
#def human(n):
#    n = float(n or 0)
#    for unit in ("B", "KB", "MB", "GB", "TB"):
#        if n < 1024 or unit == "TB":
#            return ("%d %s" if unit == "B" else "%.2f %s") % (n, unit)
#        n /= 1024
#
#
#def parse_ts(s):
#    if not s:
#        return None
#    try:
#        t = datetime.fromisoformat(s)
#    except ValueError:
#        return None
#    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)
#
#
#def panel_host():
#    """The name this panel is reachable by - whatever its certificate is for.
#
#    It listens on every address the machine has, but only this name matches
#    the certificate, so it is the only one worth printing back.
#    """
#    cert = CFG.get("ADMIN_CERT", "")
#    if cert.startswith("/etc/letsencrypt/live/"):
#        return cert.split("/")[4]
#    return "this-server"
#
#
## Ports that belong to the service itself. Moving the panel onto one of them
## takes down the thing it exists to administer.
#RESERVED_PORTS = {53: "DNS", 80: "HTTP", 443: "HTTPS",
#                  8443: "the relays' sync API",
#                  8446: "the exit's route to Google over IPv6", 22: "SSH"}
#
#
#def remaining_days(ts):
#    """Days left until `ts`, as placeholder text for the day field.
#
#    Shown greyed inside the input rather than as its value, so that saving a
#    row without touching the field does not silently reset the clock to
#    whatever it happened to say.
#    """
#    when = parse_ts(ts)
#    if not when:
#        return "بی‌نهایت"
#    left = (when - datetime.now(timezone.utc)).total_seconds() / 86400.0
#    if left <= 0:
#        return "تمام"
#    return "%d روز" % max(1, round(left))
#
#
#def load_config():
#    cfg = {}
#    with open(CONFIG) as fh:
#        for line in fh:
#            line = line.strip()
#            if not line or line.startswith("#") or "=" not in line:
#                continue
#            k, v = line.split("=", 1)
#            cfg[k.strip()] = v.strip().strip('"').strip("'")
#    for required in ("ADMIN_PATH", "ADMIN_HASH", "ADMIN_SALT", "ADMIN_PORT"):
#        if not cfg.get(required):
#            sys.exit("%s: %s is missing" % (CONFIG, required))
#    return cfg
#
#
#def hash_password(password, salt):
#    # 200k rounds: slow enough that guessing at scale is pointless, fast enough
#    # that a login is not noticeable.
#    return hashlib.pbkdf2_hmac(
#        "sha256", password.encode(), bytes.fromhex(salt), 200_000).hex()
#
#
## ------------------------------------------------------------------ storage
#class Store:
#    def __init__(self, path):
#        self.lock = threading.Lock()
#        self.db = sqlite3.connect(path, check_same_thread=False, timeout=15)
#        self.db.row_factory = sqlite3.Row
#        self.db.execute("PRAGMA foreign_keys = ON")
#        self.db.execute("PRAGMA journal_mode = WAL")
#
#        # Created here as well as in the panel's schema: this process can be
#        # the first to open the database on a machine where the panel has not
#        # started yet, and a missing table would mean nobody could sign in.
#        self.db.execute(
#            "CREATE TABLE IF NOT EXISTS admin_sessions ("
#            " token TEXT PRIMARY KEY, expires_at TEXT NOT NULL)")
#        self.db.commit()
#
#    def q(self, sql, args=()):
#        with self.lock:
#            return self.db.execute(sql, args).fetchall()
#
#    def one(self, sql, args=()):
#        rows = self.q(sql, args)
#        return rows[0] if rows else None
#
#    def run(self, sql, args=()):
#        with self.lock:
#            cur = self.db.execute(sql, args)
#            self.db.commit()
#            return cur
#
#    # The same two reads smartdns-panel does, spelled the same way. This panel
#    # keeps its own connection rather than importing that one, so they are
#    # written twice on purpose - but they must agree, because one writes what
#    # the other turns into the relays' bypass lists.
#    def template_groups(self, template_id):
#        return {(r["service_key"], r["group_key"]) for r in self.q(
#            "SELECT service_key, group_key FROM template_services"
#            " WHERE template_id = ?", (template_id,))}
#
#    def template_domains_off(self, template_id):
#        return {r["domain"] for r in self.q(
#            "SELECT domain FROM template_domains_off WHERE template_id = ?",
#            (template_id,))}
#
#    def snapshot(self, path):
#        """A consistent copy of the database at `path`, minus the metrics.
#
#        VACUUM INTO rather than copying the file: sqlite is in WAL mode, so
#        what is on disk is not the whole story and a copy taken while the bot
#        is writing can produce something that will not open.
#
#        Health samples are dropped. They are the bulk of the rows and none of
#        the value - what matters in a restore is who the customers are, what
#        they bought and what they have used.
#        """
#        with self.lock:
#            self.db.execute("VACUUM INTO ?", (path,))
#        copy = sqlite3.connect(path)
#        try:
#            copy.execute("DELETE FROM metrics")
#            copy.commit()
#            copy.execute("VACUUM")
#        finally:
#            copy.close()
#        return path
#
#    def close(self):
#        with self.lock:
#            self.db.close()
#
#
#def inspect_backup(path):
#    """Check a file really is one of our backups, and say what is in it.
#
#    Raises rather than returning a verdict, because every caller wants to stop.
#    Opening as sqlite is not enough: somebody's unrelated database would pass
#    that and then replace every customer with nothing.
#    """
#    db = sqlite3.connect(path)
#    try:
#        status = db.execute("PRAGMA integrity_check").fetchone()[0]
#        if status != "ok":
#            raise ValueError("integrity check failed: %s" % status)
#        have = {r[0] for r in db.execute(
#            "SELECT name FROM sqlite_master WHERE type = 'table'")}
#        missing = {"users", "ips", "templates", "settings"} - have
#        if missing:
#            raise ValueError("not a panel backup - missing %s"
#                             % ", ".join(sorted(missing)))
#        return {t: db.execute("SELECT count(*) FROM " + t).fetchone()[0]
#                for t in ("users", "ips", "templates", "transactions")}
#    finally:
#        db.close()
#
#
#def parse_upload(body, content_type, field):
#    """Pull one file out of a multipart/form-data body.
#
#    Hand-written because the stdlib's cgi module was removed in Python 3.13
#    and this panel is not allowed a pip step. One field is all that is needed,
#    so the parser only has to find its part and hand back the bytes between
#    that part's blank line and the next boundary.
#    """
#    marker = "boundary="
#    if marker not in (content_type or ""):
#        raise ValueError("not a file upload")
#    boundary = content_type.split(marker, 1)[1].strip().strip('"')
#    sep = b"--" + boundary.encode("latin-1")
#    want = ('name="%s"' % field).encode("latin-1")
#    for part in body.split(sep):
#        head, blank, data = part.partition(b"\r\n\r\n")
#        if not blank or want not in head:
#            continue
#        # The bytes before the next boundary carry a trailing CRLF that
#        # belongs to the delimiter, not to the file.
#        return data[:-2] if data.endswith(b"\r\n") else data
#    raise ValueError("no file was chosen")
#
#
## A checked backup waiting for the operator to confirm. In memory on purpose:
## a pending restore should not survive a restart, because nobody would
## remember agreeing to it.
#PENDING = {}
#
#
#CATALOGUE = []
#
#
#def load_catalogue():
#    try:
#        with open(SERVICES_FILE, encoding="utf-8") as fh:
#            services = json.load(fh).get("services", [])
#    except Exception:
#        services = []
#    services.append({"key": "custom", "label": "دامنه‌های دلخواه شما",
#                     "groups": [{"key": "main", "label": "همه", "domains": []}]})
#    return services
#
#
#def catalogue_now():
#    """The catalogue with the operator's own domains filled in.
#
#    Those live in the database, not the catalogue file, so CATALOGUE carries
#    their service with an empty list - and the template page, drawn from it,
#    showed "your domains" as having none while the relay was routing them.
#    """
#    custom = [r["domain"] for r in STORE.q(
#        "SELECT domain FROM custom_domains ORDER BY domain")]
#    return [dict(svc, groups=[dict(g, domains=custom) for g in svc["groups"]])
#            if svc["key"] == "custom" else svc for svc in CATALOGUE]
#
#
## -------------------------------------------------------------------- pages
#CSS = """
#/* Fasty DNS brand system: void #07080A, signal #C7F000, 1px lines, no radius.
#   Both faces are served by this panel itself - see send_font. Persian text
#   falls through to the device's own face; Latin and every numeral are the
#   brand's, which is where the system is strictest. */
#@font-face{font-family:'Space Grotesk';src:url(f/space.woff2) format('woff2');
# font-weight:300 700;font-style:normal;font-display:swap}
#@font-face{font-family:'JetBrains Mono';src:url(f/mono.woff2) format('woff2');
# font-weight:400 800;font-style:normal;font-display:swap}
#:root{--void:#07080A;--surface:#0D0F12;--raised:#14171C;--line:#23272E;
# --line2:#35404A;--dim:#646B76;--muted:#9AA1AC;--text:#EDEFF2;--signal:#C7F000;
# --pressed:#8BA800;--wash:#1F2610;--warn:#FFB020;--warn-wash:#2A2110;
# --fail:#FF4D3D;--fail-wash:#2A1414}
#*{box-sizing:border-box}
#body{margin:0;background:var(--void);color:var(--text);
# font:15px/1.6 'Space Grotesk',Vazirmatn,Tahoma,system-ui,sans-serif}
#a{color:var(--signal);text-decoration:none}
#.wrap{max-width:1180px;margin:0 auto;padding:24px 32px}
#header{display:flex;align-items:center;justify-content:space-between;
# border-bottom:1px solid var(--line);padding-bottom:16px;margin-bottom:24px;
# flex-wrap:wrap;gap:12px}
#h1{font-size:22px;margin:0;font-weight:600;letter-spacing:-.02em}
#nav a{margin-left:20px;color:var(--muted);font-size:14px;
# transition:color .12s ease-out}
#nav a:hover{color:var(--text)}
#nav a.on{color:var(--signal);font-weight:600}
#.card{background:var(--surface);border:1px solid var(--line);padding:20px;
# margin-bottom:20px}
#.card h2{font-size:17px;margin:0 0 14px;font-weight:600;color:var(--text)}
#table{width:100%;border-collapse:collapse;font-size:14px}
#th{text-align:right;color:var(--dim);font-weight:500;padding:9px 8px;
# border-bottom:1px solid var(--line);font-size:11px;letter-spacing:.16em;
# text-transform:uppercase;font-family:'JetBrains Mono',ui-monospace,monospace}
#td{padding:10px 8px;border-bottom:1px solid var(--line)}
#tr:last-child td{border-bottom:0}
#code{background:var(--void);border:1px solid var(--line);padding:2px 7px;
# color:var(--text);font-size:13px;
# font-family:'JetBrains Mono',ui-monospace,monospace;direction:ltr;
# unicode-bidi:isolate}
#.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:1px;
# background:var(--line);border:1px solid var(--line)}
#.stat{background:var(--surface);padding:20px}
#.stat .n{font-size:30px;font-weight:500;letter-spacing:-.03em;
# font-family:'JetBrains Mono',ui-monospace,monospace;direction:ltr;
# unicode-bidi:isolate}
#.stat .l{color:var(--dim);font-size:10px;margin-top:6px;letter-spacing:.16em;
# text-transform:uppercase;font-family:'JetBrains Mono',ui-monospace,monospace}
#.bar{height:6px;background:var(--void);border:1px solid var(--line);margin-top:7px}
#.bar i{display:block;height:100%;background:var(--signal)}
#.bar i.warn{background:var(--warn)}
#.bar i.hot{background:var(--fail)}
#input,select,button,textarea{font:inherit;background:var(--void);color:var(--text);
# border:1px solid var(--line);padding:10px 12px;min-height:38px;
# transition:background .12s ease-out,border-color .12s ease-out,color .12s ease-out}
#input,textarea{font-family:'JetBrains Mono',ui-monospace,monospace;font-size:14px}
#input:focus,select:focus,textarea:focus{outline:0;border-color:var(--signal)}
#button{background:var(--signal);border-color:var(--signal);color:var(--void);
# cursor:pointer;font-weight:600}
#button:hover{background:#D9FF3A;border-color:#D9FF3A}
#button:active{background:var(--pressed);border-color:var(--pressed)}
#button.danger{background:var(--fail-wash);border-color:var(--fail);color:var(--fail)}
#button.danger:hover{background:var(--fail);border-color:var(--fail);color:var(--void)}
#button.ghost{background:transparent;border-color:var(--line2);color:var(--text);
# font-weight:500}
#button.ghost:hover{background:transparent;border-color:var(--signal);color:var(--signal)}
#form.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
#.muted{color:var(--dim);font-size:13px}
#.ok{color:var(--signal)}.bad{color:var(--fail)}.warn{color:var(--warn)}
#.msg{padding:11px 14px;margin-bottom:16px;font-size:14px;border:1px solid var(--line)}
#.msg.good{background:var(--wash);border-color:var(--signal)}
#.msg.err{background:var(--fail-wash);border-color:var(--fail)}
#label{display:block;color:var(--muted);font-size:13px;margin-bottom:6px}
#.f{margin-bottom:14px}
#.login{max-width:360px;margin:14vh auto}
#.receipt{border:1px solid var(--line);padding:16px;margin-bottom:16px;
# background:var(--void)}
#.receipt .who{font-size:15px;font-weight:600;margin-bottom:10px}
#.receipt img{max-width:100%;max-height:420px;border:1px solid var(--line);display:block}
#td.acts{white-space:nowrap}
#td.acts form{display:inline}
#td.acts button{padding:7px 11px;font-size:12px;margin-right:4px;min-height:34px}
#a.dl{display:inline-block;background:var(--signal);color:var(--void);font-weight:600;
# padding:11px 18px;text-decoration:none;min-height:44px}
#a.dl:hover{background:#D9FF3A}
#.svc{display:inline-block;margin:0 0 8px 14px}
#.svc label{display:inline;color:var(--text);font-size:14px}
#details.svc{display:block;margin:0 0 6px;border:1px solid var(--line);
# background:var(--void)}
#details.svc>summary{padding:10px 12px;cursor:pointer;list-style:none;
# display:flex;align-items:center;gap:10px}
#details.svc>summary::-webkit-details-marker{display:none}
#details.svc>summary::before{content:'▸';color:var(--dim);font-size:11px}
#details.svc[open]>summary::before{content:'▾'}
#details.svc[open]{border-color:var(--line2)}
#details.svc>summary label{flex:1}
#.doms{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));
# gap:2px 14px;padding:4px 30px 12px;border-top:1px solid var(--line);margin-top:2px}
#.doms label{display:flex;align-items:center;gap:7px;color:var(--muted);font-size:12px;
# font-family:'JetBrains Mono',ui-monospace,monospace;margin:0;padding:2px 0}
#.doms label span{direction:ltr;overflow:hidden;text-overflow:ellipsis;
# white-space:nowrap}
#.doms input{margin:0;min-height:0}
#.optin{display:block;font-size:11px;color:var(--warn);font-weight:400;margin-top:2px}
#.pick{margin-right:auto;display:flex;gap:6px}
#.pick button{padding:4px 10px;font-size:11px;font-weight:500;min-height:0;
# background:transparent;border:1px solid var(--line);color:var(--muted)}
#.pick button:hover{background:var(--raised);border-color:var(--line2);color:var(--text)}
#.brand{display:flex;align-items:center;gap:10px;margin:0 0 20px;direction:ltr}
#.brand svg{display:block}
#.brand .name{font-size:20px;font-weight:700;letter-spacing:-.025em;color:var(--text)}
#.brand .dns{font-family:'JetBrains Mono',ui-monospace,monospace;font-size:12px;
# font-weight:500;letter-spacing:.22em;color:var(--muted)}
#footer{text-align:center;color:var(--dim);font-size:11px;padding:26px 0 6px;
# direction:ltr;font-family:'JetBrains Mono',ui-monospace,monospace;
# letter-spacing:.16em;text-transform:uppercase}
#"""
#
## Where the installer writes the version it installed. Read per page rather
## than once, so it can never disagree with what is on disk.
#VERSION_FILE = "/var/lib/smart-dns/version"
#
#
#def app_version():
#    try:
#        with open(VERSION_FILE) as fh:
#            return fh.read().strip()[:20]
#    except OSError:
#        return ""
#
#
## The mark, drawn rather than fetched, on the brand's own 44x44 grid.
#MARK = ("<svg viewBox='0 0 44 44' width='%d' height='%d' aria-hidden='true'>"
#        "<rect width='44' height='44' rx='11' fill='#C7F000'/>"
#        "<path d='M12 14 L20 22 L12 30' stroke='#07080A' stroke-width='3.4'"
#        " stroke-linecap='square' fill='none'/>"
#        "<path d='M23 14 L31 22 L23 30' stroke='#07080A' stroke-width='3.4'"
#        " stroke-linecap='square' fill='none'/></svg>")
#FAVICON = ("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 44 44'"
#           "%3E%3Crect width='44' height='44' rx='11' fill='%23C7F000'/%3E%3Cpath d='M12 14"
#           " L20 22 L12 30' stroke='%2307080A' stroke-width='3.4' fill='none'/%3E%3Cpath"
#           " d='M23 14 L31 22 L23 30' stroke='%2307080A' stroke-width='3.4' fill='none'/%3E%3C/svg%3E")
#
#
#def brand_html():
#    return ("<div class='brand'>%s<span class='name'>Fasty</span>"
#            "<span class='dns'>DNS</span></div>" % (MARK % (26, 26)))
#
#
#def footer_html():
#    v = app_version()
#    return "<footer>FASTY DNS%s</footer>" % (" · v" + html.escape(v) if v else "")
#
#
#def page(title, body, cfg, active="", msg=None, msg_kind="good"):
#    nav = ""
#    for path, label in (("", "خانه"), ("users", "کاربران"), ("receipts", "رسیدها"),
#                        ("templates", "قالب‌ها"), ("domains", "دامنه‌ها"),
#                        ("settings", "تنظیمات"), ("logs", "لاگ")):
#        cls = " class='on'" if active == path else ""
#        nav += "<a href='/%s/%s'%s>%s</a>" % (cfg["ADMIN_PATH"], path, cls, label)
#    banner = ""
#    if msg:
#        banner = "<div class='msg %s'>%s</div>" % (msg_kind, html.escape(msg))
#    return ("""<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
#<meta name="viewport" content="width=device-width,initial-scale=1">
#<link rel="icon" href="%s">
#<title>%s</title><style>%s</style></head><body><div class="wrap">%s
#<header><h1>%s</h1><nav>%s<a href='/%s/logout'>خروج</a></nav></header>
#%s%s%s</div></body></html>""" % (html.escape(title), FAVICON, CSS, brand_html(),
#                                 html.escape(title), nav, cfg["ADMIN_PATH"],
#                                 banner, body, footer_html()))
#
#
#def login_page(cfg, error=None):
#    err = "<div class='msg err'>%s</div>" % html.escape(error) if error else ""
#    # The action is spelled out rather than left to default to the current
#    # URL. A form with no action posts wherever the browser happens to be,
#    # which after a bookmark to a page that has moved is not the panel.
#    return """<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
#<meta name="viewport" content="width=device-width,initial-scale=1">
#<link rel="icon" href="%s">
#<title>ورود</title><style>%s</style></head><body><div class="wrap">%s
#<div class="login" style="margin-top:6vh">
#<div class="card"><h2>پنل مدیریت</h2>%s
#<form method="post" action="/%s/"><div class="f"><label>رمز عبور</label>
#<input type="password" name="password" autofocus style="width:100%%"></div>
#<button type="submit" style="width:100%%">ورود</button></form></div>
#</div>%s</div></body></html>""" % (FAVICON, CSS, brand_html(), err,
#                                   cfg["ADMIN_PATH"], footer_html())
#
#
#def bar(used, total):
#    if not total:
#        return "<span class='muted'>-</span>"
#    pct = min(100, int(100.0 * used / total))
#    cls = "hot" if pct >= 90 else ("warn" if pct >= 75 else "")
#    return ("%d%% <span class='muted'>(%s از %s)</span>"
#            "<div class='bar'><i class='%s' style='width:%d%%'></i></div>"
#            % (pct, human(used), human(total), cls, pct))
#
#
## ----------------------------------------------------------------- handler
## Sessions live in the database, not in this process. They used to be a dict,
## which meant every restart signed the operator out - and this panel restarts
## whenever it is upgraded, whenever its port or path is changed, and after a
## restore. Being signed out is not only an annoyance: without a session, a
## visit to the bare address is answered with the same bare 404 a stranger
## gets, which is how "the panel 404s sometimes" was really happening.
##
## Failed attempts stay in memory. Losing that count on restart only makes
## guessing slightly easier for someone who cannot cause restarts anyway.
#ATTEMPTS = {}          # address -> [count, first_failure_time]
## ------------------------------------------------------------------ logging
## journald reads a leading <N> on a line as its syslog level. Warnings and
## errors carry one, so `journalctl -p warning` - which is what
## `smartdns-logs -e` runs - shows exactly the problems. Ordinary lines stay
## unmarked and land at info, as they always did. Before this everything
## landed at info, stderr included, and a failure looked like a heartbeat.
#INFO, WARN, ERROR = 6, 4, 3
## The visitor went away, or never finished saying hello. Not a fault here.
#GONE = (ConnectionError, TimeoutError, ssl.SSLError)
#
#
#def log(level, msg):
#    tag = "<%d>" % level if level < INFO else ""
#    for line in str(msg).splitlines() or [""]:
#        print(tag + line, flush=True)
#
#
#def log_exception(what):
#    """An error with its traceback, every line at error level. journald makes
#    each line its own entry, and at info all but the first would be lost
#    among the ordinary ones."""
#    log(ERROR, "%s\n%s" % (what, traceback.format_exc().rstrip()))
#
#
#def log_access(h, prefix, code, path, who=""):
#    """One line for one request: what was asked, the answer, how long it took
#    and who asked. Server errors at error level; everything else is info."""
#    try:
#        code = int(code)
#    except (TypeError, ValueError):
#        code = 0
#    ms = (time.monotonic() - getattr(h, "_t0", time.monotonic())) * 1000
#    # 501 is a scanner's GET to a POST-only port: the visitor's mistake.
#    log(ERROR if code >= 500 and code != 501 else INFO, "%s %s %s %d %dms from %s%s" % (
#        prefix, getattr(h, "command", None) or "-", path, code, ms,
#        h.client_address[0], " " + who if who else ""))
#
#
## Form fields never written to the journal, whatever the action.
#SECRET_FIELDS = re.compile(r"pass|token|secret|session|salt|hash", re.I)
#
#
#def describe(params):
#    """An action's form, fit for the journal: no passwords or tokens, and a
#    long list - a template's domains - as a count rather than every name."""
#    out = []
#    for k in sorted(params):
#        vals = [v for v in params[k] if v != ""]
#        if not vals:
#            continue
#        if SECRET_FIELDS.search(k):
#            out.append("%s=***" % k)
#        elif len(vals) > 4:
#            out.append("%s=[%d]" % (k, len(vals)))
#        else:
#            out.append("%s=%s" % (k, ",".join(v[:40] for v in vals)))
#    return " " + " ".join(out) if out else ""
#
#
## How long a visitor may take over the TLS handshake, and then how long any one
## read or write may stall. Per operation, so an upload that keeps moving is
## never cut off, while a connection that has gone quiet is let go.
#HANDSHAKE_TIMEOUT = 10
#IO_TIMEOUT = 30
#
#
#class TLSServer(http.server.ThreadingHTTPServer):
#    """TLS per connection, under a deadline - never on the listening socket.
#
#    Wrapping the listening socket runs every visitor's handshake inside
#    accept(), on the one thread that accepts for all of them and with no
#    timeout, so a single connection that opens and then says nothing freezes
#    the server for everybody until it goes away. The customer panel froze
#    exactly that way in production, and this server was built the same way.
#    Here accept() only accepts; a stalled visitor stalls only its own thread.
#
#    ctx=None serves plain http. That is for tests - main() refuses to.
#    """
#    daemon_threads = True
#
#    def __init__(self, addr, handler, ctx):
#        self.ctx = ctx
#        super().__init__(addr, handler)
#
#    def finish_request(self, request, client_address):
#        if self.ctx is None:
#            return super().finish_request(request, client_address)
#        request.settimeout(HANDSHAKE_TIMEOUT)
#        try:
#            tls = self.ctx.wrap_socket(request, server_side=True)
#        except (ssl.SSLError, OSError):
#            return      # a scanner, a dropped phone, plain http to an https port
#        try:
#            tls.settimeout(IO_TIMEOUT)
#            self.RequestHandlerClass(tls, client_address, self)
#        except (ssl.SSLError, OSError):
#            pass
#        finally:
#            try:
#                tls.close()
#            except OSError:
#                pass
#
#    def handle_error(self, request, client_address):
#        # Whatever a handler did not catch, with its traceback, at error
#        # level. http.server's default prints it at info, where nobody looks.
#        if isinstance(sys.exc_info()[1], GONE):
#            return
#        log_exception("request from %s failed" % client_address[0])
#
#
#STORE = None
#CFG = {}
#
#
#class Admin(http.server.BaseHTTPRequestHandler):
#    server_version = "smartdns"
#    protocol_version = "HTTP/1.1"
#
#    def log_message(self, fmt, *args):
#        # http.server's own notes - a malformed request, a timeout. They can
#        # quote the raw request line, so the secret path is masked here too.
#        msg = fmt % args
#        if CFG.get("ADMIN_PATH"):
#            msg = msg.replace(CFG["ADMIN_PATH"], "<admin>")
#        log(INFO, "admin %s from %s" % (msg, self.client_address[0]))
#
#    def parse_request(self):
#        self._t0 = time.monotonic()
#        return super().parse_request()
#
#    def log_request(self, code="-", size="-"):
#        log_access(self, "admin", code, self.shown_path())
#
#    def shown_path(self):
#        """The path for the journal, with the secret part shown as <admin>
#        and the query - only ever the message after an action - left off."""
#        path = urllib.parse.urlparse(getattr(self, "path", "") or "").path
#        secret = CFG.get("ADMIN_PATH") or ""
#        if secret and (path == "/" + secret or path.startswith("/" + secret + "/")):
#            path = "/<admin>" + path[len(secret) + 1:]
#        return path[:120]
#
#    # -- plumbing ---------------------------------------------------------
#    def send(self, body, code=200, headers=None):
#        blob = body.encode("utf-8") if isinstance(body, str) else body
#        # Start the header buffer clean. Nothing reaches the socket until
#        # end_headers(), so a send() that raised part-way through leaves a
#        # half-written status line behind; without this, the error page that
#        # follows is appended to it and the browser is handed two responses in
#        # one - which it reports as corrupted content rather than as an error.
#        self._headers_buffer = []
#        self.send_response(code)
#        self.send_header("Content-Type", "text/html; charset=utf-8")
#        self.send_header("Content-Length", str(len(blob)))
#        # This panel is only ever reached over TLS, and none of it should sit
#        # in a cache or be framed by anything.
#        self.send_header("Cache-Control", "no-store")
#        self.send_header("X-Frame-Options", "DENY")
#        self.send_header("X-Content-Type-Options", "nosniff")
#        self.send_header("Referrer-Policy", "no-referrer")
#        for k, v in (headers or {}).items():
#            self.send_header(k, v)
#        self.end_headers()
#        self.wfile.write(blob)
#
#    def redirect(self, path, headers=None):
#        """Redirect, percent-encoding anything that is not plain ascii.
#
#        Every message this panel shows after an action is Persian, and it
#        travels in the query string of a Location header. A header can only
#        carry latin-1, so an unencoded message makes send_header raise in the
#        middle of the response - which the browser reports as corrupted
#        content, after the action has already been carried out.
#        """
#        base, sep, query = path.lstrip("/").partition("?")
#        if sep:
#            fields = []
#            for item in query.split("&"):
#                key, _, value = item.partition("=")
#                # A message starting with ! is a refusal - a bad number, a
#                # name already taken. The request line cannot say which; this
#                # can.
#                if key == "m" and value.startswith("!"):
#                    log(WARN, "admin %s refused: %s"
#                        % (getattr(self, "_action", "-"), value[1:]))
#                fields.append("%s=%s" % (key, urllib.parse.quote(value, safe="")))
#            query = "?" + "&".join(fields)
#        h = {"Location": "/%s/%s%s" % (CFG["ADMIN_PATH"], base, query)}
#        h.update(headers or {})
#        self.send("", 303, h)
#
#    def body_params(self):
#        length = int(self.headers.get("Content-Length", 0) or 0)
#        # A file upload is read as bytes elsewhere; decoding a database as
#        # utf-8 and running it through parse_qs would be nonsense.
#        if "multipart/form-data" in (self.headers.get("Content-Type") or ""):
#            self.raw_body = self.rfile.read(min(length, MAX_UPLOAD))
#            return {}
#        raw = self.rfile.read(length).decode("utf-8", "replace") if length else ""
#        return urllib.parse.parse_qs(raw, keep_blank_values=True)
#
#    # -- backup and restore ----------------------------------------------
#    def send_font(self, name):
#        """One of the two faces this panel is drawn in.
#
#        Before the session check on purpose: the sign-in page is drawn in them
#        too, and a font is not a secret. Cached for a year - the files change
#        only when the installer replaces them, under the same names.
#        """
#        if name not in ("space.woff2", "mono.woff2"):
#            return self.lost()
#        try:
#            with open(os.path.join(FONT_DIR, name), "rb") as fh:
#                blob = fh.read()
#        except OSError:
#            return self.lost()
#        return self.send(blob, 200, {"Content-Type": "font/woff2",
#                                     "Cache-Control": "public, max-age=31536000, immutable"})
#
#    def send_backup(self):
#        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
#        # Beside the database rather than in /tmp: the unit sets PrivateTmp, so
#        # /tmp is a mount point of its own, and the restore path below cannot
#        # rename across one.
#        path = os.path.join(os.path.dirname(DB), ".backup-%s.db" % stamp)
#        try:
#            STORE.snapshot(path)
#            with open(path, "rb") as fh:
#                blob = fh.read()
#        except Exception as e:
#            log_exception("backup failed: %r" % e)
#            return self.redirect("settings?m=!پشتیبان‌گیری نشد: %s" % e)
#        finally:
#            try:
#                os.unlink(path)
#            except OSError:
#                pass
#        return self.send(blob, 200, {
#            "Content-Type": "application/octet-stream",
#            "Content-Disposition":
#                'attachment; filename="smartdns-backup-%s.db"' % stamp})
#
#    # -- receipts ---------------------------------------------------------
#    def send_receipt(self, ident):
#        """Hand back the stored image itself, for the <img> on the page.
#
#        Served from here rather than inlined as a data URI: the page lists
#        every pending receipt, and inlining several megabytes of base64 into
#        the HTML would make the list slow to open over an Iranian connection
#        even when the operator only wants to glance at one.
#        """
#        row = STORE.one("SELECT receipt_blob, receipt_type FROM transactions"
#                        " WHERE id = ?", (int(ident) if ident.isdigit() else 0,))
#        if not row or not row["receipt_blob"]:
#            return self.send("<h1>404</h1>", 404)
#        return self.send(bytes(row["receipt_blob"]), 200, {
#            "Content-Type": row["receipt_type"] or "application/octet-stream",
#            # Not inline for a PDF: opening one in the panel's own origin is a
#            # needless way to run somebody else's file next to the session.
#            "Content-Disposition": "inline; filename=receipt-%s" % ident})
#
#    def receipts(self):
#        p = CFG["ADMIN_PATH"]
#        rows = STORE.q(
#            "SELECT t.*, u.first_name, u.username, u.phone, u.telegram_id,"
#            " length(t.receipt_blob) AS size,"
#            " (SELECT name FROM plans WHERE id = t.plan_id) AS plan_name"
#            " FROM transactions t JOIN users u ON u.id = t.user_id"
#            # An online payment link that was opened and never paid is not a
#            # decision anybody made, and below it would read as a rejection.
#            " WHERE t.status != 'started'"
#            " ORDER BY CASE t.status WHEN 'pending' THEN 0 ELSE 1 END,"
#            " t.created_at DESC LIMIT 100")
#        pending = [r for r in rows if r["status"] == "pending"]
#        out = ["<div class='card'><h2>رسیدهای در انتظار (%d)</h2>" % len(pending)]
#        if not pending:
#            out.append("<p class='muted'>رسیدی نرسیده.</p>")
#        for r in pending:
#            who = (r["first_name"] or "") + " · " + (
#                r["username"] or r["phone"]
#                or str(r["telegram_id"] or "#%d" % r["user_id"]))
#            if r["plan_name"]:
#                who += " · پلن %s" % r["plan_name"]
#            out.append(
#                "<div class='receipt'>"
#                "<div class='who'>%s<span class='muted'> · %s · %s</span></div>"
#                "<a href='/%s/receipt/%d' target='_blank'>"
#                "<img src='/%s/receipt/%d' alt='رسید'></a>"
#                "<div class='row' style='margin-top:10px'>"
#                "<form method='post' action='/%s/receipt-decide'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<input type='hidden' name='to' value='approved'>"
#                "<button>تأیید</button></form>"
#                "<form method='post' action='/%s/receipt-decide'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<input type='hidden' name='to' value='rejected'>"
#                "<button class='danger'>رد</button></form>"
#                "<a class='muted' href='/%s/users'>ویرایش حساب این کاربر ←</a>"
#                "</div></div>"
#                % (html.escape(who), html.escape(r["created_at"][:16]),
#                   human(r["size"] or 0),
#                   p, r["id"], p, r["id"], p, r["id"], p, r["id"], p))
#        out.append("<p class='muted'>تأیید یا رد فقط تصمیم را ثبت می‌کند و عکس "
#                   "را پاک می‌کند؛ سهمیه و زمان را خودتان در صفحهٔ کاربران "
#                   "می‌گذارید.</p></div>")
#
#        decided = [r for r in rows if r["status"] != "pending"]
#        if decided:
#            out.append("<div class='card'><h2>تصمیم‌های قبلی</h2>"
#                       "<table><tr><th>کاربر</th><th>رسید</th><th>تصمیم</th>"
#                       "<th>تاریخ</th></tr>")
#            for r in decided[:40]:
#                out.append("<tr><td>%s</td><td>%s</td><td class='%s'>%s</td>"
#                           "<td>%s</td></tr>"
#                           % (html.escape((r["first_name"] or "") + " · " +
#                                          (r["username"] or r["phone"] or "")),
#                              html.escape(r["created_at"][:16]),
#                              "ok" if r["status"] == "approved" else "bad",
#                              "تأیید شد" if r["status"] == "approved" else "رد شد",
#                              html.escape((r["decided_at"] or "")[:16])))
#            out.append("</table></div>")
#        return "".join(out)
#
#    def take_upload(self):
#        """Stage an uploaded file and describe it, or explain why it is no good."""
#        try:
#            blob = parse_upload(getattr(self, "raw_body", b""),
#                                self.headers.get("Content-Type"), "file")
#        except ValueError as e:
#            return self.redirect("settings?m=!%s" % e)
#        if not blob:
#            return self.redirect("settings?m=!فایل خالی بود")
#        if len(blob) >= MAX_UPLOAD:
#            return self.redirect("settings?m=!فایل خیلی بزرگ است")
#
#        path = os.path.join(os.path.dirname(DB),
#                            ".restore-%s.db" % secrets.token_hex(6))
#        with open(path, "wb") as fh:
#            fh.write(blob)
#        try:
#            counts = inspect_backup(path)
#        except Exception as e:
#            os.unlink(path)
#            return self.redirect("settings?m=!این فایل نسخهٔ پشتیبان سالمی نیست: %s" % e)
#
#        old = PENDING.pop("path", None)
#        if old and os.path.exists(old):
#            os.unlink(old)
#        PENDING.update({"path": path, "counts": counts, "size": len(blob)})
#        return self.redirect("restore")
#
#    def restore_page(self):
#        p = CFG["ADMIN_PATH"]
#        if not PENDING.get("path") or not os.path.exists(PENDING.get("path", "")):
#            return ("<div class='card'><h2>بازگردانی</h2><p class='muted'>فایلی "
#                    "برای بازگردانی منتظر نیست. از <a href='/%s/settings'>تنظیمات</a> "
#                    "یک نسخهٔ پشتیبان بفرستید.</p></div>" % p)
#        c = PENDING["counts"]
#        now_c = STORE.one(
#            "SELECT (SELECT count(*) FROM users) u, (SELECT count(*) FROM ips) i,"
#            " (SELECT count(*) FROM templates) t,"
#            " (SELECT count(*) FROM transactions) x")
#        rows = [("کاربران", c["users"], now_c["u"]),
#                ("آی‌پی‌های ثبت‌شده", c["ips"], now_c["i"]),
#                ("قالب‌ها", c["templates"], now_c["t"]),
#                ("تراکنش‌ها", c["transactions"], now_c["x"])]
#        body = ["<div class='card'><h2>این فایل جایگزین دیتابیس فعلی شود؟</h2>",
#                "<p class='muted'>حجم فایل: %s</p>" % human(PENDING["size"]),
#                "<table class='tbl'><tr><th></th><th>در فایل</th>"
#                "<th>الان در سرویس</th></tr>"]
#        for label, new, old in rows:
#            cls = "" if new == old else " class='warn'"
#            body.append("<tr><td>%s</td><td%s>%d</td><td>%d</td></tr>"
#                        % (label, cls, new, old))
#        body.append("</table>")
#        body.append(
#            "<div class='msg err' style='margin-top:18px'>بازگردانی، دیتابیس "
#            "فعلی را کامل جایگزین می‌کند. از وضعیت فعلی قبلش یک نسخه کنار "
#            "دیتابیس نگه داشته می‌شود، پس این کار برگشت‌پذیر است — ولی سرویس "
#            "چند ثانیه‌ای ری‌استارت می‌شود.</div>")
#        body.append(
#            "<form method='post' action='/%s/restore-apply' style='display:inline'>"
#            "<button class='danger'>بله، جایگزین کن</button></form> "
#            "<form method='post' action='/%s/restore-cancel' style='display:inline'>"
#            "<button class='ghost'>انصراف</button></form></div>" % (p, p))
#        return "".join(body)
#
#    def moving_to(self, port, path):
#        """Hand back the new address, then restart onto it.
#
#        A redirect would be wrong: the browser would follow it to the old
#        address, which is about to stop answering. So this is a page, with the
#        new address on it, and the restart happens a second later - by which
#        time the operator has the link in front of them.
#        """
#        url = "https://%s:%s/%s/" % (panel_host(), port, path)
#        self.send(page("آدرس تازه",
#                       "<div class='card'><h2>آدرس پنل عوض شد</h2>"
#                       "<p>از این به بعد اینجاست — همین حالا ذخیره‌اش کنید:</p>"
#                       "<p><code>%s</code></p>"
#                       "<p class='muted'>پنل تا چند ثانیهٔ دیگر روی آدرس تازه "
#                       "بالا می‌آید. اگر باز نشد، به احتمال زیاد فایروال یا "
#                       "security group سرور پورت را نمی‌گذارد رد شود؛ از روی "
#                       "خود سرور با <code>smartdns-access</code> برش گردانید."
#                       "</p></div>" % html.escape(url), CFG, "settings"),
#                  200, {"Refresh": "6; url=%s" % url})
#        try:
#            self.wfile.flush()
#        except Exception:
#            pass
#        print("panel moving to %s" % url, flush=True)
#        threading.Timer(1.0, os._exit, (0,)).start()
#
#    def apply_restore(self):
#        path = PENDING.get("path")
#        if not path or not os.path.exists(path):
#            return self.redirect("settings?m=!چیزی برای بازگردانی نیست")
#        keep = "%s.before-restore-%s" % (
#            DB, datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S"))
#        try:
#            STORE.snapshot(keep)
#            # Stop the bot before the swap. It holds the old file open and
#            # keeps writing to the journal beside it; deleting that journal
#            # underneath a running process is how a restore becomes corruption.
#            systemctl("stop", "smartdns-panel")
#            STORE.close()
#            os.replace(path, DB)
#            for suffix in ("-wal", "-shm"):
#                try:
#                    os.unlink(DB + suffix)
#                except OSError:
#                    pass
#            systemctl("start", "smartdns-panel")
#        except Exception as e:
#            log_exception("restore failed: %r" % e)
#            systemctl("start", "smartdns-panel")
#            return self.redirect("settings?m=!بازگردانی نشد: %s" % e)
#        PENDING.clear()
#
#        p = CFG["ADMIN_PATH"]
#        self.send(page("بازگردانی شد",
#                       "<div class='card'><h2>بازگردانی شد</h2>"
#                       "<p>نسخهٔ قبلی اینجا نگه داشته شد:</p><p><code>%s</code></p>"
#                       "<p class='muted'>این پنل هم دارد ری‌استارت می‌شود تا "
#                       "دیتابیس تازه را باز کند. چند ثانیه دیگر خودش برمی‌گردد.</p>"
#                       "<p><a href='/%s/users'>رفتن به کاربران</a></p></div>"
#                       % (html.escape(keep), p),
#                       CFG, "settings"),
#                  200, {"Refresh": "16; url=/%s/users" % p})
#        try:
#            self.wfile.flush()
#        except Exception:
#            pass
#        # This process still has the replaced file open, so the only honest way
#        # to pick up the new one is to let systemd start us again.
#        print("restarting after restore", flush=True)
#        threading.Timer(1.0, os._exit, (0,)).start()
#
#    @staticmethod
#    def one(params, key, default=""):
#        return (params.get(key) or [default])[0].strip()
#
#    # -- auth -------------------------------------------------------------
#    def session_token(self):
#        cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
#        return cookie["sdns"].value if "sdns" in cookie else ""
#
#    def session_ok(self):
#        token = self.session_token()
#        if not token:
#            return False
#        row = STORE.one("SELECT expires_at FROM admin_sessions WHERE token = ?",
#                        (token,))
#        if not row:
#            return False
#        if (parse_ts(row["expires_at"]) or datetime.now(timezone.utc))                 <= datetime.now(timezone.utc):
#            STORE.run("DELETE FROM admin_sessions WHERE token = ?", (token,))
#            return False
#        return True
#
#    def locked_out(self):
#        rec = ATTEMPTS.get(self.client_address[0])
#        if not rec:
#            return False
#        count, first = rec
#        if time.time() - first > LOCKOUT_SECONDS:
#            ATTEMPTS.pop(self.client_address[0], None)
#            return False
#        return count >= MAX_TRIES
#
#    def note_failure(self):
#        addr = self.client_address[0]
#        count, first = ATTEMPTS.get(addr, (0, time.time()))
#        ATTEMPTS[addr] = (count + 1, first)
#
#    # -- routing ----------------------------------------------------------
#    def route(self):
#        prefix = "/" + CFG["ADMIN_PATH"]
#        path = urllib.parse.urlparse(self.path).path
#        if not path.startswith(prefix):
#            return None
#        rest = path[len(prefix):].strip("/")
#        return rest
#
#    def lost(self):
#        """Answer a request that did not name the secret path.
#
#        A stranger gets a bare 404 and learns nothing - that is the whole
#        point of the path. Somebody already holding a valid session is not a
#        stranger: they have full access already, so sending them to the panel
#        reveals nothing and saves them from the commonest way to meet this
#        page, which is typing the host without the path, or following a
#        bookmark from before the path or port was changed.
#        """
#        if self.session_ok():
#            return self.redirect("")
#        # Its request line names the path and who asked, the secret part
#        # masked, so "it 404s sometimes" stays answerable.
#        return self.send("<h1>404</h1>", 404)
#
#    def do_GET(self):
#        rest = self.route()
#        if rest is None:
#            return self.lost()
#        if rest == "logout":
#            cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
#            if "sdns" in cookie:
#                STORE.run("DELETE FROM admin_sessions WHERE token = ?",
#                          (cookie["sdns"].value,))
#            return self.redirect("", {"Set-Cookie": "sdns=; Max-Age=0; Path=/"})
#        if rest.startswith("f/"):
#            return self.send_font(rest[len("f/"):])
#        if not self.session_ok():
#            return self.send(login_page(CFG))
#        if rest == "backup.db":
#            return self.send_backup()
#        if rest.startswith("receipt/"):
#            return self.send_receipt(rest.split("/", 1)[1])
#        try:
#            return self.view(rest)
#        except Exception as e:
#            log_exception("admin GET %s failed" % rest)
#            return self.send(page("خطا", "<div class='card'>%s</div>"
#                                  % html.escape(str(e)), CFG), 500)
#
#    def do_POST(self):
#        rest = self.route()
#        if rest is None:
#            return self.lost()
#        params = self.body_params()
#        if not self.session_ok():
#            if self.locked_out():
#                log(WARN, "admin login refused from %s: too many failed attempts"
#                    % self.client_address[0])
#                return self.send(login_page(
#                    CFG, "تلاش‌های ناموفق زیاد. چند دقیقه صبر کنید."))
#            given = self.one(params, "password")
#            want = CFG["ADMIN_HASH"]
#            if given and hmac.compare_digest(
#                    hash_password(given, CFG["ADMIN_SALT"]), want):
#                token = secrets.token_urlsafe(32)
#                STORE.run(
#                    "INSERT OR REPLACE INTO admin_sessions (token, expires_at)"
#                    " VALUES (?, ?)",
#                    (token, (datetime.now(timezone.utc)
#                             + timedelta(hours=SESSION_HOURS)).isoformat(
#                                 timespec="seconds")))
#                # Tidy up whatever has run out, so the table cannot grow
#                # forever on a panel that is logged into daily.
#                STORE.run("DELETE FROM admin_sessions WHERE expires_at <= ?",
#                          (now(),))
#                ATTEMPTS.pop(self.client_address[0], None)
#                log(INFO, "admin login from %s" % self.client_address[0])
#                return self.redirect("", {
#                    "Set-Cookie": "sdns=%s; Path=/; HttpOnly; Secure; SameSite=Strict"
#                                  % token})
#            self.note_failure()
#            if given:
#                log(WARN, "admin login failed from %s (%d in a row)"
#                    % (self.client_address[0],
#                       ATTEMPTS.get(self.client_address[0], (0, 0))[0]))
#            return self.send(login_page(CFG, "رمز اشتباه است."))
#        # What was done, before doing it - so an action that then fails is
#        # still on the record, next to the error it caused.
#        self._action = rest
#        log(INFO, "admin action %s%s" % (rest, describe(params)))
#        try:
#            return self.action(rest, params)
#        except Exception as e:
#            log_exception("admin POST %s failed" % rest)
#            return self.send(page("خطا", "<div class='card'>%s</div>"
#                                  % html.escape(str(e)), CFG), 500)
#
#    # -- views ------------------------------------------------------------
#    def view(self, rest):
#        msg = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("m")
#        msg = msg[0] if msg else None
#        kind = "err" if (msg or "").startswith("!") else "good"
#        msg = msg.lstrip("!") if msg else None
#        pages = {"": ("پنل مدیریت", self.home), "index": ("پنل مدیریت", self.home),
#                 "users": ("کاربران", self.users),
#                 "receipts": ("رسیدها", self.receipts),
#                 "templates": ("قالب‌ها", self.templates),
#                 "domains": ("دامنه‌ها", self.domains),
#                 "settings": ("تنظیمات", self.settings),
#                 "restore": ("بازگردانی", self.restore_page),
#                 "logs": ("لاگ", self.logs)}
#        if rest not in pages:
#            return self.lost()
#        title, fn = pages[rest]
#        active = "" if rest == "index" else rest
#        return self.send(page(title, fn(), CFG, active, msg, kind))
#
#    def home(self):
#        u = STORE.one("SELECT count(*) c, COALESCE(sum(used_bytes),0) b FROM users")
#        act = STORE.one("SELECT count(*) c FROM users WHERE status = 'active'")
#        ips = STORE.one("SELECT count(*) c FROM ips")
#        out = ["<div class='card'><h2>خلاصه</h2><div class='grid'>"]
#        for n, l in ((u["c"], "کاربر"), (act["c"], "فعال"),
#                     (ips["c"], "آی‌پی ثبت‌شده"), (human(u["b"]), "مجموع مصرف")):
#            out.append("<div class='stat'><div class='n'>%s</div>"
#                       "<div class='l'>%s</div></div>" % (html.escape(str(n)), l))
#        out.append("</div></div>")
#
#        rows = STORE.q("SELECT m.* FROM metrics m JOIN (SELECT host, MAX(at) at"
#                       " FROM metrics GROUP BY host) l"
#                       " ON l.host = m.host AND l.at = m.at ORDER BY m.host")
#        out.append("<div class='card'><h2>سرورها</h2>")
#        if not rows:
#            out.append("<p class='muted'>هنوز آماری نرسیده.</p>")
#        else:
#            out.append("<table><tr><th>سرور</th><th>CPU</th><th>RAM</th>"
#                       "<th>SWAP</th><th>دیسک</th><th>شبکه</th><th>روشن</th></tr>")
#            for r in rows:
#                seen = parse_ts(r["at"])
#                stale = ""
#                if seen and (datetime.now(timezone.utc) - seen).total_seconds() > 120:
#                    stale = " <span class='bad'>قطع</span>"
#                swap = (bar(r["swap_used"], r["swap_total"]) if r["swap_total"]
#                        else "<span class='muted'>ندارد</span>")
#                out.append(
#                    "<tr><td><code>%s</code>%s</td><td>%s%%</td><td>%s</td>"
#                    "<td>%s</td><td>%s</td>"
#                    "<td class='muted'>↓%s/s ↑%s/s</td>"
#                    "<td class='muted'>%d روز</td></tr>"
#                    % (html.escape(r["host"]), stale, r["cpu"],
#                       bar(r["mem_used"], r["mem_total"]), swap,
#                       bar(r["disk_used"], r["disk_total"]),
#                       human(r["rx_bps"]), human(r["tx_bps"]),
#                       (r["uptime"] or 0) // 86400))
#            out.append("</table>")
#        out.append("</div>")
#        return "".join(out)
#
#    def users(self):
#        tpls = STORE.q("SELECT * FROM templates ORDER BY id")
#        default = STORE.one("SELECT id FROM templates WHERE is_default = 1")
#        did = default["id"] if default else 0
#        rows = STORE.q("SELECT u.*, (SELECT ip FROM ips WHERE user_id = u.id LIMIT 1)"
#                       " ip FROM users u ORDER BY u.created_at DESC")
#        out = ["<div class='card'><h2>کاربران (%d)</h2>" % len(rows)]
#        if not rows:
#            return "".join(out) + "<p class='muted'>هنوز کسی ثبت‌نام نکرده.</p></div>"
#        out.append("<table><tr><th>نام کاربری</th><th>آی‌پی</th><th>مصرف</th>"
#                   "<th>سهمیه (گیگ)</th><th>سرعت Mb/s</th><th>زمان (روز)</th>"
#                   "<th>قالب</th><th>وضعیت</th><th></th></tr>")
#        p = CFG["ADMIN_PATH"]
#        for r in rows:
#            tid = r["template_id"] or did
#            sel = "".join("<option value='%d'%s>%s</option>"
#                          % (t["id"], " selected" if t["id"] == tid else "",
#                             html.escape(t["name"])) for t in tpls)
#            # "pending" is amber, not red: nothing is wrong with the
#            # account, it is only waiting for somebody here to give it a plan.
#            cls = {"active": "ok", "over_quota": "warn",
#                   "pending": "warn"}.get(r["status"], "bad")
#            label = {"active": "فعال", "pending": "در انتظار پلن",
#                     "over_quota": "سهمیه تمام شده", "expired": "منقضی",
#                     "suspended": "مسدود"}.get(r["status"], r["status"])
#            quota_gb = ("%.0f" % (r["quota_bytes"] / GB)) if r["quota_bytes"] else "0"
#            kbps = r["speed_kbps"] or 0
#            speed_mb = ("%g" % (kbps / 1000.0)) if kbps else "0"
#            left = remaining_days(r["expires_at"] or r["quota_reset_at"])
#            out.append(
#                "<tr><td><code>%s</code><br><span class='muted'>%s</span></td>"
#                "<td><code>%s</code></td><td>%s</td>"
#                "<td><form id='u%d' method='post' action='/%s/user-save'></form>"
#                "<input form='u%d' type='hidden' name='id' value='%d'>"
#                "<input form='u%d' name='quota_gb' value='%s' size='4'"
#                " title='گیگابایت، ۰=نامحدود'></td>"
#                "<td><input form='u%d' name='speed_mb' value='%s' size='4'"
#                " title='مگابیت بر ثانیه، ۰=بی‌حد'></td>"
#                "<td><input form='u%d' name='days' size='4' placeholder='%s'"
#                " title='از امروز چند روز دیگر'></td>"
#                "<td><form method='post' action='/%s/user-template'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<select name='template_id' onchange='this.form.submit()'>%s</select>"
#                "</form></td>"
#                "<td class='%s'>%s</td>"
#                "<td class='acts'><button form='u%d' title='ذخیره'>ثبت</button>"
#                "<form method='post' action='/%s/user-status'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<input type='hidden' name='to' value='%s'>"
#                "<button class='%s' title='%s'>%s</button></form>"
#                "<form method='post' action='/%s/user-reset'"
#                " onsubmit='return confirm(\"مصرف این کاربر صفر شود؟\")'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<button class='ghost' title='صفر کردن مصرف'>صفر</button></form>"
#                "</td></tr>"
#                # What a customer signs in with. Accounts opened before this
#                # was a username have a phone number instead, and the ones
#                # that came through the bot have neither - so the column shows
#                # whichever this account actually has.
#                % (html.escape(str(r["username"] or r["phone"]
#                                   or r["telegram_id"] or "#%d" % r["id"])),
#                   html.escape(r["first_name"] or ""),
#                   html.escape(r["ip"] or "-"), human(r["used_bytes"]),
#                   r["id"], p, r["id"], r["id"], r["id"], quota_gb,
#                   r["id"], speed_mb, r["id"], left,
#                   p, r["id"], sel, cls, html.escape(label),
#                   r["id"],
#                   p, r["id"],
#                   "active" if r["status"] == "suspended" else "suspended",
#                   "ghost" if r["status"] == "suspended" else "danger",
#                   "برگرداندن" if r["status"] == "suspended" else "مسدود کردن",
#                   "فعال" if r["status"] == "suspended" else "مسدود",
#                   p, r["id"]))
#        out.append("</table><p class='muted'>ثبت‌نام تازه با وضعیت «در انتظار "
#                   "پلن» می‌آید و تا وقتی برایش پلن ذخیره نکنید هیچ ترافیکی "
#                   "نمی‌گیرد؛ اولین ذخیرهٔ همین سطر فعالش می‌کند. "
#                   "صفر در سهمیه یا سرعت یعنی بی‌حد. "
#                   "«زمان» خالی یعنی بدون تغییر؛ عددی که بنویسید تاریخ پایان را "
#                   "از امروز همان‌قدر روز جلو می‌برد، و رنگ خاکستریِ داخلش روزهای "
#                   "باقی‌مانده است. سرعت فقط دانلود را محدود می‌کند و تا ۳۰ ثانیه "
#                   "دیگر روی رله‌ها اعمال می‌شود.</p></div>")
#        return "".join(out)
#
#    def templates(self):
#        """Two pages behind one path: the list, and one template's editor.
#
#        Editing is its own page because the editor carries a checkbox for every
#        domain in the catalogue - some five hundred of them. Rendering that
#        for every template at once would make a page several times the size,
#        opened over a connection from Iran, to show one template's detail.
#        """
#        wanted = urllib.parse.parse_qs(
#            urllib.parse.urlparse(self.path).query).get("t")
#        if wanted:
#            row = STORE.one("SELECT * FROM templates WHERE id = ?",
#                            (int(wanted[0]) if wanted[0].isdigit() else 0,))
#            if row:
#                return self.template_editor(row)
#        return self.template_list()
#
#    def template_list(self):
#        tpls = STORE.q("SELECT * FROM templates ORDER BY id")
#        default = STORE.one("SELECT id FROM templates WHERE is_default = 1")
#        did = default["id"] if default else 0
#        p = CFG["ADMIN_PATH"]
#        out = ["<div class='card'><h2>قالب‌ها</h2>"
#               "<table><tr><th>نام</th><th>کاربر</th><th>سرویس‌ها</th>"
#               "<th>دامنه‌ها</th><th></th></tr>"]
#        for t in tpls:
#            users = STORE.one("SELECT count(*) c FROM users"
#                              " WHERE COALESCE(template_id, ?) = ?",
#                              (did, t["id"]))["c"]
#            name = html.escape(t["name"])
#            if t["is_default"]:
#                out.append("<tr><td>%s <span class='muted'>(پیش‌فرض)</span></td>"
#                           "<td>%d</td><td colspan='2' class='muted'>همه، از جمله "
#                           "سرویس‌هایی که بعداً اضافه شوند</td><td></td></tr>"
#                           % (name, users))
#                continue
#            groups = STORE.template_groups(t["id"])
#            off = STORE.template_domains_off(t["id"])
#            n_groups = n_dom = total_dom = 0
#            for svc in catalogue_now():
#                for g in svc["groups"]:
#                    total_dom += len(g["domains"])
#                    if (svc["key"], g["key"]) in groups:
#                        n_groups += 1
#                        n_dom += sum(1 for d in g["domains"] if d not in off)
#            out.append("<tr><td>%s</td><td>%d</td><td>%d</td>"
#                       "<td>%d <span class='muted'>از %d</span></td>"
#                       "<td><a href='/%s/templates?t=%d'>ویرایش</a></td></tr>"
#                       % (name, users, n_groups, n_dom, total_dom, p, t["id"]))
#        out.append("</table></div>")
#        out.append("<div class='card'><h2>قالب تازه</h2>"
#                   "<form method='post' action='/%s/template-new' class='row'>"
#                   "<input name='name' placeholder='نام قالب'><button>ساختن</button>"
#                   "</form><p class='muted'>قالب تازه با همهٔ سرویس‌ها ساخته می‌شود؛ "
#                   "بعد تیک‌ها را بردارید. هر قالبِ در حال استفاده یک resolver روی هر "
#                   "رله است، پس حداکثر ۸ تا.</p></div>" % p)
#        return "".join(out)
#
#    def template_editor(self, t):
#        p = CFG["ADMIN_PATH"]
#        back = "<p><a href='/%s/templates'>‹ برگشت به فهرست قالب‌ها</a></p>" % p
#        if t["is_default"]:
#            return (back + "<div class='card'><h2>%s (پیش‌فرض)</h2>"
#                    "<p class='muted'>قالب پیش‌فرض همیشه همهٔ سرویس‌ها را از رله "
#                    "می‌برد، از جمله سرویس‌هایی که بعداً اضافه شوند. برای همین "
#                    "قابل ویرایش نیست — یک قالب تازه بسازید.</p>"
#                    "<p class='muted'>یک استثنا: گروه‌هایی که «پیش‌فرض خاموش» "
#                    "علامت خورده‌اند، حتی در این قالب هم مسیریابی نمی‌شوند. "
#                    "برای روشن کردنشان یک قالب تازه بسازید و آنجا تیکشان بزنید."
#                    "</p></div>"
#                    % html.escape(t["name"]))
#
#        groups = STORE.template_groups(t["id"])
#        off = STORE.template_domains_off(t["id"])
#        out = [back,
#               "<div class='card'><h2>%s</h2>" % html.escape(t["name"]),
#               "<p class='muted'>تیک سرویس یعنی همهٔ دامنه‌هایش از رله می‌رود — "
#               "از جمله دامنه‌هایی که بعداً به آن اضافه شوند. کشو را باز کنید تا "
#               "بین دامنه‌ها یکی‌یکی انتخاب کنید.</p>",
#               "<form method='post' action='/%s/template-save'>"
#               "<input type='hidden' name='id' value='%d'>" % (p, t["id"])]
#
#        for svc in catalogue_now():
#            for g in svc["groups"]:
#                key = "%s.%s" % (svc["key"], g["key"])
#                on = (svc["key"], g["key"]) in groups
#                label = (svc["label"] if len(svc["groups"]) == 1
#                         else "%s — %s" % (svc["label"], g["label"]))
#                # An opt-in group is one where routing is the wrong default,
#                # not a matter of taste. Say why, next to the tick, rather
#                # than letting it look like every other box on the page.
#                if g.get("opt_in"):
#                    # The reason comes from the group, not from here. These
#                    # are switched off for four different reasons and only one
#                    # of them is matchmaking - a warning that says the same
#                    # thing about all of them is wrong about three.
#                    label += ("<span class='optin'>پیش‌فرض خاموش — %s</span>"
#                              % html.escape(g.get("note") or
#                                            "روشن کردنش چیزی را می‌شکند"))
#                kept = [d for d in g["domains"] if d not in off]
#                # Open the drawer when the operator has already been in here
#                # picking domains, so their exceptions are visible rather than
#                # hidden behind a summary that looks like every other one.
#                partial = on and len(kept) != len(g["domains"])
#                out.append(
#                    "<details class='svc'%s><summary>"
#                    "<label><input type='checkbox' name='g' value='%s'%s> %s</label>"
#                    "<span class='muted count'>%d از %d دامنه</span>"
#                    "<span class='pick'><button type='button' data-all='1'>همه</button>"
#                    "<button type='button' data-all='0'>هیچ‌کدام</button></span>"
#                    "</summary>"
#                    % (" open" if partial else "", html.escape(key),
#                       " checked" if on else "", label,
#                       len(kept) if on else 0, len(g["domains"])))
#                if not g["domains"]:
#                    out.append("<p class='muted'>دامنه‌ای ندارد.</p>")
#                out.append("<div class='doms'>")
#                for d in sorted(g["domains"]):
#                    # A tick on this page means "routed". Inside a group that
#                    # is switched off nothing is routed, so nothing there is
#                    # ticked - otherwise the drawer contradicts the summary
#                    # beside it, which already says 0 of however many.
#                    out.append("<label><input type='checkbox' name='d' value='%s'%s>"
#                               "<span>%s</span></label>"
#                               % (html.escape(d),
#                                  " checked" if on and d not in off else "",
#                                  html.escape(d)))
#                out.append("</div></details>")
#
#        out.append("<div style='margin-top:16px'><button>ذخیره</button> "
#                   "<button class='danger' formaction='/%s/template-delete' "
#                   "formnovalidate>حذف قالب</button></div></form></div>" % p)
#        # Convenience only. Every checkbox above is a plain form control, so
#        # the page works with this script blocked or broken - it just means
#        # ticking five hundred boxes by hand.
#        out.append("""<script>
#(function () {
#  function count(d) {
#    var boxes = d.querySelectorAll('.doms input');
#    var on = d.querySelectorAll('.doms input:checked').length;
#    var g = d.querySelector('summary input[name=g]');
#    var label = d.querySelector('.count');
#    if (label) label.textContent = (g.checked ? on : 0) + ' از ' + boxes.length + ' دامنه';
#  }
#  document.addEventListener('click', function (e) {
#    var b = e.target.closest('.pick button');
#    if (b) {
#      // Inside a <summary>, so the drawer would otherwise open and close
#      // under the operator every time they pressed one of these.
#      e.preventDefault();
#      e.stopPropagation();
#      var d = b.closest('details'), all = b.dataset.all === '1';
#      d.querySelectorAll('.doms input').forEach(function (i) { i.checked = all; });
#      // No domains and the service still ticked would be a tick that routes
#      // nothing, so the two move together.
#      d.querySelector('summary input[name=g]').checked = all;
#      return count(d);
#    }
#    if (e.target.matches('summary input[name=g]')) {
#      e.stopPropagation();
#      var d3 = e.target.closest('details');
#      var boxes = d3.querySelectorAll('.doms input');
#      // Ticking a service means all of it. The drawer is for taking things
#      // out afterwards, not for putting five hundred domains in by hand.
#      if (e.target.checked) {
#        var any = d3.querySelectorAll('.doms input:checked').length;
#        if (!any) boxes.forEach(function (i) { i.checked = true; });
#      } else {
#        boxes.forEach(function (i) { i.checked = false; });
#      }
#      return count(d3);
#    }
#    if (e.target.matches('.doms input')) {
#      var d2 = e.target.closest('details');
#      // Ticking a domain in a service that is switched off is a request for
#      // that service, so switch it on rather than silently ignoring it.
#      if (e.target.checked) d2.querySelector('summary input[name=g]').checked = true;
#      count(d2);
#    }
#  });
#})();
#</script>""")
#        return "".join(out)
#
#    def domains(self):
#        rows = STORE.q("SELECT * FROM custom_domains ORDER BY added_at DESC")
#        shipped = sum(len(g["domains"]) for s in CATALOGUE for g in s["groups"])
#        p = CFG["ADMIN_PATH"]
#        out = ["<div class='card'><h2>دامنه‌های شما (%d)</h2>" % len(rows),
#               "<form method='post' action='/%s/domain-add' class='row' "
#               "style='margin-bottom:14px'>"
#               "<input name='domain' placeholder='example.com' style='min-width:220px'>"
#               "<input name='note' placeholder='یادداشت (اختیاری)'>"
#               "<button>افزودن</button></form>" % p]
#        if rows:
#            out.append("<table><tr><th>دامنه</th><th>یادداشت</th><th>افزوده</th>"
#                       "<th></th></tr>")
#            for r in rows:
#                out.append("<tr><td><code>%s</code></td><td class='muted'>%s</td>"
#                           "<td class='muted'>%s</td>"
#                           "<td><form method='post' action='/%s/domain-del'>"
#                           "<input type='hidden' name='domain' value='%s'>"
#                           "<button class='danger'>حذف</button></form></td></tr>"
#                           % (html.escape(r["domain"]), html.escape(r["note"] or ""),
#                              (r["added_at"] or "")[:10], p, html.escape(r["domain"])))
#            out.append("</table>")
#        out.append("<p class='muted'>زیردامنه‌ها خودکار شامل می‌شوند. این‌ها در سرویس "
#                   "«دامنه‌های دلخواه» جمع می‌شوند، پس در هر قالب می‌شود تیکشان را "
#                   "برداشت. به‌علاوهٔ %d دامنه‌ای که با نصاب می‌آید.</p></div>" % shipped)
#        return "".join(out)
#
#    def settings(self):
#        p = CFG["ADMIN_PATH"]
#        out = []
#        out.append(
#            "<div class='card'><h2>نسخهٔ پشتیبان</h2>"
#            "<p class='muted'>یک فایل sqlite با همهٔ کاربران، آی‌پی‌ها، قالب‌ها، "
#            "تراکنش‌ها و تنظیمات. آمار سلامت سرورها داخلش نیست — حجم زیادی است "
#            "و ارزشی در بازگردانی ندارد.</p>"
#            "<p><a class='dl' href='/%s/backup.db'>دانلود نسخهٔ پشتیبان</a></p>"
#            "<h2 style='margin-top:22px'>بازگردانی</h2>"
#            "<form method='post' action='/%s/restore' enctype='multipart/form-data' "
#            "class='row'><input type='file' name='file' accept='.db' required>"
#            "<button class='ghost'>بررسی فایل</button></form>"
#            "<p class='muted'>فایل اول فقط بررسی و توصیف می‌شود؛ جایگزینی جدا "
#            "تأیید می‌خواهد.</p></div>" % (p, p))
#
#        out.append("<div class='card'><h2>آدرس این پنل</h2>"
#                   "<p class='muted'>همین حالا: <code>https://%s:%s/%s/</code></p>"
#                   "<div class='f'><label>پورت</label>"
#                   "<form method='post' action='/%s/panel-port' class='row'>"
#                   "<input name='port' value='%s' size='6'>"
#                   "<button class='ghost'>تغییر پورت</button></form></div>"
#                   "<div class='f'><label>مسیر مخفی</label>"
#                   "<form method='post' action='/%s/panel-path' class='row'>"
#                   "<input name='path' value='%s' style='min-width:280px'>"
#                   "<button class='ghost'>تغییر مسیر</button>"
#                   "<button class='ghost' name='random' value='1'>مسیر تصادفی</button>"
#                   "</form></div>"
#                   "<div class='msg err'>پورت را که عوض کنید، پنل روی پورت تازه "
#                   "بالا می‌آید — ولی اگر سرور فایروال یا security group دارد "
#                   "(روی AWS، Hetzner و مانندش) باید پورت تازه را <b>اول</b> "
#                   "آنجا باز کنید، وگرنه از بیرون در دسترس نخواهد بود. اگر "
#                   "بیرون ماندید، از روی خود سرور: <code>smartdns-access port "
#                   "9443</code></div></div>"
#                   % (html.escape(panel_host()), html.escape(CFG["ADMIN_PORT"]),
#                      html.escape(CFG["ADMIN_PATH"]),
#                      p, html.escape(CFG["ADMIN_PORT"]),
#                      p, html.escape(CFG["ADMIN_PATH"])))
#
#        out.append("<div class='card'><h2>رمز این پنل</h2>"
#                   "<form method='post' action='/%s/password'>"
#                   "<div class='f'><label>رمز تازه (دست‌کم ۸ نویسه)</label>"
#                   "<input type='password' name='password' style='width:100%%'>"
#                   "</div>"
#                   "<div class='f'><label>تکرار رمز تازه</label>"
#                   "<input type='password' name='again' style='width:100%%'>"
#                   "</div><button>تغییر رمز</button></form>"
#                   "<p class='muted'>رمز ذخیره نمی‌شود، فقط هشش. با تغییر آن "
#                   "همهٔ نشست‌های دیگر بسته می‌شوند.</p></div>" % p)
#        out.append(bot_card())
#        return "".join(out)
#
#    def logs(self):
#        out = []
#        for unit in ("smartdns-panel", "smartdns-admin"):
#            try:
#                txt = subprocess.run(
#                    ["journalctl", "-u", unit, "-n", "60", "--no-pager",
#                     "--output=cat"], capture_output=True, text=True,
#                    timeout=20).stdout
#            except Exception as e:
#                txt = str(e)
#            out.append("<div class='card'><h2>%s</h2><pre style='overflow-x:auto;"
#                       "font-size:12px;color:#9aa4b2;white-space:pre-wrap'>%s</pre>"
#                       "</div>" % (unit, html.escape(txt or "(چیزی نیست)")))
#        return "".join(out)
#
#    # -- actions ----------------------------------------------------------
#    def action(self, rest, params):
#        one = lambda k, d="": self.one(params, k, d)
#
#        if rest == "user-save":
#            uid = int(one("id") or 0)
#            gb = one("quota_gb", "0")
#            days = one("days")
#            try:
#                quota = int(float(gb) * GB) if gb else 0
#            except ValueError:
#                return self.redirect("users?m=!عدد سهمیه درست نیست")
#            # Signing up gets an account, not traffic. Somebody has to decide
#            # this customer may connect, and this form - opening their row and
#            # giving them a plan - is that decision. Read the status before
#            # the writes below, because one of them can change it.
#            was = STORE.one("SELECT status FROM users WHERE id = ?", (uid,))
#            joining = bool(was) and was["status"] == "pending"
#            # Clearing the warning bits matters: a user raised above a
#            # threshold they had already crossed would otherwise never be
#            # warned again.
#            STORE.run("UPDATE users SET quota_bytes = ?, warned = 0,"
#                      " status = CASE WHEN status = 'over_quota' THEN 'active'"
#                      " ELSE status END WHERE id = ?", (quota, uid))
#            if "speed_mb" in params:
#                try:
#                    mb = float(one("speed_mb", "0") or 0)
#                except ValueError:
#                    return self.redirect("users?m=!عدد سرعت درست نیست")
#                if mb < 0:
#                    return self.redirect("users?m=!سرعت منفی نمی‌شود")
#                STORE.run("UPDATE users SET speed_kbps = ? WHERE id = ?",
#                          (int(mb * 1000), uid))
#            if days:
#                try:
#                    count = float(days)
#                except ValueError:
#                    return self.redirect("users?m=!تعداد روز درست نیست")
#                if count < 0:
#                    return self.redirect("users?m=!تعداد روز منفی نمی‌شود")
#                if count == 0:
#                    # No end date at all. The account then ends only when its
#                    # allowance does, which is what an operator means by
#                    # putting zero in a box that everywhere else on this page
#                    # means "no limit".
#                    STORE.run("UPDATE users SET expires_at = NULL,"
#                              " quota_reset_at = NULL, quota_mode = 'oneoff',"
#                              " status = CASE WHEN status = 'expired' THEN 'active'"
#                              " ELSE status END WHERE id = ?", (uid,))
#                    if joining:
#                        STORE.run("UPDATE users SET status = 'active'"
#                                  " WHERE id = ?", (uid,))
#                        tell(uid, MSG_ACTIVATED)
#                    return self.redirect(
#                        "users?m=ذخیره شد؛ بدون محدودیت زمانی"
#                        + ("؛ حساب فعال شد" if joining else ""))
#                when = datetime.now(timezone.utc) + timedelta(days=count)
#                stamp = when.isoformat(timespec="seconds")
#                row = STORE.one("SELECT quota_mode FROM users WHERE id = ?", (uid,))
#                if row and row["quota_mode"] == "monthly":
#                    # A renewing plan: the number moves its next reset rather
#                    # than ending it, which is what renewing means.
#                    STORE.run("UPDATE users SET quota_reset_at = ?"
#                              " WHERE id = ?", (stamp, uid))
#                else:
#                    # Everything else gets an end date that many days out, and
#                    # comes back if it had already run out - which is the whole
#                    # reason an operator types in this box. This used to key
#                    # off whether the account already had a date, which worked
#                    # only because every account started as a dated trial.
#                    STORE.run("UPDATE users SET expires_at = ?,"
#                              " status = CASE WHEN status = 'expired' THEN 'active'"
#                              " ELSE status END WHERE id = ?", (stamp, uid))
#            if joining:
#                STORE.run("UPDATE users SET status = 'active' WHERE id = ?",
#                          (uid,))
#                tell(uid, MSG_ACTIVATED)
#                return self.redirect("users?m=ذخیره شد؛ حساب فعال شد")
#            return self.redirect("users?m=ذخیره شد")
#
#        if rest == "receipt-decide":
#            tid = int(one("id") or 0)
#            to = one("to")
#            if to not in ("approved", "rejected"):
#                return self.redirect("receipts?m=!تصمیم نامعتبر")
#            # The image goes with the decision. It was evidence for a judgement
#            # that has now been made, and keeping every customer's bank slip
#            # for ever is a liability rather than a record.
#            # settled = 0 hands the rest to smartdns-panel and the bot: a
#            # receipt sent for a plan gets that plan applied, and a customer
#            # with a Telegram is told either way.
#            STORE.run("UPDATE transactions SET status = ?, decided_at = ?,"
#                      " receipt_blob = NULL, settled = 0 WHERE id = ?",
#                      (to, now(), tid))
#            plan = STORE.one("SELECT p.name FROM transactions t JOIN plans p"
#                             " ON p.id = t.plan_id WHERE t.id = ?", (tid,))
#            if to == "approved" and plan:
#                done = ("رسید تأیید شد؛ پلن «%s» تا چند ثانیه دیگر روی حساب اعمال می‌شود"
#                        % plan["name"])
#            elif to == "approved":
#                done = "رسید تأیید شد؛ حالا سهمیه و زمانش را بگذارید"
#            else:
#                done = "رسید رد شد"
#            return self.redirect("receipts?m=%s" % done)
#
#        if rest == "user-status":
#            uid = int(one("id") or 0)
#            to = one("to")
#            if to not in ("active", "suspended"):
#                return self.redirect("users?m=!وضعیت نامعتبر")
#            # Clearing the warning bits on the way back in: an account that
#            # crossed a threshold while blocked would otherwise never warn
#            # again once it is working.
#            STORE.run("UPDATE users SET status = ?, warned = CASE WHEN ? = 'active'"
#                      " THEN 0 ELSE warned END WHERE id = ?", (to, to, uid))
#            return self.redirect(
#                "users?m=%s" % ("کاربر مسدود شد؛ تا ۳۰ ثانیه دیگر قطع می‌شود"
#                                if to == "suspended" else "کاربر برگشت"))
#
#        if rest == "user-reset":
#            uid = int(one("id") or 0)
#            # The kernel counters on the relays are not touched. Usage here is
#            # the growth of those counters since the last sync, so zeroing the
#            # total is enough - the next sync adds only what has happened
#            # since, not the whole counter again.
#            STORE.run("UPDATE users SET used_bytes = 0, warned = 0,"
#                      " status = CASE WHEN status = 'over_quota' THEN 'active'"
#                      " ELSE status END WHERE id = ?", (uid,))
#            return self.redirect("users?m=مصرف صفر شد")
#
#        if rest == "user-template":
#            STORE.run("UPDATE users SET template_id = ? WHERE id = ?",
#                      (int(one("template_id") or 0), int(one("id") or 0)))
#            return self.redirect("users?m=قالب عوض شد؛ تا ۳۰ ثانیه دیگر روی رله‌ها اعمال می‌شود")
#
#        if rest == "template-new":
#            name = one("name")
#            if not name:
#                return self.redirect("templates?m=!نام لازم است")
#            count = STORE.one("SELECT count(*) c FROM templates")["c"]
#            if count >= 8:
#                return self.redirect("templates?m=!سقف ۸ قالب پر است؛ هر قالب یک "
#                                     "resolver روی هر رله است")
#            try:
#                cur = STORE.run("INSERT INTO templates (name, is_default, created_at)"
#                                " VALUES (?, 0, ?)", (name, now()))
#            except sqlite3.IntegrityError:
#                return self.redirect("templates?m=!قالبی با این نام هست")
#            # Everything except the opt-in groups. A new template starting
#            # with those already ticked would be the panel deciding something
#            # it just told the operator was theirs to decide.
#            skipped = 0
#            for svc in CATALOGUE:
#                for g in svc["groups"]:
#                    if g.get("opt_in"):
#                        skipped += 1
#                        continue
#                    STORE.run("INSERT OR IGNORE INTO template_services"
#                              " (template_id, service_key, group_key) VALUES (?,?,?)",
#                              (cur.lastrowid, svc["key"], g["key"]))
#            return self.redirect(
#                "templates?t=%d&m=قالب ساخته شد با همهٔ سرویس‌ها%s"
#                % (cur.lastrowid,
#                   "؛ %d گروهِ «پیش‌فرض خاموش» تیک نخورد" % skipped
#                   if skipped else ""))
#
#        if rest == "template-save":
#            tid = int(one("id") or 0)
#            if STORE.one("SELECT is_default FROM templates WHERE id = ?",
#                         (tid,))["is_default"]:
#                return self.redirect("templates?m=!قالب پیش‌فرض قابل تغییر نیست")
#            wanted = set(params.get("g") or [])
#            # Checkboxes only report what is ticked, so the off-list is worked
#            # out by subtraction: every domain in a routed group that did not
#            # come back.
#            keep = set(params.get("d") or [])
#            STORE.run("DELETE FROM template_services WHERE template_id = ?", (tid,))
#            STORE.run("DELETE FROM template_domains_off WHERE template_id = ?", (tid,))
#            for svc in catalogue_now():
#                for g in svc["groups"]:
#                    if "%s.%s" % (svc["key"], g["key"]) not in wanted:
#                        continue
#                    STORE.run("INSERT OR IGNORE INTO template_services"
#                              " (template_id, service_key, group_key) VALUES (?,?,?)",
#                              (tid, svc["key"], g["key"]))
#                    # A ticked service with none of its domains ticked is a
#                    # tick that routes nothing, which nobody means. It is what
#                    # the form sends when the helper script is blocked, so
#                    # read it the only way it makes sense: all of them.
#                    picked = keep.intersection(g["domains"]) or set(g["domains"])
#                    for d in g["domains"]:
#                        if d not in picked:
#                            STORE.run("INSERT OR IGNORE INTO template_domains_off"
#                                      " (template_id, domain) VALUES (?, ?)", (tid, d))
#            return self.redirect("templates?t=%d&m=ذخیره شد؛ تا ۳۰ ثانیه دیگر روی "
#                                 "رله‌ها اعمال می‌شود" % tid)
#
#        if rest == "template-delete":
#            tid = int(one("id") or 0)
#            row = STORE.one("SELECT is_default FROM templates WHERE id = ?", (tid,))
#            if not row or row["is_default"]:
#                return self.redirect("templates?m=!قالب پیش‌فرض حذف نمی‌شود")
#            # Move anyone on it back to the default first, so nobody is left
#            # pointing at a template that no longer exists.
#            default = STORE.one("SELECT id FROM templates WHERE is_default = 1")
#            STORE.run("UPDATE users SET template_id = ? WHERE template_id = ?",
#                      (default["id"] if default else None, tid))
#            STORE.run("DELETE FROM template_services WHERE template_id = ?", (tid,))
#            STORE.run("DELETE FROM templates WHERE id = ?", (tid,))
#            return self.redirect("templates?m=قالب حذف شد و کاربرانش به پیش‌فرض برگشتند")
#
#        if rest == "domain-add":
#            raw = one("domain")
#            try:
#                domain = clean_domain(raw)
#            except ValueError as e:
#                return self.redirect("domains?m=!%s" % e)
#            for svc in CATALOGUE:
#                for grp in svc["groups"]:
#                    if domain in grp["domains"]:
#                        return self.redirect(
#                            "domains?m=!%s از قبل در سرویس %s هست"
#                            % (domain, svc["label"]))
#            if STORE.one("SELECT 1 FROM custom_domains WHERE domain = ?", (domain,)):
#                return self.redirect("domains?m=!%s از قبل اضافه شده" % domain)
#            STORE.run("INSERT INTO custom_domains (domain, note, added_at)"
#                      " VALUES (?, ?, ?)", (domain, one("note") or None, now()))
#            return self.redirect("domains?m=%s اضافه شد" % domain)
#
#        if rest == "domain-del":
#            STORE.run("DELETE FROM custom_domains WHERE domain = ?", (one("domain"),))
#            return self.redirect("domains?m=حذف شد")
#
#        if rest == "restore":
#            return self.take_upload()
#
#        if rest == "restore-apply":
#            return self.apply_restore()
#
#        if rest == "restore-cancel":
#            path = PENDING.pop("path", None)
#            PENDING.clear()
#            if path and os.path.exists(path):
#                os.unlink(path)
#            return self.redirect("settings?m=بازگردانی لغو شد")
#
#        if rest == "panel-port":
#            port = one("port")
#            if not port.isdigit() or not 1 <= int(port) <= 65535:
#                return self.redirect("settings?m=!پورت باید عددی بین ۱ تا ۶۵۵۳۵ باشد")
#            if int(port) in RESERVED_PORTS:
#                return self.redirect(
#                    "settings?m=!پورت %s برای %s است"
#                    % (port, RESERVED_PORTS[int(port)]))
#            if port == CFG["ADMIN_PORT"]:
#                return self.redirect("settings?m=همان پورت قبلی است")
#            set_config_key("ADMIN_PORT", port)
#            CFG["ADMIN_PORT"] = port
#            return self.moving_to(port, CFG["ADMIN_PATH"])
#
#        if rest == "panel-path":
#            new = secrets.token_hex(12) if one("random") else one("path")
#            if not re.match(r"^[A-Za-z0-9_-]{8,64}$", new):
#                return self.redirect(
#                    "settings?m=!مسیر باید ۸ تا ۶۴ نویسه از حروف، رقم، - و _ باشد")
#            if new == CFG["ADMIN_PATH"]:
#                return self.redirect("settings?m=همان مسیر قبلی است")
#            set_config_key("ADMIN_PATH", new)
#            CFG["ADMIN_PATH"] = new
#            return self.moving_to(CFG["ADMIN_PORT"], new)
#
#        if rest == "password":
#            new = one("password")
#            # Asked twice, because it cannot be read back to check afterwards
#            # and a typo here locks the operator out of their own panel.
#            if new != one("again"):
#                return self.redirect("settings?m=!دو رمز یکی نیستند")
#            if len(new) < 8:
#                return self.redirect("settings?m=!رمز باید حداقل ۸ نویسه باشد")
#            salt = secrets.token_hex(16)
#            digest = hash_password(new, salt)
#            set_config_key("ADMIN_SALT", salt)
#            set_config_key("ADMIN_HASH", digest)
#            CFG["ADMIN_SALT"], CFG["ADMIN_HASH"] = salt, digest
#            # Everyone else holding a session was authenticated with the old
#            # password; a password change should end those.
#            STORE.run("DELETE FROM admin_sessions WHERE token != ?",
#                      (self.session_token(),))
#            return self.redirect("settings?m=رمز عوض شد")
#
#        if rest == "bot-token":
#            if one("clear"):
#                set_setting("bot_token", "")
#                set_setting("bot_username", "")
#                return self.redirect("settings?m=ربات قطع شد")
#            token = one("bot_token").strip()
#            if not BOT_TOKEN_RE.match(token):
#                return self.redirect("settings?m=!این توکن درست نیست؛ همان را که "
#                                     "BotFather داد کامل بگذارید")
#            if token != setting("bot_token"):
#                set_setting("bot_token", token)
#                set_setting("bot_username", "")
#            new_admin_code()
#            return self.redirect("settings?m=توکن ذخیره شد؛ ربات تا چند ثانیه دیگر وصل می‌شود")
#
#        if rest == "bot-code":
#            new_admin_code()
#            return self.redirect("settings?m=کد مدیریت تازه ساخته شد")
#
#        if rest == "bot-admin-del":
#            gone = one("id").strip()
#            set_setting("bot_admins", ",".join(
#                a.strip() for a in setting("bot_admins").split(",")
#                if a.strip() and a.strip() != gone))
#            return self.redirect("settings?m=مدیر ربات حذف شد")
#
#        return self.lost()
#
#
#DOMAIN_RE = __import__("re").compile(
#    r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
#FORBIDDEN = ("localhost", "local", "internal", "arpa", "telegram.org",
#             "t.me", "telegram.me")
#
#
#def clean_domain(raw):
#    """Same normalisation the bot does, so a domain added here and one added
#    there end up identical rather than as two rows differing by a www."""
#    import re
#    d = (raw or "").strip().lower()
#    d = re.sub(r"^[a-z]+://", "", d)
#    d = d.split("/")[0].split("?")[0].split("@")[-1].split(":")[0].strip(".")
#    if not d:
#        raise ValueError("خالی است")
#    if not DOMAIN_RE.match(d):
#        raise ValueError("قالب دامنه درست نیست")
#    if any(d == f or d.endswith("." + f) for f in FORBIDDEN):
#        raise ValueError("این دامنه را نمی‌شود مسیر داد")
#    return d
#
#
## ------------------------------------------------------------ telegram bot
## The bot is smartdns-bot, reading its settings from this same database. This
## panel only sets them - the token, and who may become the bot's admin - and
## queues a message when it changes an account; it never talks to Telegram.
#BOT_TOKEN_RE = re.compile(r"^\d{5,15}:[A-Za-z0-9_-]{30,64}$")
#MSG_ACTIVATED = ("✅ حساب شما فعال شد.\n"
#                 "اگر هنوز آی‌پی اینترنتتان را ثبت نکرده‌اید، از «🌐 ثبت آی‌پی» ثبتش کنید.")
#
#
#def setting(key, default=""):
#    row = STORE.one("SELECT value FROM settings WHERE key = ?", (key,))
#    return row["value"] if row else default
#
#
#def set_setting(key, value):
#    STORE.run("INSERT INTO settings (key, value) VALUES (?, ?)"
#              " ON CONFLICT(key) DO UPDATE SET value = excluded.value",
#              (key, str(value)))
#
#
#def new_admin_code(hours=24):
#    # The same shape smartdns-panel's new_admin_code writes, which the bot reads.
#    until = (datetime.now(timezone.utc) + timedelta(hours=hours)).isoformat(
#        timespec="seconds")
#    code = secrets.token_hex(4)
#    set_setting("bot_admin_code", "%s|%s" % (code, until))
#    return code
#
#
#def mask_token(token):
#    return (token[:6] + "…" + token[-4:]) if len(token) > 12 else "…"
#
#
#def tell(user_id, text):
#    """Queue a Telegram message for an account, if it has a Telegram."""
#    try:
#        STORE.run("INSERT INTO outbox (chat_id, text, created_at)"
#                  " SELECT telegram_id, ?, ? FROM users"
#                  " WHERE id = ? AND telegram_id IS NOT NULL",
#                  (text, now(), user_id))
#    except sqlite3.OperationalError as e:
#        log(WARN, "message for user %d not queued: %s" % (user_id, e))
#
#
#def bot_card():
#    """The Telegram bot: its token, the code that makes somebody its admin,
#    and who already is. Plans, the card number and Zibal are set inside
#    the bot itself, where the operator who sells is."""
#    p = CFG["ADMIN_PATH"]
#    token = setting("bot_token")
#    name = setting("bot_username")
#    admins = [a.strip() for a in setting("bot_admins").split(",") if a.strip()]
#    code, _, until = setting("bot_admin_code").partition("|")
#    due = parse_ts(until)
#    live = bool(code) and bool(due) and due > datetime.now(timezone.utc)
#    out = ["<div class='card'><h2>ربات تلگرام</h2>"]
#    if token:
#        out.append("<p>ربات: <b>%s</b> · توکن: <code dir='ltr'>%s</code></p>"
#                   % (html.escape("@" + name if name else "در حال اتصال…"),
#                      html.escape(mask_token(token))))
#    else:
#        out.append("<p class='muted'>هنوز رباتی وصل نیست. در تلگرام با "
#                   "<code>@BotFather</code> یک ربات بسازید و توکنش را اینجا "
#                   "بگذارید.</p>")
#    out.append("<form method='post' action='/%s/bot-token' class='row'>"
#               "<input name='bot_token' placeholder='123456789:AA...' dir='ltr'"
#               " autocomplete='off' style='min-width:280px'>"
#               "<button>%s</button></form>"
#               % (p, "عوض کردن توکن" if token else "ذخیرهٔ توکن"))
#    if token:
#        if live:
#            out.append("<div class='msg good'>برای مدیر ربات شدن، این را به ربات "
#                       "بفرستید: <code dir='ltr'>/admin %s</code><br>"
#                       "<span class='muted'>یک بار کار می‌کند و تا %s (UTC) "
#                       "معتبر است.</span></div>"
#                       % (html.escape(code), html.escape(until[:16].replace("T", " "))))
#        out.append("<form method='post' action='/%s/bot-code' class='row'>"
#                   "<button class='ghost'>کد مدیریت تازه</button></form>" % p)
#        out.append("<h2 style='margin-top:18px'>مدیرهای ربات</h2>")
#        if not admins:
#            out.append("<p class='muted'>هنوز کسی مدیر ربات نشده.</p>")
#        for a in admins:
#            out.append("<form method='post' action='/%s/bot-admin-del' class='row'>"
#                       "<code dir='ltr'>%s</code><input type='hidden' name='id' value='%s'>"
#                       "<button class='danger'>حذف</button></form>"
#                       % (p, html.escape(a), html.escape(a)))
#        out.append("<form method='post' action='/%s/bot-token' class='row'"
#                   " style='margin-top:14px' onsubmit='return confirm(\"ربات قطع شود؟\")'>"
#                   "<input type='hidden' name='clear' value='1'>"
#                   "<button class='danger'>قطع ربات</button></form>" % p)
#    out.append("<p class='muted'>پلن‌ها، شمارهٔ کارت و مرچنت زیبال از داخل خود "
#               "ربات، در منوی «🛠 مدیریت»، تنظیم می‌شوند.</p></div>")
#    return "".join(out)
#
#
#def set_config_key(key, value):
#    """Rewrite one key in admin.env, leaving the rest of the file alone."""
#    lines = []
#    if os.path.exists(CONFIG):
#        with open(CONFIG) as fh:
#            lines = [l for l in fh.read().split("\n") if not l.startswith(key + "=")]
#    lines = [l for l in lines if l.strip()]
#    lines.append("%s=%s" % (key, value))
#    tmp = CONFIG + ".tmp"
#    with open(tmp, "w") as fh:
#        fh.write("\n".join(lines) + "\n")
#    os.chmod(tmp, 0o600)
#    os.replace(tmp, CONFIG)
#
#
#def make_admin_server(ctx, port):
#    return TLSServer(("0.0.0.0", port), Admin, ctx)
#
#
#def main():
#    global STORE, CFG, CATALOGUE
#    CFG = load_config()
#    CATALOGUE = load_catalogue()
#    STORE = Store(DB)
#
#    port = int(CFG["ADMIN_PORT"])
#    cert = CFG.get("ADMIN_CERT")
#    key = CFG.get("ADMIN_KEY")
#    if cert and key and os.path.exists(cert):
#        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
#        ctx.load_cert_chain(cert, key)
#        httpd = make_admin_server(ctx, port)
#        scheme = "https"
#    else:
#        # Refuse rather than silently serve a login form in the clear: the
#        # password would cross the network readable by anyone on the path.
#        sys.exit("no certificate at %s - refusing to serve the panel over plain "
#                 "http" % cert)
#    print("admin panel up on %s://0.0.0.0:%d/%s/"
#          % (scheme, port, CFG["ADMIN_PATH"]), flush=True)
#    httpd.serve_forever()
#
#
#if __name__ == "__main__":
#    main()
#__END_ADMIN__

#__BEGIN_ADMIN_SERVICE__
#[Unit]
#Description=Smart DNS admin web panel
#After=network-online.target smartdns-panel.service
#
#[Service]
#Type=simple
#ExecStart=/usr/local/bin/smartdns-admin
#Restart=always
#RestartSec=10
## Reads the certificate and writes admin.env when the password changes, so it
## needs root - but nothing else on the box.
#NoNewPrivileges=yes
#ProtectHome=yes
#PrivateTmp=yes
#
#[Install]
#WantedBy=multi-user.target
#__END_ADMIN_SERVICE__

#__BEGIN_BOT__
##!/usr/bin/env python3
#"""smartdns-bot - the service's Telegram bot.
#
#It runs on the exit, beside smartdns-panel, for the plain reason that Telegram
#is filtered inside Iran and a relay could not reach it. It is a process of its
#own rather than a thread in the panel: the panel's sync API is what keeps every
#customer connected, and neither a Telegram outage nor a bug in a chat handler
#should be able to take that down.
#
#It holds no rules of its own. What a plan does to an account, how an address is
#registered and how a payment is settled live in smartdns-panel, which this loads
#as a module, so there is one copy of each. Messages that come out of those
#rules - a warning, an approval - are queued in the outbox table by whichever
#process made the decision, and delivered from here.
#
#Two things a customer starts in the bot finish on a relay, because they have
#to: the mini app that registers an address (only the relay sees the customer's
#real one) and online payment (Zibal wants an Iranian server, and the
#customer's browser has to come back to one). The relay reports where its pages
#are on every sync, and the bot links there.
#
#The token lives in the database, set from the admin panel's settings or with
#`smartdns-bot token`. Nothing needs restarting: the bot reads it every few
#seconds and connects, reconnects or goes quiet to match.
#
#    smartdns-bot              run the bot - what the service does
#    smartdns-bot status       the token, the bot's name, its admins, the relay
#    smartdns-bot token        set the token (asked for, so it stays out of history)
#    smartdns-bot code         a fresh one-time code for becoming the bot's admin
#    smartdns-bot off          forget the token
#
#Standard library only, like everything else here.
#"""
#
#import getpass
#import hmac
#import importlib.machinery
#import importlib.util
#import ipaddress
#import json
#import os
#import re
#import secrets
#import signal
#import sqlite3
#import sys
#import threading
#import time
#import urllib.error
#import urllib.request
#import uuid
#from datetime import datetime, timedelta, timezone
#
#PANEL_CODE = os.environ.get("SMARTDNS_PANEL", "/usr/local/bin/smartdns-panel")
#TELEGRAM = os.environ.get("TELEGRAM_API", "https://api.telegram.org")
## Long polling: Telegram holds the request open this long when there is nothing
## to say, so the bot answers at once without asking every second.
#POLL_SECONDS = 20
#TOKEN_RE = re.compile(r"^\d{5,15}:[A-Za-z0-9_-]{30,64}$")
## A Persian or Arabic keyboard types these, and a number should not care. The
## separators matter as much as the digits: "۱۵۰٬۰۰۰" is a price.
#DIGITS = str.maketrans("۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩٫٬،", "01234567890123456789.,,")
#RECEIPT_TYPES = ("image/jpeg", "image/png", "image/webp", "application/pdf")
#
#P = None        # smartdns-panel, loaded in main() - or handed in by a test
#
#
#def load_panel(path=None):
#    spec = importlib.util.spec_from_loader(
#        "smartdns_panel", importlib.machinery.SourceFileLoader(
#            "smartdns_panel", path or PANEL_CODE))
#    mod = importlib.util.module_from_spec(spec)
#    spec.loader.exec_module(mod)
#    return mod
#
#
## ------------------------------------------------------------------ telegram
#class TelegramError(Exception):
#    def __init__(self, message, code=None, retry_after=None):
#        super().__init__(message)
#        self.code = code
#        self.retry_after = retry_after
#
#
#class Telegram:
#    """The few Bot API calls this needs, over urllib.
#
#    Nothing here ever writes the token down: it is in every URL, so errors are
#    reported by Telegram's description and never by the request.
#    """
#
#    def __init__(self, token, base=None):
#        self.token = token
#        self.base = base or TELEGRAM
#
#    def call(self, method, **params):
#        body = json.dumps({k: v for k, v in params.items() if v is not None}).encode()
#        req = urllib.request.Request(
#            "%s/bot%s/%s" % (self.base, self.token, method), data=body,
#            headers={"Content-Type": "application/json"})
#        return self._send(req, (params.get("timeout") or 0) + 15)
#
#    def upload(self, method, field, filename, blob, ctype, **params):
#        boundary = uuid.uuid4().hex.encode()
#        parts = []
#        for k, v in params.items():
#            if v is None:
#                continue
#            v = v if isinstance(v, str) else json.dumps(v)
#            parts.append(b"--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n"
#                         % (boundary, k.encode(), v.encode()))
#        parts.append(b"--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\n"
#                     b"Content-Type: %s\r\n\r\n" % (boundary, field.encode(),
#                                                    filename.encode(), ctype.encode())
#                     + blob + b"\r\n")
#        parts.append(b"--%s--\r\n" % boundary)
#        req = urllib.request.Request(
#            "%s/bot%s/%s" % (self.base, self.token, method), data=b"".join(parts),
#            headers={"Content-Type": "multipart/form-data; boundary=%s" % boundary.decode()})
#        return self._send(req, 60)
#
#    def download(self, file_id, limit):
#        info = self.call("getFile", file_id=file_id)
#        if (info.get("file_size") or 0) > limit:
#            raise TelegramError("file too big", code="too_big")
#        req = urllib.request.Request("%s/file/bot%s/%s" % (self.base, self.token,
#                                                           info["file_path"]))
#        with urllib.request.urlopen(req, timeout=60) as res:
#            blob = res.read(limit + 1)
#        if len(blob) > limit:
#            raise TelegramError("file too big", code="too_big")
#        return blob
#
#    def _send(self, req, timeout):
#        try:
#            with urllib.request.urlopen(req, timeout=timeout) as res:
#                data = json.loads(res.read() or b"{}")
#        except urllib.error.HTTPError as e:
#            try:
#                data = json.loads(e.read() or b"{}")
#            except ValueError:
#                data = {"ok": False, "error_code": e.code, "description": "HTTP %d" % e.code}
#        if not data.get("ok"):
#            raise TelegramError(data.get("description") or "telegram refused",
#                                data.get("error_code"),
#                                (data.get("parameters") or {}).get("retry_after"))
#        return data.get("result")
#
#
## ------------------------------------------------------------------- helpers
#MENU_ACCOUNT = "👤 حساب من"
#MENU_BUY = "🛒 خرید / تمدید"
#MENU_IP = "🌐 ثبت آی‌پی"
#MENU_DNS = "📡 آدرس DNS"
#MENU_HELP = "❓ راهنما"
#MENU_PING = "📶 پینگ بازی‌ها"
#MENU_EXIT = "🌍 سرور خروجی"
#MENU_ADMIN = "🛠 مدیریت"
#MENU_CANCEL = "انصراف"
#MENU_ACTIONS = {MENU_ACCOUNT: "account", MENU_BUY: "buy", MENU_IP: "ip",
#                MENU_DNS: "dns", MENU_HELP: "help", MENU_ADMIN: "admin_home",
#                MENU_PING: "pings", MENU_EXIT: "exits"}
#
#STATUS = {"active": "✅ فعال", "pending": "⏳ در انتظار خرید پلن",
#          "over_quota": "⛔️ حجم تمام شده", "expired": "⌛️ دوره تمام شده",
#          "suspended": "🚫 مسدود"}
#
#PLAN_FORMAT = ("پلن را در یک خط بفرستید، بخش‌ها با | جدا:\n"
#               "نام | حجم (گیگ) | مدت (روز) | سرعت (مگابیت) | قیمت (تومان)\n\n"
#               "مثال:\nیک‌ماهه ۵۰ گیگ | 50 | 30 | 0 | 150000\n\n"
#               "حجم ۰ یعنی نامحدود، روز ۰ یعنی بدون محدودیت زمان، سرعت ۰ یعنی بی‌حد.")
#
#
#def btn(text, data):
#    return {"text": text, "callback_data": data}
#
#
#def kb(*rows):
#    return {"inline_keyboard": [list(r) for r in rows if r]}
#
#
#def cancel_kb():
#    return kb([btn("انصراف", "cancel")])
#
#
#def number(text):
#    """A number as somebody typed it, in any digits, with or without commas."""
#    return float((text or "").translate(DIGITS).replace(",", "").strip())
#
#
#def ago(**kw):
#    return (datetime.now(timezone.utc) - timedelta(**kw)).isoformat(timespec="seconds")
#
#
#def format_card(digits):
#    # Isolated left-to-right, or a Persian line around it reorders the groups.
#    return "⁦%s⁩" % " ".join(digits[i:i + 4] for i in range(0, len(digits), 4))
#
#
#def mask(token):
#    return (token[:6] + "…" + token[-4:]) if len(token) > 12 else "…"
#
#
#def typed_ip(text, own=()):
#    """An address somebody typed: (address, "") or ("", why). The same rules as
#    the relay's page, which is where the other way of typing one lives."""
#    text = (text or "").translate(DIGITS).strip()
#    try:
#        addr = ipaddress.IPv4Address(text)
#    except ValueError:
#        return "", "این آی‌پی درست نیست — چهار عدد با نقطه، مثل 5.123.45.67"
#    if not addr.is_global or addr.is_multicast:
#        return "", ("این آی‌پی عمومی نیست. آی‌پی اینترنت خود را بنویسید، نه آی‌پی "
#                    "داخل شبکهٔ خانه (مثل 192.168...)")
#    if str(addr) in own:
#        return "", "این آی‌پی مال سرورهای خود سرویس است"
#    return str(addr), ""
#
#
#def parse_plan(text):
#    parts = [x.strip() for x in (text or "").split("|")]
#    if len(parts) != 5:
#        return None, "باید پنج بخش باشد که با | از هم جدا شده‌اند."
#    name = parts[0]
#    if not 1 <= len(name) <= 40:
#        return None, "نام پلن باید ۱ تا ۴۰ نویسه باشد."
#    try:
#        gb, days, mbps, price = (number(x) for x in parts[1:])
#    except ValueError:
#        return None, "حجم، روز، سرعت و قیمت باید عدد باشند."
#    if min(gb, days, mbps) < 0 or days != int(days):
#        return None, "حجم، روز و سرعت نمی‌توانند منفی باشند و روز باید عدد صحیح باشد."
#    if price < 1000 or price != int(price):
#        return None, "قیمت باید عدد صحیح و دست‌کم ۱٬۰۰۰ تومان باشد."
#    return {"name": name, "quota_gb": gb, "days": int(days),
#            "speed_mbps": mbps, "price": int(price)}, ""
#
#
#EXIT_FORMAT = ("نام و آی‌پی سرور خروجی را این‌طور بفرستید:\n"
#               "آلمان ۲ | 203.0.113.10\n\n"
#               "اگر موقع نصب برایش تونل گرفتید، خط تونلی که چاپ کرده را هم آخرش بگذارید:\n"
#               "آلمان ۲ | 203.0.113.10 | bp-stealth-8444-d.<token>\n\n"
#               "اول روی آن سرور doctor-dns.sh را اجرا کنید، گزینهٔ «3) extra exit» را بزنید "
#               "و آی‌پی رله را بدهید.")
#TUNNEL_FORMAT = ("خط تونلی که نصب‌کنندهٔ آن سرور چاپ کرده را بفرستید:\n"
#                 "bp-stealth-8444-d.<token>\n\n"
#                 "برای برداشتن تونل و وصل شدن مستقیم، «حذف» را بفرستید.")
#
#
#def ms_text(ms):
#    return ("%d ms" % round(ms)) if isinstance(ms, (int, float)) else "اندازه‌گیری نشده"
#
#
#def exit_label(name, ms):
#    if not isinstance(ms, (int, float)):
#        return "⚫ %s — اندازه‌گیری نشده" % name
#    dot = "🟢" if ms < 80 else ("🟡" if ms < 150 else "🔴")
#    return "%s %s — %d ms" % (dot, name, round(ms))
#
#
#def game_ping(game):
#    """(fastest ms, "ok") for a game, or (None, "filtered" | "no-answer")."""
#    hosts = game.get("hosts") or []
#    times = [h["ms"] for h in hosts if isinstance(h, dict) and isinstance(h.get("ms"), (int, float))]
#    if times:
#        return min(times), "ok"
#    states = {h.get("state") for h in hosts if isinstance(h, dict)}
#    if states and states <= {"filtered"}:
#        return None, "filtered"
#    return None, "no-answer"
#
#
#def ping_line(game):
#    ms, state = game_ping(game)
#    label = game.get("label") or "?"
#    if ms is None:
#        return ("🚫 %s — فیلتر است" if state == "filtered" else "⚫ %s — جواب نمی‌دهد") % label
#    dot = "🟢" if ms < 80 else ("🟡" if ms < 150 else "🔴")
#    return "%s %s — %d ms" % (dot, label, round(ms))
#
#
#def host_state(h):
#    if isinstance(h.get("ms"), (int, float)):
#        loss = h.get("loss") or 0
#        return "%d ms%s" % (round(h["ms"]),
#                            (" · %d٪ از دست رفته" % round(loss * 100)) if loss else "")
#    return {"filtered": "فیلتر", "no-dns": "بدون DNS"}.get(h.get("state"), "بی‌جواب")
#
#
#def store_trials(store):
#    return store.one("SELECT count(*) c FROM users WHERE trial_at IS NOT NULL")["c"]
#
#
#def days_left(stamp):
#    due = P.parse_ts(stamp)
#    if not due:
#        return (stamp or "")[:10]
#    left = max(0, (due - datetime.now(timezone.utc)).days)
#    return "%s (%d روز مانده)" % (stamp[:10], left)
#
#
## ----------------------------------------------------------------------- bot
#class Bot:
#    def __init__(self, store, tg, relays=()):
#        self.store = store
#        self.tg = tg
#        self.relays = tuple(relays)
#        # What the next message from a chat answers: ("receipt", plan_id),
#        # ("ip",), ("admin-quota", user_id)... In memory: a restart forgets a
#        # half-finished question, which costs somebody pressing a button again.
#        self.state = {}
#        self.throttle = P.Throttle()
#        self.stopped = False
#
#    # -- lifecycle --------------------------------------------------------
#    def start(self):
#        threading.Thread(target=self.sender, daemon=True).start()
#
#    def stop(self):
#        self.stopped = True
#
#    def sender(self):
#        """Deliver the outbox, forward new receipts, settle decisions.
#
#        A thread of its own so a broadcast to a thousand customers does not
#        hold up the next person pressing a button.
#        """
#        pruned = 0
#        while not self.stopped:
#            busy = 0
#            for job in (self.forward_receipts, self.drain, self.settle):
#                try:
#                    busy += job() or 0
#                except Exception as e:
#                    P.log(P.WARN, "bot: %s failed: %s" % (job.__name__, e))
#            if time.time() - pruned > 3600:
#                pruned = time.time()
#                try:
#                    self.store.run("DELETE FROM outbox WHERE created_at < ?", (ago(days=14),))
#                except Exception as e:
#                    P.log(P.WARN, "bot: outbox not pruned: %s" % e)
#            time.sleep(0.5 if busy else 3)
#
#    def settle(self):
#        P.settle_transactions(self.store)
#        return 0
#
#    def drain(self, limit=25):
#        """Send what is queued, a batch at a time, inside Telegram's rate limit."""
#        rows = self.store.q("SELECT * FROM outbox WHERE sent_at IS NULL AND attempts < 5"
#                            " ORDER BY id LIMIT ?", (limit,))
#        sent = 0
#        for r in rows:
#            if self.stopped:
#                break
#            try:
#                self.say(r["chat_id"], r["text"])
#                self.store.run("UPDATE outbox SET sent_at = ? WHERE id = ?", (P.now(), r["id"]))
#                sent += 1
#            except TelegramError as e:
#                if e.retry_after:
#                    time.sleep(min(int(e.retry_after), 30))
#                    break
#                # 403 is a customer who blocked the bot, 400 a chat that never
#                # existed: neither gets better by asking again.
#                gone = e.code in (400, 403)
#                self.store.run("UPDATE outbox SET attempts = CASE WHEN ? THEN 5"
#                               " ELSE attempts + 1 END WHERE id = ?", (gone, r["id"]))
#            except Exception as e:
#                P.log(P.WARN, "bot: telegram unreachable while sending: %s" % e)
#                break
#            time.sleep(0.04)
#        return sent
#
#    # -- sending ----------------------------------------------------------
#    def say(self, chat, text, markup=None):
#        return self.tg.call("sendMessage", chat_id=chat, text=text[:4096],
#                            reply_markup=markup, disable_web_page_preview=True)
#
#    def menu(self, chat):
#        rows = [[MENU_ACCOUNT, MENU_BUY], [MENU_IP, MENU_DNS], [MENU_PING, MENU_HELP]]
#        # Only when there is a choice to make: one exit is no choice.
#        if self.store.active_exits():
#            rows.insert(2, [MENU_EXIT])
#        if self.is_admin(chat):
#            rows.append([MENU_ADMIN])
#        return {"keyboard": [[{"text": t} for t in r] for r in rows],
#                "resize_keyboard": True}
#
#    def is_admin(self, chat):
#        return chat in P.bot_admins(self.store)
#
#    def setting(self, key):
#        return self.store.setting(key, "")
#
#    # -- updates ----------------------------------------------------------
#    def handle(self, update):
#        if "callback_query" in update:
#            return self.on_callback(update["callback_query"])
#        msg = update.get("message") or {}
#        chat = msg.get("chat") or {}
#        frm = msg.get("from") or {}
#        # Private chats only: an account is a person, and a group would show
#        # everybody's quota and card number to everybody.
#        if chat.get("type") != "private" or frm.get("is_bot") or not frm.get("id"):
#            return
#        chat_id = chat["id"]
#        user = self.customer(frm)
#        text = (msg.get("text") or "").strip()
#        if text.startswith("/start"):
#            self.state.pop(chat_id, None)
#            return self.welcome(chat_id, user)
#        if text.startswith("/admin"):
#            self.state.pop(chat_id, None)
#            return self.admin_command(chat_id, text)
#        if text in ("/cancel", MENU_CANCEL):
#            self.state.pop(chat_id, None)
#            return self.say(chat_id, "باشد، لغو شد.", self.menu(chat_id))
#        if text in MENU_ACTIONS:
#            self.state.pop(chat_id, None)
#            return getattr(self, MENU_ACTIONS[text])(chat_id, user)
#        waiting = self.state.get(chat_id)
#        if waiting:
#            return self.answer(chat_id, user, msg, waiting)
#        if msg.get("photo") or msg.get("document"):
#            return self.say(chat_id, "برای فرستادن رسید، اول از «🛒 خرید / تمدید» پلن "
#                                     "و روش کارت به کارت را انتخاب کنید.", self.menu(chat_id))
#        return self.say(chat_id, "از دکمه‌های پایین صفحه انتخاب کنید.", self.menu(chat_id))
#
#    def customer(self, frm):
#        """The account behind a Telegram user, opened the first time they write.
#
#        It starts the way a web signup does - pending, with nothing - and
#        becomes able to connect when a plan is bought or an operator gives it
#        one. The Telegram username is not stored as the account's username:
#        that column is what the web panel signs in with, and a handle somebody
#        else can take later is no login name.
#        """
#        user = self.store.user_by_telegram(int(frm["id"]))
#        if user:
#            return user
#        name = " ".join(x for x in (frm.get("first_name"), frm.get("last_name")) if x)
#        user = self.store.create_user(int(frm["id"]), None, name.strip()[:60])
#        P.log(P.INFO, "bot: new account #%d from telegram" % user["id"])
#        handle = frm.get("username")
#        P.tell_admins(self.store, "🆕 مشتری تازه در ربات: %s%s"
#                      % (P.user_label(user), (" @" + handle) if handle else ""))
#        return user
#
#    def on_callback(self, cq):
#        data = cq.get("data") or ""
#        msg = cq.get("message") or {}
#        chat = msg.get("chat") or {}
#        frm = cq.get("from") or {}
#        try:
#            self.tg.call("answerCallbackQuery", callback_query_id=cq.get("id"))
#        except Exception:
#            pass
#        if chat.get("type") != "private" or not frm.get("id"):
#            return
#        chat_id = chat["id"]
#        user = self.customer(frm)
#        if data == "cancel":
#            self.state.pop(chat_id, None)
#            return self.say(chat_id, "باشد، لغو شد.", self.menu(chat_id))
#        if data == "buy":
#            return self.buy(chat_id, user)
#        if data == "trial":
#            return self.take_trial(chat_id, user)
#        if data == "ip":
#            return self.ip(chat_id, user)
#        if data == "typeip":
#            self.state[chat_id] = ("ip",)
#            return self.say(chat_id, "آی‌پی اینترنت خود را بفرستید (مثل 5.123.45.67).",
#                            cancel_kb())
#        kind, _, arg = data.partition(":")
#        if kind == "plan" and arg.isdigit():
#            return self.pick_plan(chat_id, int(arg))
#        if kind == "card" and arg.isdigit():
#            return self.card(chat_id, user, int(arg))
#        if kind == "zp" and arg.isdigit():
#            return self.online(chat_id, user, int(arg))
#        if kind == "ex":
#            return self.choose_exit(chat_id, user, arg)
#        if kind == "a":
#            if not self.is_admin(chat_id):
#                return self.say(chat_id, "این بخش فقط برای مدیر ربات است.")
#            return self.admin_callback(chat_id, msg, arg)
#
#    def answer(self, chat, user, msg, waiting):
#        kind = waiting[0]
#        text = (msg.get("text") or "").strip()
#        if kind == "receipt":
#            return self.receive_receipt(chat, user, msg, waiting[1])
#        if kind == "ip":
#            return self.receive_ip(chat, user, text)
#        if kind.startswith("admin-"):
#            if not self.is_admin(chat):
#                self.state.pop(chat, None)
#                return
#            return self.admin_answer(chat, text, waiting)
#        self.state.pop(chat, None)
#
#    # -- customers --------------------------------------------------------
#    def welcome(self, chat, user):
#        self.say(chat, "سلام %s 👋\n\nبه Fasty DNS خوش آمدید. از این ربات می‌توانید:\n"
#                       "• پلن بخرید یا تمدید کنید\n"
#                       "• آی‌پی اینترنتتان را ثبت کنید\n"
#                       "• حجم باقی‌مانده و وضعیت حسابتان را ببینید\n\n"
#                       "از دکمه‌های پایین شروع کنید."
#                 % (user["first_name"] or "دوست عزیز"), self.menu(chat))
#
#    def account(self, chat, user):
#        user = self.store.one("SELECT * FROM users WHERE id = ?", (user["id"],))
#        self.say(chat, self.account_text(user),
#                 kb([btn("🛒 خرید / تمدید", "buy"), btn("🌐 ثبت آی‌پی", "ip")]))
#
#    def account_text(self, user, admin=False):
#        ips = self.store.user_ips(user["id"])
#        quota, used = user["quota_bytes"], user["used_bytes"]
#        lines = ["👤 %s" % (user["first_name"] or user["username"] or "حساب شما")]
#        if admin:
#            lines.append("شناسه: #%d%s%s" % (
#                user["id"], ("  · وب: %s" % user["username"]) if user["username"] else "",
#                ("  · تلگرام: %s" % user["telegram_id"]) if user["telegram_id"] else ""))
#            tpl = (self.store.one("SELECT name FROM templates WHERE id = ?",
#                                  (user["template_id"],)) if user["template_id"] else None)
#            lines.append("قالب: %s" % (tpl["name"] if tpl else "پیش‌فرض"))
#        lines.append("وضعیت: %s" % STATUS.get(user["status"], user["status"]))
#        last = self.store.one(
#            "SELECT p.name FROM transactions t JOIN plans p ON p.id = t.plan_id"
#            " WHERE t.user_id = ? AND t.status = 'approved'"
#            " ORDER BY t.decided_at DESC LIMIT 1", (user["id"],))
#        if last:
#            lines.append("پلن: %s" % last["name"])
#        lines.append("آی‌پی ثبت‌شده: %s" % (ips[0]["ip"] if ips else "ثبت نشده"))
#        lines.append("مصرف: %s" % P.human_fa(used))
#        if quota:
#            lines.append("حجم: %s · باقی‌مانده: %s"
#                         % (P.human_fa(quota), P.human_fa(max(0, quota - used))))
#        elif user["status"] != "pending":
#            lines.append("حجم: نامحدود")
#        if user["speed_kbps"]:
#            lines.append("سرعت: %g مگابیت بر ثانیه" % (user["speed_kbps"] / 1000.0))
#        if user["expires_at"]:
#            lines.append("پایان دوره: %s" % days_left(user["expires_at"]))
#        elif user["quota_reset_at"]:
#            lines.append("تمدید حجم: %s" % user["quota_reset_at"][:10])
#        if user["status"] == "pending" and not admin:
#            if P.trial_reason(self.store, user):
#                lines.append("\nبرای شروع، از «🛒 خرید / تمدید» یک پلن بخرید.")
#            else:
#                lines.append("\n🎁 یک تست رایگان %s دارید — از «🛒 خرید / تمدید» بگیریدش."
#                             % P.trial_summary(self.store))
#        elif not ips and not admin:
#            lines.append("\nآی‌پی‌تان هنوز ثبت نشده؛ تا ثبت نشود سرویس کار نمی‌کند.")
#        return "\n".join(lines)
#
#    def buy(self, chat, user):
#        user = self.store.one("SELECT * FROM users WHERE id = ?", (user["id"],))
#        rows = []
#        if not P.trial_reason(self.store, user):
#            rows.append([btn("🎁 تست رایگان %s" % P.trial_summary(self.store), "trial")])
#        plans = self.store.q("SELECT * FROM plans WHERE active = 1 ORDER BY price, id")
#        rows += [[btn(P.plan_summary(p), "plan:%d" % p["id"])] for p in plans]
#        if not rows:
#            return self.say(chat, "هنوز پلنی برای فروش گذاشته نشده. کمی بعد دوباره سر بزنید.")
#        self.say(chat, "یکی را انتخاب کنید:" if plans else "تست رایگان را می‌توانید بگیرید:",
#                 kb(*rows))
#
#    def take_trial(self, chat, user):
#        ok, why = P.grant_trial(self.store, user["id"])
#        if not ok:
#            return self.say(chat, "⚠️ " + why, self.menu(chat))
#        P.log(P.INFO, "bot: trial taken by user %d" % user["id"])
#        self.say(chat, "🎁 تست رایگان شما فعال شد: %s\n\nدو کار مانده:\n"
#                       "۱. از «🌐 ثبت آی‌پی» آی‌پی اینترنتتان را ثبت کنید.\n"
#                       "۲. از «📡 آدرس DNS» آدرس را در کنسول، گوشی یا مودم بگذارید.\n\n"
#                       "بعد از تمام شدن تست، از «🛒 خرید / تمدید» پلن بگیرید."
#                 % P.trial_summary(self.store), self.menu(chat))
#
#    def pick_plan(self, chat, plan_id):
#        plan = self.store.one("SELECT * FROM plans WHERE id = ? AND active = 1", (plan_id,))
#        if not plan:
#            return self.say(chat, "این پلن دیگر فروخته نمی‌شود.")
#        rows = []
#        if self.setting("card_number"):
#            rows.append([btn("💳 کارت به کارت", "card:%d" % plan_id)])
#        if self.setting("zibal_merchant") and self.setting("relay_panel"):
#            rows.append([btn("🔐 پرداخت آنلاین (زیبال)", "zp:%d" % plan_id)])
#        if not rows:
#            return self.say(chat, "هنوز روش پرداختی تنظیم نشده. لطفاً با پشتیبانی تماس بگیرید.")
#        self.say(chat, "پلن انتخابی:\n%s\n\nروش پرداخت را انتخاب کنید:"
#                 % P.plan_summary(plan), kb(*rows))
#
#    def card(self, chat, user, plan_id):
#        plan = self.store.one("SELECT * FROM plans WHERE id = ? AND active = 1", (plan_id,))
#        number_ = self.setting("card_number")
#        if not plan or not number_:
#            return self.say(chat, "این روش پرداخت الان در دسترس نیست.")
#        holder = self.setting("card_holder")
#        self.state[chat] = ("receipt", plan["id"])
#        self.say(chat, "مبلغ %s را به این کارت واریز کنید:\n\n%s\n%s\n"
#                       "بعد، عکس رسید (یا فایل PDF آن) را همین‌جا بفرستید."
#                 % (P.toman(plan["price"]), format_card(number_),
#                    ("به نام %s\n" % holder) if holder else ""), cancel_kb())
#
#    def online(self, chat, user, plan_id):
#        plan = self.store.one("SELECT * FROM plans WHERE id = ? AND active = 1", (plan_id,))
#        base = self.setting("relay_panel")
#        if not plan or not base or not self.setting("zibal_merchant"):
#            return self.say(chat, "پرداخت آنلاین الان در دسترس نیست.")
#        token = secrets.token_urlsafe(24)
#        self.store.run(
#            "INSERT INTO transactions (user_id, amount, kind, plan_id, status,"
#            " created_at, pay_token, note) VALUES (?, ?, 'zibal', ?, 'started', ?, ?,"
#            " 'telegram')", (user["id"], int(plan["price"]), plan["id"], P.now(), token))
#        self.say(chat, "پلن: %s\nمبلغ: %s\n\nبرای پرداخت روی دکمه بزنید. لینک تا ۲۴ ساعت "
#                       "معتبر است؛ بعد از پرداخت، پلن خودکار فعال می‌شود و همین‌جا خبرتان "
#                       "می‌کنیم." % (plan["name"], P.toman(plan["price"])),
#                 kb([{"text": "🔐 پرداخت %s" % P.toman(plan["price"]),
#                      "url": "%s/pay/%s" % (base, token)}]))
#
#    def receive_receipt(self, chat, user, msg, plan_id):
#        file_id = ctype = None
#        if msg.get("photo"):
#            file_id, ctype = msg["photo"][-1]["file_id"], "image/jpeg"
#        elif msg.get("document"):
#            ctype = (msg["document"].get("mime_type") or "").lower()
#            if ctype in RECEIPT_TYPES:
#                file_id = msg["document"]["file_id"]
#        if not file_id:
#            return self.say(chat, "لطفاً عکس رسید را بفرستید (عکس، یا فایل JPG، PNG، WEBP "
#                                  "یا PDF). برای لغو «انصراف» را بزنید.", cancel_kb())
#        plan = self.store.one("SELECT * FROM plans WHERE id = ?", (plan_id,))
#        if not plan:
#            self.state.pop(chat, None)
#            return self.say(chat, "این پلن دیگر فروخته نمی‌شود.", self.menu(chat))
#        try:
#            blob = self.tg.download(file_id, P.MAX_RECEIPT)
#        except TelegramError as e:
#            if e.code == "too_big":
#                return self.say(chat, "فایل بزرگ‌تر از %s است؛ عکس کوچک‌تری بفرستید."
#                                % P.human(P.MAX_RECEIPT), cancel_kb())
#            raise
#        self.state.pop(chat, None)
#        # One pending receipt per customer, as on the web: a second one replaces
#        # the first, because somebody who sends three photos means the last.
#        self.store.run("DELETE FROM transactions WHERE user_id = ? AND status = 'pending'",
#                       (user["id"],))
#        self.store.run(
#            "INSERT INTO transactions (user_id, amount, kind, plan_id, receipt_blob,"
#            " receipt_type, note, status, created_at, admin_notified)"
#            " VALUES (?, ?, 'card', ?, ?, ?, 'telegram', 'pending', ?, 0)",
#            (user["id"], int(plan["price"]), plan["id"], blob, ctype, P.now()))
#        P.log(P.INFO, "bot: receipt from user %d for plan %d, %s"
#              % (user["id"], plan["id"], P.human(len(blob))))
#        self.say(chat, "✅ رسید دریافت شد.\nپس از بررسی، پلن «%s» فعال می‌شود و همین‌جا "
#                       "خبرتان می‌کنیم." % plan["name"], self.menu(chat))
#        self.forward_receipts()
#
#    def ip(self, chat, user):
#        base = self.setting("relay_panel")
#        rows = []
#        text = "آی‌پی اینترنتی را ثبت کنید که سرویس باید رویش کار کند.\n\n"
#        if base:
#            rows.append([{"text": "🌐 ثبت خودکار آی‌پی", "web_app": {"url": base + "/tg"}}])
#            text += ("روش ساده: فیلترشکن (VPN) را خاموش کنید، با همان اینترنت (وای‌فای "
#                     "خانه یا اینترنت گوشی) وصل شوید و «ثبت خودکار آی‌پی» را بزنید.\n\n")
#        rows.append([btn("⌨️ آی‌پی را خودم می‌نویسم", "typeip")])
#        text += "اگر آی‌پی‌تان را می‌دانید، می‌توانید خودتان هم بنویسید."
#        self.say(chat, text, kb(*rows))
#
#    def receive_ip(self, chat, user, text):
#        own = set(self.relays) | {self.setting("relay_dns")}
#        ip, why = typed_ip(text, own)
#        if not ip:
#            return self.say(chat, why + "\nدوباره بفرستید یا «انصراف» را بزنید.", cancel_kb())
#        self.state.pop(chat, None)
#        res = self.store.claim_ip(user["id"], ip)
#        if res.get("ok"):
#            P.log(P.INFO, "bot: user %d registered %s by hand" % (user["id"], ip))
#        self.say(chat, ("✅ " if res.get("ok") else "⚠️ ") + res.get("message", ""),
#                 self.menu(chat))
#
#    def pings(self, chat, user):
#        self.say(chat, self.ping_text(detail=False), self.menu(chat))
#
#    def ping_text(self, detail):
#        """The latest game pings the relays measured.
#
#        Customers see one line per game, fastest first. The admin also sees
#        every host behind it, its address and loss, and which relay measured.
#        """
#        relays = P.relay_pings(self.store)
#        if not relays:
#            return ("📶 هنوز پینگی اندازه گرفته نشده. سرور ایران هر ۵ دقیقه پینگ "
#                    "سرورهای بازی را می‌گیرد؛ کمی بعد دوباره سر بزنید.")
#        now = datetime.now(timezone.utc)
#        lines = ["📶 پینگ سرورهای بازی از سرور ایران", ""]
#        for relay, entry in sorted(relays.items()):
#            if not isinstance(entry, dict):
#                continue
#            if detail or len(relays) > 1:
#                lines.append("🖥 رله %s" % relay)
#            games = [g for g in (entry.get("games") or {}).values() if isinstance(g, dict)]
#            games.sort(key=lambda g: (game_ping(g)[0] is None, game_ping(g)[0] or 0,
#                                      g.get("label") or ""))
#            for g in games:
#                lines.append(ping_line(g))
#                if detail:
#                    for h in g.get("hosts") or []:
#                        lines.append("      %s %s— %s" % (
#                            h.get("host") or "?", ("(%s) " % h["ip"]) if h.get("ip") else "",
#                            host_state(h)))
#            seen = P.parse_ts(entry.get("at"))
#            if seen:
#                age = int((now - seen).total_seconds() // 60)
#                lines.append("⏱ %s%s" % (
#                    "همین حالا" if age < 1 else "%d دقیقه پیش" % age,
#                    " — قدیمی است؛ رله ممکن است قطع باشد" if age > P.PING_STALE_MINUTES else ""))
#            lines.append("")
#        if not detail:
#            lines.append("این پینگِ سرور ما در ایران است، نه اینترنت شما: خود بازی آنلاین "
#                         "مستقیم از اینترنت شما به سرور بازی وصل می‌شود، پس پینگ شما ممکن "
#                         "است کمی فرق کند.")
#        return "\n".join(lines).strip()
#
#    def exit_names(self):
#        names = {"0": P.main_exit_name(self.store)}
#        names.update({str(r["id"]): r["name"] for r in self.store.active_exits()})
#        return names
#
#    def exits(self, chat, user):
#        user = self.store.one("SELECT * FROM users WHERE id = ?", (user["id"],))
#        names = self.exit_names()
#        if len(names) == 1:
#            return self.say(chat, "این سرویس فقط یک سرور خروجی دارد.", self.menu(chat))
#        measured = P.fresh_exit_pings(self.store)
#        active = {eid: True for eid in names if eid != "0"}
#        now_on = P.resolve_exit(user["exit_id"], measured, active)
#        choice = user["exit_id"]
#        rows = [[btn("%s⚡️ خودکار — همیشه کمترین پینگ" % ("✓ " if choice is None else ""),
#                     "ex:auto")]]
#        for eid in sorted(names, key=lambda e: (measured.get(e) is None, measured.get(e) or 0)):
#            mine = choice is not None and str(choice) == eid
#            rows.append([btn(("✓ " if mine else "") + exit_label(names[eid], measured.get(eid)),
#                             "ex:%s" % eid)])
#        self.say(chat, "🌍 سرور خروجی\n\nسایت‌ها و دانلودهای شما از این سرور به اینترنت "
#                       "می‌روند. پینگ، زمان رسیدن از سرور ایران به هر سرور خروجی است.\n\n"
#                       "الان از: %s%s" % (names.get(now_on, "?"),
#                                          " (خودکار)" if choice is None else ""), kb(*rows))
#
#    def choose_exit(self, chat, user, arg):
#        if arg == "auto":
#            value = None
#        elif arg == "0":
#            value = 0
#        elif arg.isdigit() and self.store.one("SELECT 1 FROM exits WHERE id = ? AND active = 1",
#                                              (int(arg),)):
#            value = int(arg)
#        else:
#            return self.say(chat, "این سرور دیگر در دسترس نیست.", self.menu(chat))
#        self.store.run("UPDATE users SET exit_id = ? WHERE id = ?", (value, user["id"]))
#        P.log(P.INFO, "bot: user %d chose exit %s" % (user["id"], arg))
#        self.say(chat, "✅ خودکار شد: همیشه از سروری که کمترین پینگ را دارد." if value is None
#                 else "✅ ذخیره شد؛ تا ۳۰ ثانیه دیگر از این سرور می‌روید.")
#        return self.exits(chat, user)
#
#    def dns(self, chat, user):
#        address = self.setting("relay_dns") or (self.relays[0] if self.relays else "")
#        if not address:
#            return self.say(chat, "آدرس DNS هنوز معلوم نیست؛ کمی بعد دوباره امتحان کنید.")
#        self.say(chat, "📡 آدرس DNS:\n\n%s\n\nاین را در تنظیمات شبکهٔ کنسول، گوشی یا مودم "
#                       "به‌عنوان DNS اول بگذارید. اگر DNS دوم هم می‌خواهد، همین آدرس را "
#                       "دوباره بنویسید — آدرس دیگری آنجا باعث می‌شود سرویس گاهی کار کند و "
#                       "گاهی نه.\n\nآی‌پی اینترنتتان هم باید ثبت شده باشد." % address)
#
#    def help(self, chat, user):
#        self.say(chat, "❓ راه‌اندازی در سه قدم:\n\n"
#                       "۱. از «🛒 خرید / تمدید» یک پلن بخرید.\n"
#                       "۲. از «🌐 ثبت آی‌پی» آی‌پی اینترنتی را ثبت کنید که سرویس رویش "
#                       "کار می‌کند. اگر مودم را ریست کردید یا اینترنت عوض شد، دوباره "
#                       "ثبت کنید.\n"
#                       "۳. از «📡 آدرس DNS» آدرس را بگیرید و در کنسول، گوشی یا مودم "
#                       "بگذارید.\n\n"
#                       "حجم و زمان باقی‌مانده را در «👤 حساب من» ببینید.", self.menu(chat))
#
#    # -- admin ------------------------------------------------------------
#    def admin_command(self, chat, text):
#        parts = text.split()
#        if len(parts) >= 2:
#            return self.claim_admin(chat, parts[1])
#        if self.is_admin(chat):
#            return self.admin_home(chat, None)
#        return self.say(chat, "برای مدیر ربات شدن، کد مدیریت را از تنظیمات پنل مدیریت "
#                              "بگیرید و این‌طور بفرستید:\n/admin کد")
#
#    def claim_admin(self, chat, code):
#        key = "admin:%d" % chat
#        ok, wait = self.throttle.check(key, limit=5, window=900)
#        if not ok:
#            return self.say(chat, "تلاش زیاد بوده. %d دقیقه دیگر." % max(1, wait // 60))
#        stored, _, until = self.setting("bot_admin_code").partition("|")
#        due = P.parse_ts(until)
#        if (not stored or not due or due < datetime.now(timezone.utc)
#                or not hmac.compare_digest(stored, code.strip().lower())):
#            self.throttle.hit(key)
#            P.log(P.WARN, "bot: a wrong admin code from telegram %d" % chat)
#            return self.say(chat, "این کد درست نیست یا منقضی شده. از پنل مدیریت کد تازه بگیرید.")
#        admins = P.bot_admins(self.store)
#        if chat not in admins:
#            admins.append(chat)
#        self.store.set_setting("bot_admins", ",".join(str(a) for a in admins))
#        # One use. Whoever sees the code in the admin panel after this cannot
#        # turn it into a second admin.
#        self.store.set_setting("bot_admin_code", "")
#        self.throttle.clear(key)
#        P.log(P.INFO, "bot: telegram %d is now a bot admin" % chat)
#        self.say(chat, "✅ شما مدیر ربات شدید. دکمهٔ «🛠 مدیریت» به منو اضافه شد.",
#                 self.menu(chat))
#
#    def admin_home(self, chat, user):
#        if not self.is_admin(chat):
#            return self.say(chat, "این بخش فقط برای مدیر ربات است.", self.menu(chat))
#        pending = self.store.one("SELECT count(*) c FROM transactions"
#                                 " WHERE status = 'pending' AND receipt_blob IS NOT NULL")["c"]
#        self.say(chat, "🛠 مدیریت", kb(
#            [btn("📥 رسیدها (%d)" % pending, "a:rc"), btn("👥 کاربران", "a:us")],
#            [btn("📦 پلن‌ها", "a:pl"), btn("💳 روش‌های پرداخت", "a:py")],
#            [btn("🎁 تست رایگان", "a:tr"), btn("📊 آمار", "a:st")],
#            [btn("📢 پیام همگانی", "a:bc"), btn("📶 پینگ", "a:pg")],
#            [btn("🌍 خروجی‌ها", "a:ex")]))
#
#    def ask(self, chat, state, text):
#        self.state[chat] = state
#        return self.say(chat, text, cancel_kb())
#
#    def admin_callback(self, chat, msg, arg):
#        parts = arg.split(":")
#        cmd = parts[0]
#        ids = [int(x) for x in parts[1:] if x.isdigit()]
#        pages = {"rc": self.admin_receipts, "us": self.admin_users, "pl": self.admin_plans,
#                 "py": self.admin_payments, "st": self.admin_stats, "tr": self.admin_trial,
#                 "pg": self.admin_pings, "ex": self.admin_exits}
#        if cmd in pages:
#            return pages[cmd](chat)
#        if cmd in ("ok", "no") and ids:
#            return self.decide(chat, msg, ids[0], "approved" if cmd == "ok" else "rejected")
#        if cmd == "uf":
#            return self.ask(chat, ("admin-find",), "نام، نام کاربری، شناسه، آیدی عددی تلگرام "
#                                                   "یا آی‌پی را بفرستید:")
#        if cmd == "ul" and len(parts) == 2:
#            return self.list_users(chat, parts[1])
#        if cmd == "u" and ids:
#            return self.user_card(chat, ids[0])
#        if cmd == "up" and ids:
#            return self.choose_plan_for(chat, ids[0])
#        if cmd == "upp" and len(ids) == 2:
#            return self.grant_plan(chat, ids[0], ids[1])
#        if cmd in ("uq", "ud", "uv") and ids:
#            state, text = {
#                "uq": ("admin-quota", "حجم را به گیگابایت بفرستید (۰ یعنی نامحدود):"),
#                "ud": ("admin-days", "از امروز چند روز؟ (۰ یعنی بدون محدودیت زمان)"),
#                "uv": ("admin-speed", "سقف سرعت دانلود به مگابیت بر ثانیه (۰ یعنی بی‌حد):"),
#            }[cmd]
#            return self.ask(chat, (state, ids[0]), text)
#        if cmd == "ut" and ids:
#            return self.choose_template(chat, "utt", ids[0], allow_none=False)
#        if cmd == "utt" and len(ids) == 2:
#            if self.store.one("SELECT 1 FROM templates WHERE id = ?", (ids[1],)):
#                self.store.run("UPDATE users SET template_id = ? WHERE id = ?",
#                               (ids[1], ids[0]))
#                self.say(chat, "✅ قالب عوض شد؛ تا ۳۰ ثانیه دیگر روی رله‌ها اعمال می‌شود.")
#            return self.user_card(chat, ids[0])
#        if cmd == "ur" and ids:
#            P.reset_user_usage(self.store, ids[0])
#            self.say(chat, "✅ مصرف صفر شد.")
#            return self.user_card(chat, ids[0])
#        if cmd in ("ux", "ua") and ids:
#            P.set_user_status(self.store, ids[0], "suspended" if cmd == "ux" else "active")
#            self.say(chat, "🚫 مسدود شد؛ تا ۳۰ ثانیه دیگر قطع می‌شود." if cmd == "ux"
#                     else "✅ حساب برگشت.")
#            return self.user_card(chat, ids[0])
#        if cmd == "pn":
#            return self.ask(chat, ("admin-plan-new",), PLAN_FORMAT)
#        if cmd == "p" and ids:
#            return self.plan_card(chat, ids[0])
#        if cmd == "pe" and ids:
#            plan = self.store.one("SELECT * FROM plans WHERE id = ?", (ids[0],))
#            if not plan:
#                return self.say(chat, "این پلن پیدا نشد.")
#            return self.ask(chat, ("admin-plan-edit", ids[0]), PLAN_FORMAT + "\n\nالان:\n%s | %g | %d | %g | %d"
#                            % (plan["name"], plan["quota_gb"], plan["days"],
#                               plan["speed_mbps"], plan["price"]))
#        if cmd == "pt" and ids:
#            return self.choose_template(chat, "ptt", ids[0], allow_none=True)
#        if cmd == "ptt" and len(ids) == 2:
#            self.store.run("UPDATE plans SET template_id = NULLIF(?, 0) WHERE id = ?",
#                           (ids[1], ids[0]))
#            return self.plan_card(chat, ids[0])
#        if cmd == "pa" and ids:
#            self.store.run("UPDATE plans SET active = 1 - active WHERE id = ?", (ids[0],))
#            return self.plan_card(chat, ids[0])
#        if cmd == "pd" and ids:
#            if self.store.one("SELECT 1 FROM transactions WHERE plan_id = ?", (ids[0],)):
#                self.store.run("UPDATE plans SET active = 0 WHERE id = ?", (ids[0],))
#                self.say(chat, "این پلن در سفارش‌ها استفاده شده، پس فقط فروشش متوقف شد.")
#            else:
#                self.store.run("DELETE FROM plans WHERE id = ?", (ids[0],))
#                self.say(chat, "🗑 پلن حذف شد.")
#            return self.admin_plans(chat)
#        if cmd in ("trg", "trh", "trs"):
#            state, text = {
#                "trg": ("admin-trial-gb", "حجم تست رایگان به گیگابایت (۰ یعنی نامحدود):"),
#                "trh": ("admin-trial-hours", "مدت تست رایگان به ساعت (۰ یعنی خاموش):"),
#                "trs": ("admin-trial-speed", "سرعت تست رایگان به مگابیت بر ثانیه (۰ یعنی بی‌حد):"),
#            }[cmd]
#            return self.ask(chat, (state,), text)
#        if cmd == "trx":
#            self.store.set_setting("trial_on", "" if P.trial_settings(self.store)["on"] else "1")
#            return self.admin_trial(chat)
#        if cmd == "xn":
#            return self.ask(chat, ("admin-exit-new",), EXIT_FORMAT)
#        if cmd == "xe" and ids:
#            return self.exit_card(chat, ids[0])
#        if cmd == "xr" and ids:
#            return self.ask(chat, ("admin-exit-name", ids[0]), "نام تازهٔ این سرور خروجی:")
#        if cmd == "xu" and ids and ids[0] != 0:
#            return self.ask(chat, ("admin-exit-tunnel", ids[0]), TUNNEL_FORMAT)
#        if cmd == "xt" and ids and ids[0] != 0:
#            self.store.run("UPDATE exits SET active = 1 - active WHERE id = ?", (ids[0],))
#            return self.exit_card(chat, ids[0])
#        if cmd == "xd" and ids and ids[0] != 0:
#            moved = self.store.run("UPDATE users SET exit_id = NULL WHERE exit_id = ?",
#                                   (ids[0],)).rowcount
#            self.store.run("DELETE FROM exits WHERE id = ?", (ids[0],))
#            P.log(P.INFO, "bot: exit %d deleted by telegram %d" % (ids[0], chat))
#            self.say(chat, "🗑 حذف شد. %d نفر که آن را انتخاب کرده بودند روی خودکار رفتند."
#                     % moved)
#            return self.admin_exits(chat)
#        if cmd == "pc":
#            return self.ask(chat, ("admin-card",), "شمارهٔ کارت و نام صاحب کارت را این‌طور "
#                                                   "بفرستید:\n6037 9912 3456 7890 | علی رضایی")
#        if cmd == "pz":
#            return self.ask(chat, ("admin-merchant",), "مرچنت کد زیبال را بفرستید:")
#        if cmd == "pcx":
#            self.store.set_setting("card_number", "")
#            self.store.set_setting("card_holder", "")
#            return self.admin_payments(chat)
#        if cmd == "pzx":
#            self.store.set_setting("zibal_merchant", "")
#            return self.admin_payments(chat)
#        if cmd == "bc":
#            return self.ask(chat, ("admin-bc",), "متن پیام همگانی را بفرستید:")
#        if cmd == "bcy":
#            waiting = self.state.get(chat)
#            if not waiting or waiting[0] != "admin-bc-confirm":
#                return self.say(chat, "پیامی برای ارسال آماده نیست.")
#            self.state.pop(chat, None)
#            cur = self.store.run(
#                "INSERT INTO outbox (chat_id, text, created_at) SELECT telegram_id, ?, ?"
#                " FROM users WHERE telegram_id IS NOT NULL", (waiting[1], P.now()))
#            P.log(P.INFO, "bot: broadcast to %d accounts by telegram %d" % (cur.rowcount, chat))
#            return self.say(chat, "📢 در صف ارسال: %d پیام. کمی طول می‌کشد." % cur.rowcount,
#                            self.menu(chat))
#
#    def admin_answer(self, chat, text, waiting):
#        kind = waiting[0]
#        if kind == "admin-find":
#            self.state.pop(chat, None)
#            return self.find_users(chat, text)
#        if kind in ("admin-quota", "admin-days", "admin-speed"):
#            uid = waiting[1]
#            try:
#                value = number(text)
#            except ValueError:
#                return self.say(chat, "یک عدد بفرستید.", cancel_kb())
#            if value < 0:
#                return self.say(chat, "عدد منفی نمی‌شود.", cancel_kb())
#            self.state.pop(chat, None)
#            if not self.store.one("SELECT 1 FROM users WHERE id = ?", (uid,)):
#                return self.say(chat, "این کاربر پیدا نشد.")
#            joined = False
#            if kind == "admin-quota":
#                joined, done = P.set_user_quota(self.store, uid, value), "حجم ذخیره شد"
#            elif kind == "admin-days":
#                joined, done = P.set_user_days(self.store, uid, value), "مدت ذخیره شد"
#            else:
#                P.set_user_speed(self.store, uid, value)
#                done = "سرعت ذخیره شد"
#            self.say(chat, "✅ %s%s" % (done, "؛ حساب فعال شد" if joined else ""))
#            return self.user_card(chat, uid)
#        if kind == "admin-exit-new":
#            parts = [x.strip() for x in text.split("|")]
#            name = parts[0][:40] if parts else ""
#            ip = parts[1].translate(DIGITS) if len(parts) > 1 else ""
#            tunnel = P.parse_exit_tunnel(parts[2]) if len(parts) > 2 else None
#            why = self.exit_problem(name, ip)
#            if not why and len(parts) > 2 and not tunnel:
#                why = "خط تونل درست نیست."
#            if why:
#                return self.say(chat, "⚠️ %s\n\n%s" % (why, EXIT_FORMAT), cancel_kb())
#            self.state.pop(chat, None)
#            eid = self.store.run(
#                "INSERT INTO exits (name, ip, active, created_at, tunnel_transport,"
#                " tunnel_port, tunnel_token) VALUES (?, ?, 1, ?, ?, ?, ?)",
#                (name, ip, P.now()) + (tunnel or (None, None, None))).lastrowid
#            P.log(P.INFO, "bot: exit %d (%s) added by telegram %d" % (eid, ip, chat))
#            self.say(chat, "✅ اضافه شد. رله تا ۳۰ ثانیه دیگر آن را می‌شناسد و تا ۵ دقیقه "
#                           "پینگش را می‌گیرد.")
#            return self.exit_card(chat, eid)
#        if kind == "admin-exit-tunnel":
#            eid = waiting[1]
#            if text.strip() in ("حذف", "-", "off"):
#                self.state.pop(chat, None)
#                self.store.run("UPDATE exits SET tunnel_transport = NULL, tunnel_port = NULL,"
#                               " tunnel_token = NULL WHERE id = ?", (eid,))
#                self.say(chat, "✅ تونل برداشته شد؛ رله تا ۳۰ ثانیه دیگر مستقیم وصل می‌شود.")
#                return self.exit_card(chat, eid)
#            tunnel = P.parse_exit_tunnel(text)
#            if not tunnel:
#                return self.say(chat, "⚠️ خط تونل درست نیست.\n\n%s" % TUNNEL_FORMAT, cancel_kb())
#            self.state.pop(chat, None)
#            self.store.run("UPDATE exits SET tunnel_transport = ?, tunnel_port = ?,"
#                           " tunnel_token = ? WHERE id = ?", tunnel + (eid,))
#            P.log(P.INFO, "bot: exit %d given a %s tunnel on port %d by telegram %d"
#                  % (eid, tunnel[0], tunnel[1], chat))
#            self.say(chat, "✅ تونل ذخیره شد. رله تا ۳۰ ثانیه دیگر آن را برقرار می‌کند.\n"
#                           "اگر رله تا حالا هیچ تونلی نداشته، اول روی رله "
#                           "doctor-dns.sh را با --tunnel اجرا کنید تا BackPack نصب شود.")
#            return self.exit_card(chat, eid)
#        if kind == "admin-exit-name":
#            name = text.strip()[:40]
#            if not name:
#                return self.say(chat, "یک نام بفرستید.", cancel_kb())
#            self.state.pop(chat, None)
#            if waiting[1] == 0:
#                self.store.set_setting("main_exit_name", name)
#            else:
#                self.store.run("UPDATE exits SET name = ? WHERE id = ?", (name, waiting[1]))
#            return self.exit_card(chat, waiting[1])
#        if kind.startswith("admin-trial-"):
#            try:
#                value = number(text)
#            except ValueError:
#                return self.say(chat, "یک عدد بفرستید.", cancel_kb())
#            if value < 0:
#                return self.say(chat, "عدد منفی نمی‌شود.", cancel_kb())
#            self.state.pop(chat, None)
#            self.store.set_setting({"admin-trial-gb": "trial_gb",
#                                    "admin-trial-hours": "trial_hours",
#                                    "admin-trial-speed": "trial_mbps"}[kind], "%g" % value)
#            self.say(chat, "✅ ذخیره شد.")
#            return self.admin_trial(chat)
#        if kind in ("admin-plan-new", "admin-plan-edit"):
#            plan, why = parse_plan(text)
#            if not plan:
#                return self.say(chat, "⚠️ %s\n\n%s" % (why, PLAN_FORMAT), cancel_kb())
#            self.state.pop(chat, None)
#            values = (plan["name"], plan["quota_gb"], plan["days"], plan["speed_mbps"],
#                      plan["price"])
#            if kind == "admin-plan-new":
#                pid = self.store.run(
#                    "INSERT INTO plans (name, quota_gb, days, speed_mbps, price, active,"
#                    " created_at) VALUES (?, ?, ?, ?, ?, 1, ?)", values + (P.now(),)).lastrowid
#                self.say(chat, "✅ پلن ساخته شد و در فروش است.")
#            else:
#                pid = waiting[1]
#                self.store.run("UPDATE plans SET name = ?, quota_gb = ?, days = ?,"
#                               " speed_mbps = ?, price = ? WHERE id = ?", values + (pid,))
#                self.say(chat, "✅ پلن ویرایش شد.")
#            return self.plan_card(chat, pid)
#        if kind == "admin-card":
#            first, _, holder = text.partition("|")
#            digits = re.sub(r"[\s-]", "", first.translate(DIGITS))
#            if not re.fullmatch(r"\d{16}", digits):
#                return self.say(chat, "شمارهٔ کارت باید ۱۶ رقم باشد. دوباره بفرستید:", cancel_kb())
#            self.state.pop(chat, None)
#            self.store.set_setting("card_number", digits)
#            self.store.set_setting("card_holder", holder.strip()[:60])
#            self.say(chat, "✅ کارت ذخیره شد.")
#            return self.admin_payments(chat)
#        if kind == "admin-merchant":
#            merchant = text.strip()
#            if not re.fullmatch(r"[A-Za-z0-9-]{4,64}", merchant):
#                return self.say(chat, "مرچنت کد زیبال را همان‌طور که پنل زیبال نشان می‌دهد "
#                                      "بفرستید — فقط حروف انگلیسی و عدد:", cancel_kb())
#            self.state.pop(chat, None)
#            self.store.set_setting("zibal_merchant", merchant)
#            self.say(chat, "✅ مرچنت ذخیره شد.")
#            return self.admin_payments(chat)
#        if kind in ("admin-bc", "admin-bc-confirm"):
#            if not text:
#                return self.say(chat, "یک پیام متنی بفرستید.", cancel_kb())
#            count = self.store.one("SELECT count(*) c FROM users"
#                                   " WHERE telegram_id IS NOT NULL")["c"]
#            self.state[chat] = ("admin-bc-confirm", text[:4000])
#            return self.say(chat, "پیش‌نمایش:\n\n%s" % text[:4000], kb(
#                [btn("📢 ارسال به %d نفر" % count, "a:bcy")], [btn("انصراف", "cancel")]))
#        self.state.pop(chat, None)
#
#    # receipts
#    def admin_receipts(self, chat):
#        rows = self.store.q("SELECT id FROM transactions WHERE status = 'pending'"
#                            " AND receipt_blob IS NOT NULL ORDER BY id LIMIT 10")
#        if not rows:
#            return self.say(chat, "رسید در انتظاری نیست.")
#        for r in rows:
#            self.send_receipt(chat, r["id"])
#
#    def forward_receipts(self):
#        """Show each new receipt to every bot admin, once."""
#        admins = P.bot_admins(self.store)
#        if not admins:
#            return 0
#        rows = self.store.q("SELECT id FROM transactions WHERE status = 'pending'"
#                            " AND admin_notified = 0 AND receipt_blob IS NOT NULL"
#                            " ORDER BY id LIMIT 10")
#        for r in rows:
#            if self.store.run("UPDATE transactions SET admin_notified = 1"
#                              " WHERE id = ? AND admin_notified = 0", (r["id"],)).rowcount != 1:
#                continue
#            for chat in admins:
#                try:
#                    self.send_receipt(chat, r["id"])
#                except Exception as e:
#                    P.log(P.WARN, "bot: receipt %d not shown to %d: %s" % (r["id"], chat, e))
#        return len(rows)
#
#    def send_receipt(self, chat, tid):
#        t = self.store.one("SELECT t.*, p.name AS plan_name FROM transactions t"
#                           " LEFT JOIN plans p ON p.id = t.plan_id WHERE t.id = ?", (tid,))
#        if not t or t["status"] != "pending" or not t["receipt_blob"]:
#            return
#        user = self.store.one("SELECT * FROM users WHERE id = ?", (t["user_id"],))
#        caption = "🧾 رسید #%d\nکاربر: %s\nپلن: %s\nمبلغ: %s\nزمان: %s UTC" % (
#            tid, P.user_label(user) if user else "#%d" % t["user_id"],
#            t["plan_name"] or "— (از پنل وب)",
#            P.toman(t["amount"]) if t["amount"] else "—",
#            (t["created_at"] or "")[:16].replace("T", " "))
#        markup = kb([btn("✅ تأیید", "a:ok:%d" % tid), btn("❌ رد", "a:no:%d" % tid)],
#                    [btn("👤 حساب کاربر", "a:u:%d" % t["user_id"])])
#        ctype = t["receipt_type"] or "application/octet-stream"
#        ext = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp",
#               "application/pdf": "pdf"}.get(ctype, "bin")
#        method, field = (("sendPhoto", "photo") if ctype in ("image/jpeg", "image/png")
#                         else ("sendDocument", "document"))
#        self.tg.upload(method, field, "receipt-%d.%s" % (tid, ext), bytes(t["receipt_blob"]),
#                       ctype, chat_id=str(chat), caption=caption, reply_markup=markup)
#
#    def decide(self, chat, msg, tid, to):
#        # Only a receipt still pending: two admins pressing at once, or one in
#        # the bot and one in the web panel, decide it once.
#        cur = self.store.run("UPDATE transactions SET status = ?, decided_at = ?,"
#                             " receipt_blob = NULL, settled = 0"
#                             " WHERE id = ? AND status = 'pending'", (to, P.now(), tid))
#        if cur.rowcount != 1:
#            return self.say(chat, "رسید #%d قبلاً بررسی شده." % tid)
#        P.settle_transactions(self.store)
#        t = self.store.one("SELECT t.*, p.name AS plan_name FROM transactions t"
#                           " LEFT JOIN plans p ON p.id = t.plan_id WHERE t.id = ?", (tid,))
#        P.log(P.INFO, "bot: receipt %d %s by telegram %d" % (tid, to, chat))
#        if to == "approved":
#            done = ("تأیید شد و پلن «%s» اعمال شد" % t["plan_name"] if t["plan_name"]
#                    else "تأیید شد؛ پلنی همراهش نبود، حجم و زمان را خودتان بگذارید")
#        else:
#            done = "رد شد"
#        try:
#            self.tg.call("editMessageReplyMarkup", chat_id=chat,
#                         message_id=msg.get("message_id"), reply_markup={"inline_keyboard": []})
#        except Exception:
#            pass
#        self.say(chat, "رسید #%d %s." % (tid, done),
#                 kb([btn("👤 حساب کاربر", "a:u:%d" % t["user_id"])]))
#        for other in P.bot_admins(self.store):
#            if other != chat:
#                P.queue_message(self.store, other, "رسید #%d را مدیر دیگری بررسی کرد: %s."
#                                % (tid, done))
#
#    # customers
#    def admin_users(self, chat):
#        counts = {r["status"]: r["c"] for r in self.store.q(
#            "SELECT status, count(*) c FROM users GROUP BY status")}
#        self.say(chat, "👥 کاربران: %d" % sum(counts.values()), kb(
#            [btn("🔎 جستجو", "a:uf")],
#            [btn("⏳ در انتظار (%d)" % counts.get("pending", 0), "a:ul:pending"),
#             btn("✅ فعال (%d)" % counts.get("active", 0), "a:ul:active")],
#            [btn("⛔️ تمام‌شده (%d)" % (counts.get("over_quota", 0) + counts.get("expired", 0)),
#                 "a:ul:ended"),
#             btn("🚫 مسدود (%d)" % counts.get("suspended", 0), "a:ul:suspended")]))
#
#    def list_users(self, chat, which):
#        where = {"pending": "status = 'pending'", "active": "status = 'active'",
#                 "ended": "status IN ('over_quota', 'expired')",
#                 "suspended": "status = 'suspended'"}.get(which)
#        if not where:
#            return
#        rows = self.store.q("SELECT * FROM users WHERE %s ORDER BY id DESC LIMIT 30" % where)
#        self.show_users(chat, rows)
#
#    def find_users(self, chat, text):
#        q = (text or "").translate(DIGITS).strip().lstrip("@#")
#        if not q:
#            return self.say(chat, "چیزی برای جستجو نفرستادید.")
#        num = int(q) if q.isdigit() else -1
#        like = "%" + q + "%"
#        rows = self.store.q(
#            "SELECT * FROM users WHERE id = ? OR telegram_id = ? OR username LIKE ?"
#            " OR first_name LIKE ? OR phone LIKE ?"
#            " OR id IN (SELECT user_id FROM ips WHERE ip = ?)"
#            " ORDER BY id DESC LIMIT 30", (num, num, like, like, like, q))
#        self.show_users(chat, rows)
#
#    def show_users(self, chat, rows):
#        if not rows:
#            return self.say(chat, "کسی پیدا نشد.")
#        if len(rows) == 1:
#            return self.user_card(chat, rows[0]["id"])
#        self.say(chat, "%d نفر:" % len(rows), kb(*[
#            [btn("%s · %s" % (P.user_label(u), STATUS.get(u["status"], u["status"])),
#                 "a:u:%d" % u["id"])] for u in rows]))
#
#    def user_card(self, chat, uid):
#        user = self.store.one("SELECT * FROM users WHERE id = ?", (uid,))
#        if not user:
#            return self.say(chat, "این کاربر پیدا نشد.")
#        blocked = user["status"] == "suspended"
#        self.say(chat, self.account_text(user, admin=True), kb(
#            [btn("📦 اعمال پلن", "a:up:%d" % uid), btn("♻️ صفر کردن مصرف", "a:ur:%d" % uid)],
#            [btn("📊 حجم", "a:uq:%d" % uid), btn("📅 روز", "a:ud:%d" % uid),
#             btn("🚀 سرعت", "a:uv:%d" % uid)],
#            [btn("🗂 قالب", "a:ut:%d" % uid),
#             btn("✅ برگرداندن" if blocked else "🚫 مسدود کردن",
#                 ("a:ua:%d" if blocked else "a:ux:%d") % uid)]))
#
#    def choose_plan_for(self, chat, uid):
#        plans = self.store.q("SELECT * FROM plans ORDER BY active DESC, price, id")
#        if not plans:
#            return self.say(chat, "هنوز پلنی ساخته نشده.")
#        self.say(chat, "کدام پلن روی این حساب اعمال شود؟ (از امروز، مصرف صفر می‌شود)", kb(*[
#            [btn(P.plan_summary(p), "a:upp:%d:%d" % (uid, p["id"]))] for p in plans]))
#
#    def grant_plan(self, chat, uid, pid):
#        plan = self.store.one("SELECT * FROM plans WHERE id = ?", (pid,))
#        user = self.store.one("SELECT * FROM users WHERE id = ?", (uid,))
#        if not plan or not user:
#            return self.say(chat, "پلن یا کاربر پیدا نشد.")
#        P.apply_plan(self.store, uid, plan)
#        P.tell_user(self.store, user, "🎁 پلن «%s» برای حساب شما فعال شد." % plan["name"])
#        P.log(P.INFO, "bot: plan %d given to user %d by telegram %d" % (pid, uid, chat))
#        self.say(chat, "✅ پلن «%s» اعمال شد." % plan["name"])
#        return self.user_card(chat, uid)
#
#    def choose_template(self, chat, cmd, target, allow_none):
#        rows = self.store.q("SELECT * FROM templates ORDER BY is_default DESC, id")
#        buttons = [[btn(t["name"] + (" (پیش‌فرض)" if t["is_default"] else ""),
#                        "a:%s:%d:%d" % (cmd, target, t["id"]))] for t in rows]
#        if allow_none:
#            buttons.append([btn("بدون تغییر قالب کاربر", "a:%s:%d:0" % (cmd, target))])
#        self.say(chat, "قالب را انتخاب کنید:", kb(*buttons))
#
#    # plans
#    def admin_plans(self, chat):
#        rows = self.store.q("SELECT * FROM plans ORDER BY active DESC, price, id")
#        buttons = [[btn(("" if p["active"] else "⏸ ") + P.plan_summary(p), "a:p:%d" % p["id"])]
#                   for p in rows]
#        buttons.append([btn("➕ پلن تازه", "a:pn")])
#        self.say(chat, "📦 پلن‌ها" + ("" if rows else "\nهنوز پلنی ساخته نشده."), kb(*buttons))
#
#    def plan_card(self, chat, pid):
#        plan = self.store.one("SELECT * FROM plans WHERE id = ?", (pid,))
#        if not plan:
#            return self.say(chat, "این پلن پیدا نشد.")
#        tpl = (self.store.one("SELECT name FROM templates WHERE id = ?", (plan["template_id"],))
#               if plan["template_id"] else None)
#        sold = self.store.one("SELECT count(*) c FROM transactions WHERE plan_id = ?"
#                              " AND status = 'approved'", (pid,))["c"]
#        self.say(chat, "%s\nقالب: %s\nوضعیت: %s\nفروخته‌شده: %d" % (
#            P.plan_summary(plan), tpl["name"] if tpl else "قالب کاربر عوض نمی‌شود",
#            "در فروش" if plan["active"] else "فروش متوقف", sold), kb(
#            [btn("✏️ ویرایش", "a:pe:%d" % pid), btn("🗂 قالب", "a:pt:%d" % pid)],
#            [btn("⏸ توقف فروش" if plan["active"] else "▶️ فروش دوباره", "a:pa:%d" % pid),
#             btn("🗑 حذف", "a:pd:%d" % pid)],
#            [btn("↩️ همهٔ پلن‌ها", "a:pl")]))
#
#    # exits
#    def exit_problem(self, name, ip):
#        if not name:
#            return "نام لازم است."
#        try:
#            addr = ipaddress.IPv4Address(ip)
#        except ValueError:
#            return "آی‌پی درست نیست — چهار عدد با نقطه."
#        if not addr.is_global:
#            return "این آی‌پی عمومی نیست."
#        if str(addr) in set(self.relays) | {self.setting("relay_dns")}:
#            return "این آی‌پیِ رله است، نه یک سرور خروجی."
#        if self.store.one("SELECT 1 FROM exits WHERE ip = ?", (str(addr),)):
#            return "این سرور قبلاً اضافه شده."
#        return ""
#
#    def admin_exits(self, chat):
#        rows = self.store.q("SELECT * FROM exits ORDER BY id")
#        measured = P.fresh_exit_pings(self.store)
#        auto = self.store.one("SELECT count(*) c FROM users WHERE status = 'active'"
#                              " AND exit_id IS NULL")["c"]
#        lines = ["🌍 سرورهای خروجی", "",
#                 "پینگ از سرور ایران تا هر خروجی. %d مشتری روی «خودکار» هستند و همیشه "
#                 "به کمترین پینگ می‌روند." % auto]
#        if not rows:
#            lines += ["", "هنوز خروجی اضافه‌ای نیست. روی سرور تازه doctor-dns.sh را اجرا "
#                          "کنید، «3) extra exit» را بزنید و آی‌پی رله را بدهید؛ بعد اینجا "
#                          "اضافه‌اش کنید."]
#        buttons = [[btn(exit_label(P.main_exit_name(self.store) + " (اصلی)", measured.get("0")),
#                        "a:xe:0")]]
#        for r in rows:
#            buttons.append([btn(("" if r["active"] else "⏸ ")
#                                + exit_label(r["name"], measured.get(str(r["id"]))),
#                                "a:xe:%d" % r["id"])])
#        buttons.append([btn("➕ خروجی تازه", "a:xn")])
#        self.say(chat, "\n".join(lines), kb(*buttons))
#
#    def exit_card(self, chat, eid):
#        measured = P.fresh_exit_pings(self.store)
#        chosen = self.store.one("SELECT count(*) c FROM users WHERE exit_id = ?", (eid,))["c"]
#        ms = measured.get(str(eid))
#        if eid == 0:
#            return self.say(chat, "%s (اصلی)\nپینگ: %s\nانتخاب کرده‌اند: %d نفر\n\nسروری که "
#                                  "رله با آن نصب شده و پنل و ربات روی آن است. پشتیبان بقیهٔ "
#                                  "خروجی‌ها هم هست: اگر یکی جواب ندهد، ترافیکش به این می‌آید."
#                            % (P.main_exit_name(self.store), ms_text(ms), chosen), kb(
#                                [btn("✏️ نام", "a:xr:0")], [btn("↩️ همهٔ خروجی‌ها", "a:ex")]))
#        r = self.store.one("SELECT * FROM exits WHERE id = ?", (eid,))
#        if not r:
#            return self.say(chat, "این سرور پیدا نشد.")
#        tunnel = ("%s، پورت %d" % (r["tunnel_transport"], r["tunnel_port"])
#                  if r["tunnel_transport"] and r["tunnel_token"] else "ندارد — مستقیم")
#        self.say(chat, "%s\nآی‌پی: %s\nپینگ: %s\nوضعیت: %s\nتونل: %s\n"
#                       "انتخاب کرده‌اند: %d نفر" % (
#                           r["name"], r["ip"], ms_text(ms),
#                           "فعال" if r["active"] else "غیرفعال", tunnel, chosen), kb(
#            [btn("✏️ نام", "a:xr:%d" % eid),
#             btn("⏸ غیرفعال کردن" if r["active"] else "▶️ فعال کردن", "a:xt:%d" % eid)],
#            [btn("🔀 تونل", "a:xu:%d" % eid), btn("🗑 حذف", "a:xd:%d" % eid)],
#            [btn("↩️ همهٔ خروجی‌ها", "a:ex")]))
#
#    # game pings
#    def admin_pings(self, chat):
#        self.say(chat, self.ping_text(detail=True))
#
#    # the free trial
#    def admin_trial(self, chat):
#        t = P.trial_settings(self.store)
#        taken = self.store.one("SELECT count(*) c FROM users WHERE trial_at IS NOT NULL")["c"]
#        self.say(chat, "🎁 تست رایگان\n\nوضعیت: %s\nحجم: %s\nمدت: %g ساعت\nسرعت: %s\n"
#                       "تا حالا گرفته‌اند: %d نفر\n\nهر حساب تلگرام فقط یک بار می‌تواند "
#                       "بگیرد، و فقط تا وقتی هیچ پلنی نگرفته باشد."
#                 % ("روشن" if t["on"] else "خاموش",
#                    ("%g گیگ" % t["gb"]) if t["gb"] else "نامحدود", t["hours"],
#                    ("%g مگابیت بر ثانیه" % t["mbps"]) if t["mbps"] else "بی‌حد", taken), kb(
#            [btn("📊 حجم", "a:trg"), btn("⏱ مدت", "a:trh"), btn("🚀 سرعت", "a:trs")],
#            [btn("خاموش کردن" if t["on"] else "روشن کردن", "a:trx")]))
#
#    # payments
#    def admin_payments(self, chat):
#        card, holder = self.setting("card_number"), self.setting("card_holder")
#        merchant, panel = self.setting("zibal_merchant"), self.setting("relay_panel")
#        lines = ["💳 روش‌های پرداخت", "",
#                 "کارت به کارت: %s" % ((format_card(card) + (" — " + holder if holder else ""))
#                                       if card else "تنظیم نشده"),
#                 "زیبال: %s" % (("مرچنت " + merchant[:8] + "…") if merchant else "تنظیم نشده")]
#        if merchant and not panel:
#            lines.append("\n⚠️ پرداخت آنلاین از روی رله انجام می‌شود و هنوز رله‌ای با دامنه "
#                         "و گواهی همگام نشده؛ تا آن وقت دکمهٔ پرداخت آنلاین به مشتری نشان "
#                         "داده نمی‌شود.")
#        elif panel:
#            lines.append("\nدامنهٔ رله برای ثبت در پنل زیبال: %s" % panel)
#        self.say(chat, "\n".join(lines), kb(
#            [btn("💳 شمارهٔ کارت", "a:pc"), btn("🔐 مرچنت زیبال", "a:pz")],
#            [btn("حذف کارت", "a:pcx"), btn("حذف مرچنت", "a:pzx")]))
#
#    # stats
#    def admin_stats(self, chat):
#        s = self.store
#        counts = {r["status"]: r["c"] for r in s.q(
#            "SELECT status, count(*) c FROM users GROUP BY status")}
#        tg = s.one("SELECT count(*) c FROM users WHERE telegram_id IS NOT NULL")["c"]
#        used = s.one("SELECT COALESCE(sum(used_bytes), 0) b FROM users")["b"]
#        ips = s.one("SELECT count(*) c FROM ips")["c"]
#        pending = s.one("SELECT count(*) c FROM transactions WHERE status = 'pending'"
#                        " AND receipt_blob IS NOT NULL")["c"]
#        sales = s.one("SELECT count(*) c, COALESCE(sum(amount), 0) a FROM transactions"
#                      " WHERE status = 'approved' AND decided_at >= ?", (ago(days=30),))
#        lines = ["📊 آمار", "",
#                 "کاربران: %d (در ربات: %d)" % (sum(counts.values()), tg),
#                 "فعال: %d · در انتظار: %d · تمام‌شده: %d · مسدود: %d" % (
#                     counts.get("active", 0), counts.get("pending", 0),
#                     counts.get("over_quota", 0) + counts.get("expired", 0),
#                     counts.get("suspended", 0)),
#                 "آی‌پی ثبت‌شده: %d" % ips,
#                 "مجموع مصرف: %s" % P.human(used),
#                 "رسید در انتظار: %d" % pending,
#                 "تست رایگان گرفته‌اند: %d" % store_trials(self.store),
#                 "فروش ۳۰ روز اخیر: %d مورد، %s" % (sales["c"], P.toman(sales["a"])),
#                 "", "🖥 سرورها:"]
#        rows = s.q("SELECT m.* FROM metrics m JOIN (SELECT host, MAX(at) at FROM metrics"
#                   " GROUP BY host) l ON l.host = m.host AND l.at = m.at ORDER BY m.host")
#        now = datetime.now(timezone.utc)
#        for r in rows:
#            seen = P.parse_ts(r["at"])
#            stale = not seen or (now - seen).total_seconds() > 120
#
#            def pct(a, b):
#                return ("%d٪" % (100 * (a or 0) / b)) if b else "-"
#            lines.append("%s %s — CPU %s · RAM %s · دیسک %s%s" % (
#                "🔴" if stale else "🟢", r["host"],
#                ("%.0f٪" % r["cpu"]) if r["cpu"] is not None else "-",
#                pct(r["mem_used"], r["mem_total"]), pct(r["disk_used"], r["disk_total"]),
#                " · قطع" if stale else ""))
#        if not rows:
#            lines.append("هنوز آماری نرسیده.")
#        self.say(chat, "\n".join(lines))
#
#
## ---------------------------------------------------------------------- main
#def open_store():
#    os.makedirs(os.path.dirname(P.DB), exist_ok=True)
#    # The panel may be migrating the same database this instant, straight
#    # after an upgrade; losing that race is a "duplicate column" that goes away
#    # on the next try.
#    for _ in range(10):
#        try:
#            return P.Store(P.DB)
#        except sqlite3.OperationalError as e:
#            P.log(P.WARN, "bot: database not ready (%s) - trying again" % e)
#            time.sleep(3)
#    return P.Store(P.DB)
#
#
#def relay_addresses():
#    try:
#        cfg = P.load_config()
#    except (OSError, SystemExit):
#        return ()
#    return tuple(x.strip() for x in cfg.get("RELAY_IP", "").split(",") if x.strip())
#
#
#def run():
#    store = open_store()
#    relays = relay_addresses()
#    token, bot, offset, retry_at = None, None, None, 0.0
#    while True:
#        want = store.setting("bot_token", "").strip()
#        if want != token or (want and bot is None and time.time() >= retry_at):
#            if bot:
#                bot.stop()
#                bot = None
#            if want != token:
#                offset = None
#            token = want
#            if not token:
#                P.log(P.INFO, "bot: no token - set one in the admin panel's settings, "
#                              "or with: smartdns-bot token")
#            else:
#                tg = Telegram(token)
#                try:
#                    me = tg.call("getMe")
#                    tg.call("deleteWebhook")
#                    store.set_setting("bot_username", me.get("username") or "")
#                    bot = Bot(store, tg, relays)
#                    bot.start()
#                    P.log(P.INFO, "bot: up as @%s" % me.get("username"))
#                except TelegramError as e:
#                    P.log(P.ERROR, "bot: telegram refused the token: %s" % e)
#                    retry_at = time.time() + 300
#                except Exception as e:
#                    P.log(P.WARN, "bot: telegram unreachable: %s" % e)
#                    retry_at = time.time() + 30
#        if not bot:
#            time.sleep(5)
#            continue
#        try:
#            updates = bot.tg.call("getUpdates", offset=offset, timeout=POLL_SECONDS,
#                                  allowed_updates=["message", "callback_query"])
#        except TelegramError as e:
#            P.log(P.WARN, "bot: getUpdates refused: %s" % e)
#            if e.code == 401:
#                bot.stop()
#                bot, retry_at = None, time.time() + 300
#            time.sleep(5)
#            continue
#        except Exception as e:
#            P.log(P.WARN, "bot: telegram unreachable: %s" % e)
#            time.sleep(10)
#            continue
#        for update in updates or []:
#            offset = update["update_id"] + 1
#            try:
#                bot.handle(update)
#            except Exception:
#                P.log_exception("bot: update %s failed" % update.get("update_id"))
#
#
#def cli(args):
#    if hasattr(os, "geteuid") and os.geteuid() != 0:
#        print("run as root:  sudo smartdns-bot %s" % " ".join(args), file=sys.stderr)
#        return 1
#    store = open_store()
#    cmd = args[0]
#    if cmd == "status":
#        token = store.setting("bot_token", "")
#        name = store.setting("bot_username", "")
#        code, _, until = store.setting("bot_admin_code", "").partition("|")
#        print("token    %s" % (mask(token) if token else "not set"))
#        print("bot      %s" % (("@" + name) if name else "-"))
#        print("admins   %s" % (", ".join(str(a) for a in P.bot_admins(store)) or "none"))
#        print("code     %s" % (("/admin %s  (until %s UTC)" % (code, until[:16])) if code else "none"))
#        print("relay    %s" % (store.setting("relay_panel", "") or
#                               "no relay with a domain has synced - no mini app, no online payment"))
#        return 0
#    if cmd == "token":
#        token = args[1] if len(args) > 1 else getpass.getpass("bot token (from @BotFather): ")
#        token = token.strip()
#        if not TOKEN_RE.match(token):
#            print("that is not a bot token - it looks like 123456789:AA... ", file=sys.stderr)
#            return 2
#        store.set_setting("bot_token", token)
#        store.set_setting("bot_username", "")
#        code = P.new_admin_code(store)
#        print("token saved - the bot connects within a few seconds.")
#        print("to become its admin, send it this (works once, for 24 hours):\n\n    /admin %s\n"
#              % code)
#        return 0
#    if cmd == "code":
#        print("send the bot this (works once, for 24 hours):\n\n    /admin %s\n"
#              % P.new_admin_code(store))
#        return 0
#    if cmd == "off":
#        store.set_setting("bot_token", "")
#        store.set_setting("bot_username", "")
#        print("token forgotten - the bot goes quiet within a few seconds")
#        return 0
#    print(__doc__.split("\n\n")[-2], file=sys.stderr)
#    return 2
#
#
#def main(argv):
#    global P
#    P = load_panel()
#    if len(argv) > 1:
#        return cli(argv[1:])
#
#    def bye(*_):
#        sys.exit(0)
#
#    signal.signal(signal.SIGTERM, bye)
#    signal.signal(signal.SIGINT, bye)
#    run()
#
#
#if __name__ == "__main__":
#    sys.exit(main(sys.argv))
#__END_BOT__

#__BEGIN_BOT_SERVICE__
#[Unit]
#Description=Smart DNS Telegram bot
#After=network-online.target smartdns-panel.service
#Wants=network-online.target
#
#[Service]
#Type=simple
## Idle until a token is set in the admin panel's settings, or with
## `smartdns-bot token`; it reads the token from the database and needs no
## restart to pick one up. It listens on nothing - it only dials out to Telegram.
#ExecStart=/usr/local/bin/smartdns-bot
#Restart=always
#RestartSec=10
#NoNewPrivileges=yes
#ProtectSystem=strict
#ProtectHome=yes
#PrivateTmp=yes
#ReadWritePaths=/var/lib/smart-dns
#
#[Install]
#WantedBy=multi-user.target
#__END_BOT_SERVICE__

#__BEGIN_SMARTDNS_ACCESS__
##!/bin/bash
## smartdns-access - change how the admin panel is reached.
##
## usage: smartdns-access                    show the address it answers on
##        smartdns-access port <number>      move it to another port
##        smartdns-access path [new]         change the secret path, or roll one
##        smartdns-access password [new]     set a new password
##        smartdns-access rotate             new path and new password at once
##
## Three things stand in front of the panel and only one of them is a secret in
## the cryptographic sense:
##
##   the port    keeps it out of the way of casual scanning, nothing more
##   the path    an unguessable URL - it is a secret, but it travels in every
##               request line and lands in any proxy log along the way
##   the password the actual authentication
##
## So this can change all three, and the password is the one that matters. It
## is never stored: only a salted hash goes into admin.env, which is why a
## forgotten password is replaced rather than recovered.
#set -uo pipefail
#export PATH="$PATH:/usr/sbin:/sbin"
#
#CONF=/etc/smart-dns/admin.env
#UNIT=smartdns-admin.service
#
#R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
#[ -t 1 ] || { R=; G=; Y=; B=; N=; }
#die() { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
#
#[ "$(id -u)" = 0 ] || die "run as root"
#[ -f "$CONF" ] || die "$CONF is missing - this machine has no admin panel.
#    It is set up on the exit node, by the installer, once the machine has a
#    domain and a certificate."
#
#get() { sed -n "s/^$1=//p" "$CONF" | head -1; }
#
#set_key() {
#    local key="$1" value="$2" tmp
#    tmp="$(mktemp)"
#    grep -v "^${key}=" "$CONF" > "$tmp" 2>/dev/null || true
#    printf '%s=%s\n' "$key" "$value" >> "$tmp"
#    # Copy rather than move: the file is mode 600 and owned by root, and a
#    # move from /tmp would bring the temporary file's permissions with it.
#    cat "$tmp" > "$CONF"
#    rm -f "$tmp"
#    chmod 600 "$CONF"
#}
#
#hash_password() {
#    ADMIN_PASS="$1" ADMIN_SALT="$2" python3 -c '
#import hashlib, os
#print(hashlib.pbkdf2_hmac("sha256", os.environ["ADMIN_PASS"].encode(),
#                          bytes.fromhex(os.environ["ADMIN_SALT"]), 200000).hex())'
#}
#
#domain() {
#    # Whatever the certificate is for. The panel answers on any address the
#    # machine has, but only this name matches the certificate, so it is the
#    # only one worth printing.
#    local d
#    d="$(sed -n 's|^ADMIN_CERT=/etc/letsencrypt/live/\([^/]*\)/.*|\1|p' "$CONF" | head -1)"
#    [ -n "$d" ] || d="$(hostname -I 2>/dev/null | awk '{print $1}')"
#    printf '%s' "${d:-this-server}"
#}
#
#show() {
#    printf '\n    %sAdmin panel%s\n\n        https://%s:%s/%s/\n\n' \
#        "$B" "$N" "$(domain)" "$(get ADMIN_PORT)" "$(get ADMIN_PATH)"
#    printf '    The password is not stored, only a hash of it. If it is lost,\n'
#    printf '    set a new one:  smartdns-access password\n\n'
#}
#
#restart() {
#    systemctl restart "$UNIT" 2>/dev/null
#    sleep 2
#    if systemctl is-active --quiet "$UNIT"; then
#        printf '%s    panel restarted%s\n' "$G" "$N"
#    else
#        printf '%s    the panel did not come back - journalctl -u %s%s\n' \
#            "$Y" "$UNIT" "$N"
#    fi
#}
#
#case "${1:-show}" in
#show|"")
#    show
#    ;;
#
#port)
#    new="${2:-}"
#    case "$new" in
#        ""|*[!0-9]*) die "usage: smartdns-access port <number>" ;;
#    esac
#    [ "$new" -ge 1 ] && [ "$new" -le 65535 ] || die "a port is 1-65535"
#    # These belong to the service itself. Moving the panel onto one of them
#    # would take down the thing it is meant to administer.
#    case "$new" in
#        53|80|443) die "port $new is the service's own - pick another" ;;
#        8443) die "port 8443 is the sync API the relays talk to" ;;
#        8446) die "port 8446 is the exit's own route to Google over IPv6" ;;
#        22) die "port 22 is ssh" ;;
#    esac
#    old="$(get ADMIN_PORT)"
#    if [ "$new" != "$old" ] && ss -tlnH "sport = :$new" 2>/dev/null | grep -q .; then
#        die "something else is already listening on $new"
#    fi
#    set_key ADMIN_PORT "$new"
#    printf '    port %s -> %s\n' "$old" "$new"
#    restart
#    show
#    ;;
#
#path)
#    new="${2:-}"
#    if [ -z "$new" ]; then
#        new="$(openssl rand -hex 12)"
#    else
#        case "$new" in
#            */*|*' '*|*'?'*|*'#'*) die "a path is one segment: letters, digits, - and _" ;;
#            *[!A-Za-z0-9_-]*) die "use only letters, digits, - and _" ;;
#        esac
#        [ "${#new}" -ge 8 ] || die "too short to be unguessable - use 8 or more"
#    fi
#    set_key ADMIN_PATH "$new"
#    printf '    the old address stops working now.\n'
#    restart
#    show
#    ;;
#
#password)
#    new="${2:-}"
#    if [ -z "$new" ]; then
#        # -s so it is not echoed, and asked twice because it cannot be read
#        # back afterwards to check.
#        printf '  new password (8 or more, not shown as you type): '
#        read -rs new; printf '\n'
#        printf '  again: '
#        read -rs again; printf '\n'
#        [ "$new" = "$again" ] || die "they did not match - nothing changed"
#    fi
#    [ "${#new}" -ge 8 ] || die "use 8 characters or more"
#    salt="$(openssl rand -hex 16)"
#    hash="$(hash_password "$new" "$salt")" || die "could not hash the password"
#    [ -n "$hash" ] || die "could not hash the password"
#    set_key ADMIN_SALT "$salt"
#    set_key ADMIN_HASH "$hash"
#    printf '    password changed. Everyone signed in is signed out.\n'
#    # Sessions live in the panel's memory, so restarting is what ends them -
#    # which is the point of changing a password.
#    restart
#    ;;
#
#rotate)
#    "$0" path >/dev/null
#    "$0" password "${2:-}"
#    show
#    ;;
#
#*)
#    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
#    exit 1
#    ;;
#esac
#__END_SMARTDNS_ACCESS__

#__BEGIN_SMARTDNS_LOGS__
##!/bin/bash
## smartdns-logs - what this machine has been doing, all in one place.
##
## usage: smartdns-logs          recent logs of every part, and whether each runs
##        smartdns-logs -e       only warnings and errors
##        smartdns-logs -f       follow them live (ctrl-c to stop)
##        smartdns-logs -n 500   more lines per part (default 100)
##        smartdns-logs --report all of it in one file to send, secrets masked
#set -uo pipefail
#
## Where this machine's config lives. A variable only so a test can point it
## somewhere else; nothing else sets it.
#ETC="${SMARTDNS_ETC:-/etc/smart-dns}"
#
#n=100
#follow=no
#report=""
#errors=""
## journald's own level filter. The programs mark their warnings and errors
## with a syslog level, so this is exactly the problems and nothing else.
#prio=()
#while [ $# -gt 0 ]; do
#    case "$1" in
#        -e|--errors) errors=yes; prio=(-p warning) ;;
#        -f|--follow) follow=yes ;;
#        --report) report=yes ;;
#        -n) shift; n="${1:-}" ;;
#        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
#        *) echo "unknown option: $1  (try -h)" >&2; exit 1 ;;
#    esac
#    shift
#done
#case "$n" in ''|*[!0-9]*) echo "-n wants a number of lines" >&2; exit 1 ;; esac
#[ "$(id -u)" = 0 ] || { echo "run as root:  sudo smartdns-logs" >&2; exit 1; }
#
## Which side this is decides which parts it has. The timers are listed for
## their status - a oneshot service reads "inactive" between runs, which looks
## like a fault and is not - and the services for their logs.
#if [ -f "$ETC/sync.env" ]; then
#    role=relay
#    status="smartdns-sync dnsmasq nginx coturn epic-pin.timer smartdns-acl-save.timer"
#    logs="smartdns-sync dnsmasq nginx coturn epic-pin smartdns-acl-save"
#    # One tunnel per extra exit that has one, started by the sync agent.
#    for u in $(systemctl list-units --plain --no-legend 'smartdns-tunnel@*' 2>/dev/null | awk '{print $1}'); do
#        status="$status $u"
#        logs="$logs $u"
#    done
#    for f in /etc/smartdns-profiles/*.conf; do
#        [ -e "$f" ] || continue
#        status="$status smartdns-dns@$(basename "$f" .conf)"
#        logs="$logs smartdns-dns@$(basename "$f" .conf)"
#    done
#elif [ -f "$ETC/panel.env" ]; then
#    role=exit
#    status="smartdns-panel smartdns-admin smartdns-bot nginx smartdns-cert.timer"
#    logs="smartdns-panel smartdns-admin smartdns-bot nginx smartdns-cert"
#elif [ -f "$ETC/exit.env" ]; then
#    # An extra exit: nginx carrying traffic, and its own tunnel when it has one.
#    role=extra
#    status="nginx"
#    logs="nginx"
#else
#    echo "Fasty DNS is not installed on this machine" >&2
#    exit 1
#fi
## The tunnel, on either side, when the installer set one up.
#if [ -f /etc/systemd/system/smartdns-tunnel.service ]; then
#    status="$status smartdns-tunnel"
#    logs="$logs smartdns-tunnel"
#fi
#
## Every secret in this machine's config, replaced wherever it turns up in a
## report. None should ever reach a log, but a report is made to be handed to
## somebody else. Paths are left alone: they are where things are, not keys.
#MASK=$(cat <<'PY'
#import glob, re, sys
#found = set()
#for path in glob.glob(sys.argv[1] + "/*.env"):
#    try:
#        with open(path) as fh:
#            for line in fh:
#                key, _, value = line.strip().partition("=")
#                value = value.strip().strip("\"'")
#                if (re.search(r"SECRET|PATH|HASH|SALT|TOKEN|PASS", key)
#                        and len(value) >= 6 and not value.startswith("/")):
#                    found.add(value.encode())
#    except OSError:
#        pass
#data = sys.stdin.buffer.read()
#for value in sorted(found, key=len, reverse=True):
#    data = data.replace(value, b"<secret>")
#sys.stdout.buffer.write(data)
#PY
#)
#
## One file with everything worth sending when something is wrong - the state of
## each part, its warnings and errors, its recent logs - with the secrets masked.
## It still holds customers' addresses and usernames: those are what the logs
## are about, and the reader is told so.
#if [ -n "$report" ]; then
#    out="${SMARTDNS_REPORT_DIR:-/tmp}/doctor-dns-report-$role-$(date -u +%Y%m%d-%H%M%S).txt"
#    umask 077
#    {
#        echo "Fasty DNS report - $role - $(date -u '+%F %T') UTC"
#        echo "version  $(cat /var/lib/smart-dns/version 2>/dev/null || echo '?')"
#        echo "system   $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}"), kernel $(uname -r)"
#        echo "up       $(uptime -p 2>/dev/null || echo '?')"
#        # A clock that has drifted breaks TLS between the two machines and
#        # moves every expiry date, so it earns a line in any report.
#        echo "clock    $(timedatectl show -p NTPSynchronized --value 2>/dev/null \
#                         | sed 's/^yes$/synchronised/; s/^no$/NOT synchronised/')"
#        echo
#        echo "== disk and memory"
#        df -h / 2>/dev/null | tail -1
#        free -m 2>/dev/null | sed -n '1,2p'
#        if [ "$role" = relay ]; then
#            echo
#            echo "== routing"
#            smartdns-rules 2>&1
#            echo
#            echo "== access control"
#            smartdns-acl enforce status 2>&1 | head -3
#        fi
#        echo
#        echo "################ warnings and errors ################"
#        bash "$0" -e -n 300
#        echo
#        echo "################ recent logs ################"
#        bash "$0" -n 150
#    } 2>&1 | python3 -c "$MASK" "$ETC" > "$out"
#    echo "report written: $out ($(du -k "$out" | cut -f1) KB)"
#    echo "Secrets and the admin panel's address are masked. It does hold your"
#    echo "customers' IP addresses and usernames, from the logs - send it only"
#    echo "to someone you trust."
#    exit 0
#fi
#
#if [ "$follow" = yes ]; then
#    args=()
#    for u in $logs; do args+=(-u "$u"); done
#    exec journalctl "${args[@]}" ${prio[@]+"${prio[@]}"} -f -n 20 --no-pager -o short-iso
#fi
#
#printf 'Fasty DNS %s - %s\n' \
#       "$(cat /var/lib/smart-dns/version 2>/dev/null || echo '?')" "$role"
#echo
#echo "== services"
#for u in $status; do
#    printf '  %-26s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)"
#done
#failed="$(systemctl list-units --state=failed --no-legend 2>/dev/null)"
#if [ -n "$failed" ]; then
#    echo
#    echo "== failed"
#    echo "$failed"
#fi
#for u in $logs; do
#    echo
#    echo "== $u"
#    journalctl -u "$u" ${prio[@]+"${prio[@]}"} -n "$n" --no-pager -o short-iso 2>/dev/null
#done
#if [ -s /var/log/nginx/error.log ]; then
#    echo
#    echo "== nginx errors"
#    if [ -n "$errors" ]; then
#        # "access forbidden by rule" is the exit turning away everyone but its
#        # relay - the gate doing its job, at nginx's error level. Not a problem.
#        grep -v 'access forbidden by rule' /var/log/nginx/error.log | tail -n "$n"
#    else
#        tail -n "$n" /var/log/nginx/error.log
#    fi
#fi
#__END_SMARTDNS_LOGS__

#__BEGIN_SMARTDNS_RULES__
##!/usr/bin/env python3
#"""smartdns-rules - what each template's resolver does with a domain.
#
#usage: smartdns-rules                  every resolver on this relay, and what it routes
#       smartdns-rules show [TEMPLATE]  what one template redirects, bypasses and pins
#       smartdns-rules check DOMAIN...  what every template does with these names
#
#Every template that has customers gets its own dnsmasq on this relay; the
#default template is the resolver on port 53. `check` answers from both sides:
#the rule that decides the name, read from that resolver's own files, and the
#answer the resolver actually gives when asked. A resolver still running on old
#config shows up as the two disagreeing.
#
#Nothing here reads a customer's traffic. It says where a name would go, not
#who asked for it.
#"""
#import collections
#import json
#import os
#import random
#import re
#import signal
#import socket
#import struct
#import subprocess
#import sys
#
#SYNC_ENV = "/etc/smart-dns/sync.env"
#DNSMASQ_D = "/etc/dnsmasq.d"
#BASE_DIR = "/etc/smartdns-base"
#PROFILE_DIR = "/etc/smartdns-profiles"
#TEMPLATE_NAMES = "/var/lib/smart-dns/templates.json"
#CUSTOM_CONF = "50-smartdns-custom.conf"
#ACL = "/usr/local/bin/smartdns-acl"
#NFT = "/usr/sbin/nft"
#NAT_TABLE = "smartdns_nat"
#MAIN_PORT = 53
#HOST = "127.0.0.1"
#TIMEOUT = 3.0
#
## address=/a.com/b.com/1.2.3.4, server=/a.com/1.1.1.1, local=/a.com/. A server=
## line with no slashes is an upstream, not a rule about any name.
#RULE_LINE = re.compile(r"^(address|server|local)=/(.+)/([^/]*)$")
#DOMAIN = re.compile(r"^[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?)*$")
#
#Rule = collections.namedtuple("Rule", "kind domain target source")
#
#
#def run(*args):
#    try:
#        return subprocess.run(list(args), capture_output=True, text=True,
#                              timeout=20)
#    except (OSError, subprocess.SubprocessError):
#        return None
#
#
#def self_ip():
#    try:
#        with open(SYNC_ENV) as fh:
#            for line in fh:
#                k, _, v = line.strip().partition("=")
#                if k.strip() == "SELF_IP":
#                    return v.strip().strip('"').strip("'")
#    except OSError:
#        pass
#    return None
#
#
## ------------------------------------------------------------------ reading
#def conf_dir_files(d):
#    """The files dnsmasq reads from a --conf-dir: all of them, less the ones
#    it skips itself and the package manager's leftovers."""
#    try:
#        names = sorted(os.listdir(d))
#    except OSError:
#        return []
#    out = []
#    for n in names:
#        if n.startswith(".") or n.endswith("~") or (n.startswith("#") and n.endswith("#")):
#            continue
#        if n.endswith((".dpkg-dist", ".dpkg-old", ".dpkg-new")):
#            continue
#        p = os.path.join(d, n)
#        if os.path.isfile(p):
#            out.append(p)
#    return out
#
#
#def read_rules(path):
#    rules = []
#    try:
#        fh = open(path, encoding="utf-8", errors="replace")
#    except OSError:
#        return rules
#    with fh:
#        for line in fh:
#            m = RULE_LINE.match(line.strip())
#            if not m:
#                continue
#            kind, domains, target = m.groups()
#            for d in domains.split("/"):
#                d = d.strip().lower().rstrip(".")
#                if d:
#                    rules.append(Rule(kind, d, target.strip(), os.path.basename(path)))
#    return rules
#
#
#def conf_port(path):
#    try:
#        with open(path) as fh:
#            for line in fh:
#                if line.startswith("port="):
#                    return int(line.split("=", 1)[1])
#    except (OSError, ValueError):
#        pass
#    return None
#
#
#def load_names():
#    """Template names by id, and the default's id, as the panel last sent them."""
#    try:
#        with open(TEMPLATE_NAMES, encoding="utf-8") as fh:
#            info = json.load(fh)
#        names = {str(k): str(v) for k, v in (info.get("names") or {}).items()}
#        return names, str(info.get("default") or "")
#    except (OSError, ValueError, AttributeError):
#        return {}, ""
#
#
#class Resolver:
#    def __init__(self, key, port, files, name=""):
#        self.key, self.port, self.files, self.name = key, port, files, name
#        self.rules = [r for f in files for r in read_rules(f)]
#
#    @property
#    def unit(self):
#        return "dnsmasq" if self.key == "main" else "smartdns-dns@%s" % self.key
#
#    def label(self):
#        if self.key == "main":
#            return "%s (default)" % self.name if self.name else "default template"
#        return self.name or "template %s" % self.key
#
#    def decide(self, name):
#        """The rule dnsmasq applies to `name`: the longest domain that covers
#        it, and at a tie address= over server= - which is how this dnsmasq
#        behaves, measured, and why a template cannot un-route a name that
#        another file it reads routes."""
#        best = key = None
#        for r in self.rules:
#            if r.domain == "#":
#                length = 0
#            elif name == r.domain or name.endswith("." + r.domain):
#                length = len(r.domain)
#            else:
#                continue
#            k = (length, 1 if r.kind == "address" else 0)
#            if key is None or k > key:
#                best, key = r, k
#        return best
#
#
#def resolvers():
#    names, default = load_names()
#    out = [Resolver("main", MAIN_PORT, conf_dir_files(DNSMASQ_D),
#                    names.get(default, ""))]
#    try:
#        confs = [f for f in os.listdir(PROFILE_DIR) if f.endswith(".conf")]
#    except OSError:
#        confs = []
#    for f in sorted(confs, key=lambda f: (len(f), f)):
#        path = os.path.join(PROFILE_DIR, f)
#        key = f[:-len(".conf")]
#        out.append(Resolver(key, conf_port(path), conf_dir_files(BASE_DIR) + [path],
#                            names.get(key, "")))
#    return out
#
#
#def meaning(rule, me):
#    """(where it goes, how to say it) for the rule deciding a name."""
#    if rule is None:
#        return "direct", "no rule"
#    shown = "%s=/%s/%s" % (rule.kind, rule.domain, rule.target)
#    if rule.kind == "address":
#        if rule.target == me:
#            return "relay", shown
#        if rule.target in ("", "#", "0.0.0.0", "::"):
#            return "blocked", shown
#        return "pinned", shown
#    if rule.kind == "server":
#        return "direct", shown
#    return "local", shown
#
#
## ------------------------------------------------------------------ asking
#def skip_name(buf, off):
#    while True:
#        n = buf[off]
#        if n == 0:
#            return off + 1
#        if n & 0xC0 == 0xC0:
#            return off + 2
#        off += 1 + n
#
#
#def ask(name, port, host=None, timeout=None):
#    """The A records a resolver gives for `name`: a list, empty when it
#    answered with none, or None when it did not answer at all."""
#    qid = random.randrange(65536)
#    packet = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
#    for label in name.encode("idna").split(b"."):
#        if label:
#            packet += bytes([len(label)]) + label
#    packet += b"\x00" + struct.pack(">HH", 1, 1)
#    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
#    s.settimeout(timeout or TIMEOUT)
#    try:
#        s.sendto(packet, (host or HOST, port))
#        while True:
#            data, _ = s.recvfrom(4096)
#            if len(data) >= 12 and struct.unpack(">H", data[:2])[0] == qid:
#                break
#    except OSError:
#        return None
#    finally:
#        s.close()
#    try:
#        qd, an = struct.unpack(">HH", data[4:8])
#        off = 12
#        for _ in range(qd):
#            off = skip_name(data, off) + 4
#        ips = []
#        for _ in range(an):
#            off = skip_name(data, off)
#            typ, _cls, _ttl, rdlen = struct.unpack(">HHIH", data[off:off + 10])
#            off += 10
#            if typ == 1 and rdlen == 4:
#                ips.append(socket.inet_ntoa(data[off:off + 4]))
#            off += rdlen
#        return ips
#    except (IndexError, struct.error):
#        return []
#
#
## --------------------------------------------------------------- customers
#def assignment():
#    """Registered addresses per resolver port, read off the redirect rules.
#
#    Not off the sets alone: a set no rule points at is a leftover, and the
#    addresses in it are really answered by the default resolver on 53.
#    """
#    r = run(NFT, "list", "chain", "ip", NAT_TABLE, "pre")
#    ports = {}
#    if r is not None and r.returncode == 0:
#        for m in re.finditer(r"ip saddr @(\S+) (?:udp|tcp) dport 53 redirect to :(\d+)",
#                             r.stdout):
#            ports[m.group(1)] = int(m.group(2))
#    by_port = {}
#    for setname, port in ports.items():
#        members = set()
#        r = run(NFT, "-j", "list", "set", "ip", NAT_TABLE, setname)
#        if r is not None and r.returncode == 0:
#            try:
#                for item in json.loads(r.stdout).get("nftables", []):
#                    for e in (item.get("set") or {}).get("elem") or []:
#                        if isinstance(e, dict):
#                            e = (e.get("elem") or {}).get("val", e)
#                        if isinstance(e, str):
#                            members.add(e)
#            except (ValueError, AttributeError):
#                pass
#        by_port.setdefault(port, set()).update(members)
#    return by_port
#
#
#def registered():
#    r = run(ACL, "list", "--json")
#    if r is None or r.returncode != 0:
#        return None
#    try:
#        return {row["ip"] for row in json.loads(r.stdout)}
#    except (ValueError, TypeError, KeyError):
#        return None
#
#
#def state(unit):
#    r = run("systemctl", "is-active", unit)
#    return (r.stdout.strip() or "unknown") if r is not None else "unknown"
#
#
## ---------------------------------------------------------------- commands
#def counts(res, me):
#    """Distinct names per kind. Not lines: every bypass is written twice, once
#    per public resolver, and would otherwise count double."""
#    seen = collections.defaultdict(set)
#    for r in res.rules:
#        seen[meaning(r, me)[0]].add(r.domain)
#    return collections.Counter({k: len(v) for k, v in seen.items()})
#
#
#def cmd_summary():
#    me = self_ip()
#    rs = resolvers()
#    regs = registered()
#    ports = assignment()
#    on_profile = set().union(*ports.values()) if ports else set()
#    print("Fasty DNS routing - this relay answers as %s" % (me or "?"))
#    print()
#    print("  %5s  %9s  %8s  %6s  %6s  %-9s %s"
#          % ("PORT", "CUSTOMERS", "REDIRECT", "BYPASS", "PINNED", "STATE", "TEMPLATE"))
#    for res in rs:
#        if res.key == "main":
#            n = len(regs - on_profile) if regs is not None else "?"
#        else:
#            n = len(ports.get(res.port, ())) if regs is not None or ports else 0
#        c = counts(res, me)
#        print("  %5s  %9s  %8d  %6d  %6d  %-9s %s"
#              % (res.port or "?", n, c["relay"], c["direct"], c["pinned"],
#                 state(res.unit), res.label()))
#    print()
#    print("A template with no customers has no resolver here, so is not listed.")
#    if regs is None:
#        print("(customers are counted from the firewall - run as root to see them)")
#    print("try: smartdns-rules check <domain>    smartdns-rules show <template>")
#    return 0
#
#
#def find(rs, arg):
#    if not arg or arg.lower() in ("main", "default"):
#        return rs[0]
#    for res in rs:
#        if res.key == arg or (res.name and res.name.casefold() == arg.casefold()):
#            return res
#    return None
#
#
#def cmd_show(arg):
#    me = self_ip()
#    rs = resolvers()
#    res = find(rs, arg)
#    if res is None:
#        names, _ = load_names()
#        if any(n.casefold() == arg.casefold() for n in names.values()) or arg in names:
#            print("template %s has no customers, so it has no resolver on this relay "
#                  "yet - it gets one when somebody is put on it." % arg)
#            return 0
#        print("no template %r here. There are: %s"
#              % (arg, ", ".join(r.name or r.key for r in rs)), file=sys.stderr)
#        return 1
#    custom = {r.domain for r in read_rules(os.path.join(DNSMASQ_D, CUSTOM_CONF))}
#    groups = collections.defaultdict(dict)
#    for r in res.rules:
#        kind = meaning(r, me)[0]
#        groups[kind].setdefault(r.domain, r)
#    print("%s - resolver on :%s" % (res.label(), res.port or "?"))
#    titles = (("relay", "redirected to this relay"),
#              ("direct", "bypassed - resolved elsewhere, the customer goes direct"),
#              ("pinned", "pinned to a fixed address"),
#              ("blocked", "answered with nothing"),
#              ("local", "answered locally"))
#    for kind, title in titles:
#        rows = groups.get(kind)
#        if not rows:
#            continue
#        print()
#        print("%s (%d):" % (title, len(rows)))
#        for d in sorted(rows):
#            r = rows[d]
#            tag = "  [custom]" if d in custom else ""
#            if kind in ("direct", "pinned"):
#                print("  %-44s %s%s" % (d, r.target, tag))
#            else:
#                print("  %s%s" % (d, tag))
#    print()
#    print("Anything not listed has no rule: it resolves normally and goes direct.")
#    return 0
#
#
#def clean(raw):
#    d = raw.strip().lower()
#    d = re.sub(r"^[a-z]+://", "", d).split("/")[0].split(":")[0].strip(".")
#    try:
#        d = d.encode("idna").decode("ascii")
#    except UnicodeError:
#        return None
#    return d if DOMAIN.match(d) else None
#
#
#def cmd_check(domains):
#    me = self_ip()
#    rs = resolvers()
#    trouble = 0
#    for raw in domains:
#        name = clean(raw)
#        if not name:
#            print("not a domain: %s" % raw)
#            trouble = 1
#            continue
#        print(name)
#        for res in rs:
#            rule = res.decide(name)
#            kind, shown = meaning(rule, me)
#            live = ask(name, res.port) if res.port else None
#            if live is None:
#                seen, agree = "no answer", False
#            elif not live:
#                seen, agree = "no address", kind not in ("relay", "pinned")
#            else:
#                seen = "answered " + " ".join(live[:2])
#                if kind == "relay":
#                    agree = me in live
#                elif kind == "pinned":
#                    agree = rule.target in live
#                else:
#                    agree = me not in live
#            # The rule and the file it came from share one column, so a long
#            # file name cannot push the answer out of line.
#            why = "%s  (%s)" % (shown, rule.source) if rule else shown
#            print("  :%-5s %-7s %-68s %-30s %s"
#                  % (res.port or "?", kind, why, seen, res.label()))
#            if not agree:
#                trouble = 1
#                if live is None:
#                    print("  ! the resolver did not answer - is %s running?" % res.unit)
#                else:
#                    print("  ! its rules say %s, but that is not what it answered - "
#                          "it may be running on old config: systemctl restart %s"
#                          % (kind, res.unit))
#    return trouble
#
#
#def main(argv):
#    try:
#        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
#    except Exception:
#        pass
#    # `smartdns-rules show | head` closes the pipe early; that is the reader
#    # being done, not an error worth a traceback.
#    if hasattr(signal, "SIGPIPE"):
#        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
#    usage = __doc__.split("\n\n")[1]
#    if not argv:
#        return cmd_summary()
#    cmd, rest = argv[0], argv[1:]
#    if cmd in ("-h", "--help", "help"):
#        print(usage)
#        return 0
#    if cmd == "show":
#        return cmd_show(" ".join(rest) if rest else None)
#    if cmd == "check" and rest:
#        return cmd_check(rest)
#    print(usage, file=sys.stderr)
#    return 2
#
#
#if __name__ == "__main__":
#    sys.exit(main(sys.argv[1:]))
#__END_SMARTDNS_RULES__

#__BEGIN_SMARTDNS_RESTART__
##!/bin/bash
## smartdns-restart - restart every part of Fasty DNS on this machine at once.
##
## usage: smartdns-restart      restart them all, then say which came back up
##        smartdns-restart -h   this help
#set -uo pipefail
#
## Where this machine's config lives, and its templates' resolvers. Variables
## only so a test can point them somewhere else; nothing else sets them.
#ETC="${SMARTDNS_ETC:-/etc/smart-dns}"
#PROFILES="${SMARTDNS_PROFILES:-/etc/smartdns-profiles}"
#
#case "${1:-}" in
#    "") ;;
#    -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
#    *) echo "unknown option: $1  (try -h)" >&2; exit 1 ;;
#esac
#[ "$(id -u)" = 0 ] || { echo "run as root:  sudo smartdns-restart" >&2; exit 1; }
#
## Services only. The timers are clocks with nothing to unstick, and nftables is
## left alone on purpose: restarting it reloads the rules from disk, which throws
## away the allowlist and the usage counted since the last save.
#if [ -f "$ETC/sync.env" ]; then
#    role=relay
#    resolvers=""
#    for f in "$PROFILES"/*.conf; do
#        [ -e "$f" ] || continue
#        resolvers="$resolvers smartdns-dns@$(basename "$f" .conf)"
#    done
#    units="smartdns-sync$resolvers dnsmasq coturn smartdns-tunnel nginx"
#elif [ -f "$ETC/panel.env" ]; then
#    role=exit
#    units="smartdns-panel smartdns-admin smartdns-bot smartdns-tunnel nginx"
#elif [ -f "$ETC/exit.env" ]; then
#    role=extra
#    units="nginx smartdns-tunnel"
#else
#    echo "Fasty DNS is not installed on this machine" >&2
#    exit 1
#fi
#
#installed() { [ "$(systemctl show -p LoadState --value "$1" 2>/dev/null)" = loaded ]; }
#
## A service that failed too often in a row is refused a restart until its
## failures are forgotten - and that is exactly when somebody reaches for this.
#restart() {
#    systemctl reset-failed "$@" 2>/dev/null
#    systemctl restart "$@" 2>&1 | sed 's/^/    /'
#}
#
#echo "restarting Fasty DNS - $role"
#[ "$role" = relay ] && echo "customers' open connections drop for a moment and come straight back"
#echo
#
#skipped=""
#if [ "$role" = relay ]; then
#    # In one call, so systemd restarts each resolver once: they are PartOf the
#    # sync agent and would otherwise go down again with it.
#    restart smartdns-sync $resolvers
#    # A config that does not load would keep dnsmasq down after the restart,
#    # where right now it is at least running on the old one.
#    if out="$(dnsmasq --test -C /etc/dnsmasq.conf 2>&1)"; then
#        restart dnsmasq
#    else
#        echo "  dnsmasq's config does not load, so it was left running as it was:"
#        printf '%s\n' "$out" | sed 's/^/    /'
#        skipped="$skipped dnsmasq"
#    fi
#    restart coturn
#else
#    installed smartdns-panel && restart smartdns-panel
#    installed smartdns-admin && restart smartdns-admin
#    installed smartdns-bot && restart smartdns-bot
#fi
## The tunnel, when there is one, before nginx: nginx falls back to the direct
## path while it is down, so this order costs nobody a connection.
#installed smartdns-tunnel && restart smartdns-tunnel
## The tunnels to extra exits, one instance per exit, on the relay.
#for u in $(systemctl list-units --plain --no-legend 'smartdns-tunnel@*' 2>/dev/null | awk '{print $1}'); do
#    restart "$u"
#    units="$units $u"
#done
## The same for nginx, which carries every customer's traffic.
#if out="$(nginx -t 2>&1)"; then
#    restart nginx
#else
#    echo "  nginx's config does not load, so it was left running as it was:"
#    printf '%s\n' "$out" | sed 's/^/    /'
#    skipped="$skipped nginx"
#fi
#
#sleep 2
#fail=0
#for u in $units; do
#    installed "$u" || continue
#    state="$(systemctl is-active "$u" 2>/dev/null)"
#    case " $skipped " in *" $u "*) state="$state (not restarted)"; fail=1 ;; esac
#    [ "${state%% *}" = active ] || fail=1
#    printf '  %-26s %s\n' "$u" "$state"
#done
#echo
#if [ "$fail" = 0 ]; then
#    echo "all of it is back up"
#else
#    echo "not everything came back - see why with:  sudo smartdns-logs -e"
#    exit 1
#fi
#__END_SMARTDNS_RESTART__

#__BEGIN_SMARTDNS_WATCH__
##!/usr/bin/env python3
#"""smartdns-watch - the names a customer asks for, live, and where each went.
#
#usage: smartdns-watch               everybody, each line naming who asked
#       smartdns-watch ali           one customer, by username
#       smartdns-watch u12           ...or by the label smartdns-acl list shows
#       smartdns-watch 5.200.12.34   ...or by address
#
#For finding what a service needs routed: have the customer open it until it
#fails, and watch. "via relay" is already routed. "direct" went around the
#relay - if the service refuses Iran, those are the names to add, with
#`smartdns add NAME` or the panel's domains page. "filtered in Iran" is Iran's
#own block, which no routing gets past.
#
#It reads this relay's DNS answers off the wire as they leave - the very answer
#the device got, nothing asked again - and keeps nothing: what it prints is all
#there is. Ctrl-C stops it.
#"""
#import collections
#import ipaddress
#import json
#import os
#import signal
#import socket
#import struct
#import subprocess
#import sys
#import time
#
#SYNC_ENV = "/etc/smart-dns/sync.env"
#USER_NAMES = "/var/lib/smart-dns/users.json"
#ACL = "/usr/local/bin/smartdns-acl"
#ETH_P_IP = 0x0800
#SO_ATTACH_FILTER = 26
## The address Iran's filtering hands out for a name it blocks.
#FILTERED = "10.10.34."
## How long a question may go unanswered before it is shown as such. The relay
## drops an unregistered address's questions without a word, so this is also
## how an address that is not allowed shows up.
#WAIT = 3.0
#
## The socket takes every protocol, not IPv4 alone. A socket for one protocol is
## handed only what arrives, and the relay's answers - the half that says where
## each name went - are what it sends; only an every-protocol socket sees those.
## That is what tcpdump does too.
#ETH_P_ALL = 0x0003
#
## A classic BPF program, run in the kernel on every packet: IPv4, UDP, not a
## fragment, with 53 at either end. Everything else - which on a relay is
## nearly all of it, game downloads included - never reaches this process.
## A packet socket of type SOCK_DGRAM hands the filter the IP header at 0; the
## protocol comes from the kernel's own note on the packet.
#BPF = [
#    (0x28, 0, 0, 0xFFFFF000),   # ldh proto         the packet's ethertype
#    (0x15, 0, 10, ETH_P_IP),    # jeq #0x0800       IPv4, or drop
#    (0x30, 0, 0, 9),            # ldb [9]           protocol
#    (0x15, 0, 8, 17),           # jeq #17           UDP, or drop
#    (0x28, 0, 0, 6),            # ldh [6]           flags + fragment offset
#    (0x45, 6, 0, 0x1FFF),       # jset #0x1fff      a later fragment: drop
#    (0xB1, 0, 0, 0),            # ldxb 4*([0]&0xf)  header length
#    (0x48, 0, 0, 0),            # ldh [x+0]         source port
#    (0x15, 2, 0, 53),           # jeq #53           accept
#    (0x48, 0, 0, 2),            # ldh [x+2]         destination port
#    (0x15, 0, 1, 53),           # jeq #53           accept, or drop
#    (0x06, 0, 0, 0x40000),      # ret               accept
#    (0x06, 0, 0, 0),            # ret #0            drop
#]
#
#
#def attach_filter(sock):
#    import ctypes
#    prog = b"".join(struct.pack("HBBI", *ins) for ins in BPF)
#    buf = ctypes.create_string_buffer(prog, len(prog))
#    sock.setsockopt(socket.SOL_SOCKET, SO_ATTACH_FILTER,
#                    struct.pack("HP", len(BPF), ctypes.addressof(buf)))
#
#
## ------------------------------------------------------------------ packets
#def parse_ip_udp(pkt):
#    """(src, dst, sport, dport, payload) of an IPv4 UDP packet, else None."""
#    if len(pkt) < 28 or pkt[0] >> 4 != 4 or pkt[9] != 17:
#        return None
#    ihl = (pkt[0] & 0x0F) * 4
#    if ihl < 20 or len(pkt) < ihl + 8:
#        return None
#    sport, dport, ulen = struct.unpack("!HHH", pkt[ihl:ihl + 6])
#    return (socket.inet_ntoa(pkt[12:16]), socket.inet_ntoa(pkt[16:20]),
#            sport, dport, pkt[ihl + 8:ihl + max(ulen, 8)])
#
#
#def read_name(msg, off):
#    """A DNS name at `off`, and the offset just past where it was written."""
#    labels, end, jumps = [], None, 0
#    while True:
#        if off >= len(msg):
#            raise ValueError("truncated name")
#        n = msg[off]
#        if n & 0xC0 == 0xC0:
#            if off + 1 >= len(msg) or jumps > 20:
#                raise ValueError("bad pointer")
#            if end is None:
#                end = off + 2
#            off = ((n & 0x3F) << 8) | msg[off + 1]
#            jumps += 1
#            continue
#        if n & 0xC0:
#            raise ValueError("bad label")
#        if n == 0:
#            return ".".join(labels).lower(), (off + 1 if end is None else end)
#        labels.append(msg[off + 1:off + 1 + n].decode("ascii", "replace"))
#        off += 1 + n
#
#
#def parse_dns(msg):
#    """(id, is_response, rcode, name, qtype, [A addresses]) or None."""
#    if len(msg) < 12:
#        return None
#    qid, flags, qdcount, ancount = struct.unpack("!HHHH", msg[:8])
#    if qdcount != 1:
#        return None
#    try:
#        name, off = read_name(msg, 12)
#        qtype = struct.unpack("!H", msg[off:off + 2])[0]
#        off += 4
#        addrs = []
#        for _ in range(ancount if flags & 0x8000 else 0):
#            _, off = read_name(msg, off)
#            rtype, _, _, rdlen = struct.unpack("!HHIH", msg[off:off + 10])
#            off += 10
#            if rtype == 1 and rdlen == 4 and off + 4 <= len(msg):
#                addrs.append(socket.inet_ntoa(msg[off:off + 4]))
#            off += rdlen
#    except (ValueError, struct.error):
#        return None
#    return qid, bool(flags & 0x8000), flags & 0x0F, name, qtype, addrs
#
#
## ------------------------------------------------------------------ watching
#class Watcher:
#    """Pairs each question with its answer and prints a line per name.
#
#    A name is printed once, and again only if where it went changes - a CDN
#    hands out a different address every few seconds, which is not news.
#    """
#
#    def __init__(self, relay_ips, who, targets=None, out=None, clock=time.time):
#        self.local = set(relay_ips)
#        self.who = who
#        self.targets = targets
#        self.out = out or (lambda line: print(line, flush=True))
#        self.clock = clock
#        self.pending = {}
#        self.shown = {}
#        self.counts = collections.Counter()
#
#    def feed(self, pkt):
#        p = parse_ip_udp(pkt)
#        if not p:
#            return
#        src, dst, sport, dport, payload = p
#        if dport == 53 and src not in self.local:
#            client, port, asking = src, sport, True
#        elif sport == 53 and src in self.local and dst not in self.local:
#            client, port, asking = dst, dport, False
#        else:
#            return      # this relay asking its own upstream, or being answered
#        if self.targets is not None and client not in self.targets:
#            return
#        d = parse_dns(payload)
#        if not d:
#            return
#        qid, is_answer, rcode, name, qtype, addrs = d
#        if qtype != 1 or not name:
#            return      # AAAA and the rest: the relay serves IPv4 only
#        if asking and not is_answer:
#            self.pending[(client, port, qid)] = (name, self.clock())
#        elif is_answer and not asking:
#            self.pending.pop((client, port, qid), None)
#            self.report(client, name, self.verdict(rcode, addrs))
#
#    def verdict(self, rcode, addrs):
#        if rcode == 3:
#            return "no such name"
#        if rcode:
#            return "refused (rcode %d)" % rcode
#        if any(a in self.local for a in addrs):
#            return "via relay"
#        if any(a.startswith(FILTERED) for a in addrs):
#            return "filtered in Iran"
#        if addrs:
#            return "direct " + addrs[0]
#        return "no address"
#
#    def tick(self):
#        now = self.clock()
#        for key, (name, when) in list(self.pending.items()):
#            if now - when >= WAIT:
#                del self.pending[key]
#                self.report(key[0], name, "no answer")
#
#    def report(self, client, name, verdict):
#        kind = "direct" if verdict.startswith("direct") else verdict
#        if self.shown.get((client, name)) == kind:
#            return
#        self.shown[(client, name)] = kind
#        self.counts[kind.split(" (")[0]] += 1
#        stamp = time.strftime("%H:%M:%S", time.localtime(self.clock()))
#        who = "" if self.targets and len(self.targets) == 1 else \
#            "%-14s " % self.who.get(client, client)[:14]
#        self.out("%s  %s%-44s %s" % (stamp, who, name, verdict))
#
#    def summary(self):
#        total = sum(self.counts.values())
#        if not total:
#            return "no names seen"
#        parts = ["%d %s" % (n, k) for k, n in self.counts.most_common()]
#        return "%d names: %s" % (total, ", ".join(parts))
#
#
## ------------------------------------------------------------------ who is who
#def run(*args):
#    try:
#        return subprocess.run(list(args), capture_output=True, text=True, timeout=20)
#    except (OSError, subprocess.SubprocessError):
#        return None
#
#
#def self_ip():
#    try:
#        with open(SYNC_ENV) as fh:
#            for line in fh:
#                k, _, v = line.strip().partition("=")
#                if k.strip() == "SELF_IP":
#                    return v.strip().strip('"').strip("'")
#    except OSError:
#        pass
#    return None
#
#
#def local_addresses():
#    found = {"127.0.0.1"}
#    r = run("ip", "-4", "-o", "addr", "show")
#    for line in (r.stdout if r else "").splitlines():
#        parts = line.split()
#        if "inet" in parts:
#            found.add(parts[parts.index("inet") + 1].split("/")[0])
#    mine = self_ip()
#    if mine:
#        found.add(mine)
#    return found
#
#
#def load_users():
#    """{ip: {"label": "u12", "user": "ali"}} and the set that is allowed.
#
#    Usernames come from the panel by way of the sync agent. An older panel sends
#    none, and then the labels from the allowlist are all there is.
#    """
#    users = {}
#    try:
#        with open(USER_NAMES, encoding="utf-8") as fh:
#            data = json.load(fh)
#        if isinstance(data, dict):
#            users = {ip: v for ip, v in data.items() if isinstance(v, dict)}
#    except (OSError, ValueError):
#        pass
#    allowed = set()
#    r = run(ACL, "list", "--json")
#    try:
#        for row in json.loads(r.stdout) if r and r.returncode == 0 else []:
#            allowed.add(row["ip"])
#            users.setdefault(row["ip"], {"label": row.get("name", ""), "user": ""})
#    except (ValueError, KeyError, TypeError):
#        pass
#    return users, allowed
#
#
#def resolve(arg, users):
#    """The addresses an argument means: itself, or a customer's."""
#    try:
#        return {str(ipaddress.IPv4Address(arg.strip()))}
#    except ValueError:
#        pass
#    want = arg.strip().lower()
#    return {ip for ip, u in users.items()
#            if want and want in ((u.get("user") or "").lower(),
#                                 (u.get("label") or "").lower())}
#
#
#def display(users):
#    return {ip: (u.get("user") or u.get("label") or ip) for ip, u in users.items()}
#
#
## ------------------------------------------------------------------ main
#def main(argv):
#    try:
#        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
#    except Exception:
#        pass
#    if hasattr(signal, "SIGPIPE"):
#        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
#    usage = __doc__.split("\n\n")[1]
#    if argv and argv[0] in ("-h", "--help"):
#        print(usage)
#        return 0
#    if len(argv) > 1 or (argv and argv[0].startswith("-")):
#        print(usage, file=sys.stderr)
#        return 2
#    if os.geteuid() != 0:
#        print("run as root:  sudo smartdns-watch", file=sys.stderr)
#        return 1
#    if not os.path.exists(SYNC_ENV):
#        print("this is not a relay - run it where the customers' DNS is answered",
#              file=sys.stderr)
#        return 1
#
#    users, allowed = load_users()
#    who = display(users)
#    targets = None
#    if argv:
#        targets = resolve(argv[0], users)
#        if not targets:
#            print("no customer or address matches %r - the registered ones:  "
#                  "sudo smartdns-acl list" % argv[0], file=sys.stderr)
#            return 1
#
#    try:
#        sock = socket.socket(socket.AF_PACKET, socket.SOCK_DGRAM,
#                             socket.htons(ETH_P_ALL))
#        attach_filter(sock)
#    except (OSError, AttributeError) as e:
#        print("cannot watch the network here: %s" % e, file=sys.stderr)
#        return 1
#
#    if targets:
#        print("watching %s - ctrl-c to stop" % ", ".join(
#            "%s (%s)" % (ip, who.get(ip, "not registered")) for ip in sorted(targets)))
#    else:
#        print("watching everybody - ctrl-c to stop")
#    print("  via relay = already goes through the exit   direct = goes around it"
#          "   filtered = blocked inside Iran\n", flush=True)
#    for ip in sorted(targets or ()):
#        if ip not in allowed:
#            print("  note: %s is not allowed on this relay, so its questions are "
#                  "dropped - they will show as 'no answer'\n" % ip, flush=True)
#
#    # timeout(1) and systemd stop with SIGTERM; end the same way ctrl-c does.
#    def stop(*_):
#        raise KeyboardInterrupt
#    signal.signal(signal.SIGTERM, stop)
#
#    w = Watcher(local_addresses(), who, targets)
#    sock.settimeout(0.5)
#    try:
#        while True:
#            try:
#                w.feed(sock.recv(65535))
#            except socket.timeout:
#                pass
#            w.tick()
#    except KeyboardInterrupt:
#        print("\n" + w.summary())
#    return 0
#
#
#if __name__ == "__main__":
#    sys.exit(main(sys.argv[1:]))
#__END_SMARTDNS_WATCH__

#__BEGIN_TUNNEL_SERVICE__
#[Unit]
#Description=Fasty DNS tunnel between the relay and the exit (BackPack)
#After=network-online.target
#Wants=network-online.target
#
#[Service]
## BackPack keeps one tunnel running from this file, and redials on its own when
## the other end goes away. Its menu, web panel and kernel tuning stay off: the
## file says so, and this machine's tuning is the installer's to decide.
## The listening end's firewall rule - its port answers the other machine only.
## Loaded here as well as at boot, since an exit's nftables service does not
## read /etc/nftables.d; the leading - makes a missing file (the dialling end)
## no failure.
#ExecStartPre=-/usr/sbin/nft -f /etc/nftables.d/40-smartdns-tunnel.conf
#ExecStart=/usr/local/lib/smart-dns/backpack -c /etc/smart-dns/tunnel/tunnel.toml
#Restart=always
#RestartSec=5
## Every customer connection is a stream in the tunnel, and a console download
## opens dozens at once.
#LimitNOFILE=65535
#
#[Install]
#WantedBy=multi-user.target
#__END_TUNNEL_SERVICE__

#__BEGIN_SMARTDNS_TUNNEL__
##!/bin/bash
## smartdns-tunnel - the tunnel between the relay and the exit: see it, stop it, start it.
##
## usage: smartdns-tunnel          what it is, and whether it is carrying traffic
##        smartdns-tunnel off      back to plain TCP, now
##        smartdns-tunnel on       start it again, with the settings it had
##
## Either end will do for off: the relay's nginx goes straight to the exit the
## moment its end of the tunnel stops answering, whichever machine stopped it.
## To change the transport, the port or which end dials, run the installer with
## --tunnel on the exit and then on the relay.
##
## The tunnel itself is BackPack, the work of Amin Mohammadi:
## github.com/AminMGMT/BackPack (AGPL-3.0).
#set -uo pipefail
#
## Where this machine's config lives. A variable only so a test can point it
## somewhere else; nothing else sets it.
#ETC="${SMARTDNS_ETC:-/etc/smart-dns}"
#UNIT=smartdns-tunnel.service
#LOCAL_HTTPS=18443
#
#case "${1:-status}" in
#    status|off|on) ;;
#    -h|--help) sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
#    *) echo "unknown command: $1  (try -h)" >&2; exit 1 ;;
#esac
#[ "$(id -u)" = 0 ] || { echo "run as root:  sudo smartdns-tunnel" >&2; exit 1; }
#
#if [ -f "$ETC/sync.env" ]; then role=relay; env="$ETC/sync.env"
#elif [ -f "$ETC/panel.env" ]; then role=exit; env="$ETC/panel.env"
#elif [ -f "$ETC/exit.env" ]; then role=extra; env="$ETC/exit.env"
#else echo "Fasty DNS is not installed on this machine" >&2; exit 1; fi
#
#get() { sed -n "s/^$1=//p" "$env" 2>/dev/null | head -1; }
#set_key() {
#    local tmp; tmp="$(mktemp)"
#    grep -v "^$1=" "$env" > "$tmp" 2>/dev/null || true
#    printf '%s=%s\n' "$1" "$2" >> "$tmp"
#    cat "$tmp" > "$env"; rm -f "$tmp"
#}
## Set up by the installer, whether on or off at the moment.
#configured() { [ -f "$ETC/tunnel/tunnel.toml" ] && [ -n "$(get TUNNEL_TRANSPORT)" ]; }
#
## The tunnels to extra exits, which the sync agent runs one of per exit. Not
## the pair's own tunnel above: these have no settings on this machine but the
## config the sync agent writes from what the panel sends.
#extra_tunnels() {
#    local u state conf port
#    for u in $(systemctl list-units --plain --no-legend 'smartdns-tunnel@*' 2>/dev/null | awk '{print $1}'); do
#        conf="$ETC/tunnel/$(echo "$u" | sed 's/smartdns-tunnel@//; s/\.service$//').toml"
#        port="$(sed -n 's/^addr = "[^:]*:\([0-9]*\)"/\1/p' "$conf" 2>/dev/null | head -1)"
#        state="$(systemctl is-active "$u" 2>/dev/null || true)"
#        printf 'exit       %s - %s, port %s\n' "$u" "$state" "${port:-?}"
#    done
#}
#
#show() {
#    if ! configured; then
#        echo "no tunnel is set up on this $role - the relay reaches the exit directly."
#        echo "to set one up:  sudo bash doctor-dns.sh --tunnel   (on the exit first, then the relay)"
#        return 0
#    fi
#    local port; port="$(get TUNNEL_PORT)"
#    printf 'tunnel     BackPack, %s, %s, port %s\n' "$(get TUNNEL_TRANSPORT)" "$(get TUNNEL_DIRECTION)" "$port"
#    printf 'setting    %s\n' "$([ "$(get TUNNEL)" = backpack ] && echo on || echo off)"
#    printf 'service    %s\n' "$(systemctl is-active $UNIT 2>/dev/null || true)"
#    if [ "$role" = extra ]; then
#        printf 'connected  %s tunnel connection(s) with the relay\n' \
#            "$(ss -Htn state established "( sport = :$port )" 2>/dev/null | wc -l)"
#    elif [ "$role" = relay ]; then
#        # Straight at the tunnel's own end: through nginx the fallback would
#        # answer too, and say nothing about the tunnel.
#        local code
#        code="$(curl -s -o /dev/null -m 8 --connect-to "github.com:443:127.0.0.1:$LOCAL_HTTPS" \
#                -w '%{http_code}' https://github.com/ 2>/dev/null || true)"
#        if [ "$code" = 200 ]; then
#            echo "traffic    through the tunnel"
#        else
#            echo "traffic    straight to the exit - the tunnel is not carrying anything"
#        fi
#    else
#        printf 'connected  %s tunnel connection(s) with the relay\n' \
#            "$(ss -Htn state established "( sport = :$port or dport = :$port )" 2>/dev/null | wc -l)"
#    fi
#}
#
#case "${1:-status}" in
#status)
#    show ;;
#off)
#    if ! configured; then show; exit 0; fi
#    systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
#    # Kept, so an upgrade does not quietly bring it back.
#    set_key TUNNEL off
#    echo "tunnel stopped - traffic goes straight to the exit now."
#    [ "$role" = relay ] && echo "nginx falls back to the direct path by itself; nothing else to do here."
#    echo "the other machine's end keeps trying to reach this one, which does no harm;"
#    echo "stop it there as well with:  sudo smartdns-tunnel off"
#    ;;
#on)
#    if ! configured; then show; exit 1; fi
#    set_key TUNNEL backpack
#    systemctl enable --now "$UNIT" >/dev/null 2>&1 || true
#    sleep 4
#    show
#    echo
#    echo "if it is not carrying traffic yet, the other machine's end may be off:  sudo smartdns-tunnel on"
#    ;;
#esac
#__END_SMARTDNS_TUNNEL__

#__BEGIN_TUNNEL_EXIT_SERVICE__
#[Unit]
#Description=Fasty DNS tunnel to an extra exit (BackPack) - %i
#After=network-online.target
#Wants=network-online.target
## One instance per extra exit that has a tunnel, started and stopped by the
## sync agent as the panel's list of exits changes. This relay always dials:
## the exit listens, so there is no port to open here and no rule to hold.
#PartOf=smartdns-sync.service
#
#[Service]
#ExecStart=/usr/local/lib/smart-dns/backpack -c /etc/smart-dns/tunnel/%i.toml
#Restart=always
#RestartSec=5
## Every customer connection is a stream in the tunnel, and a console download
## opens dozens at once.
#LimitNOFILE=65535
#
#[Install]
#WantedBy=multi-user.target
#__END_TUNNEL_EXIT_SERVICE__

#__BEGIN_SMARTDNS_MENU__
##!/bin/bash
## smartdns-menu - every Fasty DNS command in one place, for when you do not
## remember the name of the one you want.
##
## usage: sudo smartdns-menu
##
## Each choice shows the command it runs before running it, so the next time you
## can type it yourself. Ctrl-C stops that command and comes back here.
#set -uo pipefail
#
## Where this machine's config lives. Variables only so a test can point them
## somewhere else; nothing else sets them.
#ETC="${SMARTDNS_ETC:-/etc/smart-dns}"
#VERSION_FILE="${SMARTDNS_VERSION_FILE:-/var/lib/smart-dns/version}"
#REPO="https://github.com/AmirhosseinAshouri/doctor-dns-private"
#
#B=$'\e[1m'; D=$'\e[2m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
#[ -t 1 ] || { B=; D=; G=; Y=; N=; }
#
#case "${1:-}" in
#    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
#    "") ;;
#    *) echo "unknown option: $1  (try -h)" >&2; exit 1 ;;
#esac
#[ "$(id -u)" = 0 ] || { echo "run as root:  sudo smartdns-menu" >&2; exit 1; }
#if [ -f "$ETC/sync.env" ]; then role=relay
#elif [ -f "$ETC/panel.env" ]; then role=exit
#elif [ -f "$ETC/exit.env" ]; then role=extra
#else echo "Fasty DNS is not installed on this machine" >&2; exit 1; fi
#VERSION="$(cat "$VERSION_FILE" 2>/dev/null || echo '?')"
#
## ------------------------------------------------------------------ helpers
#pause() { printf '\n%spress enter to go back%s ' "$D" "$N"; read -r _ || exit 0; }
#
## Show a command, then run it. Ctrl-C ends the command, not the menu.
#run() {
#    printf '\n%s$ %s%s\n\n' "$G" "$*" "$N"
#    trap ':' INT
#    "$@"
#    trap - INT
#    pause
#}
#
## Ask for one value into REPLY. An empty answer means go back.
#ask() { printf '  %s: ' "$1"; read -r REPLY || exit 0; [ -n "$REPLY" ]; }
#
#sure() {
#    local a
#    printf '  %s%s%s [y/N]: ' "$Y" "$1" "$N"; read -r a || exit 0
#    case "$a" in y|Y|yes) return 0 ;; esac
#    return 1
#}
#
## A menu: a title, then "label|action" items. The action is evaluated when
## chosen; what the user typed reaches commands as "$REPLY", quoted, and is
## never evaluated itself.
#choose() {
#    local title="$1" c i item back="${BACK:-back}"; shift
#    # The label is this menu's alone: the menus opened from here go back.
#    BACK=back
#    while :; do
#        printf '\n%s%s%s\n\n' "$B" "$title" "$N"
#        i=0
#        for item in "$@"; do
#            i=$((i + 1))
#            printf '  %2d) %s\n' "$i" "${item%%|*}"
#        done
#        printf '   0) %s\n\n' "$back"
#        printf 'choice: '; read -r c || exit 0
#        case "$c" in 0|q) return 0 ;; ""|*[!0-9]*) continue ;; esac
#        [ "$c" -le "$i" ] || continue
#        item="${!c}"
#        eval "${item#*|}"
#    done
#}
#
## ------------------------------------------------------------------ actions
#watch_customer() {
#    printf '  username, label (u12) or address - enter for everybody: '
#    read -r REPLY || exit 0
#    if [ -n "$REPLY" ]; then run smartdns-watch "$REPLY"; else run smartdns-watch; fi
#}
#
#add_address() {
#    local ip
#    ask "address" || return 0; ip="$REPLY"
#    printf '  a name for it (optional): '; read -r REPLY || exit 0
#    if [ -n "$REPLY" ]; then run smartdns-acl add "$ip" "$REPLY"; else run smartdns-acl add "$ip"; fi
#}
#
#reset_counters() {
#    printf '  address, or --all for everyone: '; read -r REPLY || exit 0
#    [ -n "$REPLY" ] || return 0
#    sure "zero the usage of $REPLY?" && run smartdns-acl reset "$REPLY"
#}
#
## The installer of the version this machine runs: a copy already here, or the
## release of that version from GitHub. The same version, so changing a setting
## never upgrades anything along the way.
#installer() {
#    local f
#    for f in /root/doctor-dns.sh "${SUDO_USER:+/home/$SUDO_USER/doctor-dns.sh}" ./doctor-dns.sh; do
#        if [ -n "$f" ] && [ -f "$f" ] && [ "$(bash "$f" --version 2>/dev/null)" = "$VERSION" ]; then
#            run bash "$f" "$@"; return 0
#        fi
#    done
#    # The code is in a private repository, so nothing is fetched from here:
#    # the operator copies the file in, from their own computer.
#    echo "  there is no copy of the installer for $VERSION on this machine."
#    echo "  copy doctor-dns.sh v$VERSION from $REPO/releases to /root/ -"
#    echo "      scp doctor-dns.sh root@THIS-SERVER:/root/"
#    echo "  and choose this again."
#    pause
#}
#
## The code is in a private repository, so this machine cannot fetch a new
## version: the operator copies it in, and this runs the copy it finds.
#update() {
#    local f=/root/doctor-dns.sh latest
#    if [ ! -f "$f" ]; then
#        printf '\n  There is no new copy here to update from. Download doctor-dns.sh from\n'
#        printf '  %s/releases on your own computer, copy it in -\n\n' "$REPO"
#        printf '      scp doctor-dns.sh root@THIS-SERVER:/root/\n\n'
#        printf '  and choose this again.\n'
#        pause; return 0
#    fi
#    latest="$(bash "$f" --version 2>/dev/null || echo '?')"
#    printf '  installed: %s    the copy in /root: %s\n' "$VERSION" "$latest"
#    if [ "$latest" = "$VERSION" ]; then
#        sure "the same version - run it anyway, to check and repair?" || return 0
#    else
#        sure "run it on this $role, $VERSION -> $latest?" || return 0
#    fi
#    run bash "$f"
#}
#
#uninstall() {
#    local a
#    printf '  %sThis removes Fasty DNS from this machine.%s type uninstall to go ahead: ' "$Y" "$N"
#    read -r a || exit 0
#    [ "$a" = uninstall ] && installer --uninstall
#}
#
## ------------------------------------------------------------------ menus
#menu_logs() {
#    local items=(
#        'each part: running or not, and its recent logs   (smartdns-logs)|run smartdns-logs'
#        'only warnings and errors   (smartdns-logs -e)|run smartdns-logs -e'
#        'follow the logs live, ctrl-c to stop   (smartdns-logs -f)|run smartdns-logs -f'
#        'more lines per part   (smartdns-logs -n)|ask "lines per part" && run smartdns-logs -n "$REPLY"'
#        'one file to send, secrets masked   (smartdns-logs --report)|run smartdns-logs --report'
#    )
#    [ "$role" = relay ] && items+=(
#        'what this relay is doing   (smartdns status)|run smartdns status'
#        'the names a customer asks for, live   (smartdns-watch)|watch_customer'
#    )
#    choose "Status and logs" "${items[@]}"
#}
#
#menu_domains() {
#    choose "Domains" \
#        'every routed domain   (smartdns list)|run smartdns list' \
#        'routed domains matching a word   (smartdns find)|ask "word" && run smartdns find "$REPLY"' \
#        'route a domain through the exit   (smartdns add)|ask "domain" && run smartdns add "$REPLY"' \
#        'stop routing a domain   (smartdns del)|ask "domain" && run smartdns del "$REPLY"' \
#        'never route a domain, even under a routed one   (smartdns bypass)|ask "domain" && run smartdns bypass "$REPLY"' \
#        'undo a bypass   (smartdns unbypass)|ask "domain" && run smartdns unbypass "$REPLY"' \
#        'what this relay answers for a domain   (smartdns test)|ask "domain" && run smartdns test "$REPLY"' \
#        'what every template does with a domain   (smartdns-rules check)|ask "domain" && run smartdns-rules check "$REPLY"' \
#        'every template: its port, customers and rules   (smartdns-rules)|run smartdns-rules' \
#        'one template'"'"'s full lists   (smartdns-rules show)|ask "template name" && run smartdns-rules show "$REPLY"'
#}
#
#menu_customers() {
#    choose "Customers and access" \
#        'everyone, with usage   (smartdns-acl list)|run smartdns-acl list' \
#        'one address   (smartdns-acl usage)|ask "address" && run smartdns-acl usage "$REPLY"' \
#        'register an address by hand   (smartdns-acl add)|add_address' \
#        'remove an address   (smartdns-acl del)|ask "address" && sure "remove $REPLY?" && run smartdns-acl del "$REPLY"' \
#        'zero the usage counters   (smartdns-acl reset)|reset_counters' \
#        'closed to strangers, or open?   (smartdns-acl enforce status)|run smartdns-acl enforce status' \
#        'close it: registered addresses only   (smartdns-acl enforce on)|sure "only registered addresses will get through - go ahead?" && run smartdns-acl enforce on' \
#        'open it to everyone   (smartdns-acl enforce off)|sure "anyone who finds this relay could use it - go ahead?" && run smartdns-acl enforce off' \
#        'save the allowlist to disk now   (smartdns-acl save)|run smartdns-acl save' \
#        'speed limits in force   (smartdns-shape list)|run smartdns-shape list' \
#        'remove every speed limit   (smartdns-shape off)|sure "every customer goes unlimited until the next sync - go ahead?" && run smartdns-shape off'
#}
#
#menu_admin() {
#    choose "Admin panel" \
#        'its address - forgot it? start here   (smartdns-access)|run smartdns-access' \
#        'move it to another port   (smartdns-access port)|ask "new port" && run smartdns-access port "$REPLY"' \
#        'a new secret path   (smartdns-access path)|sure "the old address stops working - go ahead?" && run smartdns-access path' \
#        'a new password   (smartdns-access password)|run smartdns-access password' \
#        'new path and new password at once   (smartdns-access rotate)|sure "the old address and password stop working - go ahead?" && run smartdns-access rotate'
#}
#
#menu_bot() {
#    choose "Telegram bot" \
#        'its token, name, admins and the relay it links to   (smartdns-bot status)|run smartdns-bot status' \
#        'set the bot token   (smartdns-bot token)|run smartdns-bot token' \
#        'a one-time code for becoming its admin   (smartdns-bot code)|run smartdns-bot code' \
#        'switch the bot off   (smartdns-bot off)|sure "the bot stops answering customers - go ahead?" && run smartdns-bot off'
#}
#
#menu_tunnel() {
#    choose "Tunnel between the relay and the exit" \
#        'is it on, and carrying traffic?   (smartdns-tunnel)|run smartdns-tunnel' \
#        'turn it off - plain TCP from now on   (smartdns-tunnel off)|sure "traffic goes straight to the exit from now on - go ahead?" && run smartdns-tunnel off' \
#        'turn it back on   (smartdns-tunnel on)|run smartdns-tunnel on' \
#        'change it: transport, port, which end dials   (doctor-dns.sh --tunnel)|installer --tunnel'
#}
#
#menu_install() {
#    choose "Installation" \
#        "the version installed here: $VERSION   (doctor-dns.sh --version)|printf '\n  %s\n' \"\$VERSION\"; pause" \
#        'update from a new copy in /root|update' \
#        'get or renew a certificate   (smartdns-cert)|ask "domain" && run smartdns-cert "$REPLY"' \
#        'remove Fasty DNS from this machine   (doctor-dns.sh --uninstall)|uninstall'
#}
#
#restart_all() {
#    if [ "$role" = relay ]; then
#        sure "customers' open connections drop for a moment - go ahead?" || return 0
#    fi
#    run smartdns-restart
#}
#
#main() {
#    local items
#    if [ "$role" = relay ]; then
#        items=(
#            'status and logs|menu_logs'
#            'domains|menu_domains'
#            'customers and access|menu_customers'
#            'tunnel to the exit|menu_tunnel'
#            'restart everything   (smartdns-restart)|restart_all'
#            'installation, updates and certificates|menu_install'
#        )
#    else
#        items=(
#            'status and logs|menu_logs'
#            'admin panel|menu_admin'
#            'tunnel to the relay|menu_tunnel'
#            'restart everything   (smartdns-restart)|restart_all'
#            'installation, updates and certificates|menu_install'
#            'telegram bot|menu_bot'
#        )
#    fi
#    # An extra exit is nginx and nothing else of ours: no panel, bot or tunnel.
#    if [ "$role" = extra ]; then
#        items=(
#            'status and logs|menu_logs'
#            'restart everything   (smartdns-restart)|restart_all'
#            'installation, updates and certificates|menu_install'
#        )
#    fi
#    BACK=quit choose "Fasty DNS $VERSION - $role" "${items[@]}"
#}
#
#main
#__END_SMARTDNS_MENU__

#__BEGIN_SMARTDNS_API_GUARD__
##!/bin/bash
## smartdns-api-guard - let only the relays reach this exit's sync API (8443).
##
## usage: smartdns-api-guard           load the rule
##        smartdns-api-guard --print   show the rule, and load nothing
##
## The panel already refuses any address that is not one of its relays, but only
## after the TLS handshake: a stranger still gets that far, and enough strangers
## holding connections open can wear the API down. Dropped here, they never get
## a connection at all.
##
## smartdns-panel.service runs this before every start, so the list is always
## the RELAY_IP the panel itself reads: a relay added there by hand is let in
## the next time the panel restarts, as it would be by the panel.
#set -u
#
## Variables only so a test can point them somewhere else; nothing else sets them.
#ETC="${SMARTDNS_ETC:-/etc/smart-dns}"
#NFT="${SMARTDNS_NFT:-/usr/sbin/nft}"
#
#valid_ip() {
#    local IFS=. p
#    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
#    for p in $1; do [ "$p" -le 255 ] || return 1; done
#}
#
#list="127.0.0.1"
#for ip in $(sed -n 's/^RELAY_IP=//p' "$ETC/panel.env" 2>/dev/null | head -1 | tr ',' ' '); do
#    if valid_ip "$ip"; then list="$list, $ip"
#    else echo "ignoring '$ip' in RELAY_IP - not an IPv4 address" >&2; fi
#done
#[ "$list" = "127.0.0.1" ] && echo "no relays in RELAY_IP - only this machine will reach 8443" >&2
#
#rules="table inet smartdns_api
#delete table inet smartdns_api
#table inet smartdns_api {
#    chain input {
#        type filter hook input priority -5 ; policy accept ;
#        tcp dport 8443 ip saddr { $list } accept
#        tcp dport 8443 drop
#    }
#}"
#
#case "${1:-}" in
#    --print) printf '%s\n' "$rules"; exit 0 ;;
#    -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
#    "") ;;
#    *) echo "unknown option: $1  (try -h)" >&2; exit 1 ;;
#esac
#
#[ -x "$NFT" ] || NFT="$(command -v nft || true)"
#if [ -z "$NFT" ]; then
#    echo "nft is not installed - the sync API stays open, and the panel refuses strangers itself" >&2
#    exit 0
#fi
#if printf '%s\n' "$rules" | "$NFT" -f -; then
#    echo "port 8443 answers: $list"
#else
#    echo "nft refused the rule - the sync API stays open, and the panel refuses strangers itself" >&2
#fi
#exit 0
#__END_SMARTDNS_API_GUARD__

#__BEGIN_EPIC_PIN__
##!/usr/bin/env python3
#"""Pin Epic's backend names to the addresses that are actually reachable here.
#
#Epic's game backend must NOT be routed through the exit: matchmaking has to come
#from the same address the console later plays from, or the game server ignores
#the gameplay packets. See docs/fortnite-udp.md.
#
#But letting it resolve normally has its own failure. Epic round-robins each name
#across many addresses and a few are unreachable from Iran - one in thirty-three
#when sampled. A console that draws a dead one stalls on that service, which is
#why Fortnite worked on some attempts and not others.
#
#So pin each name to addresses verified reachable. Those address= entries are more
#specific than the server= bypass rule, so dnsmasq prefers them.
#
#The important part is knowing when NOT to act. Epic's address sets rotate
#constantly, so the first version of this rewrote the file on nearly every run -
#and since dnsmasq cannot re-read its config without a restart, that meant
#restarting the resolver every ten minutes, all day. Each restart is a brief DNS
#outage and a full cache flush, which is its own source of exactly the
#intermittent breakage this script exists to prevent. It made a day of test
#results untrustworthy.
#
#So: probe only the addresses already pinned. If they all still answer, do nothing
#at all. Re-resolve and rewrite only when a pinned address has actually died, or
#when there are no pins yet. In the steady state this touches nothing.
#"""
#import concurrent.futures as cf
#import os
#import socket
#import subprocess
#import sys
#
#CONF = "/etc/dnsmasq.d/epic-pins.conf"
#RESOLVERS = ("1.1.1.1", "8.8.8.8")
#PROBE_PORT = 443
#PROBE_TIMEOUT = 2.5
#
#HOSTS = [
#    "account-public-service-prod.ol.epicgames.com",
#    "datarouter.ol.epicgames.com",
#    "launcher-public-service-prod06.ol.epicgames.com",
#    "links-public-service-live.ol.epicgames.com",
#    "events-public-service-live.ol.epicgames.com",
#    "datastorage-public-service-live.ol.epicgames.com",
#    "data-asset-directory-public-service-prod.ol.epicgames.com",
#    "fortnitecontent-website-prod07.ol.epicgames.com",
#    "fortnite-public-service-prod11.ol.epicgames.com",
#    "mcp-gc.live.fngw.ol.epicgames.com",
#    "gc.svc.live.fngw.ol.epicgames.com",
#    "ds.svc.live.fngw.ol.epicgames.com",
#    "fngw-svc-ds-livefn.ol.epicgames.com",
#    "fn-service-habanero-live-public.ogs.live.on.epicgames.com",
#    "fn-service-discovery-live-public.ogs.live.on.epicgames.com",
#    "prm-dialogue-public-api-prod.edea.live.use1a.on.epicgames.com",
#]
#
#
#def resolve(host):
#    for r in RESOLVERS:
#        try:
#            out = subprocess.run(
#                ["dig", "+short", "+time=3", "+tries=1", "@" + r, host, "A"],
#                capture_output=True, text=True, timeout=8).stdout
#        except Exception:
#            continue
#        ips = [l.strip() for l in out.splitlines()
#               if l.strip() and l.strip()[0].isdigit() and l.count(".") == 3]
#        if ips:
#            return ips
#    return []
#
#
#def alive(ip):
#    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
#    s.settimeout(PROBE_TIMEOUT)
#    try:
#        s.connect((ip, PROBE_PORT))
#        return True
#    except Exception:
#        return False
#    finally:
#        s.close()
#
#
#def read_pins():
#    """host -> [addresses], from the file we last wrote."""
#    pins = {}
#    if not os.path.exists(CONF):
#        return pins
#    for line in open(CONF):
#        line = line.strip()
#        if not line.startswith("address=/"):
#            continue
#        parts = line.split("/")
#        if len(parts) >= 3:
#            pins.setdefault(parts[1], []).append(parts[2])
#    return pins
#
#
#def main():
#    pins = read_pins()
#
#    # Steady state: everything already pinned still answers, so leave the
#    # resolver alone. Restarting it to write a file that differs only by Epic's
#    # rotation is how this script used to cause the problem it prevents.
#    if pins and set(pins) == set(HOSTS):
#        addrs = sorted({a for v in pins.values() for a in v})
#        with cf.ThreadPoolExecutor(max_workers=16) as ex:
#            health = dict(zip(addrs, ex.map(alive, addrs)))
#        dead = [a for a in addrs if not health[a]]
#        if not dead:
#            print("epic-pin: all %d pinned addresses still healthy, nothing to do"
#                  % len(addrs))
#            return 0
#        print("epic-pin: %d pinned address(es) died (%s), refreshing"
#              % (len(dead), ", ".join(dead[:4])))
#
#    lines = ["# generated by epic-pin - do not edit, changes are overwritten",
#             "# only addresses that answered on tcp/%d from this host" % PROBE_PORT,
#             ""]
#    total = good = 0
#    with cf.ThreadPoolExecutor(max_workers=16) as ex:
#        resolved = dict(zip(HOSTS, ex.map(resolve, HOSTS)))
#        every = sorted({ip for ips in resolved.values() for ip in ips})
#        health = dict(zip(every, ex.map(alive, every)))
#
#    for host in HOSTS:
#        ips = [ip for ip in resolved.get(host, []) if health.get(ip)]
#        total += len(resolved.get(host, []))
#        good += len(ips)
#        if not ips:
#            # Nothing verified: say nothing and let the bypass resolve it live.
#            # A wrong pin is worse than no pin.
#            continue
#        for ip in ips:
#            lines.append("address=/%s/%s" % (host, ip))
#
#    with open(CONF, "w") as fh:
#        fh.write("\n".join(lines) + "\n")
#
#    check = subprocess.run(["dnsmasq", "--test", "-C", "/etc/dnsmasq.conf"],
#                           capture_output=True, text=True)
#    if check.returncode != 0:
#        os.remove(CONF)
#        print("epic-pin: dnsmasq rejected the file, removed it\n" + check.stderr,
#              file=sys.stderr)
#        return 1
#
#    # A reload only clears the cache; dnsmasq does not re-read /etc/dnsmasq.d
#    # without a restart. That is why the syntax check above runs first, and why
#    # reaching this line at all should be rare.
#    subprocess.run(["systemctl", "restart", "dnsmasq"], check=False)
#    print("epic-pin: rewrote pins and restarted dnsmasq (%d/%d healthy)"
#          % (good, total))
#    return 0
#
#
#if __name__ == "__main__":
#    sys.exit(main())
#__END_EPIC_PIN__

#__BEGIN_EPIC_PIN_SERVICE__
#[Unit]
#Description=Pin Epic backend names to reachable addresses
#After=network-online.target dnsmasq.service
#Wants=network-online.target
#
#[Service]
#Type=oneshot
#ExecStart=/usr/local/bin/epic-pin
#TimeoutStartSec=120
#__END_EPIC_PIN_SERVICE__

#__BEGIN_EPIC_PIN_TIMER__
#[Unit]
#Description=Refresh Epic backend address pins
#
#[Timer]
## Epic's address sets rotate, and a pin that has gone stale is worse than none,
## so refresh often and start shortly after boot rather than waiting a full cycle.
#OnBootSec=2min
#OnUnitActiveSec=10min
#AccuracySec=30s
#
#[Install]
#WantedBy=timers.target
#__END_EPIC_PIN_TIMER__

#__BEGIN_FONT_SPACE__
#d09GMgABAAAAADN0ABMAAAAAgJAAADMGAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGoIjG9tKHIRuP0hWQVKCBgZgP1NUQVRYJx4AgWwvRBEICsscuxAwvhQB
#NgIkA4Q+C4IiAAQgBYQsByAbFnYlbKcYbgfsf9olgIhqVoxRVHJ2Uf7/awIVGepku+y0lMErFMclYuImuKClnXJxFNd9n5kSDaGeKD89s9CdYjQey7Zw3fxE
#XZQpQzFNxKEJ9nTul9IR+TN/4eqfCFbBdI+3oojEUJaMdWktz2gpUT5Pc7nbdsv+M291R/eKd3duUmgoNBQa7pbzTxe+bvobQUMJOkJjn+T6z9Oc/blvZpLJ
#e5mIQgjpJEwSJAZbKEuzbZYCNYtQMco6VJR1Qp1SWVVnd7+yojY8bfOfujl2u1sltX1tBoLHAcdx3hEHHJWCAYgiEzDqb/o3F9Euql39/xc/Krb9iDBxWUqy
#vW/PrHxfC8DpBcAvpQAW5KP3NOmABuIQFJ7/2O9f1zn3JSwMIDtywBqAXebGItfo6jjRqaur/htVuMGJG/AHAFhsO2mF/Y5Sg6koA/OcHMNafoxSHehLh2d2
#Dx2FQqFQKBQ6CoVKodAodBQejUr7aTQajUajUakUKpVKpVJo1CGdmgxYZCclzvcZpwHnDlMv6QOOtAFywEETyRAR+4SW5ZP0P7pVPyJKEpIQgkzAl2Fz5v76
#FeSsKa+/ovLuyhW323UG/tTZJ+lJBtnBZTzOB4DyyupmnMOuAqw+ICxi4jiOUZZQBvcAE0pQMl83JMjWtvq1f9/ekw6qZOupACui8sAyFRWhuPxmzsWaR7Rv
#w7wh2uUAsUzKIykCScZFJS6Knd7nQh8kkYz9qL/w6v+fqmU7n1reA3fvbFLrAnAkLwKOslw0sWjc2bWbZjQgQQyHpEDcygLADaDElcCNIHmBlC4waFfRQbsO
#F3PlGGYzeJF7OXROqcypc27duSzdlQke8aemJ4OhWxexzYybuuP/br5v6ZHzuHvPEnxuKlxjRBCuMK6YZl2vbuumIvUFEcRWtGpWH27f/B+d1ubBol+Jbo2F
#sKTMdf5ng0hcgF4AADCK0TAmROVA3HxIhQokQEciapCYeiQpgzRpQsZrRvqkZVuvU7Y99mA8VPMUadKiRY5TRBZVn7RWbdp16LQUkUl1sRTiwTiYUD+JMbGS
#ajsD9Rgi789oArhGWzwKmw5Yi4iP2OPMoYBGAAGBvQQniJKsakPY8PwgjOIkFZlUxIAyTb8I45+J9rEYFhmVAT2GLDCbIcs+zMzKY/id6KY1GE4GPkVbu12/
#YQ04UJWM1WX4dNpXr+50oAMinymkm/RM8Eu9HLwVfPgtNeZX/h1iNm6GJSxnc2ypXb+ps8UuRD+uaBdK/lwPQ0/bf4Ir6CEFkZZTpHVhUjTiTvRoSc0JvA5S
#Az8ovht9uCc2vLOmf1DlP/pnf5KRJ04IHVAwSFAoNQvN4XS5PV6fvyIQrA7p4RojWltX35BMpRubWrKTJue0OrmqxzBxcHLxCgiqFJPS8nGr8cF1m6lHnyE7
#7bbXPgfYsBgnYmzCkzcuwqmAv6JNjBtSk5OxGNpDoczNAPMwH3kuNXE3YJEmo/LdQOiME2BarN5XzCQBAAaBXVyf1690xa5dlq6sRAWktup83nZ1TJO9YaSl
#InQAbmq5pC9IO5QjxWnXwB96aS5ialE/HXXLWNBVzFMzeq+c1qlYUL5qh54zjGnRtS7OFaPutN/q0B7H0NySh/GlMrBGkTvuEy8l0VXyvxZpRxXjxyNMKkYj
#ko+KFoiPTUfx5x/My3okk9EbVI1jA6dh2gXf3lazlWkV1U1USCgZBIKqQP0XJdRH7EoW4RBeLJ3r9khlSKMVbWhHBzqN2ToBmqspPb9fqe7vibqMrMlNTaL8
#fW9gxidlqjsSqlFEmqKRHLtA88T7w5m5UL8Qodiz0ziAzuE6Io1Ghdbdqp4TwKkmTsP1ZBJMn0bAu5qg7ofxFW4hudSEDPShNZ4UPMQRWZ6UY7Kx09h1X+pr
#y/2A9diAjdiEzfcDSCPYsVgzESKNLDWOVM/zZ2cOBk4IPyq/G5dBR0QzaFmOAtcDEsZUQu51Yv1KQHKEMDkCv1KZUWTMTg6OXaB44szpzVe8zBeN6/XnN+5W
#kRIPCuQTjsaNycdE4lxi0I3h5HlWhKma1rw2gXNxrl4kEWqZKKHFxrC8qyk6j69wXxP3M6zHBmzEJmymuWxwgAkGnD5KcqkTAQDUkLe/LC9F7Q9xa7PNvbbk
#amhxYEryqVOnAqWcmLIjbbyrguFGR+KO32j/3KQnSadT5qniHpCsTCHZN3eHzlLemkfFV45ygEyDUAG1o2rJ1Xi2HD7Vx/m0qXjgrSI465W94lUdgLE/uhgq
#Afc8ApAB6CKRb1+Pkj5rLmKWSQ3CnYNIku3btBM0awMca8smsLYMoj0RLO0JPQR4Puz3ICKsZ9JBubRBQghkqlNaGjTDTTHd2uQMZT9I3uuYad8xyp5L0pmE
#POlk/SX8pa0SYa4xdcghbuz+saAwQM3HNNBwEjK0MliGq0Jz9ykuXF+uYBmG08hylw0Ya3//EgzJvVR3IxysQJeLbFqqvAvhUWSwgj7EdrUtLQQRLUbXoY7k
#QvmPe/BsA0EcyFPd+GSWBafyDVM3mnylk4bhvoCBIOMX40q+wz1Msox//I3xqRBZkuWGzGLWWq34237lovb8lO81+00o7OoOYb4fBnzuJoBG8iRmPVtKq35O
#/RazlLfQ4MVOOZX55sWaiazaSLvqv7EWWTQop9vx6H0/M5NB1jQfFUnxMJOAwFh9/4R1PXb+Rw1kK60Z/qz4FVGdvrsjbE98d/jGLfeAQ05gHPQzGM2H5NAr
#inFl2RgppEpYoBjhvnrvnhxil3pcXrROQIWYvd9T5ots286njHmlH2WQr8/xvQKCCeuq6OtjiDCrzkGqZVZG6WUEozAc5416s+1mciNvKIQLh3mXiOUFvo+N
#yc+gGCnZwO/Lvjz1l4uTC8mPMtn+yFrnyc8DefxiLKqi+qYHzOkYKPI6diyyPYUGE/FiU5uB0u+vtlKF2/VgXn1BS7QKD0e+4caFe3Ad9v73jdcrMNywnMzE
#A/ggS0oSErXlD1wuYa6Z5xqEC4mYEiTHycxeVZoCLoVGk2XtaM2x313QJrcs7tV6AUoI4iFtuU1SQAHI8yhJliUwEbsCCrK+A3mIZymZjB4hRLLbH/IMuxLQ
#bLmMnfby5WewLb4S4e3RcTr4uYmtCyiFWAMVd+wTHXbl0/ArDAkJnHrdRBj1Hb1ffNinHd677JocjpxLl9whM2Ut7rNmxdKMcTrv5mhprM8tw5HVdrMhOLLE
#ZttbICpMsN8z642hjA/LtpJp/9nXySAC/aupTZjmgIKW9zamxDbsuDf/0vzysqRoSUjIjf+pBWiIhEjOoIilAd2a3A63GSHG+O0KGtDcrcIg/EtOiqkyekXV
#Mlk67aBfbks0Wrx/97fqCZHrhcXXzw9BnuZyqclncuWXRG6WuOU8gnMF0+X9T4eOw0/eZEC4AXWGDdoCGPWYwyBcXIyrB3PQoIFSNpelZsMqLYhDPC5SAI1P
#0F/6DDIaR5SKBApfUfPsfDlDEJQEnG+viUg26pcGAwCW7k5wE3VD939tIuntmKtFCqUwlhCumNwg48SE/y+t0UCXlFan0SESmrVIa5Uj1U4LN52LWp6XXkAl
#g5Q0k2bNWK06WfTo4TTHHC6L7bLAKvstlIXZRxLiQWRpPiYmfgYbExOSQey4CkyjKk00XgoAsADiAJWZWYSFSgUAgJMQAFhVOwTgEgakJNWpldAgpl4UEM2C
#jjsEBaIFV4JrZDOhGId4yhISLMGJGhN0pctwmzTRxIxJmW0qeDLY7vqsXGR1vOrZ+SgsaNMgRyyEsAg1g+D+NZzEpkIDSaUQQ624CCAmKkyZoYOtSex/IxAt
#2A2uMcVpFggAuABX5RBRE4uCsBtUa9AJYCNWGTJIw4CMBsTggAYFFnDYEYETUQiYYYUb9QjAjyC88ECHCzVIIA4fqmBDHUIIowLjUCmqmQzccrHDf9CtjOa5
#Pwd26EBeR+js6Zk6UvBPmAggjLJfLi1N2gr5yKYr99b2o+B/Er4CRHduHrUK2J37q/tAFEbtvc39G2CS0WGWbMoqz6IAAZeWWQWk9JnlafvdKtq3lf3HPcKo
#JXWTkvzmDCYAwxkkxIPMK3WA5VnxhgotkIJa6y096vqgPmtx7cUz80D2KxsxbECXxXZYa85hBNvsEoHrO2DIPnsdr9sSO63Th1ENngxHQQQuBhtYkjbaUw+3
#Av/9cGt1edwcc+2wy7AR+1kkocOt++vzTptRebZjedmVGYZwNPdEVytlvDYb5AgzbCzXR21KxK2XTftizLA5FtXP4tOje2aQJo2k1NxnYCMgSycuNc/LLPw3
#hW3v/iPIykb4yWTuJrlSV1MOt8f3eY2OENKjiUxr9rDci+81wb6upTiw2VHh8/q45s2tDoftkcI3pa/Kbc3Nc9UGdJdPM2uSZvPF43VxzadpWtRh81czl99R
#1SD8IU+lBZVraxsaouNqjJpkJpnMZJLpZDp9+BYngPqNuRlKLGg1yTkYEg6Fcs1cYXlIVR2O3BrLwdj6URq1Xi9RbpridDLInaYEFGCvOghgZnlzOkdWjv42
#gyDdp64jAHiUvjQm/Wvq/UF+UcYoDwX6twcAOiljavW+e8iAIPb8+tGbCABUHoaMtFyUQK96VowOglJSsGWgH7kFk/owEOWPR81ycL1firpfj20TwBS3eEg6
#2L/ImE7zXKcdKickYpbZdrvH20s9ekCv1iN67J8wAl1Gm8OFRfU0nuHWK/RgxQT//O/w520P7r67/zWAd7e9u+/dzaCrBrLQ9Y458HmzfKeQAlZEVJ0aZnoG
#teJcApwYbh4JDRr5VaOY0JKqNNEy0pnBwsphXUaDMnXMKEF2ZGRkPUkF1GgH+AAD/D86GbeSEmYAAwfJMdANgjitsN0GaObo/zaMjffSGLpjrGlZVm8tChRr
#E3Rtq9U0aXf11RRsqWjKhO+sJafkaaVUDybJqfwPSSQ6FGJposUwaqNUWRrsZ4fyNsC5buNWXmuVfZrJYbWZzpsG4efNqkd1JII1bthq4AXM7pDNr8kxn2sY
#eS7ZG9y+HA19ylHrY0KpizgcsQT3rstlGFGXTW51y9aoVT6AQ+6qNZZMUG6eUhvUutVVzgy5sUbQ2o8olaEiUhkrLJRLXZzoalOwBduvTKjaZoui8IjLUOzz
#W9piCGWC+v33TWjFiwauuj4G7TPKi9z7Jxr+OFeDfTL6Vfo/nfgCCnXDH2hfHOVjjZRk24jwtuxiZfWWjks4Gf38tueOE+oGxc9kVCg0D4wIvSmLi8kRD9Kk
#cNbys3jF3gt+JHIFl94+4IpvVCfsYznkNHZDRb9N0opUzqyYT/NgSmDUaGzhFgpzdi0WhrP5XYQW4mdyPO5KFV5Cxq10LVLwJlG91dJ11yz/p2iLiW8s32zu
#vLMjC5qlKdCBcNnLeommIjhzplguOLe0TepEOE7dJbtiUXd+du/wxeh2yXhrJvROrepyNByF4SWgOitEFfUZu/gwlCn/f2oyWPvaEG7Gd9XDiRQHj7v5J3dQ
#NXeKi5ZkFVes7tgJ1BzJWTWd/dO2sc5DlSLVl1nxl64IvZ/69PT+x+hijXqWkKDUYT7vAoB+jG25WUlB4awt4Vb1ezlYcXGJwpq3qdnUPAxR87VbXHnCe4B6
#kYGSJ9mLVItb7ODViqijl7zFa5uWrjEbLyj2ZBRZ7C08HOBsKyB5ScgiUtmBUOWx7ZKzEALJUSsXp1723G1n+XW1XHzz8X28sdBx+Uazrp3NFTxGNVVDyhhJ
#sgc6bDlE6irlxGZKtdUOss08ljZFoZMxv8GLaIt8OxlJTFHo1T6E3jkfrpmagm0soUzpVylNfeY/bDHi+unkO579PAqOE+bQ8HWPsTPW8ZVwotrqe74io3D0
#aBLO7TUen8bwYAWXXKx7vUNK87M3zdK3pDi97XcIGp4aZF/06HP3e2J3nK6+PU6pXcPd98kyS45GViyZJGZpvs3Q4racekflzUclY1pho0DvIzv1jqcpZsKx
#WamKR82FshOTy1jG7NPDkKadVJAGyc1DFmVjtN+UvoUCgSSzSDyh+yicKAY2LCKffBHHbwxLVJaZFDEozFJLGEVUjuk/KRpVSiKuj60vZZX1ifHnrs9kpPOo
#kRB8GK3G/sOA5QZN6shuDU+3vwv2C8J4m208WziO9odRy+X53bfw2RB740OVgt6n2kKIRLfca/sSsnuJO67Kr8Tp7ut9TMi1nhfnzN6ktCNr/MUgsTFndze4
#aL8/S0jeq/PUOa3ewDDw4rTNVevWenwAtDVLOes9Dp93GEHr6yjrwAVOV4Ik9I35weXNott42a3ykd2aqnMJb/SCx3v7PBIzvpqukacIpUkB/2Rf4DCvL+sP
#kyYrSZO1PbRajnFSotXao6tkL5IrQ98rNByKxV6x8qytfWHl/7xhQ8CHpcDZ29jX3HPNqz+IqwbaYao7jY0S/K0T45Fe+MDxbPoDfro6U1E/JgbOCm+So59V
#n55vOmAcSx1d/e9ZH+G5TD96qcHS94J95uRUMOXifGdO1D2HSHQL4vIb1CRQbmTq1ut01p3KNz4ceL5XLsQ58S4zvhJk52W3kkyLibl+dOlPSbR1WnKV1PxC
#U7emYnuY+HqI2nZMkuF7v2C8CgnrKJFt8Vi0ROe28qmhlFXZnT93jcLOm6zu2HbbczbPOS87kXd7x5YRfareE3aMcZ0tg9NgF6PiZaz0DHU52PXWv1rqePJS
#8Yu5ngE3+OGfG27iFPUV8km2/Rxo9liRwbipty1MVJeidpTTeOQ5hzlr5miEDn3qqqknzqlutlg7J3ImNpyZN/O3G+wdrVCr8Dpvf98A2JCedWtW7FwhffTM
#6lvSNZga4g+lItFUZ9PeJjGikannH0EhXXdSEz0l0NIty9bPXb9l6dJ6VUOmPdm1uLu9MdMA/AOH8ESuBbdwmnC9/d14JFeH67TAjDi7KXp2NYj1Lm49lyLf
#6yyjCj1rK9PVYx8p83W4A750lZn0G4ui4jfcO9q4Fn14A2DQtnhHW1pKSc2WKrtTU2U+3Yvn4uzpdEPb0EMTsE4dSlZ2RsN2GnY057Usxn3itY3wrfTEALlp
#oG1TumldmMMbKRWw1mwGVqRnbRTQWg2ZmKWKzSjjzolFmyBm5PHfFDlkTKwKVMAVeDA2XfNUXs2AxW/WQXqvyTZA9t206I7QN81dYeBzDQrgHxhNx0qVbjVk
#1Dnfh4V/ir+jHgmnPgYV1z1v95r0g/Vuk/N5gCOWTlSX8o6hxkQzVf5AtbOiZJ6J//f/+ytF5SaVCvckRAZDRkJVMRJKopDoXIJyc432PBpleE9ZX7hEwWo0
#RGW6DOTOfoWPxb+aByyIpQWtaHK/Rb1VEwtVVsZCNQu+m2xqRcG/H1/TvbwJvum6Vx7YN+sa3bwRXrOxCx1Gp5dru9fwQd6XkQch220x/KTYBn4Nst1F4Tso
#GL7v34PW56rhm27Vg4wDaHCzAFqB389/9+zFwTfK3dMkujLp//MFsrOFah1NUyz59Jqr5XpfEVEVr/V/w+dKUEqACodAd5bSk96w1VT54DOoXiSRMDIQRpxB
#0ghX4gNEKXz/G5Yr1yYJTYsNtpEtScIu9zQkqznV0fG4ExDDB3LEmCEqWm2QvaKFPo1MBMW8mWNMIWUskMs9ZWVBDUcDxpA7i972Y6uU3tNaUIzQSYIk/+PS
#tMwgaMzM/eY+XEoM4JWwMUjSk3EUiCVDalpZ2PLwmyBFMvpGpXoGK9yZHWqMOfWshgh8bPcU/V0YybFXe1lzrRfcOL0b270sL1H4OJbi8+ftx/afBhU/wDYy
#nVTTWvtWxvIChVaMEvBfge99a+Zi9Ay1JvN7hygSYU5VQ8OMhipOOJEAwbDc3UtH9ZNReaAUDeiKiDynQ6+z1EXjPw+7lYPwH68EBd8U/hHIehd+r+cfYwAE
#H+IU/BUt1qhN8l/hwUY5LTMXFZukNsKIfqfCbayp0EDsakLweBdhZ1oTBAPEOHKEzZBEiwW2dHiyiEUbzHJ/XSrECanj98UhpgwC907GM+MM9tpmOw4/BK2c
#5X57D+Zd+T7Im3+8xwuEuuZRO9mcCtal4Cd/tSXL/pbXwC+npSolpaA12jIwEQn2epDI0Q6YmVREmMpKRfqpS996yyw8VFIRM7o9cRZmerayEqWCLi4uOq98
#a4KD/0hsSLCAczaRF+/H+i8SF49iR6v4/DYMjB6KBqPxAoeDyRGhagDv/wG16xJ806kJDxxOPyBrr8O91xvQYXRyuTbZywGyZ3976jvLzruw6hbFU9e6/0VY
#zwM23MO4fP79pBK2eEBXTOQzAwj+hYjlJQoB5WY8kAab5TYOPCcGSKRryaqVu1fGfFetoVMRiXQlDyfJR8B/fABsQrbkMKeLZw4A3GCR+yPl9BjBcLakWIcO
#Msc9dk8yGEYIxFrR2IKZTClUXVMxVI/6azFqLN/J5vViE44pgRgxtymoGdYx5FhfMuLz14aZXHSEmy9LeKfcgvYqPw5NvAEp6HqR2k9DtDqSloMta7pY9SeP
#/zJLOWtN2z35y3DRHSBC2DRONBoQEgrVVzr9kWiA46mKWkX9nHVVnU8rF42AD25neHJNVKlqNEEM3pTSABQxZBRUkv3diqfSarstqZBXq0lD0OMPRiK+Jnhq
#UGmnE0qiwQgbqURGoVe46qvdHIXY4RJhmOPRUnDcmycd7J44bWDE+J+HnlH+bH5s2L6+yROBGnF3lJFBNYSJDbq8p+C7T88WQzjlaC4xGhUrB4fEs8+/Cb+m
#zctZGKR+gB9xXYpwyshwjCkmHHbLyGHmDaGwv05HcsiXvB9xQAnCV6jBT6/0+CprBapRlmBgE9XgGpi0Ip1p+d2iSmfUlvLaWifGXDqimNj5QMH2B/wAj+IF
#+JvQhVP4BfwpC1Ew5kFHbtOoXuD3B7wEz6SmLbiFVptQ3Y6kyWfzcuCcPDZfQ9Ctd6lNgA8aH4QXkKZlLf5W09IJL4z2ZLXNW2Rd2DZf+CAW7c1qnb/Quqh1
#nmRQC9nSVn+LaVk1GLw8um6Bxi8EfL9yCS4o7NzVgUz6v7Lsg7m9ZKLQJpCJwyeC7w9M9FgtwHdkNDmafwn/JP5xxCL6aM+/BZLWiP9zCKVS79RyvbyYLNFX
#VDVLTMYmmTqgUhSzeml7DfGhk60k2zwPlEXK5sAt9MMRjm0UTLklENyaIih81wBXUnlfCcbfm/d8fedTq8auSj/1VP2csb3XYskr88csqenzTSioEyDwAvxb
#GV5DYhlmtBFLV5O49D3letiCr0eOwCP0qrruYZ3BPbu86dEth/3Vx/tG9sWPn/W338Le+sEQrA9D4VZuMAQTQTj41QOAsrpE4VKLHqOb3oWu61kdoXCHi7GF
#WB/hpQzimfSUwu3tRHscizPvyneN3EX6aYYJ0EDyujioyzWHPvi/f2BDri44xxQ2HEAMmXW5c8RUg72+CF103KXXla/3S4vRxcdV+G/C6T/e/9t4sA31+4n9
#gB6WkZ3PgD7kbPn5s5nzRr/fnMv6fUajWmyuWX+9GElZrxSS9ZSV9cggaa8rOnI2mLj84gXlhYt4swJ29HdvMat785Y6ZWjeCuoWK/cr9y3/8IEhYN85ZxSZ
#ujWQHNTNZeJrIMqsfYA9dGVMjIdg3foI2vIILJlkdmmRcRN43/+561MEeqvBpV+t+6fgFl8dDt3rerWDBmGDTg96SDzkqcZ/MH7C+3qtz08Y/8Lbnhn04i5u
#Ht3PHRa3SsyNjP4U1t/JF3tQvd454vw7evgnFuGKM3+CbKlsl0C4UybbKRTskh6RNHN5GYkkw+M2TxRdgC24htN9WB/7avDfgLroZXoJltQL2RtV96N7GLNg
#oTfp4jk52aHYc54kOF1Du8JdDP8qb2OcdCTf0Ssuq80vCBYX7thG3Zkm+mEGfORrceHz4wpxhxH8HPwAu/KS712PyBN8ef6uU/C6/WCzIjzfZp0Pgg+Jh2Ao
#0z8ZuE1nV1kGmX6VytoLBHAXgqo9FWp1QGcwBLTqLnWA1R+TLc8vWCaTbivI3w7WCGFltSKy3VYDPF9zXFU+3XhPo8Jrkxbehn5NlBLr3zzzxBTwLENAh9Oq
#zAnlYKl0/vO64VX60tlaPx7rl2JLM0/2XawH6/mLfA1eR6gwpRlT8rVIvGVaQaRcLVtsgD4TSVVLDBAFTDJlXoeBB7iTUIOOGXFi4TShSSTeRowaTPsqtFon
#iSn08g+ur3X8IwLPZPZ6zXK2k7EeLys3N5tLZf1SUrZdFm+NlPYLiK3GSQBM1kw3lFtzMpp5/hmYD7BrCksYAttgxFW+av+fRiQxa3ulRdDxcKRNpA/My5iL
#Mn3owi0jWAOIZ+8KN9QIK4XKT5gn6IzWFuichrcMDLQNsmkGTs3D5dwOFt4VHg6PhPZTFrHq/9S9OhwvT16+ALQDuL735uerxI0Mk63v3dzPCjVN47vUNabI
#67lZLzLM+oWlwDZWW5DzfeJgVR6wW/FWD6itedVbpobSxannq+U1gEaj1unynO4h4knqACbSFHA0DUG7gSCdm9qJylP7NAJQMUa7l7Ow9/9twKzSHO3Wudxt
#xnzl53JRlBqpq0o1UGfXk/Vl57EMm9nd3d+n9sHe1+/nomAOD8LSsB2+GH4tfB1+hv9GnDEQp8beuBe5B/kg/obWpylpVVqXdqEXoo+l0fQLpnRPu55ua3cN
#9m73C54bO37sDPwm/N9ZyWv50NyeZ+Z8XpqPzGvz1lwm9hKnE5cTDxFP51fyv/OXxSjp0lY6y5xyRFlTnit/UuORx2nURdR7+JZmrFxkjE0scTl301fS99Df
#8Gcm0i/vL2NecWhxT/kUn+EFX+ZH+YCf6rewd7NP+PM+5t9xpur1Te2o/fUM7nzuYe6p+kn9+j0aCBUKIA34E8ztQ+BR4OdR43iOjE6Uvd4ebtJB0tmuLRCY
#Pr21NncQPvBaQRAE7lhSEV9OtQoFS1cahprTG2WlmD6ao2sbDXz0KFBnENJ+/8vP2jGWKEMSlQHBAQh23A8Qj8XijEC5OObCufmkLnigFAUjDzGUTEEbJTbo
#GdjOnJ2O7IIJhDlDOE1MvGgUBPHiosaZRHrs7vqQ4tykP7WEVVmH3G63VVXYem7eLL6n26mzQRLRRaJsOUm8Oo/tXkjSIGmS0jABV9tJVerZTPOGdOv40QdG
#IiScSDKL7cTb2ZWbN9itqcMAa/T8TqhJRut+dMPQ1jFcfW3BZgVjt7qu2d4o1UnpWAUi6/P5wgkS2XZ1red2WPuaLJ8sjZhvpT93WCT2P9zMpr2bZtZjCtBi
#Bgze43p7G/rBrgo0XSspLUOHxRCZLcfr9cOuzieQCco2IGUX9D4ivkrcmgfk2Rdbgh8S7/dg+6kvI6/c0W5DJxjCk+kIEYc+4Td1mYA122NMrjaevHfaBiKk
#9HzaYv83cemMxDz0L7TZhO6n6v39Cd1dAp58DQ4Sap9/873uMf+35rC54fF6I6x2/IR4oCXBxG6TRLZbl9TEwKDoAz8VB50SS4F2/G7vVurYKMup+OjdE0W9
#GeAoSiZXyGPUNisxbH0tiI1VgDrb2jyjrsp0TwQsMI3XtJYt4bkVV3VYgmAVzqzyvG/ojTirT3B+fiR3kD2hDo9Ux4qStbhOvFBSTBVtiLYHMzF0eaFvKloB
#7Gzj0ld/JWjIUDN07Nv0pghY9TS1a3zQC994A8+qKaAropDwG/L6gMymmixTrQSZDHQv3hp6ekMeyeyibYhBHKProNyZoCJBiNzd0nfEKyhw3R7Ba7aossyu
#A9eQKCzK4XGDyKaTRK4mC9ojQqyJgyUPAXOIxtgt7HGsjjIfGPF4qBm6Jtq420SHg2wJ0U6Z8DZlZMp9dbecfUlwWEljrQPKz8bcd47NsSfSh0CCIVxp/3Sq
#jqPlHObLu5+0eU5deOJ/Y4Tz0MU+OBh5eUIf2gCFXpLXgEdQ48WhvrUhTY41+PWD7O1O6Vnx5B0HtyG4p6jc26NZBu1gEPXA3Y0j9AD8RyUk3pUHI5ezl6cx
#huZgEL5/+MlFIP3ZTmTfw+dez9Tduomwlb48qOhZ1eZVqxUJImVxw/A1qqpDDW12PmfF2jtwdaBOuTfKDF4oS5Sq4zIt0qXyPGbg/QFjZ+iPQoyj9oy4JcjW
#kVVsX8bwjJfujbqDO8YFzWsH/bqnixwTVkHQaxKD2pu9dIhAmdRpeq7qTFpUTwNsSwcVYK13ObjWqLJD1/CeoYXgyUoydr0avYwoTpSZP95oq8iK29JnzAl2
#Yy3DlId9A8pDYRgzc4uLPGdBS+mW5YSr4eV6/kFjk1D+Tc0TjKRq0CAy3eLS/MoK2C9lPt+GGluGktl6EJ95uZimEydNDwEenYyhXm9f0ltJZg9pb0e+ym4s
#OWHY3PvH/Z8t3oRtMDQQYczgIieJu6vuGzZXrVsYQ9aB/99zpqlQ9+k4jsQnlcGE4r2ecdvzHhCBQfahneUz8qz5GUaWz1NHhHdoo62oEocvR32rCYEsrK/4
#5pfKA0660+lb3Z4AjZnGWT2Vyltl3BgH7rL4KQFmdCjA8bsD0nCrW6FBDl5c0Gb2pP3dmm+4jq5oiyhP7DYHqDNkjMauZIoc3Zk1JVRjTMpQAvWRr2caCsAO
#XnV3tcO2w5c/T74PaEJGx0os14UtKe0npHkMBgFeyFZO3+GasafprivTlF0ublfz+w3tEYfRUps8RL0U7XZdvad3fEL1toHTGJgCuWHjYvCF0Z8GHrD20w5X
#DYMm52MlkzammF4nDfBIJUKoVUOwRQTYBAi0sCKRqKudsX7QogN+ELFznJytg/RR2z12a3hl1Q1O7M7huWxq/LZIlyzOfPl2r94fYM+YNRbQ1q0dzHE+VfHO
#WIh/xLMuV2aYt6o6OSViscuIqoViTDu/nyxntbDCyG41eDZCPNNvne4MSkymru21wlKpnH3nUB+yzULha4x8letPFd7gZhOj6X+TeWQqb5hMdAw0UHmOEIx5
#UhRQYUlkFtEcU/YAGM3A0KSKuc4+HyRgW4rEi7IemexZnXMJ18PJQd4rxmHgaGwn5LqCjRBChBR31xbGTA/N5Ga5wGMToHYku7K17Ae3VTfQ9SwoKbqhfaLL
#xg3jgOXcUoPFFMdOiFVkiRYrgyOECOeOtM7b5AyDcV+YV9IMZs6cyMF2Bhnn3zZZIlS+R6Dktcu3wsdjp4d//n7ij1/0b2HDUhu+aezKDs32D0EULG1U6Auz
#6LYjDXNDVMyAjMfQgfOvM5aDc83A/V6R5zstu+ZKYyAOYFtoGNngT7l3XrUyYkOsEsd5qTowI9QB3uNHXDUy37r6kG/JzrZzjmaOef71T5/yvbu6XWB3PwGF
#1KBSrCWeuU2ThMRwn3r0VYbENdCqK2pEHmq7x7iZvZBnp5yNdueGhTQOIdldN5uPdSAjO+DBiqZdsfC6sQRVucUw9mb5f5Gy8x10XtBbEQFyDEaSCFe5GKCr
#Pwno2JHriuNK4rGBM5/nCRDYHxMp1ZBNekErcHc0UTWtSp5PcQ68SiS1XNBeyUR2ar2ZSOmc8sPtnkHQy9NaDMuQAElDhDPUHnhxrIL3iMwjzFa/MjRzI58H
#/M9/xvVI5QbDPwEyp1gTkx+7e2h+cn8P7vf21G+RGflUa4C1Vh+AN/BquR5N9KcSR8K7Wu6OiNnHsubFYcbc01keNH0hX37ZQ6ER6pTbQwyUgYrXXhGBjRXj
#NzhVBbY7i+eqAStkOyYAZ56nhYFiLNJ/VuTqlFFy3R1NW/f6psyHZdc07IQlsmZTwYyZmvYtCwwNYpSqESZXY3F0YzSTR0a6fQUhCsowSiig/J4Ag0ZrRWpa
#OmCDOWg2p7Ra3B/3lz0hptMyBniBrxG9pP/7dB7IfzF1TAL8WrkPGjucvXxnZX5+pUW9UICRVJp2ENhUkvBr8NNv0gxkVYl08b/ED9BIHgI2TqJDoFxQEVlD
#t9wUo1h6IhbVRFdI5DIwdWNkolhh/D0VIecRqhtD7VTuurgL71HvcRHqTkbnRNCNj8bVkJ26KYtlRjOarqKRMKnLVHAYQqou6WB0zURm/g4UWizjObKQXmVN
#QwDZj8iqPjTBjEJY6101MfOX86LTw0XzteGVX9J2IjU9JVJMkiYeeTAMnBBi5WK4E9gF5xZdkhYR8gAHs1jUg4okJ2IiG/l612LoRNwcnnXK07K5+vhzZrzc
#Vgz7/Xuxbrg6y1YP3+PNBFRAjQZjQRqaGkW0WDENQFksyabb1VNE54hCioeuvlA4we/v86UZyrmqM7PylKSDjWtAa9AQ6HA+pNYGHTzGBCcHpu9nE5kPfeZU
#Kc/0ITlSWzhB/mBVWmUlx1knTcE7geVHEz6HNFCkxeJhApch28S0vmiNp4ot6eIS9KQr5JeWVdAL0zXtaksIVP0I9wH8sm0D7PnXs7M4pUz/390BaBM9/j5H
#VroeHsR+yOYWhd1b5gj5wu0pQBwwASwv3d7VfjSTe/Ghp2d5UeYDPcHaY4sGYiLlg9aD8mocBy5yAqbYW1l+cktrlOgP9Acf46HyIPpnRPZ6Rg64Wrid0Nj/
#OdO4tvyLk1uMgesk1WZDPby9iHIctvCp0W1bnOZaxX9lrzRklofoqhAJphzdtXoLAdEF7IhQ2aPBEloB3vuYYpyGRSHiK3l5UGXWMZmmlVaFmrjNht9KU0nu
#Hqkd6fLTMj0hZkyP9ZMfIwgF4sKF6MJhqJ4P0ABLALRNQfbZOI4xJg5/r3kbnnjEq9x7bzJkP9KWbkUR7XWwDJEZVGLUd9XsQQX9XgX32YIATVkzMkWknLR5
#JbI0ra2XNxVe1uFsUnRrdWFhdTUjCbtEzv8rf2+miofbBzDaHppu4YSwKpKAip2MHIOa8rqlcWbk4Ria/db6cVIUIhGUKrdzNjet/Gt3l8pl03xsSlYhPd8a
#9Kvyvm3Qfd27h8CJ+0us3ezstC1u5J7jo7d90JBZTkLGMjxPckMYVq7VfDttLtDZwkKCZb7jieUX6upXYBeUbbLiU4IWgwxZoIYqi8Q3baK6BoLdd0rAmq6d
#Yqubi7rd4NM+WYG8IHBDiwDN8R/1TMdSypm49TCs976srFiOuX2QI64Bs0IYBB4KArGARBCHDcZrGnfCWXw2a4zigIAFgqNZuVVuNqu9XpWzl1syS3NEX5Rc
#k7ITIWgXj6BaOnrpgiRcOqrkiidyRw6DSOVOYHiaxVTQD/uC/HbD3yDorRncNdnQEYTm6EG8owuzVVdS+eWRCTfCJ3y/ecMx8BsS7wCI0rX+GH0NJNI7546G
#1jbDPXv+74z9OjSpboWRFPuLaxJp6YFERaYvNaNUSFm0WpRY14q5HDoHJkb6FqxM5T1cxsqNRSppmgpx+PnrciApHG9LeVsDiv/AxTho9rdNA9E9nI/A0JGO
#5uQ28NhLkaXcIpdYPrY4RkduQwLYtjMNaQ/s7l8yz98Ugw5TsaadwfbVnEtwXheryD+x1NWtW0C6qykdzaeD2qcz8Cwurk3q5PZOf4nX3DuLb8Bi+O0BldYu
#E3fj4p7JdjzTg9D9T46wrMIUI6bGLSvX7lpDVaQyCOKW73tb7Fx1LTlQDEystLJWTX+5cZsmfnNSqDTa1Rur7hzej54ahyS6YyNgHiJ23okYaTEq2lgYvDQB
#yVGeB2yco3OKZxgJZYNOlEGguZydBhDl7mrZlzWC53Jmppjom0Y61JgIF0rbqW52eOmB6OG6aBohBF9YqQ8UIkGtxoXh/63GNq9Zvhe4l+DZyB/9j9asweAq
#VRlUioBT0ygAoRStBDJDQvZ/nlFrZoguVSW3BwM5iUwLC6jvOAehn7pVMc1tgu49g+PKmR09lMpzHMSHYxgNbkiKNQIsODKMG1BS3eA7g1r4Ul0L1QQ24wTn
#ncYpzBDee+eqVCqZONG15FI16HxEe2Vii9f0f3MPwX8wBY7gCq9q9MuC+aCRX932MxJ60OC9Kxwe72UipHd7adw5czsgr5mFN5ZbOunWCY56GqkvJRbIy713
#DNTcaO6D1YsAA2YAx9Nx1fSHAnp+jTzkX3WG42juWNTtQH8PUIzjKyT00btJjSU+kojtAHaNZ7+XTXR/33zfaf7ELHNxFxTqmH17lzyMEP+jB1iiXK5PAAHg
#3K0Ww3rU1WYC4E4NyWVax3Bfhu5fYKspyAF+cPDMrdvSC17l1Uwn8EdDujlY0dfIL9eEoWU2/RTJJSw9hEuhUyAeJYxq5ViiEsmQKWLlB16aUEDvupLSxrhl
#LdyhT+ZQu92e4Rlu7+z/o97Eropd+Js4vBMCV8hh10Qs9NR5DvQCsURBabmylZNwqQv4jciAMlZLfi2HV4NhIGoa4lYqN7FYoc0lG9wdRdVnekjoVJeJAQCf
#YarPEASQXo2CVFr0QCxtEDOQ5zcbrndnaWAagWwPQ23uftWYyyMODBY4BDqW48oU2FhMkZhhGRIMhRxFEhmNFcQl5OoQK7FBYQa1V9kHkqOFmMt1PUcKLb5n
#ElFUSBnoeBLLN0rjY8uXkn3gQV5xZIfBSMSEXMEC6JHrXn2oZUdRl8XEUhWF6CvgenGzmBEjWmwCDTT2/v0CdTuceFIjKSEOq+g+C4JAnchffe764IP2egYq
#gY8RnI5z1QaC0QoY7N1TKLgmm+lzSFDCPCpEdjVQwtD0sI/SKW03YI/Ik12pfFX3KyHw/wSXVlao1HBIbQCKU2Ohx5g+yhwiMqHvW+r6yL0HGIwcqTv5vD37
#00xJ+hSA//4lzyvv8+nyP6X/uzs3UQEwYQCA4L/V9f+uhK+WvG3H4z0wuISLAewJbp8p02W5PnusTECxQx/0jDRxUNE3lVlEvVT1GiLDYnpWoOfnct05bLWP
#huV7c/tc87oPd+hR1CfKK/ce2e3QnoQJvVN3L0EpdlSsqgeFenty8F5B32j3XX5b9gwjDMsj3cv6ZLQbDF0/VhxoqZfLt7WaqysQG2rR1gvIeMoL9JR85Uye
#Xn6EJUP7TOsiZfc0dStqegCWVJTVJeiJsXW52oSnNqKaoTpOrk8Vx+HZPpet7bIaa+Pb2Em9pbGTuF6V76NdGM59RE4KVTey+7gnZizoHrIGMr2eyDjlQVUD
#R4zGyXXlGoBleLxcyPbpQsMA2RpR+xr9p9DwuiqarAF5MDjMR2TEYGIsMbn0MOCYMXYv8jNP5Vq6hykeMxIG90u9ymBDqE5ZvxbXPlMi/uAIcNBSHL0GnzIq
#cceA1dkkNLEAeBK400jMk6cxNp+fJmnx60JZeJoiUKlTTYyadjYCrNUHpxF4DbQqI8IaHnpkMtTab1bqmltmtiUTjR1CWdnOFno3UE89WozWcUpjW3OH3d4E
#c/Iwg9W1senOkTYG2haLwqL2uKEt89m4RJJI5pXOmDg0N6clDalAaOxo5o1FVUg/mrkabdfyltMTKy/WOWodjroP2xOdqQ7bZeKyu4qasfTpdp02rz8d/ERf
#LNm8QMj2vA0ENK6lCjYab26jM61tTsVz4NvLXgYAAAA=
#__END_FONT_SPACE__

#__BEGIN_FONT_MONO__
#d09GMgABAAAAAF58ABIAAAAA6jQAAF4VAAI2BAAAAAAAAAAAAAAAAAAAAAAAAAAAGlIbIByBmQ4GYD9TVEFUgSAnHgCBfC9MEQgKgaYggYBzMPhAATYCJAOI
#CguECAAEIAWHBAcgG0jUJWxbisxuBxCeUr2WkQhbNWeJRkVJWR2X7P/POE7GEFbgnGr1OktuMDWl0FVjzrnGmBJ2Zu/zcnb1UfcaWGXc8jLuhS3lDVOh1TOp
#U8X9NB3fxVv47XAo+MFvRrajaYfS0YoviTbVDKVGFzU4mtBZ+5syW7BC2ySW6OW/orXqFIVDpzcdeBQlDZja9/prCnY2pE0p7hIWroorLpFIgjpMZ2DbyJ+c
#l9SIdKaZPZ9NacbphDiNlEbyjlOaAZdQQ/IETA8plZDWGv8hxYb0Wt2GSLf+BwUhIJwipQsJCSVAIKSV3U2yaUAmS0LCQtIFEgiEJtLuxFb+WQuIDe1PLNiu
#K3fd+4rtFSz1asehpvtv0I0llvi+seDXvKf5va/bynGP7bqnw2J2++HS7qVUW6wxFTUVEhjCUAYS2kAghv/VVfW/wCB3WQVu4AWGcDfet+FREN7LW3b1EQch
#BgkQ9+5xU83N1ECRC0yypRn8z/T11UrOvHie986zNrWpcZ71PCvOE+fEihNxIlYycSLiJPfqJDgnVsT7iQvykEOchCDez4kEJyIhZJJJcE5c5oKk4sR8cC5k
#YoMLwXqSOfEkPDzdtz93Igm8gAq0gAIKMEsgDP+2c/y3TXTZpnl36Lf1/+iKIiiDMAiDMCAgslZt3ezizKmve9/r78r/6DyRbpRbBejY1rKWAqDCKTEaAaiy
#NUNJjf7/6dR/0ok+XYhh7ShIrTJPfZ6sNV4T3juuPXSrZogoAXb99MWcuk2AvXsXa7+yovrW/35u1ymVmqh5iM/MwN/fsZ++1+7PN7sxMo4hUwUnatJlOCth
#AnWiSHvdiyiozDEfSNsxr8PPe3WvdwnrpI/lt/OGc4cxIOkMAdthcuTS7KwAtLa80tuT9nBtN8QG7d1bR5NFQiFkQnar7zT8/zfVz/ZdAOQfkhswktYGHcH9
#SxtyhL1FE1KoHGLr6k7Cm3kDgINAakCQEkBRJgDp+wygBCjYxGDABRh2IW7+KXJDpFMYAPx/qS/5HPxMhxBkF03OfSw6F5U714W7deWiLO3/p2pvO4OZWV4s
#ND8lyVrHzrmoKOiHVemz5a983DQPwgBDEoT0xBlC3HS+HOScKon8QUvKKdIpbCjdlIaSlrMZak4icR4rvgI5WOjO847Seb6ZpH0j+LqMoUKYEBajLmHJufD/
#kxUv5wacbna7lL81hEFkkEcQEZFgw2CXzXp/72tm9TK+djKX5SEbySCQIGn719OvDmM/+6GZ7d+u9erOXJkiEhIgIiKSss/7nQoC4Isfyxk+IJShlQ1PKMcT
#yvOEinjxlYXx1VTja6jJ11GP19Hxeg1+HATAGyFCkdEcl4QISADg8Ujy1PVJcRD4xxKTm9M/D7E0gEAcFZGkJWSyFKul+gs6HXT+MsTaxePHIkHRISe3PzJn
#j3r2JkFnV04HQnJ7dcgl/JfjZQCYurZP/RXwgj+CBCumhFLKCFVBJVVUV1Nt9dTXSBPNRVLR0CsHVTKzINk5udXxaRQQ1K7TAn1et9BY400y1XSzzDHfIkvl
#W24VuyJrrbfJVjvtttcBR+Sdu3KjpIJ1r4XTJYBkCsxkwRJyqIA5jUcyeZEv+VPQ649ff0jLhNTWpyFPy1bPO4wSTkOnTAWIYFLFilTLzsmdpqP6RF6iR6K7
#lg0wSXkiTuxhZ2mWhUhnWZWxpP0jzp+OE75SY9GT+WM+ceLkOiVQllbmKpe5t92h12o9/YOc5hCqvIMCA+3XQ5nK/vNxPmNnybMJ74YFCVe1IrGmQ6kmDYE7
#by7Q0Z4MAT+D9xImj97RINSbW590q72Sn0SzNg+J3nI/c4QyuVxZQAxykq+E3w7/kJM3CsG5i1LgFxo3/B32neJH1srdqbvMnkg63/VmEd5Vld0/SDmoEra0
#autFnbadz1zb6HBj/cp1GiXWM326u0/Se/kQzquO/P/oUYUw0Yz8Ty2kTvqNOekab9Nu+jfpTXMz3Q5G/men7U9VCzYKUvhz7wh8jjIqVp7Gpr3JXjY5cZG+
#6OER3uFTYZF94RAlURMdXHrh7IoW3MMjqZCIbM7ZqQpXHLiX0PQqpoAZ1EkDy3/B+CJ2m5kO/48yVqhL2fkPqoX3405qs45XwtqrxiXcpiv4hQeiByGf8uNA
#5CDREVzhKAyi5Vvw0FdjK14lRdKl5dQY+dzL3rRGe0d/OszB4D9yvPhI4/Jj2bg9IeNe5v8Zz4q8468XaVVZKvulNan6RzS5pqOpN5sP72yf2/NkcS6ry3CN
#rtD6zCAbGyziiZJbaef+VLPv7Z1q/ai8+mu3jo7vX94DPU6O4ak6kbN8ti/+V5qreLWVIOWY0lBgu85yZcRSzwWEhUU0colVaNMbNfeASu3xGvPTOzChqr1p
#uOn67T+pOc289R0Ut1SWlVVouDmNdkLzEimu/NCXocEU/PiEo46ZOrHJIgOQ4I9QtRlMBzW5SN5cATw1pHAQbFYPSRky5+7Ib5JiNKnmS5s+F8pYVIHhXdzG
#4Ag3kelozIy5ORE4c22EUQQYCvWJtNlXguuk42T6ijeW7qVAoAp0Wqp9pEz3E5nCRJbPmc4yXaKkwmTTUsKb2O4IXX4FJkZXWxBTPszZcGGkslUVvL8/FP1l
#qIVpLFGdvoeeYTJdHGi42RKhJUteVdJUHOFtXHcpSFXxUImGegGAzzhifGuqAMMoVxaIAhm/gpYo6UmLX223N17n89nNOMlfKk0Z+tqcrr+e/kUnTwuGLNYf
#Bvm6Y2LsCrHG0UkAG9sg0C/MjN1VgGgK/WjawahDB8IwlPXdR5Q3n3f2yNz0hUjTe/xfBKyqHX9EfVV3MAJ9ycJYB6KOW1TSatT/mUEt1X+MsE6XclDN9pUp
#YfGqpK7sgGuHS6orxJItUa3BtR5LoJgTs/mB0ctY/78KigujZ5ass4Emx42XfHyMEDI+ztvnkvf80b4iac9XakUSn99ZTyV4J3WS68X/+JVDF8d5po/84qbP
#isKtiSffXY6Ck84Z7SpG8Gz2mJICzDKSX1LlrUzeh5hZ7h7XIFP40W8HHhX7ONWlMY7j46CYt+dmh0j1DeSmVrhRG7racf3dSW0Ao/hclKmmd3uwUNq6rUNi
#TVDolaVjLQqxLStUZxJMqYVqptqXE987iK3qpBzutViFLmgtKp1QSvWV/6d1BuLXGvdhClcY+hr6nqMOdcLe4MuxHLgb7GXWFbFvZZe6V/E2q+iuHi5uPbcr
#0a+36R3ZPLHg6UUaJWZmA3Z8YcaZHgQ+h3FbwFdLeWCdDiqfU+zceB6UTtjnaQdJnothFSngML94JG192LonYTvxjE93amGrTM5lqloGKgWjVVWFID3FSqyr
#YQvxyVTN8cqks1kS/h4laFT6TqMkHQ2sYLzksJx9R1/D+hjJ8PV8kQfwUlo+l7TB1u2RxKcTCN6kM/Y7GZE0rjF5tA7O1jecOSlytVz0ZqqKi8JxzXO0pp9S
#oNOpCErGQQwsJF6Dy0tiB97bJRzXdrXpWpi7cdUX89uFmro2QeLOhTltwZRamKNU+3LiI4TYOZDUweGNs9MFHY7ZRCilenXvp1kKjbM1PGB76+rKtmtQkoRS
#rVlgbVnT/8TiV6Gno2OtFULWGYo2CabUQpFQ7cuJawKxhZ3oUUOxkF3QDVAwhFKqr+Hf5h6Uzda0IJvI1t2tdsACvJragUqxq1o3PmLLZysa/P5mrW/lwHbV
#MY59gKASis8l/g5+ygZi37D0WjeN9DIVes3oWNuA2psbaCEJptQCzVDty4l3CWJprGkRKlmjgEtpA6iTUEpdjAi+sQ7qNJIk+PhhG8Em/LAaJ95KiC35JCrd
#sgKblQ0dhXZIO5QIy40nSg34PZPCmh7dFuCADjIUmb8oFnuEUwuF85nFEAEck40GseEyMfMGKc7RkcuUWLCOsJA5lEaJNiOfnCxgyCjJN5t7j4yRpnALQ163
#4C5YQV4lHHRx4tWL2CBLorEiyKYscHQ0spJ2CBT6YqCLDJ/m+S7v4xNkyTPS7Jih1PlTME7Z19rnP34JwhdBPUSGotpGz4bNTwap2zPcez4ftQSZu4tm9jUh
#sge+A9NxGNe0vxhXr8TJG4s2LIxmz9hzUwujeuKpOHiRIdZDSQIWTnRjF3QrjER23VHN8UpVUN5cfMTC0DKZATV3ugZD5TPzpYvhmMy7EOsCSWueNxTnyOEy
#NW0uBxkWWXaGVUq3xuCkYicr92R+Ms9lq0V98XTg+CAFBioP0XZgJtkB1Unop9ngzknahA9baY+JfdldMYN+m4umHZgytkhM8jBytuzBK30aX/LuRd/1Bjtg
#KaFXUoKimPRCfBWCSSg+l+S75IeMqgTB9jPaGtMoFXqpdKxtg+VIhlRJgim1kHJU+3LikkFsSibpKNGYwi7oDKQnhFLqYmbwjc0QI5VCeS3rU0kITrI8bVbF
#gK1g3qhsQU4zVQV1NuL0NOOSu/Q7MmgixSXencpJ3DPZNtEkRtw+MYHEagfnNGIT+SCnBbIxyxJG5yB6T40qDsq5B97cfjKNffEJDZHvW0L6h1qIC1HacUwy
#DLHSkHTg8VpxjmQuU9IRYw+STSildCeE6kSSqF72evGDDD58XF+z+q3jVowsQoh4xtjOFLCM8DFWxTDaLh7diMV80gWjJeKGC7orgpwxMtycs2rGxl981Ll8
#pZ5ISd+N8e7QqG/z1yBQ9V09wl9uoZCDYOhaZOru8NWIpGL+9a0eUha/3UZlcRAtbpL3PaX2oAqUlMXuqoKF1YqMzj1S1LONDV7Zy9nKrsc0yAvP2EdSC/Jk
#4n04uJ8i1tuTPPS96A0u6F6QcfbyUc3xCs2rcNX9Afn1Gaj3PUirBR97KF7oCLtJKg28iHU91UcgkJzMNU0fQaEd2CX6+yrSJbvc8sDbIp5eUPt5ijVZ0+7U
#IbKokZQz5eaBTsA4O/lyU6nRyvCYL6ScdXTVn0h7Syy8MrJyyW51dvbEtWD3CcXnMv98PmpEmqp+10TkBBujwVJydRSkqlPMWOvVA6O1UugNomOtGmocqmAF
#STClFiydal9OHJOItcRkCGI4dtcu6KHoLgilVG/YN6irQe1m0lQ4yeM2zSl2Oz4NasDrIsVB3D6X0QH79kj07jwLvzkCexC6pnbE5NcQID8p/E7hD5Ph0lzQ
#A8SO52OvX17Q2CvagZC0XmBGSaClF570+3h58c0dhmgqbsNt0JFsPOWONqeaI1Nak6JCRrUkNX6J+jc3GM8zgcq5SX70XuIltWMmh7p37bSY0xuZC8PUuXBv
#PgOQPinPZG8X0OFEyzduSvoGoeVz6Rg+u10twmqdXY+DVmfO2DcuJZplr67pu2Zp82dkQGxmM1LV0GAlODq4OHJTLRjSTJC4+AHVAbKDxxBmNeAdbFsXJkan
#/2ry8+LbtqCiacZ2I77JfzkAwq7hC+ka+EV1cWpedDZnM45k8pHT1cjoUnoKlJCtot2csxVJ4eo33Qu1BAW43WjUE8jBSSO+Z1tObM8Rq/TJNNgGGlKmZHoa
#5M5pAypOeZ4teLJyWL2hiTREz5iUppcAmGyiWVUyMCxiu76aIeQgwdi1Sge6ChP3XbJs5oE1/18i83qeGtjt+LzI3gjzoQb6is3JcqArW7OvZzf6TLribGek
#hq8Y2z46nbBfXkQIpZIwW+03c0cOlfTm3U9aBw2ytQrYvdFBc9OMDZxa0NSJAXGwuUCsHiQLYI6ibrugF0J1We+Pao4XYHqR1ePCmzXPWG1OL+Fn9QbNSgPb
#KhiHWix0qfIoo14MrdhUy1rRv0R5N8f2+k+MYWuqQC00uCHsUQ0dhYkjoX7Kjlanfwmy4S8ZqDIL9u0ltwfzyyXoN1eEXgYV0bxvGV6LRVaf6h0PTPYBQk0o
#Ppfiu+LFVKBgWMU2/40oqaT3Px1vACj37vmVMA3FtK3ReII8t2CKW/KIVQ7ZHDTLtw1Rpr0vX4gtKqrAKZqxiil7R1eLLKCIQJQvfArAipdmHmCUsrywssJ/
#Lo2g7W4buWeMjekleIwlNKvgJyn3KGZBrRbYFF8pSK8GjhnRKrlg25Xsc+SuR4HlgNoPDfJWan/rDOQ+i0mEDF1BXQjEC3SFD8w+nV8xomFE0XZH80AcME13
#tfxF5n1ou2ZymOkWLeaeETVynYU9Zuz0cdtEWLjdawewYNucWScksU0W8zGjVhZuZCdA10HgQ0Lxuezc7QhdsJBY3tAbIi+lQm/jI4inoO7KOminGkBiYZwI
#xKkFg94coTaF3pb7CTQaZk/KsHctQcsDG/h8EkypBY6j2pcTCwSxbJxsg9BG1nVBbwerE0qp3o5HE8tBvVv8cTwdUzEizJTdHuHbovOfGVPeMpDeBWaatpPC
#7272rfPKYeudMKbJdlu5YcBIJ22uGbaDuROxzVmyZ8RDRDg2B6UTaPu0fdLkOd9xlEMznE9pEcse6CsL7hgEaJAwncSJWQextJfsA6uBLme0qfeBamgHWiJn
#/+YHxtCLlmZCH/8JZGDfXU5427IQlI60hbc3VFQg+04TJodYkksOMuMgeHNlJJ4cBCPjzUQ7kCD6EN4UhBKIS/2HhfRrwe6ONrxBSXAkwuOBf5snrxNgHWEk
#vPYIEzhOTNcQS8DkKGjZ7YOUs6OvTyCbtMPRou80hbyVe9/DojxRd6SArPARbQeek+yB6jOIMh7uYl6XaA702c/dZwSBLATfWUsddsJjEEXV2q0KP0sixgAu
#3CEGN8aGvgAXaY+NZZc7IHctig8cTELwQxUv4aaimj4EGlAR+6Cra4kTmuxBMNdS9LSIOu0rpOCWexY1kcgYd/oC0BXrk/a57N5Z2QnCI2LVqIugclTlOG8H
#zFaZtig4EurjU4nwXDuFlKSw8snsCkG0J9mUhTw7sXlls0/aFt8/dIR1DfKIUFwU+miSz+Wn5NEzR2cmPVfbSi26GnNOhV7tfsqvwCv7/RC0bWf+fhMdZZ6i
#3bY+o+ML6nBwi1AqCcByVd9GzqvQd/e3HAefVtU0PIBN30BJmKEgNmXa2JGNS4KpfOjMAqL25Q4lPwWUR9ApqYcnJ4JKTEMynmYQGb3mfcQ4wDf7JzSFopbQ
#da1r0KWE4oTj2naubsdOVaHXuY86BmiS/dM2gl3HMbaz1O0y0Oq889rnsnSX9sl6tPDZnah5tHi2A8v4pCeUV9r8dcaG+HgXxkjdgNkVkmjIpid5CpvT20QQ
#mERZYSPWsbuwAGpvKxBAAvaUDYAWUSsZ9nPECOPXdCMw6dCkGqCaUKoYIbIo1lKKLMXq9R9JSADEjkX4m7p2DeAtt377XN69c+pKoe/bVtMIsDtrhTxktqy1
#Wd+HBBhuyQfDAXQn+4MTdz1iwZqo6LIIRhe0BggvNOHcq/emOyWVvOAvJ/vlujoAoON6thxoVVvr2gCoYy0W5bjcdJDUoF1NXcPbI64JpQqTBtNvB2nUTiW9
#4f1Uy3CWrc2BbbNDxacZq2vWQpmyWtB04tpdxJaLxEatQ0VZOdI2SpmVcZcsd9aszl4isYogHs94Uc5aEIQXAZqVnjBWo5Ul5QkFFkImEu1BWDxPq6SPZDGx
#8k544CvPuICjFrjDPkDTicvJIpbrSYCyB69mXNABOM2+c5f0j1T63vf97lcSdDR0bJyeCfel414Cm9hXgJtVDQOtgik1UXlTfFd8SZnKNlFlkjFkX0+zidF2
#PJIj4X8j0T9v/h+2mrfKtrjzhVBhddqRRQQrIrhjJrAsYSbFiX0dsYxJJnA/DM1ooCcwF+1AbfpiYLzIhZNH+3VNDpnBOGnGFIuvRcxPCKVigEE2yH2VQtgg
#ksVkgwrQDpN6uDlnpfArT4cHInnGmp21QBjWV2g6sa0uYvNQXYUD6s7yqb4iV1ktd8ny2x3jrpdDXrfgTlkgrxJWcqrwJ4BirGKTCL1ENmUyNFEoqcZS0bLU
#2nvXdrWHjJPg7gYCtjFhluLE6nEKNEirUKNYxtbIBrYesRVpB8j0TSnC8uriPjVuqLp0BjYPp3r7XFoHpdsj9U9v3dObJEe/axOVtcvkkH+24eH8frwunAOx
#AdiA7WQcAGufk/Km6cRiX8Su7WSDGJBo2bqvN6y5zYTH53LyJoLAeZHmnz6SVt/KuPrjMnCX+GA540Rvn8v6FMZL8kbCbFCMZXMah6NnfPtj8Ut83ZHjWHCD
#GoQtxCwViG8IxecydDfUpSSkNj7TmsYVtdIzutZqV5vdmMwjk+0omnNg7p5E5pypHUwtxC6qpIAqiGC2CHTBnDm995tWzvljoJ3fLlG0GfEudJytHM36p2Qa
#vSxK8oEC3Ge2ZgEkAHHszNANt/M4w+P8trFrj3Db9oyns9TCLTGZajg47yF2KiQ78lac0i7oAzcrT+vDzZl/RE3uysIUNsQznvTxEkuTSU5VxZMigsjw1CkZ
#kqqo+pFu5AFOSf6pzkibPzKvOzZXORmLJtvXyIPDmP2gq6/GNeYt2cTiefIcWxhXQ4YN/Ryja/Mqr2LO83JobiHTVm+oRHIF99oq+eCZoH7Iyv5gpVaehG/C
#xqBeCiBdsUquX2Lobi7D4u72Ur1+WTbAR8DH7WVLFMD9D1rimsHN8IouYodR8hqrC4s3Gzr6dQorn0ao5b7+OWB/r/JmkO1Eu2vhnJBIOAlNngwHL2MFY0ve
#YummYVPpzFuh2QyvkMq3ZPmGesw2lba4fwrJ5xmH8qgrSpN9tIUvpHEQNz2NGgdaxIaQei/FI69L9Ic0LQyQ4ebMP+TqO2Vl0UUQMecuMABucCC1z+X6HeyM
#SJh3LY70J6Brit3Rk6FzZc89Crhlwd3uAowT3o048axFbCwlXzCLgd4sZvUXIEI77BgXv65dDGdwTF/MCAVj0fv2mObjqEcQOSragamyEQUb1HfA5xjpxbzu
#yPxZab+fmcJOHxgB2E9BRxfzAeMiqGR+ivEZqOXPP0aQFmZ+7Z7WGtNhDFL3TGON07FnqpvfUq1Kqt+yaBX90Zb6PSx6++Yi9wxRHtBVIZx28PT9zQZE/V22
#ZpXGud5mzTUmYQFfQ/FHIQGeIOujJ8PBwxixN1vyH0MXiMluOv0fJod0+hSfA0M599SbZ5dY+ZemozTZHTYDafAWChTAq/cGZm9QE0jJESOLeas2T1etjPHb
#vEeaz9L4VUlIVup/oZkyqb1qlrOySHswbKVdQRS58JikvSoWbkn+kj+rpjexwpm02FANzsRr3eKqyMj86/ktzMuXsSqKkHSGPcL3epWkIx7nt3kR5sXLXrVH
#VGVRcjj2W9BUqOiLyvinispfpY68jFWBm7rwGG+/ytWZV7aDlVrE8uzEtKH0zXi4Nl2lz5nXNd9kHuyW4Nv2OfZQwfXyYm15nEbmWcz9l52wh/YzrR9VjKhp
#Kf9CtDKaqqLzE9SUl5EQcNnkuUjSpDg4Cyd9O1ixHbFUKYlNFQXCO6NAHZti/NM/oc6PNT9V4pts2zt3PmNnTxU1zcL+eDVexS8r3GzzQya+vRfF9dLe/Faq
#lUrMt7dLI3c5GKXR9lfiJ5DU+3opUrd+XEpQrZcnh6npN2qlSvrv8N8j3NeLy/rfx8V99W++1czYxToV+TosjZj+LuEtvEWW5b+mrege+XUxP8ZM2800Ck/n
#V7ZDez1/1SmPs1ul5MRuYnbwMHYu6iOnvD8d6Eh5/aBS+1zm39Vw6XiRZ1kyqWJopK/j/LWaBbvYIht8hr0c3s8mveev0vNizCwZMz8s0kWdYQ8dvJ5m68zH
#KV9l5lnMzN0towzOszOuP9Rk96qr7BxbkXb+hi6+rwdeA6+30U4dcPODkMDEVLaiO4RIrlIOMBeoGlG7dAD5p9AoDYmELVie1BTNQrLMtNeJeYoYHyYm2fgZ
#AySF2oSPOiz/y4kbleqgUnNaBfSNljyqpnzShCwqe5veh51iTNakM175ZEJpGMKo4d6U6nU1YU23+u6lP7BSvMpTHlZcVlaiSE2b+OE2KHf6sNrTnl71vNf3
#D8l2KpX8RpzQ0lbSa0aIjWNChj+i8MpKRH7QROYlGMtHT2A00oTEVloHCoCnEisAYtWfssAOAwADXvgxOnrfKP6YEdwOe9L3hpzmPYCbw5pSbf3AYXwXALQU
#D14F1jVb0K8SHtSla38CwP/Kn6LX1hfTHmC9aVaJSaLZ8cImR6XyBEhB3/NDbCUr837QdR/nlEKLiMRdBwSuFO8PgFKBeJU3UmwqDsMDwAWBggcNqvK8bU6D
#0ZkGSdrxEl7/uleiJUFCHY0YkJx8/Hq8btAut/ppS7MMy7a8MATQCtdYhBoufo16QXz+qqVa+k9UBXgOA3j2XuH+EkCeBffd4y8D4PH4bPcWjQUxSNYeMJNg
#/eQ4v2tRIIaHwT5rrdeRiVmFYWYkFUhN4xAbu1hHWRlVG5HpFd5xXIrDcrjZhQAIxCBoSPCWGFmHqgjVBMHL6QD5kEKSzZwvyUJeJD9SQiXJPzrq8ZAhLwAi
#c7SQKzlNaNc5JKRzsY6yhNA0evNx4yy6FQmJGxR7pOdMLSKh6Lp4i1NK3Cp4gClWW4AFGUoIHkLxPiv7JY9ndc96CYeUCCIDCZIQhZqsBGnLy1BNcWaMoMQw
#BgWvE15cIRQJjTIl0eiVpDTN5GXIFCbCmBzTbR3LhKcgNnGJTvmIhjZIcYHRZoeQNtc2XK2KvdqTZISRcYK5TcLBtjaVpEddMh+3yWSPw0Hq1qFu7cOOYe1G
#FTfT1aY92q1di+1tMtyj2KZM/SM83sVJ/0AXD6pVtjxgHRpNGRZqp/LBgP3i7e0zM3FsSSgBNxc7x0TxyIwti/fqgCRET4ilcx0DkfXcgajtnTZbxDUORqia
#37K6cFI/KB9/gk+4Nj9kVxPW+m7GdsIYzOFBRIbEKiqv6gzZIDlBG/TGQF+D3n5hkaJUwu+cUGE5jjsGXkIhzVxfXRdqByu4Je5wfWxak1BD58SLKBY9kH2R
#oNleUHwX7HIc7wlmuQHL8v3lRK0EqmEybCnndvraT17J8tDIeeH9c9KhWMfW0kvqFFbokOwhSrj6Z1JATQCN/00z/oUl7uHqzCWkQpFogtrXOZogv1put6HT
#8LPi8g+80ZCnUX3KJzg55SEyP8JCXkBCCS9LHOMxDHZRiNw88smijx6ZrAaNgJAIriHkYsTnxEoLS0meLwKg58gKY022YbBblMyXhb8FGVLuQgQ7wHA++Xzz
#4sJ24sUG6mmR68+Sl5QmhS1xcQQ9Xxgf0N6eilXKvTMaE+km2tp8UcYqXAXmBi/3UcIQM4sCbZqbXTBy5eIyG5AF0h6l6wvyDyD5caGV1JH06dy4TuH2Pue7
#lz5ykA7RtXmbUcuXCdNBYUBmQynOajzzy7Sb6r0gM5pqbdLfgDb4EL1ryHyVKDCowOS1KkaRqb63VBrSdzLwvA12N3ikGr/wBo1PzfrNIggFgabHFUQMcuWr
#EZzEZcqi91AHVgwaQSwfNUh/hOcoR7JocB5gSwq47Mhrbjz95STx8dEQxSr4ah+AIDjDpyVDphCPbEvkRRJTZIVVW+1FbLAZAAZmPG9JCm2ium31CAy2Pj0y
#knmZEaD+cUpmPsEEoQRUsvphMddoJkaqI2qrDESYOmLebx2jkijtolYzgqSakgRuJAMW1x2RxbNr9szZVOOJGkpimKVcPOTLULp/RB17hVSpikJUIQsfwooj
#8VBgREqlHsJ3nfidbqy66rxPXpwmT125HWPMkjHhNgiO4um+T4cINklqGWc8ReVWjk8609zq6Rs4ENpwlzpoPR9Jb1OduKclT1GV4WYCjbhHyafIZG8gKq6P
#mTXwFiPaqmts1NTIvSEryExr5HYvP8PmI/UCEYnJrKIdqxQLXs5pWEZlV/D+l6rC7KTSkrzb60hE5Bnp8AtRXyV09VhHsYyFf+6QL7x1IZcV2JjIXFBK9W+o
#mfJO0b9y/en3Lr4IsReiTfEzMyyVWxJXPSC65IIU1jxMMB3CrniiBZlq3t8bocHwKOOjiEyzmgB50KrSen+/TIKFCFWhkA4IJLQiltZY8FvrJXkD6dVa2b5u
#OcpXXueiUaWnIYC7lK+mnh2fOaghgacRPcqhAi1ZRNibGOF89K2Bk+r5626xvJU96Dv/3CcjZ3MSBOTdB3KFDMFHfMHcvo0im40+rkfXt66ThDXabqo3TtzJ
#F4YKgZsx0mMgOMFauHmxySiNHS3GXfpoCvz6a17ulslgKrUac8KMoIpytGJxlNb6RKbZw6U/u8qcnv1repsmmPT2I8oQ5V4Z+f+7Cs3HLLz3ZPKoNt1PHgqx
#ag7+ksgaE11+0qLDUliigk2xlhyYuTgQkidBAbONp8snOREhYyUEzQnQE+0m3xO8tqcdZqs7ytQWjPMpPMWXTCuzD/sqpl0onkN8JdGrohcmemxzTUH6Tath
#2yj/maMg/Hi1HBWxcfAxwc3o8fgZQR1b70fCj+O3iUP9SEnhq0YFUpYkwoFYnSOaWosbRp1bBE6aLzaL8uc05u2ZR6+6VoIxpG11lVrLbbLtzdewWF5etHU0
#QSjrkhZZQKIxwVW2kDS6RE23FvwSj1H4UlouWDyTaPkwE1SQEn57vWntbbEA2gqKL9dT3NBgjUWFd1D8WQoOJXvejv7nwAnQRs2Rjc01saMeZyMjrU1wuHGS
#p3OV3+Iax6xv5Af8qoU89tIcUwkcEUSvlwIjHZnKQ+W5Ub/COOxJySE1MIJCvGpFHHTXEHVKAoqDVywpWNPhah5n87hpKBoWiJqSRyoKk8b5mSI4/7ym76C6
#ty1KJUoJliFPG8szSh1moFKiRljSUxApOxsshDveslYwjzbFYkShg1GsQg7+R8n08aOqfWjDF5Dg38h+8cuD+oN1HvDUT0q8rrz2k2VXVcd05PTA4Da27YZb
#tWmxomjjjmZMJFkfiI5tYsUxY7ZcueGKchxLEjIEjl5uvKqe0IMHKEPyRbA5/s8yHllhiWnqngsWrWDX3GRpsVktcaokp3xmjixaeIA+ygUlcsNTJAiXqnIs
#LRutQ5nqOxvnZVM+Qw3dI/Mv0DBcw6SNsDf6pRcrP5aLi6a6aYLXlW/4VujrczQdaH21vkcrhv2F/aR54OvORxGwr+Hy91dZBGm9aab0ozNuXT0byXNQ4Ho9
#QWah6ZD+7gDtWhC2hCmqiDUR6hKpTgTkr3RMWu/3N0ziwFlEr4ZW/3mGTaTIOiUQaxatrk5UQMOejSBu7EE9Kt6o482dgLDjeri71/9jZOjgUBJTerhFEIM7
#rsuSNjKsHLb16Kdk0wWF8XX22fZ6GG1M1nIObOEPVmEwZEOkGKT3ZnYcwLcoFMauQORYMCL4PMsVahdg63wl2Z4QC9i4XazgXix3LaA8laAw87HFHbZVFUat
#VEli7o03rJXgGEziBLhbuUjTdSQxNXqWKWLWZMQ9uZCKkqYH5Zgl9GSWMaLBvN6SzcrhvgycPjBXMFs3IpSyoxmJqIOKVqeO0Uqq5zlPrAiuSbAIiqeNeP1W
#mwC0Rf2ymly8ja9+TBxtY63KzUzjDDXk9b3H/k4yMM3kWvqxwakprR95nIK0HIMV6yv8MV/jHxQzfsF323ewXRuIysY/a5/He1mnLyUJfccpkG0zrI4B6obM
#9oTvticbizHfM44TxQJNwDTGqTVZdExZJGXC+zGboQMqxHmTAaCqhbvTbKOIWtPjOqVjVrvOScIEe2KIuoW4EEmqK1Yfh8pD/VRGrI0c6mkHkI8h+TYeUVM6
#R79hPn1/JI2G/MOX+A3OpA8H3zBJZhYAbWfz6A7VL+ogNkeDhSbNY3cEWk1amjU8XQeJUx8gHqF09IPdqKzM5uPVNPzfT75OKUolwezfNh3I9X/PqEVaoxjj
#Z5fqOMQ+fTBet2njgLSznYztNovT8HTaXY2OmHXAD25MQLKacV75hrlblvDpav41T4XzhNmKbPSHQ0mBTN70un1sRseoYMRyFYc5mUxdnh/gZH23+/LdGtY7
#/7EuaPQF/uSr2ea0NFybU8B273Nv0FPNztOW5cDX1pkKi8xiWWmNo1ixFPbJNZhIotHJ+yrmizApl4tKRV2ARcGcJRw7qsM4NmcJhjnYpTaUlCGYWIyhMr0M
#i5gUZCRSat/eBdTeu6Ku4wpcCppC4JYuarfBg+m0GA0d/vn0AO+9/YT+Ya4xd7qeAI77J4iqnySESIkfFESxuIn49hgJq+0eKXgpIMd+8CUEPmIzbzOx7M4d
#RFN8XZ11pALXIIhe44pzJwlKRN2CTlB7jxQ2DQnco/arPfUjRh8B2u+RK3QEKLs3X//VyYxiZGqd+uX8e1ZKQVgLpSPSz+9scsxvwil14W1hrSUUQN5b8N9g
#UqhmGszeYbm34D/BxOnLufQdgEnB7CVsynm2zS58IQw9ukKpQqFYhsl0smFWLJLvEe6g9t5XSg+H58BQnnPeu3J9Qf96Ma6RynC1eD04cMZ/anPo2xEKN4fr
#RBGM65CcQuniwAVDFEKPpuPtB380mlop4hIa8RlThkizIqi99xA9/r83m1xX5kPnbJP7V3M7ectXCBS4SKxQCVYAFkVTx+JXR5N8nVwhx6X8giL0sjtDlwAb
#tWJOlaMYdbb7gZXkIRKxCOGzC1nop565mgRDQCfhV3tLwKsp+8RLYnwlYFLqGoOuWDJWIlJJJWKVJJaMdftbwLeX7tp6v3tvtpXHm2V9r+e7mst3QaDybhUv
#NV6WF5OeV0FXpNqkqfQKbXR0XkW8IJUw322V0hP03KgolZiB0UHujdZr9Q3B2wsZpI6xsO2255rrRld937OFDL2evrD/OXgVdH/cto554cvExIcX1jJt98dn
#AzOpKVQSe0lNYSUB/qJYPNayco/FfIRfek1QguZiZATeXmlxBFymHqvvtW8ltSoejhjl7IrDhSXMosdAT1EaNfK4WB95jxwM6YuLkxFaRaUn4BiyewLBciGq
#QLYgqELIR1SyLTJEBVgUzF3CtaNbMK7NXYI52udNs5DZiEAgVmGyrTKVQixAhDRymqV9HoiiEN6AfcjhCVQqjVpZXFxI3yB5j/TFxsmNGnq5QI4Ph7iAQDVg
#UlBnKccuTwyOLTIUFGyIq4p7+x2qlHJ+9pIRyg6Yg9FRRCWToio0PQz8e/cgMehAjTrNEDE0d2a64wHxYDcYPEOczJ+Xi4d4YmMkBpXC7Gq2d9hdAbPCoJLE
#zPZVi3Sk2ZidTdzrIzLDhwyihvy/0ahvTjZajqsqXfOsbWSDWIbwBIgKsQMz8d6iI0TozTECmM5UDsiUmPTsUwIJd3W1zgOOe+RW/96H9RfCLs317f258RfQ
#Vaym56hY34wRc+TUqsyTBMAYBiz2dlFYflGJQnYgP6eIns8RlCP7KoepH6SlPqbu1wzTHqeljVL3g1oGWQftWwuKBWY45jATsMHj4Eo4xkZ0hbEKNYhRFNmA
#DLNiEQYQc6DmDLd/WEKjrHQ3OYbkBTWwRKCobIqFBb8JEc6jmRXy0QAxB4bOKMGEUausdC45XE2EgnTc+K3JPDIie6QtDKsvPg2pLiPLLHVNtiwyGZUpRUKO
#Xesp4QKC+pqerEUL8rmibNrzCW0UjK7Q4DobtDMMDu0esnoqj1H6hEF946A2yhoN9ZoyZ5UbNKgr9CrFTmLnTnLnv4l/K+SSLQTIpzhagy47aZfJlXwBopS9
#B3G1B8F35+m13a2DacVI2rr5rTXZ7qDXQoe8pXT3rFmL6JKlVRJ4Fv0nVbC0rIbuEfWKt86d26WX9gL2uynnIv1NI/4P+Tkf+gMjvnNR7yT7O8/4P9EIvu6Z
#fwacPgNvfTzd+0al86pcfhV2Vbpi7gKSLO0uINaTwm4VAZgUQ6WiK6ubg5VJNGV3Q6qZI1GN+NvUkLRUkNr/bKaFAJK4Jv1go3d/T++KfQSorf3v12tK7QVS
#TCVCNGo5GYIKnN5SBeYcDB5Ehnbrys+MlRMgk4K5+7prgpQqlVKZQi3iyBQKmZ4cPZlLLCbfvRzl7Wx1cuQ8m4cDdgzq1mYec+e+lfv9v8j9II9S3VpDKSd1
#U3y5TCFTy4bfDjnb3iFDNy4k8qb9ODDG0nHlVuBu9qhdrUFQQMEbREIfzs/wTZ5jeD/Ts5loep7EwmfNw3Ghr06EG5ByE45rDHntC8ZCl8c1kVevW/8e4Msv
#ZxHXIkZxW1m2s2iUpcgrfsbjPS/OLVIsdhYastV2rHp+g9cgxWVcZqFqv6PIwFBXywUlxhqmXC4oFoFcbSVySxcvLlDm83A5uESeE1vPqVOphQ31IhV9T2pQ
#bzrTVpsuYqRLSctNSGen9xbJHKWUJ9C9s+d+vKy2NHJoc0KAnbqJPf9rXtzILVwlMc9pZE9u8t6V41KQnvUoXOwTm/CTsP+EatnlWe3VkhvvQrRPvrgPvClS
#CVmS5PK5GeXJ46NLzxBC2S72bb6fiOUrhCyWSrjgTZQ9MymMj+k5nzIYn+bQPwb79xp4iwZ4gLmdfodKvUNnjOO9x+nDB2kwcr42R5i1PSvzSGacCq+u4AUl
#4UoynnwlIfH47dLjG1PPfqgKRE3ErVrgX/AoFt1PmZ3izYz0SeMamwK+/GSUjehwsVj/IaD95n68jiNwYEIWaeK2+SQ34KqZP3MUCg5XgWEPGMblYAowalOX
#cMvf5SD3GVk/R+KWuemE5vDxHV8dX/ZUR6LD6kjsOEUo/lo1jlu3Udx4kT+P5X+FZJ/mlZ9CDHY6UGgMNxYG3gGV2dfNqIt23Y02v1S8Y4Nb+4+54ohB2rMc
#6AIJpccceggcf77WHnetpe7+dPOoW7NnWaAmwTxlM5X2G0bL2f12Ygq0dVUjMTaC3V8+aijtt5mmzLUJSwOaPe7Rzbs/BbcCYhODqaNRhrPtaDNsRu3ZzmBq
#N6ziQljISknJqqcjqjIkTI6XR7ybKSms0hFgCmTjPSEP26UBK8T1FG32CNLM05i6/uCTwLFf4M6ZOyHYHNi5/HIMrM6CCAQGTy6YVGi1VxB79JN6UPzFAA8a
#eA0gC0RftACdB+4PNB2PukG6yMgb8bEBQlbdN29xbYncDAqy4F64TQ0Q8ypdgQ4AnsWKL38p6H/KeMbwXfmWtj3LjgBofn+lR5RgytQ1DIf7SEVuv3raKriK
#060ELdQUfw6eS429fCDvncbYqVBe1Tx3ASup16c+gB+MT50zJtIKCWD7+PQf4A/s3SKRM/9B9Nxn4bSsj2B0GNUzN6Upf/WafJaSxkAKJGZJpjkztUm0ug+I
#m+S1t8N2LD3Y6DHyGFAGjg3AnJk58GQqbufyfOdCwHmtwWgvVVQ5/wC69vU7jV6ZOSlrrL9P1MLdmjuzdSAtgruNPD7hrWyldstL5wwfvq0W6ddlDNshA5ai
#vOxL9OyL2X2OfonGnDAhl8ilzMUXT452A6GBkTZ4sG5vNESDJ0hjdsIRMWdB5ZY7kJZYVvfgByv6fsGzBjOI70pVY+fvxQ9d9+vfTGD1J9nCTnEuPP8dvADZ
#676v3SC75eoSbeO72chXjKxfKPj8vHRCaXff12/t57A/ldMGjwKPgNM1ohEBibiz2nfP+zk4DcKeDnjQFmlr9qErft3IMfSCHG4u50etrjupxv8BeuM1/Y1G
#TE+Tqxgc3qeH+hN7svO15q5v5Odn/WhrlK1hp4VGBuXw08rROcOTdfdO5nEpdtKY8r3VuHCR8bPemOCvSujy9+6uVdX3U4a02oHkjPSF0721KOVeKA4n1/DT
#NN6BiRyNHK22kStyK6RFtkr+Ri95ko2qtRhaoVPhBrVcMuPCjbSi/bj+8vtupcvSUkvS49JLUlPl6eAZHVPfJ07PUXzqOx84Gt/Phkjr2nLotWOSlSlGL0Ji
#uBiWXXDXwBcEeDaWBFa+DK0LSeKShE6DGmB4B16A5/8YbjXki/FGXyzx8JmhU/iT8yb/1IuGAqtbLhj0Rt+L9kvy6qx27IhO7nCkrKS3tvI7fc0NTA/MHYGZ
#8PPv4BdQuiFi+O4mevsIrHYCaHJ+r0sAeved1l/Y+D0hx2Rx3uMTJHdLbmTrQGTSw+dho2D7CAxCNqg/kglRPDHq7scOpJNe/dJwMnypHqR69AI9iF292Bbu
#bwgxkyXHq2YcmgV4RNBdXxm+RLKYCPfUAyPJirz2e9/tfw+iodESsfhmeE3xnMEjOiPWRp8LY3Lk+AXwKuu9t+Bb71m3BbBzOW0NrWupa9esW0cLOKmlSQ0w
#bYcn4PHvHvhYFTFziWnIiLflpwYByBQuVuMiuhCf+CMusTcVNydzuFqc5hJWDwwMlf9aajq11NgS0v5+nvDm4rYQEPPDF52p9IbK9Wo5Gkf25TIliqEKVG4C
#mzTk4Jb49j9gJqCiVACUZ8z9uHKR1UQiAwtUprKASBQoO6Hmp9EYe4pRZUXZgjJlBVq8J+dmEkUVJqSXa3J4pKe9weT1t9lwfWhenovTwmrMy+1jLWD1gScU
#otZS3s/laYp8L1LV2cUFasjgiUx5hXoumd59dm7qYlNKsjbv6Nf46/bgtY5Bj6xK67QbqF9bNnz0+FlWf+7XYCpwjDwGYj21Gg59XRmi6my1Zs7CE/oWWPpH
#IS/468/W826gG8qnTLfQnu3yux+MkL4ttUEYvfVr7pN3UdYaidfwmPwLORsac/evw8WK2fDR9ni6wqc9TRGcwPnE00bgfQisJgXZNwyHuwA2SasgX5lTYFSp
#OJ3C57FXmAIOHh1dU7C+dsAGVCYlDjh+uLBVMTtOqnANXuuKmIsKIFhntuKrOk2uSLR6iaaGy9E278ZNdbWXZ8NBqDao+ivYUfbgWqbAY80Pw+FBib5iY3H5
#X/5l14Bz7q/ltysRzRkjb/OnykEAlBjWmdUb/bO35Cd9oqKc690zQTK25P3dOkCJ+FFUKgYM03CmukHp7yXAyXTc159Wzp1c8MsP8IdfrNtNkTnGqiZpO8yC
#dQu/RyLzO5uK5TowerYzUz8+Jd+SLFtYRn+/OVykcAqqhtcGZkEU4JgDeMikGAuBpgeW7cYWvucCLlH9y6yZANYiIlKjdlZKrArPpdzD+dD/cNgH8zOh5dOq
#4BZ+M6xqfBtT3Ur1LfNAuszwbdKhd1FuWNpO3Lz0UwZG9sAv6/YKYWD07R+Ct3gJDHb+RK1MuSFaBMovaBljnwpvZIjjU3ZtX8VgxZvJF4fCnjjDnU/CXhyx
#uia9rrfJkZGI381L+sscv2/ZoGqpQ9nhwxP7wClDMgNgzypyzvWpH+GP41ObDyRImon1sxDGXpU/FhqXn+2gU+vxe+qFPaU9nLGXgD9Jy7DYM4He7kRiV1Vx
#obf1VaC1i4Pgw6lV+qOpotKfpSon+CjLqIIVdWcqh8anfE/pT+uoDW7O2JwX+CeF4eeU/p927CWYgllwHXwLkkG9ovx3WH8DsrncPwTr56q9DZkHjYvnXLzp
#o+ru9HBfmogmL9FKKqrrg5dn19Zt2ui1gS5T39TopLfAyZld1pkbL78m9m7cNE98Ob7elXkF61uI5hrcesJxTPP+/ab8y7MD/T1kD5i+evE7Lcl4yjeU/ZVZ
#FJX4/nv/qo1zhR/SJhj9urHQizbpX42FHlu/skI+3thI6r6npZKlNEMSRnIILJQPFk75vtiI/UWR47SN/I320ZQPNnw4Vfr2K1gK60KoI962fxu3zbfNafY2
#Sx7sbqrxksWb9ZNNauzErWB4xC1T6HrQsQdtnQ4BUdImJEYmfp41WHkKSCrO0b4M14eksB+jV4pfqZbJfo0eiFWUd30BkAoUTvWvLQcLsYPLMQIKpk0KKgd9
#y3zP6M/MANsL2OBr1ZCkAuR+/J23F8Jjvb6ufETYWFLSHWE6qTmatANFdiYBI5X3J53TX/xs+paD/Av6i5xNpVKXItgsq5DDACzycp7/Of25jz7YS8a0qPib
#VzPi6HQh79qLuPgX13h5y27JCQfvxiX2peaac0W4RpyTGWp8mUxkGPS8lh3jYz/fOkbvPPsErHpccDRhteQkJykJ4Js/PDgjuRJfr1ctZ99CimC4EU324JNm
#LuFcKVmfzKDsP2b83XMJyfSkIc30UvZAgu+gMFBvlNL9Th93Q04gP5h7M9Mn4pLLdSnikyep392yrGPm6TtI9okyruM/NP/7LuIK8NzP61slbkqdOy9TYpYU
#MBAVrSh/zSpmU0qmJSMsFt7IVGWDTp4L/3DYmgKelmUpsgq02oJS+ouqiRH+7sfNuJT+/dP1TC2zil2l0NqZ6MRgFbtz3eMS9ezjTsbY1s9jeVSRzKALeRN8
#4A7OcBOp1aJcc27q6oS4XOSlFGpx6CukM0Izrt6Mj5zxDUN5bwtgfyLnbuAS9Rv6nOLbw7GJNVTsMUbSXI1elJFsrwKnJtx9nzN28Ev6Bry2/brNtCP6JHwy
#f3Lj8YSET4d7J2nfZT8eCJgrsozpGURWFpGRbgS5S9pWewOrQezG/P0fpG7iMFQCyHC5xFeFZH4lTCb5Y74+rjMAIMt/jCzDDCAA5mLj+sMAJcz5fn2Qw9qO
#IGYKV0m239T+7jMdwNWdUoZvjWd1oDBlI3URUU63eAhvkTdWjRd//ptHbbKW9js7ZTkA0/VzBhQR5Vxaivf3AD5fBxrwtvTpYdg0peh3U0P2WBGctyhbmG70
#WEsi3pbZmPY8HI3Z7I/t/F/MtD9mucY/LFPueTiaUAfDThCzgIzoaypw13Ow0UTRRMqxEJI1HAgjp6CMfsvprKchhHayxMfohs3+De1x0d7NREA5nXqd0jlS
#mrXgM+h5LNnbLU+Gh7ZJ0Bx41O5ZCsVUuv0oRf0h5OqglOE7zq4AcydpwnqkuH8JqnBuB8fHxQLSAAzILbWwgRAAoC3ANYTXbjzVxsPvBIZG0RH78YjnEPFy
#CP0ZBFtadGGrl1HHPFWiIK6gS0S4P5drltPm7mueb3WQv33zB5SB4ISJK91jek8kd00GHCmC3porMAEOd55JdI6LjVAYY0gX9zagjclhuRjAoMLKtCiRMvcJ
#T9XkSFuAWO0Q4rWcEjnQVS+TVaIFuxq7Br656xsRnLs55+iIM5gs4NzPRpSFHEgdZIpaMYrr3dXBELfJL5w9Ab2CoKFqybmYSDh+CLkShnNlAk6mQSO96vL/
#d+ehMg4hASAWyv1P5Vvo4HVrLXNERZdvvEhD9SmWWmkV7sCr5EMO4CrckHP4Dd5EVpGL5P+0tIgSAbGc7qHXaIv26A90xLylEKmulCl1SXvYafaO+yhaKNoq
#AorXFUP8EL/K/+Pg5XKyQa6Tu+RB56Rz6BKV/yg7K1e4m92jbtXtuddeLZVF1azqVC33zngDL5pjAK94A3/j3g0pDt6QJkeBv/Mdh/yL7/mB//Fec7iPcYu4
#L3E/09d6pN9pTRnVDfiss/TZ+7MG/8q/9m/t8TOvOujfO+rvA0IzEB6CIQrEh34Zc76JPYn8MaNM++FcoLf73b2P994/D/7m80nPP985wm0CncAn/Dx/nZez
#LX+bn779LyuX/5aPciePSN/i3Prq1reUo0u64gXE1/Ll7d/IY4lISWrSlI68VwsvwjxYq99oRv+qLZ3Y2Dsq05nFnti67dqxvXNO+hGJTeKRFG51u/v9pf/B
#/+T/8BP/r08K3n1w93k5Kf/lNbcZ2zLUC9T9nb/TsW0X3YgeRW+jD7tf6/6we0LP0ctbsR1Ns7THtB/0P5K7JPdE7sP+K9vD+mP6n7bPbq9u7+4M7XP7GSNz
#AeURMGADACnq7KL/KRsuPkEsgT3KJZWBEAB5lv/Xk3+94HNwpJHpbEQYoEiQvg9KCEOyeYZKHerYN3MYy7TOhD38mOKDE0Icy9jhC0dzhir1go/S9sajVbWB
#jZRGG6vyyk8IRV9OEHubWDI/D3jkyfjksmXxg4zMHLGELzJfKz0m/y97osl6jCpSrYEmhKuq7eNgW5VMKcRqHF1JycZeKlNcqX0EPZC28noOgfALnCMBeT5K
#eu6UI1pbOfEaPpJKMZaTY8OUI6fE7K/W/w+eSGXTZppmkxMSVo8WbUngM594a2GbZUBR8IdydffY08d2P4DbGJRzdhxCRBuIfuzP4M9v3BHNtAEgRmTwY8Ej
#TVDWEec5DtGIs9bRh82mwfwaMLAk5w72an83v1NbbYG/xbE/KTCDAyAKIfx2PmGShBA7bfQCfYQfUUjGdoUBnn/EeGjC1Wq6Zw8YOpsYRmphGeSPIyn4DAk6
#HOFJfPiWvb9lSXZyd1e9OMRJnBrIRJFeJ4tzJx3gfpJrldmZ7l/xQLB5Mc3/98Lxk3Bw0Ywf4mMevEjnBGRg6WLcgbXbsukkCNRCdNzQxFuSHJpvGrkhlc1Z
#EhFGk4iHj9eQEJ2o7Y9j7ZrbRJBb7tkr7bYbK0eHPIDpBe4amlzTDSZq/bBqQM9H5iBbAwujgxQVU+6/xi1ov7CHdOLB7bMpzvXYxE0TaZ7wXGi/rXwYagmq
#mk8rbRpIswra/b4ZBVBCdAf+z7rNP6+0B1DMJ6Rkcenm6YgxPA8AA5UhlGUVJXe4w7SxP5JR1smEAw55CSeWJ1c4CDwl+9+W5jsIeZ6OE3AT40mYzDwh9ppw
#NTh7S27UxYFbWwY1ya6UduwaoZQd1xRSrE8XYZOUyvtCOrAkHvpV/KsYvJxPc9GQzJxImXs3Jgk4Gyqe2m/hNAMoXPZxEFQF9gI9yzsUVzTklHZIwbPnX3d1
#hdw9mAtXnjRBsDZitBcJY2Q5H5oJ9ILd+mpKH0yMtZs/C7SSQr5zzmjZKY+e0wn+3A+Rh3eet/qt/L9UCtoPv4158+W4x2C3KN97yob/jKrGAKf3y+bRKf5B
#uzfWa48GgIrfVCulSqWABvnLuoGIX1kfAeG+eD+NcT1ZhH5FkyXmr7ihc9HXQYIEHzj71y//0sj8E78Ef/yIIp/sbj7JGymWCv6aUUIRt+aGM7txlDeBvTdD
#aHpHO9EQF45u2JUP9JTn+1qp13vIiVUUQMqL2XWfYCRXWGECjQyj1hfPynu2OadVtOYjc27cRnDHXkAScCY8BqHQjuJaSYI4dN4x2Uy44Q2QCKOjfnBucTAO
#DIRqI7Ctfv14bzhp42Gm7WyZ2c5pFPEtWWGl5yWZhZ5o5C0mkF6fpjkko6AGwprA81vajF0exTNexoc2HP8w+CSQmSAbxRjZCsRxGtJEDIBEGDbhqgPjqbIw
#wmQPgeBwns45bj1NBwEX0wcDnckFNu2KLGjiThNki4VQigzXWOFCrNBaxxTC4vigNFFHyFsZkwD+ds4xuEBdiWfHxyQbmAeyAuOWe2OqqC7cXTZjOPxfRzQH
#VyHsS7KEg9pfsDP4p82hbZE5bQwQpk/vQVipuBZpGdOPAfhqFKOPc7gnBvHrdZW+0jmu1TUZyqzVlJzRy5k4pxkRl9m0bOxCemj7MRJLcdy5Jp6RhQ206YHv
#2VqlXIqtg2Vbz/wO9ACAkp+HBGBLrKMdekQ+0vcFC8TzD38PDv/rcwbn2TFYCJE6a/T9ta78dxAF4ValZymJ9S3gJF9Vs7uDgUwCXdj3f1dg6Av1LhVxwvWD
#TVaUFFgXBFkS+HAz2ZNgFiKQmYDbcIEMAjXnN/qRgth23cQsjHZVOE0U93EXCZ1Ery4Th9JdNmV5h4fPWkmCV+iAS2b8kIpx4AmckBgYnI5bIO8sgGTYTH5y
#XmGSKHGuuZeg5o2GwRRSRbZKgWc0FJZNJC7qZFSNcdKU/LBp2/hY2DkZT83VwpgGnmBojIlQJeTxOYlwZfkEnhdqghCklocTLh+wBuGWpnRPADKFyzwms2IV
#xBja/bhjecVlIsKz5obidznT9lwKJocfAhMCEOGxjguMyaAchwDuc58Rmm22keZZNZ4NERxmcLNdrft5q5A71jdng4sIJmFb4F5cnZthJo6IEOZft2yarpyp
#OfA04cRSVSF3v5pP2DXZ5n00kweiHDcCIug8CVJ9pBxRxGIGuN+LVFHa+R1DCtmuHcplVCoL2QvwOOfJVlwAxmEbzARDDqjd6YWUpUlMH8KzbdvmPnHRuePa
#cc5BQ2gZ6qIUFWU45W6R3IwaE2JntDuYNgi8td6Jqq8bitzadXcNPNwrCp3aDXct5v+++7lVGZbZnoqGAtXndoesWkL+tW6o/6OoJKPgHiEkdH+80+qMn0Po
#Fy1V2Vu2WgLDGt/qw71Vv7UMXDHY8QMpv9ffJCWdc+56ZJnd2XF0aabPg/R9fwb/fuOO9Pg+OgqMLuStSunfHmBuBo4Dd9HlnVbeja8JZ7ejXEcQLsej0N2k
#tVIoKBFXu0W9xkqEtHCs2dWJkynusroLxh/76c001QBkySi6gqY5VxrcI35oe960gn3grQhCgX9FEIiP33TBcnh+xU/ewdiuYjGZ2Mz0DANc1HV41rgT86VS
#Np6J6O4529G/ncWmEmMdTEm+eCGn4rWqBDPU3KITNv2PO0Y2mwu39yE0jke1OeUQajxBaEbdifhIll8KotVsNoAreoyjxl2UtXiYa5FXNONgyJpSN1XTckwz
#h9bhXBLSNsZ+K5ij+az+d2mxmMJCgZEUhNZM0Zz0JwH7qSlCuf5QGGEkCgeqOpydPslARUeK/DgG3VT+A/qxTmo7F1jbWpVl1SBVjdk4IPICyD9V6TZTYM2d
#T87Pr64Y+OO3AbxY8AtzXWJQg+MpDDjQ2g2KzO1YD6Rh8SIoW7/juiGIgNg0g86EmLN2FUhYwFwvCJigc5Wr8heN1xzGEs49BrXX8iJd2rBcpLPcWpsP09kc
#l0c8Y9WI1qVrjzQ0TThzGrGWzvEBVqXu5LmMomQE58U9DWXgOhbqqTfs37LUCbWAeyyzoqg7lNLNeGAbbY+QCST9LXavkVfjnlyXUmwejKH5vCDMTsG9nFe0
#m2NpifHj9hWYWM/43Hd2dR0hFAgaTSEo6bMB0uiw6GCibbCSgqbN6J6QHs6p+WSF3TK7qU7KItRmwmdVCLJMBDRpsvX4E+h6bXrLSBRCGKGUSL8khpObMxWh
#772+toGpyMQPRCCcKl2otWSAyZrR88sFxKagNMAl5tFMHZgMBOB3w5JJkAuR7s7rkFMfkjgPyBDRiIymoZXzrWIggQDcTmcCkkESKoq6VcQksG6JjJyXGxgz
#WeB8g80UHpMKUwmWis7KaaePMJrQmGh4yS0lmBqPrEL7rJM4TlUkQc8I4JTB4LW++F6hAkq15rosb2kqFYTxQrHEZT2bYOYkg2ImUAnRhrwd8OmxbbaME7nU
#BocwX/ZRIrWOQuUU5ytDDhreqmIhjZuo9EgAUcrV9r5DQ7/QESaIzVdQMErElHQVeGekeMQDKy1ASvcvbJCW5O3BYf7KfL2t+roubzTYwDmJbN00en6LZO1a
#5R1GWbiNN+eqRYVhjr9ZLEuDuVhMKYImTNrLxZlhaW0dFnk5WrWwlGDM6dl+kN5nS3HGvR62pNlRXlS1cqE1Wlxhm/q4eklvsjn2ew87upXOxhjbN5fkTRWQ
#bQlCfqOEUKWvy6wQL0QxQevoAAcIInDBHNcGww0DJ9sSteI52qHpz/6fvKdCbAtkuQqWwy0Yzns+EHmw4ikxt46fcJbp+8yjFppKw08eswMQtqvnnU+gF4Lw
#tegL6CPFF7aMDEHu1fOqQgibskeHoKsmTSWAm4uTRYTkviQl1gh3dYSlTEyyIGWpwsitO34XUi5JZmPHdUNNANkJk0Pb1XHtlzmW171tK6Lo5ZsTaA3xFgmB
#EQcVQ+7tVRDNAw19o6swtpOs3v6NksekZi+5N/MSi2jtSufZPMMOMu3O7bpBTpymxV3esXhZcrLsAXbaF81hfh9MsVnqkFuyH0T7P5fBFx4lYgafzJG4NFSb
#OhH5tM+l6WfATwL8BKKxSirA/VERGbnP/3cjySbrjim8fQK5nMm9VaXh/TdctMD5iYfvh1+KSwPgZDbB+LFpjDNR5CzgkusEjcvoBJDeZI7rQsAP0/1uhW7/
#5ucnT538XX31+KkzZaUEQSywxchpBATpRRUE0SysBqjcL08f9Ed/9eSZc2MQPk1HKmnvDn1/275929Y/+gtbd+y68Tet6yuu37t778a5h07iHy/cz6EHtplT
#lR+Qq/4FjPSV02QZ+WwbI6sTQbRDKcyCZ9Z+fPvw+/bd3V/B/MP5aQlKepcpgYsrhrler2Ot3YZQkjWrAiokyajW1bpcTaRc4z+4WDbBtkq5jqwgo8KYjIXJ
#XpxiFQkPbjemcy2a0BtdUEzA+UsIZVyC1suYKohcG/tNoEV3Z2X0w/u91pRvsd+JJQfWwx9gfn/f0puNRtccJSzgnxAY3hY/wP2fH7S1kknmUAo3Wic7+oay
#aKgj86X31+9k1jFjQ+ZjwEv7P89/1zgd+N/vQfxjRDfjiIykP9NjjPZTX4jedK8HSesI9O2RYp/QsIZPu+QYX1eL7VL5Oi4mWe01pkFYboI6VdDlzcg1hAF1
#OAxlbIdhmQ8NCRaCxBiafjhOk7PD3SiDCJr4fFmeZtRQLkcxZa29romhLjIZX0hTEB2z6Mw/ryEsyvh4HiqSm4f/DAUJyg7i9VB3KwZY5Z7SImmcQNkdzy4Y
#NEsMcfmthjeSD2hpeod40f7EBjUCITiL41hZf9g58Nx1wXBENTzpSoAMNk1u6cBI7qI03yb9mTCrUkuCjETQouCMC+b4wFInSSST9lCWMvBImv1kIeC+XaKP
#eJtRUEB/yrMjmqaFKWk9lBg22Zg3FyXdCtWl1FrtjoNuXSP315npXCMqeuffcEMcvuuuDPcC6OsD2GRk6tOugy/gRu7z7QQyQsl5I3xduG/Xiy0rldCRBKfS
#554PMeHgfbXqB0cb7PB2d1W3rWr1nPzgyWjiYCAjgAvwRYJsDcruO9PT4a4jtwA+tWpOjCuXX8R1j55ECnICxmbxk2QFnjlT5aX0wrtiZ1QMdRQTKPurZeAT
#N2heItILRak2fJMoxJYtrpt0vE6LST6/f44tgFeSflEHTPoQdyYhac7JS4251VWZjNktR9zwm/wIJG1pgfMHT//zNN/syVsQU0G6WGoW87sZ4FmiDV30jcVj
#Tmmx5sflXLl2f88PIrd3q0ZAiKFIphIDjmbwdoIEJFFzUZcRos8uhpZtakteE7rLemiTDsJOWUOUPgcBjZLzm8GIkqNKzQX1XhI451gOqy5mugHz0obSEgG2
#tVgdeRDDIOYuLgMqB/jSGjlh5xTYUxIDkfM6Oa8b3ZAWA6AeUAnCP35/zLWcMVS5Y3aHwWfsuJumA4oXNq1dD3zWHaWEZWa0VIzhXSCw5d9lfPAdY9HYYmBF
#GaEBGYoD4JAxuHaDozdZ8dSZ3ThQergiMVY96ajSFCuWiejwnKOO1EkP1QWeW/cCbPlfshLmwbYVumv69zAv8+EFHlW70O5OkwnGxe+uuZH4GWuCKMkG1t6j
#cktXUHkiuYPgNtUjaM/ufy/Xo3CPNVC27ovIW+c80C/ZSikWM3g4H/Qv1b4h18opnxTiYW16eBBBTOAEtiQ9OndTE/TpQqivGsuqXeNHrhuk9TAmzxyAn/QO
#plHwRPV8z5v2UdZJzdInqaqK2aryn1Ud0peoahKsmjZmzv7y+1iaheiZ+JhCT4jDbufIZ6qzwbFdzhaL21+luiesSt6q5zhR68/urbfRNUYtRL7C/+SX5PIx
#e0gPMvTByYjFAczW6bK0Gb2x07XmpojppLay72UVngjl/y9yX9A+s05sJ4bu7NNHAPewqfWXSrvXqZWdp00SO/S3AAyTeZWPNwqWW2sCq5rmT8d1Q/wVOwzg
#fGMQiYsLThB4nBtCst0jBVurVaE1spY3Y1PROqfADJBQRzPW0lFAxQMrpv1egAayI+Ex/FdYNQZj/D5S8Qp7hzRbyYX7ahZCygij0QzjpW4cvonGI5HPc14R
#Dm2e5jnPU71SKukB8Qi6gVFkCoBUkYWiAvlZXHTi9yKoMANvFv2MYjgyC1YFrj0wZ8k8yWoKDgxFU04nZXgQgB9hIp5YH4+7EEQPk0sohRBiL3qYcIILTizn
#BIzyqzmqgSax2OMQtADDu8IiG1kGwsw9kYMIN5QNHs8rnuswgHht93giDyPVdN113wioOT4uX29v8YsKP3hgPJ8qo8Dg4AoJJu0P5nH2X011uKziJLTGRr91
#z7+7Bg+lPv9cAJWyHeC/kNlRJdW6r+gru9QFFB/P2/t15r/aw0cf2txMrBYf9FQ7cIeL5/SL5zUvt9FQvWQ2OV5GnA1Gnq7DXZHtV9qjo1zQxX4Njp7D74IX
#X05de6SKyg76ObmGgt0MDxl5G8yW5PLw2ad7XYeQz8vY/yJMr7yIRuCl2WY6rr9msdrnSKGyd8/QOF4zg60H695gUwVSRoZTrLXbcae17Qy3R9jlvIuMQ6ET
#+QPqQM3AFtUhkrp0Q1kJ9hS7vVdq8JzqHxgcodERQ/nMgwyV+VaUOQnALdUIeaI1k0T9SpjOkYLODel0nqjj2+B7WRH/oahrK+NDlMNn5YjcVvVvqchLP7e+
#rSkYkRUxxKf3APx4y+v2ExxYDyNUrU7KUBRl9VWy1qxPg4kFjxKbub/CSoS0dDGZhLh+NnIQwSYNJ/IzuJ7aX+4sfgFC3z8l8BwnSC+QEVyr8ZQRwCgeL4AW
#c8LWv7oyfjXP/4uQLwjfiGZ37945XDSeIAVmnf0xxwFEf/NLbE32xj7KwU8MbNl5rgUJjsMqQmb2HGcZIERP29UX22gWN1tdoddpcsZI66EdBZ0YPP1vf7LM
#WeCT4BbDB+cAqq6NkbonJhU3PMnYi3qpNNB7mS+kc4FWnuGCMOIz47WPcsB8Wy/GqCz5LMZKTHDKtaDomrUgIzEGSCsxjUnPAngpMEQDj83A1c0ZUI8ky1Rh
#TeACkNpMa43gMaSIviLUcwn0mdo2RfuAzhnN9oHckGjOsMBfT4LnCFfU2T0XhyiHNArIzM86mC98Stkw6/R1M7Jz8AUQ9S5HitQBleDCNZxkR5YEKYByif7u
#V3+0Mg0JZtFvenzf23Fce7ptss4heM/F3Ld2ELQ22vHJkyfWx4/b3Kjp6CszzY3L23mboeFv/+yu+YWTm4eP9f19P6YHYDCjzCQio1DsvcpQttbhDcbOiYaN
#rjzuQggefWeZQ68b5B+H++Nvbj188PD2xferywl6sUo8NcmAtBEZCjp/xm7Y7GMdo074Ov3Sqd5xZuzrJch8QyMJ9E2h3PazgvkTC+Io35Kkdv7oRz59NIII
#Q2jtX4GihIeJLwpg5LSk0sPXWS+xb9zr1wzFxtu9lpsCq3qKBpMGwMzhKVGa337hPjVdiCixqjKiTFnA1+vkQmn+Nu8aOr+8IJN8ZCCi0PUTDcAPU8yi2bN3
#3FFNDtBvVFeZ+aRUOwYmkIZIZgolEZivEJb/gM2KMtPtA0AF++dSktXkN2bYirsIHORQvDjRXD3OjH7xKxVsqSAlZvD+ld3qGz91mkTsLyD1mQ7/gev1YboK
#1yhxlf72fa5W14hgOddgdN9qP2UA5gqYEjcCUgifHThfunVbl72izK7dVQg7Jg2CqiqmCslTD5ujCJFgI7eWKLmQRupEri/MJyLTkAWw2p+kTDFRs55QX/Tc
#ivpbHBnAt75TzluZr99J87TeofoplM2N13d8a7k4ozpQy+d5ip3/lmpyjxOE2BQ4YTe0T9BUFVdBbX2f/Pgv3MwS4gVQ8YL1toV8rhUMe1oNoZ/rajhHHfTq
#f6i1AsYerBiQbCA+X/QC/aQb9BPp4msxNc9ldfRbkNWmptepY2dRNeA4L2gSvDfQKl13aLaPEvS9Xi6rucUCyD/NcFgzKj+HDWd2zfyl3DMHYQjODLlBzfzP
#2Z9lLfo4U9Ck6BSmyFRjztn1Wq0jjTq03XoyNR+5uVkbD9cKIJ+shIEoopL3xYOl1y0VhttjyUzoSHz3WTWfZ6tUO6lg7awVGg+K2UlfxHzs7GOz8G8IWpC/
#E5pEDTQvwmjSpnx9ulk/AROfNSqlmn1Orczo9AepOtXmH7AAv8EPxnLusRots42D2IE7Ua/aNqChvwBuKEzU9SSrgReHWeFMN2hF3iGnrX2Z5fhxVuLTkoKu
#F8654LAnygZVY/Q0J5Tzx7aEufwd2CwTUPT23tP86lwfzn/tElJi1iHcVkz3kYmN6+bxy95O5x+9rEHzd5f19AoEFLx1xRYhco2//PtztYRvbL/QQucQ8vn8
#T+jJ06TC/kL8Rurf/vjPWW8OU1D+97yXBCcnbIs9PaJ6Xc/yuj2isLYG5en1CEGlKHqTCi1YM058dz0ck+yt5rD8R/WXLF02Qkoy8Bz6IQiO1XMtjYXVi+5Q
#DPozRdovFckaP7R+QDz53ipq+vZmq1aqVoqOAYEPW9k8nU10BXabLAnJDUUohb2rA8/wZEu2oYqL1da5l11rNILFuXLwLO1mIpYbBFptST4iCenEmmKqP3Pm
#CMzGmvJemjEEBjYgCwi+6DIx4XhBq5fNYZDtnoSV6wpMu1iRVV0sWJOlLoeag0m5NVYk6X53a0DaUuP5RbZtBnXtJOv2jQKOmLvL2vR6ZAT/cV/8VrvTHT33
#Qse+8JxxYlpbG/YKroNxftgNKQrSkCxKsgSE60g4Z9gE84mO3A/mVKRqam2pDFrkZLs2IyNsWVjH+j3opuNX6o3GkF5FckRt34BCxgHCRdotgxxJKqUkYj1B
#NHYYZVVbHzQMpwkfGciyAOdHkoqSPW8LrbqJzHpruZHGxNv5G2n+YkJiO5886G/UVRkEaljFWzY4WgENccm8UwoMmqmRCcU0+ucALj5nOKuLnMu5z0od8Nys
#AUduaLoxz9BViHucPJEIqcagfPsqrstZzKQvzFGs/7ML+Nxa+dzY1Yjj+mItlLIrqxpSCVgozMqisHG2Y8YNxqh3TWu7VcAsWmvwmvm6lp6kDpyMs+kNMXU+
#inRaxDrRqtfxTNoj8ZwbSdcEzxqQveVXf7x87e6zEtsUFTyw5rkmXEcxsK5jlSV5+F9tMY9VWRRAKBxYT0eQa96yd7VimbeGlasVGoScXz4xDb170eTjLHOM
#8JbSU3Aqh2jHFo9ObOAFl4VpWdF0u1CqkrAP2kHY9Rw9KyQ5Qwib23FugsV546vAbr5YFIZxsi2SCd97QRNq+FpzRgTWZBceEcFacjLPlCNOCqXMNyvapOu7
#0wIYbHfnnYePi5PT/Nn5ValWbzbrd/WGDnrX6AhSvy/JSFE00/5VlUVlJ58kHMBLKbmKZTqbfBqYe/o57IlhsE6rw/OdOlu9rd/XKpXyzeXp//chentyt538
#w8T+3WhB4+Tjumskr+BOtU5D27bIQlI1yfrUii/60Bvr+vjTDNI4xdlXiwBjfHrt5rpQuKlNj209ML/33+PfqmCV4jsNDBz67g3ef7G7TX8K5jib4JEDrJeq
#jVr9Dif5oRLiNQDg3v3Pl+6u9F6x/zxvy7OKhwAgo9yol83/iV+UigM35RwhnfWeeP0McgR7Y8NKLV4csoJPhc9pp+yanCsImiEfNsnkQsMslGuzkTywPluA
#g4xrbFq182mBvOZ/gHbNLgVBIzzHLOWXIVSGSeGuDiSOIOGBlpeMiqaefgp4SsVgjF23186nbGENECDJ0tJP81SDc+xXd+vccd8ddndnuMv15bB9cHdQckfZ
#vvTHaTOTu7ldc+esvbN3MYYMu+LOM8lpjG2omdtMtWKlnXDX7+Qo0AKTYynuWJZdCpdZztmbg2POAbtQcvTL3+psl1wVr29idfwlOCqw52cAowHFNzY3JZAY
#CuHbq7PrxlYMj0Xhi6val+yZO1ef/p758M95c5pg02bHMuu79RV7sQWdrW4U05lvcmwjhym6lOfqH5p0cvZcc/E/66iZu/8TVfHxyXZb7M5B6e9IXoay7h2c
#3lx6tXm2WCZ0dW1ZWj/i+tubWtY/tuTkeqN6H3HawgpvBMALADtxL//wB0cACcyhwnZyk8gIsIzaw3kxSV4A9sNjkhBi/yTDH7cnBZp6OSmhZlSYVKB0JDxD
#RvXo+sUI8KW5LdISCVK8G/p/UoaK1k4qoY6tkz7QxfFJX9SL35N+qF2qT/qjYbFOBsCXZw8eCG/Ohygtgrq18anXoEOmlHBntJIOmKfFXJkO2Aeaa2aatcvE
#a/mGlkyitmj+n3XPq5kInaU1nHrbLL3qkji14CMjUmdlu/BN4idFtyId5k0EsAIaljRy/XkVacT7iXqdmopt2GpvrW6KTcTALodLrlb4mvN1282DKnG9um+q
#JTNypaKIhe6DVv7SvLPYKQAbWpOSygIdS9DC4bI6sama62Ub0Pz8+ujmtYL1NFqHpk3GpalaPbNS0/HjN83TKTaAAAA=
#__END_FONT_MONO__

#__BEGIN_DOMAINS__
#3docean.net
#accounts.google.com
#acm.org
#activision.com
#adobe.com
#adobelogin.com
#ads.google.com
#adservice.google.com
#ai.google
#aistudio.google.com
#aka.ms
#algolia.com
#algolia.net
#altera.com
#amd.com
#amp.dev
#analytics.google.com
#android.com
#ant.design
#anthropic.com
#anydesk.com
#apache.org
#apexlegends.com
#apis.google.com
#appengine.google.com
#apple.com
#apps.admob.com
#appspot.com
#arcgis.com
#archive.ubuntu.com
#arduino.cc
#arxiv.org
#asana.com
#atlassian.com
#atlassian.net
#aws.amazon.com
#b4x.com
#baeldung.com
#battle.net
#battlecode.org
#battlefield.com
#beans.org
#bethesda.net
#bintray.com
#bioware.com
#bit.dev
#bitbucket.org
#bitsrc.io
#bitvise.com
#blizzard.com
#bluemix.net
#books.google.com
#bootstrapcdn.com
#bootswatch.com
#branch.io
#bugsnag.com
#bun.sh
#business.google.com
#c9.io
#caddy.com
#caddyserver.com
#callofduty.com
#canva.com
#centos.org
#chatgpt.com
#chocolatey.org
#cisco.com
#clamav.net
#classroom.google.com
#claude.ai
#clients.google.com
#clients2.google.com
#clients6.google.com
#cljdoc.org
#cloud.google.com
#cloudera.com
#cloudflare.com
#cloudfront.net
#cocalc.com
#code.google.com
#code.visualstudio.com
#codecanyon.net
#codecov.io
#codeium.com
#codesandbox.io
#codex.cs.yale.edu
#coinbase.com
#colab.research.google.com
#count.ly
#coursehero.com
#coursera-apps.org
#coursera.com
#coursera.org
#cp.maxcdn.com
#crashlytics.com
#crates.io
#criteriongames.com
#csb.app
#curd.io
#cursor.com
#cursor.sh
#dartlang.org
#datacamp.com
#deepmind.google
#deepseek.com
#dell.com
#demandbase.com
#deno.land
#design.google.com
#developer.chrome.com
#developer.google.com
#developer.samsung.com
#developers.google.com
#dice.se
#digikey.com
#digitalocean.com
#discord.com
#discord.gg
#discordapp.com
#discordapp.net
#dl-ssl.google.com
#dl.google.com
#dns.google.com
#docker.com
#docker.io
#docs.datastax.com
#domains.google.com
#dotnet.microsoft.com
#doubleclick.net
#doubleclickbygoogle.com
#download.01.org
#download.virtualbox.org
#ea.com
#eaaccess.com
#eaassets-a.akamaihd.net
#eacdn.com
#eamobile.com
#eaplay.com
#easports.com
#edgesuite.net
#edx.org
#elastic.co
#element14.com
#en25.com
#enterprisedb.com
#envato-static.com
#envato.com
#epicgames.com
#es.io
#eslint.org
#espressif.com
#events.google.com
#explainshell.com
#expo.io
#expressjs.com
#fabric.io
#faceit.com
#fbsbx.com
#fcmobile.com
#fiber.google.com
#figma.com
#firebase.com
#firebase.google.com
#flurry.com
#flutter.dev
#flutter.io
#fluttercrashcourse.com
#flutterlearn.com
#fly.io
#fodev.org
#forums.cpanel.net
#freecodecamp.org
#frostbite.com
#fsdn.com
#gallery.io
#gallerycdn.vsassets.io
#gamepass.com
#garena.com
#gcr.io
#geforce.com
#gemini.google.com
#getbootstrap.com
#getcaddy.com
#ghcr.io
#github.com
#githubapp.com
#githubassets.com
#githubusercontent.com
#gitkraken.com
#gitlab-static.net
#gitlab.com
#gitlab.io
#gitpod.io
#go.dev
#goanimate.com
#godbolt.org
#godoc.org
#gog.com
#golang.org
#google-analytics.com
#google.ai
#googleadservices.com
#googleapis.com
#googleblog.com
#googlesource.com
#googletagmanager.com
#googletagservices.com
#googleusercontent.com
#gopkg.in
#grabcad.com
#gradle.org
#grafana.com
#graphicriver.net
#graphql.org
#gravatar.com
#groq.com
#gstatic.com
#hackerrank.com
#hashicorp.com
#helm.sh
#heroku.com
#hetzner.com
#hf.co
#hoyoverse.com
#huggingface.co
#humblebundle.com
#hyper.is
#i.stack.imgur.com
#i18next.com
#ibm.com
#ieee.org
#incredibuild.com
#intel.com
#invis.io
#issuetracker.google.com
#itch.io
#jaspersoft.com
#java.com
#javacardos.com
#jenkins-ci.org
#jenkins.org
#jenkov.com
#jetbrains.com
#jfrog.io
#jfrog.org
#jhipster.tech
#jitpack.io
#jitsi.org
#jungle.net
#justpaste.it
#jwplayer.com
#k8s.io
#kaggle.com
#kaggle.net
#kaggleusercontent.com
#khanacademy.org
#krafton.com
#kubernetes.io
#labix.org
#labs.google
#laravel.com
#launchpad.net
#leagueoflegends.com
#learn.microsoft.com
#lenovo.com
#libraries.io
#lightstep.com
#linear.app
#linode.com
#livefyre.com
#maas.io
#mailgun.com
#marketingplantform.google.com
#marketplace.visualstudio.com
#material.io
#mathworks.com
#maven.google.com
#maven.org
#maxis.com
#mbed.com
#medium.com
#metasploit.com
#microchip.com
#mihoyo.com
#minecraft.net
#minecraftservices.com
#miro.com
#mistral.ai
#mit.edu
#mojang.com
#mongodb.com
#mongodb.org
#mp.microsoft.com
#mybridge.co
#myfonts.net
#mysql.com
#nativescript.org
#needforspeed.com
#netflix.com
#netlify.app
#netlify.com
#newrelic.com
#nextjs.org
#nflxext.com
#nflximg.net
#nflxvideo.net
#nginx.com
#ni.com
#nintendo.com
#nintendo.net
#nirsoft.net
#nodejs.org
#notebooklm.google.com
#notion.so
#npmjs.com
#npmjs.org
#nuget.org
#nvidia.com
#oaistatic.com
#oaiusercontent.com
#ollama.com
#openai.com
#openrouter.ai
#optimize.google.com
#optimizely.com
#oracle.com
#origin.com
#overleaf.com
#packagesource.com
#packagist.org
#packtpub.com
#parsely.com
#payments.google.com
#paypal.com
#paypalobjects.com
#perplexity.ai
#photodune.net
#php.net
#piles.overleaf.com
#pkg.go.dev
#play.google.com
#playstation.com
#playstation.net
#pnpm.io
#polymer-project.org
#popcap.com
#postman.com
#proandroiddev.com
#pscdn.co
#pubg.com
#pypi.org
#python.org
#qt.io
#qualcomm.com
#quay.io
#railway.app
#rapid7.com
#raspberrypi.com
#rbxcdn.com
#reactjs.org
#realm.io
#registry.k8s.io
#releases.hashicorp.com
#render.com
#replit.com
#researchgate.net
#respawn.com
#riotgames.com
#roblox.com
#rockstargames.com
#ruby-doc.org
#rubygems.org
#rust-lang.org
#salesforce.com
#scdn.co
#schema.org
#sciencedirect.com
#seleniumhq.org
#sendgrid.com
#sentry.io
#serialport.io
#serverfault.com
#slack-edge.com
#slack.com
#socket.io
#softlayer.com
#softonic.com
#sonarsource.com
#sonatype.org
#sonyentertainmentnetwork.com
#sparkjava.com
#spiceworks.com
#splunk.com
#spotify.com
#spring.io
#springer.com
#sstatic.net
#st.com
#stackexchange.com
#stackoverflow.com
#steamcommunity.com
#steamcontent.com
#steampowered.com
#steamstatic.com
#storage.googleapis.com
#stripe.com
#sun.com
#supabase.com
#supercell.com
#superuser.com
#surveys.google.com
#swaggerhub.com
#swift.org
#swtor.com
#symfony.com
#tagmanager.google.com
#take2games.com
#teamtreehouse.com
#teamviewer.com
#telerik.com
#tensorflow.org
#terraform.io
#themeforest.net
#thesims.com
#ti.com
#tinyjpg.com
#tinypng.com
#together.ai
#toggl.com
#traviscistatus.com
#trello.com
#ttvnw.net
#twitch.tv
#ubi.com
#ubisoft.com
#udemy.com
#udemycdn-a.com
#udemycdn.com
#unity.com
#unity3d.com
#unrealengine.com
#unsplash.com
#upwork.com
#vagrantup.com
#valorant.com
#valvesoftware.com
#vercel.app
#vercel.com
#videohive.net
#virtualbox.org
#visualstudio.microsoft.com
#vmcdn.com
#vmware.com
#vscode-cdn.net
#vscode.dev
#vuejs.org
#vuetifyjs.com
#vuforia.com
#web.dev
#wikia.com
#windsurf.com
#withgoogle.com
#wolframalpha.com
#wpastra.com
#x.ai
#xbox.com
#xboxlive.com
#xilinx.com
#yarnpkg.com
#yarnpkg.org
#zeit.co
#zeplin.io
#zoom.us
#__END_DOMAINS__

#__BEGIN_SERVICES__
#{
#  "services": [
#    {
#      "key": "playstation",
#      "label": "PlayStation",
#      "groups": [
#        {
#          "key": "online",
#          "label": "فروشگاه، اکانت و بازی آنلاین",
#          "domains": [
#            "playstation.com",
#            "playstation.net",
#            "pscdn.co",
#            "sonyentertainmentnetwork.com"
#          ]
#        },
#        {
#          "key": "download",
#          "label": "دانلود بازی",
#          "domains": [
#            "gst.prod.dl.playstation.net",
#            "ps5cel.np.dl.playstation.net",
#            "uef.np.dl.playstation.net",
#            "zeus.dl.playstation.net"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "xbox",
#      "label": "Xbox",
#      "groups": [
#        {
#          "key": "online",
#          "label": "فروشگاه، اکانت و بازی آنلاین",
#          "domains": [
#            "edgesuite.net",
#            "gamepass.com",
#            "mp.microsoft.com",
#            "xbox.com",
#            "xboxlive.com"
#          ]
#        },
#        {
#          "key": "download",
#          "label": "دانلود بازی",
#          "domains": [
#            "assets1.xboxlive.com",
#            "dl.delivery.mp.microsoft.com",
#            "dlassets.xboxlive.com",
#            "xvcf1.xboxlive.com",
#            "xvcf2.xboxlive.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "nintendo",
#      "label": "Nintendo",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "nintendo.com",
#            "nintendo.net"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "steam",
#      "label": "Steam",
#      "groups": [
#        {
#          "key": "main",
#          "label": "فروشگاه و انجمن",
#          "domains": [
#            "steamcommunity.com",
#            "steampowered.com",
#            "steamstatic.com",
#            "valvesoftware.com"
#          ]
#        },
#        {
#          "key": "download",
#          "label": "دانلود بازی",
#          "domains": [
#            "steamcontent.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "epic",
#      "label": "Epic Games",
#      "groups": [
#        {
#          "key": "main",
#          "label": "فروشگاه، لانچر و اکانت",
#          "domains": [
#            "epicgames.com",
#            "unrealengine.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "ea",
#      "label": "EA",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "apexlegends.com",
#            "battlefield.com",
#            "bioware.com",
#            "criteriongames.com",
#            "dice.se",
#            "ea.com",
#            "eaaccess.com",
#            "eaassets-a.akamaihd.net",
#            "eacdn.com",
#            "eamobile.com",
#            "eaplay.com",
#            "easports.com",
#            "fcmobile.com",
#            "frostbite.com",
#            "maxis.com",
#            "needforspeed.com",
#            "origin.com",
#            "popcap.com",
#            "respawn.com",
#            "swtor.com",
#            "thesims.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "blizzard",
#      "label": "Blizzard / Activision",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "activision.com",
#            "battle.net",
#            "blizzard.com",
#            "callofduty.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "ubisoft",
#      "label": "Ubisoft",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "ubi.com",
#            "ubisoft.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "riot",
#      "label": "Riot Games",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "leagueoflegends.com",
#            "riotgames.com",
#            "valorant.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "rockstar",
#      "label": "Rockstar",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "rockstargames.com",
#            "take2games.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "bethesda",
#      "label": "Bethesda",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "bethesda.net"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "gog",
#      "label": "GOG / itch.io",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "gog.com",
#            "humblebundle.com",
#            "itch.io"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "roblox",
#      "label": "Roblox",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "rbxcdn.com",
#            "roblox.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "minecraft",
#      "label": "Minecraft",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "minecraft.net",
#            "minecraftservices.com",
#            "mojang.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "othergames",
#      "label": "بازی‌های دیگر",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "battlecode.org",
#            "faceit.com",
#            "garena.com",
#            "hoyoverse.com",
#            "incredibuild.com",
#            "krafton.com",
#            "mihoyo.com",
#            "pubg.com",
#            "supercell.com",
#            "unity.com",
#            "unity3d.com",
#            "vuforia.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "netflix",
#      "label": "Netflix",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "netflix.com",
#            "nflxext.com",
#            "nflximg.net",
#            "nflxvideo.net"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "twitch",
#      "label": "Twitch",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "ttvnw.net",
#            "twitch.tv"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "spotify",
#      "label": "Spotify",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "scdn.co",
#            "spotify.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "openai",
#      "label": "OpenAI / ChatGPT",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "chatgpt.com",
#            "oaistatic.com",
#            "oaiusercontent.com",
#            "openai.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "anthropic",
#      "label": "Claude",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "anthropic.com",
#            "claude.ai"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "otherai",
#      "label": "هوش مصنوعی دیگر",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "codeium.com",
#            "cursor.com",
#            "cursor.sh",
#            "deepmind.google",
#            "deepseek.com",
#            "groq.com",
#            "hf.co",
#            "huggingface.co",
#            "kaggle.com",
#            "kaggle.net",
#            "kaggleusercontent.com",
#            "mistral.ai",
#            "ollama.com",
#            "openrouter.ai",
#            "perplexity.ai",
#            "tensorflow.org",
#            "together.ai",
#            "windsurf.com",
#            "x.ai"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "github",
#      "label": "GitHub",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "github.com",
#            "githubapp.com",
#            "githubassets.com",
#            "githubusercontent.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "gitlab",
#      "label": "GitLab / Bitbucket",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "bitbucket.org",
#            "gitkraken.com",
#            "gitlab-static.net",
#            "gitlab.com",
#            "gitlab.io",
#            "gitpod.io"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "docker",
#      "label": "Docker / Kubernetes",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "docker.com",
#            "docker.io",
#            "gcr.io",
#            "ghcr.io",
#            "helm.sh",
#            "k8s.io",
#            "kubernetes.io",
#            "quay.io",
#            "registry.k8s.io"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "packages",
#      "label": "مخازن پکیج",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "archive.ubuntu.com",
#            "bintray.com",
#            "centos.org",
#            "chocolatey.org",
#            "crates.io",
#            "fsdn.com",
#            "go.dev",
#            "godoc.org",
#            "golang.org",
#            "gopkg.in",
#            "gradle.org",
#            "jfrog.io",
#            "jfrog.org",
#            "jitpack.io",
#            "labix.org",
#            "launchpad.net",
#            "libraries.io",
#            "maas.io",
#            "maven.google.com",
#            "maven.org",
#            "npmjs.com",
#            "npmjs.org",
#            "nuget.org",
#            "packagesource.com",
#            "packagist.org",
#            "pkg.go.dev",
#            "pnpm.io",
#            "pypi.org",
#            "rubygems.org",
#            "sonatype.org",
#            "yarnpkg.com",
#            "yarnpkg.org"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "microsoft",
#      "label": "Microsoft / VS Code",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "aka.ms",
#            "code.visualstudio.com",
#            "dotnet.microsoft.com",
#            "gallerycdn.vsassets.io",
#            "learn.microsoft.com",
#            "marketplace.visualstudio.com",
#            "visualstudio.microsoft.com",
#            "vscode-cdn.net",
#            "vscode.dev"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "jetbrains",
#      "label": "JetBrains",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "jetbrains.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "adobe",
#      "label": "Adobe",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "adobe.com",
#            "adobelogin.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "nvidia",
#      "label": "NVIDIA",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "geforce.com",
#            "nvidia.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "apple",
#      "label": "Apple",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "apple.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "google",
#      "label": "Google",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "accounts.google.com",
#            "ads.google.com",
#            "adservice.google.com",
#            "ai.google",
#            "aistudio.google.com",
#            "analytics.google.com",
#            "apis.google.com",
#            "appengine.google.com",
#            "apps.admob.com",
#            "books.google.com",
#            "business.google.com",
#            "classroom.google.com",
#            "clients.google.com",
#            "clients2.google.com",
#            "clients6.google.com",
#            "cloud.google.com",
#            "code.google.com",
#            "colab.research.google.com",
#            "design.google.com",
#            "developer.google.com",
#            "developers.google.com",
#            "dl-ssl.google.com",
#            "dl.google.com",
#            "dns.google.com",
#            "domains.google.com",
#            "doubleclick.net",
#            "doubleclickbygoogle.com",
#            "events.google.com",
#            "fiber.google.com",
#            "firebase.google.com",
#            "gemini.google.com",
#            "google-analytics.com",
#            "google.ai",
#            "googleadservices.com",
#            "googleapis.com",
#            "googleblog.com",
#            "googlesource.com",
#            "googletagmanager.com",
#            "googletagservices.com",
#            "googleusercontent.com",
#            "gstatic.com",
#            "issuetracker.google.com",
#            "labs.google",
#            "marketingplantform.google.com",
#            "notebooklm.google.com",
#            "optimize.google.com",
#            "payments.google.com",
#            "play.google.com",
#            "storage.googleapis.com",
#            "surveys.google.com",
#            "tagmanager.google.com",
#            "withgoogle.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "discord",
#      "label": "Discord",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "discord.com",
#            "discord.gg",
#            "discordapp.com",
#            "discordapp.net"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "slackzoom",
#      "label": "Slack / Zoom / Teams",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "jitsi.org",
#            "slack-edge.com",
#            "slack.com",
#            "zoom.us"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "figma",
#      "label": "Figma / Canva / Notion",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "asana.com",
#            "canva.com",
#            "figma.com",
#            "invis.io",
#            "linear.app",
#            "miro.com",
#            "notion.so",
#            "trello.com",
#            "zeplin.io"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "cloud",
#      "label": "کلاود و هاستینگ",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "appspot.com",
#            "aws.amazon.com",
#            "bluemix.net",
#            "c9.io",
#            "cloudflare.com",
#            "cloudfront.net",
#            "cocalc.com",
#            "codesandbox.io",
#            "csb.app",
#            "digitalocean.com",
#            "download.virtualbox.org",
#            "es.io",
#            "firebase.com",
#            "fly.io",
#            "heroku.com",
#            "hetzner.com",
#            "ibm.com",
#            "java.com",
#            "linode.com",
#            "netlify.app",
#            "netlify.com",
#            "oracle.com",
#            "railway.app",
#            "render.com",
#            "replit.com",
#            "softlayer.com",
#            "sparkjava.com",
#            "supabase.com",
#            "vercel.app",
#            "vercel.com",
#            "virtualbox.org",
#            "vmware.com",
#            "zeit.co"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "education",
#      "label": "آموزش و مرجع",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "acm.org",
#            "arxiv.org",
#            "baeldung.com",
#            "cljdoc.org",
#            "codex.cs.yale.edu",
#            "coursehero.com",
#            "coursera-apps.org",
#            "coursera.com",
#            "coursera.org",
#            "datacamp.com",
#            "edx.org",
#            "fluttercrashcourse.com",
#            "flutterlearn.com",
#            "freecodecamp.org",
#            "goanimate.com",
#            "grabcad.com",
#            "hackerrank.com",
#            "ieee.org",
#            "jenkov.com",
#            "khanacademy.org",
#            "mathworks.com",
#            "medium.com",
#            "mit.edu",
#            "mybridge.co",
#            "overleaf.com",
#            "packtpub.com",
#            "piles.overleaf.com",
#            "proandroiddev.com",
#            "researchgate.net",
#            "sciencedirect.com",
#            "serverfault.com",
#            "spiceworks.com",
#            "springer.com",
#            "stackexchange.com",
#            "stackoverflow.com",
#            "superuser.com",
#            "teamtreehouse.com",
#            "udemy.com",
#            "udemycdn-a.com",
#            "udemycdn.com",
#            "wikia.com",
#            "wolframalpha.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "hardware",
#      "label": "سخت‌افزار و درایور",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "altera.com",
#            "amd.com",
#            "android.com",
#            "anydesk.com",
#            "arduino.cc",
#            "bitvise.com",
#            "cisco.com",
#            "clamav.net",
#            "dell.com",
#            "developer.samsung.com",
#            "digikey.com",
#            "download.01.org",
#            "element14.com",
#            "espressif.com",
#            "intel.com",
#            "lenovo.com",
#            "microchip.com",
#            "ni.com",
#            "nirsoft.net",
#            "qualcomm.com",
#            "raspberrypi.com",
#            "softonic.com",
#            "st.com",
#            "sun.com",
#            "teamviewer.com",
#            "ti.com",
#            "xilinx.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "finance",
#      "label": "پرداخت و مالی",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "coinbase.com",
#            "demandbase.com",
#            "en25.com",
#            "mailgun.com",
#            "paypal.com",
#            "paypalobjects.com",
#            "salesforce.com",
#            "sendgrid.com",
#            "stripe.com",
#            "upwork.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "webdev",
#      "label": "ابزار وب و فریم‌ورک",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "algolia.com",
#            "algolia.net",
#            "amp.dev",
#            "ant.design",
#            "apache.org",
#            "arcgis.com",
#            "atlassian.com",
#            "atlassian.net",
#            "b4x.com",
#            "beans.org",
#            "bit.dev",
#            "bitsrc.io",
#            "bootstrapcdn.com",
#            "bootswatch.com",
#            "bun.sh",
#            "caddy.com",
#            "caddyserver.com",
#            "cloudera.com",
#            "codecov.io",
#            "curd.io",
#            "dartlang.org",
#            "deno.land",
#            "developer.chrome.com",
#            "docs.datastax.com",
#            "elastic.co",
#            "enterprisedb.com",
#            "eslint.org",
#            "explainshell.com",
#            "expressjs.com",
#            "flutter.dev",
#            "flutter.io",
#            "forums.cpanel.net",
#            "gallery.io",
#            "getbootstrap.com",
#            "getcaddy.com",
#            "godbolt.org",
#            "grafana.com",
#            "graphql.org",
#            "hashicorp.com",
#            "hyper.is",
#            "i.stack.imgur.com",
#            "i18next.com",
#            "jaspersoft.com",
#            "javacardos.com",
#            "jenkins-ci.org",
#            "jenkins.org",
#            "jhipster.tech",
#            "jungle.net",
#            "laravel.com",
#            "material.io",
#            "mbed.com",
#            "metasploit.com",
#            "mongodb.com",
#            "mongodb.org",
#            "mysql.com",
#            "nativescript.org",
#            "nextjs.org",
#            "nginx.com",
#            "nodejs.org",
#            "php.net",
#            "polymer-project.org",
#            "postman.com",
#            "python.org",
#            "qt.io",
#            "rapid7.com",
#            "reactjs.org",
#            "realm.io",
#            "releases.hashicorp.com",
#            "ruby-doc.org",
#            "rust-lang.org",
#            "schema.org",
#            "seleniumhq.org",
#            "serialport.io",
#            "socket.io",
#            "sonarsource.com",
#            "splunk.com",
#            "spring.io",
#            "sstatic.net",
#            "swaggerhub.com",
#            "swift.org",
#            "symfony.com",
#            "telerik.com",
#            "terraform.io",
#            "traviscistatus.com",
#            "vagrantup.com",
#            "vuejs.org",
#            "vuetifyjs.com",
#            "web.dev"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "assets",
#      "label": "تصویر، فونت و قالب",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "3docean.net",
#            "codecanyon.net",
#            "cp.maxcdn.com",
#            "envato-static.com",
#            "envato.com",
#            "graphicriver.net",
#            "gravatar.com",
#            "justpaste.it",
#            "jwplayer.com",
#            "myfonts.net",
#            "photodune.net",
#            "themeforest.net",
#            "tinyjpg.com",
#            "tinypng.com",
#            "toggl.com",
#            "unsplash.com",
#            "videohive.net",
#            "vmcdn.com",
#            "wpastra.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "analytics",
#      "label": "تحلیل و تبلیغات",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "branch.io",
#            "bugsnag.com",
#            "count.ly",
#            "crashlytics.com",
#            "expo.io",
#            "fabric.io",
#            "fbsbx.com",
#            "flurry.com",
#            "fodev.org",
#            "lightstep.com",
#            "livefyre.com",
#            "newrelic.com",
#            "optimizely.com",
#            "parsely.com",
#            "sentry.io"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "bypass",
#      "label": "دور زده‌ها",
#      "groups": [
#        {
#          "key": "ea",
#          "label": "EA — سرورهای بازی",
#          "opt_in": true,
#          "note": "روشن کردنش بازی‌های EA را از سرور جدا می‌کند — این‌ها روی ۴۴۳ نیستند",
#          "domains": [
#            "gosredirector.ea.com",
#            "blaze.ea.com",
#            "gameservices.ea.com",
#            "tnt-ea.com"
#          ]
#        },
#        {
#          "key": "playstation",
#          "label": "PlayStation — STUN و API",
#          "opt_in": true,
#          "note": "روشن کردنش تشخیص NAT کنسول را خراب می‌کند",
#          "domains": [
#            "np.playstation.net",
#            "np.dl.playstation.net"
#          ]
#        },
#        {
#          "key": "epic",
#          "label": "Epic Games — بک‌اند بازی",
#          "opt_in": true,
#          "note": "روشن کردنش matchmaking فورتنایت را می‌شکند",
#          "domains": [
#            "account-public-service-prod.ol.epicgames.com",
#            "data-asset-directory-public-service-prod.ol.epicgames.com",
#            "datarouter.ol.epicgames.com",
#            "datastorage-public-service-live.ol.epicgames.com",
#            "ds.svc.live.fngw.ol.epicgames.com",
#            "events-public-service-live.ol.epicgames.com",
#            "fn-service-discovery-live-public.ogs.live.on.epicgames.com",
#            "fn-service-habanero-live-public.ogs.live.on.epicgames.com",
#            "fngw-svc-ds-livefn.ol.epicgames.com",
#            "fortnite-public-service-prod11.ol.epicgames.com",
#            "fortnitecontent-website-prod07.ol.epicgames.com",
#            "gc.svc.live.fngw.ol.epicgames.com",
#            "launcher-public-service-prod06.ol.epicgames.com",
#            "links-public-service-live.ol.epicgames.com",
#            "mcp-gc.live.fngw.ol.epicgames.com",
#            "prm-dialogue-public-api-prod.edea.live.use1a.on.epicgames.com"
#          ]
#        },
#        {
#          "key": "azure",
#          "label": "Azure — core.windows.net",
#          "opt_in": true,
#          "note": "روشن کردنش این اتصال‌ها را قطع می‌کند — SNI در مسیر مخدوش می‌شود",
#          "domains": [
#            "core.windows.net"
#          ]
#        }
#      ]
#    }
#  ]
#}
#__END_SERVICES__

#__DOCTOR_DNS_COMPLETE__
