import AppKit
import XCTest
@testable import Board

// These events are delivered directly to hidden test views, never posted to the user's desktop.
final class NativeAcceptanceTests: XCTestCase {
    private func board(tool: Tool) -> BoardWindow {
        _=NSApplication.shared
        let board=BoardWindow()
        board.window?.contentView?.layoutSubtreeIfNeeded()
        board.toolControl.selectedSegment=Tool.allCases.firstIndex(of:tool)!
        return board
    }
    private func mouse(_ board: BoardWindow,_ type: NSEvent.EventType,_ point: CGPoint,_ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:board.canvas.convert(point,to:nil),modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:board.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
    }
    private func drag(_ board: BoardWindow,from start: CGPoint,to end: CGPoint,flags: NSEvent.ModifierFlags = []) {
        board.canvas.mouseDown(with:mouse(board,.leftMouseDown,start,flags))
        board.canvas.mouseDragged(with:mouse(board,.leftMouseDragged,end,flags))
        board.canvas.mouseUp(with:mouse(board,.leftMouseUp,end,flags))
    }
    private func key(_ board: BoardWindow,code: UInt16,flags: NSEvent.ModifierFlags = []) {
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:board.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
        board.canvas.keyDown(with:event)
    }

    func testContinuousBrushThenMoveConfirmAndUndo() throws {
        let b=board(tool:.brush)
        drag(b,from:CGPoint(x:100,y:100),to:CGPoint(x:200,y:200))
        XCTAssertEqual(b.model.pending?.points.count,2)
        XCTAssertTrue(b.model.state.layers[0].raster.tiles.isEmpty)
        drag(b,from:CGPoint(x:120,y:150),to:CGPoint(x:200,y:100))
        XCTAssertEqual(b.model.pending?.points.first,CGPoint(x:120,y:150))
        XCTAssertFalse(b.model.state.layers[0].raster.tiles.isEmpty)
        XCTAssertEqual(b.model.undoStack.count,1)
        b.toolControl.selectedSegment=Tool.allCases.firstIndex(of:.select)!
        drag(b,from:CGPoint(x:150,y:130),to:CGPoint(x:180,y:150))
        XCTAssertEqual(b.model.pending?.points.first,CGPoint(x:150,y:170))
        key(b,code:124); key(b,code:125,flags:.shift)
        XCTAssertEqual(b.model.pending?.points.first,CGPoint(x:151,y:180))
        key(b,code:36); XCTAssertNil(b.model.pending); XCTAssertEqual(b.model.undoStack.count,2)
        let revision=b.model.state.layers[0].contentRevision
        b.undo(nil); XCTAssertNotEqual(b.model.state.layers[0].contentRevision,revision)
        b.redo(nil); XCTAssertEqual(b.model.state.layers[0].contentRevision,revision)
        b.model.dirty=false
    }

    func testBrushSelectionOutlineAppearsOnlyAfterRelease() throws {
        let b=board(tool:.brush)
        b.canvas.mouseDown(with:mouse(b,.leftMouseDown,CGPoint(x:100,y:100)))
        b.canvas.mouseDragged(with:mouse(b,.leftMouseDragged,CGPoint(x:200,y:200)))
        b.crosshairOverlay.updateGuides()
        XCTAssertNil(b.crosshairOverlay.objectOutline.path)
        b.canvas.mouseUp(with:mouse(b,.leftMouseUp,CGPoint(x:200,y:200)))
        XCTAssertNotNil(b.crosshairOverlay.objectOutline.path)
        b.cancelObject()
    }

    func testShapeResizeSnapsItsEndpoint() throws {
        let b=board(tool:.rectangle)
        drag(b,from:CGPoint(x:103,y:107),to:CGPoint(x:207,y:183))
        XCTAssertEqual(b.model.pending?.frame,CGRect(x:103,y:107,width:104,height:76))
        drag(b,from:CGPoint(x:207,y:183),to:CGPoint(x:237,y:214),flags:.shift)
        XCTAssertEqual(b.model.pending?.frame.maxX,240)
        XCTAssertEqual(b.model.pending?.frame.maxY,210)
        b.snapField.integerValue=100
        drag(b,from:CGPoint(x:240,y:210),to:CGPoint(x:390,y:305),flags:.shift)
        XCTAssertEqual(b.model.pending?.frame.maxX,400)
        XCTAssertEqual(b.model.pending?.frame.maxY,300)
        key(b,code:53); XCTAssertNil(b.model.pending); XCTAssertTrue(b.model.state.layers[0].raster.tiles.isEmpty)
    }

    func testTextChangesDoNotBakeAndLayerSwitchDoes() throws {
        let b=board(tool:.text)
        b.textField.stringValue="验收文字"
        b.canvas.mouseDown(with:mouse(b,.leftMouseDown,CGPoint(x:80,y:80)))
        XCTAssertEqual(b.model.pending?.text,"验收文字")
        b.textField.stringValue="修改文字"; b.fontSizeField.doubleValue=48
        b.foreground.color=NSColor(srgbRed:0,green:0,blue:1,alpha:1)
        b.settingsChanged(b.textField)
        XCTAssertEqual(b.model.pending?.text,"修改文字"); XCTAssertEqual(b.model.pending?.fontSize,48)
        XCTAssertTrue(b.model.undoStack.isEmpty)
        b.addLayer()
        XCTAssertNil(b.model.pending); XCTAssertFalse(b.model.state.layers[0].raster.tiles.isEmpty)
        XCTAssertEqual(b.model.state.layers.count,2)
        b.model.dirty=false
    }

    func testImageDropUsesChosenLayerAndRemainsEditable() throws {
        let b=board(tool:.brush)
        let first=b.model.state.activeID; b.addLayer(); let target=b.model.state.activeID
        try b.model.selectLayer(first)
        let c=try bitmapContext(24,16); c.setFillColor(RGBA.black.cg); c.fill(CGRect(x:0,y:0,width:24,height:16))
        let pasteboard=NSPasteboard(name:NSPasteboard.Name("SimpleBoardTest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(try imageData(c.makeImage()!),forType:.png)
        XCTAssertTrue(b.receiveDrop(pasteboard,layerID:target,point:CGPoint(x:50,y:60)))
        XCTAssertEqual(b.model.state.activeID,target); XCTAssertEqual(b.model.pending?.layerID,target)
        XCTAssertEqual(b.model.pending?.frame,CGRect(x:50,y:60,width:24,height:16))
        XCTAssertTrue(b.model.state.layers.allSatisfy({$0.raster.tiles.isEmpty}))
        b.cancelObject(); XCTAssertNil(b.model.pending); b.model.dirty=false
    }

    func testCrosshairRulersAndPixelStroke() throws {
        let b=board(tool:.brush)
        b.toggleCrosshair(); XCTAssertTrue(b.canvas.crosshair)
        b.canvas.mouseMoved(with:mouse(b,.mouseMoved,CGPoint(x:80,y:90)))
        b.freezeCrosshair(); XCTAssertFalse(b.canvas.trackingCrosshair)
        let horizontal=b.crosshairOverlay.horizontal.frame, vertical=b.crosshairOverlay.vertical.frame
        b.canvas.mouseMoved(with:mouse(b,.mouseMoved,CGPoint(x:120,y:130)))
        XCTAssertEqual(b.canvas.frozenPoint,CGPoint(x:80,y:90))
        XCTAssertEqual(b.crosshairOverlay.horizontal.frame,horizontal); XCTAssertEqual(b.crosshairOverlay.vertical.frame,vertical)
        b.scroll.magnification=2; b.scroll.contentView.scroll(to:CGPoint(x:20,y:30)); b.rulersChanged()
        let frozen=b.crosshairOverlay.convert(b.canvas.frozenPoint,from:b.canvas)
        XCTAssertEqual(b.crosshairOverlay.horizontal.frame.minY,frozen.y)
        XCTAssertEqual(b.crosshairOverlay.vertical.frame.minX,frozen.x)
        XCTAssertEqual(b.crosshairOverlay.horizontal.frame.height,1)
        XCTAssertNil(b.crosshairOverlay.hitTest(frozen))
        b.toggleRulers(); b.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(b.topRuler.isHidden); XCTAssertEqual(b.topRuler.frame.height,0)
        b.toggleRulers(); b.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(b.topRuler.isHidden); XCTAssertEqual(b.topRuler.frame.height,24)
        b.scroll.magnification=16; b.rulersChanged(); XCTAssertTrue(b.canvas.pixelEditing)
        drag(b,from:CGPoint(x:100,y:100),to:CGPoint(x:110,y:100))
        XCTAssertEqual(b.model.state.layers.count,1); XCTAssertEqual(b.model.undoStack.count,1)
        b.undo(nil); XCTAssertEqual(b.model.state.layers.count,1)
        b.model.dirty=false
    }

    func testCanvasEdgeExpansionAndInwardDragUndoGranularity() throws {
        let b=board(tool:.select)
        drag(b,from:CGPoint(x:1280,y:400),to:CGPoint(x:1400,y:400))
        XCTAssertEqual(b.model.state.size,CGSize(width:1400,height:800)); XCTAssertEqual(b.model.undoStack.count,1)
        drag(b,from:CGPoint(x:700,y:800),to:CGPoint(x:700,y:880))
        XCTAssertEqual(b.model.state.size,CGSize(width:1400,height:880)); XCTAssertEqual(b.model.undoStack.count,2)
        b.undo(nil); XCTAssertEqual(b.model.state.size,CGSize(width:1400,height:800))
        drag(b,from:CGPoint(x:1400,y:400),to:CGPoint(x:1300,y:400))
        XCTAssertEqual(b.model.state.size,CGSize(width:1300,height:800)); XCTAssertEqual(b.model.undoStack.count,2)
        b.model.dirty=false
    }

    func testSeparatePixelClicksNeverAddLayers() throws {
        let b=board(tool:.brush); b.scroll.magnification=16; b.rulersChanged()
        let original=b.model.state.layers[0].revision
        for i in 0..<20 {
            let point=CGPoint(x:100+i,y:100)
            b.canvas.mouseDown(with:mouse(b,.leftMouseDown,point))
            b.canvas.mouseUp(with:mouse(b,.leftMouseUp,point))
        }
        XCTAssertEqual(b.model.state.layers.count,1)
        XCTAssertNotEqual(b.model.state.layers[0].revision,original)
        XCTAssertEqual(b.model.undoStack.count,20)
        b.undo(nil); XCTAssertEqual(b.model.state.layers.count,1)
        b.model.dirty=false
    }
}
