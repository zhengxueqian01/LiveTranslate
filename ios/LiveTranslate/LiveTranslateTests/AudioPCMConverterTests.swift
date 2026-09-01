import AVFAudio
import XCTest
@testable import LiveTranslate

final class AudioPCMConverterTests: XCTestCase {
    func testAudibleEnergyDistinguishesSilenceFromTone() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let silentBuffer = try makeBuffer(format: format, samples: Array(repeating: 0, count: 480))
        let toneBuffer = try makeBuffer(format: format, samples: Array(repeating: 0.01, count: 480))

        XCTAssertFalse(AudioPCMConverter.hasAudibleEnergy(silentBuffer, threshold: 0.001))
        XCTAssertTrue(AudioPCMConverter.hasAudibleEnergy(toneBuffer, threshold: 0.001))
    }

    private func makeBuffer(format: AVAudioFormat, samples: [Float]) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
        buffer.frameLength = buffer.frameCapacity
        channel.update(from: samples, count: samples.count)
        return buffer
    }
}
