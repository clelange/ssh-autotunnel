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
- Replaced unlimited reconnect loops with a shared, network-aware three-attempt policy, endpoint launch ledger, five-minute healthy reset, pooled-hop dependency coordination, and terminal Try Again notifications.
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
- Pooled compatible jump-host profiles by normalized hop endpoint, added deterministic private ControlPaths, and made ownership manifests/locks safely adopt only verified masters left by an exited app instance.
- Added structured hop ownership conflicts and recovery guidance to runtime status, diagnostics, the local API, and CLI while leaving foreign or unverified sockets untouched.
- Replaced destination routing through raw hop endpoints with stable fail-closed internal OpenSSH adapter aliases and added managed-include migration backups.
- Added a recursive read-only OpenSSH config audit with Include/glob provenance, safe Match evaluation, endpoint alias resolution, evidence-based findings, and read-only API/CLI JSON reporting.
- Added Settings review/application for selected equivalent single-hop ProxyJump replacements with complete diffs, metadata revalidation, private backups, atomic writes, and multi-file rollback.
- Replaced automatic first-launch setup with an on-demand template-based New Connection flow and a dashboard empty state for first profile creation.
- Renamed the setup core from account presets to connection templates and simplified template setup to a single-template apply path.
- Renamed stored setup account state to template accounts in app configuration and redacted exports.
- Polished first-run template setup UI with fitting empty-state actions, human-readable System PAC summaries, clearer credential readiness labels, and disabled save with review warnings when required setup input is missing.
- Added a tester QA checklist covering first-run setup, templates, credentials, tunnels, PAC/network behavior, CLI, Shortcuts, cleanup, and issue reporting for ad-hoc builds.
- Added a Developer ID release packaging path that signs the app, embedded CLI, and DMG with hardened runtime/timestamps, supports notarytool submission/stapling, and documents GitHub Release publishing.
- Added Settings-managed optional installation and guarded removal of `/usr/local/bin/ssh-autotunnelctl` as a symlink to the embedded CLI; the app continues to use its bundled helper directly.
- Simplified the public release DMG to the app plus an Applications link, while retaining the standalone CLI only in the local developer/tester ZIP.
- Replaced the primary trusted-network workflow with Direct Networks that prefer DNS search-domain matching across Wi-Fi/Ethernet/VPN, pause matching tunnels and shared-hop usage, resume prior intent, route PAC traffic normally, and launch direct interactive SSH while preserving legacy routing-only policies.
- Added a backward-compatible per-profile Connect All eligibility preference with Overview/menu-bar guidance, status/CLI/export/Shortcuts exposure, and tested inactive-profile selection.
- Propagated initial and dynamic terminal dimensions through the interactive SSH helper PTY so OpenSSH and remote tmux sessions can follow terminal resizes, with synthetic-PTY coverage for resize delivery and cleanup.
- Added readable profile-derived fail-closed hop adapter aliases with hashed compatibility aliases, v3 managed-config migration and rename history, collision protection, managed-integration audit status, and install/apply preconditions.
- Reserved historical readable aliases for their existing hop endpoints, disambiguated reused profile names, and made Settings, snippets, and audit reports share the same history-aware catalog. Regression coverage checks name reuse, existing owners, suffixed collisions, repeat generation, and actual OpenSSH ControlPath resolution.
- Made managed-include detection require an unconditional include before Host, Match, or earlier Include directives. Audits disable replacements until scoped integration is reinstalled; installation prepends an unconditional include with a private backup. Added scope, comment/argument parsing, safe-fix rejection, repair, and OpenSSH resolution coverage.
- Initial implementation was pushed to `origin/main` at commit `676e33f`.

- Added Sparkle 2.10 in-app updates with a GitHub Releases-hosted signed feed, application-menu check action, opt-in daily checks in Settings, and user-confirmed installation through the existing quit path.
- Added shared framework embedding/signing for all app packagers, release-only updater enablement, a Keychain-backed Ed25519 public-key configuration, and post-notarization feed generation/verification. Private signing material stays outside the repository.

- Reviewed updater startup gating, signature/feed validation, packaging/signing, and Sparkle's normal quit-event path. Fixed the maintenance gap where CI was manual-only: PRs targeting `main` and pushes to `main` now run with read-only permissions, no persisted checkout credentials, and strict committed-version resolution.
- Added Dependabot Swift checks on weekdays and GitHub Actions checks weekly, retaining the exact Sparkle pin and normal PR review. Enabled repository Dependabot alerts and security-update PRs through GitHub; scheduled version updates activate when `.github/dependabot.yml` reaches `main`.

## Validation Status

Last full package verification:

```sh
swift build
swift test
./script/build_and_run.sh --verify
./script/package_local.sh --verify
```

All passed on macOS 26.5.1 with Xcode 26.5 / Swift 6.3.2 after merging the template-based connection setup and dashboard redesign to `main`.

Latest feature validation:

```sh
swift build
swift test
```

Both passed on `feat/shared-hop-ssh-audit` after shared hop ownership/pooling, fail-closed adapters, recursive SSH config audit and safe-fix services, and Settings/API/CLI reporting. The core test suite has 378 XCTest cases.

Latest interactive terminal resize validation:

```sh
swift test --filter SSHProcessLauncherTests
swift test --filter InteractiveSSHSessionRunnerTests
swift build
swift test
./script/build_and_run.sh --verify
```

All passed on `feat/interactive-ssh-resize`. `swift test` executed 439 XCTest cases, including synthetic outer/inner PTYs that verified initial dimensions, larger and coalesced smaller resize delivery, `SIGWINCH` propagation, monitor cleanup, non-terminal fallback, and interactive-runner descriptor wiring.

Latest adapter review-fix validation (2026-09-24):

`swift build` and `swift test` passed on macOS 26.6.2 with Swift 6.4; the full suite executed 459 XCTest cases. Focused resolver/setup/audit and setup/audit/safe-fix runs also passed. Regression coverage verifies historical alias ownership with OpenSSH `-G`, reused-name and suffix collisions, unconditional include requirements, rejection before file writes, backup-protected include repair, and idempotent updates. No personal SSH configuration or live connections were changed during validation.

Original readable hop adapter validation:

```sh
swift test --filter 'HopAdapterNameResolverTests|SSHConfigSetupServiceTests|SSHConfigAuditServiceTests|SSHConfigSafeFixServiceTests'
swift build
swift test
```

All passed on `feat/readable-hop-adapters`. The focused suites executed 36 XCTest cases covering readable slug generation, pooled and colliding profiles, v3 migration, historical and hashed aliases, fail-closed resolution, managed-integration states, and apply-time revalidation. The full suite executed 452 XCTest cases.

Latest safe reconnect validation:

```sh
swift build
swift test
./script/build_and_run.sh --verify
```

All passed on `feat/safe-reconnect-policy`. `swift test` executed 421 XCTest cases covering bounded jittered delays, endpoint limits, offline pausing and exact-once resume, terminal failure ordering, pooled hop recovery, configuration migration, OpenSSH command limits, and notification deduplication.

Latest shared-hop live validation:

```sh
./script/build_and_run.sh --verify
ssh-autotunnelctl check-ssh-config --json
ssh-autotunnelctl connect "PSI General"
ssh-autotunnelctl connect "PSI CMS Tier-3"
```

All passed on `feat/shared-hop-ssh-audit`. PSI General used the stable app-owned `hopx.psi.ch` master and reached a healthy SOCKS5 tunnel on port 1084; a raw `-W hepserver.psi.ch:22` probe through the internal adapter returned the server SSH banner. PSI CMS Tier-3 used its separate stable app-owned `t3hop01.psi.ch` master, readiness marker, and healthy SOCKS5 tunnel on port 1085, then stopped cleanly while PSI General remained healthy. Settings displayed both adapter names and the v2 fail-closed snippet; Check SSH Config reported the real seven-file configuration with its safe replacement initially unselected and made no SSH config edits.

Latest UI polish validation:

```sh
swift build
swift test
./script/build_and_run.sh --verify
```

All passed on `feat/new-connection-ui-polish`. Computer Use smoke-tested the isolated first-run dashboard and New Connection wizard with a temporary `CFFIXED_USER_HOME`: empty-state buttons fit, the System PAC tile showed “Not configured,” PSI Tier-3 missing credentials disabled Save with a review warning, typed password state changed to “Entered now,” and cancelling left the temporary config empty.

Latest tester-build validation:

```sh
swift build
swift test
./script/build_and_run.sh --verify
./script/package_local.sh --verify
```

All passed on `main`. The package artifact is `dist/package/SSH-AutoTunnel-local.zip` with SHA-256 `abd278ff5a018bea6689d07e50de122972084df494197f2823c306ef4c393791`. The release app bundle was verified with `codesign --verify --deep --strict`, inspected as ad-hoc signed with bundle ID `dev.clange.ssh-autotunnel`, and launched successfully with a temporary `CFFIXED_USER_HOME`.

Latest non-live validation:

```sh
swift build
swift test
./script/build_and_run.sh --verify
./script/package_local.sh --verify
```

All passed on `main` after the default-branch merge. `swift test` executed 342 XCTest cases, `build_and_run.sh --verify` built, signed, launched, and detected the app, and `package_local.sh --verify` produced and verified `dist/package/SSH-AutoTunnel-local.zip`.

Latest release packaging validation:

```sh
swift build
swift test
./script/package_local.sh --verify
NOTARY_PROFILE=ssh-autotunnel-notary CODESIGN_IDENTITY=6775658B7B33A035FF1A113A53C67E9D8B2D29C0 NOTARIZE=1 ./script/package_release.sh --verify
```

All passed for `v0.7.0` (build `10`) on macOS 26.6.2 with Swift 6.4. The full suite executed 459 XCTest cases, and GitHub Actions run `35977752096` passed build, test, local package verification, and artifact upload on release commit `b9bea10`. Apple accepted notarization submission `2ca2c02d-bdba-45bd-8953-7846f42e947c`. The stapled DMG and the copy downloaded from the draft release passed checksum verification, Gatekeeper assessment as `Notarized Developer ID`, exact app-plus-Applications-link layout checks, app and embedded-helper signature validation, version/build inspection, and byte-for-byte comparison. The downloaded app also passed startup and local status endpoint checks with an empty temporary `CFFIXED_USER_HOME`, separate loopback ports, and manual PAC mode; the existing installed app and its connections were left running. The release is an arm64 build for Apple silicon Macs running macOS 26 or later. GitHub Release `v0.7.0` was published as the latest release. The published DMG SHA-256 is `2d9ce62ec2e0b68b8a6e17b747b30d9cd70d66971f4ee165ead042680447eb2f`.

Previous release packaging validation (`v0.6.3`):

```sh
swift build
swift test
./script/package_local.sh --verify
NOTARY_PROFILE=ssh-autotunnel-notary CODESIGN_IDENTITY=6775658B7B33A035FF1A113A53C67E9D8B2D29C0 ./script/package_release.sh --notarize
```

All passed for `v0.6.3`. `swift test` executed 434 XCTest cases, and GitHub Actions run `29521387798` passed build, test, local package verification, and artifact upload on release commit `53245ab`. `package_release.sh --notarize` produced `dist/release/SSH-AutoTunnel-0.6.3.dmg`, and Apple accepted submission `c882a28b-a73e-4d13-9bd4-07e7aeb0186b`. The stapled DMG and a copy downloaded back from the draft GitHub Release both passed checksum verification, Gatekeeper assessment as `Notarized Developer ID`, read-only mounting, exact app-plus-Applications-link layout checks with no loose CLI, app and embedded-helper signature validation, byte-for-byte comparison, and version/build inspection for `0.6.3` build `9`. GitHub Release `v0.6.3` was published as the latest release. The published DMG SHA-256 is `df6f31017ed26ed45e1f6e0297a1d8383a363adeb8e04501ba3f6b59ae4944d5`. `build_and_run.sh --verify` was skipped to avoid interrupting the installed app and its active tunnels.

Latest updater validation:

```sh
swift build
swift test
./script/package_local.sh --verify
python3 script/test_appcast.py
APP_VERSION=0.8.0 APP_BUILD=11 RELEASE_DIST_DIR="$PWD/dist/updater-verification" NOTARY_PROFILE=ssh-autotunnel-notary CODESIGN_IDENTITY=6775658B7B33A035FF1A113A53C67E9D8B2D29C0 ./script/package_release.sh --notarize
```

All passed on `feat/github-app-updates`: 459 XCTest cases and seven integration tests using real Sparkle tools, a disposable key, and a DMG fixture. Integration tests cover feed/download signature verification and tampering, signed wrong-URL/build rejection, wrong-key publishing failure, and disabled-development-build rejection. The unpublished 0.8.0/build 11 packaging rehearsal passed nested framework/app/helper signing, notarization (submission `c6d2ca66-91d7-4fd1-aa7e-02f5b77a6acf`), stapling, Gatekeeper, and signed appcast generation against the final DMG. This is a test artifact, not a published release or version bump.

Computer Use verified an isolated copy with a distinct bundle ID, temporary `CFFIXED_USER_HOME`, empty profiles, separate ports, and a loopback-hosted signed feed: automatic checking started off, the toggle worked, the menu/settings actions found version 0.8.0, dismissal left the app running, last-check time updated, and a tampered feed showed the signature-validation error. The isolated app quit cleanly; the installed app and its connections remained running. No production update was installed. `build_and_run.sh --verify` was skipped because it would quit the installed app.

Latest updater review/dependency-maintenance validation (2026-09-24):

`actionlint .github/workflows/ci.yml`, Dependabot YAML parsing, `swift build --force-resolved-versions`, `swift build`, and `swift test` passed; the Swift suite still has 459 passing cases. GitHub's Swift updater source covers changing `exact:` requirements alongside `Package.resolved`, so the 2.10.0 pin remains exact. Repository API reads confirmed Dependabot security updates are enabled and unpaused. The existing updater's seven signature/metadata integration tests and local package verification are included in every PR run, using only a disposable key. The review found no additional actionable defect in the updater code; the previously documented full installation/relaunch and active-connection cancellation rehearsal remains required before publishing.

## Known Gaps

- Before publishing the first updater-enabled release, upload the signed `appcast.xml` alongside its DMG/checksum. Versions through 0.7.0 need a manual upgrade. Complete a real install/relaunch and active-connection cancellation rehearsal in an isolated account; signature generation/validation and update discovery/error UI are already verified. Preserve the update-signing Keychain key when moving release machines; signed-feed failure fallback is deliberately disabled.

- The real PSI General and PSI CMS Tier-3 shared-hop/tunnel flows are live-validated. CERN SSH authentication still needs live validation with the user’s Keychain secrets and reachable network.
- The pseudo-terminal process boundary, prompt matcher, and terminal resize propagation are unit-tested with fakes, mixed prompt transcripts, and synthetic PTYs, but still need live tuning and app-launched tmux resize validation against real CERN/PSI sessions.
- System PAC restoration command planning, durable snapshot storage, and manager orchestration are unit-tested, but the live `networksetup` apply/restore flow still needs manual testing across Wi-Fi, Ethernet, and VPN transitions.
- App Intents now cover the local control API actions, but Shortcuts discovery and invocation still need end-to-end validation from the Shortcuts app.
- Configuration export/import and support-bundle generation are unit-tested and exposed through CLI/API/Shortcuts, but live Shortcuts import/export invocation still needs end-to-end validation.
- The local API token can be rotated from settings and is stored in a user-private config file; client authentication and error handling have integration coverage.
- `ssh-auto2fa` service detection is unit-tested with fake readers; real Keychain availability still depends on the user's local items and access prompts.
- The local package script creates an ad-hoc-signed zip. The release package script can Developer ID-sign and notarize a DMG; future release machines still need their own notarytool profile or Apple/App Store Connect notary credentials configured.

## Next Useful Milestones

- Validate and tune CERN lxplus authentication prompts.
- Manually validate system PAC apply/restore across Wi-Fi, Ethernet, and VPN transitions.
- Validate Shortcuts/App Intents discovery and invocation from the Shortcuts app.
