// Makes Attic/Assets.xcassets/AppIcon.appiconset/AppIcon.png from attic-logo.png:
//   swiftc -O -o /tmp/make_icon Artwork/make_icon.swift && /tmp/make_icon Artwork/attic-logo.png Attic/Assets.xcassets/AppIcon.appiconset/AppIcon.png

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Crops the logo to the inside of its rounded square and continues the square's own background
// into the corners (iOS rounds the icon itself), then writes a 1024×1024 PNG without alpha.
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(input as CFURL, nil)!, 0, nil)!
let size = 1024
// The square runs from x 56 to 1196 and y 65 to 1189, with a light rim along its top edge.
let cropped = image.cropping(to: CGRect(x: 68, y: 68, width: 1116, height: 1116))!
var px = [UInt8](repeating: 0, count: size * size * 4)
let context = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.interpolationQuality = .high
context.draw(cropped, in: CGRect(x: 0, y: 0, width: size, height: size))

func index(_ x: Int, _ y: Int) -> Int { (y * size + x) * 4 }
func lum(_ x: Int, _ y: Int) -> Int { let i = index(x, y); return max(Int(px[i]), Int(px[i + 1]), Int(px[i + 2])) }

let zone = 380
let rim = 8
for (cornerX, cornerY) in [(0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1)] {
    let xs = cornerX == 0 ? 0..<zone : (size - zone)..<size
    let ys = cornerY == 0 ? 0..<zone : (size - zone)..<size
    func inZone(_ x: Int, _ y: Int) -> Bool { xs.contains(x) && ys.contains(y) }
    // 0 known, 1 to fill. Outside the square: the black reachable from the corner.
    var state = [[Int8]](repeating: [Int8](repeating: 0, count: size), count: size)
    var distance = [[Int]](repeating: [Int](repeating: Int.max, count: size), count: size)
    var queue = [(cornerX, cornerY)]
    distance[cornerY][cornerX] = 0
    var head = 0
    while head < queue.count {
        let (x, y) = queue[head]; head += 1
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let nx = x + dx, ny = y + dy
            guard inZone(nx, ny), distance[ny][nx] == Int.max, lum(nx, ny) < 6 else { continue }
            distance[ny][nx] = 0
            queue.append((nx, ny))
        }
    }
    // The square's edge (antialiasing and rim) is filled too.
    var layer = queue
    for step in 1...rim {
        var next: [(Int, Int)] = []
        for (x, y) in layer {
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard inZone(nx, ny), distance[ny][nx] == Int.max else { continue }
                distance[ny][nx] = step
                next.append((nx, ny))
            }
        }
        layer = next
    }
    var unknown: [(Int, Int)] = []
    for y in ys { for x in xs where distance[y][x] != Int.max { state[y][x] = 1; unknown.append((x, y)) } }
    // Fill from the inside outwards, each pixel the average of its known neighbours.
    while !unknown.isEmpty {
        var filled: [(Int, Int, [Int])] = []
        var remaining: [(Int, Int)] = []
        for (x, y) in unknown {
            var sum = [0, 0, 0], count = 0
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < size, ny < size, state[ny][nx] == 0 else { continue }
                let i = index(nx, ny)
                sum[0] += Int(px[i]); sum[1] += Int(px[i + 1]); sum[2] += Int(px[i + 2]); count += 1
            } }
            if count > 0 { filled.append((x, y, sum.map { ($0 + count / 2) / count })) } else { remaining.append((x, y)) }
        }
        if filled.isEmpty { break }
        for (x, y, color) in filled {
            let i = index(x, y)
            px[i] = UInt8(color[0]); px[i + 1] = UInt8(color[1]); px[i + 2] = UInt8(color[2])
            state[y][x] = 0
        }
        unknown = remaining
    }
}
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
