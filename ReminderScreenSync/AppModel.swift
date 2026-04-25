import EventKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: Keys.apiKey)
        }
    }

    @Published var devices: [ScreenDevice] = []
    @Published var reminderLists: [ReminderListOption] = []

    @Published var isLoadingDevices = false
    @Published var isLoadingReminderLists = false
    @Published var logs: [SyncLogEntry] = []
    @Published var autoStartSync: Bool {
        didSet {
            UserDefaults.standard.set(autoStartSync, forKey: Keys.autoStartSync)
        }
    }
    @Published var editingProfile: SyncProfile? = nil

    let reminderStore = ReminderStore()
    let profileManager = ProfileManager()

    @Published private var engines: [UUID: SyncEngine] = [:]
    @Published private var lastSyncDates: [UUID: Date] = [:]
    @Published private var syncingStates: [UUID: Bool] = [:]

    init() {
        self.apiKey = UserDefaults.standard.string(forKey: Keys.apiKey) ?? ""
        self.autoStartSync = UserDefaults.standard.bool(forKey: Keys.autoStartSync)
        reminderStore.refreshAuthorizationSummary()
    }

    var isRunning: Bool { !engines.isEmpty }
    var isSyncing: Bool { syncingStates.values.contains(true) }
    var lastSyncDate: Date? { lastSyncDates.values.max() }
    var runningProfileCount: Int { engines.count }

    func bootstrap() async {
        if Self.hasFullReminderAccess(EKEventStore.authorizationStatus(for: .reminder)) {
            await loadReminderLists()
        }
        if autoStartSync {
            for profile in profileManager.profiles where profile.isEnabled {
                await startProfile(profile)
            }
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
            appendLog(lists.isEmpty ? "没有可同步的 Apple Reminders 列表。" : "已加载 \(lists.count) 个 Apple Reminders 列表。")
        } catch {
            appendLog(error.localizedDescription)
        }
    }

    func loadDevices() async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendLog("请先填写 \(AppConstants.openPlatformName) API Key。")
            return
        }

        isLoadingDevices = true
        defer { isLoadingDevices = false }

        do {
            let client = ZectrixAPIClient(apiKey: apiKey)
            devices = try await client.fetchDevices()
            appendLog(devices.isEmpty ? "没有获取到 \(AppConstants.deviceName) 设备。" : "已获取 \(devices.count) 台 \(AppConstants.deviceName) 设备。")
            updateProfileDeviceNames()
        } catch {
            appendLog("获取设备失败：\(error.localizedDescription)")
        }
    }

    var canLoadDevices: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func canStartProfile(_ profile: SyncProfile) -> Bool {
        canLoadDevices
            && !profile.deviceId.isEmpty
            && !profile.reminderListIDs.isEmpty
            && profile.pollIntervalMinutes > 0
    }

    func startProfile(_ profile: SyncProfile) async {
        guard canStartProfile(profile) else {
            appendLog("[\(profile.name)] 配置不完整，无法启动同步。")
            return
        }

        let selectedLists = reminderLists.filter { profile.reminderListIDs.contains($0.id) }
        guard !selectedLists.isEmpty else {
            appendLog("[\(profile.name)] 所选的 Reminders 列表不存在或已删除。")
            return
        }

        let writeBackID = reminderStore.preferredWriteBackListID(from: profile.reminderListIDs)
            ?? selectedLists.first?.id
            ?? profile.reminderListIDs.first!

        stopProfile(profile.id)

        do {
            try await reminderStore.requestAccessIfNeeded()
        } catch {
            appendLog(error.localizedDescription)
            return
        }

        let engine = SyncEngine(
            apiKey: apiKey,
            deviceId: profile.deviceId,
            selectedReminderLists: selectedLists,
            writeBackReminderListID: writeBackID,
            reminderStore: reminderStore,
            pollInterval: TimeInterval(profile.pollIntervalMinutes * 60)
        )
        let profileId = profile.id
        let profileName = profile.name
        engine.onLog = { [weak self] message in
            self?.appendLog("[\(profileName)] \(message)")
        }
        engine.onSyncingChanged = { [weak self] isSyncing in
            self?.syncingStates[profileId] = isSyncing
        }
        engine.onLastSyncChanged = { [weak self] date in
            self?.lastSyncDates[profileId] = date
        }
        engines[profileId] = engine
        engine.start()
        appendLog("[\(profileName)] 同步服务已启动。")
    }

    func stopProfile(_ id: UUID) {
        guard let engine = engines[id] else { return }
        engine.stop()
        engines.removeValue(forKey: id)
        syncingStates.removeValue(forKey: id)
        if let name = profileManager.profile(id: id)?.name {
            appendLog("[\(name)] 同步服务已停止。")
        }
    }

    func stopAllProfiles() {
        for id in engines.keys {
            stopProfile(id)
        }
    }

    func syncProfile(_ id: UUID) {
        engines[id]?.runManualSync()
    }

    func syncAllProfiles() {
        for engine in engines.values {
            engine.runManualSync()
        }
    }

    func isProfileRunning(_ id: UUID) -> Bool {
        engines.keys.contains(id)
    }

    func isProfileSyncing(_ id: UUID) -> Bool {
        syncingStates[id] ?? false
    }

    func profileLastSyncDate(_ id: UUID) -> Date? {
        lastSyncDates[id]
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

    func deviceName(for deviceId: String) -> String {
        devices.first { $0.deviceId == deviceId }?.displayName ?? deviceId
    }

    func listNames(for listIDs: [String]) -> [String] {
        listIDs.compactMap { id in
            reminderLists.first { $0.id == id }?.displayName
        }
    }

    private func updateProfileDeviceNames() {
        for (index, profile) in profileManager.profiles.enumerated() {
            if let device = devices.first(where: { $0.deviceId == profile.deviceId }) {
                var updated = profile
                updated.deviceName = device.displayName
                profileManager.profiles[index] = updated
            }
        }
        profileManager.save()
    }

    static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private enum Keys {
        static let apiKey = "ReminderScreenSync.apiKey"
        static let autoStartSync = "ReminderScreenSync.autoStartSync"
    }

    private static func hasFullReminderAccess(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .fullAccess || status == .authorized
        } else {
            return status == .authorized
        }
    }
}
