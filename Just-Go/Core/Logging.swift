import Foundation
import os

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.erail.just-go"

    static let data = Logger(subsystem: subsystem, category: "data")
    static let routing = Logger(subsystem: subsystem, category: "routing")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    /// A trip's Live Activity as the system is asked for it and asked to take it down. Read from a
    /// phone with Console: nothing on a simulator stands in for a real Lock Screen.
    static let trip = Logger(subsystem: subsystem, category: "trip")
}
