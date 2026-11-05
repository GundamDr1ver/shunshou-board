import AppKit
import XCTest
@testable import Board

private final class TestDrop: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any?
    var draggingSourceOperationMask: NSDragOperation { [.copy,.move] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination=false
    var numberOfValidItemsForDrop=1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(_ pasteboard: NSPasteboard, source: Any? = nil) { draggingPasteboard=pasteboard; draggingSource=source }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey:Any], using block: (NSDraggingItem,Int,UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

final class InteractionUpdateTests: XCTestCase {
    private func board(_ tool: Tool = .select) -> BoardWindow {
        _=NSApplication.shared; let b=BoardWindow()
        b.toolControl.selectedSegment=Tool.allCases.firstIndex(of:tool)!
        b.window?.contentView?.layoutSubtreeIfNeeded(); return b
    }
    private func event(_ b: BoardWindow,_ type: NSEvent.EventType,_ p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:b.canvas.convert(p,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:b.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
    }
    private func key(_ b: BoardWindow,_ shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:shift ? [.command,.shift]:.command,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:b.window!.windowNumber,context:nil,characters:shift ? "Z":"z",charactersIgnoringModifiers:shift ? "Z":"z",isARepeat:false,keyCode:6)!
    }
    private func image(_ overlay: CrosshairOverlay) throws -> CGImage {
        let c=try bitmapContext(max(1,Int(overlay.bounds.width)),max(1,Int(overlay.bounds.height)))
        c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(origin:.zero,size:overlay.bounds.size))
        overlay.layer!.render(in:c); return try XCTUnwrap(c.makeImage())
    }

    func testZoomThresholdAndRightButtonPanPreserveDocument() throws {
        let b=board(.brush)
        let original=b.model.state.layers[0].revision
        XCTAssertFalse(b.canvas.pixelEditing)
        for _ in 0..<4 { b.canvas.zoomByScroll(20,at:CGPoint(x:100,y:100)) }
        XCTAssertTrue(b.canvas.pixelEditing); XCTAssertFalse(b.crosshairOverlay.grid.path!.isEmpty)
        b.canvas.zoomByScroll(-100,at:CGPoint(x:100,y:100))
        XCTAssertFalse(b.canvas.pixelEditing); XCTAssertTrue(b.crosshairOverlay.grid.path!.isEmpty)
        b.scroll.magnification=2; b.scroll.contentView.scroll(to:CGPoint(x:100,y:100))
        let before=b.scroll.contentView.bounds.origin
        b.canvas.rightMouseDown(with:event(b,.rightMouseDown,CGPoint(x:200,y:200)))
        b.canvas.rightMouseDragged(with:event(b,.rightMouseDragged,CGPoint(x:250,y:240)))
        b.canvas.rightMouseUp(with:event(b,.rightMouseUp,CGPoint(x:250,y:240)))
        XCTAssertEqual(b.scroll.contentView.bounds.origin.x,before.x-50,accuracy:0.01)
        XCTAssertEqual(b.scroll.contentView.bounds.origin.y,before.y-40,accuracy:0.01)
        XCTAssertEqual(b.model.state.layers[0].revision,original); XCTAssertTrue(b.model.undoStack.isEmpty)
    }

    func testCanvasResizeIsGhostOnlyUntilReleaseAndCropsAllLayers() throws {
        let b=board(); let m=b.model
        for i in 0..<2 {
            if i > 0 { try m.addLayer() }
            m.pending=EditableObject(tool:.rectangle,frame:CGRect(x:1200,y:100,width:30,height:30),color:.black,lineWidth:1,filled:true,layerID:m.state.activeID); try m.bake()
        }
        let size=m.state.size, frame=b.canvas.frame.size, count=m.undoStack.count
        b.canvas.mouseDown(with:event(b,.leftMouseDown,CGPoint(x:1280,y:400)))
        b.canvas.mouseDragged(with:event(b,.leftMouseDragged,CGPoint(x:1100,y:400)))
        XCTAssertEqual(m.state.size,size); XCTAssertEqual(b.canvas.frame.size,frame); XCTAssertEqual(m.undoStack.count,count)
        XCTAssertEqual(b.canvas.resizePreview?.width,1100); XCTAssertNotNil(b.crosshairOverlay.resizeOutline.path)
        b.canvas.mouseUp(with:event(b,.leftMouseUp,CGPoint(x:1100,y:400)))
        XCTAssertEqual(m.state.size.width,1100); XCTAssertEqual(m.undoStack.count,count+1); XCTAssertNil(b.crosshairOverlay.resizeOutline.path)
        try m.resize(size)
        for layer in m.state.layers { XCTAssertEqual(try m.state.composite(only:layer.id).dataProvider!.data,try bitmapContext(Int(size.width),Int(size.height)).makeImage()!.dataProvider!.data) }
        m.undo(); m.undo(); XCTAssertEqual(m.state.size,size)
        XCTAssertTrue(m.state.layers.allSatisfy { !$0.raster.tiles.isEmpty }); m.dirty=false
    }

    func testMenuAndCanvasUndoRedoIncludePendingObjects() throws {
        let b=board(.rectangle), delegate=AppDelegate(); delegate.board=b; delegate.buildMenu()
        defer { NSApp.mainMenu=nil }
        b.canvas.mouseDown(with:event(b,.leftMouseDown,CGPoint(x:100,y:100)))
        b.canvas.mouseDragged(with:event(b,.leftMouseDragged,CGPoint(x:200,y:180)))
        b.canvas.mouseUp(with:event(b,.leftMouseUp,CGPoint(x:200,y:180)))
        XCTAssertNotNil(b.model.pending)
        XCTAssertTrue(b.canvas.performKeyEquivalent(with:key(b))); XCTAssertNil(b.model.pending)
        XCTAssertTrue(b.canvas.performKeyEquivalent(with:key(b,true))); XCTAssertNotNil(b.model.pending)
        XCTAssertTrue(b.model.undoStack.isEmpty)
        try b.model.bake()
        NSApp.mainMenu?.update()
        XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with:key(b))); XCTAssertTrue(b.model.state.layers[0].raster.tiles.isEmpty)
        NSApp.mainMenu?.update()
        let edit=NSApp.mainMenu!.items.first(where:{$0.title == "编辑"})!.submenu!
        edit.update()
        XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with:key(b,true))); XCTAssertFalse(b.model.state.layers[0].raster.tiles.isEmpty)
        b.model.dirty=false
    }

    func testMultipleLayerSelectionAndBatchDeleteAreOneUndo() throws {
        let b=board(); b.addLayer(); b.addLayer()
        let ids=b.model.state.layers.map(\.id), steps=b.model.undoStack.count
        b.table.selectRowIndexes(IndexSet([0,1]),byExtendingSelection:false)
        b.tableViewSelectionDidChange(Notification(name:NSTableView.selectionDidChangeNotification))
        XCTAssertEqual(b.selectedLayerIDs.count,2)
        XCTAssertTrue(b.addLayerButton.isEnabled); XCTAssertTrue(b.deleteLayerButton.isEnabled)
        XCTAssertFalse(b.duplicateLayerButton.isEnabled); XCTAssertFalse(b.mergeLayerButton.isEnabled); XCTAssertFalse(b.renameLayerButton.isEnabled)
        b.duplicateLayer(); XCTAssertEqual(b.model.state.layers.count,3)
        b.deleteLayer(); XCTAssertEqual(b.model.state.layers.count,1); XCTAssertEqual(b.model.undoStack.count,steps+1)
        b.undo(nil); XCTAssertEqual(b.model.state.layers.map(\.id),ids)
        b.model.dirty=false
    }

    func testLayerDragOrderingCommitsPendingContentAndCanUndo() throws {
        let b=board(); b.addLayer(); b.addLayer()
        let original=b.model.state.layers.map(\.id), target=b.model.state.activeID
        b.model.startObject(EditableObject(tool:.rectangle,frame:CGRect(x:20,y:20,width:20,height:20),color:.black,lineWidth:1,filled:true,layerID:target))
        let pb=NSPasteboard(name:NSPasteboard.Name(UUID().uuidString)); defer { pb.releaseGlobally() }
        let writer=try XCTUnwrap(b.tableView(b.table,pasteboardWriterForRow:0)); pb.writeObjects([writer])
        let drop=TestDrop(pb,source:b.table)
        XCTAssertEqual(b.tableView(b.table,validateDrop:drop,proposedRow:3,proposedDropOperation:.above),.move)
        XCTAssertTrue(b.tableView(b.table,acceptDrop:drop,row:3,dropOperation:.above))
        XCTAssertEqual(b.model.state.layers.map(\.id),[original[2],original[0],original[1]])
        XCTAssertFalse(b.model.state.layers[0].raster.tiles.isEmpty)
        b.undo(nil); XCTAssertEqual(b.model.state.layers.map(\.id),original)
        XCTAssertFalse(b.model.state.layers[2].raster.tiles.isEmpty); b.model.dirty=false
    }

    func testHoverDropTargetsLayerAndSwitchesSingleSelection() throws {
        let b=board(); b.addLayer(); b.addLayer()
        let target=b.layerAt(1).id, original=b.model.state.activeID
        let c=try bitmapContext(20,20); c.setFillColor(RGBA.black.cg); c.fill(CGRect(x:0,y:0,width:20,height:20))
        let pb=NSPasteboard(name:NSPasteboard.Name(UUID().uuidString)); defer { pb.releaseGlobally() }
        pb.setData(try imageData(c.makeImage()!),forType:.png); let drop=TestDrop(pb)
        XCTAssertEqual(b.tableView(b.table,validateDrop:drop,proposedRow:1,proposedDropOperation:.on),.copy)
        XCTAssertEqual(b.model.state.activeID,original)
        XCTAssertTrue(b.tableView(b.table,acceptDrop:drop,row:1,dropOperation:.on))
        XCTAssertEqual(b.model.pending?.layerID,target); XCTAssertEqual(b.selectedLayerIDs,[target])
        XCTAssertEqual(b.model.state.activeID,target); XCTAssertTrue(b.window?.firstResponder === b.canvas)
        b.cancelObject(); b.model.dirty=false
    }

    func testLongNameCannotPushLockOutsideRowAndButtonsAlign() throws {
        let b=board()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0]+descendants($0) } }
        for width in [1180,1320,1600] {
            b.window?.setContentSize(CGSize(width:width,height:800))
            try b.model.transaction("重命名") { $0.layers[0].name=String(repeating:"很长的图层名称",count:30) }
            b.window?.contentView?.layoutSubtreeIfNeeded(); b.table.layoutSubtreeIfNeeded()
            let cell=try XCTUnwrap(b.table.view(atColumn:0,row:0,makeIfNecessary:true))
            cell.layoutSubtreeIfNeeded()
            let lock=try XCTUnwrap(descendants(cell).compactMap { $0 as? NSButton }.first { $0.action == #selector(BoardWindow.toggleLocked(_:)) })
            let label=try XCTUnwrap(descendants(cell).compactMap { $0 as? LayerNameField }.first)
            let clip=try XCTUnwrap(b.table.enclosingScrollView?.contentView)
            XCTAssertLessThanOrEqual(clip.convert(lock.bounds,from:lock).maxX,clip.bounds.maxX,"Lock must stay inside the real visible table, width \(width)")
            XCTAssertLessThanOrEqual(clip.convert(label.bounds,from:label).maxX,clip.convert(lock.bounds,from:lock).minX)
            XCTAssertEqual(label.lineBreakMode,.byTruncatingTail); XCTAssertTrue(label.usesSingleLineMode)
            XCTAssertFalse(label.cell!.isScrollable,"A scrolling text cell clips instead of drawing the ellipsis")
        }
        b.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(b.addLayerButton.frame.width,b.deleteLayerButton.frame.width,accuracy:0.5)
        XCTAssertEqual(b.renameLayerButton.frame.width,b.mergeLayerButton.frame.width,accuracy:0.1)
        XCTAssertEqual(b.addLayerButton.superview!.frame.width,b.renameLayerButton.superview!.frame.width,accuracy:0.1)
        b.window?.setContentSize(CGSize(width:1320,height:800)); b.window?.contentView?.layoutSubtreeIfNeeded()
        let content=try XCTUnwrap(b.window?.contentView), rep=try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in:content.bounds))
        content.cacheDisplay(in:content.bounds,to:rep)
        let c=try bitmapContext(rep.pixelsWide,rep.pixelsHigh)
        c.setFillColor(NSColor.windowBackgroundColor.cgColor); c.fill(CGRect(x:0,y:0,width:rep.pixelsWide,height:rep.pixelsHigh))
        if let rendered=rep.cgImage { drawImage(rendered,in:CGRect(x:0,y:0,width:rep.pixelsWide,height:rep.pixelsHigh),on:c) }
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/qa")
        try imageData(XCTUnwrap(c.makeImage())).write(to:root.appendingPathComponent("layout-0.1.3.png"))
        b.model.dirty=false
    }

    func testColorControlsFollowSnapInThreeToolbarRows() throws {
        let b=board()
        for i in 0..<12 { b.colorHistory.record(RGBA(r:Double(i)/12,g:0.3,b:0.6,a:1)) }
        b.foreground.sendAction(b.foreground.action,to:b)
        b.window?.setContentSize(CGSize(width:1180,height:800)); b.window?.contentView?.layoutSubtreeIfNeeded()
        let settings=try XCTUnwrap(b.foreground.superview as? NSStackView)
        let snap=try XCTUnwrap(settings.arrangedSubviews.firstIndex(of:b.snapField))
        let sampler=try XCTUnwrap(settings.arrangedSubviews.firstIndex { ($0 as? NSButton)?.action == #selector(BoardWindow.sampleColor) })
        let color=try XCTUnwrap(settings.arrangedSubviews.firstIndex(of:b.foreground))
        XCTAssertGreaterThan(sampler,snap); XCTAssertGreaterThan(color,sampler)
        XCTAssertTrue(b.historyRow.superview === settings)
        if let history=settings.arrangedSubviews.firstIndex(of:b.historyRow) { XCTAssertGreaterThan(history,color) }
        let content=try XCTUnwrap(b.window?.contentView), root=try XCTUnwrap(content.subviews.first as? NSStackView)
        XCTAssertEqual(root.arrangedSubviews.firstIndex(where:{$0 is NSBox}),3)
        XCTAssertLessThanOrEqual(content.convert(b.historyRow.bounds,from:b.historyRow).maxX,content.bounds.maxX)
        XCTAssertEqual(b.mergeLayerButton.title,"合并↓")
    }

    func testColorHistoryPersistsAndDeduplicates() throws {
        let domain="SimpleBoard-test-\(UUID().uuidString)"
        let defaults=try XCTUnwrap(UserDefaults(suiteName:domain))
        defer { defaults.removePersistentDomain(forName:domain) }
        let history=ColorHistory(defaults:defaults)
        for i in 0..<16 { history.record(RGBA(r:Double(i)/20,g:0,b:0,a:1)) }
        XCTAssertEqual(history.colors.count,12)
        let last=history.colors[5]; history.record(last)
        XCTAssertEqual(history.colors.count,12); XCTAssertEqual(ColorHistory(defaults:defaults).colors.first,last)
        let b=BoardWindow(defaults:defaults); XCTAssertEqual(b.historyRow.arrangedSubviews.compactMap { $0 as? ColorSwatch }.count,12)
    }

    func testGridAndSelectionPathsStayCompleteAcrossPartialRedrawAndScroll() throws {
        let b=board(); b.scroll.magnification=8; b.rulersChanged()
        b.model.selection=CGRect(x:30,y:30,width:50,height:50); b.crosshairOverlay.updateGuides()
        let first=try XCTUnwrap(b.crosshairOverlay.selection.path).boundingBox
        b.model.selection=CGRect(x:100,y:100,width:70,height:60); b.crosshairOverlay.updateGuides()
        XCTAssertNotEqual(b.crosshairOverlay.selection.path?.boundingBox,first)
        XCTAssertEqual(b.crosshairOverlay.selection.path?.boundingBox,b.crosshairOverlay.convert(b.model.selection!,from:b.canvas))
        let grid=try XCTUnwrap(b.crosshairOverlay.grid.path); XCTAssertFalse(grid.isEmpty)
        let c=try bitmapContext(30,30); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:true)
        b.canvas.draw(CGRect(x:10,y:10,width:2,height:2)); NSGraphicsContext.restoreGraphicsState()
        XCTAssertEqual(b.crosshairOverlay.grid.path,grid)
        b.scroll.contentView.scroll(to:CGPoint(x:20,y:20)); b.rulersChanged()
        let moved=try XCTUnwrap(b.crosshairOverlay.grid.path)
        var vertical=0, horizontal=0, last=CGPoint.zero
        moved.applyWithBlock { element in
            let e=element.pointee
            if e.type == .moveToPoint { last=e.points[0] }
            if e.type == .addLineToPoint { if last.x == e.points[0].x { vertical += 1 }; if last.y == e.points[0].y { horizontal += 1 } }
        }
        XCTAssertGreaterThan(vertical,10); XCTAssertGreaterThan(horizontal,10)
        let rendered=try image(b.crosshairOverlay)
        XCTAssertGreaterThan(rendered.width,500)
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/qa")
        try imageData(rendered).write(to:root.appendingPathComponent("guides-0.1.2.png"))
    }

    func testMinimapRefreshesMovedPendingObjectWithoutBaking() throws {
        let b=board()
        b.model.startObject(EditableObject(tool:.rectangle,frame:CGRect(x:100,y:100,width:160,height:160),color:.black,lineWidth:1,filled:true,layerID:b.model.state.activeID))
        func thumbnail() throws -> Data {
            let cell=try XCTUnwrap(b.table.view(atColumn:0,row:0,makeIfNecessary:true))
            return try XCTUnwrap(cell.subviews.compactMap { $0 as? NSImageView }.first?.image?.tiffRepresentation)
        }
        let before=try thumbnail(), old=b.model.pending!.bounds
        b.model.pending?.move(by:CGPoint(x:700,y:300)); b.model.notify(old.union(b.model.pending!.bounds))
        let refreshed=expectation(description:"coalesced minimap refresh")
        DispatchQueue.main.async {
            do { let updated=try thumbnail(); XCTAssertNotEqual(before,updated) }
            catch { XCTFail(error.localizedDescription) }
            refreshed.fulfill()
        }
        wait(for:[refreshed],timeout:2)
        XCTAssertTrue(b.model.state.layers[0].raster.tiles.isEmpty); b.model.cancel()
    }
}
