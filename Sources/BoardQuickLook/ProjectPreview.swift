import Foundation
import ImageIO

func projectPreviewURL(_ project: URL) throws -> URL {
    let preview=project.appendingPathComponent("preview.png")
    guard let source=CGImageSourceCreateWithURL(preview as CFURL,nil),
          CGImageSourceGetCount(source) > 0 else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return preview
}
