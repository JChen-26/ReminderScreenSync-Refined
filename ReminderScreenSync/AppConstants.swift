import Foundation

enum AppConstants {
    static let appName = "AI便利贴与苹果提醒事项同步中心"
    static let shortAppName = "AI便利贴同步"
    static let deviceName = "AI便利贴"
    static let openPlatformName = "极趣云平台"
    static let apiKeyLabel = "极趣云平台 API Key"
    static let defaultPollIntervalMinutes = 1
    static let defaultPollInterval: TimeInterval = TimeInterval(defaultPollIntervalMinutes * 60)
    static let maxLogEntries = 200
    static let zectrixBaseURL = URL(string: "https://cloud.zectrix.com/open/v1")!
}

extension String {
    var titleKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
