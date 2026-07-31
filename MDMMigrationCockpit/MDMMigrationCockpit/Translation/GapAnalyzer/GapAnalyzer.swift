import Foundation

/// Produces the gap report — the single most valuable output of the tool.
///
/// Honesty is the product here. Reporting something as translatable when it
/// isn't is far worse than flagging it for manual rebuild.
struct GapAnalyzer {

    let mapper: IntuneMapper

    init(mapper: IntuneMapper) {
        self.mapper = mapper
    }

    /// Classify every source profile and explain the reasoning.
    ///
    /// targetProfileNames: names of policies already in Intune, used to warn
    /// before creating duplicates.
    func analyze(
        sourceProfiles: [NormalizedProfile],
        targetProfileNames: [String] = []
    ) -> [TranslationResult] {
        sourceProfiles.map { analyzeOne($0, targetNames: targetProfileNames) }
    }

    private func analyzeOne(_ profile: NormalizedProfile, targetNames: [String]) -> TranslationResult {
        var notes: [String] = []
        var statuses: [MappingStatus] = []

        if profile.payloads.isEmpty {
            notes.append("Profile has no parseable payloads — inspect it manually in Jamf.")
            return TranslationResult(profile: profile, status: .requiresManualRebuild, notes: notes)
        }

        for payload in profile.payloads {
            if let mapping = mapper.table.mapping(forPayloadType: payload.type) {
                statuses.append(mapping.status)

                switch mapping.status {
                case .direct:
                    notes.append("✓ \(display(payload.type)) → \(mapping.intuneEquivalent ?? "Intune settings catalog")")
                case .partial:
                    notes.append("△ \(display(payload.type)) → \(mapping.intuneEquivalent ?? "Intune") — \(mapping.notes)")
                case .manual:
                    notes.append("✗ \(display(payload.type)): no Intune equivalent — \(mapping.notes)")
                case .unverified:
                    notes.append("? \(display(payload.type)): mapping not verified against current Intune docs — treat as manual until confirmed.")
                }
                if let impact = mapping.userImpact, !impact.isEmpty {
                    notes.append("⚠ User impact: \(impact)")
                }
            } else {
                statuses.append(.unverified)
                notes.append("? \(display(payload.type)): not in the mapping table — no claim is made; verify by hand.")
            }
        }

        // Scope caveats — Smart Group criteria never survive translation.
        if !profile.scope.groupNames.isEmpty {
            notes.append("Scope uses groups (\(profile.scope.groupNames.joined(separator: ", "))) — group criteria must be rebuilt as Entra/Intune groups.")
        }

        // Duplicate check: does something with a very similar name already
        // exist in Intune? Name match is a heuristic, so it's a warning, not
        // a verdict change.
        if let existing = closestExistingName(to: profile.displayName, in: targetNames) {
            notes.append("⚠ Possible duplicate: Intune already has “\(existing)” — review before creating another copy.")
        }

        return TranslationResult(
            profile: profile,
            status: overallStatus(statuses),
            notes: notes
        )
    }

    /// Fuzzy name match: exact (case-insensitive) or one name containing the
    /// other, ignoring separators. Conservative on purpose — short names
    /// don't trigger containment matching.
    private func closestExistingName(to sourceName: String, in targetNames: [String]) -> String? {
        func canon(_ s: String) -> String {
            s.lowercased()
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        let source = canon(sourceName)
        for target in targetNames {
            let candidate = canon(target)
            if candidate == source { return target }
            if source.count > 6, candidate.count > 6,
               candidate.contains(source) || source.contains(candidate) {
                return target
            }
        }
        return nil
    }

    /// Worst-case rollup: only fully green when every payload is direct;
    /// fully red when nothing translates; partial otherwise.
    private func overallStatus(_ statuses: [MappingStatus]) -> TranslationStatus {
        let translatable = statuses.filter { $0 == .direct || $0 == .partial }
        if translatable.count == statuses.count && statuses.allSatisfy({ $0 == .direct }) {
            return .fullyTranslatable
        }
        if translatable.isEmpty {
            return .requiresManualRebuild
        }
        return .partiallyTranslatable
    }

    /// Human display for reverse-DNS payload types.
    private func display(_ type: String) -> String {
        mapper.table.mapping(forPayloadType: type)?.jamfPayload ?? type
    }

    /// Known structural gaps that have no direct Intune equivalent.
    /// These always land in the report regardless of payload contents.
    static let knownStructuralGaps: [String] = [
        "Jamf Policies (event-triggered) — no Intune equivalent; rebuild as scripts or Win32-style app logic",
        "Jamf Smart Groups with live criteria — Intune dynamic groups use different syntax and evaluation timing",
        "Jamf Extension Attributes — map to Intune custom attributes, but script output contracts differ",
        "Self Service branding and layout — no equivalent; Company Portal customization is limited"
    ]

    /// Export the report for change-board sign-off.
    func exportMarkdown(_ results: [TranslationResult]) -> String {
        var lines: [String] = []
        lines.append("# MDM Migration Gap Report")
        lines.append("")
        lines.append("| Profile | Verdict |")
        lines.append("|---|---|")
        for result in results {
            lines.append("| \(result.profile.displayName) | \(label(result.status)) |")
        }
        lines.append("")
        for result in results {
            lines.append("## \(result.profile.displayName) — \(label(result.status))")
            for note in result.notes { lines.append("- \(note)") }
            lines.append("")
        }
        lines.append("## Structural gaps (always apply)")
        for gap in Self.knownStructuralGaps { lines.append("- \(gap)") }
        return lines.joined(separator: "\n")
    }

    private func label(_ status: TranslationStatus) -> String {
        switch status {
        case .fullyTranslatable:      return "Translatable"
        case .partiallyTranslatable:  return "Partial"
        case .requiresManualRebuild:  return "Manual rebuild"
        }
    }
}
