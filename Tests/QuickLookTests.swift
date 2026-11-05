import XCTest
import QuickLookUI
@testable import Board
@testable import BoardQuickLook

final class QuickLookTests: XCTestCase {
    func testSavedProjectProvidesPreviewWithoutLoadingLayers() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let project=folder.appendingPathComponent("预览.sboard")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try ProjectFile.save(BoardModel().state,to:project)
        try FileManager.default.removeItem(at:project.appendingPathComponent("layers"))
        let url=try projectPreviewURL(project)
        XCTAssertEqual(url.lastPathComponent,"preview.png")
        XCTAssertNotNil(QLPreviewReply(fileURL:url))
        try Data("broken image".utf8).write(to:url)
        XCTAssertThrowsError(try projectPreviewURL(project))
        try FileManager.default.removeItem(at:url)
        XCTAssertThrowsError(try projectPreviewURL(project))
    }
    func testExtensionDeclarationsMatchDocumentType() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        for (kind,point,principal) in [("Preview","preview","BoardPreviewProvider")] {
            let data=try Data(contentsOf:root.appendingPathComponent("Resources/QuickLook/\(kind).plist"))
            let plist=try XCTUnwrap(PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any])
            let ext=try XCTUnwrap(plist["NSExtension"] as? [String:Any])
            let attributes=try XCTUnwrap(ext["NSExtensionAttributes"] as? [String:Any])
            XCTAssertEqual(ext["NSExtensionPointIdentifier"] as? String,"com.apple.quicklook.\(point)")
            XCTAssertEqual(ext["NSExtensionPrincipalClass"] as? String,principal)
            XCTAssertEqual(attributes["QLSupportedContentTypes"] as? [String],["com.vinasky.simpleboard.project"])
            XCTAssertNotNil(NSClassFromString(principal))
            if kind == "Preview" { XCTAssertEqual(attributes["QLIsDataBasedPreview"] as? Bool,true) }
        }
    }
}
