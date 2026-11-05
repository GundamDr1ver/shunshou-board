import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var board: BoardWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        if board == nil { board=BoardWindow(); buildMenu() }; board.showWindow(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let window=board?.window, !board.windowShouldClose(window) { return .terminateCancel }; return .terminateNow
    }
    func application(_ sender: NSApplication,open urls: [URL]) {
        if board == nil { board=BoardWindow(); buildMenu(); board.showWindow(nil) }
        if let url=urls.first { board.open(url) }
    }
    func buildMenu() {
        let menu=NSMenu(); NSApp.mainMenu=menu
        func submenu(_ title: String) -> NSMenu { let item=NSMenuItem(); item.title=title; let m=NSMenu(title:title); item.submenu=m; menu.addItem(item); return m }
        func add(_ menu: NSMenu,_ title: String,_ action: Selector,_ key: String="",_ flags: NSEvent.ModifierFlags = .command,_ target: AnyObject? = nil) {
            // Match shifted native key events with their uppercase character.
            let item=NSMenuItem(title:title,action:action,keyEquivalent:flags.contains(.shift) ? key.uppercased():key)
            item.keyEquivalentModifierMask=flags; item.target=target; menu.addItem(item)
        }
        let app=submenu("顺手画板")
        add(app,"关于顺手画板",#selector(NSApplication.orderFrontStandardAboutPanel(_:)),"",.command,NSApp)
        app.addItem(.separator()); add(app,"隐藏顺手画板",#selector(NSApplication.hide(_:)),"h",.command,NSApp)
        add(app,"退出顺手画板",#selector(NSApplication.terminate(_:)),"q",.command,NSApp)
        let file=submenu("文件")
        add(file,"新建",#selector(BoardWindow.newDocument),"n",.command,board)
        add(file,"打开…",#selector(BoardWindow.openDocument),"o",.command,board)
        add(file,"添加图片…",#selector(BoardWindow.importImage),"i",.command,board)
        file.addItem(.separator()); add(file,"保存工程…",#selector(BoardWindow.saveDocument),"s",.command,board)
        add(file,"工程另存为…",#selector(BoardWindow.saveAs),"s",[.command,.shift],board)
        add(file,"导出 PNG…",#selector(BoardWindow.exportPNG),"e",.command,board)
        add(file,"导出 JPEG…",#selector(BoardWindow.exportJPEG),"e",[.command,.shift],board)
        let edit=submenu("编辑")
        add(edit,"撤销",#selector(BoardWindow.undo(_:)),"z",.command,board)
        add(edit,"重做",#selector(BoardWindow.redo(_:)),"z",[.command,.shift],board)
        edit.addItem(.separator()); add(edit,"剪切可见合成",#selector(BoardWindow.cut(_:)),"x")
        add(edit,"拷贝可见合成",#selector(BoardWindow.copy(_:)),"c")
        add(edit,"仅当前层剪切",#selector(BoardWindow.cutCurrent(_:)),"x",[.command,.shift],board)
        add(edit,"仅当前层拷贝",#selector(BoardWindow.copyCurrent(_:)),"c",[.command,.shift],board)
        add(edit,"粘贴到当前层",#selector(BoardWindow.paste(_:)),"v")
        add(edit,"全选",#selector(BoardWindow.selectAll(_:)),"a")
        add(edit,"裁剪到选区",#selector(BoardWindow.cropSelection),"k",[.command,.shift],board)
        let view=submenu("显示")
        add(view,"切换十字线",#selector(BoardWindow.toggleCrosshair),"r",.command,board)
        add(view,"停止/恢复十字线跟随",#selector(BoardWindow.freezeCrosshair),"r",[.command,.shift],board)
        add(view,"切换标尺",#selector(BoardWindow.toggleRulers),"r",[.command,.option],board)
        view.addItem(.separator()); add(view,"放大",#selector(BoardWindow.zoomIn),"+",.command,board)
        add(view,"缩小",#selector(BoardWindow.zoomOut),"-",.command,board)
        add(view,"实际像素",#selector(BoardWindow.actualSize),"0",.command,board)
        add(view,"适合窗口",#selector(BoardWindow.fitCanvas),"9",.command,board)
        let layers=submenu("图层")
        add(layers,"新建图层",#selector(BoardWindow.addLayer),"n",[.command,.shift],board)
        add(layers,"重命名…",#selector(BoardWindow.renameLayer),"",.command,board)
        add(layers,"复制图层",#selector(BoardWindow.duplicateLayer),"j",.command,board)
        add(layers,"合并到下层",#selector(BoardWindow.mergeLayer),"m",.command,board)
        add(layers,"删除图层",#selector(BoardWindow.deleteLayer),"",.command,board)
    }
}

let application=NSApplication.shared
let delegate=AppDelegate()
application.setActivationPolicy(.regular)
application.delegate=delegate
application.run()
