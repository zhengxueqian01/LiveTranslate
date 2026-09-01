import AVFAudio
import CoreMedia
import Foundation

private final class AudioConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer?
    private let exhaustedStatus: AVAudioConverterInputStatus
    private let lock = NSLock()
    private var didSupplyBuffer = false

    init(
        buffer: AVAudioPCMBuffer?,
        exhaustedStatus: AVAudioConverterInputStatus
    ) {
        self.buffer = buffer
        self.exhaustedStatus = exhaustedStatus
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            if let buffer, !didSupplyBuffer {
                didSupplyBuffer = true
                status.pointee = .haveData
                return buffer
            }
            status.pointee = exhaustedStatus
            return nil
        }
    }
}

enum AudioPCMConverterError: LocalizedError {
    case missingFormatDescription
    case missingStreamDescription
    case nonPCMFormat
    case invalidInputFormat
    case emptyBufferList
    case audioBufferExtractionFailed(OSStatus)
    case invalidFrameCount
    case converterUnavailable
    case outputBufferAllocationFailed
    case conversionFailed(String?)
    case inputFormatChanged
    case finished

    var errorDescription: String? {
        switch self {
        case .missingFormatDescription:
            "音频样本缺少格式描述。"
        case .missingStreamDescription:
            "音频样本缺少流格式描述。"
        case .nonPCMFormat:
            "ReplayKit 提供了非 PCM 音频，无法识别。"
        case .invalidInputFormat:
            "无法创建 ReplayKit 音频输入格式。"
        case .emptyBufferList:
            "ReplayKit 音频样本不包含可用数据。"
        case let .audioBufferExtractionFailed(status):
            "读取 ReplayKit 音频失败（OSStatus: \(status)）。"
        case .invalidFrameCount:
            "ReplayKit 音频样本帧数无效。"
        case .converterUnavailable:
            "系统无法创建所需的音频格式转换器。"
        case .outputBufferAllocationFailed:
            "系统无法分配语音识别音频缓冲区。"
        case let .conversionFailed(message):
            if let message {
                "音频格式转换失败：\(message)"
            } else {
                "音频格式转换失败。"
            }
        case .inputFormatChanged:
            "ReplayKit 音频格式在广播期间发生变化。"
        case .finished:
            "音频格式转换器已经结束。"
        }
    }
}

final class AudioPCMConverter {
    static let maximumTailOutputBufferCount = 32

    let outputFormat: AVAudioFormat

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var isFinished = false

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard !isFinished else {
            throw AudioPCMConverterError.finished
        }
        return try withInputBuffer(from: sampleBuffer) { inputBuffer, inputFormat in
            let converter = try streamingConverter(for: inputFormat)
            let outputBuffer = try makeOutputBuffer(
                inputFrameCount: inputBuffer.frameLength,
                inputSampleRate: inputFormat.sampleRate
            )
            let inputProvider = AudioConverterInputProvider(
                buffer: inputBuffer,
                exhaustedStatus: .noDataNow
            )
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                inputProvider.next(status: inputStatus)
            }
            guard status != .error,
                  status != .endOfStream,
                  conversionError == nil else {
                throw AudioPCMConverterError.conversionFailed(
                    conversionError?.localizedDescription
                )
            }
            return outputBuffer
        }
    }

    func finish() throws -> [AVAudioPCMBuffer] {
        guard !isFinished else { return [] }
        isFinished = true
        guard let converter else { return [] }

        var outputs: [AVAudioPCMBuffer] = []
        for _ in 0..<Self.maximumTailOutputBufferCount {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(max(1_024, Int(outputFormat.sampleRate / 10)))
            ) else {
                throw AudioPCMConverterError.outputBufferAllocationFailed
            }
            let inputProvider = AudioConverterInputProvider(
                buffer: nil,
                exhaustedStatus: .endOfStream
            )
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                inputProvider.next(status: inputStatus)
            }
            guard status != .error, conversionError == nil else {
                throw AudioPCMConverterError.conversionFailed(
                    conversionError?.localizedDescription
                )
            }
            if outputBuffer.frameLength > 0 {
                outputs.append(outputBuffer)
            }
            if status == .endOfStream {
                self.converter = nil
                inputFormat = nil
                return outputs
            }
        }
        throw AudioPCMConverterError.conversionFailed(
            "结束输入后转换器未在有限次数内完成。"
        )
    }

    private func withInputBuffer<Result>(
        from sampleBuffer: CMSampleBuffer,
        body: (AVAudioPCMBuffer, AVAudioFormat) throws -> Result
    ) throws -> Result {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw AudioPCMConverterError.missingFormatDescription
        }
        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw AudioPCMConverterError.missingStreamDescription
        }
        guard streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            throw AudioPCMConverterError.nonPCMFormat
        }
        guard let inputFormat = AVAudioFormat(streamDescription: streamDescription) else {
            throw AudioPCMConverterError.invalidInputFormat
        }

        var bufferListSize = 0
        let sizingStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: nil
        )
        guard sizingStatus == noErr || sizingStatus == kCMSampleBufferError_ArrayTooSmall else {
            throw AudioPCMConverterError.audioBufferExtractionFailed(sizingStatus)
        }
        guard bufferListSize >= MemoryLayout<AudioBufferList>.size else {
            throw AudioPCMConverterError.emptyBufferList
        }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }
        let bufferList = rawBufferList.assumingMemoryBound(to: AudioBufferList.self)
        var retainedBlockBuffer: CMBlockBuffer?
        let extractionStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard extractionStatus == noErr else {
            throw AudioPCMConverterError.audioBufferExtractionFailed(extractionStatus)
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard !buffers.isEmpty,
              buffers.allSatisfy({ $0.mData != nil && $0.mDataByteSize > 0 }) else {
            throw AudioPCMConverterError.emptyBufferList
        }
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            bufferListNoCopy: UnsafePointer(bufferList),
            deallocator: nil
        ) else {
            throw AudioPCMConverterError.emptyBufferList
        }

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0,
              sampleCount <= Int(inputBuffer.frameCapacity),
              inputFormat.sampleRate > 0,
              outputFormat.sampleRate > 0 else {
            throw AudioPCMConverterError.invalidFrameCount
        }
        inputBuffer.frameLength = AVAudioFrameCount(sampleCount)

        return try withExtendedLifetime(retainedBlockBuffer) {
            try body(inputBuffer, inputFormat)
        }
    }

    private func streamingConverter(for newInputFormat: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, let inputFormat {
            guard inputFormat.isEqual(newInputFormat) else {
                throw AudioPCMConverterError.inputFormatChanged
            }
            return converter
        }
        guard let converter = AVAudioConverter(from: newInputFormat, to: outputFormat) else {
            throw AudioPCMConverterError.converterUnavailable
        }
        converter.primeMethod = .none
        self.converter = converter
        inputFormat = newInputFormat
        return converter
    }

    private func makeOutputBuffer(
        inputFrameCount: AVAudioFrameCount,
        inputSampleRate: Double
    ) throws -> AVAudioPCMBuffer {
        let scaledFrameCount = ceil(
            Double(inputFrameCount) * outputFormat.sampleRate / inputSampleRate
        )
        guard scaledFrameCount.isFinite,
              scaledFrameCount > 0,
              scaledFrameCount <= Double(UInt32.max) else {
            throw AudioPCMConverterError.invalidFrameCount
        }
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(scaledFrameCount)
        ) else {
            throw AudioPCMConverterError.outputBufferAllocationFailed
        }
        return outputBuffer
    }

    static func hasAudibleEnergy(_ buffer: AVAudioPCMBuffer, threshold: Float) -> Bool {
        let threshold = max(0, threshold)
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            return buffers.contains { audioBuffer in
                containsFloat32Energy(audioBuffer, threshold: threshold)
            }
        case .pcmFormatFloat64:
            return buffers.contains { audioBuffer in
                containsFloat64Energy(audioBuffer, threshold: Double(threshold))
            }
        case .pcmFormatInt16:
            return buffers.contains { audioBuffer in
                containsInt16Energy(audioBuffer, threshold: threshold)
            }
        case .pcmFormatInt32:
            return buffers.contains { audioBuffer in
                containsInt32Energy(audioBuffer, threshold: threshold)
            }
        case .otherFormat:
            return false
        @unknown default:
            return false
        }
    }

    private static func containsFloat32Energy(_ buffer: AudioBuffer, threshold: Float) -> Bool {
        guard let data = buffer.mData else { return false }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
        let samples = data.assumingMemoryBound(to: Float.self)
        return (0..<count).contains { abs(samples[$0]) >= threshold }
    }

    private static func containsFloat64Energy(_ buffer: AudioBuffer, threshold: Double) -> Bool {
        guard let data = buffer.mData else { return false }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Double>.stride
        let samples = data.assumingMemoryBound(to: Double.self)
        return (0..<count).contains { abs(samples[$0]) >= threshold }
    }

    private static func containsInt16Energy(_ buffer: AudioBuffer, threshold: Float) -> Bool {
        guard let data = buffer.mData else { return false }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.stride
        let samples = data.assumingMemoryBound(to: Int16.self)
        return (0..<count).contains {
            abs(Float(samples[$0]) / Float(Int16.max)) >= threshold
        }
    }

    private static func containsInt32Energy(_ buffer: AudioBuffer, threshold: Float) -> Bool {
        guard let data = buffer.mData else { return false }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Int32>.stride
        let samples = data.assumingMemoryBound(to: Int32.self)
        return (0..<count).contains {
            abs(Double(samples[$0]) / Double(Int32.max)) >= Double(threshold)
        }
    }
}
