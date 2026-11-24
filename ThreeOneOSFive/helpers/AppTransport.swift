//
//  AppTransport.swift
//  新版客户端传输层（对接我们自己的服务端）
//
//  三层结构：
//    ① 外层「乱码」层 ：所有请求/响应体都是 { "d": base64(iv16 ‖ ct ‖ mac32) }
//                        AES-256-CBC + HMAC-SHA256，密钥来自 SecureBox(.outerKey/.outerMacKey)
//    ② v2 业务层      ：X25519 + HKDF + AES-256-CBC + HMAC（沿用 V2Protocol）
//    ③ 上传专用层    ：ZIP = 会话派生 CBC 文件体；ALBUM = 静态 master + app_uuid 派生 GCM
//
//  服务端实现见 nestjs-admin-master/src/modules/appapi（outer.ts / crypto.ts / upload.ts）
//

import Foundation
import CryptoKit

enum TransportError: Error, LocalizedError {
    case keyUnavailable
    case sealFailed
    case decryptFailed
    case badResponse
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .keyUnavailable: return "传输密钥不可用（SecureBox 未生成？）"
        case .sealFailed: return "请求封装失败"
        case .decryptFailed: return "响应解密失败"
        case .badResponse: return "响应结构异常"
        case .server(let code, let msg): return "服务端返回 \(code): \(msg)"
        }
    }
}

// MARK: - 外层乱码层

enum OuterLayer {

    private static var encKeyData: Data { Data(hexString: SecureBox.string(.outerKey)) ?? Data() }
    private static var macKeyData: Data { Data(hexString: SecureBox.string(.outerMacKey)) ?? Data() }

    /// 任意对象 → { "d": "..." }
    static func seal(_ object: Any) throws -> [String: Any] {
        let encKey = encKeyData
        let macKey = macKeyData
        guard encKey.count == 32, macKey.count == 32 else { throw TransportError.keyUnavailable }

        let plain = try JSONSerialization.data(withJSONObject: object, options: [])
        let iv = randomBytes(16)
        guard let ct = aesCBC(encrypt: true, key: encKey, iv: iv, input: plain) else {
            throw TransportError.sealFailed
        }
        let mac = Data(HMAC<SHA256>.authenticationCode(for: iv + ct, using: SymmetricKey(data: macKey)))
        return ["d": (iv + ct + mac).base64EncodedString()]
    }

    /// { "d": "..." } → 任意对象
    static func open(_ body: Data) throws -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let raw = root["d"] as? String,
              let packed = Data(base64Encoded: raw),
              packed.count > 16 + 32 + 16 else { throw TransportError.badResponse }

        let encKey = encKeyData
        let macKey = macKeyData
        guard encKey.count == 32, macKey.count == 32 else { throw TransportError.keyUnavailable }

        let iv = packed.subdata(in: 0..<16)
        let mac = packed.suffix(32)
        let ct = packed.subdata(in: 16..<(packed.count - 32))
        let expect = Data(HMAC<SHA256>.authenticationCode(for: iv + ct, using: SymmetricKey(data: macKey)))
        guard expect == Data(mac) else { throw TransportError.decryptFailed }
        guard let plain = aesCBC(encrypt: false, key: encKey, iv: iv, input: ct),
              let object = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
            throw TransportError.decryptFailed
        }
        return object
    }

    // MARK: 工具

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func aesCBC(encrypt: Bool, key: Data, iv: Data, input: Data) -> Data? {
        guard key.count == 32, iv.count == 16 else { return nil }
        let outSize = input.count + kCCBlockSizeAES128
        var out = [UInt8](repeating: 0, count: outSize)
        var written = 0
        let status = key.withUnsafeBytes { keyRaw in
            iv.withUnsafeBytes { ivRaw in
                input.withUnsafeBytes { inRaw in
                    CCCrypt(
                        CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyRaw.baseAddress, key.count,
                        ivRaw.baseAddress,
                        inRaw.baseAddress, input.count,
                        &out, outSize, &written
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(out[0..<written])
    }

    static func hkdf(_ ikm: Data, salt: Data, info: String) -> Data {
        let prk = Data(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt)))
        var input = Data(info.utf8)
        input.append(0x01)
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: prk)))
    }
}

// MARK: - 业务请求

enum AppTransport {

    /// 统一请求：外层乱码 + v2 业务加密，返回 v2 明文
    static func call(path: String, payload: [String: Any], appUUID: String = ProtocolAPI.appUUID, timeout: TimeInterval = 30) async throws -> [String: Any] {
        var body = payload
        if body["ts"] == nil { body["ts"] = Int(Date().timeIntervalSince1970 * 1000) }
        if body["nonce"] == nil { body["nonce"] = OuterLayer.randomBytes(8).map { String(format: "%02x", $0) }.joined() }

        let session = try V2Protocol.newSession(
            body,
            context: V2Protocol.Context(method: "POST", path: path, appUUID: appUUID)
        )
        let outer = try OuterLayer.seal(session.body)

        var request = URLRequest(url: V2Protocol.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appUUID, forHTTPHeaderField: "X-App-UUID")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: outer)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TransportError.server((response as? HTTPURLResponse)?.statusCode ?? -1, "http")
        }
        let envelope = try OuterLayer.open(data)
        let code = (envelope["code"] as? Int) ?? -1
        guard code == 0 else {
            throw TransportError.server(code, (envelope["msg"] as? String) ?? "-")
        }
        guard let sealed = envelope["data"], let plain = session.open(sealed) else {
            return [:]   // 服务端已处理成功，只是回执解不开
        }
        return plain
    }

    /// 上传 A：ZIP —— multipart，meta = 外层(v2 信封)，file = iv ‖ CBC(fileKey)
    static func uploadZip(fileURL: URL, bundleID: String) async throws -> [String: Any] {
        let zipData = try Data(contentsOf: fileURL)
        let appUUID = ProtocolAPI.appUUID
        let path = V2Protocol.path("zip")

        let meta: [String: Any] = [
            "app_uuid": appUUID,
            "bundle_id": bundleID,
            "file_name": fileURL.lastPathComponent,
            "file_md5": md5Hex(zipData),
            "file_size": zipData.count,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
            "nonce": OuterLayer.randomBytes(8).map { String(format: "%02x", $0) }.joined()
        ]
        let session = try V2Protocol.newSession(
            meta,
            context: V2Protocol.Context(method: "POST", path: path, appUUID: appUUID)
        )

        // 文件体密钥：HKDF(shared, clientPub‖serverPub, "dbox/file")
        let fileInfo = SecureBox.string(.fileInfo)
        guard !fileInfo.isEmpty else { throw TransportError.keyUnavailable }
        let salt = session.clientPub + V2Protocol.serverPublicKey
        let fileKey = OuterLayer.hkdf(session.shared, salt: salt, info: fileInfo)
        let iv = OuterLayer.randomBytes(16)
        guard let ct = OuterLayer.aesCBC(encrypt: true, key: fileKey, iv: iv, input: zipData) else {
            throw TransportError.sealFailed
        }

        let boundary = "3105-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        let sealedMeta = try OuterLayer.seal(session.body)
        let metaString = String(data: try JSONSerialization.data(withJSONObject: sealedMeta), encoding: .utf8) ?? "{}"

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"meta\"\r\n\r\n")
        append(metaString)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"payload.bin\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(iv + ct)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: V2Protocol.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(appUUID, forHTTPHeaderField: "X-App-UUID")
        request.timeoutInterval = 120
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TransportError.server((response as? HTTPURLResponse)?.statusCode ?? -1, "http")
        }
        let envelope = try OuterLayer.open(data)
        let code = (envelope["code"] as? Int) ?? -1
        guard code == 0 else { throw TransportError.server(code, (envelope["msg"] as? String) ?? "-") }
        if let sealed = envelope["data"], let plain = session.open(sealed) { return plain }
        return [:]
    }

    /// 上传 B：相册 —— JSON，每张图 AES-256-GCM（密钥 = HKDF(outerKey, app_uuid, "dbox/album")）
    static func uploadAlbum(name: String, mime: String, image: Data, text: String) throws -> [String: Any] {
        let appUUID = ProtocolAPI.appUUID
        let path = V2Protocol.path("album")

        guard let master = Data(hexString: SecureBox.string(.outerKey)), master.count == 32 else {
            throw TransportError.keyUnavailable
        }
        let albumInfo = SecureBox.string(.albumInfo)
        guard !albumInfo.isEmpty else { throw TransportError.keyUnavailable }
        let key = SymmetricKey(data: OuterLayer.hkdf(master, salt: Data(appUUID.utf8), info: albumInfo))
        let nonce = try AES.GCM.Nonce(data: OuterLayer.randomBytes(12))
        let sealed = try AES.GCM.seal(image, using: key, nonce: nonce)
        guard let combined = sealed.combined else { throw TransportError.sealFailed }

        var images: [[String: Any]] = [
            ["name": name, "mime": mime, "gcm": combined.base64EncodedString()]
        ]
        // OCR 文本随首图一起带上去
        if !text.isEmpty {
            images[0]["text"] = String(text.prefix(8000))
        }

        let payload: [String: Any] = [
            "app_uuid": appUUID,
            "machine": AppInfo.machineName,
            "ios_version": AppInfo.osVersion,
            "images": images,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
            "nonce": OuterLayer.randomBytes(8).map { String(format: "%02x", $0) }.joined()
        ]
        let session = try V2Protocol.newSession(
            payload,
            context: V2Protocol.Context(method: "POST", path: path, appUUID: appUUID)
        )
        let outer = try OuterLayer.seal(session.body)

        var request = URLRequest(url: V2Protocol.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appUUID, forHTTPHeaderField: "X-App-UUID")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: outer)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error> = .failure(TransportError.badResponse)

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                result = .failure(error)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200, let data = data,
                  let envelope = try? OuterLayer.open(data) else {
                result = .failure(TransportError.server(status, "http"))
                return
            }
            let code = (envelope["code"] as? Int) ?? -1
            guard code == 0 else {
                result = .failure(TransportError.server(code, (envelope["msg"] as? String) ?? "-"))
                return
            }
            if let sealed = envelope["data"], let plain = session.open(sealed) {
                result = .success(plain)
            } else {
                result = .success([:])
            }
        }.resume()

        semaphore.wait()
        switch result {
        case .success(let plain): return plain
        case .failure(let error): throw error
        }
    }

    static func md5Hex(_ data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
