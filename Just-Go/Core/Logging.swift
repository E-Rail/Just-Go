import Foundation
import os

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.erail.just-go"

    static let data = Logger(subsystem: subsystem, category: "data")
    static let routing = Logger(subsystem: subsystem, category: "routing")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
}
