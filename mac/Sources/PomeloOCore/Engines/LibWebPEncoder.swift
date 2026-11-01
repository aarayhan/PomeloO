import CoreGraphics
import CWebP
import Foundation
import ImageIO

/// WebP written in-process with libwebp at quality 90 (the Windows setting). The picture is converted to
/// sRGB with straight alpha first, so wide-gamut photos keep their colours without an embedded profile.
/// Camera metadata (EXIF) is added afterwards with libwebpmux.
struct LibWebPEncoder: ImageEncoder {
    private static let quality: Float = 90
    /// The largest side WebP can hold.
    private static let maxSide = 16_383

    var formats: Set<ImageFormat> { [.webp] }

    func write(_ image: CGImage, as format: ImageFormat, metadata: [CFString: Any], to url: URL,
               progress: @escaping @Sendable (Double) -> Void, cancel: CancelFlag) throws {
        guard max(image.width, image.height) <= Self.maxSide else {
            throw ConversionError.failed("WebP images can be at most \(Self.maxSide) pixels on a side.")
        }
        var pixels = try Self.straightRGBA(image)
        let encoded = try encode(&pixels, width: image.width, height: image.height, progress: progress, cancel: cancel)
        let exif = ExifPayload.make(from: metadata)
        let data = exif.flatMap { Self.addingEXIF($0, to: encoded) } ?? encoded
        do { try data.write(to: url) } catch { throw ConversionError.cannotWrite(url.lastPathComponent) }
    }

    // MARK: pixels

    /// 8-bit sRGB, red-green-blue-alpha, alpha not multiplied into the colours (what libwebp wants).
    static func straightRGBA(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ConversionError.failed("Not enough memory to convert this image.") }
        data.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count {
                let a = Int(p[i + 3])
                if a != 0 && a != 255 {  // undo the multiplication Core Graphics did
                    p[i] = UInt8(min(255, (Int(p[i]) * 255 + a / 2) / a))
                    p[i + 1] = UInt8(min(255, (Int(p[i + 1]) * 255 + a / 2) / a))
                    p[i + 2] = UInt8(min(255, (Int(p[i + 2]) * 255 + a / 2) / a))
                }
                i += 4
            }
        }
        return data
    }

    // MARK: encoding

    /// Carries what the C callbacks need.
    private final class Hook {
        let progress: @Sendable (Double) -> Void
        let cancel: CancelFlag
        init(progress: @escaping @Sendable (Double) -> Void, cancel: CancelFlag) {
            self.progress = progress
            self.cancel = cancel
        }
    }

    private func encode(_ pixels: inout [UInt8], width: Int, height: Int,
                        progress: @escaping @Sendable (Double) -> Void, cancel: CancelFlag) throws -> Data {
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { throw ConversionError.failed("libwebp could not start.") }
        config.quality = Self.quality
        guard WebPValidateConfig(&config) != 0 else { throw ConversionError.failed("libwebp rejected its settings.") }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw ConversionError.failed("libwebp could not start.") }
        defer { WebPPictureFree(&picture) }
        picture.use_argb = 1
        picture.width = Int32(width)
        picture.height = Int32(height)
        let imported = pixels.withUnsafeBufferPointer { p in
            WebPPictureImportRGBA(&picture, p.baseAddress, Int32(width * 4))
        }
        guard imported != 0 else { throw ConversionError.failed("Not enough memory to convert this image.") }

        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        picture.writer = WebPMemoryWrite
        withUnsafeMutablePointer(to: &writer) { picture.custom_ptr = UnsafeMutableRawPointer($0) }

        let hook = Hook(progress: progress, cancel: cancel)
        picture.user_data = Unmanaged.passUnretained(hook).toOpaque()
        picture.progress_hook = { percent, picture in
            guard let raw = picture?.pointee.user_data else { return 1 }
            let hook = Unmanaged<Hook>.fromOpaque(raw).takeUnretainedValue()
            hook.progress(Double(percent) / 100)
            return hook.cancel.isCancelled ? 0 : 1  // 0 stops the encoder
        }

        let ok = withExtendedLifetime(hook) { WebPEncode(&config, &picture) }
        guard ok != 0 else {
            if picture.error_code == VP8_ENC_ERROR_USER_ABORT { throw CancellationError() }
            throw ConversionError.failed("libwebp could not encode this image (error \(picture.error_code.rawValue)).")
        }
        return Data(bytes: writer.mem, count: writer.size)
    }

    // MARK: metadata

    /// Adds an EXIF chunk with libwebpmux. If anything goes wrong the picture is kept without metadata:
    /// losing the camera data is better than failing the conversion.
    static func addingEXIF(_ exif: Data, to webp: Data) -> Data? {
        webp.withUnsafeBytes { webpBytes in
            exif.withUnsafeBytes { exifBytes in
                guard let webpBase = webpBytes.bindMemory(to: UInt8.self).baseAddress,
                      let exifBase = exifBytes.bindMemory(to: UInt8.self).baseAddress else { return nil }
                var input = WebPData(bytes: webpBase, size: webpBytes.count)
                guard let mux = WebPMuxCreate(&input, 1) else { return nil }
                defer { WebPMuxDelete(mux) }
                var chunk = WebPData(bytes: exifBase, size: exifBytes.count)
                guard WebPMuxSetChunk(mux, "EXIF", &chunk, 1) == WEBP_MUX_OK else { return nil }
                var assembled = WebPData()
                WebPDataInit(&assembled)
                defer { WebPDataClear(&assembled) }
                guard WebPMuxAssemble(mux, &assembled) == WEBP_MUX_OK, let bytes = assembled.bytes else { return nil }
                return Data(bytes: bytes, count: assembled.size)
            }
        }
    }
}

/// EXIF as a stand-alone block, made by the system's own writer so it is exactly what ImageIO would put
/// in a JPEG: a one-pixel JPEG is written with the metadata and its EXIF segment is cut out.
enum ExifPayload {
    static func make(from metadata: [CFString: Any]) -> Data? {
        guard !metadata.isEmpty else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let pixel = context.makeImage() else { return nil }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, pixel, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return exifSegment(inJPEG: jpeg as Data)
    }

    /// The bytes after `Exif\0\0` in the first APP1 segment, which is what a WebP EXIF chunk holds.
    static func exifSegment(inJPEG jpeg: Data) -> Data? {
        let bytes = [UInt8](jpeg)
        var i = 2  // after the start-of-image marker
        while i + 4 <= bytes.count, bytes[i] == 0xFF {
            let marker = bytes[i + 1]
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            guard length >= 2, i + 2 + length <= bytes.count else { return nil }
            if marker == 0xE1, length > 8, bytes[(i + 4)..<(i + 10)].elementsEqual([0x45, 0x78, 0x69, 0x66, 0, 0]) {
                return Data(bytes[(i + 10)..<(i + 2 + length)])
            }
            if marker == 0xDA { return nil }  // start of scan: no more headers
            i += 2 + length
        }
        return nil
    }
}
