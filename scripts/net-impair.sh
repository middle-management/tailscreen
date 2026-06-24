#!/usr/bin/env bash
# net-impair.sh — inject loss / delay / bandwidth limits onto Tailscreen's
# transport so the WAN-only failure modes can be reproduced on a single Mac.
#
# WHY THIS EXISTS
#   Every local test path (test-local.sh, local-headscale, the XCTest E2E
#   suites) runs over loopback: ~0% loss, in-order delivery, a 16 KB MTU.
#   That hides an entire class of bugs that only appear between real, distant
#   devices over DERP-relayed Tailscale — packet loss driving PLI/keyframe
#   storms, the adaptive-bitrate sweep reacting to loss, viewer stall +
#   recovery, and head-of-line blocking when one viewer is slow. This script
#   uses macOS's pf + dummynet (the machinery behind Network Link Conditioner)
#   to impair the node-to-node transport so you can watch the pipeline behave
#   under those conditions.
#
# WHAT IT IMPAIRS
#   Two tsnet nodes on the *same* Mac (the `./test-local.sh` / two-instance
#   setup) negotiate a direct WireGuard path and, being co-located, prefer
#   their loopback endpoints — so their encrypted UDP transport rides `lo0`.
#   This script pushes UDP on the chosen interface (default lo0) through a
#   dummynet pipe carrying the loss/delay/bandwidth you ask for. The headscale
#   control port (8080/tcp) and STUN (3478/udp) are left alone so connection
#   setup still works; we only beat up the data path.
#
#   IMPORTANT: this is best-effort. If your two nodes fall back to a
#   DERP-relayed path instead of going direct, the relevant flow may not be on
#   lo0. Verify impairment is biting by watching the viewer's stats overlay
#   (rising PLI count, dropping bitrate) or the merged log while it runs. If
#   nothing changes, the path isn't on --iface; try --iface en0, or force a
#   relayed path. For *deterministic* reorder/loss coverage that needs no root
#   and no network, use the depacketizer unit tests in RTPPacketTests instead.
#
# USAGE
#   sudo ./scripts/net-impair.sh up   [--loss PCT] [--delay MS] [--bw RATE] \
#                                     [--reorder PCT] [--reorder-delay MS] \
#                                     [--iface IFACE]
#   sudo ./scripts/net-impair.sh down
#   sudo ./scripts/net-impair.sh status
#
#   # Example: 3% loss + 80 ms each way on the loopback data path, then run
#   # the two-instance harness in another terminal and watch it recover.
#   sudo ./scripts/net-impair.sh up --loss 3 --delay 80
#   ./test-local.sh 2
#   sudo ./scripts/net-impair.sh down
#
# Requires root (pfctl/dnctl). Tear down with `down` when finished — pf stays
# enabled until you do.
set -euo pipefail

ANCHOR="tailscreen-impair"
PIPE_MAIN=1          # bulk path: loss + delay + bandwidth
PIPE_REORDER=2       # a fraction of packets sent down a higher-delay pipe to
                     # induce out-of-order arrival (see --reorder)
STAMP="/tmp/tailscreen-net-impair.state"

# Defaults
LOSS=0               # percent
DELAY=0              # ms (one way)
BW=""                # e.g. 5Mbit/s ; empty = unlimited
REORDER=0            # percent of packets pushed to the reorder pipe
REORDER_DELAY=60     # extra ms of delay for the reordered fraction
IFACE="lo0"

die() { echo "net-impair: $*" >&2; exit 1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"
}

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//'
    exit "${1:-0}"
}

parse_opts() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --loss)          LOSS="$2"; shift 2;;
            --delay)         DELAY="$2"; shift 2;;
            --bw)            BW="$2"; shift 2;;
            --reorder)       REORDER="$2"; shift 2;;
            --reorder-delay) REORDER_DELAY="$2"; shift 2;;
            --iface)         IFACE="$2"; shift 2;;
            -h|--help)       usage 0;;
            *)               die "unknown option: $1";;
        esac
    done
}

# Convert a 0–100 percent into the 0–1 loss rate dummynet's `plr` wants.
pct_to_rate() {
    awk -v p="$1" 'BEGIN { printf "%.4f", p/100 }'
}

cmd_up() {
    need_root
    parse_opts "$@"

    # Build the dummynet pipe config. plr/bw are only added when non-zero so a
    # delay-only run doesn't accidentally cap bandwidth.
    local main_cfg="delay ${DELAY}"
    [ -n "$BW" ] && main_cfg="$main_cfg bw ${BW}"
    if [ "$(awk -v l="$LOSS" 'BEGIN{print (l>0)}')" = "1" ]; then
        main_cfg="$main_cfg plr $(pct_to_rate "$LOSS")"
    fi

    echo "net-impair: configuring pipe $PIPE_MAIN on $IFACE: $main_cfg"
    dnctl pipe "$PIPE_MAIN" config $main_cfg

    local rules=""
    rules="dummynet in  quick on ${IFACE} proto udp from any to any pipe ${PIPE_MAIN}\n"
    rules="${rules}dummynet out quick on ${IFACE} proto udp from any to any pipe ${PIPE_MAIN}\n"

    # Optional reordering: send REORDER% of packets through a higher-delay
    # pipe so they land *after* later packets. dummynet has no native reorder
    # knob; the two-pipe + probability trick is the standard workaround. The
    # `probability` keyword is supported by the pf fork macOS ships, but if
    # your macOS rejects it, drop --reorder and rely on --loss/--delay (and
    # the deterministic depacketizer unit tests) instead.
    if [ "$(awk -v r="$REORDER" 'BEGIN{print (r>0)}')" = "1" ]; then
        local total_delay=$((DELAY + REORDER_DELAY))
        echo "net-impair: configuring pipe $PIPE_REORDER (reorder ${REORDER}%, +${REORDER_DELAY}ms)"
        dnctl pipe "$PIPE_REORDER" config delay "$total_delay"
        local prob
        prob="$(pct_to_rate "$REORDER")"
        # Probability rules must precede the catch-all so the matched fraction
        # diverts to the slow pipe; the rest falls through to PIPE_MAIN.
        rules="dummynet in  quick on ${IFACE} proto udp from any to any probability ${prob} pipe ${PIPE_REORDER}\n${rules}"
        rules="dummynet out quick on ${IFACE} proto udp from any to any probability ${prob} pipe ${PIPE_REORDER}\n${rules}"
    fi

    # The anchor only fires if the main pf ruleset references it. Append both
    # a dummynet-anchor and a (regular) anchor of our name to the *current*
    # ruleset, preserving whatever pf.conf already had. `down` restores it.
    pfctl -sr 2>/dev/null > "${STAMP}.rules" || true
    {
        cat /etc/pf.conf 2>/dev/null || true
        echo "dummynet-anchor \"${ANCHOR}\""
        echo "anchor \"${ANCHOR}\""
    } | pfctl -f - 2>/dev/null

    printf "%b" "$rules" | pfctl -a "$ANCHOR" -f - 2>/dev/null
    # `pfctl -E` prints its enable-reference token to *stderr* ("Token : N");
    # capture it so `down` can release exactly our reference and not disable pf
    # out from under something else that enabled it.
    pfctl -E 2>&1 | grep -i 'token' > "${STAMP}.token" || true
    : > "$STAMP"

    echo "net-impair: UP — loss=${LOSS}% delay=${DELAY}ms bw=${BW:-unlimited} reorder=${REORDER}% iface=${IFACE}"
    echo "net-impair: run your test now; tear down with: sudo $0 down"
}

cmd_down() {
    need_root
    # Flush our anchor + pipes, restore the stock ruleset, release our pf
    # enable-reference (pf may have been off before we started).
    pfctl -a "$ANCHOR" -F all 2>/dev/null || true
    dnctl -q flush 2>/dev/null || true
    pfctl -f /etc/pf.conf 2>/dev/null || true
    if [ -f "${STAMP}.token" ] && [ -s "${STAMP}.token" ]; then
        local tok
        tok="$(awk '{print $NF}' "${STAMP}.token")"
        [ -n "$tok" ] && pfctl -X "$tok" 2>/dev/null || true
    fi
    rm -f "$STAMP" "${STAMP}.token" "${STAMP}.rules"
    echo "net-impair: DOWN — impairment removed, pf restored to /etc/pf.conf"
}

cmd_status() {
    echo "== dnctl pipes =="
    dnctl -q list 2>/dev/null || echo "(none / needs root)"
    echo
    echo "== pf anchor '${ANCHOR}' =="
    pfctl -a "$ANCHOR" -sr 2>/dev/null || echo "(empty / needs root)"
    echo
    if [ -f "$STAMP" ]; then echo "state: UP (per $STAMP)"; else echo "state: DOWN"; fi
}

main() {
    [ $# -ge 1 ] || usage 1
    local sub="$1"; shift
    case "$sub" in
        up)     cmd_up "$@";;
        down)   cmd_down "$@";;
        status) cmd_status "$@";;
        -h|--help|help) usage 0;;
        *)      die "unknown subcommand: $sub (use up|down|status)";;
    esac
}

main "$@"
