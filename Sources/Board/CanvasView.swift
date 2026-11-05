import AppKit

class CanvasView: NSView {
    let model: BoardModel
    weak var controller: BoardWindow?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var pointer = CGPoint.zero
    var crosshair = false
    var trackingCrosshair = true
    var frozenPoint = CGPoint.zero
    private var track: NSTrackingArea?
    private enum Drag { case none, draw, move, resizeObject, select, expand, pixel }
    private var drag = Drag.none
    private var start = CGPoint.zero
    private var previous = CGPoint.zero
    private var rawPointer = CGPoint.zero
    private(set) var snapping = false
    private var originalFrame = CGRect.zero
    private var initialCanvas = CGSize.zero
    private var dirtyError: String?
    private var panStart=CGPoint.zero
    private var panOrigin=CGPoint.zero
    private(set) var resizePreview: CGSize?
    var pixelEditing: Bool { zoom >= 8 }
    var showObjectOutline: Bool { drag != .draw }

    init(model: BoardModel) {
        self.model=model; super.init(frame:CGRect(origin:.zero,size:CGSize(width:model.state.size.width+20,height:model.state.size.height+20)))
        registerForDraggedTypes([.fileURL,.tiff,.png])
        setAccessibilityElement(true); setAccessibilityLabel("画布"); setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let track { removeTrackingArea(track) }
        track=NSTrackingArea(rect:.zero,options:[.mouseMoved,.activeInKeyWindow,.inVisibleRect,.mouseEnteredAndExited],owner:self)
        addTrackingArea(track!)
    }
    func syncSize() {
        let size=CGSize(width:model.state.size.width+20,height:model.state.size.height+20)
        if frame.size != size { setFrameSize(size) }
    }
    var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }

    override func draw(_ dirtyRect: NSRect) {
        guard let c=NSGraphicsContext.current?.cgContext else { return }
        NSColor.windowBackgroundColor.setFill(); dirtyRect.fill()
        let rect=dirtyRect.intersection(model.state.rect)
        guard !rect.isNull else { drawEdge(on:c); return }
        c.saveGState(); c.clip(to:model.state.rect)
        c.interpolationQuality=zoom >= 1 ? .none:.high
        c.setFillColor(NSColor.white.cgColor); c.fill(rect)
        let checker: CGFloat=12
        c.setFillColor(NSColor(white:0.91,alpha:1).cgColor)
        for y in Int(floor(rect.minY/checker))...Int(ceil(rect.maxY/checker)) {
            for x in Int(floor(rect.minX/checker))...Int(ceil(rect.maxX/checker)) where (x+y)%2 == 0 { c.fill(CGRect(x:CGFloat(x)*checker,y:CGFloat(y)*checker,width:checker,height:checker)) }
        }
        do {
            try model.state.draw(on:c,region:rect,pending:model.pending)
            dirtyError=nil
        } catch {
            let message=error.localizedDescription
            if dirtyError != message { dirtyError=message; DispatchQueue.main.async { [weak self] in self?.controller?.show(error) } }
        }
        c.restoreGState(); drawEdge(on:c)
    }
    private func drawEdge(on c: CGContext) {
        c.setStrokeColor(NSColor.separatorColor.cgColor); c.setLineWidth(1/zoom); c.stroke(model.state.rect)
        c.setFillColor(NSColor.controlAccentColor.cgColor)
        let s=model.state.size, n=6/zoom
        for p in [CGPoint(x:s.width,y:s.height/2),CGPoint(x:s.width/2,y:s.height),CGPoint(x:s.width,y:s.height)] {
            c.fill(CGRect(x:p.x-n/2,y:p.y-n/2,width:n,height:n))
        }
    }
    private func aligned(_ point: CGPoint) -> CGPoint {
        guard snapping else { return point }
        let step=CGFloat(controller?.snapStep ?? 10)
        return CGPoint(x:(point.x/step).rounded()*step,y:(point.y/step).rounded()*step)
    }
    private func position(_ event: NSEvent) -> CGPoint {
        rawPointer=convert(event.locationInWindow,from:nil)
        snapping=event.modifierFlags.contains(.shift)
        return aligned(rawPointer)
    }
    func snapSpacingChanged() {
        pointer=aligned(rawPointer); controller?.crosshairOverlay.update()
    }
    override func flagsChanged(with event: NSEvent) {
        snapping=event.modifierFlags.contains(.shift)
        snapSpacingChanged(); controller?.updateStatus()
    }
    override func mouseMoved(with event: NSEvent) {
        pointer=position(event); controller?.crosshairOverlay.update()
        controller?.updateStatus()
    }
    override func mouseDown(with event: NSEvent) {
        guard controller?.busy != true else { return }
        window?.makeFirstResponder(self)
        start=position(event); previous=start; pointer=start
        controller?.crosshairOverlay.update()
        let hit=convert(event.locationInWindow,from:nil)
        let s=model.state.size
        if hit.x >= s.width-3/zoom || hit.y >= s.height-3/zoom {
            do { try model.bake(); drag = .expand; start=hit; initialCanvas=s; resizePreview=s; originalFrame=CGRect(x:0,y:0,width:hit.x >= s.width-3/zoom ? 1:0,height:hit.y >= s.height-3/zoom ? 1:0); controller?.crosshairOverlay.updateGuides() } catch { controller?.show(error) }; return
        }
        guard model.state.rect.contains(hit), let controller else { return }
        let editingPixels=pixelEditing && (controller.tool == .brush || controller.tool == .eraser)
        if let object=model.pending, !editingPixels, !object.startsNextStroke(using:controller.tool) {
            let handle=CGRect(x:object.frame.maxX-8/zoom,y:object.frame.maxY-8/zoom,width:16/zoom,height:16/zoom)
            if handle.contains(hit) { drag = .resizeObject; start=hit; originalFrame=object.frame; return }
            if object.bounds.contains(hit) { drag = .move; start=hit; originalFrame=object.frame; return }
        }
        do {
            try model.bake(); model.selection=nil
            if controller.tool != .select { controller.rememberCurrentColor() }
            if editingPixels {
                drag = .pixel
                try model.pixel(at:start,color:controller.color,continuing:false,erase:controller.tool == .eraser)
                controller.crosshairOverlay.updateGuides(); return
            }
            switch controller.tool {
            case .select: drag = .select; model.selection=CGRect(origin:start,size:.zero); controller.crosshairOverlay.updateGuides()
            case .text:
                _=try model.editable()
                let text=controller.textValue.isEmpty ? "文字" : controller.textValue
                let font=NSFont(name:controller.fontName,size:controller.fontSize) ?? .systemFont(ofSize:controller.fontSize)
                let size=(text as NSString).size(withAttributes:[.font:font])
                drag = .none
                model.startObject(EditableObject(tool:.text,frame:CGRect(origin:start,size:CGSize(width:max(40,size.width+8),height:max(controller.fontSize*1.5,size.height+8))),color:controller.color,lineWidth:controller.lineWidth,text:text,fontName:controller.fontName,fontSize:controller.fontSize,layerID:model.state.activeID))
            default:
                _=try model.editable()
                drag = .draw
                model.startObject(EditableObject(tool:controller.tool,points:[start],frame:CGRect(origin:start,size:CGSize(width:1,height:1)),color:controller.color,lineWidth:controller.lineWidth,filled:controller.filled,layerID:model.state.activeID,freehand:controller.tool == .brush || controller.tool == .eraser))
            }
        } catch { drag = .none; controller.show(error) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard controller?.busy != true else { return }
        let p=position(event); pointer=p
        do {
            switch drag {
            case .draw:
                guard var object=model.pending else { return }
                let old=object.bounds
                if object.tool == .brush || object.tool == .eraser {
                    let d=hypot(p.x-previous.x,p.y-previous.y)
                    guard d >= 0.35/max(zoom,0.1) else { return }
                    object.points.append(p); object.frame=Geometry.bounds(object.points)
                    // Only the newest segment is invalidated while a stroke grows.
                    let segment=Geometry.bounds([previous,p]).insetBy(dx:-object.lineWidth*2,dy:-object.lineWidth*2)
                    model.pending=object; model.notify(segment)
                } else {
                    object.points=[start,p]; object.frame=Geometry.bounds([start,p]); model.pending=object; model.notify(old.union(object.bounds))
                }
            case .move:
                guard var object=model.pending else { return }
                let old=object.bounds
                let origin=aligned(CGPoint(x:originalFrame.minX+rawPointer.x-start.x,y:originalFrame.minY+rawPointer.y-start.y))
                object.move(by:CGPoint(x:origin.x-object.frame.minX,y:origin.y-object.frame.minY)); model.pending=object; model.notify(old.union(object.bounds))
            case .resizeObject:
                guard var object=model.pending else { return }
                let old=object.bounds
                let end=aligned(CGPoint(x:originalFrame.maxX+rawPointer.x-start.x,y:originalFrame.maxY+rawPointer.y-start.y))
                object.resize(to:CGRect(x:originalFrame.minX,y:originalFrame.minY,width:max(1,end.x-originalFrame.minX),height:max(1,end.y-originalFrame.minY)))
                model.pending=object; model.notify(old.union(object.bounds))
            case .select:
                model.selection=Geometry.bounds([start,p]).intersection(model.state.rect).integral; controller?.crosshairOverlay.updateGuides()
            case .expand:
                let target=aligned(CGPoint(x:initialCanvas.width+rawPointer.x-start.x,y:initialCanvas.height+rawPointer.y-start.y))
                let w=originalFrame.width > 0 ? max(1,target.x):initialCanvas.width
                let h=originalFrame.height > 0 ? max(1,target.y):initialCanvas.height
                resizePreview=CGSize(width:ceil(w),height:ceil(h)); controller?.crosshairOverlay.updateGuides()
                controller?.status.stringValue="画布 \(Int(w)) × \(Int(h)) · 松开确认，缩小会裁切所有层"
            case .pixel:
                // Interpolate mouse samples so a fast drag cannot leave gaps in a pixel stroke.
                let count=max(1,Int(max(abs(p.x-previous.x),abs(p.y-previous.y))))
                for i in 1...count { let t=CGFloat(i)/CGFloat(count); try model.pixel(at:CGPoint(x:previous.x+(p.x-previous.x)*t,y:previous.y+(p.y-previous.y)*t),color:controller?.color ?? .black,continuing:true,erase:controller?.tool == .eraser) }
            case .none: break
            }
        } catch { controller?.show(error); drag = .none }
        previous=p; controller?.crosshairOverlay.update()
        if drag != .expand { controller?.updateStatus(); autoscroll(with:event) }
    }
    override func mouseUp(with event: NSEvent) {
        // The release can carry a final position or modifier change without a drag event.
        if drag != .none {
            mouseDragged(with:event)
        }
        let finishedDrawing = drag == .draw
        let finishedPixels = drag == .pixel
        if drag == .draw, controller?.geometryMode == true, model.pending?.tool == .brush, let pending=model.pending {
            model.pending=Geometry.recognize(pending); model.notify(pending.bounds.union(model.pending!.bounds))
        }
        if drag == .expand {
            if let resizePreview { do { try model.resize(resizePreview) } catch { controller?.show(error) } }
            resizePreview=nil; syncSize(); needsDisplay=true
        }
        drag = .none
        if finishedDrawing, let pending=model.pending { model.notify(pending.bounds) }
        if finishedPixels { controller?.refreshLayerPanel() }
        controller?.crosshairOverlay.updateGuides()
        controller?.updateStatus()
    }
    override func keyDown(with event: NSEvent) {
        guard controller?.busy != true else { return }
        if controller?.handleShortcut(event) == true { return }
        switch event.keyCode {
        case 36,76: do { try model.bake() } catch { controller?.show(error) }
        case 53:
            if drag == .expand { drag = .none; resizePreview=nil; controller?.crosshairOverlay.updateGuides() }
            else { model.cancel() }
        case 51,117:
            if model.pending != nil { model.cancel() }
            else { do { _=try model.cut(currentOnly:event.modifierFlags.contains(.shift)) } catch { controller?.show(error) } }
        case 123,124,125,126:
            guard var object=model.pending else { return }
            let step: CGFloat=event.modifierFlags.contains(.shift) ? CGFloat(controller?.snapStep ?? 10):1
            let d=CGPoint(x:event.keyCode == 123 ? -step:event.keyCode == 124 ? step:0,y:event.keyCode == 126 ? -step:event.keyCode == 125 ? step:0)
            let old=object.bounds; object.move(by:d); model.pending=object; model.notify(old.union(object.bounds))
        default: super.keyDown(with:event)
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if controller?.handleShortcut(event) == true { return true }
        return super.performKeyEquivalent(with:event)
    }
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { super.scrollWheel(with:event); return }
        zoomByScroll(event.scrollingDeltaY,at:convert(event.locationInWindow,from:nil))
    }
    func zoomByScroll(_ delta: CGFloat, at point: CGPoint) {
        guard let scroll=enclosingScrollView else { return }
        scroll.setMagnification(min(scroll.maxMagnification,max(scroll.minMagnification,zoom*exp(delta*0.03))),centeredAt:point)
        needsDisplay=true; controller?.rulersChanged()
    }
    override func rightMouseDown(with event: NSEvent) {
        panStart=event.locationInWindow; panOrigin=enclosingScrollView?.contentView.bounds.origin ?? .zero
    }
    override func rightMouseDragged(with event: NSEvent) {
        guard let scroll=enclosingScrollView else { return }
        let p=event.locationInWindow
        let target=CGPoint(x:panOrigin.x-(p.x-panStart.x)/zoom,y:panOrigin.y+(p.y-panStart.y)/zoom)
        let rect=CGRect(origin:target,size:scroll.contentView.bounds.size)
        scroll.contentView.scroll(to:scroll.contentView.constrainBoundsRect(rect).origin); scroll.reflectScrolledClipView(scroll.contentView)
        controller?.rulersChanged()
    }
    override func rightMouseUp(with event: NSEvent) {}
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p=convert(sender.draggingLocation,from:nil)
        return controller?.receiveDrop(sender.draggingPasteboard,layerID:model.state.activeID,point:p) ?? false
    }
}

final class BoardRuler: NSView {
    weak var canvas: CanvasView?
    var vertical = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        guard let canvas,let c=NSGraphicsContext.current?.cgContext else { return }
        let unit=CGFloat(canvas.controller?.snapStep ?? 10)
        var labelStep=unit
        while labelStep*canvas.zoom < 55 { labelStep *= 2 }
        let first=canvas.convert(CGPoint.zero,from:self), last=canvas.convert(CGPoint(x:bounds.maxX,y:bounds.maxY),from:self)
        let lo=vertical ? first.y:first.x, hi=vertical ? last.y:last.x
        guard hi > lo else { return }
        // The ruler can omit crowded labels while snapping remains tied to the configured image-pixel unit.
        let minor=unit/5*canvas.zoom >= 5 ? unit/5:unit*canvas.zoom >= 5 ? unit:labelStep
        let begin=Int(floor(lo/minor)), end=Int(ceil(hi/minor))
        c.setStrokeColor(NSColor.secondaryLabelColor.cgColor); c.setLineWidth(1)
        for i in begin...end {
            let value=CGFloat(i)*minor
            guard value >= 0 else { continue }
            let at=convert(CGPoint(x:value,y:value),from:canvas)
            let major=abs((value/unit).rounded()-value/unit)<0.001
            let label=abs((value/labelStep).rounded()-value/labelStep)<0.001
            if vertical {
                c.move(to:CGPoint(x:0,y:at.y)); c.addLine(to:CGPoint(x:major ? 9:5,y:at.y))
                if label { ("\(Int(value))" as NSString).draw(at:CGPoint(x:9,y:at.y+1),withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:8,weight:.regular),.foregroundColor:NSColor.secondaryLabelColor]) }
            } else {
                c.move(to:CGPoint(x:at.x,y:bounds.maxY)); c.addLine(to:CGPoint(x:at.x,y:bounds.maxY-(major ? 9:5)))
                if label { ("\(Int(value))" as NSString).draw(at:CGPoint(x:at.x+2,y:1),withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:9,weight:.regular),.foregroundColor:NSColor.secondaryLabelColor]) }
            }
        }
        c.strokePath()
    }
}
