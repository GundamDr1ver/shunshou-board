import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Board

final class BoardTests: XCTestCase {
    let red=RGBA(r:1,g:0,b:0,a:1), blue=RGBA(r:0,g:0,b:1,a:1)
    func object(_ model: BoardModel, rect: CGRect, color: RGBA? = nil) -> EditableObject {
        EditableObject(tool:.rectangle,frame:rect,color:color ?? red,lineWidth:0,filled:true,layerID:model.state.activeID)
    }
    func sample(_ image: CGImage, x: Int, y: Int) -> NSColor {
        // Sample in an explicit sRGB bitmap: NSBitmapImageRep.colorAt returns calibrated colors on macOS 27.
        let c=try! bitmapContext(1,1)
        drawImage(image.cropping(to:CGRect(x:x,y:y,width:1,height:1))!,in:CGRect(x:0,y:0,width:1,height:1),on:c)
        let bytes=c.data!.assumingMemoryBound(to:UInt8.self), a=CGFloat(bytes[3])/255
        return NSColor(srgbRed:a > 0 ? CGFloat(bytes[0])/255/a:0,green:a > 0 ? CGFloat(bytes[1])/255/a:0,blue:a > 0 ? CGFloat(bytes[2])/255/a:0,alpha:a)
    }
    func assertColor(_ image: CGImage,_ point: CGPoint,_ expected: RGBA,file: StaticString=#filePath,line: UInt=#line) {
        let actual=sample(image,x:Int(point.x),y:Int(point.y))
        XCTAssertEqual(actual.redComponent,expected.r,accuracy:0.025,file:file,line:line)
        XCTAssertEqual(actual.greenComponent,expected.g,accuracy:0.025,file:file,line:line)
        XCTAssertEqual(actual.blueComponent,expected.b,accuracy:0.025,file:file,line:line)
        XCTAssertEqual(actual.alphaComponent,expected.a,accuracy:0.025,file:file,line:line)
    }
    func testSparseBakeAndUndo() throws {
        let m=BoardModel(); m.pending=object(m,rect:CGRect(x:270,y:270,width:30,height:30)); try m.bake()
        XCTAssertNil(m.pending); XCTAssertEqual(m.state.layers[0].raster.tiles.count,1)
        let image=try m.state.composite(); assertColor(image,CGPoint(x:270,y:280),red); assertColor(image,CGPoint(x:270,y:700),.clear)
        m.undo(); XCTAssertTrue(m.state.layers[0].raster.tiles.isEmpty); m.redo(); XCTAssertEqual(m.state.layers[0].raster.tiles.count,1)
    }
    func testCopyDoesNotBakeAndHonorsLayerOrder() throws {
        let m=BoardModel(); m.state.size=CGSize(width:64,height:64)
        m.pending=object(m,rect:m.state.rect); try m.bake(); try m.addLayer()
        m.pending=object(m,rect:CGRect(x:0,y:0,width:32,height:32),color:blue)
        assertColor(try m.copyImage(currentOnly:false),CGPoint(x:10,y:10),blue)
        XCTAssertNotNil(m.pending); XCTAssertTrue(m.state.layers[1].raster.tiles.isEmpty)
    }
    func testCutVisibleLayersIsSingleUndoAndKeepsHidden() throws {
        let m=BoardModel(); m.state.size=CGSize(width:64,height:64)
        m.pending=object(m,rect:m.state.rect); try m.bake(); try m.addLayer(); m.pending=object(m,rect:m.state.rect,color:blue); try m.bake()
        m.state.layers[0].visible=false
        let count=m.undoStack.count; m.selection=CGRect(x:8,y:8,width:16,height:16)
        assertColor(try m.cut(currentOnly:false),CGPoint(x:4,y:4),blue)
        XCTAssertEqual(m.undoStack.count,count+1)
        assertColor(try m.state.composite(),CGPoint(x:12,y:12),.clear)
        m.state.layers[0].visible=true
        assertColor(try m.state.composite(),CGPoint(x:12,y:12),red)
        m.undo(); assertColor(try m.state.composite(),CGPoint(x:12,y:12),blue)
    }
    func testLockedCutIsAtomic() throws {
        let m=BoardModel(); m.state.size=CGSize(width:32,height:32)
        m.pending=object(m,rect:m.state.rect); try m.bake(); try m.addLayer(); m.state.layers[0].locked=true
        m.selection=m.state.rect; let before=m.undoStack.count
        XCTAssertThrowsError(try m.cut(currentOnly:false)); XCTAssertEqual(m.undoStack.count,before)
        assertColor(try m.state.composite(),CGPoint(x:10,y:10),red)
    }
    func testCutActiveObjectDoesNotBakeAndUndoRestoresEditableObject() throws {
        let m=BoardModel(); m.state.size=CGSize(width:64,height:64)
        m.pending=object(m,rect:CGRect(x:0,y:0,width:32,height:32))
        m.selection=CGRect(x:0,y:0,width:16,height:32)
        _=try m.cut(currentOnly:false)
        XCTAssertNotNil(m.pending); XCTAssertTrue(m.state.layers[0].raster.tiles.isEmpty == false)
        XCTAssertEqual(sample(try m.state.composite(pending:m.pending),x:8,y:8).alphaComponent,0,accuracy:0.01)
        assertColor(try m.state.composite(pending:m.pending),CGPoint(x:24,y:8),red)
        m.undo(); XCTAssertEqual(m.pending?.tool,.rectangle)
        assertColor(try m.state.composite(pending:m.pending),CGPoint(x:8,y:8),red)
        m.redo(); XCTAssertNotNil(m.pending); XCTAssertEqual(sample(try m.state.composite(pending:m.pending),x:8,y:8).alphaComponent,0,accuracy:0.01)
    }
    func testEraserPreviewMatchesBakeWithBackground() throws {
        let m=BoardModel(); m.state.size=CGSize(width:32,height:32); m.state.layers[0].background=blue
        m.pending=object(m,rect:m.state.rect); try m.bake()
        var eraser=object(m,rect:CGRect(x:8,y:8,width:8,height:8)); eraser.tool = .eraser; eraser.lineWidth=8; eraser.points=[CGPoint(x:12,y:12)]
        m.pending=eraser
        let before=try m.state.composite(pending:m.pending); try m.bake()
        assertColor(before,CGPoint(x:12,y:12),blue); assertColor(try m.state.composite(),CGPoint(x:12,y:12),blue)
    }
    func testBackgroundAndLayerOpacityAreIndependentAndCutClearsBackground() throws {
        let m=BoardModel(); m.state.size=CGSize(width:32,height:32)
        m.state.layers[0].background=RGBA(r:1,g:1,b:1,a:0.5)
        m.pending=object(m,rect:CGRect(x:0,y:0,width:8,height:8)); try m.bake()
        assertColor(try m.state.composite(),CGPoint(x:4,y:4),red)
        XCTAssertEqual(sample(try m.state.composite(),x:16,y:16).alphaComponent,0.5,accuracy:0.01)
        m.selection=CGRect(x:12,y:12,width:8,height:8); _=try m.cut(currentOnly:false)
        XCTAssertEqual(sample(try m.state.composite(),x:16,y:16).alphaComponent,0,accuracy:0.01)
        m.state.layers[0].opacity=0.5
        XCTAssertEqual(sample(try m.state.composite(),x:4,y:4).alphaComponent,0.5,accuracy:0.01)
    }
    func testCropAndResizeStayAlignedAndUndoTogether() throws {
        let m=BoardModel(); m.state.size=CGSize(width:600,height:500)
        m.pending=object(m,rect:CGRect(x:270,y:280,width:20,height:20)); try m.bake(); try m.addLayer()
        m.selection=CGRect(x:260,y:260,width:60,height:80); try m.crop()
        XCTAssertEqual(m.state.size,CGSize(width:60,height:80)); assertColor(try m.state.composite(),CGPoint(x:15,y:25),red)
        m.undo(); XCTAssertEqual(m.state.size,CGSize(width:600,height:500))
        let tiles=m.state.layers[0].raster.tiles.count; try m.resize(CGSize(width:7680,height:4320)); XCTAssertEqual(m.state.layers[0].raster.tiles.count,tiles)
        m.undo(); XCTAssertEqual(m.state.size,CGSize(width:600,height:500))
    }
    func testPixelEditingUsesCurrentLayerAndOneUndoPerStroke() throws {
        let m=BoardModel(); m.state.size=CGSize(width:32,height:32)
        m.pending=object(m,rect:m.state.rect); try m.bake()
        try m.addLayer()
        let revision=m.state.layers[0].revision, steps=m.undoStack.count
        try m.pixel(at:CGPoint(x:4,y:4),color:blue,continuing:false)
        try m.pixel(at:CGPoint(x:5,y:4),color:blue,continuing:true)
        XCTAssertEqual(m.state.layers.count,2); XCTAssertEqual(m.undoStack.count,steps+1); XCTAssertEqual(m.state.layers[0].revision,revision)
        assertColor(try m.state.composite(),CGPoint(x:4,y:4),blue)
        m.undo(); XCTAssertEqual(m.state.layers.count,2); assertColor(try m.state.composite(),CGPoint(x:4,y:4),red)
    }
    func testLastLayerCannotDisappear() throws { let m=BoardModel(); try m.deleteLayer(); XCTAssertEqual(m.state.layers.count,1); XCTAssertEqual(m.state.activeID,m.state.layers[0].id) }
    func testMergePreservesVisibleComposition() throws {
        let m=BoardModel(); m.state.size=CGSize(width:32,height:32); m.pending=object(m,rect:m.state.rect); try m.bake(); try m.addLayer()
        m.pending=object(m,rect:CGRect(x:0,y:0,width:16,height:16),color:blue); try m.bake(); m.state.layers[1].opacity=0.5
        let before=sample(try m.state.composite(),x:4,y:4); try m.mergeDown(); let after=sample(try m.state.composite(),x:4,y:4)
        XCTAssertEqual(m.state.layers.count,1); XCTAssertEqual(before.redComponent,after.redComponent,accuracy:0.01); XCTAssertEqual(before.blueComponent,after.blueComponent,accuracy:0.01)
    }
    func testGeometryRecognitionAndFallback() {
        let m=BoardModel()
        var stroke=object(m,rect:.zero); stroke.tool = .brush
        stroke.points=(0...50).map { CGPoint(x:$0*2,y:$0) }; XCTAssertEqual(Geometry.recognize(stroke).tool,.line)
        stroke.points=(0...100).map { let a=Double($0)*Double.pi*2/100; return CGPoint(x:100+50*cos(a),y:100+50*sin(a)) }
        XCTAssertEqual(Geometry.recognize(stroke).tool,.ellipse)
        stroke.points=[CGPoint(x:0,y:0),CGPoint(x:40,y:70),CGPoint(x:80,y:10),CGPoint(x:20,y:30),CGPoint(x:60,y:90),CGPoint(x:10,y:90),CGPoint(x:90,y:50)]
        XCTAssertEqual(Geometry.recognize(stroke).tool,.brush)
        let corners=[CGPoint(x:0,y:0),CGPoint(x:100,y:0),CGPoint(x:100,y:80),CGPoint(x:0,y:80),CGPoint(x:0,y:0)]
        stroke.points=zip(corners,corners.dropFirst()).flatMap { a,b in (0..<20).map { i in let t=CGFloat(i)/20; return CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t) } }+[corners[0]]
        XCTAssertEqual(Geometry.recognize(stroke).tool,.rectangle)
        let triangle=[CGPoint(x:50,y:0),CGPoint(x:100,y:90),CGPoint(x:0,y:90),CGPoint(x:50,y:0)]
        stroke.points=zip(triangle,triangle.dropFirst()).flatMap { a,b in (0..<20).map { i in let t=CGFloat(i)/20; return CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t) } }+[triangle[0]]
        XCTAssertEqual(Geometry.recognize(stroke).tool,.triangle)
    }
    func testNextBrushStrokeDoesNotAccidentallyMovePreviousStroke() {
        let m=BoardModel(); var stroke=object(m,rect:CGRect(x:0,y:0,width:100,height:100)); stroke.tool = .brush; stroke.freehand=true
        XCTAssertTrue(stroke.startsNextStroke(using:.brush)); XCTAssertFalse(stroke.startsNextStroke(using:.select))
        stroke.points=(0...50).map { CGPoint(x:$0*2,y:$0) }
        let line=Geometry.recognize(stroke)
        XCTAssertEqual(line.tool,.line); XCTAssertTrue(line.startsNextStroke(using:.brush)); XCTAssertFalse(line.startsNextStroke(using:.select))
        let pasted=object(m,rect:.zero); XCTAssertFalse(pasted.startsNextStroke(using:.brush))
    }
    func testImageImportRespectsPhotoOrientation() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at:url) }
        let c=try bitmapContext(64,32); c.setFillColor(red.cg); c.fill(CGRect(x:0,y:0,width:64,height:32))
        let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.jpeg.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(dest,c.makeImage()!,[kCGImagePropertyOrientation:6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let image=try readImage(url); XCTAssertEqual(image.width,32); XCTAssertEqual(image.height,64)
    }
    func testProjectRoundtripIncrementalSaveAndImmutableLoadedUndo() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), url=root.appendingPathComponent("test.sboard")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let m=BoardModel(); m.state.size=CGSize(width:80,height:60); m.pending=object(m,rect:CGRect(x:0,y:0,width:20,height:10)); try m.bake(); try m.addLayer(); m.state.layers[1].background=RGBA(r:1,g:1,b:1,a:0.1)
        try ProjectFile.save(m.state,to:url)
        let inode=(try FileManager.default.attributesOfItem(atPath:url.appendingPathComponent("layers/0.png").path))[.systemFileNumber] as! NSNumber
        let loaded=try ProjectFile.load(url); XCTAssertTrue(loaded.layers[0].raster.tiles.isEmpty); XCTAssertNotNil(loaded.layers[0].raster.source)
        assertColor(try loaded.composite(only:loaded.layers[0].id),CGPoint(x:5,y:5),red)
        XCTAssertEqual(sample(try loaded.composite(only:loaded.layers[0].id),x:5,y:40).alphaComponent,0,accuracy:0.01)
        try ProjectFile.save(m.state,to:url)
        let inode2=(try FileManager.default.attributesOfItem(atPath:url.appendingPathComponent("layers/0.png").path))[.systemFileNumber] as! NSNumber
        XCTAssertEqual(inode,inode2)
        m.state.layers[0].name="只改名字"; m.state.layers[0].touch(); try ProjectFile.save(m.state,to:url)
        XCTAssertEqual(inode,(try FileManager.default.attributesOfItem(atPath:url.appendingPathComponent("layers/0.png").path))[.systemFileNumber] as! NSNumber)
        m.state.layers[0].raster=Raster(); m.state.layers[0].touch(pixels:true); try ProjectFile.save(m.state,to:url)
        assertColor(try loaded.composite(only:loaded.layers[0].id),CGPoint(x:5,y:5),red)
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.appendingPathComponent("preview.png").path))
    }
    func testProjectRejectsPathTraversal() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:root.appendingPathComponent("layers"),withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let id=UUID(), layer=LayerRecord(id:id,revision:UUID(),contentRevision:UUID(),name:"bad",visible:true,locked:false,opacity:1,background:.clear,backgroundHoles:[],file:"../../secret.png")
        let manifest=Manifest(version:1,width:32,height:32,activeID:id,layers:[layer])
        try JSONEncoder().encode(manifest).write(to:root.appendingPathComponent("layers/manifest.json"))
        XCTAssertThrowsError(try ProjectFile.load(root))
    }
    func testMainAndArchitecturePerformanceScenarios() throws {
        for (size,count) in [(CGSize(width:3840,height:2160),10),(CGSize(width:7680,height:4320),20)] {
            let m=BoardModel(); m.state.size=size
            for i in 0..<count {
                if i > 0 { try m.addLayer() }
                for j in 0..<16 {
                    let rect=CGRect(x:(j*419+i*37)%Int(size.width-200),y:(j*283+i*19)%Int(size.height-200),width:180,height:180)
                    m.pending=object(m,rect:rect,color:RGBA(r:Double(i%3)/2,g:0.4,b:0.7,a:0.7)); try m.bake()
                }
            }
            let total=m.state.layers.reduce(0) { $0+$1.raster.tiles.count }
            var samples: [Double]=[]
            for i in 0..<120 {
                let start=CFAbsoluteTimeGetCurrent(), c=try bitmapContext(96,96)
                let region=CGRect(x:CGFloat(i*17),y:CGFloat(i*9),width:96,height:96)
                c.translateBy(x:-region.minX,y:-region.minY); try m.state.draw(on:c,region:region)
                samples.append((CFAbsoluteTimeGetCurrent()-start)*1000)
            }
            samples.sort(); let p95=samples[Int(Double(samples.count)*0.95)]
            print("BENCH \(Int(size.width))x\(Int(size.height)) layers=\(count) tiles=\(total) localDraw_p95_ms=\(String(format:"%.3f",p95))")
            XCTAssertLessThan(total,count*200)
            XCTAssertLessThan(p95,100,"Local repaint unexpectedly slow; inspect optimized build before accepting UI performance.")
        }
    }
    func testNativeViewLayoutAndOffscreenPreview() throws {
        XCTAssertTrue(Thread.isMainThread)
        _=NSApplication.shared
        let board=BoardWindow()
        guard let content=board.window?.contentView else { return XCTFail("missing native content") }
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(board.scroll.frame.width,700)
        XCTAssertGreaterThan(board.scroll.frame.height,400)
        XCTAssertGreaterThan(board.table.enclosingScrollView!.frame.height,100)
        XCTAssertEqual(board.toolControl.segmentCount,Tool.allCases.count)
        board.toolControl.selectedSegment=Tool.allCases.firstIndex(of:.rectangle)!
        board.foreground.color=red.ns; board.fill.state = .on
        board.model.pending=object(board.model,rect:CGRect(x:90,y:80,width:300,height:180))
        board.model.notify()
        try board.model.bake(); board.addLayer()
        board.model.pending=EditableObject(tool:.text,frame:CGRect(x:110,y:120,width:400,height:80),color:.black,lineWidth:1,text:"顺手画板 · Native",fontSize:32,layerID:board.model.state.activeID)
        board.model.notify()
        content.layoutSubtreeIfNeeded()
        if let rep=content.bitmapImageRepForCachingDisplay(in:content.bounds) {
            content.cacheDisplay(in:content.bounds,to:rep)
            let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/qa",isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let c=try bitmapContext(rep.pixelsWide,rep.pixelsHigh)
            c.setFillColor(NSColor.windowBackgroundColor.cgColor); c.fill(CGRect(x:0,y:0,width:rep.pixelsWide,height:rep.pixelsHigh))
            if let image=rep.cgImage { drawImage(image,in:CGRect(x:0,y:0,width:rep.pixelsWide,height:rep.pixelsHigh),on:c) }
            if let image=c.makeImage() { try imageData(image).write(to:root.appendingPathComponent("native-window.png")) }
        } else { XCTFail("could not render native view offscreen") }
        try board.model.bake()
        let example=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/Examples/入门示例.sboard",isDirectory:true)
        try FileManager.default.createDirectory(at:example.deletingLastPathComponent(),withIntermediateDirectories:true)
        try ProjectFile.save(board.model.state,to:example)
        board.model.dirty=false
    }
    func testDenseLayersAndLongStrokePerformance() throws {
        for (size,count) in [(CGSize(width:3840,height:2160),10),(CGSize(width:7680,height:4320),20)] {
            let c=try bitmapContext(256,256)
            c.setFillColor(red.cg); c.fill(CGRect(x:0,y:0,width:256,height:256))
            c.setFillColor(blue.cg); c.fill(CGRect(x:0,y:0,width:128,height:128))
            let tile=c.makeImage()!, m=BoardModel(); m.state.size=size
            let all=Raster.keys(in:m.state.rect)
            for i in 0..<count {
                if i > 0 { try m.addLayer() }
                m.state.layers[i].raster.tiles=Dictionary(uniqueKeysWithValues:all.map { ($0,tile) })
                m.state.layers[i].opacity=0.65
            }
            var stroke=object(m,rect:CGRect(x:0,y:0,width:3000,height:1200)); stroke.tool = .brush; stroke.lineWidth=4
            stroke.points=(0..<6000).map { i in CGPoint(x:Double(i)/2,y:600+sin(Double(i)/80)*500) }
            var times: [Double]=[]
            for i in 0..<120 {
                let region=CGRect(x:CGFloat(i*15),y:CGFloat(i*7),width:96,height:96), out=try bitmapContext(96,96)
                out.translateBy(x:-region.minX,y:-region.minY)
                let start=CFAbsoluteTimeGetCurrent(); try m.state.draw(on:out,region:region,pending:stroke)
                times.append((CFAbsoluteTimeGetCurrent()-start)*1000)
            }
            times.sort(); let p95=times[Int(Double(times.count)*0.95)]
            print("BENCH_DENSE \(Int(size.width))x\(Int(size.height)) layers=\(count) strokePoints=6000 localDraw_p95_ms=\(String(format:"%.3f",p95))")
            XCTAssertLessThan(p95,16.7,"Dense local draw exceeds a 60 Hz frame budget")
        }
    }
    func testProjectIOAtTargetSizes() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        for (size,count) in [(CGSize(width:3840,height:2160),10),(CGSize(width:7680,height:4320),20)] {
            let m=BoardModel(); m.state.size=size
            for i in 0..<count {
                if i > 0 { try m.addLayer() }
                m.pending=object(m,rect:CGRect(x:i*40,y:i*30,width:800,height:600),color:RGBA(r:Double(i%3)/2,g:0.4,b:0.7,a:0.7)); try m.bake()
            }
            let url=root.appendingPathComponent("\(count).sboard"), start=CFAbsoluteTimeGetCurrent()
            try ProjectFile.save(m.state,to:url); let first=CFAbsoluteTimeGetCurrent()
            try ProjectFile.save(m.state,to:url); let second=CFAbsoluteTimeGetCurrent()
            let loaded=try ProjectFile.load(url); let end=CFAbsoluteTimeGetCurrent()
            XCTAssertEqual(loaded.layers.count,count); XCTAssertTrue(loaded.layers.allSatisfy({$0.raster.tiles.isEmpty}))
            print("BENCH_IO \(Int(size.width))x\(Int(size.height)) layers=\(count) firstSave_s=\(String(format:"%.3f",first-start)) unchangedSave_s=\(String(format:"%.3f",second-first)) manifestOpen_ms=\(String(format:"%.3f",(end-second)*1000))")
        }
    }
}
