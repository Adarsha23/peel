import Foundation
#if canImport(Vision)
import Vision
#endif

/// On-device text extraction for image attachments. Each image gets a sidecar at
/// attachments/<id>/.ocr/<name>.txt (hidden, so the strip never shows it) that
/// search and Claude Code can read. No network, ever.
public enum OCR {
    public static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "heic", "tiff", "gif", "webp", "bmp"]

    public static func sidecarURL(for image: URL) -> URL {
        image.deletingLastPathComponent()
            .appendingPathComponent(".ocr")
            .appendingPathComponent(image.lastPathComponent + ".txt")
    }

    /// Recognize text and write the sidecar; skips work if one already exists.
    /// An empty sidecar is still written so failed/blank images aren't rescanned.
    public static func index(_ image: URL) {
        #if canImport(Vision)
        guard imageExtensions.contains(image.pathExtension.lowercased()) else { return }
        let sidecar = sidecarURL(for: image)
        guard !FileManager.default.fileExists(atPath: sidecar.path) else { return }
        DispatchQueue.global(qos: .utility).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(url: image).perform([request])
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            try? FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? text.write(to: sidecar, atomically: true, encoding: .utf8)
        }
        #endif
    }

    public static func text(for image: URL) -> String? {
        try? String(contentsOf: sidecarURL(for: image), encoding: .utf8)
    }
}
