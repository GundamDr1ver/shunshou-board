import AppKit
import QuartzCore

final class CrosshairOverlay: NSView {
    weak var canvas: CanvasView?
    let horizontal=CALayer(), vertical=CALayer()
    let grid=CAShapeLayer(), selection=CAShapeLayer(), objectOutline=CAShapeLayer(), objectHandle=CAShapeLayer(), resizeOutline=CAShapeLayer()
    private var gridClip=CGRect.null
    private var gridZoom: CGFloat=0
    private var gridSize=CGSize.zero
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame:frame)
        wantsLayer=true; layer?.isGeometryFlipped=true
        layer?.masksToBounds=true
        for shape in [grid,selection,objectOutline,objectHandle,resizeOutline] {
            shape.fillColor=nil; shape.strokeColor=NSColor.controlAccentColor.cgColor
            shape.lineWidth=1; layer?.addSublayer(shape)
        }
        grid.strokeColor=NSColor.black.withAlphaComponent(0.16).cgColor
        selection.lineDashPattern=[4,3]; objectOutline.lineDashPattern=[4,3]; resizeOutline.lineDashPattern=[6,4]
        objectHandle.fillColor=NSColor.controlAccentColor.cgColor
        for line in [horizontal,vertical] {
            line.backgroundColor=NSColor.systemPink.withAlphaComponent(0.8).cgColor
            layer?.addSublayer(line)
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); update(); updateGuides() }

    func update() {
        guard let canvas, let clip=canvas.enclosingScrollView?.contentView else { return }
        let point=canvas.trackingCrosshair ? canvas.pointer:canvas.frozenPoint
        let area=convert(clip.bounds,from:clip).intersection(convert(canvas.model.state.rect,from:canvas)).intersection(bounds)
        let position=convert(point,from:canvas)
        let hidden = !canvas.crosshair || area.isNull || !area.contains(position)
        // The overlay is viewport-sized; moving its two lines never invalidates image pixels.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        horizontal.isHidden=hidden; vertical.isHidden=hidden
        if !hidden {
            horizontal.frame=CGRect(x:area.minX,y:position.y,width:area.width,height:1)
            vertical.frame=CGRect(x:position.x,y:area.minY,width:1,height:area.height)
        }
        CATransaction.commit()
    }

    func updateGuides() {
        guard let canvas, let clip=canvas.enclosingScrollView?.contentView else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        let visible=convert(clip.bounds,from:clip).intersection(bounds)
        let scale=window?.backingScaleFactor ?? 2
        for shape in [grid,selection,objectOutline,objectHandle,resizeOutline] { shape.contentsScale=scale }
        for shape in [selection,objectOutline,objectHandle,resizeOutline] { shape.frame=bounds }
        if gridClip != clip.bounds || gridZoom != canvas.zoom || gridSize != canvas.model.state.size || grid.frame != bounds {
            gridClip=clip.bounds; gridZoom=canvas.zoom; gridSize=canvas.model.state.size
            grid.frame=bounds
            let area=visible.intersection(convert(canvas.model.state.rect,from:canvas))
            let path=CGMutablePath()
            if canvas.pixelEditing && !area.isNull {
                let source=canvas.convert(area,from:self)
                func aligned(_ value: CGFloat) -> CGFloat { (value*scale).rounded()/scale+0.5/scale }
                for x in Int(floor(source.minX))...Int(ceil(source.maxX)) {
                    let at=aligned(convert(CGPoint(x:CGFloat(x),y:source.minY),from:canvas).x)
                    path.move(to:CGPoint(x:at,y:area.minY)); path.addLine(to:CGPoint(x:at,y:area.maxY))
                }
                for y in Int(floor(source.minY))...Int(ceil(source.maxY)) {
                    let at=aligned(convert(CGPoint(x:source.minX,y:CGFloat(y)),from:canvas).y)
                    path.move(to:CGPoint(x:area.minX,y:at)); path.addLine(to:CGPoint(x:area.maxX,y:at))
                }
            }
            grid.lineWidth=1/scale; grid.path=path
        }
        selection.path=canvas.model.selection.map { CGPath(rect:convert($0,from:canvas),transform:nil) }
        let object=canvas.showObjectOutline ? canvas.model.pending:nil
        objectOutline.path=object.map { CGPath(rect:convert($0.frame,from:canvas),transform:nil) }
        objectHandle.path=object.map {
            let p=convert(CGPoint(x:$0.frame.maxX,y:$0.frame.maxY),from:canvas)
            return CGPath(rect:CGRect(x:p.x-3.5,y:p.y-3.5,width:7,height:7),transform:nil)
        }
        resizeOutline.path=canvas.resizePreview.map { CGPath(rect:convert(CGRect(origin:.zero,size:$0),from:canvas),transform:nil) }
    }
}
