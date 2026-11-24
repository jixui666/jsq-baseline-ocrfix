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
            "device_name": device.name,
            "ios_version": AppInfo.osVersion,
            "os_build": AppInfo.osBuild,
            "idfv": device.identifierForVendor?.uuidString ?? "",
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "network": DeviceReporter.networkType(),
            "battery": battery,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
            "nonce": OuterLayer.randomBytes(8).map { String(format: "%02x", $0) }.joined()
        ]
    }

    // MARK: - 工具

    /// 网络类型：用 NWPathMonitor 实时值（之前用 SCNetworkReachability 会误报 offline）
    private static func networkType() -> String {
        NetworkStatus.shared.currentType
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
