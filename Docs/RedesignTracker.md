# SSH AutoTunnel Redesign Tracker

This document tracks the Core Tunnel-inspired redesign without changing the
product name, bundle IDs, Swift targets, CLI name, support directories,
Shortcuts identity, package names, or persisted paths.

## Implemented

- Product naming decision: keep **SSH AutoTunnel**.
- Backwards-compatible profile schema additions:
  - `tags`
  - `connectOnLaunch`
  - `notificationPolicy`
  - `sshLogLevel`
  - `tunnelRequestsRemoteSession`
  - `localPortForwardings`
  - curated SSH options for bind address, address family, compression,
    identity files, certificate files, agent forwarding, ProxyCommand, and
    optional reconnect attempt limit.
- Tunnel command construction keeps dynamic SOCKS forwarding as the primary
  PAC path and emits local `-L` forwards for enabled rows.
- Tunnel commands use sessionless SSH (`-N`) by default.
- Configured SSH log levels apply to normal launches; diagnostics still request
  verbose SSH output.
- Jump hosts remain the typed ProxyJump/app-owned-hop model.
- Raw `extraSSHOptions` remain available as the escape hatch for uncommon
  OpenSSH options.
- Local API/status snapshots, diagnostics snapshots, profile JSON templates,
  configuration export/import, and the SSH config importer include the new
  fields.
- Per-profile connection notifications support disabled, failures/recoveries,
  and all status changes policies.
- Optional per-profile reconnect attempt limits are enforced for tunnel and
  hop reconnect loops.
- Main window redesign uses a native split layout with Overview, All Profiles,
  Needs Attention, tag filters, and per-profile detail pages.
- Overview shows System PAC state, active network state, unhealthy/reconnecting
  profiles, running tunnels/hops, PAC/status URLs, local server ports, recent
  connection changes, terminal preference, and quick actions.
- Profile detail pages show tunnel, interactive SSH, optional hop, forwarding
  rows, authentication/2FA, PAC/network rules, reconnect/notification settings,
  SSH options, and recent logs.
- Settings exposes profile editing for the new fields while retaining the
  existing app-level settings, PAC/network rule editing, import/export, support
  bundle, terminal preference, launch-at-login, OpenSSH config, and PAC append
  controls.
- Menu bar provides Connect All, Disconnect All, grouped profile submenus,
  hop controls, interactive SSH, System PAC toggle, settings, diagnostics,
  setup, and quit.
- Shortcuts create/update profile actions expose tags, connect-on-launch,
  notification policy, SSH log level, session request mode, local forwarding,
  bind/address-family/compression/identity/certificate/agent/proxy command, and
  reconnect limit fields.
- Regression coverage includes Codable defaults, command building, local
  forwarding validation, SSH config import mapping, status/diagnostics fields,
  reconnect limits, profile templates, and tracker presence.

## In Progress

- Live UX review with real user profiles and networks.
- Manual validation of real CERN/PSI authentication prompts, System PAC
  transitions, and Shortcuts discovery/invocation.

## Deferred

### Automatic Sync Across Macs

- Reason: requires conflict resolution, identity mapping, secret handling, and a
  decision about the sync backend. Implementing this in the redesign would
  change the app's trust and data model.
- Expected model/service impact: profile IDs, Keychain references, PAC/network
  rules, support bundle redaction, import/export, and local API writes would
  need sync-aware metadata and conflict handling.
- Acceptance criteria:
  - Users can enable or disable sync explicitly.
  - Profile, PAC rule, network rule, and app-level setting conflicts are
    detected and resolved predictably.
  - Keychain-backed password/TOTP material is never synced in plain text.
  - Offline edits on two Macs do not silently overwrite each other.

### Trash/Recent-Deleted Profiles

- Reason: profile deletion currently has direct cleanup semantics, including
  optional Keychain cleanup and scoped network-rule cleanup. A trash model needs
  reversible deletes without weakening those guarantees.
- Expected model/service impact: profile storage would need deleted-state
  metadata, restore actions, retention policy, local API/CLI/Shortcuts commands,
  and updated cleanup planning.
- Acceptance criteria:
  - Deleted profiles can be restored with their non-secret configuration intact.
  - Permanent deletion still supports explicit Keychain cleanup.
  - Scoped PAC/network rules are restored or pruned consistently.
  - Recent-deleted entries are excluded from active PAC and connection actions.

### Full `ssh_config` Directive Browser

- Reason: a full directive browser would be large and easy to overfit to
  OpenSSH internals. V1 should surface the high-value forwarding, proxy,
  identity, address-family, compression, and logging controls while retaining
  raw `extraSSHOptions` for uncommon directives.
- Expected model/service impact: would require a directive catalog, validation
  metadata, per-directive UI editors, importer/exporter mapping, and help text
  maintenance across OpenSSH versions.
- Acceptance criteria:
  - Users can browse supported OpenSSH directives by category.
  - Each directive has validation, help text, and import/export behavior.
  - Conflicting directives such as ProxyJump and ProxyCommand are detected.
  - The UI remains usable for common tunnel setup without exposing every option
    by default.

### Remote Port Forwarding And Reverse Dynamic Forwarding

- Reason: V1 expands forwarding with local forwards while keeping dynamic SOCKS
  as the primary PAC path. Remote and reverse dynamic forwarding have different
  security implications and require clearer UX around remote bind addresses.
- Expected model/service impact: forwarding models, command builder, validation,
  diagnostics, import/export, API/CLI/Shortcuts payloads, and UI summaries would
  need new typed rows and safety checks.
- Acceptance criteria:
  - Remote `-R` and reverse dynamic forwarding can be configured per profile.
  - GatewayPorts and bind-address behavior are visible and validated.
  - Diagnostics show effective remote forwarding configuration.
  - Import/export and automation surfaces round-trip all forwarding rows.

## Migration/Compatibility

- No name or path migration is planned because the app remains **SSH AutoTunnel**.
- Existing persisted profiles decode with defaults for all new fields.
- Existing dynamic SOCKS PAC behavior remains the default connection path.
- Existing app-owned hop behavior remains tied to `jumpHost`.
- Existing `extraSSHOptions` continue to round-trip for unsupported directives.
- Existing CLI, local API, Shortcuts actions, diagnostics, import/export,
  support bundles, package names, support directories, and CI workflows remain
  available.

## Validation History

- 2026-06-21 redesign batch:
  - `swift build` passed.
  - `swift test` passed with 335 tests.
  - `./script/build_and_run.sh --verify` passed.
  - `./script/package_local.sh --verify` passed and verified
    `dist/package/SSH-AutoTunnel-local.zip`.
