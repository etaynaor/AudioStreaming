import AVFoundation
@testable import AudioStreaming
import XCTest

final class DecodedAudioFilterProcessorTests: XCTestCase {
    func testNamedEntryReplacementAndRemoval() throws {
        let processor = DecodedAudioFilterProcessor()
        let buffer = try makeBuffer(frameLength: 16)
        var observed: [String] = []

        processor.add(entry: "meter") { _ in
            observed.append("old")
        }
        processor.add(entry: "meter") { received in
            observed.append("new:\(received.frameLength)")
        }

        XCTAssertTrue(processor.hasEntries)
        processor.process(buffer: buffer)
        XCTAssertEqual(observed, ["new:16"])

        processor.remove(entry: "meter")
        XCTAssertFalse(processor.hasEntries)
        processor.process(buffer: buffer)
        XCTAssertEqual(observed, ["new:16"])
    }

    func testCallbackCanRemoveItselfWithoutDeadlocking() throws {
        let processor = DecodedAudioFilterProcessor()
        let buffer = try makeBuffer(frameLength: 8)
        var callbackCount = 0

        processor.add(entry: "one-shot") { _ in
            callbackCount += 1
            processor.remove(entry: "one-shot")
        }

        processor.process(buffer: buffer)
        processor.process(buffer: buffer)

        XCTAssertEqual(callbackCount, 1)
        XCTAssertFalse(processor.hasEntries)
    }

    func testAudioPlayerExposesDecodedAudioFiltering() {
        let player = AudioPlayer()
        var callbackCount = 0

        player.decodedAudioFiltering.add(entry: "test") { _ in
            callbackCount += 1
        }

        XCTAssertTrue(player.decodedAudioFiltering.hasEntries)
        player.decodedAudioFiltering.removeAll()
        XCTAssertFalse(player.decodedAudioFiltering.hasEntries)
        XCTAssertEqual(callbackCount, 0)
    }

    private func makeBuffer(frameLength: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44_100,
                channels: 2,
                interleaved: true
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)
        )
        buffer.frameLength = frameLength
        return buffer
    }
}
