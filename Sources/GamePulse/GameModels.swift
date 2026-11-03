import Foundation
import SwiftUI

enum GameID: String, Codable, CaseIterable, Identifiable, Sendable {
    case genshin
    case starRail
    case zenless
    case arknights
    case wutheringWaves

    var id: String { rawValue }

    var title: String {
        switch self {
        case .genshin: "原神"
        case .starRail: "崩坏：星穹铁道"
        case .zenless: "绝区零"
        case .arknights: "明日方舟"
        case .wutheringWaves: "鸣潮"
        }
    }

    var shortTitle: String {
        switch self {
        case .starRail: "星铁"
        case .wutheringWaves: "鸣潮"
        case .arknights: "方舟"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .genshin: "sparkles"
        case .starRail: "train.side.front.car"
        case .zenless: "bolt.fill"
        case .arknights: "cross.case.fill"
        case .wutheringWaves: "waveform.path"
        }
    }

    var tint: Color {
        switch self {
        case .genshin: Color(red: 0.28, green: 0.66, blue: 0.86)
        case .starRail: Color(red: 0.56, green: 0.46, blue: 0.91)
        case .zenless: Color(red: 0.92, green: 0.72, blue: 0.16)
        case .arknights: Color(red: 0.20, green: 0.73, blue: 0.78)
        case .wutheringWaves: Color(red: 0.23, green: 0.77, blue: 0.62)
        }
    }
}

enum SessionState: String, Codable, Sendable {
    case active
    case needsLogin
    case unavailable
}

struct StaminaSnapshot: Codable, Equatable, Sendable {
    let current: Int
    let maximum: Int
    let capturedAt: Date
    let recoverySecondsPerUnit: TimeInterval

    func value(at date: Date) -> Int {
        guard current < maximum, recoverySecondsPerUnit > 0 else { return current }
        let recovered = Int(max(0, date.timeIntervalSince(capturedAt)) / recoverySecondsPerUnit)
        return min(maximum, current + recovered)
    }

    func progress(at date: Date) -> Double {
        guard maximum > 0 else { return 0 }
        return min(1, max(0, Double(value(at: date)) / Double(maximum)))
    }

    func fullAt(from date: Date) -> Date? {
        let remaining = maximum - value(at: date)
        guard remaining > 0 else { return nil }
        return date.addingTimeInterval(Double(remaining) * recoverySecondsPerUnit)
    }
}

struct DailyProgress: Codable, Equatable, Sendable {
    let completed: Int
    let total: Int

    var isComplete: Bool { total > 0 && completed >= total }
    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

struct ChecklistItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let isComplete: Bool
    let detail: String?
}

struct GameStatus: Identifiable, Codable, Equatable, Sendable {
    let id: GameID
    let staminaName: String
    let stamina: StaminaSnapshot?
    let dailyName: String
    let daily: DailyProgress
    let checklist: [ChecklistItem]
    let session: SessionState
    let message: String?
    let updatedAt: Date
}

struct StatusEnvelope: Codable, Sendable {
    let generatedAt: Date
    let games: [GameStatus]
}
