import Foundation
import IOKit.hid

enum IOHIDListenAccessError: LocalizedError {
    case denied
    case permissionRequired

    var errorDescription: String? {
        switch self {
        case .denied:
            "输入监控权限已被拒绝。请到「系统设置 → 隐私权与安全性 → 输入监控」允許 VibeKey Lite。"
        case .permissionRequired:
            "已要求输入监控权限。允許 VibeKey Lite 后，请按「套用并重启」。"
        }
    }
}

enum IOHIDListenAccess {
    static var isGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func ensure(promptForPermission: Bool) throws {
        let requestType = kIOHIDRequestTypeListenEvent
        switch IOHIDCheckAccess(requestType) {
        case kIOHIDAccessTypeGranted:
            return
        case kIOHIDAccessTypeDenied:
            throw IOHIDListenAccessError.denied
        case kIOHIDAccessTypeUnknown:
            guard promptForPermission,
                  IOHIDRequestAccess(requestType),
                  IOHIDCheckAccess(requestType) == kIOHIDAccessTypeGranted else {
                throw IOHIDListenAccessError.permissionRequired
            }
        default:
            throw IOHIDListenAccessError.permissionRequired
        }
    }
}
