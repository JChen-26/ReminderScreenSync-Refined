import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            header
            statusCard
            actionButtons
        }
        .padding(16)
        .frame(width: 260)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)

            Text(AppConstants.shortAppName)
                .font(.system(size: 14, weight: .semibold))

            Spacer()
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                statusDot
                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }

            Text(lastSyncText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var statusDot: some View {
        Circle()
            .fill(model.isRunning ? (model.isSyncing ? Color.orange : Color.green) : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
    }

    private var statusText: String {
        if model.isSyncing {
            return "同步中"
        } else if model.isRunning {
            return "运行中"
        } else {
            return "未运行"
        }
    }

    private var lastSyncText: String {
        if let date = model.lastSyncDate {
            return "最近同步：\(AppModel.displayDateFormatter.string(from: date))"
        } else {
            return "尚未同步"
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 8) {
            Button {
                model.syncAllProfiles()
            } label: {
                Label("立即同步", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.isRunning || model.isSyncing)

            Button {
                openMainWindow()
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
