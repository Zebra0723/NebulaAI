import Foundation
import NebulaCore

/// The Create screen's designer: Claude (Sonnet 5.5, structured outputs) turns a description
/// into a gesture the recognizer can run, a held pose written as feature ranges, plus an
/// action from a short safe list. Tokens are spent only here; saved gestures run locally.
struct GestureDesigner {
    static let model = "claude-sonnet-5-5"
    let apiKey: String

    struct Design: Equatable {
        var spec: CustomGestureSpec
        /// What Claude says to you (sent through Comet).
        var reply: String
    }

    struct DesignError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// One turn of the conversation. `history` holds earlier user/assistant turns as text.
    func design(request: String, history: [(role: String, text: String)], existing: [String], clashes: [String]) async throws -> Design {
        var messages: [[String: Any]] = history.map { ["role": $0.role, "content": $0.text] }
        var turn = request
        if !clashes.isEmpty {
            turn += "\n\nYour last design failed the automatic checks against my recordings:\n- " + clashes.joined(separator: "\n- ")
                + "\nPropose a different movement that avoids this."
        }
        messages.append(["role": "user", "content": turn])

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "system": Self.system(existing: existing),
            "messages": messages,
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": Self.schema]],
            // If a safety classifier declines, the server re-runs it on its recommended fallback.
            "fallbacks": "default",
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw DesignError(message: status == 401 ? "That API key didn't work. Set one in Settings." : "Claude: \(message)")
        }
        if json["stop_reason"] as? String == "refusal" {
            throw DesignError(message: "Claude declined to design that one. Try describing it differently.")
        }
        guard let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let out = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw DesignError(message: "Claude's answer wasn't a gesture design.")
        }
        return try Self.parse(out)
    }

    static func parse(_ out: [String: Any]) throws -> Design {
        guard let name = out["name"] as? String, let movement = out["movement"] as? String,
              let reply = out["reply"] as? String, let conditions = out["conditions"] as? [[String: Any]],
              let action = out["action"] as? [String: Any], let kind = action["kind"] as? String,
              let value = action["value"] as? String else {
            throw DesignError(message: "Claude's design was missing a part.")
        }
        let rule = PoseRule(name: name, conditions: conditions.map {
            Condition(feature: $0["feature"] as? String ?? "", min: ($0["min"] as? NSNumber)?.floatValue,
                      max: ($0["max"] as? NSNumber)?.floatValue, band: ($0["band"] as? NSNumber)?.floatValue ?? 0.1)
        })
        let customAction: CustomAction
        switch kind {
        case "keys": customAction = .keys(value)
        case "window": customAction = .window(value)
        default: customAction = .galaxy(value)
        }
        let hold = min(max((out["hold"] as? NSNumber)?.doubleValue ?? 0.2, 0.15), 0.6)
        return Design(spec: CustomGestureSpec(name: name, movement: movement, rule: rule, action: customAction, hold: hold), reply: reply)
    }

    // MARK: - Prompt

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "name": ["type": "string"],
            "movement": ["type": "string"],
            "reply": ["type": "string"],
            "hold": ["type": "number"],
            "conditions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "feature": ["type": "string", "enum": Feature.allCases.filter { ![.velocityX, .velocityY, .speed, .roll, .posX, .posY, .handSize].contains($0) }.map(\.name)],
                        "min": ["type": ["number", "null"]],
                        "max": ["type": ["number", "null"]],
                        "band": ["type": "number"],
                    ],
                    "required": ["feature", "min", "max", "band"],
                    "additionalProperties": false,
                ],
            ],
            "action": [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": ["keys", "window", "galaxy"]],
                    "value": ["type": "string"],
                ],
                "required": ["kind", "value"],
                "additionalProperties": false,
            ],
        ],
        "required": ["name", "movement", "reply", "hold", "conditions", "action"],
        "additionalProperties": false,
    ]

    static func system(existing: [String]) -> String {
        """
        You design hand gestures for Nebula, a gesture-control app on the user's Mac. A webcam sees one hand as \
        21 joints; Nebula turns them into the features below and fires a gesture when every condition holds while \
        the hand is held still for `hold` seconds (0.15 to 0.6). Design one held pose and one action from the user's \
        description.

        Make the pose easy to hold, comfortable, unmistakable, and unlike every existing gesture and ordinary hand \
        movement (typing, mousing, resting, drinking, touching the face or hair, talking with the hands). A pose \
        that looks like an existing gesture or ordinary movement fails the automatic check and wastes the user's \
        time. If the user's own idea is likely to clash, propose something distinct and say why.

        Existing gestures (do not overlap these):
        \(existing.map { "- " + $0 }.joined(separator: "\n"))

        Features (one hand, mirrored into right-hand space, scaled by palm length):
        - curlThumb, curlIndex, curlMiddle, curlRing, curlLittle: bend summed over the finger's joints in units of π; \
        about 0–0.15 straight, 0.6+ curled.
        - straightThumb: thumb tip distance over its length; 1 straight, under 0.7 bent.
        - reachIndex, reachMiddle, reachRing, reachLittle: how far the fingertip rises past its knuckle along the \
        palm, in finger lengths; about 0.9–1.1 extended, 0.35 or less curled into a fist.
        - extThumb: thumb tip to index knuckle, palm lengths; over 0.55 when the thumb sticks out.
        - extIndex, extMiddle, extRing, extLittle: fingertip distance from the wrist, palm lengths (about 1.7–1.9 extended).
        - spreadThumbIndex, spreadIndexMiddle, spreadMiddleRing, spreadRingLittle: angle between neighbouring \
        fingers, radians; under 0.17 together, over 0.34 apart (a V).
        - thumbToIndex, thumbToMiddle, thumbToRing, thumbToLittle: thumb tip to each fingertip, palm lengths; under 0.3 touching.
        - palmFacing: positive when the palm faces the camera (about 0.5–1), negative for the back of the hand.
        - palmAxisX, palmAxisY: direction from wrist to middle knuckle; (0, 1) fingers up, (±1, 0) sideways.
        - thumbDirX, thumbDirY, indexDirX, indexDirY: unit direction the thumb or index points; thumbDirY 0.72+ is up, -0.72 or less is down.
        - facePresent (0 or 1), lipsDistance (index tip to lips, face widths; under 0.35 at the lips), earDistance \
        (palm to nearer ear, face widths), faceDY (palm height relative to face centre, face heights).
        - openness: mean reach of the four fingers.

        Each condition gives a min and/or a max (null for none) and a band, the tolerance beyond the range \
        (0.05–0.2; use about 0.1, or 0.05 for spreads). Use 3 to 8 conditions: enough to pin the pose down, \
        none that a natural variation of it would break.

        Actions (pick one):
        - kind "keys": a keyboard shortcut for the frontmost window only, value like "cmd+shift+t" (cmd, shift, \
        opt, ctrl; keys a–z, 0–9, punctuation, left, right, up, down, space, return, tab, escape, f1–f8, pageup, pagedown).
        - kind "window": value "next", "previous" or "playPause" (tab, slide, page or track in the frontmost window).
        - kind "galaxy": value "summonNova", "muteOrbit", "unmuteOrbit", "approve" or "reject".
        Nothing else: no global media keys, no switching apps or desktops.

        name: two or three words. movement: the exact movement in one sentence, as the user will perform it. \
        reply: a short, friendly message to the user (it arrives as a text message) stating the exact movement \
        and the exact action, and, if you changed their idea, why. Plain text, no emoji.
        """
    }
}
