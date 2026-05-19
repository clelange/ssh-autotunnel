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
- Moved tunnel TOTP generation to SSH prompt time so slow logins do not consume a code generated before SSH starts.
- Added per-profile SSH host-key policies, command construction coverage, legacy decoding defaults, and strict-policy prompt rejection.
- Seeded default CERN lxplus and PSI Tier-3 profiles and PAC rules.
- Added unit tests for TOTP vectors, PAC generation, domain matching, and network policy matching.
- Extracted SSH prompt detection into a tested pure core service and made tunnel prompt replies one-shot per prompt type.
- Made SSH prompt detection choose the newest prompt in the PTY transcript and added mixed host-key/password/TOTP fixture coverage.
- Expanded SSH prompt fixture coverage for PAM/keyboard-interactive password, OTP-code, verification-code, and passcode retry ordering.
- Added integration tests for the local HTTP server, including PAC serving and complete POST body handling.
- Added authenticated local API client integration tests.
- Extracted local API routing into a tested core service covering auth, status, dispatch, unknown routes, and malformed requests.
- Added current-network fingerprint display and a “create disable rule from current network” flow.
- Extracted current-network fingerprint parsing into tested helpers and made network identity command sources injectable.
- Added scoped network-policy rules so trusted networks can disable all proxying or only selected profiles, with PAC/API/CLI/status coverage.
- Added a local API token rotation action in settings.
- Added tested notification policy and macOS notification delivery for tunnel failures/recoveries.
- Added a tested `ssh-auto2fa` preset importer and Settings action.
- Added a tested `~/.ssh/config` importer for literal host entries with Settings, local API, CLI, and Shortcuts actions.
- Added tested CLI argument parsing and `--json` output for automation.
- Added local API and CLI actions for system PAC apply/restore, PAC reload, `ssh-auto2fa` preset import, and `ssh-auto2fa` Keychain checks.
- Added tested profile configuration create/update/delete logic with local API and CLI actions for external automation.
- Expanded Shortcuts/App Intents coverage to include reconnect, PAC reload, system PAC apply/restore, and `ssh-auto2fa` import/check actions.
- Added a diagnostics control action with CLI and Shortcuts coverage for structured state, network, port, and file-permission snapshots.
- Bound local PAC, status, API, and blocking proxy servers to the loopback interface by default.
- Made local HTTP server startup wait for listener readiness to avoid transient loopback connection races.
- Persisted system PAC snapshots for restore across app restarts and app termination.
- Extracted SSH tunnel command construction into a tested builder.
- Replaced local port-only health checks with a tested SOCKS5 handshake probe.
- Added tested tunnel lifecycle policy for intentional stops, unexpected SSH exits, repeated health failures, and automatic reconnect backoff.
- Added an injectable SSH process launcher with manager-level tests for manual stops, unexpected exits, and health-failure restarts.
- Hardened PTY SSH process launcher descriptor ownership and duplicate-file-descriptor error handling.
- Added a local blocking proxy for fail-closed PAC routes, including HTTP status pages and clean HTTPS `CONNECT` failures.
- Added tested port validation and restart logic for local PAC, API, and blocking proxy servers when valid listener ports change.
- Made local HTTP server construction reject invalid ports with typed errors instead of crashing.
- Extracted local server orchestration into a tested core coordinator with restart rollback coverage.
- Extracted macOS `networksetup` parsing and system PAC apply/restore command planning into tested core services.
- Made system proxy management injectable and added tests for apply, restore, missing service handling, and snapshot reuse.
- Made persisted system PAC snapshot load errors explicit during restore instead of silently ignoring them.
- Changed persisted system PAC snapshots to a backward-compatible per-network-service archive so Wi-Fi, Ethernet, and VPN service restores do not overwrite each other.
- Added explicit unified logging for system PAC restore failures during app termination.
- Added a first-launch setup window with quick actions for `ssh-auto2fa` import, settings, PAC URL copy, and diagnostics.
- Added tested `ssh-auto2fa` Keychain service inspection and surfaced it in setup and settings before preset import.
- Added tested configuration recovery for malformed config files with backup creation and default regeneration.
- Added private file permission enforcement for the app support directory, configuration, generated PAC copy, and system PAC snapshot.
- Added `script/build_and_run.sh` and `.codex/environments/environment.toml` for local app launch.
- Added `script/package_local.sh` for release builds, local app/CLI archive creation, ad-hoc signing, and bundle verification.
- Added GitHub Actions CI for Swift build, test, and local package verification on macOS runners.
- Initial implementation was pushed to `origin/main` at commit `676e33f`.

## Validation Status

Last known good checks:

```sh
swift build
swift test
./script/build_and_run.sh --verify
./script/package_local.sh --verify
```

All passed on macOS 26.4.1 with Xcode 26.5 / Swift 6.3.2. The core test suite currently has 122 XCTest cases.

## Known Gaps

- Real CERN/PSI SSH login flows still need live validation with the user’s Keychain secrets and reachable networks.
- The pseudo-terminal process boundary and prompt matcher are now unit-tested with fakes and mixed prompt transcripts, but still need live tuning after real CERN/PSI server tests.
- System PAC restoration command planning, durable snapshot storage, and manager orchestration are unit-tested, but the live `networksetup` apply/restore flow still needs manual testing across Wi-Fi, Ethernet, and VPN transitions.
- App Intents now cover the local control API actions, but Shortcuts discovery and invocation still need end-to-end validation from the Shortcuts app.
- The local API token can be rotated from settings and is stored in a user-private config file; client authentication and error handling have integration coverage.
- `ssh-auto2fa` service detection is unit-tested with fake readers; real Keychain availability still depends on the user's local items and access prompts.
- The package script creates a local ad-hoc-signed zip; Developer ID signing and notarization still need signing credentials and distribution decisions.

## Next Useful Milestones

- Validate and tune CERN lxplus and PSI Tier-3 authentication prompts.
- Manually validate system PAC apply/restore across Wi-Fi, Ethernet, and VPN transitions.
- Validate Shortcuts/App Intents discovery and invocation from the Shortcuts app.
