// Decodes the frames fake_receiver.py put together (frames.bin) with VideoToolbox, to check
// that what Attic sends is H.264 a receiver can play, and saves one frame in the middle and
// the last one as PNG.
// Usage: xcrun swift TestPrograms/chromecast/decode_check.swift <folder with frames.bin>
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import VideoToolbox

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let data = [UInt8](try Data(contentsOf: folder.appendingPathComponent("frames.bin")))
var frames: [[UInt8]] = []
var offset = 0
while offset + 4 <= data.count {
    let length = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
    frames.append(Array(data[offset + 4..<offset + 4 + length]))
    offset += 4 + length
}

/// The NAL units of an Annex B frame.
func units(_ frame: [UInt8]) -> [[UInt8]] {
    var starts: [Int] = []
    var index = 0
    while index + 3 < frame.count {
        if frame[index] == 0, frame[index + 1] == 0, frame[index + 2] == 0, frame[index + 3] == 1 {
            starts.append(index + 4)
            index += 4
        } else {
            index += 1
        }
    }
    return starts.enumerated().map { number, start in
        let end = number + 1 < starts.count ? starts[number + 1] - 4 : frame.count
        return Array(frame[start..<end])
    }
}

var format: CMVideoFormatDescription?
var session: VTDecompressionSession?
var decoded = 0, failed = 0
var images: [Int: CVPixelBuffer] = [:]
let keep: Set<Int> = [frames.count / 2, frames.count - 1]

for (number, frame) in frames.enumerated() {
    let nals = units(frame)
    let parameterSets = nals.filter { $0.first.map { $0 & 0x1F == 7 || $0 & 0x1F == 8 } ?? false }
    if parameterSets.count == 2, session == nil {
        var made: CMVideoFormatDescription?
        parameterSets[0].withUnsafeBufferPointer { sps in
            parameterSets[1].withUnsafeBufferPointer { pps in
                let sets = [sps.baseAddress!, pps.baseAddress!]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: sets,
                                                                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &made)
            }
        }
        format = made
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        VTDecompressionSessionCreate(allocator: nil, formatDescription: made!, decoderSpecification: nil,
                                     imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session)
        let dimensions = CMVideoFormatDescriptionGetDimensions(made!)
        print("SPS/PPS in beeld \(number): \(dimensions.width)×\(dimensions.height)")
    }
    guard let session, let format else { failed += 1; continue }
    // Back to AVCC: each NAL unit with its length in front.
    var avcc: [UInt8] = []
    for nal in nals where !(nal.first.map { $0 & 0x1F == 7 || $0 & 0x1F == 8 } ?? true) {
        let length = UInt32(nal.count)
        avcc += [UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)] + nal
    }
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
                                       customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
    CMBlockBufferReplaceDataBytes(with: avcc, blockBuffer: block!, offsetIntoDestination: 0, dataLength: avcc.count)
    var sample: CMSampleBuffer?
    var size = avcc.count
    CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                              sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
    let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample!, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
        if status == noErr, let image {
            decoded += 1
            if keep.contains(number) { images[number] = image }
        } else {
            failed += 1
        }
    }
    if status != noErr { failed += 1 }
}
if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
print("Beelden: \(frames.count), gedecodeerd: \(decoded), mislukt: \(failed)")
let context = CIContext()
for (number, image) in images {
    let url = folder.appendingPathComponent("beeld-\(number).png")
    let picture = CIImage(cvPixelBuffer: image)
    try context.writePNGRepresentation(of: picture, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    print("Opgeslagen: \(url.path)")
}
