import Foundation

protocol StatusService: Sendable {
    func fetch() async throws -> [GameStatus]
}

enum ServiceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "数据桥地址无效"
        case .invalidResponse: "数据桥返回了无法识别的数据"
        case .server(let code): "数据桥请求失败（HTTP \(code)）"
        }
    }
}

struct BridgeStatusService: StatusService {
    let baseURL: String
    let bearerToken: String

    func fetch() async throws -> [GameStatus] {
        guard var components = URLComponents(string: baseURL) else {
            throw ServiceError.invalidURL
        }
        let cleanPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([cleanPath, "v1/status"].filter { !$0.isEmpty }.joined(separator: "/"))
        guard let url = components.url else { throw ServiceError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ServiceError.server(http.statusCode) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StatusEnvelope.self, from: data).games
    }
}

struct DemoStatusService: StatusService {
    func fetch() async throws -> [GameStatus] {
        let now = Date()
        return [
            game(.genshin, "原粹树脂", 118, 200, 480, "每日委托", 3, 4, now),
            game(.starRail, "开拓力", 214, 300, 360, "每日训练", 420, 500, now),
            game(.zenless, "电量", 164, 240, 360, "丽都周纪", 300, 400, now),
            game(.arknights, "理智", 93, 135, 360, "日常任务", 8, 10, now),
            game(.wutheringWaves, "结晶波片", 176, 240, 360, "每日活跃", 80, 100, now)
        ]
    }

    private func game(
        _ id: GameID,
        _ staminaName: String,
        _ current: Int,
        _ maximum: Int,
        _ recovery: TimeInterval,
        _ dailyName: String,
        _ completed: Int,
        _ total: Int,
        _ now: Date
    ) -> GameStatus {
        GameStatus(
            id: id,
            staminaName: staminaName,
            stamina: StaminaSnapshot(
                current: current,
                maximum: maximum,
                capturedAt: now,
                recoverySecondsPerUnit: recovery
            ),
            dailyName: dailyName,
            daily: DailyProgress(completed: completed, total: total),
            checklist: [],
            session: .active,
            message: "演示数据",
            updatedAt: now
        )
    }
}
