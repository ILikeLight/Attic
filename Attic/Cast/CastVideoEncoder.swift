import CoreMedia
import Foundation
import Synchronization
import VideoToolbox

/// Turns frames into H.264 for a Chromecast with the hardware encoder, as quickly as it can:
/// low-latency rate control, no reordered frames, and a key frame only at the start, when the
/// receiver asks for one, and every ten seconds. Frames come out in Annex B form (start codes)
/// with the SPS and PPS in front of every key frame, which a receiver's decoder expects.
final class CastVideoEncoder: @unchecked Sendable {
    let width: Int
    let height: Int
    private var session: VTCompressionSession?
    private let wantsKeyFrame = Atomic(true)
    private let onFrame: (CastStreamer.Frame) -> Void

    /// `onFrame` runs on the encoder's own thread.
    init?(width: Int, height: Int, frameRate: Int, bitRate: Int, onFrame: @escaping (CastStreamer.Frame) -> Void) {
        self.width = width
        self.height = height
        self.onFrame = onFrame
        var made: VTCompressionSession?
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        if VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                      encoderSpecification: lowLatency, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                      outputCallback: nil, refcon: nil, compressionSessionOut: &made) != noErr {
            guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                             encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                             outputCallback: nil, refcon: nil, compressionSessionOut: &made) == noErr else { return nil }
        }
        guard let made else { return nil }
        session = made
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
            kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 10,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(made, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(made)
    }

    deinit {
        invalidate()
    }

    func requestKeyFrame() {
        wantsKeyFrame.store(true, ordering: .relaxed)
    }

    /// `time` is when the frame was made, in nanoseconds of uptime.
    func encode(_ pixelBuffer: CVPixelBuffer, time: UInt64) {
        guard let session else { return }
        let key = wantsKeyFrame.exchange(false, ordering: .relaxed)
        let options = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(time), timescale: 1_000_000_000),
                                        duration: .invalid, frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.deliver(sample, time: time)
        }
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    private func deliver(_ sample: CMSampleBuffer, time: UInt64) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyFrame = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let startCode: [UInt8] = [0, 0, 0, 1]
        var output = Data()
        var lengthSize: Int32 = 4
        if let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: &lengthSize)
            if keyFrame {
                for index in 0..<count {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                             parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                             nalUnitHeaderLengthOut: nil) == noErr,
                          let pointer else { continue }
                    output.append(contentsOf: startCode)
                    output.append(pointer, count: size)
                }
            }
        }
        // The encoder writes each NAL unit with its length in front (AVCC); Annex B wants a start code.
        let total = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: total)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: &bytes) == noErr else { return }
        let headerLength = Int(lengthSize)
        var offset = 0
        while offset + headerLength <= total {
            let length = bytes[offset..<offset + headerLength].reduce(0) { $0 << 8 | Int($1) }
            offset += headerLength
            guard length > 0, offset + length <= total else { break }
            output.append(contentsOf: startCode)
            output.append(contentsOf: bytes[offset..<offset + length])
            offset += length
        }
        onFrame(CastStreamer.Frame(data: output, keyFrame: keyFrame, time: time))
    }
}
