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
- Added `script/build_and_run.sh` and `.codex/environments/environment.toml` for local app launch.
- Initial implementation was pushed to `origin/main` at commit `676e33f`.

## Validation Status

Last known good checks:

```sh
swift build
swift test
./script/build_and_run.sh --verify
```

All passed on macOS 26.4.1 with Xcode 26.5 / Swift 6.3.2.

## Known Gaps

- Real CERN/PSI SSH login flows still need live validation with the user’s Keychain secrets and reachable networks.
- The pseudo-terminal prompt matcher is intentionally broad and may need tightening after real server tests.
- System PAC restoration is implemented for active service changes, but needs more manual testing across Wi-Fi, Ethernet, and VPN transitions.
- App Intents are present, but Shortcuts discovery and invocation need end-to-end validation from the Shortcuts app.
- The local API currently uses a static token stored in the app configuration; token rotation UI is minimal.

## Next Useful Milestones

- Validate and tune CERN lxplus and PSI Tier-3 authentication prompts.
- Add an onboarding flow for importing existing `ssh-auto2fa` Keychain services.
- Add richer network fingerprint display and “create rule from current network.”
- Add integration tests for the local HTTP API and PAC server.
- Add user notifications for tunnel failures and recoveries.
