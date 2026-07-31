# Jamf Pro → Intune Mapping Table

**Last verified:** July 2026
**Verify against:** current Intune service release + Apple DDM schema

> This table is perishable. Intune's macOS settings catalog expands with every
> monthly service release, so ⚠️ and ❌ rows shrink over time. Treat the date
> stamp above as part of the data — a stale mapping table is worse than none,
> because it produces confidently wrong migration plans.

Legend: ✅ direct translation · ⚠️ translates with caveats · ❌ manual rebuild
· ❓ unverified

---

## Configuration profile payloads

| Jamf payload | Intune equivalent | Status | Notes |
|---|---|---|---|
| Custom Settings (.mobileconfig) | Custom profile (upload) | ✅ | The escape hatch — anything unmapped can fall back here |
| PPPC / Privacy Preferences | Settings catalog | ✅ | |
| System Extensions | Settings catalog | ✅ | Kernel extensions are legacy; map to system extensions |
| Firewall | Settings catalog → Security | ✅ | |
| Gatekeeper / Security | Settings catalog | ✅ | |
| Energy Saver | Settings catalog | ✅ | |
| Fonts | Settings catalog → System Configuration | ✅ | Font files must be under 2 MB |
| Restrictions | Settings catalog | ⚠️ | Several intelligence-related keys deprecated in OS 26.4 — use DDM instead |
| FileVault | Settings catalog → Full Disk Encryption | ⚠️ | **Recovery keys do not migrate.** See below |
| SSO Extension / Platform SSO | PSSO profile | ⚠️ | Users must re-register after the move |
| Wi-Fi | Wi-Fi profile | ⚠️ | Certificate identities must be reissued |
| VPN | VPN profile | ⚠️ | Per-app VPN and cert identity need rebuild |
| Certificates | SCEP / PKCS / Trusted cert | ⚠️ | CA connector model differs entirely from Jamf |
| Dock | Settings catalog / custom | ⚠️ | Partial coverage |
| Software Update | DDM software update | ❌ | **Mandatory rebuild.** Legacy payload, MDM commands, restrictions, and update queries are being removed with the 2026 OS release |
| Printing | Custom mobileconfig only | ❓ | Not verified — confirm before relying on this row |
| Directory Binding | — | ❌ | No equivalent; deprecated by Apple |

## Non-profile Jamf objects

This is where most migration effort actually goes.

| Jamf object | Intune equivalent | Status | Notes |
|---|---|---|---|
| Packages (PKG) | macOS app (PKG/DMG) | ✅ | Mostly clean |
| Extension Attributes | Custom attributes | ⚠️ | One value per script; output contract differs |
| Scripts | Shell scripts | ⚠️ | No parameters, no event triggers, script count limits |
| Smart Groups | Entra dynamic groups | ❌ | Different syntax; evaluates Entra attributes, not device inventory |
| Policies (event-triggered) | — | ❌ | No equivalent; rebuild as scheduled scripts |
| Self Service | Company Portal | ❌ | Company Portal customization is far more limited |
| Patch Management | — | ❌ | No equivalent |
| Restricted / Licensed Software | — | ❌ | No equivalent |

---

## User-visible disruption — surface these first

These three cause end-user impact during migration and belong at the top of the
gap report, not in a footnote.

### 1. FileVault recovery key re-escrow
Recovery keys stay with the source MDM. Intune cannot escrow a key it never
issued. Options:
- **Escrow Buddy** (Netflix, open source) — automates re-issue and escrow at next login
- Rotate keys post-migration via policy
- Manual key import (BYOD / pre-encrypted devices)

Known edge case: macOS keeps using the *original* escrow certificate until
FileVault is toggled off and on, so a renewed cert alone won't fix a failed escrow.

### 2. Certificate reissuance
Wi-Fi, VPN, and 802.1X identities issued through Jamf's CA do not transfer.
Plan SCEP/PKCS profiles in the target *before* the ABM move, or devices lose
network access on arrival.

### 3. Platform SSO re-registration
Users re-register PSSO after the move. Communicate this — it looks like a
failure to end users otherwise.

---

## Implications for the tool

1. `IntuneMapper.supportedPayloadTypes` should be **data, not code** — load it
   from a versioned JSON file so it can be updated without a rebuild.
2. Every gap report must print the mapping table's verification date.
3. The three disruption items above deserve dedicated warning UI, not a row in
   a table.
4. DDM coverage needs its own check: Apple's schema is the superset, Intune's
   catalog is a subset, and the difference moves monthly.
