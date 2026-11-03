import SwiftUI
import AppKit

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let error = state.lastError {
                        errorBanner(error)
                    }
                    ForEach(state.games) { game in
                        GameCard(game: game, now: state.now)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 18)
            }
        }
        .frame(width: 430, height: 740)
        .background {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                LinearGradient(
                    colors: [.white.opacity(0.07), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .task {
            await state.refresh()
            state.start()
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.blue.gradient)
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .foregroundStyle(.white)
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("游戏脉冲").font(.title3.bold())
                Text(sourceLabel)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await state.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .opacity(state.isRefreshing ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .disabled(state.isRefreshing)
            .help("立即刷新")

            Button {
                openWindow(id: "settings")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("设置")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("退出游戏脉冲")
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 11)
        .background(.ultraThinMaterial)
    }

    private var sourceLabel: String {
        if !state.settings.isDemoMode { return "数据桥实时数据" }
        if state.settings.hasAnyLiveAccount { return "官方社区实时数据" }
        return "演示模式"
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            if state.requiresMihoyoVerification {
                Button(state.needsMihoyoFullLogin ? "完整授权" : "完成验证") {
                    openWindow(id: state.needsMihoyoFullLogin ? "settings" : "mihoyo-verification")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if state.needsAccountLogin {
                Button("重新授权") {
                    openWindow(id: "settings")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(11)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
