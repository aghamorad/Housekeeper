import Foundation
import AppKit

// MARK: - Open a Downloaded App

/// The result of clearing one app's download flag.
public struct AppRepairOutcome: Identifiable, Equatable {
    public let id = UUID()
    public let appName: String
    public let url: URL
    public let succeeded: Bool
    public let message: String
}
