# SSH AutoTunnel Agent Notes

## Working Rules

- Keep feature work in separate commits and push each completed feature.
- Before every commit, run `swift build` and `swift test` from the repo root.
- Do not commit secrets, generated app bundles, or local build outputs.
- Keep `README.md` user-facing and concise; keep progress, implementation notes, and next steps here.
- Prefer small, focused changes that preserve the SwiftPM app structure:
  - `Sources/SSHAutoTunnelCore` for models and services.
  - `Sources/SSHAutoTunnelApp` for SwiftUI, menu bar, settings, diagnostics, and App Intents.
  - `Sources/SSHAutoTunnelCLI` for command-line remote control.
  - `Tests/SSHAutoTunnelCoreTests` for core behavior tests.

## Current Progress

- Created the SwiftPM macOS menu-bar app scaffold.
- Implemented native TOTP generation, Keychain access, SSH tunnel process management, health-aware PAC generation, network policy matching, local PAC/status/API servers, Shortcuts intents, and a CLI helper.
- Seeded default CERN lxplus and PSI Tier-3 profiles and PAC rules.
- Added unit tests for TOTP vectors, PAC generation, domain matching, and network policy matching.
- Extracted SSH prompt detection into a tested pure core service and made tunnel prompt replies one-shot per prompt type.
- Added integration tests for the local HTTP server, including PAC serving and complete POST body handling.
- Added authenticated local API client integration tests.
- Added current-network fingerprint display and a “create disable rule from current network” flow.
- Added a local API token rotation action in settings.
- Added tested notification policy and macOS notification delivery for tunnel failures/recoveries.
- Added a tested `ssh-auto2fa` preset importer and Settings action.
- Added tested CLI argument parsing and `--json` output for automation.
- Extracted SSH tunnel command construction into a tested builder.
- Replaced local port-only health checks with a tested SOCKS5 handshake probe.
- Added a local blocking proxy for fail-closed PAC routes, including HTTP status pages and clean HTTPS `CONNECT` failures.
- Extracted macOS `networksetup` parsing and system PAC apply/restore command planning into tested core services.
- Added a first-launch setup window with quick actions for `ssh-auto2fa` import, settings, PAC URL copy, and diagnostics.
- Added tested `ssh-auto2fa` Keychain service inspection and surfaced it in setup and settings before preset import.
- Added `script/build_and_run.sh` and `.codex/environments/environment.toml` for local app launch.
- Added `script/package_local.sh` for release builds, local app/CLI archive creation, ad-hoc signing, and bundle verification.
- Initial implementation was pushed to `origin/main` at commit `676e33f`.

## Validation Status

Last known good checks:

```sh
swift build
swift test
./script/build_and_run.sh --verify
./script/package_local.sh --verify
```

All passed on macOS 26.4.1 with Xcode 26.5 / Swift 6.3.2. The core test suite currently has 50 XCTest cases.

## Known Gaps

- Real CERN/PSI SSH login flows still need live validation with the user’s Keychain secrets and reachable networks.
- The pseudo-terminal prompt matcher is now unit-tested, but still needs live tuning after real CERN/PSI server tests.
- System PAC restoration command planning is unit-tested, but the live `networksetup` apply/restore flow still needs manual testing across Wi-Fi, Ethernet, and VPN transitions.
- App Intents are present, but Shortcuts discovery and invocation need end-to-end validation from the Shortcuts app.
- The local API token can be rotated from settings; client authentication and error handling have integration coverage.
- `ssh-auto2fa` service detection is unit-tested with fake readers; real Keychain availability still depends on the user's local items and access prompts.
- The package script creates a local ad-hoc-signed zip; Developer ID signing and notarization still need signing credentials and distribution decisions.

## Next Useful Milestones

- Validate and tune CERN lxplus and PSI Tier-3 authentication prompts.
- Manually validate system PAC apply/restore across Wi-Fi, Ethernet, and VPN transitions.
- Validate Shortcuts/App Intents discovery and invocation from the Shortcuts app.
