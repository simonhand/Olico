import Foundation

public struct ResignKeyPolicy: Equatable {
    public enum Action: Equatable {
        case rekey(TimeInterval)
        case cancel
    }

    public let maxAttempts: Int
    public let retryDelay: TimeInterval
    public private(set) var attempts: Int = 0

    public init(maxAttempts: Int = 5, retryDelay: TimeInterval = 0.5) {
        self.maxAttempts = maxAttempts
        self.retryDelay = retryDelay
    }

    public mutating func nextAction() -> Action {
        if attempts < maxAttempts {
            attempts += 1
            return .rekey(retryDelay)
        }
        return .cancel
    }
}
