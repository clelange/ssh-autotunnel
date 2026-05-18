# SSH AutoTunnel

SSH AutoTunnel is a macOS menu-bar app for starting SSH SOCKS5 tunnels with automatic password/TOTP handling, health-aware PAC routing, network-aware proxy policy, and local automation.

The app is designed for SSH servers that require interactive 2FA, including CERN lxplus and PSI Tier-3 style workflows.

## Features

- Menu-bar controls for connecting and disconnecting tunnel profiles.
- First-launch setup window with quick access to imports, settings, PAC URL, and diagnostics.
- Native Keychain-backed password and TOTP support.
- `ssh-auto2fa` Keychain service checks before importing preset profiles.
- SSH SOCKS5 tunnels using `/usr/bin/ssh -N -D`.
- Local PAC server with fail-closed routing when a tunnel is unhealthy.
- Local blocking proxy that shows an explanatory page for HTTP requests when a PAC-matched tunnel is down.
- SOCKS5 handshake health checks so PAC only routes through working tunnels.
- Optional macOS Automatic Proxy Configuration for the active network service.
- Network fingerprint rules to disable proxy/PAC behavior on trusted networks.
- Settings and diagnostics windows.
- Local API, CLI helper, and Shortcuts/App Intents hooks.
- Automatic recovery from malformed configuration files by backing them up and recreating defaults.

## Build and Run

```sh
./script/build_and_run.sh
```

Useful checks:

```sh
swift build
swift test
./script/build_and_run.sh --verify
./script/package_local.sh --verify
```

## Local Package

Create an unsigned/ad-hoc-signed local zip with the app bundle and CLI helper:

```sh
./script/package_local.sh
```

The archive is written to `dist/package/SSH-AutoTunnel-local.zip`.

## Local Endpoints

When running, the app serves:

- PAC: `http://127.0.0.1:18483/proxy.pac`
- Status page: `http://127.0.0.1:18483/status`
- Local API: `http://127.0.0.1:18484`
- Blocking proxy: `127.0.0.1:18485`

The PAC returns `SOCKS5 127.0.0.1:<profile-port>` for matching tunnels that pass the local SOCKS5 handshake probe, `DIRECT` for unmatched hosts, and `PROXY 127.0.0.1:18485` for matched domains whose tunnel is down. The blocking proxy can show an explanatory HTML page for plain HTTP requests; HTTPS requests fail cleanly at the proxy because the app does not intercept TLS certificates.

## CLI

The CLI helper talks to the local API:

```sh
swift run ssh-autotunnelctl status
swift run ssh-autotunnelctl status --json
swift run ssh-autotunnelctl pac-url
swift run ssh-autotunnelctl reload-pac
swift run ssh-autotunnelctl apply-system-pac
swift run ssh-autotunnelctl restore-system-proxy
swift run ssh-autotunnelctl import-ssh-auto2fa
swift run ssh-autotunnelctl check-ssh-auto2fa --json
swift run ssh-autotunnelctl connect "CERN lxplus"
swift run ssh-autotunnelctl disconnect "CERN lxplus"
```

## Configuration

Runtime configuration is stored in:

```text
~/Library/Application Support/SSHAutoTunnel/config.json
```

The app seeds CERN lxplus and PSI Tier-3 profiles. Existing `ssh-auto2fa` Keychain service names can be checked and imported from setup or settings:

- `cern-lxplus-otp-secret`
- `psit3-password`
- `psit3-otp-secret`

## Development Notes

See `AGENTS.md` for progress tracking, validation expectations, known gaps, and the repository workflow.
