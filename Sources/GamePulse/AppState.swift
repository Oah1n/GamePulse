import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var games: [GameStatus] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var requiresMihoyoVerification = false
    @Published private(set) var needsMihoyoFullLogin = false
    @Published private(set) var needsAccountLogin = false
    @Published var now = Date()

    let settings: SettingsStore
    private var clockTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.now = Date()
            }
        }
    }

    deinit {
        clockTask?.cancel()
        refreshTask?.cancel()
    }

    func start() {
        DiagnosticLog.write("app state start called; existing task=\(refreshTask != nil)")
        guard refreshTask == nil else { return }
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let minutes = max(1, await self.settings.refreshMinutes)
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func restart() {
        refreshTask?.cancel()
        refreshTask = nil
        start()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        DiagnosticLog.write("refresh started: bridge=\(!settings.isDemoMode), liveAccounts=\(settings.hasAnyLiveAccount)")
        defer { isRefreshing = false }

        do {
            if !settings.isDemoMode {
                games = try await BridgeStatusService(
                    baseURL: settings.bridgeURL,
                    bearerToken: settings.bridgeToken
                ).fetch()
            } else if settings.hasAnyLiveAccount {
                let demo = try await DemoStatusService().fetch()
                var live: [GameStatus] = []
                if settings.hasMihoyoLogin {
                    do {
                        live += try await MihoyoStatusService(
                            cookie: settings.mihoyoCookie,
                            allowedGames: [.genshin, .starRail]
                        ).fetch()
                    } catch MihoyoError.loginExpired {
                        settings.mihoyoCookie = ""
                        live += unavailableStatuses(
                            from: demo,
                            ids: [.genshin, .starRail],
                            message: "该米游社账号登录已失效"
                        )
                    }
                }
                if settings.hasMihoyoZZZLogin {
                    do {
                        live += try await MihoyoStatusService(
                            cookie: settings.mihoyoZZZCookie,
                            allowedGames: [.zenless]
                        ).fetch()
                    } catch MihoyoError.loginExpired {
                        settings.mihoyoZZZCookie = ""
                        live += unavailableStatuses(
                            from: demo,
                            ids: [.zenless],
                            message: "绝区零的米游社账号登录已失效"
                        )
                    }
                }
                if settings.hasSklandLogin {
                    do {
                        live += try await SklandStatusService(accountToken: settings.sklandToken).fetch()
                    } catch CommunityAPIError.loginExpired {
                        settings.sklandToken = ""
                        live += unavailableStatuses(
                            from: demo,
                            ids: [.arknights],
                            message: "森空岛登录已失效，请在设置中重新授权"
                        )
                    } catch {
                        live += unavailableStatuses(
                            from: demo,
                            ids: [.arknights],
                            message: error.localizedDescription,
                            session: .unavailable
                        )
                    }
                }
                if settings.hasKuroLogin {
                    do {
                        live += try await KuroStatusService(token: settings.kuroToken).fetch()
                    } catch CommunityAPIError.loginExpired {
                        settings.kuroToken = ""
                        live += unavailableStatuses(
                            from: demo,
                            ids: [.wutheringWaves],
                            message: "库街区登录已失效，请在设置中重新授权"
                        )
                    } catch {
                        live += unavailableStatuses(
                            from: demo,
                            ids: [.wutheringWaves],
                            message: error.localizedDescription,
                            session: .unavailable
                        )
                    }
                }
                DiagnosticLog.write("live status count: \(live.count)")
                let liveIDs = Set(live.map(\.id))
                games = (live + demo.filter { !liveIDs.contains($0.id) }).sorted {
                    GameID.allCases.firstIndex(of: $0.id)! < GameID.allCases.firstIndex(of: $1.id)!
                }
            } else {
                games = try await DemoStatusService().fetch()
            }
            requiresMihoyoVerification = games.contains { ($0.message ?? "").contains("人机验证") }
            needsAccountLogin = games.contains { $0.session == .needsLogin }
            needsMihoyoFullLogin = games.contains { game in
                guard (game.message ?? "").contains("人机验证") else { return false }
                switch game.id {
                case .genshin, .starRail: return !settings.hasMihoyoFullLogin
                case .zenless: return !settings.hasMihoyoZZZFullLogin
                default: return false
                }
            }
            if requiresMihoyoVerification && needsMihoyoFullLogin {
                lastError = "当前是普通登录，请在设置中完成米游社两步授权"
            } else {
                if requiresMihoyoVerification {
                    lastError = "有游戏需要完成米游社人机验证"
                } else if needsAccountLogin {
                    lastError = "有游戏账号需要重新授权"
                } else {
                    lastError = nil
                }
            }
            DiagnosticLog.write("refresh completed: \(games.count) games")
        } catch MihoyoError.geetestRequired {
            DiagnosticLog.write("refresh blocked: mihoyo geetest required")
            requiresMihoyoVerification = true
            needsMihoyoFullLogin = !settings.hasMihoyoFullLogin
            games = await verificationRequiredStatuses()
            lastError = MihoyoError.geetestRequired.localizedDescription
        } catch MihoyoError.loginExpired {
            DiagnosticLog.write("refresh failed: mihoyo login expired")
            settings.mihoyoCookie = ""
            games = await expiredMihoyoStatuses()
            lastError = MihoyoError.loginExpired.localizedDescription
        } catch {
            DiagnosticLog.write("refresh failed: \(type(of: error)): \(error.localizedDescription)")
            lastError = error.localizedDescription
            if games.isEmpty {
                games = (try? await DemoStatusService().fetch()) ?? []
            }
        }
    }

    private func expiredMihoyoStatuses() async -> [GameStatus] {
        let demo = (try? await DemoStatusService().fetch()) ?? []
        return demo.map { game in
            guard [.genshin, .starRail, .zenless].contains(game.id) else { return game }
            return GameStatus(
                id: game.id,
                staminaName: game.staminaName,
                stamina: nil,
                dailyName: game.dailyName,
                daily: DailyProgress(completed: 0, total: game.daily.total),
                checklist: [],
                session: .needsLogin,
                message: "米游社登录已失效",
                updatedAt: Date()
            )
        }
    }

    private func unavailableStatuses(
        from demo: [GameStatus],
        ids: Set<GameID>,
        message: String,
        session: SessionState = .needsLogin
    ) -> [GameStatus] {
        demo.filter { ids.contains($0.id) }.map { game in
            GameStatus(
                id: game.id,
                staminaName: game.staminaName,
                stamina: nil,
                dailyName: game.dailyName,
                daily: DailyProgress(completed: 0, total: game.daily.total),
                checklist: [],
                session: session,
                message: message,
                updatedAt: Date()
            )
        }
    }

    private func verificationRequiredStatuses() async -> [GameStatus] {
        let demo = (try? await DemoStatusService().fetch()) ?? []
        return demo.map { game in
            guard [.genshin, .starRail, .zenless].contains(game.id) else { return game }
            return GameStatus(
                id: game.id,
                staminaName: game.staminaName,
                stamina: nil,
                dailyName: game.dailyName,
                daily: DailyProgress(completed: 0, total: game.daily.total),
                checklist: [],
                session: .unavailable,
                message: "需要完成米游社人机验证",
                updatedAt: Date()
            )
        }
    }
}
