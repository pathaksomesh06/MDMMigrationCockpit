import SwiftUI

/// The app's colour language.
///
/// Deliberately narrow: colour here means *state*, not decoration. The rail is
/// the one saturated surface — an instrument panel the admin reads at a glance —
/// and everything in the working area stays quiet so dense diff tables remain
/// legible.
enum Theme {

    // MARK: Rail

    /// Deep navy, the cockpit panel. Chosen over a neutral grey so the rail
    /// reads as chrome rather than as more content.
    static let ink      = Color(red: 0.078, green: 0.141, blue: 0.235)   // #14243C
    static let inkDeep  = Color(red: 0.047, green: 0.090, blue: 0.157)   // #0C1728

    static let railGradient = LinearGradient(
        colors: [ink, inkDeep],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: Signals

    /// Primary accent — instrument teal. Distinct from the system blue used by
    /// every other Mac app, and it doesn't compete with the status colours.
    static let signal   = Color(red: 0.090, green: 0.690, blue: 0.769)   // #17B0C4
    static let go       = Color(red: 0.184, green: 0.714, blue: 0.451)   // #2FB673
    static let caution  = Color(red: 0.890, green: 0.604, blue: 0.169)   // #E39A2B
    static let stop     = Color(red: 0.851, green: 0.325, blue: 0.310)   // #D9534F
    static let declare  = Color(red: 0.486, green: 0.420, blue: 0.839)   // #7C6BD6

    // MARK: Rail typography

    static let railText       = Color.white
    static let railTextMuted  = Color.white.opacity(0.55)
    static let railDivider    = Color.white.opacity(0.10)
    static let railHighlight  = Color.white.opacity(0.10)

    // MARK: Working area

    /// Very light tints for the two tenants, used on cards and summaries so
    /// source and target stay visually distinct throughout the app.
    static let source = Color(red: 0.196, green: 0.451, blue: 0.851)     // #3273D9
    static let target = Color(red: 0.400, green: 0.361, blue: 0.784)     // #665CC8
}
