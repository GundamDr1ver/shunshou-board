import AppKit

struct TileKey: Hashable { let x: Int; let y: Int }

final class RasterSource {
    let url: URL
    private let owner: AnyObject?
    private let lock = NSLock()
    private var stored: CGImage?
    init(url: URL, owner: AnyObject? = nil) { self.url = url; self.owner = owner }
    func image() throws -> CGImage {
        lock.lock(); defer { lock.unlock() }
        if let stored { return stored }
        let image = try readImage(url); stored = image; return image
    }
}

struct Raster {
    static let tileSize = 256
    var tiles: [TileKey: CGImage] = [:]
    var source: RasterSource?
    var sourceSize: CGSize = .zero

    static func keys(in rect: CGRect) -> [TileKey] {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return [] }
        let n = CGFloat(tileSize)
        let x0 = Int(floor(rect.minX/n)), x1 = Int(ceil(rect.maxX/n))-1
        let y0 = Int(floor(rect.minY/n)), y1 = Int(ceil(rect.maxY/n))-1
        return (y0...y1).flatMap { y in (x0...x1).map { TileKey(x:$0,y:y) } }
    }
    static func rect(_ key: TileKey) -> CGRect { CGRect(x:key.x*tileSize,y:key.y*tileSize,width:tileSize,height:tileSize) }

    func tile(_ key: TileKey) throws -> CGImage? {
        if let image = tiles[key] { return image }
        guard let source else { return nil }
        let rect = Self.rect(key), clipped = rect.intersection(CGRect(origin:.zero,size:sourceSize))
        guard !clipped.isNull else { return nil }
        let image = try source.image()
        // Core Graphics cropping uses image coordinates, independent of the view transform.
        guard let crop = image.cropping(to: clipped) else { return nil }
        if clipped.size == rect.size { return crop }
        let c = try bitmapContext(Self.tileSize,Self.tileSize)
        drawImage(crop,in:CGRect(x:clipped.minX-rect.minX,y:clipped.minY-rect.minY,width:clipped.width,height:clipped.height),on:c)
        return c.makeImage()
    }

    func draw(on c: CGContext, in rect: CGRect) throws {
        for key in Self.keys(in:rect) { if let image = try tile(key) { drawImage(image,in:Self.rect(key),on:c) } }
    }

    mutating func edit(in rect: CGRect, canvas: CGSize, _ body: (CGContext) -> Void) throws {
        let affected = rect.intersection(CGRect(origin:.zero,size:canvas)).integral
        for key in Self.keys(in:affected) {
            let tileRect = Self.rect(key)
            let c = try bitmapContext(Self.tileSize,Self.tileSize)
            if let old = try tile(key) { drawImage(old,in:CGRect(x:0,y:0,width:Self.tileSize,height:Self.tileSize),on:c) }
            c.translateBy(x:-tileRect.minX,y:-tileRect.minY)
            c.clip(to:CGRect(origin:.zero,size:canvas))
            body(c)
            guard let image = c.makeImage() else { throw BoardError.invalid("无法生成图层块。") }
            tiles[key]=image
        }
    }

    func image(size: CGSize) throws -> CGImage {
        let c = try bitmapContext(Int(size.width),Int(size.height))
        try draw(on:c,in:CGRect(origin:.zero,size:size))
        guard let image=c.makeImage() else { throw BoardError.invalid("无法生成图层图片。") }
        return image
    }

    func cropped(to rect: CGRect, oldSize: CGSize) throws -> Raster {
        var result = Raster()
        for key in Self.keys(in:CGRect(origin:.zero,size:rect.size)) {
            let target = Self.rect(key)
            let sourceRect = target.offsetBy(dx:rect.minX,dy:rect.minY).intersection(rect)
            let hasContent = Self.keys(in:sourceRect).contains { tiles[$0] != nil } || (source != nil && sourceRect.intersects(CGRect(origin:.zero,size:sourceSize)))
            guard hasContent else { continue }
            let c = try bitmapContext(Self.tileSize,Self.tileSize)
            c.translateBy(x:-target.minX-rect.minX,y:-target.minY-rect.minY)
            c.clip(to:rect)
            try draw(on:c,in:sourceRect)
            result.tiles[key]=c.makeImage()
        }
        return result
    }
}

private final class CachedTile: NSObject { let image: CGImage?; init(_ image: CGImage?) { self.image=image } }
private final class LayerTileCache {
    let images=NSCache<NSString,CachedTile>()
    init() { images.totalCostLimit=8*1024*1024 }
}

struct Layer {
    var id = UUID()
    var revision = UUID()
    var contentRevision = UUID()
    var name: String
    var visible = true
    var locked = false
    var opacity: Double = 1
    var background = RGBA.clear
    var backgroundHoles: [CGRect] = []
    var raster = Raster()
    private var cache = LayerTileCache()
    init(name: String) { self.name=name }
    mutating func touch(pixels: Bool = false) { revision=UUID(); if pixels { contentRevision=UUID() } }

    func drawBackground(on c: CGContext, size: CGSize) {
        guard background.a > 0 else { return }
        c.saveGState()
        let canvas=CGRect(origin:.zero,size:size)
        for hole in backgroundHoles {
            c.beginPath(); c.addRect(canvas); c.addRect(hole); c.clip(using:.evenOdd)
        }
        c.setFillColor(background.cg); c.fill(canvas); c.restoreGState()
    }
    func draw(on c: CGContext, size: CGSize, region: CGRect, pending: EditableObject? = nil) throws {
        c.saveGState(); defer { c.restoreGState() }
        c.clip(to:region.intersection(CGRect(origin:.zero,size:size)))
        c.setAlpha(opacity)
        if pending != nil { c.beginTransparencyLayer(auxiliaryInfo:nil) }
        if let pending, pending.tool == .eraser {
            drawBackground(on:c,size:size)
            c.beginTransparencyLayer(auxiliaryInfo:nil)
            try raster.draw(on:c,in:region); pending.draw(on:c); c.endTransparencyLayer()
        } else {
            for key in Raster.keys(in:region.intersection(CGRect(origin:.zero,size:size))) {
                let rect=Raster.rect(key)
                if background.a == 0 { if let image=try raster.tile(key) { drawImage(image,in:rect,on:c) }; continue }
                let cacheKey="\(revision)-\(size.width)-\(size.height)-\(key.x)-\(key.y)" as NSString
                let image: CGImage?
                if let stored=cache.images.object(forKey:cacheKey) { image=stored.image }
                else {
                    let tileContext=try bitmapContext(Raster.tileSize,Raster.tileSize)
                    tileContext.translateBy(x:-rect.minX,y:-rect.minY); tileContext.clip(to:CGRect(origin:.zero,size:size))
                    drawBackground(on:tileContext,size:size)
                    if let tile=try raster.tile(key) { drawImage(tile,in:rect,on:tileContext) }
                    image=tileContext.makeImage(); cache.images.setObject(CachedTile(image),forKey:cacheKey,cost:Raster.tileSize*Raster.tileSize*4)
                }
                if let image { drawImage(image,in:rect,on:c) }
            }
            pending?.draw(on:c)
        }
        if pending != nil { c.endTransparencyLayer() }
    }
}

struct BoardState {
    var size = CGSize(width:1280,height:800)
    var layers = [Layer(name:"图层 1")]
    var activeID: UUID
    init() { activeID=layers[0].id }
    var activeIndex: Int { layers.firstIndex { $0.id == activeID } ?? 0 }
    var rect: CGRect { CGRect(origin:.zero,size:size) }

    func draw(on c: CGContext, region: CGRect, only id: UUID? = nil, pending: EditableObject? = nil) throws {
        c.saveGState(); defer { c.restoreGState() }
        c.clip(to:rect)
        for layer in layers where id == nil ? layer.visible : layer.id == id {
            try layer.draw(on:c,size:size,region:region,pending:pending?.layerID == layer.id ? pending : nil)
        }
    }
    func composite(region: CGRect? = nil, only id: UUID? = nil, pending: EditableObject? = nil, white: Bool = false) throws -> CGImage {
        let r=(region ?? rect).intersection(rect).integral
        guard r.width > 0 && r.height > 0 else { throw BoardError.invalid("选区为空。") }
        let c=try bitmapContext(Int(r.width),Int(r.height))
        if white { c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(origin:.zero,size:r.size)) }
        c.translateBy(x:-r.minX,y:-r.minY)
        try draw(on:c,region:r,only:id,pending:pending)
        guard let image=c.makeImage() else { throw BoardError.invalid("无法合成图片。") }
        return image
    }
}

struct HistoryEntry { let name: String; let state: BoardState; var pending: EditableObject? = nil; var objectOnly=false }

final class BoardModel {
    var state = BoardState()
    var pending: EditableObject?
    var selection: CGRect?
    private(set) var undoStack: [HistoryEntry] = []
    private(set) var redoStack: [HistoryEntry] = []
    var changed: ((CGRect?) -> Void)?
    var dirty = false

    func notify(_ region: CGRect? = nil) { changed?(region) }
    func startObject(_ object: EditableObject) { pending=object; redoStack=[]; notify() }
    func transaction(_ name: String, _ body: (inout BoardState) throws -> Void) throws {
        let before=state
        do { try body(&state) } catch { state=before; throw error }
        undoStack.append(HistoryEntry(name:name,state:before)); redoStack.removeAll()
        dirty=true; notify()
    }
    func editable(_ id: UUID? = nil) throws -> Int {
        let index=state.layers.firstIndex { $0.id == (id ?? state.activeID) } ?? state.activeIndex
        guard !state.layers[index].locked else { throw BoardError.invalid("目标图层已锁定，请先解锁。") }
        guard state.layers[index].visible else { throw BoardError.invalid("目标图层已隐藏，请先显示。") }
        return index
    }
    func bake() throws {
        guard let object=pending else { return }
        let index=try editable(object.layerID)
        pending=nil
        do {
            try transaction("烘焙") { s in
                try s.layers[index].raster.edit(in:object.bounds,canvas:s.size) { object.draw(on:$0) }
                s.layers[index].touch(pixels:true)
            }
        } catch { pending=object; throw error }
        notify(object.bounds)
    }
    func cancel() { let old=pending?.bounds; pending=nil; selection=nil; notify(old) }
    func undo() {
        if let pending, undoStack.last?.pending == nil {
            redoStack.append(HistoryEntry(name:"新增对象",state:state,pending:pending,objectOnly:true))
            cancel(); return
        }
        guard let entry=undoStack.popLast() else { return }
        redoStack.append(HistoryEntry(name:entry.name,state:state,pending:pending)); state=entry.state; pending=entry.pending; selection=nil; dirty=true; notify()
    }
    func redo() {
        guard let entry=redoStack.popLast() else { return }
        if !entry.objectOnly { undoStack.append(HistoryEntry(name:entry.name,state:state,pending:pending)) }
        state=entry.state; pending=entry.pending; selection=nil; dirty=true; notify()
    }
    func selectLayer(_ id: UUID) throws { try bake(); state.activeID=id; notify() }
    func addLayer() throws {
        try bake()
        try transaction("新建图层") { s in let layer=Layer(name:"图层 \(s.layers.count+1)"); s.layers.append(layer); s.activeID=layer.id }
    }
    func deleteLayer() throws { try deleteLayers([state.activeID]) }
    func deleteLayers(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        guard state.layers.filter({ids.contains($0.id)}).allSatisfy({!$0.locked}) else { throw BoardError.invalid("请先解锁要删除的图层。") }
        try bake(); let i=state.activeIndex
        try transaction("删除图层") { s in
            let kept=s.layers.filter { !ids.contains($0.id) }
            if kept.isEmpty {
                var layer=s.layers[i]; layer.raster=Raster(); layer.background = .clear; layer.backgroundHoles=[]; layer.touch(pixels:true)
                s.layers=[layer]; s.activeID=layer.id
            } else { s.layers=kept; if !kept.contains(where:{$0.id == s.activeID}) { s.activeID=kept[min(i,kept.count-1)].id } }
        }
    }
    func duplicateLayer() throws {
        try bake(); let i=state.activeIndex
        try transaction("复制图层") { s in var layer=s.layers[i]; layer.id=UUID(); layer.revision=UUID(); layer.name += " 副本"; s.layers.insert(layer,at:i+1); s.activeID=layer.id }
    }
    func reorderLayers(_ ids: Set<UUID>, toDisplayRow row: Int) throws {
        let display=Array(state.layers.reversed()), destination=min(max(0,row),display.count)
        let moving=display.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        var remaining=display.filter { !ids.contains($0.id) }
        let index=destination-display.prefix(destination).filter { ids.contains($0.id) }.count
        remaining.insert(contentsOf:moving,at:index)
        let reordered=Array(remaining.reversed())
        guard reordered.map(\.id) != state.layers.map(\.id) else { return }
        let order=reordered.map(\.id)
        try bake(); try transaction("图层排序") { s in
            let byID=Dictionary(uniqueKeysWithValues:s.layers.map { ($0.id,$0) })
            s.layers=order.compactMap { byID[$0] }
        }
    }
    func mergeDown() throws {
        try bake(); let i=try editable()
        guard i > 0 else { return }
        _=try editable(state.layers[i-1].id)
        let top=state.layers[i], bottom=state.layers[i-1]
        guard top.visible && bottom.visible else { throw BoardError.invalid("请先显示要合并的两层。") }
        try transaction("合并图层") { s in
            var raster=Raster()
            let needed=top.background.a > 0 || bottom.background.a > 0 || top.raster.source != nil || bottom.raster.source != nil
                ? Raster.keys(in:s.rect) : Array(Set(top.raster.tiles.keys).union(bottom.raster.tiles.keys))
            for key in needed {
                let r=Raster.rect(key), c=try bitmapContext(Raster.tileSize,Raster.tileSize)
                c.translateBy(x:-r.minX,y:-r.minY); c.clip(to:s.rect)
                try bottom.draw(on:c,size:s.size,region:r); try top.draw(on:c,size:s.size,region:r)
                raster.tiles[key]=c.makeImage()
            }
            s.layers[i-1].raster=raster; s.layers[i-1].opacity=1; s.layers[i-1].background = .clear; s.layers[i-1].backgroundHoles=[]; s.layers[i-1].touch(pixels:true)
            s.layers.remove(at:i); s.activeID=s.layers[i-1].id
        }
    }
    func resize(_ size: CGSize) throws {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else { return }
        let target=CGSize(width:ceil(size.width),height:ceil(size.height))
        guard target != state.size else { return }
        try bake()
        try transaction("画布尺寸") { s in
            if target.width < s.size.width || target.height < s.size.height {
                let kept=CGRect(origin:.zero,size:CGSize(width:min(target.width,s.size.width),height:min(target.height,s.size.height)))
                for i in s.layers.indices {
                    s.layers[i].raster=try s.layers[i].raster.cropped(to:kept,oldSize:s.size)
                    s.layers[i].backgroundHoles=s.layers[i].backgroundHoles.compactMap { let r=$0.intersection(kept); return r.isNull ? nil:r }
                    s.layers[i].touch(pixels:true)
                }
            }
            s.size=target
        }
    }
    func crop() throws {
        guard let region=selection?.intersection(state.rect).integral, region.width > 0, region.height > 0 else { return }
        try bake()
        try transaction("裁剪画布") { s in
            for i in s.layers.indices {
                s.layers[i].raster=try s.layers[i].raster.cropped(to:region,oldSize:s.size)
                s.layers[i].backgroundHoles=s.layers[i].backgroundHoles.compactMap { r in let cut=r.intersection(region); return cut.isNull ? nil : cut.offsetBy(dx:-region.minX,dy:-region.minY) }
                s.layers[i].touch(pixels:true)
            }
            s.size=region.size
        }
        selection=nil; notify()
    }
    func copyImage(currentOnly: Bool) throws -> CGImage {
        try state.composite(region:selection ?? pending?.bounds.intersection(state.rect),only:currentOnly ? state.activeID : nil,pending:pending)
    }
    func cut(currentOnly: Bool) throws -> CGImage {
        let region=(selection ?? pending?.bounds ?? state.rect).intersection(state.rect).integral
        let image=try state.composite(region:region,only:currentOnly ? state.activeID : nil,pending:pending)
        let affected=state.layers.indices.filter { currentOnly ? state.layers[$0].id == state.activeID : state.layers[$0].visible }
        guard affected.allSatisfy({ !state.layers[$0].locked }) else { throw BoardError.invalid("剪切涉及锁定图层；请先解锁，或使用仅当前层剪切。") }
        let activeObject=pending
        try transaction("剪切") { s in
            for i in affected {
                try s.layers[i].raster.edit(in:region,canvas:s.size) { $0.clear(region) }
                s.layers[i].backgroundHoles.append(region); s.layers[i].touch(pixels:true)
            }
        }
        undoStack[undoStack.count-1].pending=activeObject
        // Keep cutouts on the editable object so cutting does not turn text or geometry into a bitmap.
        if var object=pending, affected.contains(where:{state.layers[$0].id == object.layerID}) {
            let hole=region.intersection(object.bounds)
            if !hole.isNull { object.cutouts.append(hole) }; pending=object
        }
        notify(); return image
    }
    func pixel(at point: CGPoint, color: RGBA, continuing: Bool, erase: Bool = false) throws {
        let rect=CGRect(x:floor(point.x),y:floor(point.y),width:1,height:1)
        guard state.rect.contains(rect) else { return }
        if !continuing { try bake() }
        let i=try editable(), before=state
        do {
            try state.layers[i].raster.edit(in:rect,canvas:state.size) { c in
                c.setShouldAntialias(false)
                if erase { c.clear(rect) }
                else { c.setBlendMode(.copy); c.setFillColor(color.cg); c.fill(rect) }
            }
        } catch { state=before; throw error }
        if !continuing { undoStack.append(HistoryEntry(name:"像素编辑",state:before)); redoStack=[] }
        state.layers[i].touch(pixels:true); dirty=true; notify(rect)
    }
    func reset(to value: BoardState = BoardState()) { state=value; pending=nil; selection=nil; undoStack=[]; redoStack=[]; dirty=false; notify() }
}
