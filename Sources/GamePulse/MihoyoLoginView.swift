import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

enum MihoyoAccountSlot {
    case primary
    case zenless

    var title: String {
        switch self {
        case .primary: "原神 / 崩坏：星穹铁道"
        case .zenless: "绝区零"
        }
    }

    @MainActor
    func hasLogin(in settings: SettingsStore) -> Bool {
        switch self {
        case .primary: settings.hasMihoyoLogin
        case .zenless: settings.hasMihoyoZZZLogin
        }
    }

    @MainActor
    func hasFullLogin(in settings: SettingsStore) -> Bool {
        switch self {
        case .primary: settings.hasMihoyoFullLogin
        case .zenless: settings.hasMihoyoZZZFullLogin
        }
    }

    @MainActor
    func save(cookie: String, in settings: SettingsStore) {
        switch self {
        case .primary: settings.mihoyoCookie = cookie
        case .zenless: settings.mihoyoZZZCookie = cookie
        }
    }
}

@MainActor
final class MihoyoLoginModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case creatingApp
        case waitingApp
        case scannedApp
        case creatingWeb
        case waitingWeb
        case scannedWeb
        case completed
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var qrImage: NSImage?
    private var pollingTask: Task<Void, Never>?

    deinit { pollingTask?.cancel() }

    func start(settings: SettingsStore, state: AppState, slot: MihoyoAccountSlot) {
        pollingTask?.cancel()
        phase = .creatingApp
        qrImage = nil

        pollingTask = Task {
            do {
                let appSession = try await MihoyoClient.shared.createAppQRLogin()
                try Task.checkCancellation()
                qrImage = QRCodeRenderer.image(from: appSession.url)
                phase = .waitingApp

                var appCredentials: MihoyoAppCredentials?
                while !Task.isCancelled, appCredentials == nil {
                    switch try await MihoyoClient.shared.pollAppQRLogin(session: appSession) {
                    case .waiting:
                        phase = .waitingApp
                    case .scanned:
                        phase = .scannedApp
                    case .confirmed(let credentials):
                        appCredentials = credentials
                    }
                    if appCredentials == nil {
                        try await Task.sleep(for: .seconds(1.5))
                    }
                }

                guard let appCredentials else { throw CancellationError() }
                phase = .creatingWeb
                qrImage = nil
                let webSession = try await MihoyoClient.shared.createWebQRLogin(
                    deviceID: appSession.deviceID
                )
                try Task.checkCancellation()
                qrImage = QRCodeRenderer.image(from: webSession.url)
                phase = .waitingWeb

                while !Task.isCancelled {
                    switch try await MihoyoClient.shared.pollWebQRLogin(session: webSession) {
                    case .waiting:
                        phase = .waitingWeb
                    case .scanned:
                        phase = .scannedWeb
                    case .confirmed(let webCookie):
                        let cookie = try await MihoyoClient.shared.combinedLoginCookie(
                            app: appCredentials,
                            webCookie: webCookie
                        )
                        slot.save(cookie: cookie, in: settings)
                        phase = .completed
                        qrImage = nil
                        await state.refresh()
                        state.restart()
                        return
                    }
                    try await Task.sleep(for: .seconds(1.5))
                }
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
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

struct MihoyoLoginView: View {
    @StateObject private var primaryModel = MihoyoLoginModel()
    @StateObject private var zenlessModel = MihoyoLoginModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MihoyoAccountLoginCard(slot: .primary, model: primaryModel)
            Divider()
            MihoyoAccountLoginCard(slot: .zenless, model: zenlessModel)
        }
    }
}

private struct MihoyoAccountLoginCard: View {
    @EnvironmentObject private var state: AppState
    let slot: MihoyoAccountSlot
    @ObservedObject var model: MihoyoLoginModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(slot.title)
                        .font(.headline)
                    Text(loginDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if slot.hasLogin(in: state.settings) {
                    Label(
                        slot.hasFullLogin(in: state.settings) ? "已完整授权" : "待完整授权",
                        systemImage: slot.hasFullLogin(in: state.settings)
                            ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(slot.hasFullLogin(in: state.settings) ? .green : .orange)
                }
            }

            if let image = model.qrImage {
                HStack(alignment: .center, spacing: 18) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 150, height: 150)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(phaseText).font(.subheadline.weight(.medium))
                        Text(scanInstruction)
                            .font(.caption).foregroundStyle(.secondary)
                        Button("取消", role: .cancel) { model.cancel() }
                    }
                }
            } else {
                HStack {
                    Button(slot.hasFullLogin(in: state.settings) ? "重新完整授权" : "开始完整授权") {
                        model.start(settings: state.settings, state: state, slot: slot)
                    }
                    .disabled(model.isWorking)

                    if slot.hasLogin(in: state.settings) {
                        Button("退出登录", role: .destructive) {
                            slot.save(cookie: "", in: state.settings)
                            state.restart()
                            Task { await state.refresh() }
                        }
                    }
                    if case .failed(let message) = model.phase {
                        Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
        }
        .onDisappear { model.cancel() }
    }

    private var phaseText: String {
        switch model.phase {
        case .creatingApp: "正在生成第 1/2 个二维码…"
        case .waitingApp: "第 1/2 步：获取完整授权"
        case .scannedApp: "第 1/2 步：已扫码，请在手机上确认"
        case .creatingWeb: "第 1/2 步完成，正在更换二维码…"
        case .waitingWeb: "第 2/2 步：请再扫码一次"
        case .scannedWeb: "第 2/2 步：已扫码，请在手机上确认"
        case .completed: "完整授权成功"
        case .failed(let message): message
        case .idle: ""
        }
    }

    private var scanInstruction: String {
        switch model.phase {
        case .creatingWeb, .waitingWeb, .scannedWeb:
            "二维码已更新。请使用同一个米游社账号再扫一次并确认。"
        default:
            "请打开米游社 App，使用扫一扫并在手机上确认。"
        }
    }

    private var loginDescription: String {
        if slot.hasFullLogin(in: state.settings) {
            return "已完整授权该账号的\(slot.title)数据"
        }
        if slot.hasLogin(in: state.settings) {
            return "普通登录已保留；需再完成两次扫码以取得完整数据权限"
        }
        return "完整登录需使用米游社 App 连续扫描两个二维码"
    }
}

private extension MihoyoLoginModel {
    var isWorking: Bool {
        switch phase {
        case .creatingApp, .waitingApp, .scannedApp, .creatingWeb, .waitingWeb, .scannedWeb:
            true
        default:
            false
        }
    }
}

enum QRCodeRenderer {
    static func image(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 9, y: 9)) else {
            return nil
        }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
