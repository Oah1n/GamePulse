import SwiftUI

struct GameCard: View {
    let game: GameStatus
    let now: Date

    private var staminaValue: Int? { game.stamina?.value(at: now) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 27, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header

            if let stamina = game.stamina, let staminaValue {
                staminaWidget(stamina, value: staminaValue)
            } else {
                checklistPreview
            }

            dailyCapsule
        }
        .padding(17)
        .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
        .foregroundStyle(.white)
        .background { widgetBackground }
        .clipShape(shape)
        .overlay {
            shape.stroke(.white.opacity(0.22), lineWidth: 0.8)
        }
        .shadow(color: game.id.widgetShadow.opacity(0.24), radius: 15, y: 8)
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.18))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 0.7)
                Image(systemName: game.id.symbol)
                    .font(.system(size: 18, weight: .semibold))
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(game.id.title)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            sessionBadge
        }
    }

    private func staminaWidget(_ stamina: StaminaSnapshot, value: Int) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(game.staminaName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.74))
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(value)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("/ \(stamina.maximum)")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.68))
                }
                Text(fullTimeText(stamina))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
            }

            Spacer(minLength: 6)
            progressRing(stamina.progress(at: now))
        }
    }

    private func progressRing(_ value: Double) -> some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.17), lineWidth: 6)
            Circle()
                .trim(from: 0, to: value)
                .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(.caption2, design: .rounded).weight(.bold))
        }
        .frame(width: 56, height: 56)
        .accessibilityLabel("体力进度 \(Int((value * 100).rounded()))%")
    }

    private var dailyCapsule: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: game.daily.isComplete ? "checkmark.circle.fill" : "checklist")
                    .font(.caption.weight(.semibold))
                Text(game.dailyName)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(game.daily.completed) / \(game.daily.total)")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                Text(game.daily.isComplete ? "已完成" : "还差 \(max(0, game.daily.total - game.daily.completed))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.66))
            }
            ProgressView(value: game.daily.fraction)
                .progressViewStyle(.linear)
                .tint(.white)
                .scaleEffect(y: 0.75)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 0.6)
        }
    }

    private var checklistPreview: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(game.checklist.prefix(4)) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                    Text(item.title).font(.caption)
                    Spacer()
                    if let detail = item.detail {
                        Text(detail).font(.caption2).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
        .padding(11)
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var sessionBadge: some View {
        switch game.session {
        case .active:
            Label("已同步", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.white.opacity(0.88))
        case .needsLogin:
            Label("待登录", systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.yellow)
        case .unavailable:
            Label("暂不可用", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
    }

    private var statusText: String {
        game.message ?? "更新于 \(game.updatedAt.formatted(date: .omitted, time: .shortened))"
    }

    private func fullTimeText(_ stamina: StaminaSnapshot) -> String {
        guard let fullAt = stamina.fullAt(from: now) else { return "已回满" }
        return "\(fullAt.formatted(date: .omitted, time: .shortened)) 回满"
    }

    private var widgetBackground: some View {
        ZStack {
            LinearGradient(
                colors: game.id.widgetColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(.white.opacity(0.10))
                .frame(width: 190, height: 190)
                .offset(x: 150, y: -86)

            Circle()
                .fill(.black.opacity(0.08))
                .frame(width: 150, height: 150)
                .offset(x: -175, y: 105)

            Image(systemName: game.id.symbol)
                .font(.system(size: 122, weight: .bold))
                .foregroundStyle(.white.opacity(0.075))
                .rotationEffect(.degrees(-8))
                .offset(x: 150, y: 32)

            LinearGradient(
                colors: [.clear, .black.opacity(0.12)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private extension GameID {
    var widgetColors: [Color] {
        switch self {
        case .genshin:
            [Color(red: 0.28, green: 0.68, blue: 0.88), Color(red: 0.20, green: 0.39, blue: 0.66)]
        case .starRail:
            [Color(red: 0.50, green: 0.42, blue: 0.86), Color(red: 0.25, green: 0.21, blue: 0.50)]
        case .zenless:
            [Color(red: 0.94, green: 0.72, blue: 0.12), Color(red: 0.54, green: 0.36, blue: 0.08)]
        case .arknights:
            [Color(red: 0.16, green: 0.72, blue: 0.76), Color(red: 0.10, green: 0.39, blue: 0.50)]
        case .wutheringWaves:
            [Color(red: 0.18, green: 0.73, blue: 0.61), Color(red: 0.08, green: 0.36, blue: 0.40)]
        }
    }

    var widgetShadow: Color { widgetColors.last ?? tint }
}
