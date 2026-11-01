import Foundation

/// WebP output. ImageIO can read WebP but not write it, so the picture is decoded by ImageIO (camera
/// orientation applied, transparency kept), handed to ffmpeg as a lossless PNG, and encoded there with
/// libwebp at quality 90, the setting of the Windows app.
///
/// Camera metadata (EXIF) is not carried over yet: [BELUM DIUJI] whether ffmpeg keeps it from the PNG.
public struct WebPEngine: ConversionEngine {
    public let name = "ImageIO + ffmpeg (libwebp)"
    private let executable: URL?

    public init(executable: URL? = FFmpegLocator.find()) {
        self.executable = executable
    }

    public func canConvert(from: String, to: String) -> Bool {
        guard to == "webp", from != "webp", let executable,
              ImageEngine.sources.contains(from), ImageFormat(rawValue: from)?.isReadable == true else { return false }
        return FFmpegEncoders.supports("webp", at: executable)
    }

    public func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let executable else { throw ConversionError.engineUnavailable("ffmpeg") }
        let intermediate = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomeloo-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: intermediate) }

        try await runBlocking { cancel in
            let (image, _) = try ImageEngine.read(job.source)
            try cancel.check()
            try ImageEngine.write(image, metadata: [:], as: .png, to: intermediate)
            progress(0.5)
        }
        try await FFmpegRunner(executable: executable).run(
            ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", intermediate.path,
             "-frames:v", "1", "-c:v", "libwebp", "-quality", "90", job.destination.path])
        progress(1)
    }
}
