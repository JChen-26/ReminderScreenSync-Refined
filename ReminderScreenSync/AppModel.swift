import EventKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: Keys.apiKey)
            if oldValue != apiKey { stopSync() }
        }
    }

    @Published var devices: [ScreenDevice] = []
    @Published var selectedDeviceId: String {
        didSet {
            UserDefaults.standard.set(selectedDeviceId, forKey: Keys.selectedDeviceId)
            if oldValue != selectedDeviceId { stopSync() }
        }
    }
    @Published var reminderLists: [ReminderListOption] = []
    @Published var selectedReminderListIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(selectedReminderListIDs).sorted(), forKey: Keys.selectedReminderListIDs)
            if oldValue != selectedReminderListIDs { stopSync() }
        }
    }
    @Published var pollIntervalMinutesText: String {
        didSet {
            UserDefaults.standard.set(pollIntervalMinutesText, forKey: Keys.pollIntervalMinutesText)
            if oldValue != pollIntervalMinutesText { stopSync() }
        }
    }

    @Published var isLoadingDevices = false
    @Published var isLoadingReminderLists = false
    @Published var isRunning = false
    @Published var isSyncing = false
    @Published var statusMessage = "请填写极趣云平台 API Key，加载设备，并授权 Apple Reminders。"
    @Published var lastSyncDate: Date?
    @Published var logs: [SyncLogEntry] = []

    let reminderStore = ReminderStore()

    private var syncEngine: SyncEngine?

    init() {
        self.apiKey = UserDefaults.standard.string(forKey: Keys.apiKey) ?? ""
        self.selectedDeviceId = UserDefaults.standard.string(forKey: Keys.selectedDeviceId) ?? ""
        self.selectedReminderListIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.selectedReminderListIDs) ?? [])
        self.pollIntervalMinutesText =
            UserDefaults.standard.string(forKey: Keys.pollIntervalMinutesText) ??
            String(AppConstants.defaultPollIntervalMinutes)
        reminderStore.refreshAuthorizationSummary()
    }

    var selectedDevice: ScreenDevice? {
        devices.first { $0.deviceId == selectedDeviceId }
    }

    var selectedReminderLists: [ReminderListOption] {
        reminderLists.filter { selectedReminderListIDs.contains($0.id) }
    }

    var selectedReminderListSummary: String {
        switch selectedReminderLists.count {
        case 0:
            return "未选择"
        case 1:
            return selectedReminderLists[0].displayName
        case 2...3:
            return selectedReminderLists.map(\.displayName).joined(separator: "、")
        default:
            let leading = selectedReminderLists.prefix(3).map(\.displayName).joined(separator: "、")
            return "\(leading) 等 \(selectedReminderLists.count) 个列表"
        }
    }

    var writeBackReminderList: ReminderListOption? {
        guard let identifier = reminderStore.preferredWriteBackListID(from: selectedReminderLists.map(\.id)) else {
            return selectedReminderLists.first
        }
        return reminderLists.first { $0.id == identifier }
    }

    var pollIntervalMinutes: Int? {
        guard let value = Int(pollIntervalMinutesText.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0 else {
            return nil
        }
        return value
    }

    var pollIntervalValidationMessage: String? {
        let trimmed = pollIntervalMinutesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "请输入轮询分钟数。" }
        return pollIntervalMinutes == nil ? "轮询时间必须是大于 0 的整数分钟。" : nil
    }

    var canLoadDevices: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canStartSync: Bool {
        canLoadDevices && !selectedDeviceId.isEmpty && !selectedReminderLists.isEmpty && pollIntervalMinutes != nil
    }

    func bootstrap() async {
        if Self.hasFullReminderAccess(EKEventStore.authorizationStatus(for: .reminder)) {
            await loadReminderLists()
        }
    }

    func requestReminderAccess() async {
        await loadReminderLists()
    }

    func loadReminderLists() async {
        isLoadingReminderLists = true
        defer { isLoadingReminderLists = false }

        do {
            let lists = try await reminderStore.fetchReminderLists()
            reminderLists = lists
            let validIdentifiers = Set(lists.map(\.id))
            selectedReminderListIDs = selectedReminderListIDs.intersection(validIdentifiers)
            if selectedReminderListIDs.isEmpty, let first = lists.first {
                selectedReminderListIDs = [first.id]
            }
            statusMessage = lists.isEmpty ? "没有可同步的 Apple Reminders 列表。" : "已加载 \(lists.count) 个 Apple Reminders 列表。"
            appendLog(statusMessage)
        } catch {
            statusMessage = error.localizedDescription
            appendLog(error.localizedDescription)
        }
    }

    func loadDevices() async {
        guard canLoadDevices else {
            statusMessage = "请先填写 \(AppConstants.openPlatformName) API Key。"
            return
        }

        isLoadingDevices = true
        defer { isLoadingDevices = false }

        do {
            let client = ZectrixAPIClient(apiKey: apiKey)
            devices = try await client.fetchDevices()
            if !devices.contains(where: { $0.deviceId == selectedDeviceId }) {
                selectedDeviceId = devices.first?.deviceId ?? ""
            }
            statusMessage = devices.isEmpty ? "没有获取到 \(AppConstants.deviceName) 设备。" : "已获取 \(devices.count) 台 \(AppConstants.deviceName) 设备。"
            appendLog(statusMessage)
        } catch {
            statusMessage = "获取设备失败：\(error.localizedDescription)"
            appendLog(statusMessage)
        }
    }

    func startSync() async {
        if reminderLists.isEmpty {
            await loadReminderLists()
        }

        guard canStartSync,
              let pollIntervalMinutes,
              let writeBackReminderListID = writeBackReminderList?.id else {
            statusMessage = "请先填写 API Key，选择设备、至少一个提醒事项列表，并输入有效的轮询分钟数。"
            return
        }

        do {
            try await reminderStore.requestAccessIfNeeded()
        } catch {
            statusMessage = error.localizedDescription
            appendLog(error.localizedDescription)
            return
        }

        stopSync()
        let selectedLists = selectedReminderLists
        let engine = SyncEngine(
            apiKey: apiKey,
            deviceId: selectedDeviceId,
            selectedReminderLists: selectedLists,
            writeBackReminderListID: writeBackReminderListID,
            reminderStore: reminderStore,
            pollInterval: TimeInterval(pollIntervalMinutes * 60)
        )
        engine.onLog = { [weak self] message in
            self?.appendLog(message)
        }
        engine.onSyncingChanged = { [weak self] isSyncing in
            self?.isSyncing = isSyncing
        }
        engine.onLastSyncChanged = { [weak self] date in
            self?.lastSyncDate = date
            self?.statusMessage = "最近同步：\(Self.displayDateFormatter.string(from: date))"
        }
        syncEngine = engine
        isRunning = true
        statusMessage = "同步服务运行中：\(selectedReminderListSummary) -> \(selectedDevice?.displayName ?? selectedDeviceId)"
        engine.start()
    }

    func stopSync() {
        syncEngine?.stop()
        syncEngine = nil
        isRunning = false
        isSyncing = false
        if !statusMessage.hasPrefix("获取设备失败") {
            statusMessage = "同步服务已停止。"
        }
    }

    func syncNow() {
        guard isRunning else {
            statusMessage = "同步服务未运行。"
            return
        }
        syncEngine?.runManualSync()
    }

    func appendLog(_ message: String) {
        logs.insert(SyncLogEntry(timestamp: Date(), message: message), at: 0)
        if logs.count > AppConstants.maxLogEntries {
            logs.removeLast(logs.count - AppConstants.maxLogEntries)
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    func setReminderListSelected(_ reminderListID: String, isSelected: Bool) {
        if isSelected {
            selectedReminderListIDs.insert(reminderListID)
        } else {
            selectedReminderListIDs.remove(reminderListID)
        }
    }

    func selectAllReminderLists() {
        selectedReminderListIDs = Set(reminderLists.map(\.id))
    }

    func clearReminderListSelection() {
        selectedReminderListIDs = []
    }

    static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private enum Keys {
        static let apiKey = "ReminderScreenSync.apiKey"
        static let selectedDeviceId = "ReminderScreenSync.selectedDeviceId"
        static let selectedReminderListIDs = "ReminderScreenSync.selectedReminderListIDs"
        static let pollIntervalMinutesText = "ReminderScreenSync.pollIntervalMinutesText"
    }

    private static func hasFullReminderAccess(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .fullAccess || status == .authorized
        } else {
            return status == .authorized
        }
    }
}
