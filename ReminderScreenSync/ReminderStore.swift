import EventKit
import Foundation

enum ReminderStoreError: LocalizedError {
    case accessDenied
    case writeOnlyAccess
    case noWritableLists
    case missingSelectedList
    case unsafeCalendar

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "没有提醒事项完整访问权限。请在系统设置中允许本应用访问提醒事项。"
        case .writeOnlyAccess:
            return "当前只有写入权限，无法读取和同步提醒事项。请授予完整访问权限。"
        case .noWritableLists:
            return "没有可写入的提醒事项列表。"
        case .missingSelectedList:
            return "所选提醒事项列表不存在，或已被删除。"
        case .unsafeCalendar:
            return "安全检查失败：目标提醒事项不属于当前选中的列表，已拒绝写入。"
        }
    }
}

@MainActor
final class ReminderStore: ObservableObject {
    let eventStore = EKEventStore()

    @Published private(set) var authorizationSummary: String = "未检查"

    func refreshAuthorizationSummary() {
        authorizationSummary = Self.summary(for: EKEventStore.authorizationStatus(for: .reminder))
    }

    func requestAccessIfNeeded() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if Self.hasFullReminderAccess(status) {
            refreshAuthorizationSummary()
            return
        }

        if Self.isWriteOnly(status) {
            refreshAuthorizationSummary()
            throw ReminderStoreError.writeOnlyAccess
        }

        if status == .denied || status == .restricted {
            refreshAuthorizationSummary()
            throw ReminderStoreError.accessDenied
        }

        let granted = try await requestReminderAccess()
        refreshAuthorizationSummary()
        guard granted else { throw ReminderStoreError.accessDenied }
    }

    func fetchReminderLists() async throws -> [ReminderListOption] {
        try await requestAccessIfNeeded()
        let calendars = reminderCalendars()
        guard !calendars.isEmpty else {
            throw ReminderStoreError.noWritableLists
        }
        return calendars.map {
            ReminderListOption(
                id: $0.calendarIdentifier,
                title: $0.title,
                sourceTitle: $0.source.title
            )
        }
    }

    func fetchSnapshots(in calendarIdentifiers: [String]) async throws -> [ReminderSnapshot] {
        try await requestAccessIfNeeded()
        let uniqueIdentifiers = Array(Set(calendarIdentifiers)).sorted()
        guard !uniqueIdentifiers.isEmpty else { return [] }

        let calendars = try uniqueIdentifiers.map { try reminderCalendar(identifier: $0) }
        let allowedIdentifiers = Set(calendars.map(\.calendarIdentifier))
        let predicate = eventStore.predicateForReminders(in: calendars)
        let reminders = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        let snapshots = reminders
            .filter { allowedIdentifiers.contains($0.calendar.calendarIdentifier) }
            .map(Self.snapshot(from:))
        return Self.normalizedSnapshots(snapshots)
    }

    func fetchSnapshots(in calendarIdentifier: String) async throws -> [ReminderSnapshot] {
        try await fetchSnapshots(in: [calendarIdentifier])
    }

    func createReminder(from todo: ScreenTodo, in calendarIdentifier: String) throws -> ReminderSnapshot {
        let calendar = try reminderCalendar(identifier: calendarIdentifier)
        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        apply(todo: todo, to: reminder)
        try eventStore.save(reminder, commit: true)
        return Self.snapshot(from: reminder)
    }

    func updateReminder(
        identifier: String,
        from todo: ScreenTodo,
        in calendarIdentifier: String
    ) throws -> ReminderSnapshot? {
        guard let reminder = try reminder(identifier: identifier, calendarIdentifier: calendarIdentifier) else { return nil }
        apply(todo: todo, to: reminder)
        try validate(reminder, calendarIdentifier: calendarIdentifier)
        try eventStore.save(reminder, commit: true)
        return Self.snapshot(from: reminder)
    }

    func setReminderCompletion(
        identifier: String,
        completed: Bool,
        in calendarIdentifier: String
    ) throws -> ReminderSnapshot? {
        guard let reminder = try reminder(identifier: identifier, calendarIdentifier: calendarIdentifier) else { return nil }
        reminder.isCompleted = completed
        reminder.completionDate = completed ? (reminder.completionDate ?? Date()) : nil
        try validate(reminder, calendarIdentifier: calendarIdentifier)
        try eventStore.save(reminder, commit: true)
        return Self.snapshot(from: reminder)
    }

    func deleteReminder(identifier: String, in calendarIdentifier: String) throws {
        guard let reminder = try reminder(identifier: identifier, calendarIdentifier: calendarIdentifier) else { return }
        try validate(reminder, calendarIdentifier: calendarIdentifier)
        try eventStore.remove(reminder, commit: true)
    }

    func screenDraft(from reminder: ReminderSnapshot, deviceId: String) -> ScreenTodoDraft {
        ScreenTodoDraft(
            title: reminder.title,
            description: reminder.notes?.nilIfBlank,
            dueDate: reminder.dueDate,
            dueTime: reminder.dueTime,
            repeatType: reminder.repeatPattern.repeatType,
            repeatWeekday: reminder.repeatPattern.repeatWeekday,
            repeatMonth: reminder.repeatPattern.repeatMonth,
            repeatDay: reminder.repeatPattern.repeatDay,
            priority: reminder.screenPriority,
            deviceId: deviceId
        )
    }

    func preferredWriteBackListID(from selectedCalendarIDs: [String]) -> String? {
        let selectedSet = Set(selectedCalendarIDs)
        guard !selectedSet.isEmpty else { return nil }

        let calendars = reminderCalendars().filter { selectedSet.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return nil }

        if let defaultCalendar = eventStore.defaultCalendarForNewReminders(),
           calendars.contains(where: { $0.calendarIdentifier == defaultCalendar.calendarIdentifier }) {
            return defaultCalendar.calendarIdentifier
        }

        for identifier in selectedCalendarIDs where calendars.contains(where: { $0.calendarIdentifier == identifier }) {
            return identifier
        }

        return calendars.first?.calendarIdentifier
    }

    private func requestReminderAccess() async throws -> Bool {
        if #available(macOS 14.0, *) {
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestFullAccessToReminders { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .reminder) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }

    private func reminderCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .reminder)
            .filter(\.allowsContentModifications)
            .sorted {
                if $0.source.title == $1.source.title {
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                return $0.source.title.localizedStandardCompare($1.source.title) == .orderedAscending
            }
    }

    private func reminderCalendar(identifier: String) throws -> EKCalendar {
        guard let calendar = reminderCalendars().first(where: { $0.calendarIdentifier == identifier }) else {
            throw ReminderStoreError.missingSelectedList
        }
        return calendar
    }

    private func reminder(identifier: String, calendarIdentifier: String) throws -> EKReminder? {
        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            return nil
        }
        try validate(reminder, calendarIdentifier: calendarIdentifier)
        return reminder
    }

    private func validate(_ reminder: EKReminder, calendarIdentifier: String) throws {
        let calendar = try reminderCalendar(identifier: calendarIdentifier)
        guard reminder.calendar.calendarIdentifier == calendar.calendarIdentifier else {
            throw ReminderStoreError.unsafeCalendar
        }
    }

    private func apply(todo: ScreenTodo, to reminder: EKReminder) {
        reminder.title = todo.title
        reminder.notes = todo.description?.nilIfBlank
        reminder.dueDateComponents = Self.makeDueDateComponents(
            dueDate: todo.dueDate,
            dueTime: todo.dueTime
        )
        reminder.recurrenceRules = Self.makeRecurrenceRules(
            repeatPattern: todo.syncRepeatPattern,
            dueComponents: reminder.dueDateComponents
        )
        reminder.priority = ReminderPriority.toReminderPriority(todo.priority)
        reminder.isCompleted = todo.isCompleted
        reminder.completionDate = todo.isCompleted ? (reminder.completionDate ?? Date()) : nil
    }

    private static func snapshot(from reminder: EKReminder) -> ReminderSnapshot {
        let due = dueStrings(from: reminder.dueDateComponents)
        return ReminderSnapshot(
            id: reminder.calendarItemIdentifier,
            calendarIdentifier: reminder.calendar.calendarIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes,
            dueDate: due.date,
            dueTime: due.time,
            repeatPattern: repeatPattern(
                from: reminder.recurrenceRules,
                dueComponents: reminder.dueDateComponents
            ),
            isCompleted: reminder.isCompleted,
            priority: reminder.priority,
            lastModifiedAt: reminder.lastModifiedDate,
            completionDate: reminder.completionDate
        )
    }

    private static func dueStrings(from components: DateComponents?) -> (date: String?, time: String?) {
        guard let components else { return (nil, nil) }

        let dateString: String?
        if let year = components.year,
           let month = components.month,
           let day = components.day {
            dateString = String(format: "%04d-%02d-%02d", year, month, day)
        } else {
            dateString = nil
        }

        let timeString: String?
        if components.hour != nil || components.minute != nil {
            timeString = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
        } else {
            timeString = nil
        }

        return (dateString, timeString)
    }

    private static func makeDueDateComponents(dueDate: String?, dueTime: String?) -> DateComponents? {
        guard let dueDate = dueDate?.nilIfBlank else { return nil }
        let dateParts = dueDate.split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3 else { return nil }

        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = TimeZone.current
        components.year = dateParts[0]
        components.month = dateParts[1]
        components.day = dateParts[2]

        if let dueTime = dueTime?.nilIfBlank {
            let timeParts = dueTime.split(separator: ":").compactMap { Int($0) }
            if timeParts.count >= 2 {
                components.hour = timeParts[0]
                components.minute = timeParts[1]
            }
        }

        return components
    }

    private static func repeatPattern(
        from recurrenceRules: [EKRecurrenceRule]?,
        dueComponents: DateComponents?
    ) -> RepeatPattern {
        guard let rule = recurrenceRules?.first else { return .none }

        switch rule.frequency {
        case .daily:
            return rule.interval == 1 ? RepeatPattern(repeatType: "daily") : .none
        case .weekly:
            guard rule.interval == 1 else { return .none }
            let weekday = rule.daysOfTheWeek?.first.map(screenWeekday(from:))
                ?? dueComponents?.weekday.map { ($0 + 6) % 7 }
            return RepeatPattern(repeatType: "weekly", repeatWeekday: weekday)
        case .monthly:
            guard rule.interval == 1 else { return .none }
            let day = rule.daysOfTheMonth?.first?.intValue ?? dueComponents?.day
            return RepeatPattern(repeatType: "monthly", repeatDay: day)
        case .yearly:
            guard rule.interval == 1 else { return .none }
            let month = rule.monthsOfTheYear?.first?.intValue ?? dueComponents?.month
            let day = rule.daysOfTheMonth?.first?.intValue ?? dueComponents?.day
            return RepeatPattern(repeatType: "yearly", repeatMonth: month, repeatDay: day)
        @unknown default:
            return .none
        }
    }

    private static func makeRecurrenceRules(
        repeatPattern: RepeatPattern,
        dueComponents: DateComponents?
    ) -> [EKRecurrenceRule]? {
        guard repeatPattern.isRepeating else { return nil }
        guard dueComponents != nil else { return nil }

        switch repeatPattern.repeatType {
        case "daily":
            return [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]
        case "weekly":
            guard let screenWeekday = repeatPattern.repeatWeekday ?? dueComponents?.weekday.map({ ($0 + 6) % 7 }),
                  let weekday = ekWeekday(fromScreenWeekday: screenWeekday) else {
                return nil
            }
            let day = EKRecurrenceDayOfWeek(weekday)
            return [
                EKRecurrenceRule(
                    recurrenceWith: .weekly,
                    interval: 1,
                    daysOfTheWeek: [day],
                    daysOfTheMonth: nil,
                    monthsOfTheYear: nil,
                    weeksOfTheYear: nil,
                    daysOfTheYear: nil,
                    setPositions: nil,
                    end: nil
                )
            ]
        case "monthly":
            guard let day = repeatPattern.repeatDay ?? dueComponents?.day else { return nil }
            return [
                EKRecurrenceRule(
                    recurrenceWith: .monthly,
                    interval: 1,
                    daysOfTheWeek: nil,
                    daysOfTheMonth: [NSNumber(value: day)],
                    monthsOfTheYear: nil,
                    weeksOfTheYear: nil,
                    daysOfTheYear: nil,
                    setPositions: nil,
                    end: nil
                )
            ]
        case "yearly":
            guard let month = repeatPattern.repeatMonth ?? dueComponents?.month,
                  let day = repeatPattern.repeatDay ?? dueComponents?.day else {
                return nil
            }
            return [
                EKRecurrenceRule(
                    recurrenceWith: .yearly,
                    interval: 1,
                    daysOfTheWeek: nil,
                    daysOfTheMonth: [NSNumber(value: day)],
                    monthsOfTheYear: [NSNumber(value: month)],
                    weeksOfTheYear: nil,
                    daysOfTheYear: nil,
                    setPositions: nil,
                    end: nil
                )
            ]
        default:
            return nil
        }
    }

    private static func normalizedSnapshots(_ snapshots: [ReminderSnapshot]) -> [ReminderSnapshot] {
        let grouped = Dictionary(grouping: snapshots) {
            "\($0.calendarIdentifier)|\($0.titleKey)"
        }

        let normalized = grouped.values.flatMap { group -> [ReminderSnapshot] in
            if let preferred = preferredRecurringSeriesSnapshot(in: group) {
                return [preferred]
            }
            return group
        }

        return normalized.sorted(by: snapshotSort(_:_:))
    }

    private static func preferredRecurringSeriesSnapshot(in group: [ReminderSnapshot]) -> ReminderSnapshot? {
        guard group.count > 1 else { return nil }

        let repeatingCount = group.filter { $0.repeatPattern.isRepeating }.count
        let hasCompleted = group.contains { $0.isCompleted }
        guard repeatingCount > 1 || (repeatingCount >= 1 && hasCompleted) else {
            return nil
        }

        return group.sorted(by: preferredRecurringSnapshotSort(_:_:)).first
    }

    private static func preferredRecurringSnapshotSort(_ lhs: ReminderSnapshot, _ rhs: ReminderSnapshot) -> Bool {
        if lhs.isCompleted != rhs.isCompleted {
            return !lhs.isCompleted
        }

        if lhs.repeatPattern.isRepeating != rhs.repeatPattern.isRepeating {
            return lhs.repeatPattern.isRepeating
        }

        let lhsDue = DueDateResolver.resolve(dueDate: lhs.dueDate, dueTime: lhs.dueTime) ?? .distantPast
        let rhsDue = DueDateResolver.resolve(dueDate: rhs.dueDate, dueTime: rhs.dueTime) ?? .distantPast
        if lhsDue != rhsDue {
            return lhsDue > rhsDue
        }

        return snapshotSort(lhs, rhs)
    }

    private static func snapshotSort(_ lhs: ReminderSnapshot, _ rhs: ReminderSnapshot) -> Bool {
        (lhs.effectiveModifiedAt ?? .distantPast) > (rhs.effectiveModifiedAt ?? .distantPast)
    }

    private static func screenWeekday(from day: EKRecurrenceDayOfWeek) -> Int {
        (day.dayOfTheWeek.rawValue + 6) % 7
    }

    private static func ekWeekday(fromScreenWeekday weekday: Int) -> EKWeekday? {
        switch weekday {
        case 0:
            return .sunday
        case 1:
            return .monday
        case 2:
            return .tuesday
        case 3:
            return .wednesday
        case 4:
            return .thursday
        case 5:
            return .friday
        case 6:
            return .saturday
        default:
            return nil
        }
    }

    private static func hasFullReminderAccess(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .fullAccess || status == .authorized
        } else {
            return status == .authorized
        }
    }

    private static func isWriteOnly(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .writeOnly
        } else {
            return false
        }
    }

    private static func summary(for status: EKAuthorizationStatus) -> String {
        if #available(macOS 14.0, *) {
            switch status {
            case .notDetermined:
                return "未授权"
            case .restricted:
                return "受限制"
            case .denied:
                return "已拒绝"
            case .authorized, .fullAccess:
                return "完整访问"
            case .writeOnly:
                return "仅写入"
            @unknown default:
                return "未知"
            }
        } else {
            switch status {
            case .notDetermined:
                return "未授权"
            case .restricted:
                return "受限制"
            case .denied:
                return "已拒绝"
            case .authorized:
                return "已授权"
            default:
                return "未知"
            }
        }
    }
}
