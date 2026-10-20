import Foundation

/// Mouth positions from the classic cartoon lip-sync chart. The chart is organised by
/// letters, so visemes are derived from the spelling of each spoken word.
nonisolated enum Viseme: String, Sendable, CaseIterable {
    case rest = "Rest"
    case ai = "A, E, I"
    case fv = "F, V"
    case o = "O"
    case chjsh = "CH, J, SH"
    case l = "L"
    case mbp = "B, M, P"
    case ee = "EE"
    case consonant = "C, D, G, K, N, S, T, X, Y, Z"
    case u = "U"
    case r = "R"
    case th = "TH"
    case qw = "Q, W"

    /// Relative time a sound occupies within a word; vowels are held longer than consonants.
    var weight: Double {
        switch self {
        case .ai, .ee, .o, .u: 1.6
        case .qw, .r: 1.2
        case .mbp: 0.8
        default: 1.0
        }
    }

    var shape: MouthShape {
        switch self {
        case .rest:      MouthShape(halfWidth: 26, top: 0, bottom: 0, roundness: 0.4, upperTeeth: 0, lowerTeeth: 0, tongue: 0)
        case .mbp:       MouthShape(halfWidth: 24, top: 0, bottom: 0, roundness: 0.4, upperTeeth: 0, lowerTeeth: 0, tongue: 0)
        case .ai:        MouthShape(halfWidth: 30, top: 9, bottom: 15, roundness: 0.5, upperTeeth: 0.35, lowerTeeth: 0.2, tongue: 0)
        case .fv:        MouthShape(halfWidth: 28, top: 4, bottom: 5, roundness: 0.35, upperTeeth: 0.8, lowerTeeth: 0, tongue: 0)
        case .o:         MouthShape(halfWidth: 12, top: 12, bottom: 12, roundness: 1, upperTeeth: 0, lowerTeeth: 0, tongue: 0)
        case .chjsh:     MouthShape(halfWidth: 28, top: 8, bottom: 10, roundness: 0.45, upperTeeth: 0.5, lowerTeeth: 0.45, tongue: 0)
        case .l:         MouthShape(halfWidth: 27, top: 7, bottom: 11, roundness: 0.5, upperTeeth: 0.4, lowerTeeth: 0, tongue: 0.7)
        case .ee:        MouthShape(halfWidth: 32, top: 7, bottom: 11, roundness: 0.4, upperTeeth: 0.4, lowerTeeth: 0, tongue: 0.4)
        case .consonant: MouthShape(halfWidth: 30, top: 6, bottom: 8, roundness: 0.35, upperTeeth: 0.45, lowerTeeth: 0.42, tongue: 0)
        case .u:         MouthShape(halfWidth: 10, top: 13, bottom: 17, roundness: 1, upperTeeth: 0, lowerTeeth: 0, tongue: 0.5)
        case .r:         MouthShape(halfWidth: 27, top: 6, bottom: 12, roundness: 0.55, upperTeeth: 0.5, lowerTeeth: 0.3, tongue: 0)
        case .th:        MouthShape(halfWidth: 26, top: 5, bottom: 7, roundness: 0.45, upperTeeth: 0.4, lowerTeeth: 0.3, tongue: 0.6)
        case .qw:        MouthShape(halfWidth: 9, top: 13, bottom: 13, roundness: 1, upperTeeth: 0, lowerTeeth: 0, tongue: 0)
        }
    }

    private static let digraphs: [String: Viseme] = [
        "ch": .chjsh, "sh": .chjsh, "th": .th,
        "ee": .ee, "ea": .ee, "ie": .ee,
        "oo": .u, "ou": .u, "ew": .u,
        "ph": .fv, "wh": .qw, "qu": .qw,
        "ck": .consonant, "ng": .consonant,
    ]

    private static func single(_ letter: Character) -> Viseme {
        switch letter {
        case "a", "e", "i": .ai
        case "o": .o
        case "u": .u
        case "f", "v": .fv
        case "b", "m", "p": .mbp
        case "l": .l
        case "r": .r
        case "w", "q": .qw
        case "j": .chjsh
        default: .consonant
        }
    }

    /// The sequence of mouth positions for a written word, e.g. "friend" → F, R, EE, C…, C….
    static func sequence(for word: String) -> [Viseme] {
        let letters = Array(word.lowercased().filter { $0.isLetter && $0.isASCII })
        guard !letters.isEmpty else { return [.ai] }

        var result: [Viseme] = []
        var i = 0
        while i < letters.count {
            if i + 1 < letters.count, let viseme = digraphs[String(letters[i...i + 1])] {
                result.append(viseme)
                i += 2
                continue
            }
            let letter = letters[i]
            i += 1
            let isSilentE = letter == "e" && i == letters.count && letters.count > 2
            if letter == "h" || isSilentE { continue }
            result.append(letter == "y" && i == letters.count ? .ee : single(letter))
        }
        // Repeated shapes read as one held position.
        return result.reduce(into: []) { if $0.last != $1 { $0.append($1) } }
    }
}

/// Parametric mouth, so shapes can morph smoothly from one viseme to the next.
/// Lengths are in the face's 300-point design space.
nonisolated struct MouthShape: Sendable, Equatable {
    var halfWidth: Double
    /// How far the upper lip rises above the mouth line.
    var top: Double
    /// How far the lower lip drops below the mouth line.
    var bottom: Double
    /// 0 = pointed corners (grin) ... 1 = round (O, U).
    var roundness: Double
    /// Fraction of the opening covered by upper / lower teeth.
    var upperTeeth: Double
    var lowerTeeth: Double
    /// 0 ... 1 visible tongue.
    var tongue: Double

    static let rest = Viseme.rest.shape

    var isClosed: Bool { top + bottom < 2 }

    /// Scales the opening (not the width), e.g. by loudness.
    func opened(by factor: Double) -> MouthShape {
        var shape = self
        shape.top *= factor
        shape.bottom *= factor
        return shape
    }

    func interpolated(to target: MouthShape, amount t: Double) -> MouthShape {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return MouthShape(halfWidth: mix(halfWidth, target.halfWidth),
                          top: mix(top, target.top),
                          bottom: mix(bottom, target.bottom),
                          roundness: mix(roundness, target.roundness),
                          upperTeeth: mix(upperTeeth, target.upperTeeth),
                          lowerTeeth: mix(lowerTeeth, target.lowerTeeth),
                          tongue: mix(tongue, target.tongue))
    }

    func distance(to other: MouthShape) -> Double {
        abs(halfWidth - other.halfWidth) + abs(top - other.top) + abs(bottom - other.bottom)
            + 10 * (abs(roundness - other.roundness) + abs(upperTeeth - other.upperTeeth)
                    + abs(lowerTeeth - other.lowerTeeth) + abs(tongue - other.tongue))
    }
}
