# strongSwan build scripts

[bee](https://github.com/bee/bee) file and scripts to build
[strongSwan](https://strongswan.org/) into a self-contained, versioned
deployment directory, and to run it as IKEv2 gateway for the VPN clients
built into Windows, macOS, iOS, Android, ChromeOS and GNU/Linux. Users log in
with their password (EAP-MSCHAPv2), checked by the RADIUS server, like with
SoftEther’s L2TP/IPsec today.

The layout and the scripts follow `roundcube-build-scripts`.

## Layout

    /project/vpn-ikev2/
    ├── conf/                 configuration, a git repository of its own
    ├── logs/                 logs, shared by all deployments
    ├── 2026-11-16/           a deployment, built by build.sh
    │   ├── bee/              bee repository: packages, build logs, metadata
    │   ├── etc/              -> files in conf/etc, packaged ones as *.dist
    │   ├── libexec/ipsec/charon
    │   ├── sbin/swanctl
    │   ├── logs              -> /project/vpn-ikev2/logs
    │   ├── var/run/          charon.pid, charon.vici
    │   ├── startstop.sh
    │   └── profile
    ├── current               -> 2026-11-16
    ├── startstop.sh          -> current/startstop.sh
    └── profile               -> current/profile

## Network

The gateway runs on `wtf` next to SoftEther, the same way: charon runs as the
owner of the deployment, mapped to root in its own user namespace, with a
network namespace owned by that user namespace. The uplink VLAN interface is
moved into it. charon so gets `CAP_NET_ADMIN` only in its own network
namespace, which suffices for the IKE ports and the kernel IPsec state.

    client ── IKEv2/ESP ── ADDRESS (vlan, in the namespace) ── router ── NET_WISNET
                           forwards 141.14.14.128/25

- The clients get addresses from the upper half `141.14.14.128/25` of the VPN
  client network `NET_VPNX`. SoftEther’s clients keep the lower half. Once
  SoftEther is gone, widen `NET_VPNX` to `141.14.14.0/24`, and all firewall
  rules for VPN clients apply to the strongSwan clients unchanged.
- The kernel only accepts packets from a client’s IPsec SA with the source
  address assigned to that client, so the router’s rules based on source
  addresses can rely on them, unlike with SoftEther’s bridge.
- `esp4` has to be loadable on `wtf` (`/etc/kmod/whitelist.conf`), `esp6` too
  for IPv6 later. `startstop.sh` loads them.

Changes on the router (`MXR.cf.pl` in mxrouter-etc), a sketch:

    my $NET_VPNS2 = '141.14.220.XXX/31';                    # gateway uplink
    vlan('net03', NN, 'vlan.vpns1', '141.14.220.XXX/31');
    route('141.14.14.128/25', '<ADDRESS of the gateway>');
    # remove "-d 141.14.14.128/25 -j DROP" from the unrouted networks
    # allow UDP 500 and 4500 to $NET_VPNS2, like vpns-out
    # allow RADIUS from $NET_VPNS2 to 141.14.21.74, like $NET_VPNS

## Configuration repository

Start from the example:

    cp -r conf.example /project/vpn-ikev2/conf
    cd /project/vpn-ikev2/conf
    git init
    git add .
    git commit -m 'Add configuration from strongswan-build'

| File                                           | Content                       |
| ---------------------------------------------- | ----------------------------- |
| `etc/netns.conf`                               | uplink VLAN and address       |
| `etc/swanctl/swanctl.conf`                     | connection and address pool   |
| `etc/swanctl/x509/`                            | gateway certificate and chain |
| `etc/swanctl/private/`                         | gateway key (ignored by git)  |
| `etc/strongswan.d/charon/eap-radius.conf`      | RADIUS server                 |
| `etc/strongswan.d/charon/eap-radius-secret.conf` | RADIUS secret (ignored by git) |
| `etc/strongswan.d/charon-logging.conf`         | log to `logs/charon.log`      |

Create the secrets readable only by the owner of the project directory, which
charon runs as:

    umask 077
    mkdir -p etc/swanctl/private
    cp gateway.key etc/swanctl/private/
    cat >etc/strongswan.d/charon/eap-radius-secret.conf <<EOF
    eap-radius {
        servers {
            ratschefummel {
                secret = ...
            }
        }
    }
    EOF

strongSwan merges the sections of both eap-radius files.

### Certificate

The gateway needs a certificate from a publicly trusted CA for the host name
users enter (`local.id` in `swanctl.conf`), so no client needs a CA installed.
The host name has to be a subjectAltName (dNSName) of the certificate, and
Windows requires the extended key usage serverAuth. Put the certificate and the
intermediate CA certificates into `etc/swanctl/x509/`.

### RADIUS

SoftEther already sends EAP-MSCHAPv2 to the RADIUS server (`ratschefummel`),
so the server only needs the gateway’s `ADDRESS` as new client with a shared
secret.

## Build and activate

    ./build.sh /project/vpn-ikev2
    ./activate.sh /project/vpn-ikev2 2026-11-16     # as root

`build.sh` options: `-n NAME` (default: today’s date), `-c CONF_DIR`
(default: `PROJECT_DIR/conf`), `-l LOG_DIR` (default: `PROJECT_DIR/logs`).
`BEE_TMP_BUILDROOT` and `BEE_MAKEFLAGS` are passed on to bee. Run it as the
owner of the project directory: `startstop.sh` runs charon as the owner of the
deployment.

`activate.sh` stops the running gateway, points `current` to the deployment,
and starts it. Activating the previous deployment rolls back. Stopping charon
ends all connections, so clients reconnect.

## Operation

    /project/vpn-ikev2/startstop.sh start      # as root
    /project/vpn-ikev2/startstop.sh stop
    /project/vpn-ikev2/startstop.sh reload     # load changed swanctl.conf
    /project/vpn-ikev2/startstop.sh status     # connected clients
    /project/vpn-ikev2/startstop.sh exec swanctl --list-pools --leases
    /project/vpn-ikev2/startstop.sh exec       # shell in the namespaces

Except for `start`, the owner of the project directory can run these without
root, as the owner of a user namespace may enter it.

The algorithm proposals are strongSwan’s defaults. Windows proposes only weak
ones by default, so set stronger ones on Windows with
`Set-VpnConnectionIPsecConfiguration`, instead of weakening the gateway.
