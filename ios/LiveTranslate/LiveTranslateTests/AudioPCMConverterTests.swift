import AVFAudio
import CoreMedia
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

    func testStreamingConversionAcceptsTemporaryNoOutputAndFinishesOnce() throws {
        let inputFormat = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let outputFormat = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        let converter = AudioPCMConverter(outputFormat: outputFormat)
        let shortChunk = try makeSampleBuffer(
            format: inputFormat,
            samples: Array(repeating: 0.01, count: 4),
            presentationValue: 0
        )
        let normalChunk = try makeSampleBuffer(
            format: inputFormat,
            samples: Array(repeating: 0.01, count: 480),
            presentationValue: 4
        )

        let firstOutput = try converter.convert(shortChunk)
        let secondOutput = try converter.convert(normalChunk)
        let tailOutputs = try converter.finish()

        XCTAssertEqual(firstOutput.format.sampleRate, 16_000)
        let tailFrameCount = tailOutputs.reduce(0) { $0 + Int($1.frameLength) }
        let totalFrameCount = Int(firstOutput.frameLength)
            + Int(secondOutput.frameLength)
            + tailFrameCount
        XCTAssertGreaterThan(totalFrameCount, 0)
        XCTAssertThrowsError(try converter.convert(normalChunk)) { error in
            guard case AudioPCMConverterError.finished = error else {
                return XCTFail("Expected finished, got \(error)")
            }
        }
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

    private func makeSampleBuffer(
        format: AVAudioFormat,
        samples: [Float],
        presentationValue: CMTimeValue
    ) throws -> CMSampleBuffer {
        let pcmBuffer = try makeBuffer(format: format, samples: samples)
        var streamDescription = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(formatStatus, noErr)
        let description = try XCTUnwrap(formatDescription)
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: presentationValue, timescale: 48_000),
            decodeTimeStamp: .invalid
        )
        let sampleBuffer = try CMSampleBuffer(
            dataBuffer: nil,
            formatDescription: description,
            numSamples: samples.count,
            sampleTimings: [timing],
            sampleSizes: []
        )
        try sampleBuffer.setDataBuffer(
            fromAudioBufferList: pcmBuffer.audioBufferList,
            flags: [.audioBufferListAssure16ByteAlignment]
        )
        try sampleBuffer.setDataReadiness(.ready)
        return sampleBuffer
    }
}
