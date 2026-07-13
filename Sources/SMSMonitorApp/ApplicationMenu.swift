import AppKit

enum ApplicationMenu {
  private static var findMenuItem: NSMenuItem?

  static func make() -> NSMenu {
    let mainMenu = NSMenu()
    mainMenu.addItem(applicationMenuItem())
    mainMenu.addItem(editMenuItem())
    mainMenu.addItem(windowMenuItem())
    return mainMenu
  }

  static func setFindTarget(_ target: AnyObject?) {
    findMenuItem?.target = target
  }

  private static func applicationMenuItem() -> NSMenuItem {
    let rootItem = NSMenuItem()
    let menu = NSMenu(title: "短信成功率监控")
    rootItem.submenu = menu

    addItem(
      to: menu,
      title: "关于短信成功率监控",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))
    )
    menu.addItem(.separator())
    addItem(
      to: menu,
      title: "隐藏短信成功率监控",
      action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h"
    )
    addItem(
      to: menu,
      title: "隐藏其他应用",
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h",
      modifiers: [.command, .option]
    )
    addItem(
      to: menu,
      title: "显示全部",
      action: #selector(NSApplication.unhideAllApplications(_:))
    )
    menu.addItem(.separator())
    addItem(
      to: menu,
      title: "退出短信成功率监控",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    return rootItem
  }

  private static func editMenuItem() -> NSMenuItem {
    let rootItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
    let menu = NSMenu(title: "编辑")
    rootItem.submenu = menu

    addItem(to: menu, title: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    addItem(
      to: menu,
      title: "重做",
      action: Selector(("redo:")),
      keyEquivalent: "z",
      modifiers: [.command, .shift]
    )
    menu.addItem(.separator())
    findMenuItem = addItem(
      to: menu,
      title: "在当前后台中查找",
      action: #selector(AppDelegate.findInCurrentBackend(_:)),
      keyEquivalent: "f"
    )
    menu.addItem(.separator())
    addItem(to: menu, title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    addItem(to: menu, title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    addItem(to: menu, title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    addItem(
      to: menu,
      title: "全选",
      action: #selector(NSText.selectAll(_:)),
      keyEquivalent: "a"
    )
    return rootItem
  }

  private static func windowMenuItem() -> NSMenuItem {
    let rootItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
    let menu = NSMenu(title: "窗口")
    rootItem.submenu = menu

    addItem(
      to: menu,
      title: "最小化",
      action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m"
    )
    addItem(to: menu, title: "缩放", action: #selector(NSWindow.performZoom(_:)))
    menu.addItem(.separator())
    addItem(to: menu, title: "前置所有窗口", action: #selector(NSApplication.arrangeInFront(_:)))
    NSApp.windowsMenu = menu
    return rootItem
  }

  @discardableResult
  private static func addItem(
    to menu: NSMenu,
    title: String,
    action: Selector,
    keyEquivalent: String = "",
    modifiers: NSEvent.ModifierFlags = [.command]
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.keyEquivalentModifierMask = modifiers
    item.target = nil
    menu.addItem(item)
    return item
  }
}
