#if os(macOS)
import AppKit
import Darwin
import ScreenCaptureKit

/// Samples only a foreground Steam game process launched in this trial. A stalled capture or
/// a missing Screen Recording permission must never hold up the HUD measurement or teardown.
actor LabWindowCapture {
    static let markerKey = "GAMEPORT_LAB_RUN"
    private let marker: String
    private var sequence = LabFrameSequence()
    private var owner: pid_t?
    private var samples: Int?

    init(marker: String) { self.marker = marker }

    func monitor(after warmup: TimeInterval, progress: ProgressHandler?) async {
        guard CGPreflightScreenCaptureAccess() else {
            progress?("Visual checks unavailable. Grant Screen Recording access to GamePort or your terminal to enable them.")
            return
        }
        samples = 0
        let clock = ProcessInfo.processInfo
        do {
            if warmup > 0 { try await Task.sleep(for: .seconds(warmup)) }
            while !Task.isCancelled {
                let next = ContinuousClock.now.advanced(by: .seconds(5))
                let pid = await Self.frontmostPID()
                var sample: (UInt32, LabFrameSignature)?
                if let pid, Self.belongsToTrial(pid, marker: marker) {
                    sample = try? await Self.capture(pid)
                }
                let stillInFront = await Self.frontmostPID() == pid
                guard !Task.isCancelled else { return }
                if let pid, stillInFront, let (windowID, frame) = sample {
                    if owner != pid { sequence = LabFrameSequence() }
                    sequence.record(frame, window: windowID, at: clock.systemUptime)
                    owner = pid
                    samples? += 1
                } else {
                    sequence = LabFrameSequence()
                    owner = nil
                }
                try await Task.sleep(until: next, clock: .continuous)
            }
        } catch { /* The Lab finished or was cancelled. */ }
    }

    func finding(progress: ProgressHandler?) async -> LabFrameFinding? {
        if samples == 0 { progress?("No foreground game window could be sampled. Visual checks unavailable for this run.") }
        guard let owner, await Self.frontmostPID() == owner else { return nil }
        return sequence.finding(at: ProcessInfo.processInfo.systemUptime)
    }

    @MainActor private static func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func belongsToTrial(_ pid: pid_t, marker: String) -> Bool {
        // Check the command first so we only inspect the environment of a game executable.
        let selection = ["-p", String(pid), "-o", "pid=,command="]
        guard let command = try? Shell.run("/bin/ps", ["-ww"] + selection),
              LabResult.gameProcessIDs(inProcessList: command.output).contains(Int(pid)) else { return false }
        // Wine can zero-pad argv after rewriting its process title. Darwin ps -E stops at two
        // NULs and can miss the environment after that padding. Match a whole raw field instead.
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var arguments = [UInt8](repeating: 0, count: size)
        let status = arguments.withUnsafeMutableBytes { bytes in
            sysctl(&mib, 3, bytes.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return false }
        let token = (Self.markerKey + "=" + marker).utf8
        return arguments.prefix(size).split(separator: 0).contains { $0.elementsEqual(token) }
    }

    private static func capture(_ pid: pid_t) async throws -> (UInt32, LabFrameSignature)? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width >= 64 && $0.frame.height >= 64
        }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        let config = SCStreamConfiguration()
        config.width = 128
        config.height = max(16, min(256, Int(128 * window.frame.height / window.frame.width)))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return signature(image).map { (window.windowID, $0) }
    }

    static func signature(_ image: CGImage) -> LabFrameSignature? {
        // Ignore window chrome and the Metal HUD at the edges. Keep only aggregate values in memory.
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let center = bounds.insetBy(dx: bounds.width * 0.125, dy: bounds.height * 0.125)
        let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let cropped = image.cropping(to: center), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                     space: space, bitmapInfo: format), let data = bitmap.data else { return nil }
        bitmap.interpolationQuality = .high
        bitmap.setBlendMode(.copy)
        bitmap.draw(cropped, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var luminance: [UInt8] = []
        for i in stride(from: 0, to: 256, by: 4) {
            guard pixels[i + 3] >= 250 else { return nil } // Empty/transparent content is unknown.
            let luma = 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
            luminance.append(UInt8(luma.rounded()))
        }
        return LabFrameSignature(luminance: luminance)
    }
}
#endif
