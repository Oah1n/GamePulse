import Foundation
import CryptoKit

enum CommunityAPIError: LocalizedError {
    case loginExpired(String)
    case invalidResponse(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .loginExpired(let service): "\(service)登录已失效，请重新授权"
        case .invalidResponse(let service): "\(service)返回了无法识别的数据"
        case .api(let message): message
        }
    }
}

struct SklandQRSession: Sendable {
    let scanID: String
    let url: String
}

enum SklandQRState: Sendable {
    case waiting
    case confirmed(token: String)
}

actor SklandLoginClient {
    static let shared = SklandLoginClient()

    private let appCode = "4ca99fa6b56cc2ba"

    func createQRLogin() async throws -> SklandQRSession {
        var request = URLRequest(url: URL(string: "https://as.hypergryph.com/general/v1/gen_scan/login")!)
        request.httpMethod = "POST"
        deviceHeaders().forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["appCode": appCode])
        let object = try await responseObject(request)
        guard number(object["status"]) == 0,
              let data = object["data"] as? [String: Any],
              let scanID = text(data["scanId"]),
              let url = text(data["scanUrl"]),
              !scanID.isEmpty, !url.isEmpty else {
            throw CommunityAPIError.api(text(object["msg"]) ?? "无法生成森空岛登录二维码")
        }
        return SklandQRSession(scanID: scanID, url: url)
    }

    func pollQRLogin(_ session: SklandQRSession) async throws -> SklandQRState {
        var components = URLComponents(string: "https://as.hypergryph.com/general/v1/scan_status")!
        components.queryItems = [URLQueryItem(name: "scanId", value: session.scanID)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        let object = try await responseObject(request)
        if number(object["status"]) == 0,
           let data = object["data"] as? [String: Any],
           let scanCode = text(data["scanCode"]),
           !scanCode.isEmpty {
            return .confirmed(token: try await token(by: scanCode))
        }
        let message = text(object["msg"]) ?? ""
        if message.contains("过期") || message.lowercased().contains("expire") {
            throw CommunityAPIError.api("森空岛二维码已过期，请重新生成")
        }
        return .waiting
    }

    private func token(by scanCode: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://as.hypergryph.com/user/auth/v1/token_by_scan_code")!)
        request.httpMethod = "POST"
        deviceHeaders().forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "scanCode": scanCode,
            "appCode": appCode
        ])
        let object = try await responseObject(request)
        guard number(object["status"]) == 0,
              let data = object["data"] as? [String: Any],
              let token = text(data["token"]), !token.isEmpty else {
            throw CommunityAPIError.api(text(object["msg"]) ?? "森空岛扫码登录失败")
        }
        return token
    }

    private func deviceHeaders() -> [String: String] {
        [
            "Content-Type": "application/json;charset=UTF-8",
            "X-DeviceId": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "X-DeviceModel": "Chrome",
            "X-DeviceType": "7",
            "X-OSVer": "macOS"
        ]
    }
}

actor KuroLoginClient {
    static let shared = KuroLoginClient()

    private let deviceCode: String = {
        let key = "GamePulse.kuroDeviceCode"
        if let saved = UserDefaults.standard.string(forKey: key), saved.count == 40 {
            return saved
        }
        let seed = Data(UUID().uuidString.utf8)
        let generated = SHA256.hash(data: seed)
            .map { String(format: "%02X", $0) }
            .joined()
            .prefix(40)
        let value = String(generated)
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()
    private let distinctID: String = {
        let key = "GamePulse.kuroDistinctID"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        let generated = UUID().uuidString.lowercased()
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }()

    func sendSMSCode(phone: String) async throws {
        let object = try await post(
            path: "/user/getSmsCode",
            fields: ["mobile": phone, "geeTestData": ""]
        )
        let code = number(object["code"])
        let message = text(object["msg"]) ?? "发送验证码失败"
        guard code == 200 else {
            throw CommunityAPIError.api("库街区：\(message)")
        }
        if let data = object["data"] as? [String: Any], bool(data["geeTest"]) {
            throw CommunityAPIError.api(
                "库街区要求人机验证。请先在库街区 App 或官方网页点击发送验证码，再将收到的验证码输入本程序。"
            )
        }
    }

    func login(phone: String, code: String) async throws -> String {
        let object = try await post(
            path: "/user/sdkLogin",
            fields: [
                "code": code,
                "devCode": deviceCode,
                "gameList": "",
                "mobile": phone
            ]
        )
        let responseCode = number(object["code"])
        guard responseCode == 200,
              let data = object["data"] as? [String: Any],
              let token = text(data["token"]), !token.isEmpty else {
            let message = text(object["msg"]) ?? (responseCode == -130 ? "验证码错误或已过期" : "登录失败")
            throw CommunityAPIError.api("库街区：\(message)")
        }
        return token
    }

    private func post(path: String, fields: [String: String]) async throws -> [String: Any] {
        var form = URLComponents()
        form.queryItems = fields.keys.sorted().map { URLQueryItem(name: $0, value: fields[$0]) }
        var request = URLRequest(url: URL(string: "https://api.kurobbs.com\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        loginHeaders().forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        return try await responseObject(request)
    }

    private func loginHeaders() -> [String: String] {
        [
            "osVersion": "Android",
            "devCode": deviceCode,
            "distinct_id": distinctID,
            "ip": "192.168.1.114",
            "countryCode": "CN",
            "model": "23127PN0CC",
            "source": "android",
            "lang": "zh-Hans",
            "version": "2.2.1",
            "versionCode": "2210",
            "channelId": "2",
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept-Encoding": "gzip",
            "User-Agent": "okhttp/3.11.0"
        ]
    }
}

struct SklandStatusService: StatusService {
    let accountToken: String

    private let userAgent = "Skland/1.5.1 (com.hypergryph.skland; build:100501001; Android 34; ) Okhttp/4.11.0"
    private let appCode = "4ca99fa6b56cc2ba"

    func fetch() async throws -> [GameStatus] {
        let token = try extractedAccountToken()
        let grant = try await postJSON(
            url: URL(string: "https://as.hypergryph.com/user/oauth2/v2/grant")!,
            body: ["appCode": appCode, "token": token, "type": 0],
            responseCodeKey: "status",
            service: "森空岛"
        )
        guard let grantData = grant["data"] as? [String: Any],
              let code = text(grantData["code"]), !code.isEmpty else {
            throw CommunityAPIError.invalidResponse("森空岛")
        }

        let credential = try await postJSON(
            url: URL(string: "https://zonai.skland.com/web/v1/user/auth/generate_cred_by_code")!,
            body: ["code": code, "kind": 1],
            responseCodeKey: "code",
            service: "森空岛"
        )
        guard let credentialData = credential["data"] as? [String: Any],
              let cred = text(credentialData["cred"]),
              let signToken = text(credentialData["token"]),
              !cred.isEmpty, !signToken.isEmpty else {
            throw CommunityAPIError.invalidResponse("森空岛")
        }

        let bindingURL = URL(string: "https://zonai.skland.com/api/v1/game/player/binding")!
        let binding = try await signedGET(url: bindingURL, cred: cred, signToken: signToken)
        guard let bindingData = binding["data"] as? [String: Any],
              let applications = bindingData["list"] as? [[String: Any]],
              let arknights = applications.first(where: { text($0["appCode"]) == "arknights" }),
              let roles = arknights["bindingList"] as? [[String: Any]],
              let role = preferredOfficialRole(roles),
              let uid = text(role["uid"]), !uid.isEmpty else {
            throw CommunityAPIError.api("森空岛中未找到已绑定的明日方舟官服角色")
        }

        var infoComponents = URLComponents(string: "https://zonai.skland.com/api/v1/game/player/info")!
        infoComponents.queryItems = [URLQueryItem(name: "uid", value: uid)]
        let info = try await signedGET(url: infoComponents.url!, cred: cred, signToken: signToken)
        guard let data = info["data"] as? [String: Any],
              let status = data["status"] as? [String: Any],
              let ap = status["ap"] as? [String: Any],
              let routine = data["routine"] as? [String: Any],
              let daily = routine["daily"] as? [String: Any] else {
            throw CommunityAPIError.invalidResponse("森空岛")
        }

        let now = Date()
        let serverTimestamp = number(data["currentTs"])
        let capturedAt = serverTimestamp > 1_500_000_000
            ? Date(timeIntervalSince1970: TimeInterval(serverTimestamp))
            : now
        let baseAP = number(ap["current"])
        let maximumAP = number(ap["max"])
        let fullTimestamp = number(ap["completeRecoveryTime"])
        let currentAP: Int
        if serverTimestamp > 0, fullTimestamp > serverTimestamp, maximumAP > 0 {
            let remainingSeconds = fullTimestamp - serverTimestamp
            let remainingAP = (remainingSeconds + 359) / 360
            currentAP = max(0, maximumAP - remainingAP)
        } else if serverTimestamp > 0, fullTimestamp > 0, fullTimestamp <= serverTimestamp {
            currentAP = maximumAP
        } else {
            // `completeRecoveryTime == -1` is used for over-cap sanity; in
            // that case the returned current value is already authoritative.
            currentAP = baseAP
        }
        let nickname = text(role["nickName"]) ?? text(status["name"]) ?? "博士"
        DiagnosticLog.write(
            "skland ap fields: base=\(baseAP), computed=\(currentAP), max=\(maximumAP), "
            + "lastAdd=\(number(ap["lastApAddTime"])), full=\(number(ap["completeRecoveryTime"])), "
            + "currentTs=\(serverTimestamp)"
        )
        return [GameStatus(
            id: .arknights,
            staminaName: "理智",
            stamina: StaminaSnapshot(
                current: currentAP,
                maximum: maximumAP,
                capturedAt: capturedAt,
                recoverySecondsPerUnit: 360
            ),
            dailyName: "日常任务",
            daily: DailyProgress(
                completed: number(daily["current"]),
                total: number(daily["total"])
            ),
            checklist: [],
            session: .active,
            message: "\(nickname) · UID \(uid.suffix(4))",
            updatedAt: now
        )]
    }

    private func extractedAccountToken() throws -> String {
        let trimmed = accountToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let nested = object["data"] as? [String: Any],
               let content = text(nested["content"]), !content.isEmpty {
                return content
            }
            if let content = text(object["content"]), !content.isEmpty {
                return content
            }
        }
        guard !trimmed.isEmpty else { throw CommunityAPIError.loginExpired("森空岛") }
        return trimmed
    }

    private func preferredOfficialRole(_ roles: [[String: Any]]) -> [String: Any]? {
        roles.first {
            text($0["channelName"])?.contains("官服") == true || text($0["channelMasterId"]) == "1"
        } ?? roles.first
    }

    private func postJSON(
        url: URL,
        body: [String: Any],
        responseCodeKey: String,
        service: String
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let object = try await responseObject(request)
        let code = number(object[responseCodeKey])
        guard code == 0 else {
            let message = text(object["message"]) ?? text(object["msg"]) ?? "授权失败"
            if message.contains("登录") || message.lowercased().contains("token") {
                throw CommunityAPIError.loginExpired(service)
            }
            throw CommunityAPIError.api("\(service)：\(message)")
        }
        return object
    }

    private func signedGET(url: URL, cred: String, signToken: String) async throws -> [String: Any] {
        let timestamp = String(Int(Date().timeIntervalSince1970) - 2)
        let deviceID = randomDeviceID()
        let signFields = "{\"platform\":\"1\",\"timestamp\":\"\(timestamp)\",\"dId\":\"\(deviceID)\",\"vName\":\"1.5.1\"}"
        // Skland signs the raw query string for GET endpoints that carry
        // parameters. The binding endpoint has none, while player/info must
        // include `uid=...` or the server rejects an otherwise valid request.
        let body = url.query ?? ""
        let source = url.path + body + timestamp + signFields
        let key = SymmetricKey(data: Data(signToken.utf8))
        let authentication = HMAC<SHA256>.authenticationCode(for: Data(source.utf8), using: key)
        let hmacHex = authentication.map { String(format: "%02x", $0) }.joined()
        let signature = Insecure.MD5.hash(data: Data(hmacHex.utf8))
            .map { String(format: "%02x", $0) }.joined()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue(cred, forHTTPHeaderField: "cred")
        request.setValue(signature, forHTTPHeaderField: "sign")
        request.setValue(timestamp, forHTTPHeaderField: "timestamp")
        request.setValue("1", forHTTPHeaderField: "platform")
        request.setValue(deviceID, forHTTPHeaderField: "dId")
        request.setValue("1.5.1", forHTTPHeaderField: "vName")

        let object = try await responseObject(request)
        guard number(object["code"]) == 0 else {
            let message = text(object["message"]) ?? "请求失败"
            if message.contains("登录") || message.lowercased().contains("cred") {
                throw CommunityAPIError.loginExpired("森空岛")
            }
            throw CommunityAPIError.api("森空岛：\(message)")
        }
        return object
    }

    private func randomDeviceID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct KuroStatusService: StatusService {
    let token: String

    func fetch() async throws -> [GameStatus] {
        let cleanToken = extractedToken()
        guard !cleanToken.isEmpty else { throw CommunityAPIError.loginExpired("库街区") }

        let rolesObject = try await post(
            url: URL(string: "https://api.kurobbs.com/gamer/role/list")!,
            fields: ["gameId": "3"],
            token: cleanToken
        )
        guard let roles = rolesObject["data"] as? [[String: Any]],
              let role = roles.first(where: { bool($0["isDefault"]) }) ?? roles.first,
              let roleID = text(role["roleId"]),
              let serverID = text(role["serverId"]) else {
            throw CommunityAPIError.api("库街区中未找到已绑定的鸣潮官服角色")
        }

        let widgetObject = try await post(
            url: URL(string: "https://api.kurobbs.com/gamer/widget/game3/refresh")!,
            fields: [
                "gameId": "3",
                "roleId": roleID,
                "serverId": serverID,
                "type": "2",
                "sizeType": "1"
            ],
            token: cleanToken
        )
        guard let data = widgetObject["data"] as? [String: Any],
              let energy = data["energyData"] as? [String: Any],
              let liveness = data["livenessData"] as? [String: Any] else {
            throw CommunityAPIError.invalidResponse("库街区")
        }

        let capturedAt: Date
        let serverTime = number(data["serverTime"])
        if serverTime > 1_500_000_000 {
            capturedAt = Date(timeIntervalSince1970: TimeInterval(serverTime))
        } else {
            capturedAt = Date()
        }
        let nickname = text(role["roleName"]) ?? text(data["roleName"]) ?? "漂泊者"
        let signedIn = bool(data["hasSignIn"])
        return [GameStatus(
            id: .wutheringWaves,
            staminaName: text(energy["name"]) ?? "结晶波片",
            stamina: StaminaSnapshot(
                current: number(energy["cur"]),
                maximum: number(energy["total"]),
                capturedAt: capturedAt,
                recoverySecondsPerUnit: 360
            ),
            dailyName: text(liveness["name"]) ?? "每日活跃",
            daily: DailyProgress(
                completed: number(liveness["cur"]),
                total: number(liveness["total"])
            ),
            checklist: [
                ChecklistItem(
                    id: "kuro-sign-in",
                    title: "库街区签到",
                    isComplete: signedIn,
                    detail: signedIn ? "已完成" : "待完成"
                )
            ],
            session: .active,
            message: "\(nickname) · UID \(roleID.suffix(4))",
            updatedAt: Date()
        )]
    }

    private func extractedToken() -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "token=") {
            return String(trimmed[range.upperBound...].prefix { $0 != ";" && !$0.isWhitespace })
        }
        return trimmed
    }

    private func post(url: URL, fields: [String: String], token: String) async throws -> [String: Any] {
        var components = URLComponents()
        components.queryItems = fields.keys.sorted().map { URLQueryItem(name: $0, value: fields[$0]) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Android", forHTTPHeaderField: "osVersion")
        request.setValue("073A9EFAC18FC50616DD15808DAE719DBCB904B7", forHTTPHeaderField: "devCode")
        request.setValue("CN", forHTTPHeaderField: "countryCode")
        request.setValue("android", forHTTPHeaderField: "source")
        request.setValue("zh-Hans", forHTTPHeaderField: "lang")
        request.setValue("2.2.1", forHTTPHeaderField: "version")
        request.setValue("2210", forHTTPHeaderField: "versionCode")
        request.setValue("23127PN0CC", forHTTPHeaderField: "model")
        request.setValue(token, forHTTPHeaderField: "token")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("okhttp/3.11.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let object = try await responseObject(request)
        let code = number(object["code"])
        guard code == 200 else {
            let message = text(object["msg"]) ?? "请求失败"
            if code == 220 || message.contains("登录") || message.lowercased().contains("token") {
                throw CommunityAPIError.loginExpired("库街区")
            }
            throw CommunityAPIError.api("库街区：\(message)")
        }
        return object
    }
}

private func responseObject(_ request: URLRequest) async throws -> [String: Any] {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw CommunityAPIError.invalidResponse(request.url?.host ?? "数据源")
    }
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let responseCode = object.flatMap { text($0["code"]) ?? text($0["status"]) } ?? "non-json"
    let responseMessage = object.flatMap { text($0["message"]) ?? text($0["msg"]) } ?? ""
    DiagnosticLog.write(
        "community response \(request.url?.host ?? "unknown")\(request.url?.path ?? ""): "
        + "http=\(http.statusCode), code=\(responseCode), message=\(responseMessage.prefix(80)), bytes=\(data.count)"
    )
    guard (200..<300).contains(http.statusCode), let object else {
        throw CommunityAPIError.api(
            responseMessage.isEmpty
                ? "\(request.url?.host ?? "数据源") 请求失败（HTTP \(http.statusCode)）"
                : responseMessage
        )
    }
    return object
}

private func text(_ value: Any?) -> String? {
    switch value {
    case let string as String: string
    case let number as NSNumber: number.stringValue
    default: nil
    }
}

private func number(_ value: Any?) -> Int {
    switch value {
    case let number as NSNumber: number.intValue
    case let string as String: Int(string) ?? 0
    default: 0
    }
}

private func bool(_ value: Any?) -> Bool {
    switch value {
    case let value as Bool: value
    case let number as NSNumber: number.boolValue
    case let string as String: ["true", "1"].contains(string.lowercased())
    default: false
    }
}
