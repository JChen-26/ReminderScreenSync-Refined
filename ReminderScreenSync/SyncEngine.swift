import EventKit
import Foundation

@MainActor
final class SyncEngine {
    var onLog: (String) -> Void = { _ in }
    var onSyncingChanged: (Bool) -> Void = { _ in }
    var onLastSyncChanged: (Date) -> Void = { _ in }

    private let apiClient: ZectrixAPIClient
    private let reminderStore: ReminderStore
    private let recordStore: SyncRecordStore
    private let deviceId: String
    private let selectedReminderLists: [ReminderListOption]
    private let selectedReminderListIDs: Set<String>
    private let reminderListTitlesByID: [String: String]
    private let selectedReminderListSummary: String
    private let writeBackReminderListID: String
    private let pollInterval: TimeInterval
    private let pollIntervalMinutes: Int

    private var pollTask: Task<Void, Never>?
    private var eventStoreObserver: NSObjectProtocol?
    private var isSyncing = false
    private var nextReason: String?

    init(
        apiKey: String,
        deviceId: String,
        selectedReminderLists: [ReminderListOption],
        writeBackReminderListID: String,
        reminderStore: ReminderStore,
        recordStore: SyncRecordStore = SyncRecordStore(),
        pollInterval: TimeInterval = AppConstants.defaultPollInterval
    ) {
        self.apiClient = ZectrixAPIClient(apiKey: apiKey)
        self.deviceId = deviceId
        self.selectedReminderLists = selectedReminderLists
        self.selectedReminderListIDs = Set(selectedReminderLists.map(\.id))
        self.reminderListTitlesByID = Dictionary(uniqueKeysWithValues: selectedReminderLists.map { ($0.id, $0.displayName) })
        self.selectedReminderListSummary = Self.makeSummary(from: selectedReminderLists)
        self.writeBackReminderListID = writeBackReminderListID
        self.reminderStore = reminderStore
        self.recordStore = recordStore
        self.pollInterval = pollInterval
        self.pollIntervalMinutes = max(1, Int((pollInterval / 60).rounded()))
    }

    func start() {
        stop()

        eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: reminderStore.eventStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleSync(reason: "苹果提醒事项变更")
            }
        }

        let interval = pollInterval
        let pollReason = "\(pollIntervalMinutes) 分钟轮询"
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                self?.scheduleSync(reason: pollReason)
            }
        }

        scheduleSync(reason: "启动同步")
        log("已启用 EventKit 变更监听，并每 \(pollIntervalMinutes) 分钟轮询 \(AppConstants.deviceName) 设备。")
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let eventStoreObserver {
            NotificationCenter.default.removeObserver(eventStoreObserver)
            self.eventStoreObserver = nil
        }
        nextReason = nil
        isSyncing = false
        onSyncingChanged(false)
    }

    func runManualSync() {
        scheduleSync(reason: "手动同步")
    }

    private func scheduleSync(reason: String) {
        nextReason = reason
        guard !isSyncing else { return }

        Task { @MainActor in
            await drainSyncQueue()
        }
    }

    private func drainSyncQueue() async {
        guard !isSyncing else { return }
        isSyncing = true
        onSyncingChanged(true)
        defer {
            isSyncing = false
            onSyncingChanged(false)
        }

        while let reason = nextReason {
            nextReason = nil
            do {
                try await syncOnce(reason: reason)
            } catch {
                log("同步失败：\(error.localizedDescription)")
            }
        }
    }

    private func syncOnce(reason: String) async throws {
        log("开始同步：\(reason)")

        let reminders = try await reminderStore.fetchSnapshots(in: selectedReminderLists.map(\.id))
        let todos = try await apiClient.fetchAllTodos(deviceId: deviceId)
        let records = recordStore.load(deviceId: deviceId)
        let updatedRecords = try await reconcile(reminders: reminders, todos: todos, records: records)

        recordStore.save(updatedRecords, deviceId: deviceId)
        let now = Date()
        onLastSyncChanged(now)
        log("同步完成：已合并 \(selectedReminderLists.count) 个 Reminders 列表，共 \(reminders.count) 条，设备侧 \(todos.count) 条。")
    }

    private func reconcile(
        reminders: [ReminderSnapshot],
        todos: [ScreenTodo],
        records: [SyncRecord]
    ) async throws -> [SyncRecord] {
        let remindersById = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
        let todosById = Dictionary(uniqueKeysWithValues: todos.map { ($0.id, $0) })
        let remindersByTitle = Dictionary(grouping: reminders, by: \.titleKey)
        let todosByTitle = Dictionary(grouping: todos, by: { $0.title.titleKey })
        let duplicateReminderTitles = duplicateKeys(remindersByTitle)
        let duplicateTodoTitles = duplicateKeys(todosByTitle)

        logDuplicates(duplicateReminderTitles, source: selectedReminderListSummary)
        logDuplicates(duplicateTodoTitles, source: "\(AppConstants.deviceName) 设备")

        let activeRecords = records.filter {
            $0.reminderListID.nilIfBlank == nil || selectedReminderListIDs.contains($0.reminderListID)
        }
        let inactiveRecords = records.filter {
            $0.reminderListID.nilIfBlank != nil && !selectedReminderListIDs.contains($0.reminderListID)
        }

        let removedInactiveTodoIds = try await purgeDeselectedListTodos(records: inactiveRecords, todosById: todosById)

        var nextRecords: [SyncRecord] = []
        var usedReminderIds = Set<String>()
        var usedTodoIds = removedInactiveTodoIds

        for var record in activeRecords {
            let reminder = record.reminderIdentifier.flatMap { remindersById[$0] }
            let hadRecordedScreenTodo = record.screenTodoId != nil
            let rawTodo = record.screenTodoId.flatMap { todosById[$0] }
            let todo = trustedScreenTodo(for: record, reminder: reminder, rawTodo: rawTodo)
            if rawTodo != nil && todo == nil {
                record.screenTodoId = nil
            }

            switch (reminder, todo) {
            case let (.some(reminder), .some(todo)):
                usedReminderIds.insert(reminder.id)
                usedTodoIds.insert(todo.id)
                try await reconcilePair(record: &record, reminder: reminder, todo: todo)
                nextRecords.append(record)

            case let (.some(reminder), .none):
                usedReminderIds.insert(reminder.id)
                if try await handleMissingScreenTodo(
                    reminder: reminder,
                    record: &record,
                    todosByTitle: todosByTitle,
                    hadRecordedScreenTodo: hadRecordedScreenTodo
                ) {
                    if let screenTodoId = record.screenTodoId {
                        usedTodoIds.insert(screenTodoId)
                    }
                    nextRecords.append(record)
                }

            case let (.none, .some(todo)):
                if let migratedReminder = migratedReminder(
                    for: record,
                    todo: todo,
                    remindersByTitle: remindersByTitle,
                    duplicateReminderTitles: duplicateReminderTitles,
                    usedReminderIds: usedReminderIds
                ) {
                    usedReminderIds.insert(migratedReminder.id)
                    usedTodoIds.insert(todo.id)
                    try await reconcilePair(record: &record, reminder: migratedReminder, todo: todo)
                    nextRecords.append(record)
                    continue
                }

                if try await handleMissingReminder(todo: todo, record: &record) {
                    usedTodoIds.insert(todo.id)
                    if let reminderIdentifier = record.reminderIdentifier {
                        usedReminderIds.insert(reminderIdentifier)
                    }
                    nextRecords.append(record)
                }

            case (.none, .none):
                log("历史记录已失效：\(record.titleKey)，已清理。")
            }
        }

        try await pairUnmatchedByTitle(
            reminders: reminders,
            todos: todos,
            remindersByTitle: remindersByTitle,
            todosByTitle: todosByTitle,
            duplicateReminderTitles: duplicateReminderTitles,
            duplicateTodoTitles: duplicateTodoTitles,
            usedReminderIds: &usedReminderIds,
            usedTodoIds: &usedTodoIds,
            records: &nextRecords
        )

        try await createScreenTodosForUnmatchedReminders(
            reminders: reminders,
            todosByTitle: todosByTitle,
            duplicateReminderTitles: duplicateReminderTitles,
            usedReminderIds: &usedReminderIds,
            records: &nextRecords
        )

        try createRemindersForUnmatchedScreenTodos(
            todos: todos,
            remindersByTitle: remindersByTitle,
            duplicateTodoTitles: duplicateTodoTitles,
            usedTodoIds: &usedTodoIds,
            records: &nextRecords
        )

        return coalescedRecords(nextRecords)
    }

    private func pairUnmatchedByTitle(
        reminders: [ReminderSnapshot],
        todos: [ScreenTodo],
        remindersByTitle: [String: [ReminderSnapshot]],
        todosByTitle: [String: [ScreenTodo]],
        duplicateReminderTitles: Set<String>,
        duplicateTodoTitles: Set<String>,
        usedReminderIds: inout Set<String>,
        usedTodoIds: inout Set<Int>,
        records: inout [SyncRecord]
    ) async throws {
        for reminder in reminders where !usedReminderIds.contains(reminder.id) {
            let key = reminder.titleKey
            guard !key.isEmpty,
                  !duplicateReminderTitles.contains(key),
                  !duplicateTodoTitles.contains(key) else {
                continue
            }

            let candidates = (todosByTitle[key] ?? []).filter { !usedTodoIds.contains($0.id) }
            guard candidates.count == 1, let todo = candidates.first else { continue }

            var record = makeRecord(reminder: reminder, todo: todo)
            try await reconcilePair(record: &record, reminder: reminder, todo: todo)
            records.append(record)
            usedReminderIds.insert(reminder.id)
            usedTodoIds.insert(todo.id)
        }

        for todo in todos where !usedTodoIds.contains(todo.id) {
            let key = todo.title.titleKey
            guard !key.isEmpty,
                  !duplicateReminderTitles.contains(key),
                  !duplicateTodoTitles.contains(key) else {
                continue
            }

            let candidates = (remindersByTitle[key] ?? []).filter { !usedReminderIds.contains($0.id) }
            guard candidates.count == 1, let reminder = candidates.first else { continue }

            var record = makeRecord(reminder: reminder, todo: todo)
            try await reconcilePair(record: &record, reminder: reminder, todo: todo)
            records.append(record)
            usedReminderIds.insert(reminder.id)
            usedTodoIds.insert(todo.id)
        }
    }

    private func createScreenTodosForUnmatchedReminders(
        reminders: [ReminderSnapshot],
        todosByTitle: [String: [ScreenTodo]],
        duplicateReminderTitles: Set<String>,
        usedReminderIds: inout Set<String>,
        records: inout [SyncRecord]
    ) async throws {
        for reminder in reminders where !usedReminderIds.contains(reminder.id) {
            let key = reminder.titleKey
            guard !key.isEmpty else {
                log("跳过空标题提醒事项。")
                continue
            }
            guard !duplicateReminderTitles.contains(key) else { continue }

            if reminder.isCompleted {
                log("已完成提醒事项不会新建到屏幕：\(reminder.title)")
                usedReminderIds.insert(reminder.id)
                continue
            }

            if reminder.isPastDue {
                var record = makeRecord(reminder: reminder, todo: nil)
                record.reminderListID = reminder.calendarIdentifier
                record.lastReminderFingerprint = reminder.syncFingerprint
                record.lastAppleModifiedAt = reminder.effectiveModifiedAt
                records.append(record)
                usedReminderIds.insert(reminder.id)
                log("已逾期提醒事项不会创建到屏幕，但会保留在 \(reminderListLabel(for: reminder.calendarIdentifier))：\(reminder.title)")
                continue
            }

            if let existing = todosByTitle[key], !existing.isEmpty {
                log("屏幕已存在同名待办，跳过新建以避免重复：\(reminder.title)")
                continue
            }

            let created = try await apiClient.createTodo(reminderStore.screenDraft(from: reminder, deviceId: deviceId))
            var record = makeRecord(reminder: reminder, todo: nil)
            record.reminderListID = reminder.calendarIdentifier
            record.screenTodoId = created.id
            record.lastReminderFingerprint = reminder.syncFingerprint
            record.lastScreenFingerprint = reminder.syncFingerprint
            record.lastAppleModifiedAt = reminder.effectiveModifiedAt
            record.lastScreenModifiedAt = Date()
            record.lastScreenCreatedAt = created.createdAt
            records.append(record)
            usedReminderIds.insert(reminder.id)
            log("已将提醒事项同步到屏幕：\(reminder.title)")
        }
    }

    private func createRemindersForUnmatchedScreenTodos(
        todos: [ScreenTodo],
        remindersByTitle: [String: [ReminderSnapshot]],
        duplicateTodoTitles: Set<String>,
        usedTodoIds: inout Set<Int>,
        records: inout [SyncRecord]
    ) throws {
        for todo in todos where !usedTodoIds.contains(todo.id) {
            let key = todo.title.titleKey
            guard !key.isEmpty else {
                log("跳过屏幕中的空标题待办。")
                continue
            }
            guard !duplicateTodoTitles.contains(key) else { continue }

            if let sameTitle = remindersByTitle[key], !sameTitle.isEmpty {
                log("\(selectedReminderListSummary) 已存在同名提醒事项，跳过屏幕新建项以避免重复：\(todo.title)")
                continue
            }

            if !canWriteRepeatPatternToApple(for: todo) {
                var record = makeRecord(reminder: nil, todo: todo)
                record.lastReminderFingerprint = todo.syncFingerprint
                record.lastScreenFingerprint = todo.syncFingerprint
                record.lastAppleModifiedAt = Date()
                record.lastScreenModifiedAt = todo.updatedAt
                records.append(record)
                usedTodoIds.insert(todo.id)
                log("屏幕重复待办缺少截止日期，苹果提醒事项要求重复提醒必须有截止日期，暂不写入重复规则：\(todo.title)")
                continue
            }

            let created = try reminderStore.createReminder(from: todo, in: writeBackReminderListID)
            var record = makeRecord(reminder: created, todo: todo)
            record.reminderListID = created.calendarIdentifier
            record.lastReminderFingerprint = created.syncFingerprint
            record.lastScreenFingerprint = todo.syncFingerprint
            record.lastAppleModifiedAt = created.effectiveModifiedAt ?? Date()
            record.lastScreenModifiedAt = todo.updatedAt
            record.lastScreenCreatedAt = todo.createdAt
            records.append(record)
            usedTodoIds.insert(todo.id)
            log("屏幕新增待办已写入 \(reminderListLabel(for: created.calendarIdentifier))：\(todo.title)")
        }
    }

    private func handleMissingScreenTodo(
        reminder: ReminderSnapshot,
        record: inout SyncRecord,
        todosByTitle: [String: [ScreenTodo]],
        hadRecordedScreenTodo: Bool
    ) async throws -> Bool {
        let listLabel = reminderListLabel(for: reminder.calendarIdentifier)

        if reminder.isCompleted {
            record.reminderListID = reminder.calendarIdentifier
            record.screenTodoId = nil
            record.titleKey = reminder.titleKey
            record.lastReminderFingerprint = reminder.syncFingerprint
            record.lastAppleModifiedAt = reminder.effectiveModifiedAt
            log("屏幕删除了已完成提醒事项，按规则保留 \(listLabel)：\(reminder.title)")
            return true
        }

        if let candidates = todosByTitle[reminder.titleKey], candidates.count == 1, let todo = candidates.first {
            record.screenTodoId = todo.id
            try await reconcilePair(record: &record, reminder: reminder, todo: todo)
            return true
        }

        if reminder.isPastDue {
            record.reminderListID = reminder.calendarIdentifier
            record.screenTodoId = nil
            record.titleKey = reminder.titleKey
            record.lastReminderFingerprint = reminder.syncFingerprint
            record.lastScreenFingerprint = nil
            record.lastAppleModifiedAt = reminder.effectiveModifiedAt
            log("已逾期提醒事项暂不在屏幕创建，继续保留在 \(listLabel)：\(reminder.title)")
            return true
        }

        if hadRecordedScreenTodo {
            try reminderStore.deleteReminder(identifier: reminder.id, in: reminder.calendarIdentifier)
            log("屏幕删除了未完成待办，已删除 \(listLabel) 中对应提醒事项：\(reminder.title)")
            return false
        }

        let created = try await apiClient.createTodo(reminderStore.screenDraft(from: reminder, deviceId: deviceId))
        record.reminderListID = reminder.calendarIdentifier
        record.screenTodoId = created.id
        record.titleKey = reminder.titleKey
        record.lastReminderFingerprint = reminder.syncFingerprint
        record.lastScreenFingerprint = reminder.syncFingerprint
        record.lastAppleModifiedAt = reminder.effectiveModifiedAt
        record.lastScreenModifiedAt = Date()
        record.lastScreenCreatedAt = created.createdAt
        log("未完成提醒事项重新同步到屏幕：\(reminder.title)")
        return true
    }

    private func handleMissingReminder(todo: ScreenTodo, record: inout SyncRecord) async throws -> Bool {
        if !canWriteRepeatPatternToApple(for: todo) {
            let alreadyLogged =
                record.reminderIdentifier == nil &&
                record.lastReminderFingerprint == todo.syncFingerprint &&
                record.lastScreenFingerprint == todo.syncFingerprint
            record.titleKey = todo.title.titleKey
            record.lastReminderFingerprint = todo.syncFingerprint
            record.lastScreenFingerprint = todo.syncFingerprint
            record.lastAppleModifiedAt = Date()
            record.lastScreenModifiedAt = todo.updatedAt
            record.lastScreenCreatedAt = todo.createdAt
            if !alreadyLogged {
                log("屏幕重复待办缺少截止日期，苹果提醒事项要求重复提醒必须有截止日期，暂不写入重复规则：\(todo.title)")
            }
            return true
        }

        if record.reminderIdentifier != nil {
            try await apiClient.deleteTodo(id: todo.id)
            log("\(reminderListLabel(for: record.reminderListID)) 中对应提醒事项不存在，已删除屏幕待办：\(todo.title)")
            return false
        }

        let created = try reminderStore.createReminder(from: todo, in: writeBackReminderListID)
        record.reminderListID = created.calendarIdentifier
        record.reminderIdentifier = created.id
        record.titleKey = created.titleKey
        record.lastReminderFingerprint = created.syncFingerprint
        record.lastScreenFingerprint = todo.syncFingerprint
        record.lastAppleModifiedAt = created.effectiveModifiedAt ?? Date()
        record.lastScreenModifiedAt = todo.updatedAt
        record.lastScreenCreatedAt = todo.createdAt
        log("屏幕待办已补充写入 \(reminderListLabel(for: created.calendarIdentifier))：\(todo.title)")
        return true
    }

    private func reconcilePair(
        record: inout SyncRecord,
        reminder: ReminderSnapshot,
        todo: ScreenTodo
    ) async throws {
        let direction = chooseDirection(record: record, reminder: reminder, todo: todo)

        switch direction {
        case .none:
            record.reminderListID = reminder.calendarIdentifier
            record.titleKey = reminder.titleKey
            record.reminderIdentifier = reminder.id
            record.screenTodoId = todo.id
            record.lastReminderFingerprint = reminder.syncFingerprint
            record.lastScreenFingerprint = todo.syncFingerprint
            record.lastAppleModifiedAt = reminder.effectiveModifiedAt
            record.lastScreenModifiedAt = todo.updatedAt
            record.lastScreenCreatedAt = todo.createdAt

        case .appleToScreen:
            let applied = try await apply(reminder: reminder, toScreenTodo: todo)
            record.reminderListID = reminder.calendarIdentifier
            record.titleKey = reminder.titleKey
            record.reminderIdentifier = reminder.id
            record.screenTodoId = applied.screenTodoId
            record.lastReminderFingerprint = reminder.syncFingerprint
            record.lastScreenFingerprint = reminder.syncFingerprint
            record.lastAppleModifiedAt = reminder.effectiveModifiedAt
            record.lastScreenModifiedAt = applied.screenModifiedAt
            record.lastScreenCreatedAt = applied.screenCreatedAt
            if applied.recreatedForRepeatPattern {
                log("已重建屏幕待办以同步重复规则：\(reminder.title)")
            } else {
                log("按最新修改从 \(reminderListLabel(for: reminder.calendarIdentifier)) 更新屏幕：\(reminder.title)")
            }

        case .screenToApple:
            if !canWriteRepeatPatternToApple(for: todo) {
                record.reminderListID = reminder.calendarIdentifier
                record.titleKey = reminder.titleKey
                record.reminderIdentifier = reminder.id
                record.screenTodoId = todo.id
                record.lastReminderFingerprint = todo.syncFingerprint
                record.lastScreenFingerprint = todo.syncFingerprint
                record.lastAppleModifiedAt = todo.updatedAt ?? reminder.effectiveModifiedAt
                record.lastScreenModifiedAt = todo.updatedAt
                record.lastScreenCreatedAt = todo.createdAt
                log("屏幕重复待办缺少截止日期，苹果提醒事项要求重复提醒必须有截止日期，已保留苹果侧原有重复规则：\(todo.title)")
                return
            }

            if let updated = try reminderStore.updateReminder(identifier: reminder.id, from: todo, in: reminder.calendarIdentifier) {
                record.reminderListID = updated.calendarIdentifier
                record.titleKey = updated.titleKey
                record.reminderIdentifier = updated.id
                record.screenTodoId = todo.id
                record.lastReminderFingerprint = updated.syncFingerprint
                record.lastScreenFingerprint = todo.syncFingerprint
                record.lastAppleModifiedAt = updated.effectiveModifiedAt ?? Date()
                record.lastScreenModifiedAt = todo.updatedAt
                record.lastScreenCreatedAt = todo.createdAt
                log("按最新修改从屏幕更新 \(reminderListLabel(for: updated.calendarIdentifier))：\(todo.title)")
            }
        }
    }

    private struct ScreenApplyResult {
        let screenTodoId: Int
        let screenCreatedAt: Date?
        let screenModifiedAt: Date?
        let recreatedForRepeatPattern: Bool
    }

    private func apply(reminder: ReminderSnapshot, toScreenTodo todo: ScreenTodo) async throws -> ScreenApplyResult {
        if reminder.repeatPattern != todo.repeatPattern && !reminder.isPastDue {
            let recreated = try await apiClient.createTodo(reminderStore.screenDraft(from: reminder, deviceId: deviceId))

            if reminder.isCompleted {
                try await apiClient.toggleTodoCompletion(id: recreated.id)
            }

            do {
                try await apiClient.deleteTodo(id: todo.id)
            } catch {
                log("屏幕旧待办删除失败，可能需要手动清理：\(todo.title)")
            }

            return ScreenApplyResult(
                screenTodoId: recreated.id,
                screenCreatedAt: recreated.createdAt,
                screenModifiedAt: Date(),
                recreatedForRepeatPattern: true
            )
        }

        let update = ScreenTodoUpdate(
            title: reminder.title,
            description: reminder.notes ?? "",
            dueDate: reminder.dueDate ?? "",
            dueTime: reminder.dueTime ?? "",
            priority: reminder.screenPriority
        )

        var changed = false
        if update.differs(from: todo) {
            try await apiClient.updateTodo(id: todo.id, update: update)
            changed = true
        }

        if todo.isCompleted != reminder.isCompleted {
            try await apiClient.toggleTodoCompletion(id: todo.id)
            changed = true
        }

        if reminder.repeatPattern != todo.repeatPattern && reminder.isPastDue {
            log("提醒事项已逾期，当前无法在屏幕重建重复规则，已保留现有屏幕待办：\(reminder.title)")
        }

        return ScreenApplyResult(
            screenTodoId: todo.id,
            screenCreatedAt: todo.createdAt,
            screenModifiedAt: changed ? Date() : todo.updatedAt,
            recreatedForRepeatPattern: false
        )
    }

    private enum SyncDirection {
        case none
        case appleToScreen
        case screenToApple
    }

    private func chooseDirection(record: SyncRecord, reminder: ReminderSnapshot, todo: ScreenTodo) -> SyncDirection {
        if reminder.syncFingerprint == todo.syncFingerprint {
            return .none
        }

        let reminderChanged = record.lastReminderFingerprint.map { $0 != reminder.syncFingerprint } ?? false
        let screenChanged = record.lastScreenFingerprint.map { $0 != todo.syncFingerprint } ?? false

        if reminderChanged && !screenChanged {
            return .appleToScreen
        }
        if screenChanged && !reminderChanged {
            return .screenToApple
        }

        let appleDate = reminder.effectiveModifiedAt ?? record.lastAppleModifiedAt ?? .distantPast
        let screenDate = todo.updatedAt ?? record.lastScreenModifiedAt ?? .distantPast
        return screenDate > appleDate ? .screenToApple : .appleToScreen
    }

    private func makeRecord(reminder: ReminderSnapshot?, todo: ScreenTodo?) -> SyncRecord {
        SyncRecord(
            reminderListID: reminder?.calendarIdentifier ?? writeBackReminderListID,
            deviceId: deviceId,
            titleKey: reminder?.titleKey ?? todo?.title.titleKey ?? "",
            reminderIdentifier: reminder?.id,
            screenTodoId: todo?.id,
            lastReminderFingerprint: reminder?.syncFingerprint,
            lastScreenFingerprint: todo?.syncFingerprint,
            lastAppleModifiedAt: reminder?.effectiveModifiedAt,
            lastScreenModifiedAt: todo?.updatedAt,
            lastScreenCreatedAt: todo?.createdAt
        )
    }

    private func migratedReminder(
        for record: SyncRecord,
        todo: ScreenTodo,
        remindersByTitle: [String: [ReminderSnapshot]],
        duplicateReminderTitles: Set<String>,
        usedReminderIds: Set<String>
    ) -> ReminderSnapshot? {
        guard record.reminderIdentifier != nil else { return nil }

        let keys = [record.titleKey, todo.title.titleKey]
            .compactMap { $0.nilIfBlank }

        for key in keys {
            guard !duplicateReminderTitles.contains(key) else { continue }

            let candidates = (remindersByTitle[key] ?? []).filter { !usedReminderIds.contains($0.id) }
            if candidates.count == 1, let candidate = candidates.first {
                log("检测到提醒事项已迁移列表，已按同名条目重连：\(todo.title)")
                return candidate
            }
        }

        return nil
    }

    private func canWriteRepeatPatternToApple(for todo: ScreenTodo) -> Bool {
        !(todo.repeatPattern.isRepeating && todo.dueDate?.nilIfBlank == nil)
    }

    private func trustedScreenTodo(
        for record: SyncRecord,
        reminder: ReminderSnapshot?,
        rawTodo: ScreenTodo?
    ) -> ScreenTodo? {
        guard let rawTodo else { return nil }

        let todoKey = rawTodo.title.titleKey
        let knownKeys = Set([record.titleKey, reminder?.titleKey].compactMap { $0?.nilIfBlank })
        if knownKeys.contains(todoKey) {
            return rawTodo
        }

        switch screenIdentityState(record: record, todo: rawTodo) {
        case .sameCreation:
            log("屏幕待办标题已变化，id 仍指向同一创建记录：\(record.titleKey) -> \(rawTodo.title)")
            return rawTodo
        case .reusedID:
            log("检测到屏幕 id \(rawTodo.id) 已被复用，旧标题 \(record.titleKey)，新标题 \(rawTodo.title)。已忽略该 id，避免误更新或误删。")
            return nil
        case .unknown:
            log("屏幕 id \(rawTodo.id) 的标题已变化且无法确认 createDate，按 id 复用风险处理：\(record.titleKey) -> \(rawTodo.title)")
            return nil
        }
    }

    private enum ScreenIdentityState {
        case sameCreation
        case reusedID
        case unknown
    }

    private func screenIdentityState(record: SyncRecord, todo: ScreenTodo) -> ScreenIdentityState {
        if let previous = record.lastScreenCreatedAt,
           let current = todo.createdAt {
            return abs(current.timeIntervalSince(previous)) <= 1 ? .sameCreation : .reusedID
        }

        if let current = todo.createdAt,
           let lastModified = record.lastScreenModifiedAt {
            return current.timeIntervalSince(lastModified) > 1 ? .reusedID : .sameCreation
        }

        return .unknown
    }

    private func purgeDeselectedListTodos(
        records: [SyncRecord],
        todosById: [Int: ScreenTodo]
    ) async throws -> Set<Int> {
        var removedTodoIds = Set<Int>()

        for record in records {
            guard let screenTodoId = record.screenTodoId,
                  !removedTodoIds.contains(screenTodoId),
                  let rawTodo = todosById[screenTodoId],
                  let todo = trustedScreenTodo(for: record, reminder: nil, rawTodo: rawTodo) else {
                continue
            }

            try await apiClient.deleteTodo(id: todo.id)
            removedTodoIds.insert(todo.id)
            log("已取消同步列表 \(reminderListLabel(for: record.reminderListID))，对应屏幕待办已移除：\(todo.title)")
        }

        return removedTodoIds
    }

    private func duplicateKeys<T>(_ grouped: [String: [T]]) -> Set<String> {
        Set(grouped.compactMap { key, values in
            key.isEmpty || values.count < 2 ? nil : key
        })
    }

    private func logDuplicates(_ keys: Set<String>, source: String) {
        guard !keys.isEmpty else { return }
        let titles = keys.sorted().prefix(5).joined(separator: "、")
        log("\(source) 存在重复标题，已跳过这些标题的自动配对和删除：\(titles)")
    }

    private func coalescedRecords(_ records: [SyncRecord]) -> [SyncRecord] {
        var byKey: [String: SyncRecord] = [:]
        for record in records {
            let key = [
                record.reminderListID,
                record.reminderIdentifier ?? "-",
                record.screenTodoId.map(String.init) ?? "-",
                record.titleKey
            ].joined(separator: "|")
            byKey[key] = record
        }
        return byKey.values.sorted { lhs, rhs in
            if lhs.reminderListID == rhs.reminderListID {
                return lhs.titleKey < rhs.titleKey
            }
            return lhs.reminderListID < rhs.reminderListID
        }
    }

    private func reminderListLabel(for calendarIdentifier: String?) -> String {
        guard let calendarIdentifier = calendarIdentifier?.nilIfBlank else {
            return selectedReminderListSummary
        }
        return reminderListTitlesByID[calendarIdentifier] ?? calendarIdentifier
    }

    private static func makeSummary(from lists: [ReminderListOption]) -> String {
        switch lists.count {
        case 0:
            return "所选提醒事项列表"
        case 1:
            return lists[0].displayName
        case 2...3:
            return lists.map(\.displayName).joined(separator: "、")
        default:
            let leading = lists.prefix(3).map(\.displayName).joined(separator: "、")
            return "\(leading) 等 \(lists.count) 个列表"
        }
    }

    private func log(_ message: String) {
        onLog(message)
    }
}
