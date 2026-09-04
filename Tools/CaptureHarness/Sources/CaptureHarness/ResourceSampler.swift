import Darwin
import Foundation

/// CPU and memory accounting for the harness process and, when readable, for the
/// system capture daemon that does part of the work on our behalf.
struct ResourceSample: Sendable {
    let pid: pid_t
    let name: String
    let cpuSeconds: Double
    let physFootprintBytes: UInt64
}

enum ResourceSampler {
    /// Cumulative user+system CPU seconds and physical footprint for `pid`.
    /// Returns nil when the process is gone or not readable by this user.
    static func sample(pid: pid_t, name: String) -> ResourceSample? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        let cpuSeconds = Double(info.ri_user_time + info.ri_system_time) / 1_000_000_000
        return ResourceSample(pid: pid, name: name, cpuSeconds: cpuSeconds, physFootprintBytes: info.ri_phys_footprint)
    }

    static func selfSample() -> ResourceSample? {
        sample(pid: getpid(), name: "capture-harness")
    }

    /// First running process whose executable name matches, so the harness can
    /// report the capture daemon's CPU alongside its own.
    static func findProcess(named target: String) -> pid_t? {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size)
        let written = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard written > 0 else { return nil }
        var nameBuffer = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN) + 1)
        for pid in pids where pid > 0 {
            let length = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            guard length > 0 else { continue }
            let bytes = nameBuffer[0..<Int(length)].map { UInt8(bitPattern: $0) }
            if String(decoding: bytes, as: UTF8.self) == target { return pid }
        }
        return nil
    }
}

/// Turns cumulative CPU-second readings into average percent of one core.
struct CPUAccumulator {
    let name: String
    let pid: pid_t
    private(set) var firstCPUSeconds: Double?
    private(set) var lastCPUSeconds: Double?
    private(set) var peakFootprintBytes: UInt64 = 0
    private(set) var peakPercentOfOneCore: Double = 0
    private var previousCPUSeconds: Double?
    private var previousWallSeconds: Double?

    init(name: String, pid: pid_t) {
        self.name = name
        self.pid = pid
    }

    mutating func record(_ sample: ResourceSample, wallSeconds: Double) {
        if firstCPUSeconds == nil { firstCPUSeconds = sample.cpuSeconds }
        lastCPUSeconds = sample.cpuSeconds
        peakFootprintBytes = max(peakFootprintBytes, sample.physFootprintBytes)
        if let previousCPUSeconds, let previousWallSeconds, wallSeconds > previousWallSeconds {
            let percent = (sample.cpuSeconds - previousCPUSeconds) / (wallSeconds - previousWallSeconds) * 100
            peakPercentOfOneCore = max(peakPercentOfOneCore, percent)
        }
        previousCPUSeconds = sample.cpuSeconds
        previousWallSeconds = wallSeconds
    }

    func averagePercentOfOneCore(overWallSeconds wall: Double) -> Double? {
        guard let firstCPUSeconds, let lastCPUSeconds, wall > 0 else { return nil }
        return (lastCPUSeconds - firstCPUSeconds) / wall * 100
    }

    func summary(overWallSeconds wall: Double) -> ResourceSummary {
        ResourceSummary(
            process: name,
            pid: pid,
            cpuSeconds: (firstCPUSeconds != nil && lastCPUSeconds != nil) ? lastCPUSeconds! - firstCPUSeconds! : nil,
            averagePercentOfOneCore: averagePercentOfOneCore(overWallSeconds: wall),
            peakPercentOfOneCore: peakPercentOfOneCore,
            peakPhysFootprintBytes: peakFootprintBytes
        )
    }
}

struct ResourceSummary: Sendable {
    let process: String
    let pid: pid_t
    let cpuSeconds: Double?
    let averagePercentOfOneCore: Double?
    let peakPercentOfOneCore: Double
    let peakPhysFootprintBytes: UInt64

    var journalObject: [String: Any] {
        var object: [String: Any] = [
            "process": process,
            "pid": pid,
            "peakPercentOfOneCore": peakPercentOfOneCore,
            "peakPhysFootprintBytes": peakPhysFootprintBytes,
        ]
        if let averagePercentOfOneCore { object["averagePercentOfOneCore"] = averagePercentOfOneCore }
        if let cpuSeconds { object["cpuSeconds"] = cpuSeconds }
        return object
    }

    var described: String {
        let average = averagePercentOfOneCore.map { String(format: "%.2f%% of one core average", $0) } ?? "average unavailable"
        let peak = String(format: "%.2f%% peak", peakPercentOfOneCore)
        let footprint = String(format: "%.1f MB peak footprint", Double(peakPhysFootprintBytes) / 1_048_576)
        return "\(average), \(peak), \(footprint)"
    }
}
