import AppKit
import OlicoKit

enum ScreenshotError: LocalizedError {
    case emptySelection
    case encodeFailed
    case pasteboardFailed

    var errorDescription: String? {
        switch self {
        case .emptySelection: return "选区为空"
        case .encodeFailed: return "无法编码截图"
        case .pasteboardFailed: return "无法写入剪贴板"
        }
    }
}

@MainActor
final class ScreenshotController {
    private let logger: AppLogger
    private var overlay: ScreenshotOverlayController?
    private var isCapturing = false
    private var isShowingPermissionAlert = false

    init(logger: AppLogger) {
        self.logger = logger
    }

    func start(config: AppConfig) {
        guard !isCapturing else { return }
        guard CGPreflightScreenCaptureAccess() else {
            requestPermission()
            return
        }
        isCapturing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let frame = try await ScreenCaptureService.captureScreenUnderMouse()
                self.present(frame: frame, options: config.screenshot)
            } catch ScreenCaptureError.permissionDenied {
                self.isCapturing = false
                self.requestPermission()
            } catch {
                self.isCapturing = false
                self.logger.log("screenshot failed: \(error.localizedDescription)")
                self.showError(error.localizedDescription)
            }
        }
    }

    private func present(frame: CapturedFrame, options: ScreenshotOptions) {
        let controller = ScreenshotOverlayController()
        overlay = controller
        let scale = frame.screen.backingScaleFactor

        controller.present(
            image: frame.image,
            screen: frame.screen,
            onCopy: { [weak self] output in
                guard let self else { return }
                do {
                    let cropped = try self.crop(output)
                    try self.writeToPasteboard(cropped)
                    self.logger.log("screenshot copied \(cropped.width)x\(cropped.height)")
                    self.finish()
                    ScreenshotHUD.shared.show(message: "已复制到剪贴板")
                } catch {
                    self.finish()
                    ScreenshotHUD.shared.show(message: "复制失败：\(error.localizedDescription)")
                }
            },
            onSave: { [weak self] output in
                guard let self else { return }
                let cropped: CGImage
                do {
                    cropped = try self.crop(output)
                    try self.writeToPasteboard(cropped)
                } catch {
                    self.finish()
                    ScreenshotHUD.shared.show(message: "复制失败：\(error.localizedDescription)")
                    return
                }
                do {
                    let url = try ScreenshotFileWriter.save(cropped, directory: options.saveDir)
                    self.logger.log("screenshot saved")
                    self.finish()
                    ScreenshotHUD.shared.show(
                        message: "已保存 \(url.lastPathComponent)",
                        revealURL: url
                    )
                } catch {
                    self.logger.log("screenshot save failed: \(error.localizedDescription)")
                    self.finish()
                    ScreenshotHUD.shared.show(
                        message: "已复制，保存失败：\(error.localizedDescription)"
                    )
                }
            },
            onCancel: { [weak self] in
                self?.logger.log("screenshot cancelled")
                self?.finish()
            },
            onWindowPick: { [weak self] candidate, rect in
                guard let self else { return }
                self.logger.log("screenshot: pick window #\(candidate.id) \(candidate.title ?? "")")
                Task { @MainActor in
                    do {
                        let image = try await ScreenCaptureService.captureWindow(
                            id: candidate.id,
                            scale: scale
                        )
                        self.overlay?.applyWindowCapture(image, rect: rect)
                        self.logger.log("screenshot: window captured \(image.width)x\(image.height)")
                    } catch {
                        self.logger.log("screenshot window capture failed: \(error.localizedDescription)")
                        self.overlay?.cancelWindowCapture()
                    }
                }
            }
        )
    }

    private func crop(_ output: ScreenshotOutput) throws -> CGImage {
        let source = AnnotationRenderer.render(
            output.image,
            imageFrame: output.imageFrame,
            annotations: output.annotations
        )
        guard let pixelRect = ScreenshotGeometry.pixelCropRect(
            for: output.selection,
            in: output.imageFrame,
            imageSize: CGSize(width: source.width, height: source.height)
        ) else {
            throw ScreenshotError.emptySelection
        }
        guard let cropped = source.cropping(to: pixelRect) else {
            throw ScreenshotError.emptySelection
        }
        return cropped
    }

    private func writeToPasteboard(_ image: CGImage) throws {
        guard let png = ScreenshotFileWriter.pngData(image) else {
            throw ScreenshotError.encodeFailed
        }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = ScreenshotFileWriter.tiffData(image) {
            item.setData(tiff, forType: .tiff)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw ScreenshotError.pasteboardFailed
        }
    }

    private func finish() {
        overlay?.dismiss()
        overlay = nil
        isCapturing = false
    }

    private func requestPermission() {
        guard !isShowingPermissionAlert else { return }
        logger.log("screenshot: screen recording permission missing")
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
        alert.messageText = "截图失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
