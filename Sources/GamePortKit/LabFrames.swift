import Foundation

/// A thumbnail of the game window, reduced to mean luminance and a 64-bit average hash.
/// Comparing brightness as well as the hash distinguishes two solid screens of different shades.
struct LabFrameSignature {
    let mean: Double
    let hash: UInt64

    init?(luminance: [UInt8]) {
        guard luminance.count == 64 else { return nil }
        mean = Double(luminance.reduce(0) { $0 + Int($1) }) / 64
        var bits: UInt64 = 0
        for (index, pixel) in luminance.enumerated() where Double(pixel) >= mean {
            bits |= UInt64(1) << index
        }
        hash = bits
    }

    var isBlack: Bool { mean <= 6 }

    func resembles(_ other: Self) -> Bool {
        abs(mean - other.mean) <= 3 && (hash ^ other.hash).nonzeroBitCount <= 2
    }
}

enum LabFrameFinding: Equatable, Sendable { case black, unchanged }

/// Require a continuous 20-second tail of five-second samples from one window. Compare to the
/// first frame of the streak so gradual motion cannot accumulate unnoticed between samples.
struct LabFrameSequence {
    private var reference: LabFrameSignature?
    private var window: UInt32?
    private var start = 0.0
    private var last = 0.0
    private var count = 0
    private static let maximumGap = 8.0

    mutating func record(_ frame: LabFrameSignature, window id: UInt32, at time: TimeInterval) {
        let same = reference.map { first in
            if first.isBlack || frame.isBlack { return first.isBlack && frame.isBlack }
            return first.resembles(frame)
        } ?? false
        if window != id || !same || time <= last || time - last > Self.maximumGap {
            start = time
            reference = frame
            window = id
            count = 0
        }
        last = time
        count += 1
    }

    func finding(at end: TimeInterval) -> LabFrameFinding? {
        guard let reference, count >= 5, last - start >= 20, end >= last, end - last <= Self.maximumGap else { return nil }
        return reference.isBlack ? .black : .unchanged
    }
}
