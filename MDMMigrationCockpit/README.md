# MDM Migration Cockpit

A native macOS (SwiftUI) tool for planning, executing, and validating enterprise
Apple MDM migrations — MDM-agnostic, orchestrated through Apple Business Manager.

## Why

Apple's ABM-native wipeless MDM migration moves the *enrollment*.
It does not move the *configuration*. This tool fills that gap.

## Phases

| Phase | What it does |
|---|---|
| **Connect** | Authenticate to source MDM, target MDM, and ABM (AxM API) |
| **Analyze** | Export + normalize config, diff source vs target, produce a gap report |
| **Migrate** | Reassign devices to the target MDM server in waves via ABM |
| **Validate** | Confirm enrollment landed and on-device config matches the baseline |

## First supported pair

Jamf Pro → Microsoft Intune.

## Structure

```
App/           entry point, window, navigation
Core/          shared models, Keychain storage, logging
Connectors/    Jamf / Intune / ABM API clients
Translation/   normalizer, payload mapper, gap analyzer
Migration/     wave planner, post-migration validator
UI/            one SwiftUI view per phase
```

## Status

Scaffold. Placeholder files only — no implementation yet.

## Setup

1. Create a new macOS App target in Xcode (SwiftUI lifecycle).
2. Drag these folders in as **groups with folder references off** (create groups).
3. Set the deployment target and signing, then build.
