import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()

application.setActivationPolicy(.regular)
application.mainMenu = ApplicationMenu.make()
application.delegate = delegate
application.run()
