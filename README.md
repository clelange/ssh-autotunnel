# SSH AutoTunnel

SSH AutoTunnel is a macOS menu-bar app for starting SSH SOCKS5 tunnels with automatic password/TOTP handling, health-aware PAC routing, network-aware proxy policy, and local automation.

The app is designed for SSH servers that require interactive 2FA, including CERN lxplus and PSI Tier-3 style workflows.

## Features

- Menu-bar controls for connecting and disconnecting tunnel profiles.
- Native Keychain-backed password and TOTP support.
- SSH SOCKS5 tunnels using `/usr/bin/ssh -N -D`.
- Local PAC server with fail-closed routing when a tunnel is unhealthy.
- Optional macOS Automatic Proxy Configuration for the active network service.
- Network fingerprint rules to disable proxy/PAC behavior on trusted networks.
- Settings and diagnostics windows.
- Local API, CLI helper, and Shortcuts/App Intents hooks.

## Build and Run

```sh
./script/build_and_run.sh
```

Useful checks:

```sh
swift build
swift test
./script/build_and_run.sh --verify
```

## Local Endpoints

When running, the app serves:

- PAC: `http://127.0.0.1:18483/proxy.pac`
- Status page: `http://127.0.0.1:18483/status`
- Local API: `http://127.0.0.1:18484`

The PAC returns `SOCKS5 127.0.0.1:<profile-port>` for healthy matching tunnels, `DIRECT` for unmatched hosts, and a blocking local proxy for matched domains whose tunnel is down.

## CLI

The CLI helper talks to the local API:

```sh
swift run ssh-autotunnelctl status
swift run ssh-autotunnelctl pac-url
swift run ssh-autotunnelctl connect "CERN lxplus"
swift run ssh-autotunnelctl disconnect "CERN lxplus"
```

## Configuration

Runtime configuration is stored in:

```text
~/Library/Application Support/SSHAutoTunnel/config.json
```

The app seeds CERN lxplus and PSI Tier-3 profiles. Existing `ssh-auto2fa` Keychain service names can be imported from the profile settings:

- `cern-lxplus-otp-secret`
- `psit3-password`
- `psit3-otp-secret`

## Development Notes

See `AGENTS.md` for progress tracking, validation expectations, known gaps, and the repository workflow.
