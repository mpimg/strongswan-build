#!/bin/bash
#
# Start or stop the strongSwan gateway of the deployment this script is
# installed in. `build.sh` copies it to PREFIX/startstop.sh, and
# PROJECT_DIR/startstop.sh links to it through PROJECT_DIR/current.
#
# Run as root. Like SoftEther in /package/vpn, charon runs as the owner of the
# deployment, mapped to root in its own user namespace, with its own network
# namespace owned by that user namespace. That gives charon CAP_NET_ADMIN for
# its network namespace only, which it needs for the IKE ports and the kernel
# IPsec state (XFRM). The uplink VLAN interface is moved into the namespace,
# and the namespace forwards between the clients' IPsec SAs and the uplink.
# The router routes the client address pool to the uplink address.
#
# The site specific values come from etc/netns.conf of the configuration
# repository.

set -euo pipefail

PREFIX=$(dirname "$(readlink -f "$0")")
CHARON=$PREFIX/libexec/ipsec/charon
VICI_SOCKET=$PREFIX/var/run/charon.vici

die() {
    echo "$0: $*" >&2
    exit 1
}

# VLAN_PARENT, VLAN_ID, VLAN_IF, ADDRESS, GATEWAY
. "$PREFIX"/etc/netns.conf
# The owner of the deployment, which bee built as.
SWAN_USER=$(stat -c %U "$PREFIX")

charon_pid() {
    pgrep -u "$SWAN_USER" -x charon --oldest || true
}

# The PIDs of the processes in the network namespace $1, as given by
# readlink /proc/PID/ns/net. Without root, only the processes of the caller
# are readable, but the ones in charon's namespaces all belong to its owner.
netns_pids() {
    local p
    for p in /proc/[0-9]*; do
        if [ "$(readlink "$p"/ns/net 2>/dev/null)" = "$1" ]; then
            echo "${p#/proc/}"
        fi
    done
}

# Wait up to $1 seconds for the processes $2... to exit.
wait_for_exit() {
    local timeout=$1 p alive
    shift
    for _ in $(seq "$timeout"); do
        alive=
        for p; do
            kill -0 "$p" 2>/dev/null && alive=1
        done
        [ -n "$alive" ] || return 0
        sleep 1
    done
    return 1
}

# Run a command in the namespaces of the running charon, as root or as the
# owner of the user namespace. unshare --map-root-user denies setgroups() in
# the user namespace, which nsenter only accepts, if setgroups() succeeds
# outside, so as root. The owner keeps its credentials instead, mapped to root.
in_netns() {
    local pid opts=()
    pid=$(charon_pid)
    [ -n "$pid" ] || die "charon is not running"
    [ "$(id -u)" -eq 0 ] || opts=(--preserve-credentials)
    nsenter "${opts[@]}" --user --net --target "$pid" -- "$@"
}

case "${1-}" in
  start)
    [ "$(id -u)" -eq 0 ] || die "start needs root"
    [ -z "$(charon_pid)" ] || die "charon is already running"
    [ "$SWAN_USER" != root ] || die "$PREFIX is owned by root"
    case "$VLAN_ID $ADDRESS $GATEWAY" in
      *TODO*) die "set the uplink in $PREFIX/etc/netns.conf" ;;
    esac

    # The kernel IPsec modules, autoloaded only from the init namespaces.
    modprobe -a xfrm_user esp4 \
        || die "loading esp4 failed, is it whitelisted in /etc/kmod/whitelist.conf?"

    # The VLAN interface is destroyed with the network namespace, when charon
    # stops, so create it on every start.
    test -d /sys/class/net/"$VLAN_IF" \
        || ip link add link "$VLAN_PARENT" name "$VLAN_IF" type vlan id "$VLAN_ID"

    # The network namespace has to be created from inside the user namespace,
    # so the user namespace owns it. Keep a process in both to get a handle
    # for `ip link set netns` and nsenter, until charon holds them.
    pid=$(sudo -u "$SWAN_USER" unshare --propagation unchanged --user --map-root-user --net \
              bash -c 'sleep infinity >/dev/null & echo $!')
    trap 'kill "$pid"' EXIT
    ns() {
        nsenter --user --net --target "$pid" -- "$@"
    }

    ip link set "$VLAN_IF" netns "$pid"

    ns ip link set lo up
    ns ip addr add "$ADDRESS" dev "$VLAN_IF"
    ns ip link set "$VLAN_IF" up
    ns ip route add default via "$GATEWAY"
    ns sysctl -q -w net.ipv4.ip_forward=1
    # Replies to clients leave through the interface they came in, before
    # IPsec, so do not send the router ICMP redirects for them.
    ns sysctl -q -w net.ipv4.conf.all.send_redirects=0
    ns sysctl -q -w net.ipv4.conf."$VLAN_IF".send_redirects=0

    # charon does not fork. It logs to the files set in the configuration,
    # relative to PREFIX. Messages before that go to logs/charon.out. Write
    # to the deployment as its owner, as root may not on NFS (root_squash).
    cd "$PREFIX"
    # After a crash or reboot, the PID file and the vici socket are left
    # behind. No charon runs (checked above), so remove them before starting,
    # as otherwise the wait below sees the old socket and swanctl may run
    # before charon listens, and charon refuses to start, if the old PID now
    # belongs to another process of the owner.
    ns sh -c 'mkdir -p var/run && rm -f var/run/charon.pid var/run/charon.vici'
    # shellcheck disable=SC2016
    ns sh -c 'exec setsid "$0" </dev/null >>logs/charon.out 2>&1' "$CHARON" &

    for _ in $(seq 30); do
        [ -S "$VICI_SOCKET" ] && break
        sleep 1
    done
    [ -S "$VICI_SOCKET" ] || die "charon did not open $VICI_SOCKET, see $PREFIX/logs"
    ns "$PREFIX"/sbin/swanctl --load-all
    ;;
  stop)
    pid=$(charon_pid)
    [ -n "$pid" ] || exit 0
    netns=$(readlink /proc/"$pid"/ns/net)
    # This script would keep the namespaces alive itself.
    [ "$(readlink /proc/self/ns/net)" != "$netns" ] \
        || die "run stop outside of charon's namespaces"

    # charon deletes the SAs and sends clients a delete notification.
    kill -TERM "$pid"
    if ! wait_for_exit 30 "$pid"; then
        echo "$0: charon (PID $pid) still running after 30 s, killing it" >&2
        kill -KILL "$pid" 2>/dev/null || true
    fi

    # Any process left in charon's namespaces, like a shell of `exec`, keeps
    # them alive, and with them the VLAN interface, which start then fails to
    # create again. Kill only these, not all processes of the owner, which
    # also builds the deployments.
    mapfile -t pids < <(netns_pids "$netns")
    if [ ${#pids[@]} -gt 0 ]; then
        echo "$0: killing processes left in charon's namespaces: ${pids[*]}" >&2
        kill -KILL "${pids[@]}" 2>/dev/null || true
    fi
    wait_for_exit 10 "$pid" "${pids[@]}" \
        || die "processes in charon's namespaces still running after SIGKILL"
    ;;
  reload)
    # Load the changed swanctl configuration without stopping charon.
    in_netns "$PREFIX"/sbin/swanctl --load-all
    ;;
  status)
    in_netns "$PREFIX"/sbin/swanctl --list-sas
    ;;
  exec)
    # A shell, or a command, in charon's namespaces, for example
    # `startstop.sh exec swanctl --list-pools --leases`.
    shift
    . "$PREFIX"/profile
    if [ $# -eq 0 ]; then
        in_netns bash --noprofile --norc
    else
        in_netns "$@"
    fi
    ;;
  *)
    echo "usage: $0 { start | stop | reload | status | exec [COMMAND] }" >&2
    exit 1
    ;;
esac
