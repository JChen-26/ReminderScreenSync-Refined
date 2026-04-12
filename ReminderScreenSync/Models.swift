import Foundation

struct APIResponse<T: Decodable>: Decodable {
    let code: Int
    let msg: String?
    let data: T?
}

struct APIStatusResponse: Decodable {
    let code: Int
    let msg: String?
}

struct ScreenDevice: Codable, Identifiable, Hashable {
    let deviceId: String
    let alias: String?
    let board: String?

    var id: String { deviceId }
    var displayName: String {
        let name = alias?.nilIfBlank ?? "未命名设备"
        return "\(name) (\(deviceId))"
    }
}

struct ScreenTodo: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let description: String?
    let dueDate: String?
    let dueTime: String?
    let repeatType: String?
    let repeatWeekday: Int?
    let repeatMonth: Int?
    let repeatDay: Int?
    let status: Int?
    let priority: Int?
    let completed: Bool?
    let deviceId: String?
    let deviceName: String?
    let createDate: String?
    let updateDate: Double?

    var isCompleted: Bool {
        completed ?? (status == 1)
    }

    var updatedAt: Date? {
        guard let updateDate else { return nil }
        return Date(timeIntervalSince1970: updateDate)
    }

    var createdAt: Date? {
        Self.parseCreateDate(createDate)
    }

    var normalizedPriority: Int {
        min(max(priority ?? 0, 0), 2)
    }

    var repeatPattern: RepeatPattern {
        RepeatPattern(
            repeatType: repeatType,
            repeatWeekday: repeatWeekday,
            repeatMonth: repeatMonth,
            repeatDay: repeatDay
        )
    }

    var syncRepeatPattern: RepeatPattern {
        repeatPattern.effectiveForSync(dueDate: dueDate)
    }

    var syncFingerprint: String {
        TodoFingerprint(
            title: title.titleKey,
            notes: description ?? "",
            dueDate: dueDate ?? "",
            dueTime: dueTime ?? "",
            repeatPattern: syncRepeatPattern.stableString,
            priority: normalizedPriority,
            isCompleted: isCompleted
        ).stableString
    }

    private static func parseCreateDate(_ value: String?) -> Date? {
        guard let value = value?.nilIfBlank else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}

struct ScreenTodoDraft: Encodable {
    let title: String
    let description: String?
    let dueDate: String?
    let dueTime: String?
    let repeatType: String?
    let repeatWeekday: Int?
    let repeatMonth: Int?
    let repeatDay: Int?
    let priority: Int?
    let deviceId: String?
}

struct ScreenTodoUpdate: Encodable {
    let title: String?
    let description: String?
    let dueDate: String?
    let dueTime: String?
    let priority: Int?

    var isEmpty: Bool {
        title == nil && description == nil && dueDate == nil && dueTime == nil && priority == nil
    }

    func differs(from todo: ScreenTodo) -> Bool {
        if let title, title != todo.title { return true }
        if (description ?? "") != (todo.description ?? "") { return true }
        if (dueDate ?? "") != (todo.dueDate ?? "") { return true }
        if (dueTime ?? "") != (todo.dueTime ?? "") { return true }
        if let priority, priority != todo.normalizedPriority { return true }
        return false
    }
}

struct ScreenTodoMutationResult: Decodable {
    let id: Int
    let title: String?
    let status: Int?
    let priority: Int?
    let deviceId: String?
    let createDate: String?

    var createdAt: Date? {
        guard let createDate = createDate?.nilIfBlank else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: createDate)
    }
}

struct RepeatPattern: Hashable, Codable {
    let repeatType: String
    let repeatWeekday: Int?
    let repeatMonth: Int?
    let repeatDay: Int?

    static let none = RepeatPattern(repeatType: "none")

    init(
        repeatType: String?,
        repeatWeekday: Int? = nil,
        repeatMonth: Int? = nil,
        repeatDay: Int? = nil
    ) {
        let normalizedType = Self.normalizeType(repeatType)
        self.repeatType = normalizedType

        switch normalizedType {
        case "weekly":
            self.repeatWeekday = Self.normalizeWeekday(repeatWeekday)
            self.repeatMonth = nil
            self.repeatDay = nil
        case "monthly":
            self.repeatWeekday = nil
            self.repeatMonth = nil
            self.repeatDay = Self.normalizeDay(repeatDay)
        case "yearly":
            self.repeatWeekday = nil
            self.repeatMonth = Self.normalizeMonth(repeatMonth)
            self.repeatDay = Self.normalizeDay(repeatDay)
        default:
            self.repeatWeekday = nil
            self.repeatMonth = nil
            self.repeatDay = nil
        }
    }

    var isRepeating: Bool {
        repeatType != "none"
    }

    func effectiveForSync(dueDate: String?) -> RepeatPattern {
        guard isRepeating, dueDate?.nilIfBlank != nil else { return .none }
        return self
    }

    var stableString: String {
        [
            repeatType,
            repeatWeekday.map(String.init) ?? "",
            repeatMonth.map(String.init) ?? "",
            repeatDay.map(String.init) ?? ""
        ].joined(separator: "\u{1E}")
    }

    private static func normalizeType(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "daily":
            return "daily"
        case "weekly":
            return "weekly"
        case "monthly":
            return "monthly"
        case "yearly":
            return "yearly"
        default:
            return "none"
        }
    }

    private static func normalizeWeekday(_ value: Int?) -> Int? {
        guard let value, (0...6).contains(value) else { return nil }
        return value
    }

    private static func normalizeMonth(_ value: Int?) -> Int? {
        guard let value, (1...12).contains(value) else { return nil }
        return value
    }

    private static func normalizeDay(_ value: Int?) -> Int? {
        guard let value, (1...31).contains(value) else { return nil }
        return value
    }
}

struct ReminderListOption: Identifiable, Hashable {
    let id: String
    let title: String
    let sourceTitle: String

    var displayName: String {
        title == sourceTitle ? title : "\(title) · \(sourceTitle)"
    }
}

struct ReminderSnapshot: Identifiable, Hashable {
    let id: String
    let calendarIdentifier: String
    let title: String
    let notes: String?
    let dueDate: String?
    let dueTime: String?
    let repeatPattern: RepeatPattern
    let isCompleted: Bool
    let priority: Int
    let lastModifiedAt: Date?
    let completionDate: Date?

    var titleKey: String { title.titleKey }

    var effectiveModifiedAt: Date? {
        [lastModifiedAt, completionDate].compactMap { $0 }.max()
    }

    var screenPriority: Int {
        ReminderPriority.toScreenPriority(priority)
    }

    var isPastDue: Bool {
        DueDateResolver.isPastDue(dueDate: dueDate, dueTime: dueTime)
    }

    var syncRepeatPattern: RepeatPattern {
        repeatPattern.effectiveForSync(dueDate: dueDate)
    }

    var syncFingerprint: String {
        TodoFingerprint(
            title: titleKey,
            notes: notes ?? "",
            dueDate: dueDate ?? "",
            dueTime: dueTime ?? "",
            repeatPattern: syncRepeatPattern.stableString,
            priority: screenPriority,
            isCompleted: isCompleted
        ).stableString
    }
}

struct TodoFingerprint: Hashable, Codable {
    let title: String
    let notes: String
    let dueDate: String
    let dueTime: String
    let repeatPattern: String
    let priority: Int
    let isCompleted: Bool

    var stableString: String {
        [
            title,
            notes,
            dueDate,
            dueTime,
            repeatPattern,
            String(priority),
            isCompleted ? "1" : "0"
        ].joined(separator: "\u{1F}")
    }
}

enum DueDateResolver {
    static func isPastDue(dueDate: String?, dueTime: String?, referenceDate: Date = Date()) -> Bool {
        guard let resolvedDate = resolve(dueDate: dueDate, dueTime: dueTime) else { return false }
        return resolvedDate < referenceDate
    }

    static func resolve(dueDate: String?, dueTime: String?) -> Date? {
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
                components.second = 0
            }
        } else {
            components.hour = 23
            components.minute = 59
            components.second = 59
        }

        return Calendar.current.date(from: components)
    }
}

enum ReminderPriority {
    static func toScreenPriority(_ reminderPriority: Int) -> Int {
        switch reminderPriority {
        case 1...4:
            return 2
        case 5:
            return 1
        default:
            return 0
        }
    }

    static func toReminderPriority(_ screenPriority: Int?) -> Int {
        switch screenPriority {
        case 2:
            return 1
        case 1:
            return 5
        default:
            return 0
        }
    }
}

struct SyncRecord: Codable, Identifiable, Hashable {
    var reminderListID: String
    var deviceId: String
    var titleKey: String
    var reminderIdentifier: String?
    var screenTodoId: Int?
    var lastReminderFingerprint: String?
    var lastScreenFingerprint: String?
    var lastAppleModifiedAt: Date?
    var lastScreenModifiedAt: Date?
    var lastScreenCreatedAt: Date?

    var id: String {
        [
            reminderListID,
            deviceId,
            titleKey,
            reminderIdentifier ?? "-",
            screenTodoId.map(String.init) ?? "-"
        ].joined(separator: "|")
    }

    enum CodingKeys: String, CodingKey {
        case reminderListID
        case legacyListName = "listName"
        case deviceId
        case titleKey
        case reminderIdentifier
        case screenTodoId
        case lastReminderFingerprint
        case lastScreenFingerprint
        case lastAppleModifiedAt
        case lastScreenModifiedAt
        case lastScreenCreatedAt
    }

    init(
        reminderListID: String,
        deviceId: String,
        titleKey: String,
        reminderIdentifier: String?,
        screenTodoId: Int?,
        lastReminderFingerprint: String?,
        lastScreenFingerprint: String?,
        lastAppleModifiedAt: Date?,
        lastScreenModifiedAt: Date?,
        lastScreenCreatedAt: Date?
    ) {
        self.reminderListID = reminderListID
        self.deviceId = deviceId
        self.titleKey = titleKey
        self.reminderIdentifier = reminderIdentifier
        self.screenTodoId = screenTodoId
        self.lastReminderFingerprint = lastReminderFingerprint
        self.lastScreenFingerprint = lastScreenFingerprint
        self.lastAppleModifiedAt = lastAppleModifiedAt
        self.lastScreenModifiedAt = lastScreenModifiedAt
        self.lastScreenCreatedAt = lastScreenCreatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reminderListID =
            try container.decodeIfPresent(String.self, forKey: .reminderListID) ??
            container.decodeIfPresent(String.self, forKey: .legacyListName) ??
            ""
        deviceId = try container.decode(String.self, forKey: .deviceId)
        titleKey = try container.decode(String.self, forKey: .titleKey)
        reminderIdentifier = try container.decodeIfPresent(String.self, forKey: .reminderIdentifier)
        screenTodoId = try container.decodeIfPresent(Int.self, forKey: .screenTodoId)
        lastReminderFingerprint = try container.decodeIfPresent(String.self, forKey: .lastReminderFingerprint)
        lastScreenFingerprint = try container.decodeIfPresent(String.self, forKey: .lastScreenFingerprint)
        lastAppleModifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastAppleModifiedAt)
        lastScreenModifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastScreenModifiedAt)
        lastScreenCreatedAt = try container.decodeIfPresent(Date.self, forKey: .lastScreenCreatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reminderListID, forKey: .reminderListID)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(titleKey, forKey: .titleKey)
        try container.encodeIfPresent(reminderIdentifier, forKey: .reminderIdentifier)
        try container.encodeIfPresent(screenTodoId, forKey: .screenTodoId)
        try container.encodeIfPresent(lastReminderFingerprint, forKey: .lastReminderFingerprint)
        try container.encodeIfPresent(lastScreenFingerprint, forKey: .lastScreenFingerprint)
        try container.encodeIfPresent(lastAppleModifiedAt, forKey: .lastAppleModifiedAt)
        try container.encodeIfPresent(lastScreenModifiedAt, forKey: .lastScreenModifiedAt)
        try container.encodeIfPresent(lastScreenCreatedAt, forKey: .lastScreenCreatedAt)
    }
}

struct SyncLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
}
