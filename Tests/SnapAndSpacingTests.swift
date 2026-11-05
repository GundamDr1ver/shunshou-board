import AppKit
import XCTest
@testable import Board

final class SnapAndSpacingTests: XCTestCase {
    private func board(_ tool: Tool) -> BoardWindow {
        _=NSApplication.shared; let b=BoardWindow()
        b.toolControl.selectedSegment=Tool.allCases.firstIndex(of:tool)!
        b.window?.contentView?.layoutSubtreeIfNeeded(); return b
    }
    private func mouse(_ b: BoardWindow,_ type: NSEvent.EventType,_ point: CGPoint,_ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:b.canvas.convert(point,to:nil),modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:b.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
    }

    func testSnapFieldDoesNotChangeObjectStyleAndRefreshesFeedback() {
        let b=board(.rectangle), blue=RGBA(r:0,g:0,b:1,a:1)
        b.model.startObject(EditableObject(tool:.rectangle,frame:CGRect(x:10,y:10,width:40,height:40),color:blue,lineWidth:8,layerID:b.model.state.activeID))
        b.snapField.integerValue=40; b.settingsChanged(b.snapField)
        XCTAssertEqual(b.model.pending?.lineWidth,8); XCTAssertEqual(b.model.pending?.color,blue)
        XCTAssertTrue(b.status.stringValue.contains("吸附 40 px"))
        b.model.cancel()
    }

    func testReleaseWithShiftUsesFinalSnappedEndpointAtDifferentSteps() throws {
        for (step,expected) in [(10,CGPoint(x:240,y:210)),(40,CGPoint(x:240,y:200))] {
            let b=board(.line); b.snapField.integerValue=step
            b.canvas.mouseDown(with:mouse(b,.leftMouseDown,CGPoint(x:103,y:107)))
            b.canvas.mouseDragged(with:mouse(b,.leftMouseDragged,CGPoint(x:232,y:212)))
            b.canvas.mouseUp(with:mouse(b,.leftMouseUp,CGPoint(x:236,y:214),.shift))
            XCTAssertEqual(b.model.pending?.points.last,expected)
            b.model.cancel()
        }
        let b=board(.select); b.snapField.integerValue=25
        b.canvas.mouseDown(with:mouse(b,.leftMouseDown,CGPoint(x:33,y:37),.shift))
        b.canvas.mouseDragged(with:mouse(b,.leftMouseDragged,CGPoint(x:110,y:113)))
        b.canvas.mouseUp(with:mouse(b,.leftMouseUp,CGPoint(x:119,y:128),.shift))
        XCTAssertEqual(b.model.selection,CGRect(x:25,y:25,width:100,height:100))
    }

    func testObjectSnapUsesGrabOffsetWithoutIncrementalRoundingDrift() {
        let b=board(.select)
        b.model.startObject(EditableObject(tool:.rectangle,frame:CGRect(x:13,y:17,width:100,height:80),color:.black,lineWidth:1,layerID:b.model.state.activeID))
        b.canvas.mouseDown(with:mouse(b,.leftMouseDown,CGPoint(x:46,y:49),.shift))
        b.canvas.mouseDragged(with:mouse(b,.leftMouseDragged,CGPoint(x:86,y:89),.shift))
        b.canvas.mouseDragged(with:mouse(b,.leftMouseDragged,CGPoint(x:90,y:90),.shift))
        XCTAssertEqual(b.model.pending?.frame.origin,CGPoint(x:60,y:60))
        b.model.cancel()
    }

    func testModifierChangeUsesLastMousePositionAndNewSpacing() throws {
        let b=board(.line)
        b.canvas.mouseDown(with:mouse(b,.leftMouseDown,CGPoint(x:33,y:37)))
        b.canvas.mouseDragged(with:mouse(b,.leftMouseDragged,CGPoint(x:116,y:128)))
        let shift=try XCTUnwrap(NSEvent.keyEvent(with:.flagsChanged,location:.zero,modifierFlags:.shift,timestamp:0,windowNumber:b.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:56))
        b.canvas.flagsChanged(with:shift)
        XCTAssertEqual(b.canvas.pointer,CGPoint(x:120,y:130))
        b.snapField.integerValue=25; b.settingsChanged(b.snapField)
        XCTAssertEqual(b.canvas.pointer,CGPoint(x:125,y:125))
        b.canvas.mouseUp(with:mouse(b,.leftMouseUp,CGPoint(x:116,y:128),.shift))
        XCTAssertEqual(b.model.pending?.points.last,CGPoint(x:125,y:125))
        b.model.cancel()
    }

    func testToolbarVisibleGapsAndOuterMarginsMatch() throws {
        let b=board(.brush), content=try XCTUnwrap(b.window?.contentView)
        let root=try XCTUnwrap(content.subviews.first as? NSStackView)
        let operations=try XCTUnwrap(root.arrangedSubviews[2] as? NSStackView)
        let undo=try XCTUnwrap(operations.arrangedSubviews.first)
        let separator=try XCTUnwrap(root.arrangedSubviews[3] as? NSBox)
        let first=content.convert(b.toolControl.bounds,from:b.toolControl)
        let second=content.convert(b.widthField.bounds,from:b.widthField)
        let third=content.convert(undo.bounds,from:undo)
        let bottom=content.convert(separator.bounds,from:separator)
        XCTAssertEqual(first.minY-second.maxY,second.minY-third.maxY,accuracy:0.5)
        XCTAssertEqual(content.bounds.maxY-first.maxY,third.minY-bottom.maxY,accuracy:0.5)
        XCTAssertGreaterThan(third.minY-bottom.maxY,0)
        let rep=try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in:content.bounds))
        content.cacheDisplay(in:content.bounds,to:rep)
        let c=try bitmapContext(rep.pixelsWide,rep.pixelsHigh)
        c.setFillColor(NSColor.windowBackgroundColor.cgColor); c.fill(CGRect(x:0,y:0,width:rep.pixelsWide,height:rep.pixelsHigh))
        if let rendered=rep.cgImage { drawImage(rendered,in:CGRect(x:0,y:0,width:rep.pixelsWide,height:rep.pixelsHigh),on:c) }
        let qaDirectory=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/qa")
        try imageData(XCTUnwrap(c.makeImage())).write(to:qaDirectory.appendingPathComponent("layout-0.1.4.png"))
    }
}
