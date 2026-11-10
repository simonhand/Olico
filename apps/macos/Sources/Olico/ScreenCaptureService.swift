import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case windowUnavailable
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "没有屏幕录制权限"
        case .noDisplay:
            return "找不到可截图的显示器"
        case .windowUnavailable:
            return "找不到目标窗口"
        case .captureFailed(let message):
            return "抓取屏幕失败：\(message)"
        }
    }
}

struct CapturedFrame {
    let image: CGImage
    let screen: NSScreen
}

@MainActor
enum ScreenCaptureService {
    static func captureScreenUnderMouse() async throws -> CapturedFrame {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            throw ScreenCaptureError.noDisplay
        }
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw ScreenCaptureError.noDisplay
        }
        let displayID = CGDirectDisplayID(number.uint32Value)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first else {
            throw ScreenCaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        configuration.captureResolution = .best

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return CapturedFrame(image: image, screen: screen)
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
    }

    static func captureWindow(id: UInt32, scale: CGFloat) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw ScreenCaptureError.windowUnavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((window.frame.width * scale).rounded())
        configuration.height = Int((window.frame.height * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
    }
}
