// The v1 gestures, exactly as NEBULA_PLAN.md defines them, and the hand
// shapes ("poses") they're built from.

/// A hand shape both judges can recognize in a single frame. Gestures are
/// poses plus time: held still, moved, or tracked continuously.
public enum Pose: Int, CaseIterable, Sendable, Codable {
    case nothing = 0
    /// Fingers extended and together, palm to the screen.
    case flat
    /// Fingers extended, spread or not (a waving hand).
    case open
    case thumbsUp
    case thumbsDown
    /// Index and middle up in a V.
    case peace
    /// Index and middle up and together.
    case scroll
    /// Index up against the lips.
    case lips
    /// Cupped hand at the ear.
    case ear
    /// Thumb and index pinched on an imaginary knob.
    case pinch

    public static let builtinCount = 10
    public var name: String { "\(self)" }
}

public enum GestureKind: String, Sendable, Codable {
    /// Fires after a short hold.
    case held
    /// Fires on the frame the movement completes.
    case movement
    /// Engages after a short hold, then updates every frame.
    case continuous
}

public enum Gesture: String, CaseIterable, Sendable, Codable {
    case openPalm, thumbsUp, thumbsDown, peace, fingerToLips, handToEar
    case swipeLeft, swipeRight, scroll, volumeKnob, wave

    public static let count = 11
    /// Built once: `allCases` builds a new array every time it's read.
    public static let all: [Gesture] = allCases
    public static func at(_ i: Int) -> Gesture { all[i] }

    /// A stable small integer, cheap enough for the per-frame path.
    public var index: Int {
        switch self {
        case .openPalm: return 0
        case .thumbsUp: return 1
        case .thumbsDown: return 2
        case .peace: return 3
        case .fingerToLips: return 4
        case .handToEar: return 5
        case .swipeLeft: return 6
        case .swipeRight: return 7
        case .scroll: return 8
        case .volumeKnob: return 9
        case .wave: return 10
        }
    }

    public var kind: GestureKind {
        switch self {
        case .openPalm, .thumbsUp, .thumbsDown, .peace, .fingerToLips, .handToEar: return .held
        case .swipeLeft, .swipeRight, .wave: return .movement
        case .scroll, .volumeKnob: return .continuous
        }
    }

    /// The pose both judges must agree on.
    public var pose: Pose {
        switch self {
        case .openPalm, .swipeLeft, .swipeRight: return .flat
        case .wave: return .open
        case .thumbsUp: return .thumbsUp
        case .thumbsDown: return .thumbsDown
        case .peace: return .peace
        case .fingerToLips: return .lips
        case .handToEar: return .ear
        case .scroll: return .scroll
        case .volumeKnob: return .pinch
        }
    }

    public var title: String {
        switch self {
        case .openPalm: return "Open palm"
        case .thumbsUp: return "Thumbs up"
        case .thumbsDown: return "Thumbs down"
        case .peace: return "Peace sign"
        case .fingerToLips: return "Finger to lips"
        case .handToEar: return "Hand to ear"
        case .swipeLeft: return "Swipe left"
        case .swipeRight: return "Swipe right"
        case .scroll: return "Scroll"
        case .volumeKnob: return "Volume knob"
        case .wave: return "Wave"
        }
    }

    /// The exact movement, from the plan.
    public var movement: String {
        switch self {
        case .openPalm: return "Flat hand, fingers together, palm to the screen, held still"
        case .thumbsUp: return "Fist, thumb up, held"
        case .thumbsDown: return "Fist, thumb down, held"
        case .peace: return "Index and middle up in a V, palm to the screen, held"
        case .fingerToLips: return "Index finger up, held against the lips"
        case .handToEar: return "Cupped hand behind the ear, held"
        case .swipeLeft: return "Open flat hand moved quickly to your left, about shoulder width"
        case .swipeRight: return "Open flat hand moved quickly to your right, about shoulder width"
        case .scroll: return "Index and middle together and up, palm to the screen, hand moved up or down; curl the fingers or drop the hand to stop"
        case .volumeKnob: return "Thumb and index pinched as if holding a small knob, then a wrist twist: clockwise for up, counter-clockwise for down"
        case .wave: return "Open hand waved side to side 2–3 times"
        }
    }

    /// The action, from the plan.
    public var action: String {
        switch self {
        case .openPalm: return "Play or pause media in the frontmost window"
        case .thumbsUp: return "Approve the pending Galaxy approval"
        case .thumbsDown: return "Reject the pending Galaxy approval"
        case .peace: return "Summon Nova (⌃Space)"
        case .fingerToLips: return "Mute Orbit until unmuted"
        case .handToEar: return "Unmute Orbit"
        case .swipeLeft: return "Previous tab, slide, page or track in the frontmost window"
        case .swipeRight: return "Next tab, slide, page or track in the frontmost window"
        case .scroll: return "Scroll the frontmost window, speed following the hand"
        case .volumeKnob: return "Mac volume"
        case .wave: return "Disarm Nebula"
        }
    }

    /// Whether the action is tied to the frontmost window. Galaxy gestures and the
    /// volume knob are the only ones that aren't.
    public var targetsWindow: Bool {
        switch self {
        case .openPalm, .swipeLeft, .swipeRight, .scroll: return true
        case .thumbsUp, .thumbsDown, .peace, .fingerToLips, .handToEar, .volumeKnob, .wave: return false
        }
    }
}

/// The gesture pairs most likely to be confused, which the report checks one by one.
public let riskyPairs: [(String, [String])] = [
    ("open palm vs swipe vs wave", ["openPalm", "swipeLeft", "swipeRight", "wave"]),
    ("peace (V) vs scroll (together)", ["peace", "scroll"]),
    ("finger to lips vs scroll", ["fingerToLips", "scroll"]),
    ("thumbs up vs thumbs down", ["thumbsUp", "thumbsDown"]),
    ("hand to ear vs touching hair or face", ["handToEar", "nothing"]),
    ("volume knob vs other poses", ["volumeKnob", "thumbsUp", "fingerToLips"]),
]
