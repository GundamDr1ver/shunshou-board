import AppKit

final class ColorHistory {
    private let defaults: UserDefaults
    private(set) var colors: [RGBA]
    init(defaults: UserDefaults) {
        self.defaults=defaults
        colors=(defaults.data(forKey:"recentColors").flatMap { try? JSONDecoder().decode([RGBA].self,from:$0) } ?? []).filter {
            [$0.r,$0.g,$0.b,$0.a].allSatisfy { $0.isFinite && (0...1).contains($0) }
        }
        colors=Array(colors.prefix(12))
    }
    @discardableResult func record(_ color: RGBA) -> Bool {
        guard colors.first != color else { return false }
        colors.removeAll { $0 == color }; colors.insert(color,at:0); colors=Array(colors.prefix(12))
        defaults.set(try? JSONEncoder().encode(colors),forKey:"recentColors"); return true
    }
}

final class ColorSwatch: NSButton {
    var color=RGBA.clear
    override func draw(_ dirtyRect: NSRect) {
        let rect=bounds.insetBy(dx:2,dy:2)
        NSColor.white.setFill(); NSBezierPath(roundedRect:rect,xRadius:3,yRadius:3).fill()
        color.ns.setFill(); NSBezierPath(roundedRect:rect,xRadius:3,yRadius:3).fill()
        NSColor.separatorColor.setStroke(); NSBezierPath(roundedRect:rect,xRadius:3,yRadius:3).stroke()
    }
}

final class LayerNameField: NSTextField {
    private var tracking: NSTrackingArea?
    private var work: DispatchWorkItem?
    private var popover: NSPopover?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInActiveApp,.inVisibleRect],owner:self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) {
        guard attributedStringValue.size().width > bounds.width else { return }
        work?.cancel()
        let task=DispatchWorkItem { [weak self] in
            guard let self, self.window != nil else { return }
            let label=NSTextField(wrappingLabelWithString:self.stringValue)
            label.font = .systemFont(ofSize:12)
            let height=(self.stringValue as NSString).boundingRect(with:CGSize(width:260,height:CGFloat.greatestFiniteMagnitude),options:.usesLineFragmentOrigin,attributes:[.font:label.font!]).height
            let content=NSViewController(); content.view=NSView(frame:CGRect(x:0,y:0,width:280,height:min(240,max(40,height+20))))
            label.frame=content.view.bounds.insetBy(dx:10,dy:10); content.view.addSubview(label)
            let popup=NSPopover(); popup.behavior = .transient; popup.contentViewController=content
            self.popover=popup; popup.show(relativeTo:self.bounds,of:self,preferredEdge:.minX)
        }
        work=task; DispatchQueue.main.asyncAfter(deadline:.now()+0.25,execute:task)
    }
    override func mouseExited(with event: NSEvent) { work?.cancel(); popover?.close(); popover=nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { work?.cancel(); popover?.close() } }
}
