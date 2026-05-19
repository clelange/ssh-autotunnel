# SSH AutoTunnel

[![CI](https://github.com/clelange/ssh-autotunnel/actions/workflows/ci.yml/badge.svg)](https://github.com/clelange/ssh-autotunnel/actions/workflows/ci.yml)

SSH AutoTunnel is a macOS menu-bar app for starting SSH SOCKS5 tunnels with automatic password/TOTP handling, health-aware PAC routing, network-aware proxy policy, and local automation.

The app is designed for SSH servers that require interactive 2FA, including CERN lxplus and PSI Tier-3 style workflows.

## Features

- Menu-bar controls for connecting and disconnecting tunnel profiles.
- First-launch setup window with quick access to imports, settings, PAC URL, and diagnostics.
- Native Keychain-backed password and TOTP support.
- Configurable SSH host-key policy per profile, defaulting to accepting new keys while rejecting changed keys.
- `ssh-auto2fa` Keychain service checks before importing preset profiles.
- `~/.ssh/config` import for literal `Host` entries, including common user, port, jump-host, and identity options.
- SSH SOCKS5 tunnels using `/usr/bin/ssh -N -D`.
- Local PAC server with fail-closed routing when a tunnel is unhealthy.
- Local blocking proxy that shows an explanatory page for HTTP requests when a PAC-matched tunnel is down.
- SOCKS5 handshake health checks so PAC only routes through working tunnels.
- Automatic reconnect for unexpected SSH exits and repeated SOCKS5 health-check failures.
- Optional macOS Automatic Proxy Configuration for the active network service.
- Durable system PAC snapshots so the previous macOS proxy state can be restored after app restart or quit.
- Network fingerprint rules to disable all proxy/PAC behavior or only selected profiles on trusted networks.
- Settings and diagnostics windows.
- Port validation for PAC/API/blocking/SOCKS settings, with local server restart when valid listener ports change.
- Local API and CLI helper for tunnel control, profile management, PAC, diagnostics, system proxy, and imports.
- Redacted configuration export/import and support bundle generation for backup, migration, and troubleshooting.
- Shortcuts/App Intents for tunnel, profile management, PAC, diagnostics, system proxy, import, export, and support-bundle actions.
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

When running, the app serves loopback-only endpoints:

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
swift run ssh-autotunnelctl import-ssh-config
swift run ssh-autotunnelctl check-ssh-auto2fa --json
swift run ssh-autotunnelctl diagnostics --json
swift run ssh-autotunnelctl export-config ./ssh-autotunnel-config.json
swift run ssh-autotunnelctl import-config ./ssh-autotunnel-config.json
swift run ssh-autotunnelctl support-bundle ./ssh-autotunnel-support.json
swift run ssh-autotunnelctl profile-template > profile.json
swift run ssh-autotunnelctl create-profile ./profile.json
swift run ssh-autotunnelctl update-profile ./profile.json
swift run ssh-autotunnelctl delete-profile "Old tunnel"
swift run ssh-autotunnelctl pac-rule-template > pac-rule.json
swift run ssh-autotunnelctl create-pac-rule ./pac-rule.json
swift run ssh-autotunnelctl update-pac-rule ./pac-rule.json
swift run ssh-autotunnelctl delete-pac-rule "Old routing"
swift run ssh-autotunnelctl network-rule-template > network-rule.json
swift run ssh-autotunnelctl create-network-rule ./network-rule.json
swift run ssh-autotunnelctl update-network-rule ./network-rule.json
swift run ssh-autotunnelctl delete-network-rule "Old trusted network"
swift run ssh-autotunnelctl trust-current-network "CERN lxplus"
swift run ssh-autotunnelctl connect "CERN lxplus"
swift run ssh-autotunnelctl disconnect "CERN lxplus"
```

## Configuration

Runtime configuration is stored in:

```text
~/Library/Application Support/SSHAutoTunnel/config.json
```

The app support directory is kept private to the current user, and `config.json` is written with user-only permissions because it contains the local API token.

Use `ssh-autotunnelctl export-config` to write a portable configuration export. The export intentionally omits the local API token and never contains Keychain secret values. Importing an export preserves the current machine's local API token, validates port conflicts and profile references, stops tunnels removed by the import, and restarts local servers when listener ports change.

Use `ssh-autotunnelctl support-bundle` to write a redacted JSON bundle containing the portable configuration export plus diagnostics such as active ports, network fingerprint, runtime profile status, and file permission checks.

The app seeds CERN lxplus and PSI Tier-3 profiles. Existing `ssh-auto2fa` Keychain service names can be checked and imported from setup or settings:

- `cern-lxplus-otp-secret`
- `psit3-password`
- `psit3-otp-secret`

Settings, Shortcuts, and the CLI can also import literal `Host` entries from `~/.ssh/config`. Wildcard and negated host patterns are skipped because they do not map to one concrete tunnel profile.

Shortcuts/App Intents expose tunnel connect/disconnect/reconnect, status, diagnostics, imports, exports, support bundles, system PAC apply/restore, and profile/PAC/network rule management. Shortcuts can also list configured profiles, PAC rules, and network rules as typed results, use picker-based profile/rule parameters for selected-item actions, and return the current PAC URL, diagnostics summary, network fingerprint, redacted configuration JSON, and redacted support-bundle JSON as automation values.

For external automation, generate a profile JSON template with `ssh-autotunnelctl profile-template`, edit it, then pass it to `create-profile` or `update-profile`. The template command does not require the app to be running.

PAC routing rules can be managed the same way with `ssh-autotunnelctl pac-rule-template`, `create-pac-rule`, `update-pac-rule`, and `delete-pac-rule`.

Trusted-network rules can be managed with `ssh-autotunnelctl network-rule-template`, `create-network-rule`, `update-network-rule`, and `delete-network-rule`. `trust-current-network` asks the running app to create a disable rule from the current network fingerprint; pass a profile name to scope that rule to one tunnel.

## Development Notes

See `AGENTS.md` for progress tracking, validation expectations, known gaps, and the repository workflow.
