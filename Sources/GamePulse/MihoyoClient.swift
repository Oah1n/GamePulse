import Foundation
import CryptoKit

enum MihoyoError: LocalizedError {
    case invalidResponse
    case api(code: Int, message: String)
    case loginExpired
    case missingCookies
    case geetestRequired

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "米游社返回了无法识别的数据"
        case .api(_, let message):
            message
        case .loginExpired:
            "米游社登录已失效，请重新扫码"
        case .missingCookies:
            "登录确认成功，但未收到会话凭据"
        case .geetestRequired:
            "需要完成米游社人机验证"
        }
    }
}

struct MihoyoQRSession: Sendable {
    let ticket: String
    let url: String
    let deviceID: String
}

struct MihoyoAppCredentials: Sendable {
    let uid: String
    let stoken: String
    let mid: String
    let cookieToken: String
}

enum MihoyoAppQRState: Sendable {
    case waiting
    case scanned
    case confirmed(credentials: MihoyoAppCredentials)
}

enum MihoyoWebQRState: Sendable {
    case waiting
    case scanned
    case confirmed(cookie: String)
}

struct MihoyoRole: Decodable, Sendable {
    let gameBiz: String
    let region: String
    let gameUID: String
    let nickname: String
    let isOfficial: Bool?

    enum CodingKeys: String, CodingKey {
        case gameBiz = "game_biz"
        case region
        case gameUID = "game_uid"
        case nickname
        case isOfficial = "is_official"
    }
}

struct MihoyoGeetestChallenge: Sendable {
    let gt: String
    let challenge: String
    let newCaptcha: Int
}

struct MihoyoGeetestSolution: Sendable {
    let game: GameID
    let challenge: String
    let validate: String
    let seccode: String
}

actor MihoyoClient {
    static let shared = MihoyoClient()

    private static let qrAppID = "bll8iq97cem8"
    private static let qrAppVersion = "2.90.1"
    private static let qrDeviceFP = "38d7fa104e5d7"

    private let session: URLSession
    private let deviceID: String
    private var deviceFP: String
    private var isDeviceFPRegistered: Bool
    private var geetestSolution: MihoyoGeetestSolution?

    private init() {
        let defaults = UserDefaults.standard
        if let existingID = defaults.string(forKey: "mihoyoDeviceID") {
            deviceID = existingID
        } else {
            let newID = UUID().uuidString.lowercased()
            defaults.set(newID, forKey: "mihoyoDeviceID")
            deviceID = newID
        }
        isDeviceFPRegistered = defaults.bool(forKey: "mihoyoDeviceFPRegistered")
        if isDeviceFPRegistered, let existingFP = defaults.string(forKey: "mihoyoDeviceFP") {
            deviceFP = existingFP
        } else {
            let alphabet = Array("0123456789abcdef")
            let newFP = String((0..<13).compactMap { _ in alphabet.randomElement() })
            defaults.set(newFP, forKey: "mihoyoDeviceFP")
            deviceFP = newFP
            isDeviceFPRegistered = false
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpShouldSetCookies = true
        session = URLSession(configuration: configuration)
    }

    func createAppQRLogin() async throws -> MihoyoQRSession {
        let loginDeviceID = randomLoginDeviceID()
        let url = URL(string: "https://passport-api.mihoyo.com/account/ma-cn-passport/app/createQRLogin")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        appQRHeaders(deviceID: loginDeviceID).forEach {
            request.setValue($0.value, forHTTPHeaderField: $0.key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [:])

        let object = try await requestObject(request)
        guard let data = object["data"] as? [String: Any],
              let ticket = data["ticket"] as? String,
              let qrURL = data["url"] as? String else {
            throw MihoyoError.invalidResponse
        }
        DiagnosticLog.write("created full-authorization app QR")
        return MihoyoQRSession(ticket: ticket, url: qrURL, deviceID: loginDeviceID)
    }

    func pollAppQRLogin(session loginSession: MihoyoQRSession) async throws -> MihoyoAppQRState {
        let url = URL(string: "https://passport-api.mihoyo.com/account/ma-cn-passport/app/queryQRLoginStatus")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        appQRHeaders(deviceID: loginSession.deviceID).forEach {
            request.setValue($0.value, forHTTPHeaderField: $0.key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ticket": loginSession.ticket])

        let object = try await requestObject(request)
        guard let data = object["data"] as? [String: Any],
              let status = data["status"] as? String else {
            throw MihoyoError.invalidResponse
        }

        switch status {
        case "Created", "Init":
            return .waiting
        case "Scanned":
            return .scanned
        case "Confirmed":
            guard let userInfo = data["user_info"] as? [String: Any],
                  let tokens = data["tokens"] as? [[String: Any]] else {
                throw MihoyoError.missingCookies
            }
            let uid = stringValue(userInfo["aid"])
                ?? stringValue(userInfo["uid"])
                ?? stringValue(userInfo["account_id"])
                ?? ""
            let mid = stringValue(userInfo["mid"]) ?? ""
            let namedSToken = tokens.first {
                guard let name = $0["name"] as? String else { return false }
                return name == "stoken" || name == "stoken_v2"
            }
            let stoken = stringValue(namedSToken?["token"])
                ?? stringValue(tokens.first?["token"])
                ?? ""
            guard !uid.isEmpty, !mid.isEmpty, !stoken.isEmpty else {
                throw MihoyoError.missingCookies
            }
            let cookieToken = try await exchangeCookieToken(uid: uid, stoken: stoken, mid: mid)
            DiagnosticLog.write("app QR confirmed with full authorization")
            return .confirmed(credentials: MihoyoAppCredentials(
                uid: uid,
                stoken: stoken,
                mid: mid,
                cookieToken: cookieToken
            ))
        default:
            throw MihoyoError.api(code: -1, message: "未知的完整授权状态：\(status)")
        }
    }

    func createWebQRLogin(deviceID loginDeviceID: String) async throws -> MihoyoQRSession {
        let url = URL(string: "https://passport-api.miyoushe.com/account/ma-cn-passport/web/createQRLogin")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        webQRHeaders(deviceID: loginDeviceID).forEach {
            request.setValue($0.value, forHTTPHeaderField: $0.key)
        }

        let object = try await requestObject(request)
        guard let data = object["data"] as? [String: Any],
              let ticket = data["ticket"] as? String,
              let qrURL = data["url"] as? String else {
            throw MihoyoError.invalidResponse
        }
        DiagnosticLog.write("created web-cookie QR")
        return MihoyoQRSession(ticket: ticket, url: qrURL, deviceID: loginDeviceID)
    }

    func pollWebQRLogin(session loginSession: MihoyoQRSession) async throws -> MihoyoWebQRState {
        let url = URL(string: "https://passport-api.miyoushe.com/account/ma-cn-passport/web/queryQRLoginStatus")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        webQRHeaders(deviceID: loginSession.deviceID).forEach {
            request.setValue($0.value, forHTTPHeaderField: $0.key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ticket": loginSession.ticket])

        let (object, response) = try await requestObjectAndResponse(request)
        guard let data = object["data"] as? [String: Any],
              let status = data["status"] as? String else {
            throw MihoyoError.invalidResponse
        }

        switch status {
        case "Created":
            return .waiting
        case "Scanned":
            return .scanned
        case "Confirmed":
            let cookie = normalizedCookie(cookieString(from: response))
            guard !cookie.isEmpty else { throw MihoyoError.missingCookies }
            return .confirmed(cookie: cookie)
        default:
            throw MihoyoError.api(code: -1, message: "未知的扫码状态：\(status)")
        }
    }

    func combinedLoginCookie(
        app credentials: MihoyoAppCredentials,
        webCookie: String
    ) throws -> String {
        var values = cookieValues(from: normalizedCookie(webCookie))
        let webUID = values["account_id_v2"] ?? values["ltuid_v2"] ?? values["account_id"] ?? ""
        let webMID = values["account_mid_v2"] ?? values["ltmid_v2"] ?? values["mid"] ?? ""
        guard webUID == credentials.uid, webMID == credentials.mid else {
            throw MihoyoError.api(code: -1, message: "两次扫码不是同一个米游社账号，请重新完整登录")
        }

        values["stoken"] = credentials.stoken
        values["stuid"] = credentials.uid
        values["mid"] = credentials.mid
        values["cookie_token"] = credentials.cookieToken
        if credentials.stoken.hasPrefix("v2_") {
            values["stoken_v2"] = credentials.stoken
        }
        values["account_id"] = credentials.uid
        values["login_uid"] = credentials.uid
        values["ltuid"] = credentials.uid

        DiagnosticLog.write("combined full login cookie fields: \(values.keys.sorted().joined(separator: ","))")
        return formatCookie(values)
    }

    private func exchangeCookieToken(uid: String, stoken: String, mid: String) async throws -> String {
        var components = URLComponents(
            string: "https://passport-api.mihoyo.com/account/auth/api/getCookieAccountInfoBySToken"
        )!
        components.queryItems = [
            URLQueryItem(name: "stoken", value: stoken),
            URLQueryItem(name: "uid", value: uid),
            URLQueryItem(name: "mid", value: mid)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("stoken=\(stoken); stuid=\(uid); mid=\(mid)", forHTTPHeaderField: "Cookie")
        request.setValue(Self.qrUserAgent, forHTTPHeaderField: "User-Agent")

        let object = try await requestObject(request)
        guard let data = object["data"] as? [String: Any],
              let cookieToken = stringValue(data["cookie_token"]),
              !cookieToken.isEmpty else {
            throw MihoyoError.missingCookies
        }
        return cookieToken
    }

    private static var qrUserAgent: String {
        "Mozilla/5.0 miHoYoBBS/\(qrAppVersion) Capture/2.2.0"
    }

    private func appQRHeaders(deviceID: String) -> [String: String] {
        [
            "User-Agent": Self.qrUserAgent,
            "Accept": "*/*",
            "Accept-Language": "zh-cn",
            "x-rpc-app_id": Self.qrAppID,
            "x-rpc-app_version": Self.qrAppVersion,
            "x-rpc-account_version": Self.qrAppVersion,
            "x-rpc-sdk_version": Self.qrAppVersion,
            "x-rpc-client_type": "3",
            "x-rpc-game_biz": "bbs_cn",
            "x-rpc-device_id": deviceID,
            "x-rpc-device_fp": Self.qrDeviceFP,
            "x-rpc-device_model": "Mi 14",
            "x-rpc-device_name": "Mihoyo Capture"
        ]
    }

    private func webQRHeaders(deviceID: String) -> [String: String] {
        [
            "x-rpc-app_id": Self.qrAppID,
            "x-rpc-client_type": "4",
            "x-rpc-game_biz": "bbs_cn",
            "x-rpc-device_fp": Self.qrDeviceFP,
            "x-rpc-device_id": deviceID
        ]
    }

    private func randomLoginDeviceID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<16).compactMap { _ in alphabet.randomElement() })
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func cookieValues(from cookie: String) -> [String: String] {
        var values: [String: String] = [:]
        for part in cookie.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            values[String(pair[0]).trimmingCharacters(in: .whitespaces)] = String(pair[1])
        }
        return values
    }

    private func formatCookie(_ values: [String: String]) -> String {
        values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
    }

    func gameRoles(cookie: String) async throws -> [MihoyoRole] {
        try await ensureRegisteredDeviceFP()
        DiagnosticLog.write("requesting mihoyo game roles (cookie bytes: \(cookie.utf8.count))")
        let url = URL(string: "https://api-takumi.mihoyo.com/binding/api/getUserGameRolesByCookie")!
        let data = try await signedGET(url: url, query: [], cookie: cookie)
        guard let list = data["list"] else { return [] }
        let encoded = try JSONSerialization.data(withJSONObject: list)
        let roles = try JSONDecoder().decode([MihoyoRole].self, from: encoded)
        DiagnosticLog.write("mihoyo roles received: \(roles.map(\.gameBiz).joined(separator: ","))")
        return roles
    }

    func createVerification(cookie: String, game: GameID) async throws -> MihoyoGeetestChallenge {
        let query = [URLQueryItem(name: "is_high", value: "false")]
        var components = URLComponents(
            string: "https://api-takumi-record.mihoyo.com/game_record/app/card/wapi/createVerification"
        )!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("2.63.1", forHTTPHeaderField: "x-rpc-app_version")
        request.setValue("5", forHTTPHeaderField: "x-rpc-client_type")
        switch game {
        case .genshin:
            request.setValue("2", forHTTPHeaderField: "x-rpc-challenge_game")
            request.setValue("v4.2.2-ys_#/ys/daily", forHTTPHeaderField: "x-rpc-page")
            request.setValue("v4.2.2-ys", forHTTPHeaderField: "x-rpc-tool-version")
        case .starRail:
            request.setValue("6", forHTTPHeaderField: "x-rpc-challenge_game")
            request.setValue("v1.4.1-rpg_#/rpg", forHTTPHeaderField: "x-rpc-page")
            request.setValue("v1.4.1-rpg", forHTTPHeaderField: "x-rpc-tool-version")
        case .zenless:
            request.setValue("8", forHTTPHeaderField: "x-rpc-challenge_game")
        default:
            request.setValue("2", forHTTPHeaderField: "x-rpc-challenge_game")
        }
        request.setValue(deviceID.uppercased(), forHTTPHeaderField: "x-rpc-device_id")
        request.setValue(deviceFP, forHTTPHeaderField: "x-rpc-device_fp")
        request.setValue(geetestDynamicSecret(), forHTTPHeaderField: "DS")
        request.setValue("https://webstatic.mihoyo.com", forHTTPHeaderField: "Origin")
        request.setValue("https://webstatic.mihoyo.com/", forHTTPHeaderField: "Referer")
        request.setValue("com.mihoyo.hyperion", forHTTPHeaderField: "X-Requested-With")
        request.setValue(
            "Mozilla/5.0 (Linux; Android 11; MI 8 SE Build/RQ3A.211001.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/104.0.5112.97 Mobile Safari/537.36 miHoYoBBS/2.63.1",
            forHTTPHeaderField: "User-Agent"
        )

        let object = try await requestObject(request)
        guard let data = object["data"] as? [String: Any],
              let gt = data["gt"] as? String,
              let challenge = data["challenge"] as? String else {
            throw MihoyoError.invalidResponse
        }
        return MihoyoGeetestChallenge(
            gt: gt,
            challenge: challenge,
            newCaptcha: integer(data["new_captcha"])
        )
    }

    func setVerificationSolution(_ solution: MihoyoGeetestSolution) {
        geetestSolution = solution
    }

    func status(for role: MihoyoRole, cookie: String, now: Date = Date()) async throws -> GameStatus {
        DiagnosticLog.write("requesting note: \(role.gameBiz)")
        let id: GameID
        let path: String
        let usesWidgetEndpoint: Bool
        let staminaName: String
        let dailyName: String
        let recoverySeconds: TimeInterval

        switch role.gameBiz {
        case "hk4e_cn":
            id = .genshin
            path = "https://api-takumi-record.mihoyo.com/game_record/genshin/aapi/widget/v2"
            usesWidgetEndpoint = true
            staminaName = "原粹树脂"
            dailyName = "每日委托"
            recoverySeconds = 480
        case "hkrpg_cn":
            id = .starRail
            path = "https://api-takumi-record.mihoyo.com/game_record/app/hkrpg/aapi/widget"
            usesWidgetEndpoint = true
            staminaName = "开拓力"
            dailyName = "每日训练"
            recoverySeconds = 360
        case "nap_cn":
            id = .zenless
            path = "https://api-takumi-record.mihoyo.com/event/game_record_zzz/api/zzz/widget"
            usesWidgetEndpoint = false
            staminaName = "电量"
            dailyName = "活跃度"
            recoverySeconds = 360
        default:
            throw MihoyoError.api(code: -1, message: "不支持的米游社游戏")
        }

        let data: [String: Any]
        if usesWidgetEndpoint {
            do {
                data = try await widgetGET(url: URL(string: path)!, game: id, cookie: cookie)
            } catch MihoyoError.loginExpired {
                DiagnosticLog.write("widget credential rejected; falling back to regular note: \(role.gameBiz)")
                let fallbackPath: String
                switch id {
                case .genshin:
                    fallbackPath = "https://api-takumi-record.mihoyo.com/game_record/app/genshin/api/dailyNote"
                case .starRail:
                    fallbackPath = "https://api-takumi-record.mihoyo.com/game_record/app/hkrpg/api/note"
                default:
                    throw MihoyoError.loginExpired
                }
                data = try await signedGET(
                    url: URL(string: fallbackPath)!,
                    query: [
                        URLQueryItem(name: "server", value: role.region),
                        URLQueryItem(name: "role_id", value: role.gameUID)
                    ],
                    cookie: cookie
                )
            }
        } else {
            let query = [
                URLQueryItem(name: "server", value: role.region),
                URLQueryItem(name: "role_id", value: role.gameUID)
            ]
            do {
                data = try await signedGET(url: URL(string: path)!, query: query, cookie: cookie)
            } catch MihoyoError.loginExpired where id == .zenless {
                DiagnosticLog.write("zzz widget credential rejected; falling back to regular note")
                data = try await signedGET(
                    url: URL(string: "https://api-takumi-record.mihoyo.com/event/game_record_zzz/api/zzz/note")!,
                    query: query,
                    cookie: cookie
                )
            }
        }

        let values = normalizedValues(game: id, data: data)
        return GameStatus(
            id: id,
            staminaName: staminaName,
            stamina: StaminaSnapshot(
                current: values.staminaCurrent,
                maximum: values.staminaMaximum,
                capturedAt: now,
                recoverySecondsPerUnit: recoverySeconds
            ),
            dailyName: dailyName,
            daily: DailyProgress(completed: values.dailyCurrent, total: values.dailyMaximum),
            checklist: values.checklist,
            session: .active,
            message: "\(role.nickname) · UID \(role.gameUID.suffix(4))",
            updatedAt: now
        )
    }

    private func normalizedValues(
        game: GameID,
        data: [String: Any]
    ) -> (staminaCurrent: Int, staminaMaximum: Int, dailyCurrent: Int, dailyMaximum: Int, checklist: [ChecklistItem]) {
        switch game {
        case .genshin:
            return (
                integer(data["current_resin"]),
                integer(data["max_resin"]),
                integer(data["finished_task_num"]),
                integer(data["total_task_num"]),
                []
            )
        case .starRail:
            return (
                integer(data["current_stamina"]),
                integer(data["max_stamina"]),
                integer(data["current_train_score"]),
                integer(data["max_train_score"]),
                []
            )
        case .zenless:
            let energy = data["energy"] as? [String: Any] ?? [:]
            let energyProgress = energy["progress"] as? [String: Any] ?? [:]
            let vitality = data["vitality"] as? [String: Any] ?? [:]
            let cardSign = data["card_sign"] as? String ?? ""
            return (
                integer(energyProgress["current"]),
                integer(energyProgress["max"]),
                integer(vitality["current"]),
                integer(vitality["max"]),
                [
                    ChecklistItem(
                        id: "scratch-card",
                        title: "刮刮卡",
                        isComplete: cardSign == "CardSignDone",
                        detail: cardSign == "CardSignDone" ? "已完成" : "待完成"
                    )
                ]
            )
        default:
            return (0, 0, 0, 0, [])
        }
    }

    private func signedGET(url: URL, query: [URLQueryItem], cookie: String) async throws -> [String: Any] {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        guard let finalURL = components.url else { throw MihoyoError.invalidResponse }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("2.11.1", forHTTPHeaderField: "x-rpc-app_version")
        request.setValue("5", forHTTPHeaderField: "x-rpc-client_type")
        request.setValue(deviceID.uppercased(), forHTTPHeaderField: "x-rpc-device_id")
        request.setValue(deviceFP, forHTTPHeaderField: "x-rpc-device_fp")
        request.setValue(dynamicSecret(query: query), forHTTPHeaderField: "DS")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        if finalURL.path.contains("/genshin/") {
            request.setValue("2.63.1", forHTTPHeaderField: "x-rpc-app_version")
            request.setValue("https://webstatic.mihoyo.com", forHTTPHeaderField: "Origin")
            request.setValue("https://webstatic.mihoyo.com/", forHTTPHeaderField: "Referer")
            request.setValue("com.mihoyo.hyperion", forHTTPHeaderField: "X-Requested-With")
            request.setValue("v4.2.2-ys", forHTTPHeaderField: "x-rpc-tool_version")
            request.setValue("v4.2.2-ys_#/ys/daily", forHTTPHeaderField: "x-rpc-page")
            request.setValue(
                "Mozilla/5.0 (Linux; Android 11; MI 8 SE Build/RQ3A.211001.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/104.0.5112.97 Mobile Safari/537.36 miHoYoBBS/2.63.1",
                forHTTPHeaderField: "User-Agent"
            )
        } else if finalURL.path.contains("/hkrpg/") {
            request.setValue("2.63.1", forHTTPHeaderField: "x-rpc-app_version")
            request.setValue("https://webstatic.mihoyo.com", forHTTPHeaderField: "Origin")
            request.setValue("https://webstatic.mihoyo.com/", forHTTPHeaderField: "Referer")
            request.setValue("com.mihoyo.hyperion", forHTTPHeaderField: "X-Requested-With")
            request.setValue("v1.4.1-rpg", forHTTPHeaderField: "x-rpc-tool-version")
            request.setValue("v1.4.1-rpg_#/rpg", forHTTPHeaderField: "x-rpc-page")
            request.setValue(
                "Mozilla/5.0 (Linux; Android 11; MI 8 SE Build/RQ3A.211001.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/104.0.5112.97 Mobile Safari/537.36 miHoYoBBS/2.63.1",
                forHTTPHeaderField: "User-Agent"
            )
        }
        // A Geetest result is single-use and is valid for a game-record
        // request only. In particular, do not spend it on the preceding
        // getUserGameRolesByCookie request during AppState.refresh().
        let solutionForRequest: MihoyoGeetestSolution?
        if let solution = geetestSolution,
           url.host == "api-takumi-record.mihoyo.com",
           requestPath(url.path, matches: solution.game) {
            solutionForRequest = solution
        } else {
            solutionForRequest = nil
        }
        if let solution = solutionForRequest {
            DiagnosticLog.write("attaching geetest solution to note request")
            request.setValue(solution.challenge, forHTTPHeaderField: "x-rpc-challenge")
            request.setValue(solution.validate, forHTTPHeaderField: "x-rpc-validate")
            request.setValue(solution.seccode, forHTTPHeaderField: "x-rpc-seccode")
        }

        defer {
            if solutionForRequest != nil {
                geetestSolution = nil
            }
        }
        let object = try await requestObject(request)
        return object["data"] as? [String: Any] ?? [:]
    }

    private func requestPath(_ path: String, matches game: GameID) -> Bool {
        switch game {
        case .genshin: path.contains("/genshin/")
        case .starRail: path.contains("/hkrpg/")
        case .zenless: path.contains("game_record_zzz")
        default: false
        }
    }

    private func widgetGET(url: URL, game: GameID, cookie: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("2.63.1", forHTTPHeaderField: "x-rpc-app_version")
        request.setValue(deviceID.uppercased(), forHTTPHeaderField: "x-rpc-device_id")
        request.setValue(deviceFP, forHTTPHeaderField: "x-rpc-device_fp")
        request.setValue("appstore", forHTTPHeaderField: "x-rpc-channel")
        request.setValue("iPhone10,2", forHTTPHeaderField: "x-rpc-device_model")
        request.setValue("iPhone", forHTTPHeaderField: "x-rpc-device_name")
        request.setValue("16.2", forHTTPHeaderField: "x-rpc-sys_version")
        request.setValue("https://app.mihoyo.com", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        switch game {
        case .genshin:
            request.setValue("5", forHTTPHeaderField: "x-rpc-client_type")
            request.setValue(widgetDynamicSecret(), forHTTPHeaderField: "DS")
            request.setValue("https://webstatic.mihoyo.com", forHTTPHeaderField: "Origin")
            request.setValue("com.mihoyo.hyperion", forHTTPHeaderField: "X-Requested-With")
            request.setValue("v4.2.2-ys", forHTTPHeaderField: "x-rpc-tool_version")
            request.setValue("v4.2.2-ys_#/ys/daily", forHTTPHeaderField: "x-rpc-page")
            request.setValue(
                "Mozilla/5.0 (Linux; Android 11; MI 8 SE Build/RQ3A.211001.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/104.0.5112.97 Mobile Safari/537.36 miHoYoBBS/2.55.1",
                forHTTPHeaderField: "User-Agent"
            )
        default:
            request.setValue("2", forHTTPHeaderField: "x-rpc-client_type")
            request.setValue(widgetBodyDynamicSecret(), forHTTPHeaderField: "DS")
            request.setValue(
                "WidgetExtension/231 CFNetwork/1390 Darwin/22.0.0",
                forHTTPHeaderField: "User-Agent"
            )
        }

        DiagnosticLog.write("requesting widget note: \(game.rawValue)")
        let object = try await requestObject(request)
        return object["data"] as? [String: Any] ?? [:]
    }

    private func ensureRegisteredDeviceFP() async throws {
        guard !isDeviceFPRegistered else { return }

        let seedAlphabet = Array("0123456789abcdef")
        let seedID = String((0..<16).compactMap { _ in seedAlphabet.randomElement() })
        let extFields: [String: Any] = [
            "userAgent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) miHoYoBBS/2.63.1",
            "browserScreenSize": 243750,
            "maxTouchPoints": 5,
            "isTouchSupported": true,
            "browserLanguage": "zh-CN",
            "browserPlat": "iPhone",
            "browserTimeZone": "Asia/Shanghai",
            "webGlRender": "Apple GPU",
            "webGlVendor": "Apple Inc.",
            "numOfPlugins": 0,
            "listOfPlugins": "unknown",
            "screenRatio": 3,
            "deviceMemory": "unknown",
            "hardwareConcurrency": "4",
            "cpuClass": "unknown",
            "ifNotTrack": "unknown",
            "ifAdBlock": 0,
            "hasLiedResolution": 1,
            "hasLiedOs": 0,
            "hasLiedBrowser": 0
        ]
        let extData = try JSONSerialization.data(withJSONObject: extFields)
        guard let extString = String(data: extData, encoding: .utf8) else {
            throw MihoyoError.invalidResponse
        }
        let body: [String: Any] = [
            "seed_id": seedID,
            "device_id": deviceID.lowercased(),
            "platform": "5",
            "seed_time": String(Int(Date().timeIntervalSince1970 * 1000)),
            "ext_fields": extString,
            "app_name": "account_cn",
            "device_fp": deviceFP
        ]

        var request = URLRequest(url: URL(string: "https://public-data-api.mihoyo.com/device-fp/api/getFp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let object = try await requestObject(request)
        guard let data = object["data"] as? [String: Any],
              integer(data["code"]) != 403,
              let registeredFP = data["device_fp"] as? String,
              !registeredFP.isEmpty else {
            throw MihoyoError.api(code: integer((object["data"] as? [String: Any])?["code"]), message: "米游社设备指纹注册失败")
        }
        deviceFP = registeredFP
        isDeviceFPRegistered = true
        let defaults = UserDefaults.standard
        defaults.set(registeredFP, forKey: "mihoyoDeviceFP")
        defaults.set(true, forKey: "mihoyoDeviceFPRegistered")
        DiagnosticLog.write("mihoyo device fingerprint registered")
    }

    private func requestObject(_ request: URLRequest) async throws -> [String: Any] {
        let (object, _) = try await requestObjectAndResponse(request)
        return object
    }

    private func requestObjectAndResponse(_ request: URLRequest) async throws -> ([String: Any], HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MihoyoError.invalidResponse
        }

        let code = integer(object["retcode"])
        let responseMessage = object["message"] as? String ?? ""
        DiagnosticLog.write(
            "mihoyo response \(request.url?.path ?? "unknown"): retcode=\(code), message=\(responseMessage.prefix(80))"
        )
        if code != 0 {
            let message = responseMessage.isEmpty ? "米游社请求失败" : responseMessage
            if [1034, 10035, 10041, 5003].contains(code) {
                throw MihoyoError.geetestRequired
            }
            if [-100, -101, 10001, 10102].contains(code) || message.contains("登录") || message.lowercased().contains("login") {
                throw MihoyoError.loginExpired
            }
            throw MihoyoError.api(code: code, message: message)
        }
        return (object, http)
    }

    private func dynamicSecret(query: [URLQueryItem]) -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let random = Int.random(in: 100_001...200_000)
        let queryString = query
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&")
        let raw = "salt=xV8v4Qu54lUKrEYFZkJhB8cuOh9Asafs&t=\(timestamp)&r=\(random)&b=&q=\(queryString)"
        let digest = Insecure.MD5.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(timestamp),\(random),\(digest)"
    }

    private func geetestDynamicSecret() -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let random = Int.random(in: 100_000...200_000)
        let raw = "salt=xV8v4Qu54lUKrEYFZkJhB8cuOh9Asafs&t=\(timestamp)&r=\(random)&b=&q=is_high=false"
        let digest = Insecure.MD5.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(timestamp),\(random),\(digest)"
    }

    private func widgetDynamicSecret() -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let random = String((0..<6).compactMap { _ in alphabet.randomElement() })
        let raw = "salt=9ttJY72HxbjwWRNHJvn0n2AYue47nYsK&t=\(timestamp)&r=\(random)"
        let digest = Insecure.MD5.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(timestamp),\(random),\(digest)"
    }

    private func widgetBodyDynamicSecret() -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let random = Int.random(in: 100_000...200_000)
        let raw = "salt=t0qEgfub6cvueAPgR5m9aQWWVciEer7v&t=\(timestamp)&r=\(random)&b=&q="
        let digest = Insecure.MD5.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(timestamp),\(random),\(digest)"
    }

    private func cookieString(from response: HTTPURLResponse) -> String {
        let headers: [String: String] = Dictionary(uniqueKeysWithValues: response.allHeaderFields.compactMap { key, value in
            guard let key = key as? String else { return nil }
            return (key, String(describing: value))
        })
        var cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: response.url!)
        if cookies.isEmpty {
            cookies = session.configuration.httpCookieStorage?.cookies ?? []
        }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func normalizedCookie(_ cookie: String) -> String {
        var values: [String: String] = [:]
        for part in cookie.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            values[String(pair[0]).trimmingCharacters(in: .whitespaces)] = String(pair[1])
        }

        func alias(_ source: String, _ targets: [String]) {
            guard let value = values[source], !value.isEmpty else { return }
            for target in targets where values[target] == nil {
                values[target] = value
            }
        }

        alias("ltoken_v2", ["ltoken"])
        alias("ltuid_v2", ["ltuid", "stuid", "login_uid", "account_id"])
        alias("account_id_v2", ["account_id", "ltuid", "stuid", "login_uid"])
        alias("account_mid_v2", ["mid"])
        alias("cookie_token_v2", ["cookie_token"])

        DiagnosticLog.write("passport login cookie fields: \(values.keys.sorted().joined(separator: ","))")
        return values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
    }

    private func integer(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber: number.intValue
        case let string as String: Int(string) ?? 0
        default: 0
        }
    }
}

struct MihoyoStatusService: StatusService {
    let cookie: String
    let allowedGames: Set<GameID>

    func fetch() async throws -> [GameStatus] {
        let roles = try await MihoyoClient.shared.gameRoles(cookie: cookie)
        let supported = roles.filter {
            guard let id = gameID(for: $0.gameBiz) else { return false }
            return allowedGames.contains(id) && ($0.isOfficial ?? true)
        }
        var result: [GameStatus] = []
        for role in supported {
            do {
                result.append(try await MihoyoClient.shared.status(for: role, cookie: cookie))
            } catch MihoyoError.loginExpired {
                guard let id = gameID(for: role.gameBiz) else { continue }
                DiagnosticLog.write("role is valid but note credential was rejected: \(role.gameBiz)")
                result.append(unavailable(id: id, message: "当前登录未授权该游戏的小组件数据"))
            } catch MihoyoError.geetestRequired {
                guard let id = gameID(for: role.gameBiz) else { continue }
                DiagnosticLog.write("widget/note still blocked by geetest: \(role.gameBiz)")
                result.append(unavailable(id: id, message: "需要完成该游戏的米游社人机验证"))
            } catch {
                guard let id = gameID(for: role.gameBiz) else { continue }
                result.append(unavailable(id: id, message: error.localizedDescription))
            }
        }
        return result
    }

    private func gameID(for gameBiz: String) -> GameID? {
        switch gameBiz {
        case "hk4e_cn": .genshin
        case "hkrpg_cn": .starRail
        case "nap_cn": .zenless
        default: nil
        }
    }

    private func unavailable(id: GameID, message: String) -> GameStatus {
        GameStatus(
            id: id,
            staminaName: "体力",
            stamina: nil,
            dailyName: "每日进度",
            daily: DailyProgress(completed: 0, total: 0),
            checklist: [],
            session: .unavailable,
            message: message,
            updatedAt: Date()
        )
    }
}
