#!/usr/bin/env python3
"""Regenerate the Apple payload catalogs with per-platform tagging.

One file per resource, covering every supported platform, filtered at read
time by the session's platform. Two parallel files would double the
maintenance and let macOS and iOS drift apart at the next Apple release.

    python3 Tools/generate_payload_keys.py

Updates in MDMMigrationCockpit/Resources/:
    PayloadKeys.json     — rewritten: keys grouped by platform
    ApplePayloads.json   — augmented in place: platform tags added, iOS-only
                           payloads appended to existing categories. The
                           hand-curated category grouping, deprecation list and
                           declaration list are preserved, never regenerated.

Three things this gets right that a naive extraction does not:

1. Per-key OS filtering. 37 payloads exist on both platforms but expose
   different key sets — Restrictions is 209 keys in total, 99 on macOS and 156
   on iOS. Filtering only at payload level leaves every shared payload listing
   settings that don't exist on the platform being analysed.

2. Inheritance. Apple annotates supportedOS only on keys whose availability
   DIFFERS from their payload; a key with no block inherits the payload's
   support. Treating a missing block as "unsupported" silently drops more than
   half of every payload (Wi-Fi: 44 keys -> 14).

3. Payloads whose keys are all containers. System Logging's three top-level
   keys are dictionaries Apple marks n/a, with the real settings in subkeys.
   At this granularity it has no keys — but it exists on macOS, so it is kept
   with an empty key list rather than disappearing from the payload browser.

Granularity is top-level only, matching the existing catalogs: Wi-Fi lists
`EAPClientConfiguration` as one key rather than expanding its sub-dictionary.
Changing that affects how keys match Intune's `domain_key` setting ids and is
a separate decision.
"""

import json
import glob
import os
import sys
import tarfile
import urllib.request
import tempfile
import datetime

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required:  pip3 install pyyaml --user")

TARBALL = "https://codeload.github.com/apple/device-management/tar.gz/refs/heads/release"

PLATFORMS = ["macOS", "iOS"]

# Profile wrappers, not configurable payloads — they describe the envelope
# every .mobileconfig carries.
ENVELOPES = {"CommonPayloadKeys", "TopLevel"}

# Apple Education (Classroom / Schoolwork) is a separate product with its own
# provisioning model. Out of scope for MDM migration.
EXCLUDED = {"com.apple.education"}

# Categories for iOS-only payloads, using the existing curated category names.
# Anything not listed here and not already in ApplePayloads.json is reported
# at the end rather than silently filed somewhere arbitrary.
IOS_CATEGORIES = {
    "com.apple.eas.account": "Accounts",
    "com.apple.google-oauth": "Accounts",
    "com.apple.mail.managed": "Accounts",
    "com.apple.osxserver.account": "Accounts",
    "com.apple.subscribedcalendar.account": "Accounts",
    "com.apple.app.lock": "App management",
    "com.apple.sso": "Authentication",
    "com.apple.security.certificaterevocation": "Certificates",
    "com.apple.security.certificatetransparency": "Certificates",
    "com.apple.apn.managed": "Networking",
    "com.apple.cellular": "Networking",
    "com.apple.cellularprivatenetwork.managed": "Networking",
    "com.apple.networkusagerules": "Networking",
    "com.apple.relay.managed": "Networking",
    "com.apple.mdm": "Managed devices",
    "com.apple.tvremote": "Media management",
    "com.apple.SetupAssistant.managed": "User experience",
    "com.apple.homescreenlayout": "User experience",
    "com.apple.shareddeviceconfiguration": "User experience",
    "com.apple.vpn.managed.applayer": "VPN",
    "com.apple.webClip.managed": "Web",
}


def introduced(node, os_name, inherit=False):
    """Whether a schema node is available on an OS.

    `inherit` is the payload-level answer, used when a key declares no
    supportedOS block of its own.
    """
    block = node.get("supportedOS")
    if not isinstance(block, dict):
        return inherit
    value = block.get(os_name)
    if not isinstance(value, dict):
        # Block present but silent about this OS -> genuinely unsupported.
        return False
    return str(value.get("introduced", "n/a")).lower() != "n/a"


def fetch_schemas(destination):
    print("Downloading Apple device-management schemas…")
    archive = os.path.join(destination, "dm.tar.gz")
    urllib.request.urlretrieve(TARBALL, archive)
    with tarfile.open(archive) as tar:
        tar.extractall(destination)
    roots = glob.glob(os.path.join(destination, "device-management-*", "mdm", "profiles"))
    if not roots:
        sys.exit("Couldn't find mdm/profiles in the downloaded archive.")
    return roots[0]


def read_declarations(root):
    """Declarative configurations, with the platforms each supports."""
    entries = {}
    pattern = os.path.join(root, "declarative", "declarations", "**", "*.yaml")
    for path in sorted(glob.glob(pattern, recursive=True)):
        with open(path) as handle:
            document = yaml.safe_load(handle)
        if not isinstance(document, dict):
            continue
        payload = document.get("payload") or {}
        declaration_type = payload.get("declarationtype")
        if not declaration_type:
            continue
        platforms = [os_name for os_name in PLATFORMS if introduced(payload, os_name)]
        if platforms:
            entries[declaration_type.lower()] = platforms
    return entries


def read_profiles(profiles_dir):
    """Every payload, with its per-platform key lists."""
    entries = []
    for path in sorted(glob.glob(os.path.join(profiles_dir, "*.yaml"))):
        with open(path) as handle:
            document = yaml.safe_load(handle)
        if not isinstance(document, dict):
            continue

        payload = document.get("payload") or {}
        payload_type = payload.get("payloadtype")
        if not payload_type or payload_type in ENVELOPES or payload_type in EXCLUDED:
            continue

        platforms = [os_name for os_name in PLATFORMS if introduced(payload, os_name)]
        if not platforms:
            continue

        keys = {}
        for os_name in platforms:
            keys[os_name] = sorted(
                key["key"]
                for key in (document.get("payloadkeys") or [])
                if key.get("key") and introduced(key, os_name, inherit=True)
            )

        entries.append({
            "name": document.get("title"),
            "payloadType": payload_type,
            "platforms": platforms,
            "keys": keys,
        })
    return entries


def write_payload_keys(entries, resources):
    payloads = {}
    for entry in entries:
        # Several payloads share a payloadType (com.apple.MCX carries both
        # Accounts and Mobile Accounts), so entries are kept as a list and
        # separated by name rather than overwriting each other.
        payloads.setdefault(entry["payloadType"], []).append({
            "name": entry["name"],
            "platforms": entry["platforms"],
            "keys": entry["keys"],
        })

    document = {
        "schemaVersion": 3,
        "source": "apple/device-management — payloadkeys per payload",
        "sourceURL": TARBALL,
        "platforms": PLATFORMS,
        "lastVerified": datetime.date.today().isoformat(),
        "note": (
            "Every setting each payload defines, from Apple's own schemas, with "
            "keys listed separately per platform — 37 payloads exist on both "
            "macOS and iOS but expose different key sets. This is what the "
            "settings table lists, so a payload shows its full key list whether "
            "or not either tenant configures it. Payloads sharing a payloadType "
            "are separated by name. Regenerate with Tools/generate_payload_keys.py."
        ),
        "payloads": payloads,
    }
    path = os.path.join(resources, "PayloadKeys.json")
    with open(path, "w") as handle:
        json.dump(document, handle, indent=1)
        handle.write("\n")

    for os_name in PLATFORMS:
        types = sum(1 for e in entries if os_name in e["platforms"])
        keys = sum(len(e["keys"].get(os_name, [])) for e in entries)
        print(f"  PayloadKeys.json — {os_name}: {types} payload types, {keys} keys")


def augment_apple_payloads(entries, declarations, resources):
    """Add platform tags and append iOS-only payloads, preserving curation."""
    path = os.path.join(resources, "ApplePayloads.json")
    with open(path) as handle:
        catalog = json.load(handle)

    by_type = {e["payloadType"].lower(): e for e in entries}
    known = set()
    tagged = 0

    for category in catalog["categories"]:
        for payload in category["payloads"]:
            payload_type = (payload.get("payloadType") or "").lower()
            known.add(payload_type)
            entry = by_type.get(payload_type)
            # Payloads absent from Apple's schemas are vendor preference
            # domains the curated file adds deliberately (Microsoft apps),
            # so they stay and are treated as macOS.
            payload["platforms"] = entry["platforms"] if entry else ["macOS"]
            tagged += 1

    categories = {c["name"]: c for c in catalog["categories"]}
    appended, unplaced = 0, []
    for entry in entries:
        payload_type = entry["payloadType"].lower()
        if payload_type in known:
            continue
        if "iOS" not in entry["platforms"]:
            continue
        name = IOS_CATEGORIES.get(entry["payloadType"])
        if not name or name not in categories:
            unplaced.append(entry["payloadType"])
            continue
        categories[name]["payloads"].append({
            "name": entry["name"],
            "payloadType": entry["payloadType"],
            "platforms": entry["platforms"],
        })
        appended += 1

    catalog["schemaVersion"] = 3
    catalog["lastVerified"] = datetime.date.today().isoformat()

    # Declarations and deprecations build their own rows in the matrix, so they
    # need tagging too — otherwise a macOS-only declaration or a deprecated Mac
    # payload can appear in an iPad analysis.
    declared, undeclared = 0, []
    for declaration in catalog.get("declarations") or []:
        key = (declaration.get("declarationType") or "").lower()
        platforms = declarations.get(key)
        if platforms:
            declaration["platforms"] = platforms
            declared += 1
        else:
            # Not in Apple's schemas — assume macOS rather than showing it
            # everywhere, and report it so it can be checked.
            declaration["platforms"] = ["macOS"]
            undeclared.append(declaration.get("declarationType"))

    for entry in catalog.get("deprecated") or []:
        payload_type = (entry.get("payloadType") or "").lower()
        match = by_type.get(payload_type)
        # A payload Apple has removed outright is absent from the schemas, so
        # there is nothing to read a platform from. Both platforms is right:
        # "safe to drop" applies wherever the tenant still has it.
        entry["platforms"] = match["platforms"] if match else PLATFORMS

    with open(path, "w") as handle:
        json.dump(catalog, handle, indent=1)
        handle.write("\n")

    print(f"  ApplePayloads.json — {tagged} payloads tagged, {appended} iOS payloads appended")
    print(f"  ApplePayloads.json — {declared} declarations tagged, "
          f"{len(catalog.get('deprecated') or [])} deprecations tagged")
    if undeclared:
        print(f"  ⚠ declarations not in Apple's schemas, defaulted to macOS: {', '.join(str(d) for d in undeclared)}")
    if unplaced:
        print(f"  ⚠ no category for: {', '.join(sorted(unplaced))}")


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    resources = os.path.join(repo_root, "MDMMigrationCockpit", "Resources")
    if not os.path.isdir(resources):
        sys.exit(f"Resources directory not found: {resources}")

    with tempfile.TemporaryDirectory() as workspace:
        profiles_dir = fetch_schemas(workspace)
        root = os.path.dirname(os.path.dirname(profiles_dir))
        entries = read_profiles(profiles_dir)
        declarations = read_declarations(root)

    write_payload_keys(entries, resources)
    augment_apple_payloads(entries, declarations, resources)
    print("Done.")


if __name__ == "__main__":
    main()
