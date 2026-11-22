import Foundation

/// Public identifiers observed for the test receiver; not a voice-key mapping.
enum X6PreviewPolicy {
    static let vendorID = 0x1915
    static let productID = 0x1025
    static let bundleIdentifier = "com.hd838a.RemoteMic.X6Preview"
    static let storageDirectory = "SayAll-X6-Preview"

    static func matches(vendorID: Int, productID: Int) -> Bool {
        vendorID == self.vendorID && productID == self.productID
    }

    static func selectedInputIndex(uids: [String], selectedUID: String?) -> Int? {
        guard let selectedUID, !selectedUID.isEmpty else { return nil }
        let matches = uids.indices.filter { uids[$0] == selectedUID }
        return matches.count == 1 ? matches[0] : nil
    }

    static func isVirtualOutput(uid: String) -> Bool {
        uid == "MiRemoteV2ch_UID" || uid == "BlackHole2ch_UID"
    }

    static func isEligibleInput(uid: String, isUSB: Bool) -> Bool {
        isUSB && !uid.isEmpty && !isVirtualOutput(uid: uid)
    }

    static func keepCaptureAfterNotification(
        selectedID: UInt32, actualID: UInt32?, running: Bool,
        expectedRate: Double, actualRate: Double,
        expectedChannels: UInt32, actualChannels: UInt32
    ) -> Bool {
        actualID == selectedID && running && expectedRate > 0 &&
            expectedRate == actualRate && expectedChannels > 0 && expectedChannels == actualChannels
    }

    static func pcm16(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16((max(-1, min(1, value)) * Float(Int16.max)).rounded())
    }
}

/// Read-only HID observation. Values are held in memory, never injected or logged.
struct X6HIDObservationDecoder {
    struct Source: Hashable { let device: UInt64; let cookie: UInt32 }
    struct Key: Hashable, Codable { let page: UInt32; let usage: UInt32 }
    struct Edge: Equatable { let device: UInt64; let key: Key; let pressed: Bool }
    private var held: [Source: Key] = [:]

    mutating func update(source: Source, page: UInt32, usage: UInt32, value: Int, array: Bool) -> [Edge] {
        let nextUsage = array ? (value > 0 && UInt64(value) < UInt64(UInt32.max) ? UInt32(value) : 0) : usage
        let next: Key? = page > 0 && nextUsage > 0 && nextUsage != .max && (array || value != 0)
            ? Key(page: page, usage: nextUsage) : nil
        let previous = held[source]
        guard previous != next else { return [] }
        var edges: [Edge] = []
        held.removeValue(forKey: source)
        if let previous, !held.contains(where: { $0.key.device == source.device && $0.value == previous }) {
            edges.append(Edge(device: source.device, key: previous, pressed: false))
        }
        if let next {
            let alreadyHeld = held.contains { $0.key.device == source.device && $0.value == next }
            held[source] = next
            if !alreadyHeld { edges.append(Edge(device: source.device, key: next, pressed: true)) }
        }
        return edges
    }

    mutating func remove(device: UInt64) -> [Edge] {
        let keys = Set(held.filter { $0.key.device == device }.map(\.value))
        held = held.filter { $0.key.device != device }
        return keys.sorted { $0.page == $1.page ? $0.usage < $1.usage : $0.page < $1.page }
            .map { Edge(device: device, key: $0, pressed: false) }
    }
}

/// One configured action per physical press, including receivers exposing mirrored interfaces.
struct X6MappingRouter {
    struct Binding: Codable, Equatable {
        let key: X6HIDObservationDecoder.Key
        let name: String
        let action: String
        let shortcutCode: UInt16?
        let shortcutFlags: UInt
        let shortcutLabel: String
        var doubleAction: String? = nil
    }
    struct Result {
        var learned: X6HIDObservationDecoder.Key?
        var binding: Binding?
        var released: Binding?
    }
    var bindings: [Binding] = []
    static func adding(_ binding: Binding, to existing: [Binding]) -> [Binding]? {
        if let previous = existing.first(where: { $0.key == binding.key || $0.action == binding.action }) {
            return previous == binding ? existing : nil
        }
        return existing + [binding]
    }
    var enabled = false
    private(set) var learning = false
    private var held: [X6HIDObservationDecoder.Key: Set<UInt64>] = [:]
    private var resumeEnabledAfterSleep: Bool?

    mutating func armLearning() { enabled = false; learning = true }
    mutating func reset() { enabled = false; learning = false; held = [:]; resumeEnabledAfterSleep = nil }
    @discardableResult
    mutating func removeDevice(_ device: UInt64) -> [Binding] {
        let orphaned = Set(held.filter { $0.value == [device] }.map(\.key))
        held = held.mapValues { $0.subtracting([device]) }.filter { !$0.value.isEmpty }
        return bindings.filter { orphaned.contains($0.key) }
    }
    mutating func suspendForSleep() {
        if resumeEnabledAfterSleep == nil { resumeEnabledAfterSleep = enabled }
        enabled = false; learning = false; held = [:]
    }
    mutating func resumeAfterSleep() {
        guard let requested = resumeEnabledAfterSleep else { return }
        enabled = requested; resumeEnabledAfterSleep = nil
    }

    mutating func consume(_ edge: X6HIDObservationDecoder.Edge) -> Result {
        let first = held[edge.key, default: []].isEmpty
        if edge.pressed { held[edge.key, default: []].insert(edge.device) }
        else { held[edge.key]?.remove(edge.device) }
        if !edge.pressed, !first, held[edge.key, default: []].isEmpty, enabled {
            return Result(released: bindings.first { $0.key == edge.key })
        }
        guard edge.pressed, first,
              (edge.key.page == 7 && (4...231).contains(edge.key.usage)) ||
              (edge.key.page == 12 && edge.key.usage >= 0x20) else { return Result() }
        if learning {
            learning = false
            return Result(learned: edge.key)
        }
        return Result(binding: enabled ? bindings.first { $0.key == edge.key } : nil)
    }
}
