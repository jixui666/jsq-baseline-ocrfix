//
//  DeviceReporter.swift
//  开屏设备上报 —— 上报到我们自己的服务端
//
//  链路：App 启动 / 回到前台 → 采集设备信息
//        → AppTransport.call（外层乱码封装 + v2 业务加密）
//        → POST {host}/{pathDeviceOpen} → 服务端 upsert 设备 + 累加打开次数 + 写上报日志
//

import Foundation
import UIKit
import Network

final class DeviceReporter {

    static let shared = DeviceReporter()

    private let minInterval: TimeInterval = 60          // 前台反复切换时 1 分钟内不重复上报
    private let maxAttempts = 3

    private var lastReportAt: Date?
    private var inFlight = false
    private let lock = NSLock()

    private init() {}

    // MARK: - 对外接口

    /// 开屏上报。force = true 时忽略节流（冷启动用）。
    func reportOnLaunch(force: Bool = false) {
        lock.lock()
        if inFlight {
            lock.unlock()
            return
        }
        if !force, let last = lastReportAt, Date().timeIntervalSince(last) < minInterval {
            lock.unlock()
            return
        }
        inFlight = true
        lastReportAt = Date()
        lock.unlock()

        let params = buildParams()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.inFlight = false
                self.lock.unlock()
            }
            await self.send(params: params)
        }
    }

    // MARK: - 上报

    private func send(params: [String: Any]) async {
        let path = V2Protocol.path("deviceOpen")

        for attempt in 1...maxAttempts {
            do {
                let result = try await AppTransport.call(path: path, payload: params)
                let count = result["openCount"] as? Int ?? -1
                log("device report: OK — openCount=\(count) machine=\(AppInfo.machineName)")
                DebugLogWriter.shared.write("device report: success machine=\(AppInfo.machineName) openCount=\(count)")
                return
            } catch {
                log("device report: attempt \(attempt)/\(maxAttempts) FAILED — \(error.localizedDescription)")
                DebugLogWriter.shared.write("device report: attempt \(attempt) failed — \(error.localizedDescription)")
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
                }
            }
        }
        log("device report: give up after \(maxAttempts) attempts")
    }

    // MARK: - 采集

    private func buildParams() -> [String: Any] {
        let device = UIDevice.current
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? AppUpdateChecker.currentVersion
        let build = info["CFBundleVersion"] as? String ?? ""

        device.isBatteryMonitoringEnabled = true
        let battery = device.batteryLevel >= 0 ? Int((device.batteryLevel * 100).rounded()) : -1

        return [
            "app_uuid": ProtocolAPI.appUUID,
            "app_version": version,
            "app_build": build,
            "app_pac": bundle.bundleIdentifier ?? "",
            "machine": AppInfo.machineName,
            "device_name": DeviceReporter.deviceDisplayName(),
            "ios_version": AppInfo.osVersion,
            "os_build": AppInfo.osBuild,
            "idfv": device.identifierForVendor?.uuidString ?? "",
            "locale": DeviceReporter.localeIdentifier(),
            "timezone": TimeZone.current.identifier,
            "network": DeviceReporter.networkType(),
            "battery": battery,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
            "nonce": OuterLayer.randomBytes(8).map { String(format: "%02x", $0) }.joined()
        ]
    }

    // MARK: - 工具

    /// 网络类型：先看 NWPathMonitor 的实时值，还没就绪（unknown）时同步看网卡
    private static func networkType() -> String {
        let cached = NetworkStatus.shared.currentType
        if cached != "unknown" { return cached }
        return interfaceType()
    }

    /// getifaddrs 同步探测：en* 视为 WiFi，pdp_ip* 视为蜂窝
    private static func interfaceType() -> String {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return "unknown" }
        defer { freeifaddrs(addrs) }
        var result = "unknown"
        var ptr = first
        while true {
            let flags = Int32(ptr.pointee.ifa_flags)
            if let addr = ptr.pointee.ifa_addr, (flags & IFF_UP) == IFF_UP, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ptr.pointee.ifa_name)
                if name.hasPrefix("en") { return "wifi" }
                if name.hasPrefix("pdp_ip") { result = "cellular" }
            }
            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }
        return result
    }
}

// MARK: - 网络状态

/// 用 NWPathMonitor 维护当前网络类型；上报时直接读缓存值，避免 ANPS 未就绪就误判 offline
final class NetworkStatus {
    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "net.status")
    private let lock = NSLock()
    private var cached = "unknown"

    var currentType: String {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let value: String
            if path.status != .satisfied {
                value = "offline"
            } else if path.usesInterfaceType(.wifi) {
                value = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                value = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                value = "ethernet"
            } else {
                value = "other"
            }
            self.lock.lock()
            self.cached = value
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }
}


// MARK: - 用户自定义设备名

/// iOS 16+ 起 UIDevice.current.name 只会返回通用名（"iPhone"），
/// 要拿"设置 → 通用 → 关于本机 → 名称"，得走 MobileGestalt 的 UserAssignedDeviceName，
/// 或者读 lockdown 记录。这里按优先级依次尝试。
private typealias MGCopyAnswerFunc = @convention(c) (CFString) -> Unmanaged<CFTypeRef>?

func MGCopyAnswerString(_ key: String) -> String? {
    guard let handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY) else { return nil }
    defer { dlclose(handle) }
    guard let sym = dlsym(handle, "MGCopyAnswer") else { return nil }
    let fn = unsafeBitCast(sym, to: MGCopyAnswerFunc.self)
    guard let value = fn(key as CFString) else { return nil }
    guard let obj = value.takeRetainedValue() as? String else { return nil }
    return obj
}

extension DeviceReporter {
    /// 通用名不算"用户设置的名字"（iOS16+ UIDevice.name / MobileGestalt 在未授权时都返回它）
    private static let genericNames: Set<String> = ["iPhone", "iPad", "iPod touch", "iPhone's iPhone", "iPad’s iPad"]

    /// 优先取用户自定义名称：MobileGestalt → lockdown 记录，全部来源都会打日志
    static func deviceDisplayName() -> String {
        var candidates: [(String, String)] = []
        if let mg = MGCopyAnswerString("UserAssignedDeviceName") { candidates.append(("mg.UserAssignedDeviceName", mg)) }
        if let mg2 = MGCopyAnswerString("DeviceName") { candidates.append(("mg.DeviceName", mg2)) }
        let plistPaths = [
            "/var/root/Library/Lockdown/data_ark.plist",
            "/private/var/root/Library/Lockdown/data_ark.plist",
            "/var/mobile/Library/Lockdown/data_ark.plist",
            "/var/containers/Shared/SystemGroup/systemgroup.com.apple.lockdownsoftware/Library/Lockdown/data_ark.plist",
        ]
        for path in plistPaths {
            if let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
               let name = dict["DeviceName"] as? String, !name.isEmpty {
                candidates.append((path, name))
            }
        }
        candidates.append(("UIDevice.name", UIDevice.current.name))

        let summary = candidates.map { "\($0.0)=\($0.1)" }.joined(separator: " | ")
        log("device-name 候选: \(summary)")

        for (_, name) in candidates where !name.isEmpty && !genericNames.contains(name) {
            log("device-name: 采用 \(name)")
            return name
        }
        let fallback = UIDevice.current.name
        log("device-name: 只剩通用名，回退 \(fallback)")
        return fallback
    }

    /// 语言标识：优先用系统首选语言（zh-Hans-CN → zh_CN），避免 en_CN 这种只带地区的值
    static func localeIdentifier() -> String {
        if let preferred = Locale.preferredLanguages.first, !preferred.isEmpty {
            let parts = preferred.split(separator: "-")
            if parts.count >= 2 {
                let lang = parts[0]
                let region = parts.last!
                if region.count == 2 { return "\(lang)_\(region)" }
                return "\(lang)_\(Locale.current.region?.identifier ?? "")"
            }
            return String(preferred)
        }
        return Locale.current.identifier
    }
}
