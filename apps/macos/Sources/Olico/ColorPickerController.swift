import AppKit
import OlicoKit

@MainActor
final class ColorPickerController {
    private let logger: AppLogger
    private var overlay: ColorPickerOverlayController?
    private var isPicking = false
    private var isShowingPermissionAlert = false
    private var image: CGImage?
    private var imageFrame: CGRect = .zero
    private var format: ColorFormat = .hex

    init(logger: AppLogger) {
        self.logger = logger
    }

    func start(config: AppConfig) {
        guard !isPicking else { return }
        guard CGPreflightScreenCaptureAccess() else {
            requestPermission()
            return
        }
        isPicking = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let frame = try await ScreenCaptureService.captureScreenUnderMouse()
                self.present(frame: frame, format: config.screenshot.colorFormat)
            } catch ScreenCaptureError.permissionDenied {
                self.isPicking = false
                self.requestPermission()
            } catch {
                self.isPicking = false
                self.logger.log("color picker failed: \(error.localizedDescription)")
                self.showError(error.localizedDescription)
            }
        }
    }

    private func present(frame: CapturedFrame, format: ColorFormat) {
        image = frame.image
        imageFrame = CGRect(origin: .zero, size: frame.screen.frame.size)
        self.format = format

        let overlay = ColorPickerOverlayController(logger: logger)
        self.overlay = overlay
        overlay.present(
            image: frame.image,
            screen: frame.screen,
            format: format,
            onPick: { [weak self] point in
                self?.pick(at: point)
            },
            onCancel: { [weak self] in
                self?.logger.log("color picker cancelled")
                self?.finish()
            }
        )
    }

    private func pick(at point: CGPoint) {
        defer { finish() }
        guard let image,
              let result = ColorSampler.sample(image, viewPoint: point, imageFrame: imageFrame)
        else {
            ScreenshotHUD.shared.show(message: "取色失败")
            return
        }
        let text = ColorText.string(result.color, format: format)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            ScreenshotHUD.shared.show(message: "复制失败")
            return
        }
        logger.log("color picked \(text) pixel \(result.pixel.x),\(result.pixel.y)")
        ScreenshotHUD.shared.show(message: "已复制 \(text)")
    }

    private func finish() {
        overlay?.dismiss()
        overlay = nil
        image = nil
        isPicking = false
    }

    private func requestPermission() {
        guard !isShowingPermissionAlert else { return }
        logger.log("color picker: screen recording permission missing")
        if CGRequestScreenCaptureAccess() { return }
        isShowingPermissionAlert = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showPermissionAlert()
        }
    }

    private func showPermissionAlert() {
        defer { isShowingPermissionAlert = false }
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在“系统设置 › 隐私与安全性 › 屏幕录制”中允许 Olico，然后重新启动 Olico。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "取色失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
