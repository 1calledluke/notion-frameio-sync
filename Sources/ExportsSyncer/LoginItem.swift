import Foundation
import ServiceManagement

enum LoginItem {
    static func enable() {
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        }
    }

    static func disable() {
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.unregister()
        }
    }
}
