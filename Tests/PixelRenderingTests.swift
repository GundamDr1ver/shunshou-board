import AppKit
import XCTest
@testable import Board

private final class InvalidationCanvas: CanvasView {
    var invalidations=0
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set { if newValue { invalidations += 1 }; super.needsDisplay=newValue }
    }
    override func setNeedsDisplay(_ invalidRect: NSRect) { invalidations += 1; super.setNeedsDisplay(invalidRect) }
}

final class PixelRenderingTests: XCTestCase {
    private let ink=RGBA(r:0,g:0,b:0,a:1)
    private let paper=RGBA(r:1,g:0.4,b:1,a:1)

    private func color(_ image: CGImage,_ x: Int,_ y: Int) throws -> [UInt8] {
        let c=try bitmapContext(1,1)
        drawImage(try XCTUnwrap(image.cropping(to:CGRect(x:x,y:y,width:1,height:1))),in:CGRect(x:0,y:0,width:1,height:1),on:c)
        return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:4))
    }

    func testZoomedPixelHasHardEdgesAtEveryMagnification() throws {
        _=NSApplication.shared
        let b=BoardWindow(); b.model.state.size=CGSize(width:12,height:12)
        b.model.state.layers[0].background=paper
        try b.model.pixel(at:CGPoint(x:4,y:4),color:ink,continuing:false)
        for zoom in [8,16,64] {
            b.scroll.magnification=CGFloat(zoom)
            let c=try bitmapContext(12*zoom,12*zoom); c.scaleBy(x:CGFloat(zoom),y:CGFloat(zoom))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:true)
            b.canvas.draw(b.model.state.rect)
            NSGraphicsContext.restoreGraphicsState()
            let image=try XCTUnwrap(c.makeImage())
            for offset in [max(1,zoom/8),zoom/2,zoom-2] {
                XCTAssertEqual(try color(image,4*zoom+offset,4*zoom+zoom/2),[0,0,0,255],"No interpolation inside the pixel at \(zoom)x")
                let neighbor=try color(image,5*zoom+offset,4*zoom+zoom/2)
                XCTAssertEqual(neighbor[0],255); XCTAssertEqual(neighbor[2],255)
            }
            if zoom == 64 {
                let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/qa")
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                try imageData(image).write(to:root.appendingPathComponent("pixels-64x.png"))
            }
        }
        b.model.dirty=false
    }

    func testOnePixelBrushIsOneOpaquePixelWide() throws {
        let m=BoardModel(); m.state.size=CGSize(width:12,height:12)
        m.pending=EditableObject(tool:.brush,points:[CGPoint(x:2.1,y:5.4),CGPoint(x:8.8,y:5.4)],frame:CGRect(x:2.1,y:5.4,width:6.7,height:1),color:ink,lineWidth:1,layerID:m.state.activeID)
        try m.bake(); let image=try m.state.composite()
        for x in 3...7 {
            XCTAssertEqual(try color(image,x,5),[0,0,0,255])
            XCTAssertEqual(try color(image,x,4)[3],0)
            XCTAssertEqual(try color(image,x,6)[3],0)
        }
        m.pending=EditableObject(tool:.brush,points:[CGPoint(x:9.7,y:9.2)],frame:CGRect(x:9.7,y:9.2,width:1,height:1),color:ink,lineWidth:1,layerID:m.state.activeID)
        try m.bake(); XCTAssertEqual(try color(m.state.composite(),9,9),[0,0,0,255])
    }

    func testRepeatedPixelClicksNeverCreateLayersAndUndoEachStroke() throws {
        let m=BoardModel(); m.state.size=CGSize(width:12,height:12)
        try m.pixel(at:CGPoint(x:4,y:4),color:ink,continuing:false)
        let layerID=m.state.activeID
        try m.pixel(at:CGPoint(x:5,y:4),color:ink,continuing:false)
        try m.pixel(at:CGPoint(x:6,y:4),color:ink,continuing:true)
        XCTAssertEqual(m.state.layers.count,1); XCTAssertEqual(m.state.activeID,layerID); XCTAssertEqual(m.undoStack.count,2)
        m.undo(); XCTAssertEqual(m.state.layers.count,1)
        XCTAssertEqual(try color(m.state.composite(),4,4)[3],255); XCTAssertEqual(try color(m.state.composite(),5,4)[3],0)
        m.undo(); XCTAssertEqual(m.state.layers.count,1)
        m.redo(); m.redo()
        try m.pixel(at:CGPoint(x:7,y:4),color:ink,continuing:false)
        XCTAssertEqual(m.state.layers.count,1); XCTAssertEqual(m.state.activeID,layerID)
    }

    func testCrosshairMotionDoesNotInvalidateCanvas() {
        _=NSApplication.shared
        let b=BoardWindow()
        let canvas=InvalidationCanvas(model:b.model)
        canvas.controller=b; b.canvas=canvas; b.scroll.documentView=canvas; b.crosshairOverlay.canvas=canvas
        b.window?.contentView?.layoutSubtreeIfNeeded()
        b.toggleCrosshair(); canvas.invalidations=0
        let original=b.model.state.layers[0].revision
        var times:[Double]=[]
        for i in 0..<500 {
            let point=CGPoint(x:50+i%300,y:60+i%200)
            let event=NSEvent.mouseEvent(with:.mouseMoved,location:b.canvas.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:b.window!.windowNumber,context:nil,eventNumber:i,clickCount:0,pressure:0)!
            let start=CFAbsoluteTimeGetCurrent(); b.canvas.mouseMoved(with:event)
            times.append((CFAbsoluteTimeGetCurrent()-start)*1000)
        }
        XCTAssertEqual(canvas.invalidations,0,"Moving guides must not invalidate the bitmap canvas")
        XCTAssertEqual(b.model.state.layers[0].revision,original); XCTAssertTrue(b.model.undoStack.isEmpty)
        times.sort(); print("BENCH_CROSSHAIR move_p95_ms=\(String(format:"%.3f",times[475]))")
        XCTAssertLessThan(times[475],4)
    }

    func testPixelEditingRejectsLockedOrHiddenCurrentLayer() throws {
        let m=BoardModel(); m.state.size=CGSize(width:12,height:12)
        try m.pixel(at:CGPoint(x:1,y:1),color:ink,continuing:false)
        let first=m.state.activeID
        m.state.layers[m.state.activeIndex].locked=true
        XCTAssertThrowsError(try m.pixel(at:CGPoint(x:2,y:1),color:ink,continuing:false))
        m.state.layers[0].locked=false; m.state.layers[0].visible=false
        XCTAssertThrowsError(try m.pixel(at:CGPoint(x:3,y:1),color:ink,continuing:false))
        m.state.layers[0].visible=true
        try m.pixel(at:CGPoint(x:4,y:1),color:ink,continuing:false)
        XCTAssertEqual(m.state.layers.count,1); XCTAssertEqual(m.state.activeID,first)
    }
}
