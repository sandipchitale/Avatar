import Foundation

// Small shared types used across the face, the speech engine and the servers.

/// What the face shows between speeches: listening while you speak, thinking while Claude works.
nonisolated enum Presence {
    enum State: String, Codable, Sendable, CaseIterable {
        case listening, thinking, none
    }
}

/// How an utterance ended.
nonisolated enum SpeechEnd: Sendable, Equatable {
    case finished
    case stopped
}

/// The two faces, as the mod and the menu name them.
nonisolated enum Gender: String, Codable, Sendable, CaseIterable {
    case male, female
}
