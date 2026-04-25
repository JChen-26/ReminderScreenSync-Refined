import Foundation
import ServiceManagement

final class LaunchService {
    static let shared = LaunchService()

    private let service = SMAppService.mainApp

    var isEnabled: Bool {
        service.status == .enabled
    }

    var statusDescription: String {
        switch service.status {
        case .enabled:
            return "已启用"
        case .notFound:
            return "未注册"
        case .notRegistered:
            return "未启用"
        case .requiresApproval:
            return "需要系统批准"
        @unknown default:
            return "未知"
        }
    }

    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            return true
        } catch {
            print("Failed to update login item status: \(error)")
            return false
        }
    }
}
