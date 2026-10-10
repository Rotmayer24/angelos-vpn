# VPN — angelOS plugin

An Xray VPN client for angelOS. It reads the same subscription keys as
Fortuna / Happ, lets you pick a location, pings the servers, and can push the
whole system through the tunnel (TUN) — with a password asked **once**.

- **Desktop widget** — status, the chosen server, its address, live speed, a switch.
- **Bar pill** — left click connects / disconnects, right click opens the window.
- **A full window** — the gear on the widget, the bar pill's right click, or
  `angelos run vpn settings`. The same tabs also live in **Settings → VPN**.
- **Tabs**: Connection, Servers, Subscriptions, Apps (split tunneling), TUN,
  Logs, About.

## How it works

Two engines are looked up on the machine, not assumed (see *Requirements*):

- **Xray** runs the subscription config. It is the only thing that speaks
  VLESS / XHTTP / Hysteria2; it listens on a local SOCKS (default `11080`) and
  HTTP (`11081`) port.
- **sing-box** brings up the TUN interface and sends system traffic to Xray's
  SOCKS port. It is only used in TUN mode.

Modes:

- **Proxy** — nothing privileged. Apps pointed at `127.0.0.1:11080` (SOCKS5)
  or `127.0.0.1:11081` (HTTP) use the tunnel. Optionally the GNOME/KDE system
  proxy is set for you, and your previous proxy settings are restored on
  disconnect.
- **TUN** — a virtual interface routes everything. The privileged helper does
  this; installing it asks for the password once, after which `up` / `down` run
  without a prompt.

The controller (`Vpn.qml`, a QML singleton) owns the subscription fetch, the
server list, the core process, the traffic counters and the helper calls. Every
piece of UI binds to it.

## TUN: one password, then never again

`privileged/install.sh` installs, as root:

- `/usr/local/libexec/angelos-vpn` — the helper (Python 3, root).
- `/usr/local/libexec/angelos-vpn-install` — a root-owned copy of the installer
  itself, so later installs and removals never run a file the user can write.
- `/usr/share/polkit-1/actions/org.angelos.vpn.policy` — two PolicyKit actions:
  `org.angelos.vpn.helper` (`allow_active=yes`, no password after the install)
  and `org.angelos.vpn.install` (always asks, because it runs as root).

The helper takes **only validated arguments** — two port numbers, one host
name, one DNS address, two comma-separated lists (apps, domains), a kill-switch
flag and the sing-box path — and builds the sing-box config itself. No
caller-supplied configuration ever reaches root.

The generated tunnel:

- routes `127.0.0.1` traffic from the **`xray` process** directly (so its link
  to the server can never loop through the tunnel), plus the resolved server IPs
  and private networks;
- hijacks **only port 53** for DNS and sends those queries through the proxy;
- sends your chosen apps (by process name) and domains (suffixes) directly, when
  split tunneling is on;
- everything else goes to Xray's SOCKS port;
- **Kill switch** (`strict_route`) blocks leaks if the tunnel drops.

### Trust and updating

Running a binary as root is the one thing this helper exists to get right, so:

- the **subscription is treated as untrusted input**. Its `inbounds` are thrown
  away and rebuilt (loopback only) and its `dns` is replaced with your own —
  otherwise a provider could open an unauthenticated proxy on `0.0.0.0` or point
  every lookup at itself;
- the **helper binary is pinned by SHA-256** in `/usr/local/libexec/angelos-vpn.sha256`
  (root-owned, `0444`). Any later install must match it byte for byte;
- an **update therefore means "Remove", then "Install" again** — the password
  is asked once more. That is the trade for not being able to bootstrap trust
  out of `$HOME`;
- the sing-box path passed in is rejected if it is relative, not a regular file,
  not executable, group/world-writable, or owned by the calling user.

### The tunnel cannot outlive the shell

sing-box is started in its own session, so it survives angelOS — and `qs kill`
ends the shell natively rather than exiting the application, so no
`Component.onDestruction` runs. Left alone, quitting angelOS while connected in
TUN mode would keep the interface up and the machine offline until a reboot.

The helper therefore starts a **watchdog** of its own: while an angelOS shell is
running it does nothing, and the moment the last one is gone it takes the tunnel
down. Typical case: about two seconds, no reboot.

## The subscription

`Subscriptions.js` understands both shapes a Happ-style endpoint can return:

- an **Xray config** (object or array) — the Fortuna default for a `v2rayNG`
  User-Agent;
- a **base64 list** of `vless://` / `vmess://` / `trojan://` / `ss://` URIs,
  including the SIP002 `ss://method:pass@host:port` form.

Either way every server ends up as one Xray config, so a single engine runs them
all. The request carries `X-HWID` (see below) and the `v2rayNG/1.8.5`
User-Agent. A link the engine could not run (an unknown transport, reality
without a public key) is reported as unsupported rather than listed as a server
that fails at connect time.

The URL carries a secret, so it is masked in the UI and only revealed on demand.

## The device id (HWID)

The HWID is `angelos-` + `/etc/machine-id` (falling back to
`/var/lib/dbus/machine-id`, then to a generated value that is stored). It is
stable for the life of the install and is sent to the provider as one machine.
It is **never** spoofed or rotated: the provider's device limit is respected.

## Requirements

- angelOS 2.0 or newer, with Quickshell.
- `xray` and `sing-box`. Happ's copies under `/opt/happ` are used when present;
  anything in `PATH`, `/usr/bin` or `/usr/local/bin` works too. The plugin finds
  them at startup and says in **About** what it could not find.
- `python3`, `curl`, `ss`, `pkexec`, `getent`, `sh`.

Proxy mode needs none of the privileges: install the helper only if you want TUN.

## IPC

`angelos run vpn <command>` — target `vpn`:

| command | does |
| --- | --- |
| `toggle` | connect or disconnect |
| `connect` | connect |
| `disconnect` | disconnect |
| `settings` | open the window |
| `refresh` | refetch the active subscription |
| `addsub <url>` | add a subscription |
| `ping` | ping every server |
| `status` | report the current status |
| `panic` | the emergency brake: tear everything down at once |
| `logs` | write the full log and diagnostics to the cache |

## Removing the helper

Settings → VPN → TUN → **Remove**, or:

```sh
sudo privileged/install.sh --remove
```

which also takes a running tunnel down.

## Tests

Two test suites run offline, without touching the network:

```sh
python3 test/test_probe.py     # the ping probe: argument handling and the deadline
node    test/test_subscriptions.js   # the parser, against hostile and modern inputs
```

## License

MIT — see [LICENSE](LICENSE).