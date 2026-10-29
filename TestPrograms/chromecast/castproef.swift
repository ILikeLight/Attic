// Casts a moving test picture from the Mac to a Chromecast the way Attic does (CastChannel,
// CastStreamer, CastVideoEncoder from Attic/Cast), to try the protocol without an iPhone. Also
// works against fake_receiver.py. Build and run (from the Attic folder; with more than one file,
// Swift wants the top-level code in main.swift):
//   cp TestPrograms/chromecast/castproef.swift /tmp/main.swift
//   xcrun swiftc -O -o /tmp/castproef Attic/Cast/CastMessage.swift Attic/Cast/CastChannel.swift \
//     Attic/Cast/CastStreamer.swift Attic/Cast/CastVideoEncoder.swift /tmp/main.swift
//   /tmp/castproef <address of the Chromecast> [port, 8009] [seconds, 10] [ruis]
// "ruis" adds a block of noise, so that every frame takes many packets, as a busy game would.
import CoreGraphics
import CoreVideo
import Foundation
import Network

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("Gebruik: castproef <adres> [poort] [seconden]")
    exit(2)
}
let port = NWEndpoint.Port(rawValue: arguments.count > 2 ? UInt16(arguments[2]) ?? 8009 : 8009)!
let seconds = arguments.count > 3 ? Double(arguments[3]) ?? 10 : 10
let noise = arguments.contains("ruis")
let width = 1280, height = 720

let queue = DispatchQueue(label: "cast")
let video = CastStreamer.Stream.video()
var channel: CastChannel!
var streamer: CastStreamer?
var encoder: CastVideoEncoder?
var frameTimer: DispatchSourceTimer?
var started = Date.now

func makePool() -> CVPixelBufferPool? {
    let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
    ]
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    return pool
}

/// A picture that shows whether frames come smoothly: a block that crosses the screen in two
/// seconds over a background that changes colour every second, and a counter of frames as bars.
func draw(frame: Int, into buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return }
    let colours: [(CGFloat, CGFloat, CGFloat)] = [(0.8, 0.2, 0.2), (0.2, 0.6, 0.2), (0.2, 0.3, 0.8), (0.7, 0.6, 0.1)]
    let colour = colours[(frame / 60) % colours.count]
    context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    let x = CGFloat(frame % 120) / 120 * CGFloat(width - 160)
    context.fill(CGRect(x: x, y: CGFloat(height) / 2 - 80, width: 160, height: 160))
    for bit in 0..<12 where frame & (1 << bit) != 0 {
        context.fill(CGRect(x: 40 + bit * 50, y: 40, width: 40, height: 40))
    }
    if noise {
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
        for y in 100..<300 {
            for x in 900..<1200 { base[y * stride + x] = UInt32.random(in: 0...UInt32.max) | 0xFF00_0000 }
        }
    }
}

func startFrames() {
    guard let pool = makePool() else { return print("Geen beeldbuffers") }
    var frame = 0
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "frames"))
    timer.schedule(deadline: .now(), repeating: 1.0 / 60, leeway: .milliseconds(1))
    timer.setEventHandler {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        draw(frame: frame, into: buffer)
        frame += 1
        encoder?.encode(buffer, time: DispatchTime.now().uptimeNanoseconds)
    }
    timer.resume()
    frameTimer = timer
    started = .now
    queue.asyncAfter(deadline: .now() + seconds) {
        frameTimer?.cancel()
        if let figures = streamer?.figures {
            print("Verstuurd: \(figures.framesSent) beelden, bevestigd \(figures.framesConfirmed), \(figures.keyFrames) beginbeelden,",
                  "\(figures.packetsResent) pakketjes opnieuw, \(figures.framesDropped) overgeslagen, vertraging ontvanger \(figures.playoutDelay) ms")
        }
        channel.close()
    }
}

channel = CastChannel(to: .hostPort(host: NWEndpoint.Host(arguments[1]), port: port), queue: queue) { _, event in
    switch event {
    case .ready:
        print("Spiegel-ontvanger draait; aanbod sturen")
        channel.sendOffer(CastStreamer.offer(video: video, width: width, height: height, frameRate: 60,
                                             maxBitRate: 8_000_000, targetDelay: 100))
    case .answer(let answer):
        print("Antwoord: \(answer)")
        guard let host = channel.remoteHost,
              let made = CastStreamer(answer: answer, host: host, streams: [video], queue: queue) else {
            print("Het antwoord neemt de video niet aan")
            return channel.close()
        }
        streamer = made
        made.onStatus = { print("Stand: \($0) na \(String(format: "%.1f", Date.now.timeIntervalSince(started))) s") }
        made.start()
        encoder = CastVideoEncoder(width: width, height: height, frameRate: 60, bitRate: 6_000_000) { frame in
            queue.async { made.send(frame) }
        }
        made.onKeyFrameWanted = { encoder?.requestKeyFrame() }
        startFrames()
    case .closed(let reason):
        print("Verbinding dicht: \(reason ?? "door de proef")")
        encoder?.invalidate()
        streamer?.stop()
        queue.asyncAfter(deadline: .now() + 0.5) { exit(reason == nil ? 0 : 1) }
    }
}
channel.start()
dispatchMain()
