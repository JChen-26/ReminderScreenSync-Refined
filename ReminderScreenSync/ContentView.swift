import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

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
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                connectionPanel
                reminderPanel
                controlPanel
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

                    Text("统一管理设备接入、Reminders 列表选择、同步服务与运行日志。")
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
                    value: model.isSyncing ? "同步中" : (model.isRunning ? "运行中" : "未运行"),
                    tint: model.isRunning ? .green : .secondary
                )
                statusBadge(
                    title: "设备轮询",
                    value: model.pollIntervalMinutes.map { "\($0) 分钟" } ?? "未设置",
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

    private var connectionPanel: some View {
        panel(title: "设备接入", subtitle: "填写极趣云平台 API Key，加载账号下的设备并选择同步目标。") {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppConstants.apiKeyLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                SecureField("请输入 API key", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder)

                actionRow {
                    Button {
                        Task { await model.loadDevices() }
                    } label: {
                        Text(model.isLoadingDevices ? "加载中..." : "加载设备")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canLoadDevices || model.isLoadingDevices)
                } secondary: {
                    Button("立即同步") {
                        model.syncNow()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.isRunning || model.isSyncing)
                }

                pickerRow(label: "AI便利贴设备") {
                    Picker(
                        "AI便利贴设备",
                        selection: Binding(
                            get: { model.selectedDevice?.deviceId ?? "" },
                            set: { model.selectedDeviceId = $0 }
                        )
                    ) {
                        Text("请选择设备").tag("")
                        ForEach(model.devices) { device in
                            Text(device.displayName).tag(device.deviceId)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private var reminderPanel: some View {
        panel(title: "Reminders 列表", subtitle: "支持多选。同步到 AI便利贴 时会将所有勾选列表合并处理，不区分来源列表。") {
            VStack(alignment: .leading, spacing: 12) {
                actionRow {
                    Button {
                        Task { await model.requestReminderAccess() }
                    } label: {
                        Text(model.isLoadingReminderLists ? "加载中..." : "授权并读取列表")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isLoadingReminderLists)
                } secondary: {
                    Button("刷新列表") {
                        Task { await model.loadReminderLists() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isLoadingReminderLists)
                }

                HStack {
                    detailRow(label: "已选择", value: "\(model.selectedReminderLists.count) 个列表")
                    Spacer()
                    Button("全选") {
                        model.selectAllReminderLists()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.reminderLists.isEmpty)

                    Button("清空") {
                        model.clearReminderListSelection()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.selectedReminderLists.isEmpty)
                }

                if model.reminderLists.isEmpty {
                    emptyState("当前没有可同步的 Apple Reminders 列表。")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(model.reminderLists) { list in
                                reminderListRow(list)
                            }
                        }
                    }
                    .frame(maxHeight: 250)
                }

                detailRow(label: "默认回写列表", value: model.writeBackReminderList?.displayName ?? "未选择")
            }
        }
    }

    private var controlPanel: some View {
        panel(title: "同步服务", subtitle: "运行后监听 Apple Reminders 变更，并按设定周期轮询 AI便利贴 端状态。") {
            VStack(alignment: .leading, spacing: 12) {
                actionRow {
                    Button {
                        Task { await model.startSync() }
                    } label: {
                        Text(model.isRunning ? "重新启动同步服务" : "启动同步服务")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStartSync)
                } secondary: {
                    Button("停止同步") {
                        model.stopSync()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.isRunning)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("设备轮询周期")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        TextField("1", text: $model.pollIntervalMinutesText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 96)
                        Text("分钟")
                            .foregroundStyle(.secondary)
                    }

                    Text(model.pollIntervalValidationMessage ?? "请输入正整数分钟数，例如 1、5、15。")
                        .font(.caption)
                        .foregroundStyle(model.pollIntervalValidationMessage == nil ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    detailRow(label: "服务状态", value: model.statusMessage)
                    detailRow(label: "上次同步", value: model.lastSyncDate.map(AppModel.displayDateFormatter.string(from:)) ?? "尚未同步")
                    detailRow(label: "目标设备", value: model.selectedDevice?.displayName ?? "未选择")
                }
            }
        }
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
                Text(model.statusMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detailGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
            infoTile(title: "同步列表", value: model.selectedReminderListSummary)
            infoTile(title: "默认回写列表", value: model.writeBackReminderList?.displayName ?? "未选择")
            infoTile(title: "目标设备", value: model.selectedDevice?.displayName ?? "未选择")
            infoTile(title: "设备轮询周期", value: model.pollIntervalMinutes.map { "\($0) 分钟" } ?? "未设置")
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

    private func reminderListRow(_ list: ReminderListOption) -> some View {
        Toggle(isOn: Binding(
            get: { model.selectedReminderListIDs.contains(list.id) },
            set: { model.setReminderListSelected(list.id, isSelected: $0) }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text(list.title)
                    .font(.subheadline.weight(.medium))
                Text(list.sourceTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.checkbox)
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    private func actionRow<Primary: View, Secondary: View>(
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder secondary: () -> Secondary
    ) -> some View {
        HStack(spacing: 10) {
            primary()
            secondary()
        }
    }

    private func pickerRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
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
