import Darwin
import Foundation

struct ProcessMemorySample: Equatable, Sendable {
    let applicationName: String
    let physicalFootprintBytes: UInt64
}

struct MemoryConsumer: Identifiable, Equatable, Sendable {
    var id: String { applicationName }

    let applicationName: String
    let physicalFootprintBytes: UInt64
    let processCount: Int
}

struct MemoryDiagnosticsSnapshot: Equatable, Sendable {
    let system: SystemMemorySnapshot?
    let consumers: [MemoryConsumer]
    let capturedAt: Date
}

/// Read-only memory attribution for the queue UI. Physical footprint is the best per-process
/// number macOS exposes, but compressed pages and swap are system-wide and cannot be assigned
/// exactly to the process which originally created them. The UI says this explicitly.
enum SystemMemoryDiagnostics {
    static func capture(consumerLimit: Int = 6) -> MemoryDiagnosticsSnapshot {
        MemoryDiagnosticsSnapshot(
            system: SystemMemoryGate.memorySnapshot(),
            consumers: groupedConsumers(processSamples(), limit: consumerLimit),
            capturedAt: Date()
        )
    }

    static func groupedConsumers(
        _ samples: [ProcessMemorySample],
        limit: Int
    ) -> [MemoryConsumer] {
        struct Aggregate {
            var bytes: UInt64 = 0
            var count = 0
        }

        var grouped: [String: Aggregate] = [:]
        for sample in samples where sample.physicalFootprintBytes > 0 {
            grouped[sample.applicationName, default: Aggregate()].bytes +=
                sample.physicalFootprintBytes
            grouped[sample.applicationName, default: Aggregate()].count += 1
        }

        return grouped.map { name, aggregate in
            MemoryConsumer(
                applicationName: name,
                physicalFootprintBytes: aggregate.bytes,
                processCount: aggregate.count
            )
        }
        .sorted {
            if $0.physicalFootprintBytes == $1.physicalFootprintBytes {
                return $0.applicationName.localizedCaseInsensitiveCompare(
                    $1.applicationName
                ) == .orderedAscending
            }
            return $0.physicalFootprintBytes > $1.physicalFootprintBytes
        }
        .prefix(max(0, limit))
        .map { $0 }
    }

    private static func processSamples() -> [ProcessMemorySample] {
        var pids = [pid_t](repeating: 0, count: 4_096)
        let pidCount = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.stride)
        )
        guard pidCount > 0 else { return [] }

        return pids.prefix(Int(pidCount)).compactMap { pid in
            guard pid > 0,
                  let footprint = physicalFootprint(pid: pid),
                  footprint > 0,
                  let name = applicationName(pid: pid) else {
                return nil
            }
            return ProcessMemorySample(
                applicationName: name,
                physicalFootprintBytes: footprint
            )
        }
    }

    private static func physicalFootprint(pid: pid_t) -> UInt64? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
            }
        }
        guard result == 0 else { return nil }
        return usage.ri_phys_footprint
    }

    private static func applicationName(pid: pid_t) -> String? {
        if let path = executablePath(pid: pid) {
            let components = URL(fileURLWithPath: path).pathComponents
            if let appComponent = components.first(where: {
                $0.lowercased().hasSuffix(".app")
            }) {
                return String(appComponent.dropLast(4))
            }

            let executable = URL(fileURLWithPath: path).lastPathComponent
            if !executable.isEmpty {
                return friendlierName(executable)
            }
        }

        var nameBuffer = [CChar](repeating: 0, count: 1_024)
        let length = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        guard length > 0 else { return nil }
        return friendlierName(String(cString: nameBuffer))
    }

    private static func executablePath(pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { return nil }
        return String(cString: pathBuffer)
    }

    private static func friendlierName(_ executable: String) -> String {
        switch executable {
        case "swift-frontend", "swiftc":
            return "Swift compiler"
        case "node":
            return "Node.js"
        case "python", "python3", "python3.12":
            return "Python"
        case "kernel_task":
            return "macOS kernel"
        default:
            return executable
        }
    }
}
