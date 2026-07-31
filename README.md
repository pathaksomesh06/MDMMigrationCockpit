# MDM Migration Cockpit

A macOS app for planning and executing Mac fleet migrations between Jamf Pro and Microsoft Intune, using Apple Business Manager to move the devices.

It answers the question you actually have before a migration: **what have I got, what survives the move, what has to be rebuilt, and what breaks for users.**

> Read-only until you explicitly confirm a device move. The app never writes configuration to either MDM.

---

## What it does

**Connect** — authenticates to Jamf Pro, Microsoft Intune and Apple Business Manager. Credentials live in the Keychain; the app reconnects silently on launch.

**Analyze** — reads both tenants down to individual settings and compares them payload by payload. Every Apple macOS payload is listed, grouped in Apple's own categories, with a verdict:

| Status | Meaning |
|---|---|
| Aligned | Configured in both, same values — nothing to do |
| Configured differently | Configured in both, values differ — reconcile first |
| Needs migration | Source only — build it in the target |
| Intune only / Jamf only | Target has it, source doesn't |
| Gap | Source uses it, target can't deliver it |
| Safe to drop | Apple deprecated it — don't carry it across |
| Available, unused | Neither tenant configures it |

Each payload expands into a setting-by-setting diff — source value, target value, and whether the target MDM can express the setting at all.

**Migrate** — reassigns devices between MDM servers in Apple Business Manager, in waves, behind an explicit confirmation that restates every serial number.

**Validate** — post-migration enrolment and configuration parity checks.

---

## Why the comparison is trustworthy

The verdicts come from evidence, not from a hand-maintained lookup table:

- **Both tenants are read to setting level.** Intune custom profiles are decoded from their base64 mobileconfig; settings-catalog policies are read via `settingDefinitionId`, which Intune derives from Apple's own payload schema. Jamf profiles are parsed from their mobileconfig. The same artifact on both sides means a real diff.
- **Apple's schemas define the payload universe.** Payload names, types, categories, deprecation status and the full key list for every payload come from [`apple/device-management`](https://github.com/apple/device-management) — Apple's machine-readable MDM schemas.
- **Intune's own settings catalog is harvested at runtime** to determine what Intune can express *today*, rather than assuming. Cached for 14 days.
- **The mapping table only supplies what an API can't**: user-impact warnings, DDM-versus-profile advice, and the delivery mechanism per destination.

Where the app can't prove something, it says so rather than guessing.

---

## Setup

### Jamf Pro

Settings → **API roles and clients**.

1. **API Role** with read privileges: Computers, macOS Configuration Profiles, Policies, Scripts, Computer Extension Attributes, Smart Computer Groups, Static Computer Groups, Packages.
2. **API Client** assigned that role, enabled. Generate the client secret (shown once).

### Microsoft Intune

An Entra app registration, configured as a **public client**:

- **Authentication** → Mobile and desktop applications → redirect URI `mdmcockpit://auth`
- **Supported account types** → Accounts in any organizational directory (multitenant)
- **API permissions** → Microsoft Graph → *Delegated*:
  - `DeviceManagementConfiguration.ReadWrite.All`
  - `DeviceManagementManagedDevices.Read.All`
- Grant admin consent

No client secret. The app signs in interactively with OAuth 2.0 + PKCE; the tenant is detected from the account. Only the client ID is entered in the UI.

### Apple Business Manager

Preferences → **API** → create a key. You need the Client ID, Key ID and the downloaded `.p8` private key.

---

## Security

- Secrets are stored in the **Keychain** only, never in preferences or on disk in the clear.
- Intune uses **interactive sign-in with PKCE** — no client secret, and the sign-in sheet runs as a private session.
- The app is **sandboxed**, with outgoing network access and user-selected file read/write.
- Every read is read-only. The single consequential action — ABM device reassignment — is gated behind a confirmation sheet listing each serial number.

---

## Building

Requires Xcode 16 and macOS 14 or later. No third-party dependencies.

```bash
git clone https://github.com/<you>/MDMMigrationCockpit.git
open MDMMigrationCockpit/MDMMigrationCockpit.xcodeproj
```

Enable in **Signing & Capabilities → App Sandbox**:

- Network → Outgoing Connections (Client)
- File Access → User Selected File: Read/Write

---

## Project layout

```
Connectors/         Jamf, Intune and ABM API clients
  Intune/           Graph client, PKCE auth, settings-catalog harvest
Translation/        Normalizer, mapper, gap analyzer, capability matrix
Core/               App state, Keychain, logging, models
UI/                 SwiftUI views, one per migration phase
Resources/
  ApplePayloads.json    Apple's macOS payloads, categories, deprecations
  PayloadKeys.json      Every setting each payload defines
  MappingTable.json     Per-direction migration advice
```

---

## Known limitations

- **Advisory notes are richer Jamf → Intune.** The comparison works both ways, but the mapping table's commentary was written with Intune as the destination, so the reverse leans harder on the live diff.
- **Complex nested payloads are compared one level deep.** TCC and VPN carry hundreds of nested keys; expanding them fully produces noise rather than signal, so they're compared at the top level.
- **Certificates, FileVault keys and Platform SSO registration never migrate.** No tool can move them — they are reissued. The app flags each one with the remediation path.
- **Jamf Policies, Smart Group criteria and Self Service branding have no Intune equivalent** and must be rebuilt by hand.
- **Mapping data goes stale.** Intune's settings catalog expands monthly. The app shows the mapping table's age and warns after 90 days.

---

## Contributing

The data files are the most valuable thing to improve, and they need no Swift:

- `Resources/MappingTable.json` — migration advice per payload, per destination
- `Resources/ApplePayloads.json` — payload identifiers, categories, deprecations
- `Resources/PayloadKeys.json` — the settings each payload defines

If a payload you know is configured shows as "not configured", it's almost always a payload-identifier mismatch — the **Intune Catalog** inspector in the Analyze toolbar shows the domain names harvested from your tenant, which makes the fix a one-line change.

---

## Licence

MIT.

Not affiliated with, endorsed by, or supported by Apple, Jamf or Microsoft. Jamf Pro, Microsoft Intune and Apple Business Manager are trademarks of their respective owners.
