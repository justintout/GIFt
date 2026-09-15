import AppKit
import Quartz

@MainActor
final class GIFPreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var previewURL: NSURL?

    func show(url: URL) {
        previewURL = url as NSURL
        NSApp.activate(ignoringOtherApps: true)

        guard let panel = QLPreviewPanel.shared() else {
            openWithQuickLook(url: url)
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL
    }

    /// Used when the shared panel is unavailable. Avoids NSWorkspace.open(url), which lets
    /// LaunchServices route GIFs to Preview.
    private func openWithQuickLook(url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            appLog.error("failed to open Quick Look preview: \(String(describing: error), privacy: .private)")
        }
    }
}
