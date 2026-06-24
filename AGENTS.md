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

## SSH/Hop Flow Testing Notes

- When changing SSH prompt, transcript, or hop-session detection logic, add tests using exact text from real user logs when available.
- For reconnect and lifecycle changes, cover both callback orderings: output before termination and termination before late output.
- For behavior that must not reconnect, tests must wait longer than the injected reconnect delay before passing.
- After adding or changing tests, run the focused test suite or filter before reporting the change as ready.

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
- Added a tested CLI profile JSON template command for create/update automation.
- Added tested PAC rule create/update/delete logic with local API and CLI actions plus a PAC rule JSON template.
- Added tested network rule create/update/delete logic with local API and CLI actions plus a current-network trust command.
- Reused profile configuration deletion logic from Settings so profile removal also clears scoped network rules.
- Expanded Shortcuts/App Intents coverage to include reconnect, profile/PAC/network rule management, PAC reload, system PAC apply/restore, import/check actions, typed picker entities, and read-only list/value actions.
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
- Fixed System PAC active service detection on macOS 26 by using `/sbin/route` and resolving default interfaces through `networksetup -listnetworkserviceorder` before the hardware-port fallback.
- Added observed System PAC status detection for the active service, with menu-bar, dashboard, Settings, local API, CLI, and diagnostics visibility.
- Changed the main-window PAC toolbar action into an apply/disable toggle with a slashed network icon when disabling SSH AutoTunnel PAC.
- Made main-window and menu-bar System PAC enable/disable actions toggle persistent automatic PAC management instead of applying a one-shot PAC URL.
- Added setup quick actions for `ssh-auto2fa` import, settings, PAC URL copy, and diagnostics before setup was later replaced by the template-based New Connection flow.
- Debounced SwiftUI edit-driven configuration saves while keeping explicit actions immediate.
- Added tested `ssh-auto2fa` Keychain service inspection and surfaced it in setup and settings before preset import.
- Added tested configuration recovery for malformed config files with backup creation and default regeneration.
- Added private file permission enforcement for the app support directory, configuration, generated PAC copy, and system PAC snapshot.
- Added `script/build_and_run.sh` and `.codex/environments/environment.toml` for local app launch.
- Added `script/package_local.sh` for release builds, local app/CLI archive creation, ad-hoc signing, and bundle verification.
- Added GitHub Actions CI for Swift build, test, and local package verification on macOS runners.
- Hardened loopback HTTP integration tests with retrying port allocation to reduce transient port races.
- Added redacted configuration export/import and support-bundle generation with local API, CLI, Shortcuts, and core redaction/validation coverage.
- Added private pre-import configuration backups before applying a redacted configuration export.
- Added dry-run configuration export validation through local API, CLI, Shortcuts, and core tests.
- Redacted home-directory paths from support-bundle diagnostics.
- Made configuration import and validation accept raw `config.json` backups by converting them to redacted exports before local API submission.
- Applied user-only file permissions to CLI-written configuration exports and support bundles.
- Added Settings file-panel actions for configuration export, validation, import, and support-bundle generation.
- Added tested pruning for old pre-import configuration backups while preserving malformed-config recovery backups.
- Added CI artifact upload for the verified local app/CLI package zip.
- Added SHA-256 checksum generation and verification for local package archives.
- Added optional PAC fallback composition from an existing HTTP(S) PAC URL or local PAC file, with Settings reload controls and generator coverage.
- Added explicit profile deletion controls plus optional Keychain cleanup for profile password/TOTP items across Settings, local API, CLI, and Shortcuts.
- Fixed the Settings profile deletion confirmation so it does not reopen for the next selected profile after deletion.
- Added split-terminal interactive SSH for PSI jump-host profiles so the authenticated hop session stays open while the final host session connects through it.
- Changed PSI General setup connections to use an interactive hopx session instead of a sessionless `ssh -N` ControlMaster.
- Made PSI Tier-3 final interactive sessions wait for the bastion setup prompt before launching the UI-node SSH command.
- Raised the app to macOS 26, changed it into a regular Dock app with a persistent main dashboard window, and kept the menu-bar extra as a quick control surface.
- Added app-owned background SSH ControlMaster hop connections with first-class hop status, health checks, prompt-time TOTP, reconnect handling, and PSI Tier-3 readiness marker support.
- Made tunnel and interactive SSH actions for jump-host profiles wait for a verified app-owned hop before launching the tunnel or final terminal session.
- Stopped app-launched final interactive SSH sessions from re-running the manual/debug hop wait loop after the app has already verified the hop.
- Added actionable macOS reconnect notifications for tunnel and hop failures.
- Added tracking for app-launched hop-dependent interactive SSH sessions and a quit confirmation before stopping tunnels and hop connections.
- Fixed interactive SSH marker cleanup trap quoting for Application Support paths containing spaces.
- Added Settings actions to copy or install a managed OpenSSH config snippet for jump-host profiles without editing existing user config blocks.
- Added hop connect/disconnect/reconnect coverage to the local API, CLI, Shortcuts/App Intents, status snapshots, diagnostics, and tests.
- Added synchronous SSH stop-on-quit with SIGTERM/SIGKILL fallback, process-group signaling, safer graceful app relaunch in the run script, and pid-validated interactive session markers to prevent orphaned tunnels and stale quit warnings.
- Added runtime SOCKS port fallback with loopback bind probing, effective-port PAC/status/CLI/dashboard reporting, and one retry for app-owned SSH forwarding conflicts.
- Replaced automatic first-launch setup with an on-demand template-based New Connection flow and a dashboard empty state for first profile creation.
- Renamed the setup core from account presets to connection templates and simplified template setup to a single-template apply path.
- Renamed stored setup account state to template accounts in app configuration and redacted exports.
- Initial implementation was pushed to `origin/main` at commit `676e33f`.

## Validation Status

Last full package verification:

```sh
swift build
swift test
./script/build_and_run.sh --verify
./script/package_local.sh --verify
```

All passed on macOS 26.4.1 with Xcode 26.5 / Swift 6.3.2 before the runtime SOCKS port fallback update.

Latest feature validation:

```sh
swift build
swift test
```

Both passed after the connection-template setup and template-account configuration refactors. The core test suite has 342 XCTest cases.

## Known Gaps

- Real CERN/PSI SSH login flows still need live validation with the user’s Keychain secrets and reachable networks.
- The pseudo-terminal process boundary and prompt matcher are now unit-tested with fakes and mixed prompt transcripts, but still need live tuning after real CERN/PSI server tests.
- System PAC restoration command planning, durable snapshot storage, and manager orchestration are unit-tested, but the live `networksetup` apply/restore flow still needs manual testing across Wi-Fi, Ethernet, and VPN transitions.
- App Intents now cover the local control API actions, but Shortcuts discovery and invocation still need end-to-end validation from the Shortcuts app.
- Configuration export/import and support-bundle generation are unit-tested and exposed through CLI/API/Shortcuts, but live Shortcuts import/export invocation still needs end-to-end validation.
- The local API token can be rotated from settings and is stored in a user-private config file; client authentication and error handling have integration coverage.
- `ssh-auto2fa` service detection is unit-tested with fake readers; real Keychain availability still depends on the user's local items and access prompts.
- The package script creates a local ad-hoc-signed zip; Developer ID signing and notarization still need signing credentials and distribution decisions.

## Next Useful Milestones

- Validate and tune CERN lxplus and PSI Tier-3 authentication prompts.
- Manually validate system PAC apply/restore across Wi-Fi, Ethernet, and VPN transitions.
- Validate Shortcuts/App Intents discovery and invocation from the Shortcuts app.
