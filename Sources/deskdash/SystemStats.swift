import Darwin
import Foundation
import IOKit

/// The Mac's own load, for the row of meters on the clock page.
struct SystemStats: Equatable, Sendable {
    /// macOS's memory pressure (kern.memorystatus_vm_pressure_level), the same signal as Activity Monitor's graph.
    enum Pressure: Int32, Sendable {
        case normal = 1, warning = 2, critical = 4
    }

    var cpu: Double?  // share of all cores busy since the previous sample, 0...1
    var temperature: Double?  // the CPU cores' average in °C; nil on a Mac without the sensors (CPUTemperature)
    var thermal: ProcessInfo.ThermalState  // macOS's thermal pressure, which colors the temperature
    var memoryUsed: Double  // bytes in active, wired and compressed pages
    var memoryTotal: Double
    var pressure: Pressure
    var diskUsed: Double?  // share of the startup disk in use, 0...1, with purgeable space counted as free
    var download: Double?  // bytes a second over the Ethernet and Wi-Fi interfaces
    var upload: Double?
    // For the system page:
    var diskFree: Double? = nil  // bytes free on the startup disk, as Finder counts them
    var diskRead: Double? = nil  // bytes a second read from and written to the Mac's disks
    var diskWrite: Double? = nil
    var swapUsed: Double = 0  // bytes of swap in use
    var load: Double = 0  // the 1-minute load average: how many threads want a core

    var memory: Double { memoryTotal > 0 ? memoryUsed / memoryTotal : 0 }

    static let demo = SystemStats(cpu: 0.23, temperature: 51, thermal: .nominal, memoryUsed: 13.4 * 1_073_741_824,
                                  memoryTotal: 24 * 1_073_741_824, pressure: .normal, diskUsed: 0.48,
                                  download: 1_240_000, upload: 310_000, diskFree: 512_000_000_000,
                                  diskRead: 18_400_000, diskWrite: 3_100_000, swapUsed: 0, load: 2.4)
}

/// The last 10 minutes of the Mac's load, a sample every 2 s, for the system page's graphs.
struct SystemHistory: Equatable, Sendable {
    static let capacity = 300

    var cpu: [Double?] = []
    var temperature: [Double?] = []
    var memory: [Double?] = []
    var diskRead: [Double?] = []
    var diskWrite: [Double?] = []

    mutating func append(_ s: SystemStats) {
        func push(_ series: inout [Double?], _ value: Double?) {
            series.append(value)
            if series.count > Self.capacity { series.removeFirst(series.count - Self.capacity) }
        }
        push(&cpu, s.cpu)
        push(&temperature, s.temperature)
        push(&memory, s.memory)
        push(&diskRead, s.diskRead)
        push(&diskWrite, s.diskWrite)
    }

    /// Made-up but plausible: a build's burst on a quiet machine.
    static var demo: SystemHistory {
        var h = SystemHistory()
        for i in 0..<capacity {
            let t = Double(i) / Double(capacity)
            let burst = max(0, sin((t - 0.55) * .pi * 5)) * (t > 0.55 && t < 0.75 ? 1 : 0)
            h.cpu.append(0.08 + 0.05 * sin(Double(i) / 7) + 0.6 * burst)
            h.temperature.append(44 + 4 * sin(Double(i) / 23) + 30 * burst)
            h.memory.append(0.5 + 0.06 * t + 0.04 * burst)
            h.diskRead.append(2_000_000 + 60_000_000 * burst + 1_000_000 * abs(sin(Double(i) / 3)))
            h.diskWrite.append(500_000 + 20_000_000 * burst + 400_000 * abs(cos(Double(i) / 5)))
        }
        return h
    }
}

/// The processes using the most CPU, for the system page, as Activity Monitor's CPU tab lists them.
struct ProcessLoad: Equatable, Sendable, Identifiable {
    let name: String
    let cpu: Double  // share of all cores, 0...1, like the page's CPU figure
    var id: String { name }

    static let demo = [ProcessLoad(name: "swift-frontend", cpu: 0.31), ProcessLoad(name: "Safari", cpu: 0.06),
                       ProcessLoad(name: "WindowServer", cpu: 0.03)]
}

/// Each process's CPU time from libproc (proc_pid_rusage), compared with the last look: what each used since. Processes
/// of one name (a browser's helpers) count together. About 2 ms for 600 processes; only while the system page shows.
final class ProcessSampler: @unchecked Sendable {
    private var last: [pid_t: UInt64] = [:]
    private var lastAt: UInt64 = 0
    private let lock = NSLock()

    func top(_ count: Int) -> [ProcessLoad] {
        lock.lock()
        defer { lock.unlock() }
        let now = mach_absolute_time()
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = Int(proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.stride * pids.count)))
        var times: [pid_t: UInt64] = [:]
        var byName: [String: UInt64] = [:]
        for pid in pids.prefix(max(0, n)) where pid > 0 {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { continue }  // another user's process, which this one may not look into
            let total = info.ri_user_time + info.ri_system_time
            times[pid] = total
            guard let before = last[pid], total >= before else { continue }
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid, &name, UInt32(name.count))
            byName[String(cString: name), default: 0] += total - before
        }
        defer {
            last = times
            lastAt = now
        }
        guard lastAt > 0, now > lastAt else { return [] }
        // rusage's CPU times count in mach_absolute_time's units, as the wall clock here does, so their ratio is the
        // share of a core; divided by the cores, the share of all of them.
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let wall = Double(now - lastAt)
        return byName.filter { !$0.key.isEmpty }
            .map { ProcessLoad(name: $0.key, cpu: Double($0.value) / (wall * cores)) }
            .sorted { $0.cpu > $1.cpu }
            .prefix(count)
            .filter { $0.cpu >= 0.005 }
    }
}

/// Samples the Mac's load on every other clock tick, so new numbers reach the screen with the tick's own redraw.
/// CPU, memory and network come straight from the kernel (Mach host statistics and sysctl), well under a
/// millisecond together. The SSD's free space goes through the CacheDelete service, 6-40 ms a call, so it is
/// read once a minute off the main thread, and the CPU's temperature, which waits on the SMC for 3-6 ms, every 5 s.
@MainActor
final class SystemStatsService {
    private let dash: Dashboard
    private let host = mach_host_self()
    private let pageSize: Double
    private var enabled = false
    private var cpuTicks: [UInt32]?
    private var netBytes: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var netSampled: TimeInterval?
    private var diskUsed: Double?
    private var diskFree: Double?
    private var diskBytes: (read: UInt64, write: UInt64)?
    private let processes = ProcessSampler()
    private var processesBusy = false
    private var samples = 0
    private var diskTask: Task<Void, Never>?
    private var temperature: Double?
    private var temperatureTask: Task<Void, Never>?

    init(dash: Dashboard) {
        self.dash = dash
        var size: vm_size_t = 0
        host_page_size(host, &size)
        pageSize = Double(size)
    }

    func apply(_ cfg: Config.Stats) {
        guard cfg.enabled != enabled else { return }
        enabled = cfg.enabled
        diskTask?.cancel()
        temperatureTask?.cancel()
        cpuTicks = nil
        netSampled = nil
        guard enabled else {
            dash.stats = nil
            return
        }
        _ = read()  // a baseline, so the first sample on the tick already has rates
        diskTask = Task {
            while !Task.isCancelled {
                let disk = await Task.detached(priority: .utility) { Self.readDisk() }.value
                diskUsed = disk?.used
                diskFree = disk?.free
                try? await Task.sleep(for: .seconds(60))
            }
        }
        temperatureTask = Task {
            while !Task.isCancelled {
                temperature = await Task.detached(priority: .utility) { CPUTemperature.shared?.read() }.value
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Called every 2 s from the clock tick.
    func sample() {
        guard enabled, let stats = read() else { return }
        dash.history.append(stats)
        if stats != dash.stats { dash.stats = stats }
        samples += 1
        // The busiest processes, every other sample while the system page shows: listing every process is the one
        // costly read here, so it waits for someone to be looking.
        if dash.page == .system, samples % 2 == 0, !processesBusy {
            processesBusy = true
            let sampler = processes
            Task {
                let top = await Task.detached(priority: .utility) { sampler.top(3) }.value
                processesBusy = false
                if top != dash.topProcesses { dash.topProcesses = top }
            }
        }
    }

    /// For `deskdash snapshot`: rates need two samples, so it takes them a second apart.
    func prime() async {
        apply(dash.config.stats)
        guard enabled else { return }
        let disk = Self.readDisk()
        diskUsed = disk?.used
        diskFree = disk?.free
        temperature = CPUTemperature.shared?.read()
        try? await Task.sleep(for: .seconds(1))
        sample()
    }

    private func read() -> SystemStats? {
        guard let vm = Self.vmStatistics(host) else { return nil }
        let now = ProcessInfo.processInfo.systemUptime

        var cpu: Double?
        if let ticks = Self.cpuLoad(host) {
            if let last = cpuTicks {
                let delta = zip(ticks, last).map { Double($0 &- $1) }  // user, system, idle, nice; the counters wrap
                let total = delta.reduce(0, +)
                if total > 0 { cpu = 1 - delta[Int(CPU_STATE_IDLE)] / total }
            }
            cpuTicks = ticks
        }

        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)

        var download: Double?, upload: Double?
        let bytes = Self.interfaceBytes()
        if let last = netSampled, now > last {
            var rx: UInt64 = 0, tx: UInt64 = 0
            for (name, b) in bytes {
                // An interface that just appeared or reset its counters has no rate yet.
                guard let before = netBytes[name], b.rx >= before.rx, b.tx >= before.tx else { continue }
                rx += b.rx - before.rx
                tx += b.tx - before.tx
            }
            download = Double(rx) / (now - last)
            upload = Double(tx) / (now - last)
        }
        var diskRead: Double?, diskWrite: Double?
        let io = Self.diskIOBytes()
        if let last = netSampled, now > last, let before = diskBytes, io.read >= before.read, io.write >= before.write {
            diskRead = Double(io.read - before.read) / (now - last)
            diskWrite = Double(io.write - before.write) / (now - last)
        }
        diskBytes = io
        netBytes = bytes
        netSampled = now

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)

        let pages = UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
        return SystemStats(cpu: cpu, temperature: temperature, thermal: ProcessInfo.processInfo.thermalState,
                           memoryUsed: Double(pages) * pageSize,
                           memoryTotal: Double(ProcessInfo.processInfo.physicalMemory),
                           pressure: SystemStats.Pressure(rawValue: level) ?? .normal, diskUsed: diskUsed,
                           download: download, upload: upload, diskFree: diskFree, diskRead: diskRead,
                           diskWrite: diskWrite, swapUsed: Double(swap.xsu_used), load: loads[0])
    }

    // MARK: kernel counters

    private static func cpuLoad(_ host: host_t) -> [UInt32]? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return [t.0, t.1, t.2, t.3]
    }

    private static func vmStatistics(_ host: host_t) -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    /// Byte counters of the Ethernet and Wi-Fi interfaces (en*) from sysctl NET_RT_IFLIST2, whose if_data64
    /// counters are 64-bit (if_data's 32-bit ones wrap every 4 GB). Tunnels such as a VPN's utun are left
    /// out: their traffic crosses en* too, and counting both would count it twice.
    private static func interfaceBytes() -> [String: (rx: UInt64, tx: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }
        var out: [String: (rx: UInt64, tx: UInt64)] = [:]
        buffer.withUnsafeBytes { raw in
            // Each interface's RTM_IFINFO2 message is followed by its link-level address, which holds the name.
            let linkAt = MemoryLayout<if_msghdr2>.size
            let nameAt = linkAt + MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length, let base = raw.baseAddress {
                let message = base + offset
                let header = message.loadUnaligned(as: if_msghdr.self)
                let size = Int(header.ifm_msglen)
                guard size > 0, offset + size <= length else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, linkAt + MemoryLayout<sockaddr_dl>.size <= size {
                    let link = (message + linkAt).loadUnaligned(as: sockaddr_dl.self)
                    let name = String(decoding: UnsafeRawBufferPointer(start: message + nameAt,
                                                                       count: min(Int(link.sdl_nlen), size - nameAt)),
                                      as: UTF8.self)
                    if name.hasPrefix("en") {
                        let data = message.loadUnaligned(as: if_msghdr2.self).ifm_data
                        out[name] = (data.ifi_ibytes, data.ifi_obytes)
                    }
                }
                offset += size
            }
        }
        return out
    }

    /// Free space as Finder counts it, purgeable files included, which is why it goes through CacheDelete.
    nonisolated private static func readDisk() -> (used: Double, free: Double)? {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(
                  forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, total > 0,
              let free = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return (min(1, max(0, 1 - Double(free) / Double(total))), Double(free))
    }

    /// Bytes read and written since boot by every disk (the IOBlockStorageDriver statistics Activity Monitor's Disk tab
    /// shows), from the I/O registry: no permission, well under a millisecond.
    private static func diskIOBytes() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
                == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(entry)
        }
        return (read, write)
    }
}

// MARK: temperature

/// The CPU's temperature, from the sensors on its cores. macOS publishes no temperature API, but the SMC, the
/// controller that runs the fans and power, answers any process through IOKit's public calls, and temperature
/// monitors read it that way. Its keys are undocumented four-letter codes. On Apple silicon the float keys named
/// `Tp…` sit on the performance cores and `Te…` on the efficiency cores, 30 of them on an M6. Finding them lists
/// the SMC's 2,000-odd keys once, 5-16 ms. A read then waits on the SMC 0.1-0.2 ms a sensor, 3-6 ms in all, of
/// which under a millisecond is CPU. The connection stays open for the life of the process.
struct CPUTemperature: Sendable {
    /// Found on first use; nil on a Mac without the sensors, such as an Intel one.
    static let shared = open()

    private let connection: io_connect_t
    private let keys: [UInt32]

    /// The sensors' average in °C, leaving out any that reads nothing.
    func read() -> Double? {
        let values = keys.compactMap { Self.value(connection, $0) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static func open() -> CPUTemperature? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        let total = call(connection, readKey, key: code("#KEY"), size: 4)  // how many keys there are, big-endian
        let count = total.map { UInt32(bigEndian: word($0, at: 48)) } ?? 0
        let cores = [code("Tp"), code("Te")], float = code("flt ")
        var keys: [UInt32] = []
        for index in 0..<count {
            guard let key = call(connection, keyAtIndex, index: index).map({ word($0, at: 0) }),
                  cores.contains(key >> 16),
                  let info = call(connection, keyInfo, key: key),
                  word(info, at: 28) == 4, word(info, at: 32) == float,  // 4 bytes, a Float32
                  value(connection, key) != nil
            else { continue }
            keys.append(key)
        }
        guard !keys.isEmpty else {
            IOServiceClose(connection)
            return nil
        }
        return CPUTemperature(connection: connection, keys: keys)
    }

    /// A sensor's reading in °C, or nil when it reads 0, as the SMC's unused sensors do, or nonsense.
    private static func value(_ connection: io_connect_t, _ key: UInt32) -> Double? {
        guard let reply = call(connection, readKey, key: key, size: 4) else { return nil }
        let celsius = Double(reply.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 48, as: Float32.self) })
        return celsius > 0 && celsius < 150 ? celsius : nil
    }

    private static let readKey: UInt8 = 5, keyAtIndex: UInt8 = 8, keyInfo: UInt8 = 9

    /// One request to the SMC, through its user client's single method (2). Request and reply are each an
    /// SMCKeyData_t, 80 bytes, set and read here at its C offsets: the key at 0, the value's size and type at 28 and
    /// 32, the SMC's result at 40, the command at 42, a key index at 44, and the value's bytes from 48.
    private static func call(_ connection: io_connect_t, _ command: UInt8, key: UInt32 = 0, index: UInt32 = 0,
                             size: UInt32 = 0) -> [UInt8]? {
        var request = [UInt8](repeating: 0, count: 80)
        request.withUnsafeMutableBytes {
            $0.storeBytes(of: key, toByteOffset: 0, as: UInt32.self)
            $0.storeBytes(of: size, toByteOffset: 28, as: UInt32.self)
            $0[42] = command
            $0.storeBytes(of: index, toByteOffset: 44, as: UInt32.self)
        }
        var reply = [UInt8](repeating: 0, count: 80)
        var length = reply.count
        guard IOConnectCallStructMethod(connection, 2, request, request.count, &reply, &length) == kIOReturnSuccess,
              reply[40] == 0
        else { return nil }
        return reply
    }

    private static func word(_ reply: [UInt8], at offset: Int) -> UInt32 {
        reply.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    /// "Tp05" → 0x54703035, a key's characters as the SMC packs them.
    private static func code(_ name: String) -> UInt32 {
        name.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
