# SSH AutoTunnel

A macOS menu-bar app for starting SSH SOCKS5 tunnels with automatic password/TOTP handling, PAC generation, health-aware routing, and local automation.

## Build and Run

```sh
./script/build_and_run.sh
```

The app serves:

- PAC: `http://127.0.0.1:18483/proxy.pac`
- Status page: `http://127.0.0.1:18483/status`
- Local API: `http://127.0.0.1:18484`

The CLI helper talks to the local API:

```sh
swift run ssh-autotunnelctl status
swift run ssh-autotunnelctl pac-url
swift run ssh-autotunnelctl connect "CERN lxplus"
```
