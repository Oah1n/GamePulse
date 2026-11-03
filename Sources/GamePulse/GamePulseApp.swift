import SwiftUI

@main
@MainActor
struct GamePulseApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var state: AppState

    init() {
        DiagnosticLog.reset()
        let settings = SettingsStore()
        let state = AppState(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _state = StateObject(wrappedValue: state)
        DispatchQueue.main.async {
            Task { @MainActor in
                await state.refresh()
                state.start()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environmentObject(state)
        } label: {
            Label("游戏脉冲", systemImage: "gauge.with.dots.needle.67percent")
        }
        .menuBarExtraStyle(.window)

        Window("游戏脉冲设置", id: "settings") {
            SettingsView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)

        Window("米游社人机验证", id: "mihoyo-verification") {
            MihoyoVerificationView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
    }
}
