import Foundation

/// Thin wrapper around Process. Arguments are passed as an array: no shell, no quoting bugs.
public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
    }

    /// Runs a program to completion and returns its combined stdout/stderr.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           currentDirectory: URL? = nil, check: Bool = true) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting so a chatty child never blocks on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        if check, process.terminationStatus != 0 {
            let name = URL(fileURLWithPath: executable).lastPathComponent
            throw GamePortError.process("\(name) \(arguments.prefix(3).joined(separator: " "))\n\(output.suffix(2000))", process.terminationStatus)
        }
        return Result(status: process.terminationStatus, output: output)
    }

    /// Runs a program to completion with its output going straight to this process's stdout/stderr,
    /// so the user sees it live and a hang never swallows what was already printed.
    @discardableResult
    public static func runAttached(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                                   currentDirectory: URL? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Starts a long-running program with its output going to a log file. Returns immediately.
    public static func spawn(_ executable: String, _ arguments: [String], environment: [String: String],
                             log: URL, currentDirectory: URL? = nil) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.qualityOfService = .userInteractive
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    public static var isAppleSilicon: Bool {
        #if os(macOS)
        if let r = try? run("/usr/sbin/sysctl", ["-n", "hw.optional.arm64"], check: false) {
            return r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
        #endif
        return false
    }

    /// Rosetta is installed when an x86_64 binary can run; `arch -x86_64 /usr/bin/true` is the cheapest probe.
    public static var rosettaInstalled: Bool {
        #if os(macOS)
        return (try? run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"], check: false))?.status == 0
        #else
        return false
        #endif
    }

    public static var macOSVersion: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }

    public static var macOSVersionString: String {
        let v = macOSVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The frontmost app's name ("wine" for a game window), from `lsappinfo`; nil if it cannot be read.
    public static func frontmostAppName() -> String? {
        guard let asn = (try? run("/usr/bin/lsappinfo", ["front"], check: false))?.output
                .trimmingCharacters(in: .whitespacesAndNewlines), !asn.isEmpty,
              let info = (try? run("/usr/bin/lsappinfo", ["info", "-only", "name", asn], check: false))?.output,
              let open = info.firstIndex(of: "\""),
              let close = info[info.index(after: open)...].firstIndex(of: "\"") else { return nil }
        return String(info[info.index(after: open)..<close])
    }

    /// e.g. "Apple M1 (MacBookAir10,1)": what a lab result was measured on.
    public static var machineDescription: String {
        func sysctl(_ name: String) -> String {
            ((try? run("/usr/sbin/sysctl", ["-n", name], check: false))?.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "\(sysctl("machdep.cpu.brand_string")) (\(sysctl("hw.model")))"
    }
}
