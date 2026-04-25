import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingEditSheet = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            sidebar
                .frame(width: 380, alignment: .top)

            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 1120, minHeight: 760)
        .task {
            await model.bootstrap()
        }
        .sheet(isPresented: $showingEditSheet) {
            ProfileEditView(profile: model.editingProfile)
                .environmentObject(model)
                .onDisappear {
                    model.editingProfile = nil
                }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                globalConnectionPanel
                profileListPanel
                rulesPanel
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private var mainPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            overviewPanel
            logPanel
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }

                VStack(alignment: .leading, spacing: 8) {
                    Text(AppConstants.appName)
                        .font(.system(size: 30, weight: .semibold))

                    Text("统一管理设备接入、同步任务与运行日志。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                statusBadge(
                    title: "Reminders 权限",
                    value: model.reminderStore.authorizationSummary,
                    tint: .blue
                )
                statusBadge(
                    title: "同步服务",
                    value: model.isSyncing ? "同步中" : (model.isRunning ? "\(model.runningProfileCount) 个运行中" : "未运行"),
                    tint: model.isRunning ? .green : .secondary
                )
                statusBadge(
                    title: "同步任务",
                    value: "\(model.profileManager.profiles.count) 个",
                    tint: .orange
                )
            }
        }
        .padding(18)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 1)
        )
    }

    private var globalConnectionPanel: some View {
        panel(title: "准备工作", subtitle: "授权 Apple Reminders 并填入极趣云平台 API Key，加载设备。") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Reminders 权限")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(model.reminderStore.authorizationSummary)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.blue)
                    }

                    HStack(spacing: 8) {
                        Button {
                            Task { await model.requestReminderAccess() }
                        } label: {
                            Text(model.isLoadingReminderLists ? "加载中..." : "授权并读取列表")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isLoadingReminderLists)

                        Button("刷新列表") {
                            Task { await model.loadReminderLists() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isLoadingReminderLists)
                    }

                    if !model.reminderLists.isEmpty {
                        Text("已加载 \(model.reminderLists.count) 个 Reminders 列表")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(AppConstants.apiKeyLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    SecureField("请输入 API key", text: $model.apiKey)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        Task { await model.loadDevices() }
                    } label: {
                        Text(model.isLoadingDevices ? "加载中..." : "加载设备")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canLoadDevices || model.isLoadingDevices)
                }
            }
        }
    }

    private var profileListPanel: some View {
        panel(title: "同步任务", subtitle: "每个任务对应一台 AI便利贴 设备和一组 Reminders 列表。") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button {
                        model.editingProfile = nil
                        showingEditSheet = true
                    } label: {
                        Label("添加任务", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        if model.isRunning {
                            model.stopAllProfiles()
                        } else {
                            Task {
                                for profile in model.profileManager.profiles {
                                    await model.startProfile(profile)
                                }
                            }
                        }
                    } label: {
                        Text(model.isRunning ? "全部停止" : "全部启动")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if model.profileManager.profiles.isEmpty {
                    emptyState("当前没有同步任务。点击「添加任务」创建。")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(model.profileManager.profiles) { profile in
                                profileCard(profile)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }
        }
    }

    private func profileCard(_ profile: SyncProfile) -> some View {
        let isRunning = model.isProfileRunning(profile.id)
        let isSyncing = model.isProfileSyncing(profile.id)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isRunning ? (isSyncing ? Color.orange : Color.green) : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)

                Text(profile.name)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Button {
                    model.editingProfile = profile
                    showingEditSheet = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                Button {
                    model.profileManager.remove(id: profile.id)
                    model.stopProfile(profile.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red.opacity(0.8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("设备：\(profile.deviceName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("列表：\(model.listNames(for: profile.reminderListIDs).joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("轮询：每 \(profile.pollIntervalMinutes) 分钟")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastSync = model.profileLastSyncDate(profile.id) {
                    Text("最近同步：\(AppModel.displayDateFormatter.string(from: lastSync))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                if isRunning {
                    Button {
                        model.stopProfile(profile.id)
                    } label: {
                        Text("停止")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await model.startProfile(profile) }
                    } label: {
                        Text("启动")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("立即同步") {
                    model.syncProfile(profile.id)
                }
                .buttonStyle(.bordered)
                .disabled(!isRunning || isSyncing)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var rulesPanel: some View {
        panel(title: "同步策略", subtitle: "以下规则会影响自动配对、删除与冲突处理。") {
            VStack(alignment: .leading, spacing: 8) {
                ruleText("已勾选列表会先合并后再与设备待办比对；同名条目在不同列表间会被视为重复标题，跳过自动配对和自动删除。")
                ruleText("同一条待办优先使用历史映射和当前标题识别；没有历史映射时，只有标题唯一时才自动建立对应关系。")
                ruleText("设备端完成状态与 Reminders 完成状态会双向同步，但 Reminders 中已完成且设备中不存在的条目不会重新写入设备。")
                ruleText("设备删除未完成待办时，会删除来源列表中的对应提醒事项；设备删除已完成待办时，不删除提醒事项。")
                ruleText("如果设备侧 id 在删除后被复用，只有在创建时间能证明它仍是同一条待办时，系统才会继续复用该 id。")
            }
        }
    }

    private var overviewPanel: some View {
        panel(title: "运行概览", subtitle: "同步服务会按照以下参数与设备及 Apple Reminders 交互。") {
            VStack(alignment: .leading, spacing: 14) {
                detailGrid
                Divider()
                Text(model.isRunning
                     ? "\(model.runningProfileCount) 个同步任务正在运行，最近同步：\(model.lastSyncDate.map(AppModel.displayDateFormatter.string(from:)) ?? "尚未同步")"
                     : "同步服务未运行。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detailGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
            infoTile(title: "同步任务数", value: "\(model.profileManager.profiles.count) 个")
            infoTile(title: "运行中任务", value: "\(model.runningProfileCount) 个")
            infoTile(title: "Reminders 权限", value: model.reminderStore.authorizationSummary)
            infoTile(title: "最近同步", value: model.lastSyncDate.map(AppModel.displayDateFormatter.string(from:)) ?? "尚未同步")
        }
    }

    private var logPanel: some View {
        panel(title: "运行日志", subtitle: "展示最近 \(AppConstants.maxLogEntries) 条同步与状态事件。") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("当前共 \(model.logs.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清除日志") {
                        model.clearLogs()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.logs.isEmpty)
                }

                if model.logs.isEmpty {
                    emptyState("暂无同步日志。")
                        .frame(maxWidth: .infinity, minHeight: 420)
                } else {
                    List(model.logs) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(AppModel.displayDateFormatter.string(from: entry.timestamp))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text(entry.message)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 6)
                    }
                    .listStyle(.plain)
                    .frame(minHeight: 420)
                }
            }
        }
    }

    private func panel<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func statusBadge(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        )
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func infoTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func ruleText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 40)
            Text(message)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
