import AppKit
import CryptoKit
import XCTest
@testable import SplitVPNNative

/// Export the actual macOS status renderer, rather than redraw it independently.
final class WindowsTrayIconExportTests: XCTestCase {
    @MainActor func testExportWindowsTrayIcons() throws {
        guard let path = ProcessInfo.processInfo.environment["SPLITVPN_WINDOWS_TRAY_EXPORT_DIR"] else {
            throw XCTSkip("Windows icon export was not requested.")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sizes = [16, 20, 24, 32, 40, 48, 64, 128]
        var files: [[String: Any]] = []
        for (theme, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            for personal in [false, true] {
                for company in [false, true] {
                    for badge in ["none", "progress", "error", "unknown"] {
                        let boat = StatusBarController.icon(for: .init(personal: personal ? .connected : .disconnected,
                            personalConnected: personal, companyConnected: company), appearance: appearance)
                        let image = withBadge(boat, badge: badge, appearance: appearance)
                        var frames: [Data] = []
                        for size in sizes {
                            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                bytesPerRow: 0, bitsPerPixel: 0))
                            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                            NSGraphicsContext.saveGraphicsState()
                            NSGraphicsContext.current = context
                            context.imageInterpolation = .high
                            let height = CGFloat(size) * 20 / 26
                            image.draw(in: NSRect(x: 0, y: (CGFloat(size) - height) / 2,
                                width: CGFloat(size), height: height))
                            NSGraphicsContext.restoreGraphicsState()
                            frames.append(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
                        }
                        var ico = Data()
                        ico.appendLE(UInt16(0)); ico.appendLE(UInt16(1)); ico.appendLE(UInt16(sizes.count))
                        var offset = 6 + 16 * sizes.count
                        for (size, frame) in zip(sizes, frames) {
                            ico.append(contentsOf: [UInt8(size), UInt8(size), 0, 0])
                            ico.appendLE(UInt16(1)); ico.appendLE(UInt16(32))
                            ico.appendLE(UInt32(frame.count)); ico.appendLE(UInt32(offset))
                            offset += frame.count
                        }
                        for frame in frames { ico.append(frame) }
                        let name = "\(theme)-\(personal ? "on" : "off")-\(company ? "on" : "off")-\(badge).ico"
                        try ico.write(to: directory.appendingPathComponent(name))
                        files.append(["file": name, "personalConnected": personal, "companyConnected": company,
                            "badge": badge, "theme": theme,
                            "sha256": SHA256.hash(data: ico).map { String(format: "%02x", $0) }.joined()])
                    }
                }
            }
        }
        XCTAssertEqual(files.count, 32)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/SplitVPNNative/Services/StatusBarController.swift")
        let rendererHash = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
        let manifest: [String: Any] = ["source": "StatusBarController.icon(for:appearance:)",
            "rendererSha256": rendererHash, "badges": "Generic vector punctuation", "sizes": sizes, "files": files]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("manifest.json"))
    }

    @MainActor private func withBadge(_ boat: NSImage, badge: String, appearance: NSAppearance) -> NSImage {
        guard badge != "none" else { return boat }
        var foreground = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance { foreground = foreground.usingColorSpace(.deviceRGB) ?? foreground }
        // Use simple punctuation paths on Windows; no platform symbol font is embedded.
        return NSImage(size: boat.size, flipped: false) { _ in
            boat.draw(in: NSRect(origin: .zero, size: boat.size))
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let frame = CGRect(x: 17, y: 0, width: 9, height: 9)
            context.setBlendMode(.clear); context.fillEllipse(in: frame.insetBy(dx: -0.8, dy: -0.8))
            context.setBlendMode(.normal); context.setFillColor(foreground.cgColor); context.fillEllipse(in: frame)
            context.setBlendMode(.destinationOut); NSColor.white.setFill(); NSColor.white.setStroke()
            func dot(_ x: CGFloat, _ y: CGFloat) { NSBezierPath(ovalIn: NSRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)).fill() }
            if badge == "progress" { for x in [CGFloat(19.2), 21.5, 23.8] { dot(x, 4.5) } }
            else if badge == "error" {
                NSBezierPath(roundedRect: NSRect(x: 21, y: 3.6, width: 1, height: 3.3), xRadius: 0.4, yRadius: 0.4).fill()
                dot(21.5, 2)
            } else {
                let question = NSBezierPath()
                question.move(to: NSPoint(x: 19.8, y: 6))
                question.curve(to: NSPoint(x: 23, y: 6), controlPoint1: NSPoint(x: 20.1, y: 7.5), controlPoint2: NSPoint(x: 23, y: 7.5))
                question.curve(to: NSPoint(x: 21.5, y: 3.8), controlPoint1: NSPoint(x: 23, y: 4.6), controlPoint2: NSPoint(x: 21.5, y: 4.9))
                question.line(to: NSPoint(x: 21.5, y: 3.5)); question.lineWidth = 1; question.lineCapStyle = .round; question.stroke()
                dot(21.5, 1.9)
            }
            context.setBlendMode(.normal)
            return true
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
