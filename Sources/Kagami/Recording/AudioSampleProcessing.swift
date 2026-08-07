import AVFoundation
import CoreMedia

/// Prepares microphone samples for AVAssetWriter and level metering.
/// Pro audio interfaces (e.g. Focusrite 18i20) often deliver many channels;
/// we downmix to stereo only when needed and never drop samples silently.
enum AudioSampleProcessing {
    static let outputSampleRate: Double = 48_000
    static let outputChannelCount: AVAudioChannelCount = 2
    private static let monoSpreadThreshold: Float = 0.02

    private static let stereoInt16Format: AVAudioFormat? = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: outputSampleRate,
        channels: outputChannelCount,
        interleaved: true
    )

    // MARK: - Writer

    /// Returns a buffer safe to append to the AAC writer input.
    /// Stereo/native input is passed through; multi-channel input is downmixed.
    static func prepareForWriter(
        from sampleBuffer: CMSampleBuffer,
        presentationTimeStamp: CMTime? = nil
    ) -> CMSampleBuffer {
        let channels = audioChannelCount(in: sampleBuffer)
        if channels <= 2 {
            if let pts = presentationTimeStamp, let copy = retimedCopy(of: sampleBuffer, presentationTimeStamp: pts) {
                return copy
            }
            return sampleBuffer
        }

        if let converted = downmixSampleBuffer(from: sampleBuffer, presentationTimeStamp: presentationTimeStamp) {
            return converted
        }

        // Last resort — append original rather than lose the recording.
        print("Recording: downmix failed for \(channels)-ch audio, appending source buffer")
        return sampleBuffer
    }

    // MARK: - Level metering

    static func peakLevel(in sampleBuffer: CMSampleBuffer) -> Float {
        guard let layout = readChannelSamples(from: sampleBuffer, maxChannels: 2) else { return 0 }

        var peak: Float = 0
        for i in 0..<layout.frameCount {
            peak = max(peak, abs(layout.channels[0][i]))
            if layout.channels.count > 1 {
                peak = max(peak, abs(layout.channels[1][i]))
            }
        }
        return min(1, peak * 2.5)
    }

    // MARK: - Downmix

    private static func downmixSampleBuffer(
        from sampleBuffer: CMSampleBuffer,
        presentationTimeStamp: CMTime?
    ) -> CMSampleBuffer? {
        guard var layout = readChannelSamples(from: sampleBuffer, maxChannels: 2) else { return nil }

        spreadMonoIfNeeded(&layout)

        let frames = layout.frameCount
        guard frames > 0, let outputFormat = stereoInt16Format else { return nil }

        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let outData = output.int16ChannelData?[0]
        else { return nil }

        output.frameLength = AVAudioFrameCount(frames)
        let left = layout.channels[0]
        let right = layout.channels.count > 1 ? layout.channels[1] : left

        for i in 0..<frames {
            outData[i * 2]     = floatToInt16(left[i])
            outData[i * 2 + 1] = floatToInt16(right[i])
        }

        let pts = presentationTimeStamp ?? sampleBuffer.presentationTimeStamp
        return cmsSampleBuffer(from: output, presentationTimeStamp: pts, duration: sampleBuffer.duration)
    }

    // MARK: - Channel reading

    private struct ChannelLayout {
        var channels: [[Float]]
        var frameCount: Int
    }

    private static func readChannelSamples(
        from sampleBuffer: CMSampleBuffer,
        maxChannels: Int
    ) -> ChannelLayout? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        let asbd = asbdPtr.pointee
        let channelCount = Int(asbd.mChannelsPerFrame)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let isCompressed = asbd.mFormatID != kAudioFormatLinearPCM

        if isCompressed {
            return readCompressedPeakSamples(from: sampleBuffer, maxChannels: maxChannels)
        }

        guard let bufferList = copyAudioBufferList(from: sampleBuffer) else { return nil }
        defer { bufferList.deallocate() }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard !buffers.isEmpty else { return nil }

        let channelsToRead = min(maxChannels, channelCount)
        let frameCount = frameCount(in: buffers, channelCount: channelCount, isInterleaved: isInterleaved, isFloat: isFloat)
        guard frameCount > 0 else { return nil }

        var channels = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: channelsToRead)

        if isInterleaved {
            guard let data = buffers[0].mData else { return nil }
            if isFloat {
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount {
                    for ch in 0..<channelsToRead {
                        channels[ch][frame] = samples[frame * channelCount + ch]
                    }
                }
            } else {
                let samples = data.assumingMemoryBound(to: Int16.self)
                for frame in 0..<frameCount {
                    for ch in 0..<channelsToRead {
                        channels[ch][frame] = Float(samples[frame * channelCount + ch]) / 32_768
                    }
                }
            }
        } else {
            for ch in 0..<min(channelsToRead, buffers.count) {
                guard let data = buffers[ch].mData else { continue }
                let framesInBuffer = Int(buffers[ch].mDataByteSize) / (isFloat ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size)
                let count = min(frameCount, framesInBuffer)
                if isFloat {
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<count { channels[ch][frame] = samples[frame] }
                } else {
                    let samples = data.assumingMemoryBound(to: Int16.self)
                    for frame in 0..<count { channels[ch][frame] = Float(samples[frame]) / 32_768 }
                }
            }
        }

        return ChannelLayout(channels: channels, frameCount: frameCount)
    }

    private static func readCompressedPeakSamples(
        from sampleBuffer: CMSampleBuffer,
        maxChannels: Int
    ) -> ChannelLayout? {
        // Compressed (e.g. AAC) — fall back to PCM copy for metering only.
        guard let (pcm, _) = pcmBuffer(from: sampleBuffer) else { return nil }
        let frames = Int(pcm.frameLength)
        guard frames > 0 else { return nil }

        var channels: [[Float]] = []
        let count = min(maxChannels, Int(pcm.format.channelCount))

        if let floatData = pcm.floatChannelData {
            if pcm.format.isInterleaved {
                var left  = [Float](repeating: 0, count: frames)
                var right = [Float](repeating: 0, count: frames)
                let chCount = Int(pcm.format.channelCount)
                for frame in 0..<frames {
                    left[frame] = floatData[0][frame * chCount]
                    if chCount > 1 { right[frame] = floatData[0][frame * chCount + 1] }
                }
                channels = [left, right]
            } else {
                for ch in 0..<count {
                    channels.append(Array(UnsafeBufferPointer(start: floatData[ch], count: frames)))
                }
            }
        } else if let int16Data = pcm.int16ChannelData {
            if pcm.format.isInterleaved {
                var left  = [Float](repeating: 0, count: frames)
                var right = [Float](repeating: 0, count: frames)
                let chCount = Int(pcm.format.channelCount)
                for frame in 0..<frames {
                    left[frame] = Float(int16Data[0][frame * chCount]) / 32_768
                    if chCount > 1 { right[frame] = Float(int16Data[0][frame * chCount + 1]) / 32_768 }
                }
                channels = [left, right]
            } else {
                for ch in 0..<count {
                    channels.append((0..<frames).map { Float(int16Data[ch][$0]) / 32_768 })
                }
            }
        }

        guard !channels.isEmpty else { return nil }
        return ChannelLayout(channels: channels, frameCount: frames)
    }

    private static func frameCount(
        in buffers: UnsafeMutableAudioBufferListPointer,
        channelCount: Int,
        isInterleaved: Bool,
        isFloat: Bool
    ) -> Int {
        let bytesPerSample = isFloat ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size
        guard let first = buffers.first else { return 0 }
        if isInterleaved {
            return Int(first.mDataByteSize) / max(1, bytesPerSample * channelCount)
        }
        return Int(first.mDataByteSize) / bytesPerSample
    }

    private static func copyAudioBufferList(from sampleBuffer: CMSampleBuffer) -> UnsafeMutablePointer<AudioBufferList>? {
        var bufferListSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard bufferListSize > 0 else { return nil }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard status == noErr else {
            bufferList.deallocate()
            return nil
        }
        return bufferList
    }

    private static func spreadMonoIfNeeded(_ layout: inout ChannelLayout) {
        guard layout.channels.count >= 1 else { return }
        let left = layout.channels[0]
        let right = layout.channels.count > 1 ? layout.channels[1] : left

        var peakL: Float = 0
        var peakR: Float = 0
        for i in 0..<layout.frameCount {
            peakL = max(peakL, abs(left[i]))
            if layout.channels.count > 1 {
                peakR = max(peakR, abs(right[i]))
            }
        }

        guard peakL > 0 || peakR > 0 else { return }

        if layout.channels.count == 1 || peakR < peakL * monoSpreadThreshold {
            layout.channels = [left, left]
        } else if peakL < peakR * monoSpreadThreshold {
            layout.channels = [right, right]
        }
    }

    // MARK: - Helpers

    private static func audioChannelCount(in sampleBuffer: CMSampleBuffer) -> Int {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        else { return 2 }
        return max(1, Int(asbd.pointee.mChannelsPerFrame))
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> (AVAudioPCMBuffer, AVAudioFormat)? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              let inputFormat = AVAudioFormat(streamDescription: &asbd)
        else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount)
        else { return nil }

        pcmBuffer.frameLength = frameCount
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: pcmBuffer.mutableAudioBufferList
        ) == noErr else { return nil }

        return (pcmBuffer, inputFormat)
    }

    private static func cmsSampleBuffer(
        from pcm: AVAudioPCMBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime
    ) -> CMSampleBuffer? {
        guard let formatDescription = pcm.format.cmFormatDescription else { return nil }

        let frames = Int(pcm.frameLength)
        let byteCount = frames * Int(outputChannelCount) * MemoryLayout<Int16>.size
        guard let channelData = pcm.int16ChannelData?[0] else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return nil }

        CMBlockBufferReplaceDataBytes(
            with: channelData,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )

        let timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: [timing],
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        return sampleBuffer
    }

    private static func retimedCopy(
        of sampleBuffer: CMSampleBuffer,
        presentationTimeStamp: CMTime
    ) -> CMSampleBuffer? {
        let timing = CMSampleTimingInfo(
            duration: sampleBuffer.duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: sampleBuffer.decodeTimeStamp
        )
        return try? CMSampleBuffer(copying: sampleBuffer, withNewTiming: [timing])
    }

    private static func floatToInt16(_ sample: Float) -> Int16 {
        Int16(clamping: Int32((max(-1, min(1, sample)) * 32_767).rounded()))
    }
}

private extension AVAudioFormat {
    var cmFormatDescription: CMAudioFormatDescription? {
        var asbd = streamDescription.pointee
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        ) == noErr else { return nil }
        return description
    }
}
