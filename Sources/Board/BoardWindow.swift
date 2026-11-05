import AppKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    static let boardLayer=NSPasteboard.PasteboardType("com.vinasky.simpleboard.layer")
}

final class BoardWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    let model=BoardModel()
    lazy var canvas=CanvasView(model:model)
    let scroll=NSScrollView()
    let crosshairOverlay=CrosshairOverlay(frame:.zero)
    let table=NSTableView()
    let status=NSTextField(labelWithString:"")
    let topRuler=BoardRuler(), rightRuler=BoardRuler()
    let toolControl=NSSegmentedControl()
    let foreground=NSColorWell()
    let background=NSColorWell()
    let opacity=NSSlider(value:1,minValue:0,maxValue:1,target:nil,action:nil)
    let backgroundAlpha=NSSlider(value:0,minValue:0,maxValue:1,target:nil,action:nil)
    let geometry=NSButton(checkboxWithTitle:"画笔几何模式",target:nil,action:nil)
    let fill=NSButton(checkboxWithTitle:"填充",target:nil,action:nil)
    let crosshairButton=NSButton(checkboxWithTitle:"十字线（⌘R 开启，⇧⌘R 停止移动）",target:nil,action:nil)
    let colorHistory: ColorHistory
    let historyRow=NSStackView()
    var selectedLayerIDs: Set<UUID>=[]
    lazy var addLayerButton=button("新建",#selector(addLayer),symbol:"plus")
    lazy var deleteLayerButton=button("删除",#selector(deleteLayer),symbol:"minus")
    lazy var duplicateLayerButton=button("复制",#selector(duplicateLayer))
    lazy var renameLayerButton=button("重命名图层",#selector(renameLayer))
    lazy var mergeLayerButton=button("合并↓",#selector(mergeLayer))
    let widthField=NSTextField(string:"4")
    let fontSizeField=NSTextField(string:"28")
    let textField=NSTextField(string:"文字")
    let snapField=NSTextField(string:"10")
    let objectWidth=NSTextField(string:""), objectHeight=NSTextField(string:"")
    var fontName="Helvetica"
    var projectURL: URL?
    var busy=false
    private var magnificationObserver: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?
    private var refreshing=false
    private var thumbnailCache: [UUID:(UUID,CGSize,NSImage)]=[:]
    private var layerRefreshPending=false
    private var storedPasteOrigin: CGPoint?
    private var storedPasteChange = -1
    private var rulerHeight: NSLayoutConstraint?
    private var rulerWidth: NSLayoutConstraint?
    var tool: Tool { Tool.allCases[max(0,toolControl.selectedSegment)] }
    var color: RGBA { RGBA(foreground.color) }
    var lineWidth: CGFloat { CGFloat(max(0.25,min(1000,widthField.doubleValue))) }
    var fontSize: CGFloat { CGFloat(max(1,min(2000,fontSizeField.doubleValue))) }
    var textValue: String { textField.stringValue }
    var geometryMode: Bool { geometry.state == .on }
    var filled: Bool { fill.state == .on }
    var snapStep: Int { max(1,Int(snapField.currentEditor()?.string ?? snapField.stringValue) ?? 1) }

    init(defaults: UserDefaults = .standard) {
        colorHistory=ColorHistory(defaults:defaults)
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:1320,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init(window:window); window.delegate=self; window.minSize=CGSize(width:1180,height:640); window.title="顺手画板"; window.acceptsMouseMovedEvents=true; window.center()
        canvas.controller=self
        buildUI(); model.changed={ [weak self] region in self?.refresh(region) }; refresh(nil)
        window.makeFirstResponder(canvas)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func button(_ title: String, _ action: Selector, symbol: String? = nil) -> NSButton {
        let b=NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded
        if let symbol { b.image=NSImage(systemSymbolName:symbol,accessibilityDescription:title); b.imagePosition = .imageLeading }
        b.toolTip=title; return b
    }
    private func row(_ items: [NSView], spacing: CGFloat=8) -> NSStackView {
        let stack=NSStackView(views:items); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing=spacing; return stack
    }
    private func fixed(_ view: NSView, width: CGFloat) -> NSView { view.widthAnchor.constraint(equalToConstant:width).isActive=true; return view }
    private func buildUI() {
        guard let content=window?.contentView else { return }
        let root=NSStackView(); root.orientation = .vertical; root.spacing=0; root.alignment = .leading; root.edgeInsets.top=10
        root.translatesAutoresizingMaskIntoConstraints=false; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:content.leadingAnchor),root.trailingAnchor.constraint(equalTo:content.trailingAnchor),root.topAnchor.constraint(equalTo:content.topAnchor),root.bottomAnchor.constraint(equalTo:content.bottomAnchor)])

        toolControl.segmentCount=Tool.allCases.count; toolControl.trackingMode = .selectOne; toolControl.segmentStyle = .rounded
        for (i,tool) in Tool.allCases.enumerated() {
            toolControl.setImage(NSImage(systemSymbolName:tool.symbol,accessibilityDescription:tool.title),forSegment:i)
            toolControl.setLabel(tool.title,forSegment:i); toolControl.setWidth(69,forSegment:i); toolControl.setToolTip(tool.title,forSegment:i)
        }
        toolControl.selectedSegment=1; toolControl.target=self; toolControl.action=#selector(toolChanged)
        geometry.target=self; geometry.action=#selector(settingsChanged)
        let tools=row([toolControl,geometry]); tools.edgeInsets=NSEdgeInsets(top:0,left:12,bottom:0,right:12)
        root.addArrangedSubview(tools)

        foreground.color=RGBA.black.ns; foreground.supportsAlpha=true; foreground.target=self; foreground.action=#selector(settingsChanged)
        foreground.setAccessibilityLabel("前景颜色"); foreground.toolTip="绘制颜色；颜色面板支持系统取色"
        fill.target=self; fill.action=#selector(settingsChanged)
        for field in [widthField,fontSizeField,textField,snapField,objectWidth,objectHeight] { field.target=self; field.action=#selector(settingsChanged); field.delegate=self }
        widthField.toolTip="笔宽（图像像素）"; fontSizeField.toolTip="字号"; snapField.toolTip="按住 Shift 吸附到大刻度，间距以图像像素为单位"
        widthField.setAccessibilityLabel("画笔宽度"); fontSizeField.setAccessibilityLabel("文字字号"); snapField.setAccessibilityLabel("吸附像素间距")
        objectWidth.setAccessibilityLabel("当前对象宽度"); objectHeight.setAccessibilityLabel("当前对象高度")
        textField.placeholderString="添加文字内容"; textField.setAccessibilityLabel("文字内容")
        historyRow.orientation = .horizontal; historyRow.spacing=4; refreshColorHistory()
        let settings=row([NSTextField(labelWithString:"笔宽"),fixed(widthField,width:44),fill,NSTextField(labelWithString:"文字"),fixed(textField,width:160),button("字体",#selector(chooseFont)),fixed(fontSizeField,width:44),NSTextField(labelWithString:"⇧吸附"),fixed(snapField,width:44),NSTextField(labelWithString:"px"),button("取色",#selector(sampleColor),symbol:"eyedropper"),NSTextField(labelWithString:"颜色"),fixed(foreground,width:42),historyRow])
        settings.edgeInsets=NSEdgeInsets(top:0,left:12,bottom:0,right:12); root.addArrangedSubview(settings)

        crosshairButton.target=self; crosshairButton.action=#selector(toggleCrosshair)
        let operations=row([button("撤销",#selector(undo(_:)),symbol:"arrow.uturn.backward"),button("重做",#selector(redo(_:)),symbol:"arrow.uturn.forward"),button("确认 ↩",#selector(confirmObject)),button("取消 Esc",#selector(cancelObject)),button("裁剪选区",#selector(cropSelection)),crosshairButton,button("−",#selector(zoomOut)),button("适合窗口",#selector(fitCanvas)),button("+",#selector(zoomIn)),NSTextField(labelWithString:"对象 W/H"),fixed(objectWidth,width:52),fixed(objectHeight,width:52)])
        operations.edgeInsets=NSEdgeInsets(top:0,left:12,bottom:0,right:12); root.addArrangedSubview(operations)
        for line in [tools,settings,operations] { line.heightAnchor.constraint(equalToConstant:28).isActive=true }
        toolControl.heightAnchor.constraint(equalToConstant:28).isActive=true
        operations.arrangedSubviews.first?.heightAnchor.constraint(equalToConstant:28).isActive=true
        root.setCustomSpacing(8,after:tools); root.setCustomSpacing(8,after:settings); root.setCustomSpacing(12,after:operations)
        root.addArrangedSubview(separator())

        scroll.documentView=canvas; scroll.hasVerticalScroller=true; scroll.hasHorizontalScroller=true; scroll.allowsMagnification=true; scroll.minMagnification=0.05; scroll.maxMagnification=64
        scroll.backgroundColor = .underPageBackgroundColor; scroll.drawsBackground=true; scroll.contentView.postsBoundsChangedNotifications=true
        topRuler.canvas=canvas; rightRuler.canvas=canvas; rightRuler.vertical=true; crosshairOverlay.canvas=canvas
        let drawing=NSView(); drawing.translatesAutoresizingMaskIntoConstraints=false
        for view in [scroll,topRuler,rightRuler,crosshairOverlay] { view.translatesAutoresizingMaskIntoConstraints=false; drawing.addSubview(view) }
        rulerHeight=topRuler.heightAnchor.constraint(equalToConstant:24); rulerWidth=rightRuler.widthAnchor.constraint(equalToConstant:46)
        NSLayoutConstraint.activate([
            topRuler.leadingAnchor.constraint(equalTo:drawing.leadingAnchor),topRuler.topAnchor.constraint(equalTo:drawing.topAnchor),topRuler.trailingAnchor.constraint(equalTo:rightRuler.leadingAnchor),rulerHeight!,
            scroll.leadingAnchor.constraint(equalTo:drawing.leadingAnchor),scroll.topAnchor.constraint(equalTo:topRuler.bottomAnchor),scroll.bottomAnchor.constraint(equalTo:drawing.bottomAnchor),scroll.trailingAnchor.constraint(equalTo:rightRuler.leadingAnchor),
            crosshairOverlay.leadingAnchor.constraint(equalTo:scroll.leadingAnchor),crosshairOverlay.topAnchor.constraint(equalTo:scroll.topAnchor),crosshairOverlay.trailingAnchor.constraint(equalTo:scroll.trailingAnchor),crosshairOverlay.bottomAnchor.constraint(equalTo:scroll.bottomAnchor),
            rightRuler.topAnchor.constraint(equalTo:scroll.topAnchor),rightRuler.trailingAnchor.constraint(equalTo:drawing.trailingAnchor),rightRuler.bottomAnchor.constraint(equalTo:drawing.bottomAnchor),rulerWidth!])

        let sidebar=buildSidebar()
        let split=NSSplitView(); split.isVertical=true; split.dividerStyle = .thin; split.addArrangedSubview(drawing); split.addArrangedSubview(sidebar)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant:240).isActive=true; sidebar.widthAnchor.constraint(lessThanOrEqualToConstant:300).isActive=true
        split.setHoldingPriority(.defaultLow,forSubviewAt:0); split.setHoldingPriority(.defaultHigh,forSubviewAt:1)
        root.addArrangedSubview(split); split.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true; split.setContentHuggingPriority(.defaultLow,for:.vertical)
        status.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); status.textColor = .secondaryLabelColor
        let bottom=row([status]); bottom.edgeInsets=NSEdgeInsets(top:7,left:12,bottom:7,right:12); root.addArrangedSubview(bottom)
        scrollObserver=NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in self?.rulersChanged() }
        magnificationObserver=NotificationCenter.default.addObserver(forName:NSScrollView.didEndLiveMagnifyNotification,object:scroll,queue:.main) { [weak self] _ in self?.rulersChanged() }
    }
    private func separator() -> NSView { let box=NSBox(); box.boxType = .separator; return box }
    private func buildSidebar() -> NSView {
        let heading=NSTextField(labelWithString:"图层"); heading.font = .boldSystemFont(ofSize:14)
        let help=NSTextField(wrappingLabelWithString:"拖拽调整层序 · ⌘点击多选\n拖入图片时悬停选层，松开切换到该层"); help.font = .systemFont(ofSize:11); help.textColor = .secondaryLabelColor
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("layer")); column.minWidth=0; column.width=216; column.resizingMask = .autoresizingMask
        table.style = .plain; table.intercellSpacing=CGSize(width:0,height:2)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.autoresizingMask = .width
        table.addTableColumn(column); table.headerView=nil; table.rowHeight=48; table.delegate=self; table.dataSource=self; table.allowsEmptySelection=false; table.allowsMultipleSelection=true
        table.registerForDraggedTypes([.boardLayer,.fileURL,.png,.tiff]); table.setDraggingSourceOperationMask(.move,forLocal:true)
        table.setAccessibilityLabel("图层列表：拖拽排序，Command 点击多选，拖入图片悬停选层")
        let list=NSScrollView(); list.documentView=table; list.hasVerticalScroller=true; list.hasHorizontalScroller=false; list.borderType = .noBorder
        let add=row([addLayerButton,deleteLayerButton,duplicateLayerButton],spacing:8); add.distribution = .fillEqually
        let below=row([renameLayerButton,mergeLayerButton],spacing:8); below.distribution = .fillEqually
        background.supportsAlpha=false; background.target=self; background.action=#selector(layerBackgroundChanged); background.setAccessibilityLabel("图层背景颜色")
        backgroundAlpha.target=self; backgroundAlpha.action=#selector(layerBackgroundChanged); backgroundAlpha.isContinuous=false; backgroundAlpha.setAccessibilityLabel("背景透明度")
        opacity.target=self; opacity.action=#selector(layerOpacityChanged); opacity.isContinuous=false; opacity.setAccessibilityLabel("整层透明度")
        let stack=NSStackView(views:[heading,help,list,add,below,separator(),row([NSTextField(labelWithString:"背景色"),fixed(background,width:44)]),NSTextField(labelWithString:"背景不透明度"),backgroundAlpha,NSTextField(labelWithString:"整层不透明度"),opacity])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing=9; stack.edgeInsets=NSEdgeInsets(top:14,left:12,bottom:16,right:12)
        for v in [help,list,add,below,backgroundAlpha,opacity] { v.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-24).isActive=true }
        list.heightAnchor.constraint(greaterThanOrEqualToConstant:120).isActive=true
        return stack
    }
    func layerAt(_ row: Int) -> Layer { model.state.layers[model.state.layers.count-1-row] }
    func numberOfRows(in tableView: NSTableView) -> Int { model.state.layers.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let layer=layerAt(row), view=NSTableCellView()
        let eye=NSButton(image:NSImage(systemSymbolName:layer.visible ? "eye":"eye.slash",accessibilityDescription:"显示或隐藏图层")!,target:self,action:#selector(toggleVisible(_:)))
        let lock=NSButton(image:NSImage(systemSymbolName:layer.locked ? "lock.fill":"lock.open",accessibilityDescription:"锁定或解锁图层")!,target:self,action:#selector(toggleLocked(_:)))
        for b in [eye,lock] { b.bezelStyle = .inline; b.tag=row; b.isBordered=false; b.isEnabled=selectedLayerIDs.count == 1; b.widthAnchor.constraint(equalToConstant:20).isActive=true; b.setContentCompressionResistancePriority(.required,for:.horizontal) }
        let thumb=NSImageView(); thumb.imageScaling = .scaleProportionallyUpOrDown; thumb.image=thumbnail(layer)
        let name=LayerNameField(labelWithString:layer.name); name.font = .systemFont(ofSize:12); name.usesSingleLineMode=true
        name.cell?.isScrollable=false; name.cell?.wraps=false; name.lineBreakMode = .byTruncatingTail; name.maximumNumberOfLines=1
        name.setContentCompressionResistancePriority(.defaultLow,for:.horizontal); name.setContentHuggingPriority(.defaultLow,for:.horizontal)
        name.widthAnchor.constraint(greaterThanOrEqualToConstant:0).isActive=true
        for control in [eye,thumb,name,lock] {
            control.translatesAutoresizingMaskIntoConstraints=false; view.addSubview(control)
            control.centerYAnchor.constraint(equalTo:view.centerYAnchor).isActive=true
        }
        NSLayoutConstraint.activate([
            eye.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:3),
            thumb.leadingAnchor.constraint(equalTo:eye.trailingAnchor,constant:6),thumb.widthAnchor.constraint(equalToConstant:38),thumb.heightAnchor.constraint(equalToConstant:34),
            name.leadingAnchor.constraint(equalTo:thumb.trailingAnchor,constant:6),name.trailingAnchor.constraint(equalTo:lock.leadingAnchor,constant:-6),
            lock.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-3)])
        return view
    }
    private func thumbnail(_ layer: Layer) -> NSImage? {
        let pending=model.pending?.layerID == layer.id ? model.pending:nil
        if pending == nil, let cache=thumbnailCache[layer.id], cache.0 == layer.revision, cache.1 == model.state.size { return cache.2 }
        if !layer.visible && layer.raster.source != nil { return NSImage(systemSymbolName:"photo",accessibilityDescription:"隐藏图层") }
        do {
            let scale=min(38/model.state.size.width,34/model.state.size.height), c=try bitmapContext(38,34)
            c.scaleBy(x:scale,y:scale); try layer.draw(on:c,size:model.state.size,region:model.state.rect,pending:pending)
            guard let image=c.makeImage() else { return nil }
            let result=NSImage(cgImage:image,size:CGSize(width:38,height:34)); if pending == nil { thumbnailCache[layer.id]=(layer.revision,model.state.size,result) }; return result
        } catch { return NSImage(systemSymbolName:"exclamationmark.triangle",accessibilityDescription:error.localizedDescription) }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing, !table.selectedRowIndexes.isEmpty else { return }
        selectedLayerIDs=Set(table.selectedRowIndexes.map { layerAt($0).id })
        perform {
            if selectedLayerIDs.count == 1 { try model.selectLayer(layerAt(table.selectedRow).id) }
            else {
                try model.bake()
                if !selectedLayerIDs.contains(model.state.activeID) { model.state.activeID=layerAt(table.selectedRow).id }
                refreshLayerPanel()
            }
        }
    }
    func selectionShouldChange(in tableView: NSTableView) -> Bool { !busy }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item=NSPasteboardItem(); item.setString(layerAt(row).id.uuidString,forType:.boardLayer); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard !busy else { return [] }
        if info.draggingSource as? NSTableView === table {
            table.setDropRow(row,dropOperation:.above); return .move
        }
        guard row >= 0, row < model.state.layers.count else { return [] }
        let layer=layerAt(row)
        guard layer.visible, !layer.locked else { status.stringValue="该图层已隐藏或锁定，请拖到其他图层"; return [] }
        table.setDropRow(row,dropOperation:.on); return .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        if info.draggingSource as? NSTableView === table {
            let ids=Set((info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType:.boardLayer).flatMap(UUID.init(uuidString:)) })
            do { selectedLayerIDs=ids; try model.reorderLayers(ids,toDisplayRow:row); return true } catch { show(error); return false }
        }
        guard row >= 0, row < model.state.layers.count else { return false }
        return receiveDrop(info.draggingPasteboard,layerID:layerAt(row).id,point:.zero)
    }
    func refresh(_ region: CGRect?) {
        canvas.syncSize()
        if let region { canvas.setNeedsDisplay(region.insetBy(dx:-10/canvas.zoom,dy:-10/canvas.zoom)) }
        else {
            canvas.needsDisplay=true; refreshLayerPanel()
        }
        if let object=model.pending { objectWidth.stringValue="\(Int(object.frame.width))"; objectHeight.stringValue="\(Int(object.frame.height))" }
        else { objectWidth.stringValue=""; objectHeight.stringValue="" }
        window?.isDocumentEdited=model.dirty || model.pending != nil
        window?.title="\(projectURL?.deletingPathExtension().lastPathComponent ?? "未命名") — 顺手画板"
        if region == nil { rulersChanged() }
        else { crosshairOverlay.updateGuides(); updateStatus(); scheduleLayerRefresh() }
    }
    func refreshLayerPanel() {
        let ids=Set(model.state.layers.map(\.id)); selectedLayerIDs.formIntersection(ids)
        if selectedLayerIDs.isEmpty || !selectedLayerIDs.contains(model.state.activeID) { selectedLayerIDs=[model.state.activeID] }
        thumbnailCache=thumbnailCache.filter { ids.contains($0.key) }
        refreshing=true; table.reloadData()
        let selected=IndexSet(model.state.layers.indices.filter { selectedLayerIDs.contains(model.state.layers[$0].id) }.map { model.state.layers.count-1-$0 })
        table.selectRowIndexes(selected,byExtendingSelection:false)
        let layer=model.state.layers[model.state.activeIndex]
        background.color=RGBA(r:layer.background.r,g:layer.background.g,b:layer.background.b,a:1).ns
        backgroundAlpha.doubleValue=layer.background.a; opacity.doubleValue=layer.opacity
        let single=selectedLayerIDs.count == 1
        duplicateLayerButton.isEnabled=single; renameLayerButton.isEnabled=single; mergeLayerButton.isEnabled=single && model.state.activeIndex > 0
        addLayerButton.isEnabled=true; deleteLayerButton.isEnabled = !selectedLayerIDs.isEmpty
        background.isEnabled = single && !layer.locked; backgroundAlpha.isEnabled=background.isEnabled; opacity.isEnabled=background.isEnabled
        refreshing=false
    }
    private func scheduleLayerRefresh() {
        guard !layerRefreshPending else { return }; layerRefreshPending=true
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.layerRefreshPending=false; self.refreshLayerPanel() }
    }
    func rulersChanged() { topRuler.needsDisplay=true; rightRuler.needsDisplay=true; crosshairOverlay.update(); crosshairOverlay.updateGuides(); updateStatus() }
    func updateStatus() {
        let s=model.state.size,p=canvas.pointer
        let selection=model.selection.map { " · 选区 \(Int($0.width))×\(Int($0.height))" } ?? ""
        let snap=" · \(canvas.snapping ? "":"⇧")吸附 \(snapStep) px"
        let text="\(Int(s.width)) × \(Int(s.height)) px · \(model.state.layers.count) 层 · \(Int(canvas.zoom*100))%\(canvas.pixelEditing ? " · 像素网格/编辑":"") · x \(Int(p.x)) y \(Int(p.y))\(selection)\(snap)\(busy ? " · 正在处理文件…":"")"
        if status.stringValue != text { status.stringValue=text }
    }
    func show(_ error: Error) { let alert=NSAlert(error:error); if let window { alert.beginSheetModal(for:window) }; status.stringValue=error.localizedDescription }
    func perform(_ body: () throws -> Void) { guard !busy else { NSSound.beep(); return }; do { try body() } catch { show(error) } }
    @objc func toolChanged() {
        window?.makeFirstResponder(canvas)
    }
    @objc func settingsChanged(_ sender: Any?) {
        if (sender as? NSTextField) === snapField { canvas.snapSpacingChanged(); rulersChanged(); return }
        if let well=sender as? NSColorWell { rememberColor(RGBA(well.color)) }
        guard var object=model.pending else { return }
        let old=object.bounds
        if (sender as? NSTextField) === objectWidth || (sender as? NSTextField) === objectHeight {
            let w=objectWidth.doubleValue, h=objectHeight.doubleValue
            guard w.isFinite, h.isFinite, w > 0, h > 0, w < Double(Int.max)/256, h < Double(Int.max)/256 else {
                show(BoardError.invalid("对象宽高必须是有效的正像素数。")); refresh(old); return
            }
            object.resize(to:CGRect(origin:object.frame.origin,size:CGSize(width:w,height:h)))
        } else {
            object.color=color; object.lineWidth=lineWidth; object.filled=filled
            if object.tool == .text { object.text=textValue; object.fontName=fontName; object.fontSize=fontSize }
        }
        model.pending=object; model.notify(old.union(object.bounds))
    }
    func rememberCurrentColor() { rememberColor(color) }
    private func rememberColor(_ color: RGBA) { if colorHistory.record(color) { refreshColorHistory() } }
    private func refreshColorHistory() {
        for view in historyRow.arrangedSubviews { historyRow.removeArrangedSubview(view); view.removeFromSuperview() }
        let label=NSTextField(labelWithString:"最近颜色"); label.font = .systemFont(ofSize:11); label.textColor = .secondaryLabelColor; historyRow.addArrangedSubview(label)
        for (index,color) in colorHistory.colors.enumerated() {
            let swatch=ColorSwatch(frame:.zero); swatch.color=color; swatch.tag=index; swatch.target=self; swatch.action=#selector(chooseRecentColor(_:)); swatch.isBordered=false
            let hex=String(format:"#%02X%02X%02X",Int(color.r*255),Int(color.g*255),Int(color.b*255))
            swatch.toolTip=hex; swatch.setAccessibilityLabel("最近颜色 \(hex)")
            swatch.widthAnchor.constraint(equalToConstant:20).isActive=true; swatch.heightAnchor.constraint(equalToConstant:20).isActive=true; historyRow.addArrangedSubview(swatch)
        }
    }
    @objc func chooseRecentColor(_ sender: NSButton) { guard colorHistory.colors.indices.contains(sender.tag) else { return }; foreground.color=colorHistory.colors[sender.tag].ns; settingsChanged(foreground) }
    func controlTextDidChange(_ obj: Notification) { if let field=obj.object as? NSTextField, field !== objectWidth && field !== objectHeight { settingsChanged(field) } }
    @objc func sampleColor() { NSColorSampler().show { [weak self] color in guard let color, let self else { return }; self.foreground.color=color; self.settingsChanged(self.foreground) } }
    @objc func chooseFont() { NSFontManager.shared.target=self; NSFontManager.shared.setSelectedFont(NSFont(name:fontName,size:fontSize) ?? .systemFont(ofSize:fontSize),isMultiple:false); NSFontManager.shared.orderFrontFontPanel(self) }
    @objc func changeFont(_ sender: NSFontManager) { let f=sender.convert(NSFont(name:fontName,size:fontSize) ?? .systemFont(ofSize:fontSize)); fontName=f.fontName; fontSizeField.doubleValue=f.pointSize; settingsChanged(sender) }
    @objc func confirmObject() { perform { try model.bake() }; window?.makeFirstResponder(canvas) }
    @objc func cancelObject() { model.cancel(); window?.makeFirstResponder(canvas) }
    @objc func undo(_ sender: Any?) { if !busy { if let text=window?.firstResponder as? NSTextView, text.isFieldEditor { text.undoManager?.undo() } else { model.undo() } } }
    @objc func redo(_ sender: Any?) { if !busy { if let text=window?.firstResponder as? NSTextView, text.isFieldEditor { text.undoManager?.redo() } else { model.redo() } } }
    func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.control) else { return false }
        if event.keyCode == 6 || event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { redo(nil) } else { undo(nil) }; return true
        }
        if event.keyCode == 15 || event.charactersIgnoringModifiers?.lowercased() == "r" {
            if event.modifierFlags.contains(.shift) { freezeCrosshair() } else { toggleCrosshair() }; return true
        }
        return false
    }
    @objc func cropSelection() { perform { try model.crop() } }
    @objc func toggleCrosshair() { canvas.crosshair.toggle(); crosshairButton.state=canvas.crosshair ? .on:.off; crosshairOverlay.update() }
    @objc func freezeCrosshair() { canvas.trackingCrosshair.toggle(); if !canvas.trackingCrosshair { canvas.frozenPoint=canvas.pointer }; crosshairOverlay.update() }
    @objc func toggleRulers() { topRuler.isHidden.toggle(); rightRuler.isHidden=topRuler.isHidden; rulerHeight?.constant=topRuler.isHidden ? 0:24; rulerWidth?.constant=topRuler.isHidden ? 0:46 }
    @objc func zoomIn() { scroll.setMagnification(min(64,canvas.zoom*1.5),centeredAt:canvas.pointer); canvas.needsDisplay=true; rulersChanged() }
    @objc func zoomOut() { scroll.setMagnification(max(0.05,canvas.zoom/1.5),centeredAt:canvas.pointer); canvas.needsDisplay=true; rulersChanged() }
    @objc func fitCanvas() { scroll.magnification=max(0.05,min(1,min(scroll.contentSize.width/model.state.size.width,scroll.contentSize.height/model.state.size.height))); scroll.contentView.scroll(to:.zero); canvas.needsDisplay=true; rulersChanged() }
    @objc func actualSize() { scroll.magnification=1; canvas.needsDisplay=true; rulersChanged() }

    @objc func addLayer() { perform { try model.addLayer() } }
    @objc func deleteLayer() { perform { try model.deleteLayers(selectedLayerIDs) } }
    @objc func duplicateLayer() { guard selectedLayerIDs.count == 1 else { return }; perform { try model.duplicateLayer() } }
    @objc func mergeLayer() { guard selectedLayerIDs.count == 1 else { return }; perform { try model.mergeDown() } }
    @objc func toggleVisible(_ sender: NSButton) { changeLayer(sender.tag,name:"图层显隐") { $0.visible.toggle() } }
    @objc func toggleLocked(_ sender: NSButton) { changeLayer(sender.tag,name:"图层锁定") { $0.locked.toggle() } }
    private func changeLayer(_ row: Int,name: String,_ body: (inout Layer)->Void) {
        perform {
            try model.bake(); let i=model.state.layers.count-1-row
            try model.transaction(name) { s in body(&s.layers[i]); s.layers[i].touch() }
        }
    }
    @objc func renameLayer() {
        guard selectedLayerIDs.count == 1 else { return }
        let alert=NSAlert(); alert.messageText="重命名图层"; alert.addButton(withTitle:"确定"); alert.addButton(withTitle:"取消")
        let input=NSTextField(string:model.state.layers[model.state.activeIndex].name); input.frame=CGRect(x:0,y:0,width:240,height:24); alert.accessoryView=input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { try model.transaction("重命名") { $0.layers[$0.activeIndex].name=input.stringValue; $0.layers[$0.activeIndex].touch() } }
    }
    @objc func layerBackgroundChanged() {
        guard !refreshing, selectedLayerIDs.count == 1 else { return }
        var remembered=RGBA(background.color); remembered.a=backgroundAlpha.doubleValue; rememberColor(remembered)
        perform { guard !model.state.layers[model.state.activeIndex].locked else { throw BoardError.invalid("请先解锁图层。") }; var color=RGBA(background.color); color.a=backgroundAlpha.doubleValue; try model.transaction("图层背景") { s in s.layers[s.activeIndex].background=color; s.layers[s.activeIndex].touch() } }
    }
    @objc func layerOpacityChanged() {
        guard !refreshing, selectedLayerIDs.count == 1 else { return }
        perform { guard !model.state.layers[model.state.activeIndex].locked else { throw BoardError.invalid("请先解锁图层。") }; try model.transaction("图层透明度") { s in s.layers[s.activeIndex].opacity=opacity.doubleValue; s.layers[s.activeIndex].touch() } }
    }

    @objc func copy(_ sender: Any?) { copyOrCut(cut:false,currentOnly:false) }
    @objc func cut(_ sender: Any?) { copyOrCut(cut:true,currentOnly:false) }
    @objc func copyCurrent(_ sender: Any?) { copyOrCut(cut:false,currentOnly:true) }
    @objc func cutCurrent(_ sender: Any?) { copyOrCut(cut:true,currentOnly:true) }
    private func copyOrCut(cut: Bool,currentOnly: Bool) {
        perform {
            let origin=(model.selection ?? model.pending?.bounds ?? model.state.rect).origin
            let image=try model.copyImage(currentOnly:currentOnly)
            let data=try imageData(image), pasteboard=NSPasteboard.general
            if cut { _=try model.cut(currentOnly:currentOnly) }
            pasteboard.clearContents(); pasteboard.setData(data,forType:.png)
            storedPasteOrigin=origin; storedPasteChange=pasteboard.changeCount
        }
    }
    @objc func paste(_ sender: Any?) {
        perform {
            guard let image=NSImage(pasteboard:.general), let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw BoardError.invalid("剪贴板中没有可粘贴的图片。") }
            let origin=model.selection?.origin ?? (storedPasteChange == NSPasteboard.general.changeCount ? storedPasteOrigin:nil) ?? (model.state.rect.contains(canvas.pointer) ? canvas.pointer:.zero)
            try insert(cg,layerID:model.state.activeID,at:origin)
        }
    }
    override func selectAll(_ sender: Any?) { model.selection=model.state.rect; model.notify() }
    private func insert(_ image: CGImage, layerID: UUID,at point: CGPoint) throws {
        _=try model.editable(layerID); try model.bake(); selectedLayerIDs=[layerID]; model.state.activeID=layerID
        model.selection=nil
        model.startObject(EditableObject(tool:.select,frame:CGRect(origin:point,size:CGSize(width:image.width,height:image.height)),color:color,lineWidth:lineWidth,image:image,layerID:layerID))
        window?.makeFirstResponder(canvas)
    }
    func receiveDrop(_ pasteboard: NSPasteboard,layerID: UUID,point: CGPoint) -> Bool {
        guard !busy else { return false }
        do {
            _=try model.editable(layerID)
            if let urls=pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL], !urls.isEmpty {
                for url in urls { try insert(readImage(url),layerID:layerID,at:point) }; return true
            }
            if let image=NSImage(pasteboard:pasteboard), let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) { try insert(cg,layerID:layerID,at:point); return true }
            throw BoardError.invalid("拖入内容不是支持的图片。")
        } catch { show(error); return false }
    }
    @objc func importImage() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.image]; panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK, let url=panel.url else { return }
        let alert=NSAlert(); alert.messageText="是否新建一层？"; alert.informativeText="图片添加后可以移动和调整尺寸。"; alert.addButton(withTitle:"并入当前层"); alert.addButton(withTitle:"新建一层"); alert.addButton(withTitle:"取消")
        let answer=alert.runModal(); guard answer != .alertThirdButtonReturn else { return }
        perform { let image=try readImage(url); if answer == .alertSecondButtonReturn { try model.addLayer() }; try insert(image,layerID:model.state.activeID,at:.zero) }
    }

    @objc func newDocument() {
        guard allowDiscard(afterSaving:{ [weak self] in self?.newDocument() }) else { return }
        projectURL=nil; thumbnailCache=[:]; model.reset(); scroll.magnification=1
    }
    @objc func openDocument() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.simpleBoard,.image]; panel.treatsFilePackagesAsDirectories=false
        if panel.runModal() == .OK, let url=panel.url { open(url) }
    }
    func open(_ url: URL) {
        guard !busy, allowDiscard(afterSaving:{ [weak self] in self?.open(url) }) else { return }
        busy=true; updateStatus()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Result { () -> (BoardState,URL?) in
                if url.pathExtension.lowercased() == "sboard" { return (try ProjectFile.load(url),url) }
                let image=try readImage(url); var state=BoardState(); state.size=CGSize(width:image.width,height:image.height)
                let object=EditableObject(tool:.select,frame:state.rect,color:.black,lineWidth:1,image:image,layerID:state.activeID)
                try state.layers[0].raster.edit(in:state.rect,canvas:state.size) { object.draw(on:$0) }
                return (state,nil)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy=false
                switch result {
                case .success(let value): self.projectURL=value.1; self.thumbnailCache=[:]; self.model.reset(to:value.0); self.fitCanvas()
                case .failure(let error): self.show(error)
                }
                self.updateStatus()
            }
        }
    }
    @objc func saveDocument() { save(as:false) }
    @objc func saveAs() { save(as:true) }
    private func save(as saveAs: Bool,completion: (() -> Void)? = nil) {
        guard !busy else { return }
        do { try model.bake() } catch { show(error); return }
        var target=projectURL
        if saveAs || target == nil {
            let panel=NSSavePanel(); panel.allowedContentTypes=[.simpleBoard]; panel.nameFieldStringValue=projectURL?.lastPathComponent ?? "未命名.sboard"; panel.canCreateDirectories=true
            guard panel.runModal() == .OK, let url=panel.url else { return }; target=url
        }
        guard let target else { return }
        busy=true; updateStatus(); let snapshot=model.state
        window?.contentView?.isHidden=false
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Result { try ProjectFile.save(snapshot,to:target) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy=false
                switch result {
                case .success: self.projectURL=target; self.model.dirty=false; self.refresh(nil); completion?()
                case .failure(let error): self.show(error)
                }
                self.updateStatus()
            }
        }
    }
    @objc func exportPNG() { export(type:.png) }
    @objc func exportJPEG() { export(type:.jpeg) }
    private func export(type: UTType) {
        guard !busy else { return }
        let panel=NSSavePanel(); panel.allowedContentTypes=[type]; panel.nameFieldStringValue="画板.\(type.preferredFilenameExtension ?? "png")"
        guard panel.runModal() == .OK, let target=panel.url else { return }
        let snapshot=model.state, pending=model.pending; busy=true; updateStatus()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Result { try imageData(snapshot.composite(pending:pending,white:type == .jpeg),type:type).write(to:target,options:.atomic) }
            DispatchQueue.main.async { [weak self] in self?.busy=false; self?.updateStatus(); if case .failure(let error)=result { self?.show(error) } }
        }
    }
    private func allowDiscard(afterSaving: (() -> Void)? = nil) -> Bool {
        guard !busy else { return false }
        guard model.dirty || model.pending != nil else { return true }
        let alert=NSAlert(); alert.messageText="保存当前画板的更改？"; alert.informativeText="尚未保存的图层和内容会丢失。"; alert.addButton(withTitle:"保存…"); alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"不保存")
        switch alert.runModal() {
        case .alertThirdButtonReturn: return true
        case .alertFirstButtonReturn: save(as:false,completion:afterSaving); return false
        default: return false
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { allowDiscard(afterSaving:{ sender.performClose(nil) }) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if busy { return false }
        switch menuItem.action {
        case #selector(duplicateLayer), #selector(mergeLayer), #selector(renameLayer): return selectedLayerIDs.count == 1
        case #selector(undo(_:)):
            if let text=window?.firstResponder as? NSTextView, text.isFieldEditor { menuItem.title="撤销"; return text.undoManager?.canUndo ?? false }
            menuItem.title=model.pending != nil ? "撤销当前对象":"撤销\(model.undoStack.last.map { " \($0.name)" } ?? "")"; return model.pending != nil || !model.undoStack.isEmpty
        case #selector(redo(_:)):
            if let text=window?.firstResponder as? NSTextView, text.isFieldEditor { return text.undoManager?.canRedo ?? false }
            return !model.redoStack.isEmpty
        case #selector(cropSelection): return model.selection != nil
        default: return true
        }
    }
}
