import AppKit
import ImageIO
import UniformTypeIdentifiers

extension UTType {
    static let simpleBoard = UTType(exportedAs:"com.vinasky.simpleboard.project",conformingTo:.package)
}

private final class SourceFiles {
    let directory: URL
    init() throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("SimpleBoard-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    deinit { try? FileManager.default.removeItem(at:directory) }
}

struct LayerRecord: Codable {
    let id: UUID
    let revision: UUID
    let contentRevision: UUID
    let name: String
    let visible: Bool
    let locked: Bool
    let opacity: Double
    let background: RGBA
    let backgroundHoles: [CGRect]
    let file: String
}
struct Manifest: Codable {
    let version: Int
    let width: Int
    let height: Int
    let activeID: UUID
    let layers: [LayerRecord]
}

enum ProjectFile {
    static func load(_ url: URL) throws -> BoardState {
        let layerURL=url.appendingPathComponent("layers",isDirectory:true)
        let layerDirectory=try layerURL.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard layerDirectory.isDirectory == true, layerDirectory.isSymbolicLink != true else { throw BoardError.invalid("工程的图层目录无效。") }
        let manifest=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:layerURL.appendingPathComponent("manifest.json")))
        guard manifest.version == 1 else { throw BoardError.invalid("不支持此工程版本，请使用兼容版本打开。") }
        guard manifest.width > 0, manifest.height > 0, !manifest.layers.isEmpty,
              Set(manifest.layers.map(\.id)).count == manifest.layers.count,
              manifest.layers.contains(where:{$0.id == manifest.activeID}) else { throw BoardError.invalid("工程尺寸或图层清单无效。") }
        let sourceFiles=try SourceFiles()
        var state=BoardState(); state.size=CGSize(width:manifest.width,height:manifest.height); state.activeID=manifest.activeID
        state.layers=try manifest.layers.enumerated().map { index,r in
            guard r.file == "\(index).png", r.opacity.isFinite, (0...1).contains(r.opacity),
                  [r.background.r,r.background.g,r.background.b,r.background.a].allSatisfy({$0.isFinite && (0...1).contains($0)}),
                  r.backgroundHoles.allSatisfy({!$0.isNull && $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width >= 0 && $0.height >= 0}) else { throw BoardError.invalid("工程图层属性无效。") }
            let original=layerURL.appendingPathComponent(r.file), local=sourceFiles.directory.appendingPathComponent(r.file)
            let properties=try original.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw BoardError.invalid("工程图层文件无效。") }
            do { try FileManager.default.linkItem(at:original,to:local) }
            catch { try FileManager.default.copyItem(at:original,to:local) }
            let source=RasterSource(url:local,owner:sourceFiles)
            // Read image headers now; pixel decoding remains lazy until the layer is drawn.
            guard let imageSource=CGImageSourceCreateWithURL(local as CFURL,nil), let p=CGImageSourceCopyPropertiesAtIndex(imageSource,0,nil) as? [CFString:Any],
                  let width=p[kCGImagePropertyPixelWidth] as? Int, let height=p[kCGImagePropertyPixelHeight] as? Int,
                  width == manifest.width, height == manifest.height else { throw BoardError.invalid("图层图片尺寸与画布不符。") }
            var layer=Layer(name:r.name); layer.id=r.id; layer.revision=r.revision; layer.contentRevision=r.contentRevision; layer.visible=r.visible; layer.locked=r.locked
            layer.opacity=r.opacity; layer.background=r.background; layer.backgroundHoles=r.backgroundHoles
            layer.raster.source=source; layer.raster.sourceSize=state.size
            return layer
        }
        return state
    }

    static func save(_ state: BoardState, to url: URL) throws {
        let fm=FileManager.default, parent=url.deletingLastPathComponent()
        let staging=parent.appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:staging.appendingPathComponent("layers"),withIntermediateDirectories:true)
        defer { if fm.fileExists(atPath:staging.path) { try? fm.removeItem(at:staging) } }
        let previous=try? JSONDecoder().decode(Manifest.self,from:Data(contentsOf:url.appendingPathComponent("layers/manifest.json")))
        var records: [LayerRecord]=[]
        for (index,layer) in state.layers.enumerated() {
            let file="\(index).png", output=staging.appendingPathComponent("layers/\(file)")
            if let old=previous?.layers.enumerated().first(where:{$0.element.id == layer.id && $0.element.contentRevision == layer.contentRevision && $0.element.file == "\($0.offset).png"})?.element, previous?.width == Int(state.size.width), previous?.height == Int(state.size.height) {
                let input=url.appendingPathComponent("layers/\(old.file)")
                do { try fm.linkItem(at:input,to:output) } catch { try fm.copyItem(at:input,to:output) }
            } else {
                try autoreleasepool { try imageData(layer.raster.image(size:state.size)).write(to:output,options:.atomic) }
            }
            records.append(LayerRecord(id:layer.id,revision:layer.revision,contentRevision:layer.contentRevision,name:layer.name,visible:layer.visible,locked:layer.locked,opacity:layer.opacity,background:layer.background,backgroundHoles:layer.backgroundHoles,file:file))
        }
        let manifest=Manifest(version:1,width:Int(state.size.width),height:Int(state.size.height),activeID:state.activeID,layers:records)
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(manifest).write(to:staging.appendingPathComponent("layers/manifest.json"),options:.atomic)
        let info: [String:Any] = ["FormatVersion":1,"Width":Int(state.size.width),"Height":Int(state.size.height),"UTI":UTType.simpleBoard.identifier]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:staging.appendingPathComponent("Info.plist"),options:.atomic)
        let scale=min(1,512/max(state.size.width,state.size.height))
        let preview=try bitmapContext(max(1,Int(state.size.width*scale)),max(1,Int(state.size.height*scale)))
        preview.scaleBy(x:scale,y:scale); try state.draw(on:preview,region:state.rect)
        guard let image=preview.makeImage() else { throw BoardError.invalid("无法生成工程预览。") }
        try imageData(image).write(to:staging.appendingPathComponent("preview.png"),options:.atomic)
        if fm.fileExists(atPath:url.path) { _=try fm.replaceItemAt(url,withItemAt:staging) }
        else { try fm.moveItem(at:staging,to:url) }
    }
}
