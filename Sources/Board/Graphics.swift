import AppKit
import ImageIO
import UniformTypeIdentifiers

struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double
    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
    static let black = RGBA(r: 0.12, g: 0.14, b: 0.18, a: 1)
    var cg: CGColor { CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[r,g,b,a])! }
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }
}

enum BoardError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

func bitmapContext(_ width: Int, _ height: Int) throws -> CGContext {
    guard width > 0, height > 0,
          let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw BoardError.invalid("无法分配图像内存，请缩小操作范围或释放内存。")
    }
    c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
    return c
}

func drawImage(_ image: CGImage, in rect: CGRect, on c: CGContext) {
    c.saveGState(); c.translateBy(x: rect.minX, y: rect.maxY); c.scaleBy(x: 1, y: -1)
    c.draw(image, in: CGRect(origin: .zero, size: rect.size)); c.restoreGState()
}

func readImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: false] as CFDictionary) else {
        throw BoardError.invalid("无法读取图片：\(url.lastPathComponent)")
    }
    let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any]
    if let orientation=properties?[kCGImagePropertyOrientation] as? Int, orientation != 1 {
        let options: [CFString:Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:max(image.width,image.height),kCGImageSourceCreateThumbnailWithTransform:true]
        guard let upright=CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else { throw BoardError.invalid("无法解析图片方向。") }
        return upright
    }
    return image
}

func imageData(_ image: CGImage, type: UTType = .png) throws -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw BoardError.invalid("无法创建图像编码器。") }
    CGImageDestinationAddImage(dest, image, type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary : nil)
    guard CGImageDestinationFinalize(dest) else { throw BoardError.invalid("图像编码失败。") }
    return data as Data
}

enum Tool: String, CaseIterable {
    case select, brush, eraser, line, arrow, rectangle, ellipse, triangle, text
    var title: String {
        switch self {
        case .select: return "框选"; case .brush: return "画笔"; case .eraser: return "橡皮"
        case .line: return "直线"; case .arrow: return "箭头"; case .rectangle: return "矩形"
        case .ellipse: return "圆形"; case .triangle: return "三角"; case .text: return "文字"
        }
    }
    var symbol: String {
        switch self {
        case .select: return "selection.pin.in.out"; case .brush: return "pencil.tip"; case .eraser: return "eraser"
        case .line: return "line.diagonal"; case .arrow: return "arrow.up.right"; case .rectangle: return "rectangle"
        case .ellipse: return "circle"; case .triangle: return "triangle"; case .text: return "textformat"
        }
    }
}

struct EditableObject {
    var tool: Tool
    var points: [CGPoint] = []
    var frame: CGRect
    var color: RGBA
    var lineWidth: CGFloat
    var filled = false
    var text = ""
    var fontName = "Helvetica"
    var fontSize: CGFloat = 28
    var image: CGImage?
    var layerID: UUID
    var cutouts: [CGRect] = []
    var freehand = false

    func startsNextStroke(using tool: Tool) -> Bool {
        (tool == .brush || tool == .eraser) && (freehand || self.tool == .brush || self.tool == .eraser)
    }

    var bounds: CGRect { frame.insetBy(dx: -max(lineWidth, 2) * 3, dy: -max(lineWidth, 2) * 3) }
    mutating func move(by d: CGPoint) {
        frame.origin.x += d.x; frame.origin.y += d.y; points = points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        cutouts=cutouts.map { $0.offsetBy(dx:d.x,dy:d.y) }
    }
    mutating func resize(to rect: CGRect) {
        let old = frame
        if old.width > 0 && old.height > 0 {
            points = points.map { CGPoint(x: rect.minX + ($0.x - old.minX) * rect.width / old.width, y: rect.minY + ($0.y - old.minY) * rect.height / old.height) }
            cutouts=cutouts.map { CGRect(x:rect.minX+($0.minX-old.minX)*rect.width/old.width,y:rect.minY+($0.minY-old.minY)*rect.height/old.height,width:$0.width*rect.width/old.width,height:$0.height*rect.height/old.height) }
        }
        frame = rect
    }
    func draw(on c: CGContext) {
        c.saveGState(); defer { c.restoreGState() }
        for hole in cutouts {
            let clipped=hole.intersection(bounds)
            if !clipped.isNull { c.beginPath(); c.addRect(bounds); c.addRect(clipped); c.clip(using:.evenOdd) }
        }
        c.setStrokeColor(color.cg); c.setFillColor(color.cg); c.setLineWidth(lineWidth); c.setLineCap(.round); c.setLineJoin(.round)
        if let image { drawImage(image, in: frame, on: c); return }
        if tool == .text {
            let gc = NSGraphicsContext(cgContext: c, flipped: true)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
            (text as NSString).draw(in: frame, withAttributes: [.font: NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize), .foregroundColor: color.ns])
            NSGraphicsContext.restoreGraphicsState(); return
        }
        switch tool {
        case .brush, .eraser:
            if tool == .eraser { c.setBlendMode(.clear) }
            let hardPixel=lineWidth == 1
            if hardPixel { c.setShouldAntialias(false) }
            let strokePoints=hardPixel ? points.map { CGPoint(x:floor($0.x)+0.5,y:floor($0.y)+0.5) }:points
            if strokePoints.count == 1, let p=strokePoints.first {
                let rect=CGRect(x:p.x-lineWidth/2,y:p.y-lineWidth/2,width:lineWidth,height:lineWidth)
                if hardPixel { c.fill(rect) } else { c.fillEllipse(in:rect) }; return
            }
            guard let first=strokePoints.first else { return }
            c.beginPath(); c.move(to:first); for p in strokePoints.dropFirst() { c.addLine(to:p) }; c.strokePath()
        case .line, .arrow:
            let a = points.first ?? frame.origin, b = points.last ?? CGPoint(x: frame.maxX, y: frame.maxY)
            c.move(to: a); c.addLine(to: b); c.strokePath()
            if tool == .arrow {
                let angle = atan2(b.y-a.y, b.x-a.x), length = max(12, lineWidth*4)
                c.move(to: CGPoint(x: b.x-length*cos(angle-0.5), y: b.y-length*sin(angle-0.5))); c.addLine(to: b)
                c.addLine(to: CGPoint(x: b.x-length*cos(angle+0.5), y: b.y-length*sin(angle+0.5))); c.strokePath()
            }
        case .rectangle: c.addRect(frame); c.drawPath(using: filled ? .fillStroke : .stroke)
        case .ellipse: c.addEllipse(in: frame); c.drawPath(using: filled ? .fillStroke : .stroke)
        case .triangle:
            c.move(to: CGPoint(x: frame.midX, y: frame.minY)); c.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY)); c.addLine(to: CGPoint(x: frame.minX, y: frame.maxY)); c.closePath(); c.drawPath(using: filled ? .fillStroke : .stroke)
        default: break
        }
    }
}

enum Geometry {
    static func bounds(_ p: [CGPoint]) -> CGRect {
        guard let first = p.first else { return .zero }
        var x0 = first.x, x1 = first.x, y0 = first.y, y1 = first.y
        for v in p { x0 = min(x0,v.x); x1 = max(x1,v.x); y0 = min(y0,v.y); y1 = max(y1,v.y) }
        return CGRect(x: x0, y: y0, width: max(1,x1-x0), height: max(1,y1-y0))
    }
    static func recognize(_ input: EditableObject) -> EditableObject {
        let p = input.points
        guard p.count >= 6, let a = p.first, let b = p.last else { return input }
        var result = input
        let box = bounds(p), diagonal = hypot(box.width,box.height)
        guard diagonal > 12 else { return input }
        let distance = hypot(b.x-a.x,b.y-a.y)
        let length = zip(p,p.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x-$1.0.x,$1.1.y-$1.0.y) }
        if distance > diagonal * 0.75 && length / max(distance,1) < 1.12 {
            result.tool = .line; result.points = [a,b]; result.frame = box; return result
        }
        guard distance < diagonal * 0.22 else { return input }
        let center = CGPoint(x: box.midX,y: box.midY)
        let radii = p.map { hypot(($0.x-center.x)/(box.width/2), ($0.y-center.y)/(box.height/2)) }
        let radialError = radii.reduce(0) { $0 + abs($1-1) } / CGFloat(radii.count)
        if radialError < 0.13 && box.width/box.height > 0.72 && box.width/box.height < 1.38 {
            let side = (box.width+box.height)/2
            result.tool = .ellipse; result.frame = CGRect(x:center.x-side/2,y:center.y-side/2,width:side,height:side); result.points=[]; return result
        }
        // Closed strokes are simplified before classifying corners, so an arbitrary scribble stays a stroke.
        let simplified = simplify(p, tolerance: diagonal * 0.055)
        var vertices = simplified
        if vertices.count > 1 && hypot(vertices[0].x-vertices.last!.x,vertices[0].y-vertices.last!.y) < diagonal*0.22 { vertices.removeLast() }
        if vertices.count == 4 {
            let cornerError = vertices.reduce(CGFloat(0)) { sum,v in
                sum + min(abs(v.x-box.minX),abs(v.x-box.maxX)) + min(abs(v.y-box.minY),abs(v.y-box.maxY))
            } / (4*diagonal)
            if cornerError < 0.1 { result.tool = .rectangle; result.frame=box; result.points=[]; return result }
        }
        if vertices.count == 3 {
            let area = abs(vertices[0].x*(vertices[1].y-vertices[2].y)+vertices[1].x*(vertices[2].y-vertices[0].y)+vertices[2].x*(vertices[0].y-vertices[1].y))/2
            if area > box.width*box.height*0.25 { result.tool = .triangle; result.frame=box; result.points=[]; return result }
        }
        return input
    }
    private static func simplify(_ p: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard p.count > 2 else { return p }
        let a=p.first!, b=p.last!, d=hypot(b.x-a.x,b.y-a.y)
        var far: CGFloat=0, index=0
        for i in 1..<p.count-1 {
            let v=p[i]
            let distance = d < 0.001 ? hypot(v.x-a.x,v.y-a.y) : abs((b.x-a.x)*(a.y-v.y)-(a.x-v.x)*(b.y-a.y))/d
            if distance > far { far=distance; index=i }
        }
        if far <= tolerance { return [a,b] }
        return Array(simplify(Array(p[...index]),tolerance:tolerance).dropLast()) + simplify(Array(p[index...]),tolerance:tolerance)
    }
}
