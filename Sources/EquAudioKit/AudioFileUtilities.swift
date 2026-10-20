import AudioToolbox
import Foundation

// Offline audio helpers used by the tests and the app's self-test: file I/O, level analysis and
// test signals. Not for the audio thread.

public struct AudioFileError: LocalizedError, Equatable {
    public let operation: String
    public let path: String
    public let status: OSStatus

    public var errorDescription: String? {
        "Could not \(operation) “\((path as NSString).lastPathComponent)” (\(RecorderError.describe(status)))."
    }
}

/// Planar audio in memory.
public struct AudioSamples: Equatable, Sendable {
    /// One array per channel, all of `frameCount` samples.
    public var channels: [[Float]]
    public var sampleRate: Double

    public init(channels: [[Float]], sampleRate: Double) {
        self.channels = channels
        self.sampleRate = sampleRate
    }

    public var channelCount: Int { channels.count }
    public var frameCount: Int { channels.first?.count ?? 0 }
    public var duration: TimeInterval { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
}

/// What an audio file contains, as stored.
public struct AudioFileInfo: Equatable, Sendable {
    /// e.g. `kAudioFileWAVEType`, `kAudioFileM4AType`, `kAudioFileFLACType`.
    public var fileType: AudioFileTypeID
    /// e.g. `kAudioFormatLinearPCM`, `kAudioFormatAppleLossless`, `kAudioFormatFLAC`.
    public var formatID: AudioFormatID
    public var sampleRate: Double
    public var channelCount: Int
    /// Bits per sample (PCM) or encoded source bit depth (Apple Lossless, FLAC); 0 if unknown.
    public var bitDepth: Int
    public var isFloat: Bool
    public var frameCount: Int64
    public var duration: TimeInterval { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
}

public enum AudioFileUtilities {
    /// Format, length and container of an audio file.
    public static func info(of url: URL) throws -> AudioFileInfo {
        let file = try open(url)
        defer { ExtAudioFileDispose(file) }
        let format = try fileDataFormat(file, url)
        var frames: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames), "read the length of", url)
        var audioFile: AudioFileID?
        size = UInt32(MemoryLayout<AudioFileID?>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioFile, &size, &audioFile), "inspect", url)
        var fileType: AudioFileTypeID = 0
        if let audioFile {
            size = UInt32(MemoryLayout<AudioFileTypeID>.size)
            try check(AudioFileGetProperty(audioFile, kAudioFilePropertyFileFormat, &size, &fileType), "inspect", url)
        }
        let bitDepth: Int
        switch format.mFormatID {
        case kAudioFormatLinearPCM:
            bitDepth = Int(format.mBitsPerChannel)
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            bitDepth = [1: 16, 2: 20, 3: 24, 4: 32][format.mFormatFlags] ?? 0
        default:
            bitDepth = 0
        }
        return AudioFileInfo(fileType: fileType, formatID: format.mFormatID, sampleRate: format.mSampleRate,
                             channelCount: Int(format.mChannelsPerFrame), bitDepth: bitDepth,
                             isFloat: format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                             frameCount: frames)
    }

    /// Decodes any file Core Audio can read into planar float32 at the file's own sample rate.
    public static func read(_ url: URL) throws -> AudioSamples {
        let file = try open(url)
        defer { ExtAudioFileDispose(file) }
        let format = try fileDataFormat(file, url)
        let channelCount = Int(format.mChannelsPerFrame)
        guard channelCount > 0, format.mSampleRate > 0 else {
            throw AudioFileError(operation: "read", path: url.path, status: kAudioFileUnsupportedDataFormatError)
        }
        var client = AudioStreamBasicDescription(
            mSampleRate: format.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channelCount), mBitsPerChannel: 32, mReserved: 0)
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client), "decode", url)
        var expected: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        _ = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &expected)

        let chunk = 16384
        var channels = [[Float]](repeating: [], count: channelCount)
        for index in channels.indices { channels[index].reserveCapacity(Int(max(expected, 0))) }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: chunk * channelCount)
        let buffers = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer {
            scratch.deallocate()
            free(buffers.unsafeMutablePointer) // AudioBufferList.allocate uses calloc
        }
        while true {
            for channel in 0..<channelCount {
                buffers[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(chunk * 4),
                                               mData: UnsafeMutableRawPointer(scratch + channel * chunk))
            }
            var frames = UInt32(chunk)
            try check(ExtAudioFileRead(file, &frames, buffers.unsafeMutablePointer), "read", url)
            if frames == 0 { break }
            for channel in 0..<channelCount {
                channels[channel].append(contentsOf: UnsafeBufferPointer(start: scratch + channel * chunk, count: Int(frames)))
            }
        }
        return AudioSamples(channels: channels, sampleRate: format.mSampleRate)
    }

    /// Writes planar samples as an IEEE-float 32-bit WAV file (atomically). All channels must have
    /// the same length; the data must stay below the 4 GiB RIFF limit.
    public static func writeWAVFloat32(_ url: URL, channels: [[Float]], sampleRate: Double) throws {
        let channelCount = channels.count
        let frames = channels.first?.count ?? 0
        let rate = sampleRate.isFinite ? UInt32(exactly: sampleRate.rounded()) ?? 0 : 0
        let dataBytes = frames * channelCount * 4
        guard channelCount > 0, channelCount <= 1024, channels.allSatisfy({ $0.count == frames }),
              (1...1_000_000).contains(rate), dataBytes <= Int(UInt32.max) - 64 else {
            throw AudioFileError(operation: "write", path: url.path, status: OSStatus(paramErr))
        }
        var data = Data()
        data.reserveCapacity(58 + dataBytes)
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let blockAlign = UInt16(channelCount * 4)
        append("RIFF"); append32(UInt32(50 + dataBytes)); append("WAVE")
        // fmt chunk with cbSize (18 bytes) and a fact chunk, as required for non-PCM WAVE formats.
        append("fmt "); append32(18); append16(3) // WAVE_FORMAT_IEEE_FLOAT
        append16(UInt16(channelCount)); append32(rate); append32(rate * UInt32(blockAlign))
        append16(blockAlign); append16(32); append16(0)
        append("fact"); append32(4); append32(UInt32(frames))
        append("data"); append32(UInt32(dataBytes))
        var interleaved = [UInt32](repeating: 0, count: frames * channelCount)
        for (channel, samples) in channels.enumerated() {
            for frame in 0..<frames { interleaved[frame * channelCount + channel] = samples[frame].bitPattern.littleEndian }
        }
        interleaved.withUnsafeBytes { data.append(contentsOf: $0) }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw AudioFileError(operation: "write", path: url.path, status: OSStatus(ioErr))
        }
    }

    // MARK: Private

    private static func open(_ url: URL) throws -> ExtAudioFileRef {
        var file: ExtAudioFileRef?
        let status = ExtAudioFileOpenURL(url as CFURL, &file)
        guard status == noErr, let file else { throw AudioFileError(operation: "open", path: url.path, status: status) }
        return file
    }

    private static func fileDataFormat(_ file: ExtAudioFileRef, _ url: URL) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format), "inspect", url)
        return format
    }

    private static func check(_ status: OSStatus, _ operation: String, _ url: URL) throws {
        if status != noErr { throw AudioFileError(operation: operation, path: url.path, status: status) }
    }
}

/// Level measurements on sample buffers.
public enum AudioAnalysis {
    /// Level of the component at `frequency` as dBFS of a sine's peak amplitude (a full-scale sine
    /// reads 0). Hann-windowed Goertzel, so other tones more than a few bins away do not leak in;
    /// use at least ~10 periods of the lowest frequency of interest. Silence reads -200.
    public static func goertzelLevelDB<C: Collection>(samples: C, frequency: Double, sampleRate: Double) -> Double
        where C.Element == Float {
        let count = samples.count
        guard count > 1, sampleRate > 0, frequency >= 0 else { return -200 }
        let omega = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
        let windowStep = 2 * Double.pi / Double(count - 1)
        var s1 = 0.0, s2 = 0.0, windowSum = 0.0
        var index = 0
        for sample in samples {
            let window = 0.5 - 0.5 * cos(windowStep * Double(index))
            windowSum += window
            let s0 = Double(sample) * window + coefficient * s1 - s2
            s2 = s1
            s1 = s0
            index += 1
        }
        let power = max(s1 * s1 + s2 * s2 - coefficient * s1 * s2, 0)
        let amplitude = 2 * power.squareRoot() / windowSum
        return amplitude > 1e-10 ? 20 * log10(amplitude) : -200
    }

    /// RMS level in dBFS (a full-scale sine reads -3.01). Silence reads -200.
    public static func rmsDB<C: Collection>(_ samples: C) -> Double where C.Element == Float {
        guard !samples.isEmpty else { return -200 }
        let meanSquare = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return meanSquare > 1e-20 ? 10 * log10(meanSquare) : -200
    }

    /// Largest absolute sample value (linear).
    public static func peak<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        samples.reduce(0) { max($0, abs($1)) }
    }
}

/// Deterministic test signals.
public enum TestSignal {
    /// Mono sum of sines, each with peak amplitude `levelDBFS`, faded in and out over `fade` seconds
    /// (raised cosine). Schroeder phases keep the crest factor of the sum low.
    public static func multiTone(frequencies: [Double], levelDBFS: Double, seconds: Double, sampleRate: Double,
                                 fade: Double = 0.01) -> [Float] {
        let frames = max(Int((seconds * sampleRate).rounded()), 0)
        guard frames > 0, sampleRate > 0 else { return [] }
        let amplitude = pow(10, levelDBFS / 20)
        let count = Double(max(frequencies.count, 1))
        let tones = frequencies.enumerated().map { index, frequency in
            (omega: 2 * Double.pi * frequency / sampleRate, phase: Double.pi * Double(index * (index + 1)) / count)
        }
        let fadeFrames = min(max(Int(fade * sampleRate), 0), frames / 2)
        var output = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var value = 0.0
            for tone in tones { value += sin(tone.omega * Double(frame) + tone.phase) }
            var gain = amplitude
            if fadeFrames > 0 {
                let edge = min(frame, frames - 1 - frame)
                if edge < fadeFrames { gain *= 0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(fadeFrames)) }
            }
            output[frame] = Float(value * gain)
        }
        return output
    }
}
