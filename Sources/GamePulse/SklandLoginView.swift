import SwiftUI
import AppKit

@MainActor
final class SklandLoginModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case creating
        case waiting
        case completed
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var qrImage: NSImage?
    private var pollingTask: Task<Void, Never>?

    deinit { pollingTask?.cancel() }

    func start(settings: SettingsStore, state: AppState) {
        pollingTask?.cancel()
        phase = .creating
        qrImage = nil
        pollingTask = Task {
            do {
                let session = try await SklandLoginClient.shared.createQRLogin()
                try Task.checkCancellation()
                qrImage = QRCodeRenderer.image(from: session.url)
                phase = .waiting

                while !Task.isCancelled {
                    switch try await SklandLoginClient.shared.pollQRLogin(session) {
                    case .waiting:
                        phase = .waiting
                    case .confirmed(let token):
                        settings.sklandToken = token
                        phase = .completed
                        qrImage = nil
                        await state.refresh()
                        state.restart()
                        return
                    }
                    try await Task.sleep(for: .seconds(2))
                }
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
                qrImage = nil
            }
        }
    }

    func cancel() {
        pollingTask?.cancel()
        pollingTask = nil
        phase = .idle
        qrImage = nil
    }
}

struct SklandLoginView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = SklandLoginModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("明日方舟 · 森空岛").font(.headline)
                    Text("使用森空岛 App 扫码授权，不需要复制 Token")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.settings.hasSklandLogin {
                    Label("已授权", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let image = model.qrImage {
                HStack(spacing: 18) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 150, height: 150)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("请用森空岛 App 扫码")
                            .font(.subheadline.weight(.medium))
                        Text("在手机上确认后，程序会自动保存授权并刷新数据。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("取消", role: .cancel) { model.cancel() }
                    }
                }
            } else {
                HStack {
                    Button(state.settings.hasSklandLogin ? "重新扫码" : "扫码授权") {
                        model.start(settings: state.settings, state: state)
                    }
                    .disabled(model.phase == .creating || model.phase == .waiting)

                    if state.settings.hasSklandLogin {
                        Button("退出登录", role: .destructive) {
                            state.settings.sklandToken = ""
                            state.restart()
                            Task { await state.refresh() }
                        }
                    }
                    if model.phase == .creating {
                        ProgressView().controlSize(.small)
                    }
                    if case .failed(let message) = model.phase {
                        Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
        }
        .onDisappear { model.cancel() }
    }
}
