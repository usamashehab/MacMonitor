import Foundation
import Darwin

/// Reads raw system metrics. All methods are cheap enough to call once per second.
final class StatsReader {
    private var lastCPU: (busy: UInt64, total: UInt64)?
    private var lastNet: (rx: UInt64, tx: UInt64, time: Date)?

    struct Temps { var cpu: Double?; var gpu: Double?; var ssd: Double?; var battery: Double? }

    // MARK: CPU

    func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0), sys = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + sys + nice, total = busy + idle
        defer { lastCPU = (busy, total) }
        guard let last = lastCPU, total > last.total else { return 0 }
        return Double(busy - last.busy) / Double(total - last.total) * 100
    }

    // MARK: Memory

    /// Matches Activity Monitor's "Memory Used" (app + wired + compressed).
    func memory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    func swap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    // MARK: GPU / temperature (C helpers in sensors.c)

    func gpuUsage() -> Double? {
        let v = mm_gpu_utilization()
        return v < 0 ? nil : v
    }

    func temperatures() -> Temps {
        let max = 256, nameLen = 64
        var names = [CChar](repeating: 0, count: max * nameLen)
        var values = [Double](repeating: 0, count: max)
        let n = Int(mm_read_temperatures(&names, &values, Int32(max)))

        var groups: [String: [Double]] = [:]
        for i in 0..<n {
            let name = names.withUnsafeBufferPointer { String(cString: $0.baseAddress! + i * nameLen) }
            let key: String
            if name.hasPrefix("PMU tdie") || name.hasPrefix("pACC") || name.hasPrefix("eACC") { key = "cpu" }
            else if name.hasPrefix("PMU TP") && name.hasSuffix("g") || name.hasPrefix("GPU") { key = "gpu" }
            else if name.hasPrefix("NAND") { key = "ssd" }
            else if name.hasPrefix("gas gauge battery") { key = "battery" }
            else { continue }
            groups[key, default: []].append(values[i])
        }
        func avg(_ k: String) -> Double? {
            guard let a = groups[k], !a.isEmpty else { return nil }
            return a.reduce(0, +) / Double(a.count)
        }
        return Temps(cpu: avg("cpu"), gpu: avg("gpu"), ssd: avg("ssd"), battery: avg("battery"))
    }

    // MARK: Network

    /// Bytes/second down & up, summed over physical interfaces (64-bit counters).
    func network() -> (down: Double, up: Double) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }

        var rx: UInt64 = 0, tx: UInt64 = 0
        var offset = 0
        buf.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                    let m = raw.load(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    let name = if_indextoname(UInt32(m.ifm_index), &nameBuf).map { String(cString: $0) } ?? ""
                    // Skip loopback and virtual tunnels (VPN traffic would double-count).
                    let skip = ["lo", "utun", "awdl", "llw", "gif", "stf", "bridge", "ap", "anpi"]
                    if !skip.contains(where: { name.hasPrefix($0) }) {
                        rx += m.ifm_data.ifi_ibytes
                        tx += m.ifm_data.ifi_obytes
                    }
                }
                guard hdr.ifm_msglen > 0 else { break }
                offset += Int(hdr.ifm_msglen)
            }
        }
        let now = Date()
        defer { lastNet = (rx, tx, now) }
        guard let last = lastNet, rx >= last.rx, tx >= last.tx else { return (0, 0) }
        let dt = now.timeIntervalSince(last.time)
        guard dt > 0 else { return (0, 0) }
        return (Double(rx - last.rx) / dt, Double(tx - last.tx) / dt)
    }
}
