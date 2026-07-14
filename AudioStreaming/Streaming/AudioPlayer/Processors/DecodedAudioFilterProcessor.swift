//
//  DecodedAudioFilterProcessor.swift
//  AudioStreaming
//

import AVFoundation

/// A synchronous observation callback for canonical PCM frames immediately
/// after decoding and before they become eligible for rendering.
///
/// The buffer is owned by AudioStreaming and is valid only for the duration of
/// the callback. Callers must copy anything they need to retain. The callback
/// runs on the player's source queue, not the real-time render thread.
public typealias DecodedAudioFilterCallback = (_ buffer: AVAudioPCMBuffer) -> Void

public struct DecodedAudioFilterEntry: Equatable {
    public let name: String
    public let filter: DecodedAudioFilterCallback

    public init(name: String, filter: @escaping DecodedAudioFilterCallback) {
        self.name = name
        self.filter = filter
    }

    public static func == (
        lhs: DecodedAudioFilterEntry,
        rhs: DecodedAudioFilterEntry
    ) -> Bool {
        lhs.name == rhs.name
    }
}

public protocol DecodedAudioFiltering: AnyObject {
    var hasEntries: Bool { get }
    func add(entry: DecodedAudioFilterEntry)
    func add(entry named: String, filter: @escaping DecodedAudioFilterCallback)
    func remove(entry named: String)
    func removeAll()
}

final class DecodedAudioFilterProcessor: DecodedAudioFiltering {
    private let lock = UnfairLock()
    private var entries: [DecodedAudioFilterEntry] = []

    var hasEntries: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !entries.isEmpty
    }

    func add(entry: DecodedAudioFilterEntry) {
        lock.lock()
        entries.removeAll { $0.name == entry.name }
        entries.append(entry)
        lock.unlock()
    }

    func add(
        entry named: String,
        filter: @escaping DecodedAudioFilterCallback
    ) {
        add(entry: DecodedAudioFilterEntry(name: named, filter: filter))
    }

    func remove(entry named: String) {
        lock.lock()
        entries.removeAll { $0.name == named }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    func process(buffer: AVAudioPCMBuffer) {
        // Never hold the lock while invoking client code. A callback may remove
        // itself after collecting the pre-playback window.
        lock.lock()
        let currentEntries = entries
        lock.unlock()
        for entry in currentEntries {
            entry.filter(buffer)
        }
    }
}
