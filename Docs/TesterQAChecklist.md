# SSH AutoTunnel Tester QA Checklist

Use this checklist for ad-hoc tester builds before a signed/notarized release.
Record the app commit and package checksum with every report.

## Build Under Test

- Commit:
- Package: `dist/package/SSH-AutoTunnel-local.zip`
- SHA-256:
- macOS version:
- Network context: home / CERN / PSI / VPN / other

## Before Testing

- Export or copy any existing configuration you want to keep:
  `~/Library/Application Support/SSHAutoTunnel/config.json`
- Note whether macOS System PAC is currently configured for the active network
  service.
- Unzip `SSH-AutoTunnel-local.zip` and launch `SSHAutoTunnel.app`.
- If macOS blocks the ad-hoc app, record the exact Gatekeeper message. This is
  expected until Developer ID signing and notarization are configured.

## First-Run Experience

- On a clean config, the app opens the main dashboard, not a separate welcome
  or setup window.
- The empty dashboard shows **Create from Template**, **Create Manually**, and
  **Settings** without truncated labels.
- The System PAC summary uses readable text such as `Not configured`.
- Opening **Create from Template** shows CERN LxPlus, PSI CMS Tier-3, and PSI
  General.

## Template Setup

- CERN LxPlus:
  - Credential host is `lxplus.cern.ch`.
  - Default tunnel server is `lxtunnel.cern.ch`.
  - Review shows grouped Template, Credentials, Tunnel, and PAC sections.
  - Saving creates one CERN profile and one `*.cern.ch` PAC rule.
- PSI CMS Tier-3:
  - Credential host is `t3hop01.psi.ch`.
  - Tunnel profile is off by default.
  - Missing password disables Save and shows a review warning.
  - If a final UI/worker host is entered, the generated profile uses the
    `username@t3hop01.psi.ch` bastion.
- PSI General:
  - Credential host is `hopx.psi.ch`.
  - Default tunnel server is `login.psi.ch`.
  - Generated profiles use the `username@hopx.psi.ch` bastion.

## Credentials And Secrets

- Keychain status labels say `Found`, `Entered`, `Not found`, or `Unreadable`.
- Entered passwords/TOTP seeds are masked in the setup form.
- Configuration export and support bundle output do not contain password or TOTP
  secret values.
- `ssh-auto2fa` Keychain checks and import report useful created/updated counts.

## Tunnel And Hop Actions

- Connect, disconnect, reconnect, Connect All, and Disconnect All update the
  dashboard and sidebar status.
- Failed or interrupted tunnels show actionable status text and do not leave
  stale running indicators.
- PSI jump-host profiles expose hop connect, disconnect, and reconnect actions.
- Interactive SSH opens the selected terminal app and waits for required app-
  owned hops when the profile has a jump host.

## PAC And Network Behavior

- The dashboard PAC URL opens a PAC document on `127.0.0.1`.
- The status URL opens a local status page on `127.0.0.1`.
- Applying System PAC changes the active network service to the app PAC URL.
- Disabling/restoring System PAC puts the previous proxy state back.
- Quitting and relaunching does not lose the ability to restore a previously
  captured System PAC snapshot.
- Trusted-network rules can disable all proxying or only selected profiles, and
  the dashboard explains the matched rule.

## CLI And Shortcuts

- `ssh-autotunnelctl status --json` returns profile, PAC, network, and System
  PAC state.
- `ssh-autotunnelctl diagnostics --json` returns a structured diagnostics
  snapshot.
- `ssh-autotunnelctl export-config`, `validate-config`, `import-config`, and
  `support-bundle` work with user-only file permissions.
- Shortcuts discovers the SSH AutoTunnel actions and can run read-only actions
  such as status, PAC URL, diagnostics, and configuration validation.

## Cleanup

- Disconnect tunnels and hops.
- Disable/restore System PAC if it was applied.
- Export a support bundle if any issue occurred.
- Restore the previous configuration if needed.

## Report Template

```text
Commit:
Package SHA-256:
macOS:
Network/VPN:
Template/profile tested:
Action:
Expected:
Actual:
Logs/support bundle:
```
