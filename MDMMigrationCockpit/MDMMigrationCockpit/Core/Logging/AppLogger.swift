import Foundation
import OSLog

/// Central logging. Migration runs need an audit trail, so every phase logs
/// through here rather than using print().
enum AppLogger {

    private static let subsystem = "com.intuneirl.MDMMigrationCockpit"

    static let connect  = Logger(subsystem: subsystem, category: "connect")
    static let analyze  = Logger(subsystem: subsystem, category: "analyze")
    static let migrate  = Logger(subsystem: subsystem, category: "migrate")
    static let validate = Logger(subsystem: subsystem, category: "validate")

    /// TODO: add an exportable run log (JSON) so a migration can be handed to
    /// a change board or auditor as evidence.
}
