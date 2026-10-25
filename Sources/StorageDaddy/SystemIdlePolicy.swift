import CoreGraphics
import Foundation

enum SystemIdlePolicy {
    static func allows(requireIdle: Bool, minutes: Int, idleSeconds: Double) -> Bool {
        !requireIdle || (idleSeconds.isFinite && idleSeconds >= Double(min(120, max(1, minutes))) * 60)
    }
    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
    }
}
