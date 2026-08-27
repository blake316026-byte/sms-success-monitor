import AppKit

final class Fixture: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  let table = NSTableView()
  let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
    styleMask: [.titled], backing: .buffered, defer: false)
  var count = 19
  var revision = 0

  init(style: NSScroller.Style) {
    super.init()
    scroll.scrollerStyle = style
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    for id in ["name", "amount", "difference"] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.width = 300
      table.addTableColumn(column)
    }
    table.rowHeight = 34
    table.columnAutoresizingStyle = .noColumnAutoresizing
    table.allowsEmptySelection = false
    table.delegate = self
    table.dataSource = self
    scroll.documentView = table
    window.contentView?.addSubview(scroll)
    table.reloadData()
    window.contentView?.layoutSubtreeIfNeeded()
    table.selectRowIndexes(IndexSet(integer: 8), byExtendingSelection: false)
  }

  func numberOfRows(in tableView: NSTableView) -> Int { count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell = NSTableCellView()
    let label = NSTextField(labelWithString: "\(revision)-\(row)")
    label.frame = NSRect(x: 0, y: 0, width: 200, height: 25)
    cell.addSubview(label)
    cell.textField = label
    return cell
  }

  func refresh(structureChanged: Bool = false) {
    revision += 1
    MonitorTableRefresh.apply(to: table, structureChanged: structureChanged, selectedRow: 8) {
      cell, _, row in cell.textField?.stringValue = "\(self.revision)-\(row)"
    }
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.002))
  }

  func check() {
    for position in [NSPoint(x: -10000, y: -10000), NSPoint(x: 150, y: 175), NSPoint(x: 10000, y: 10000)] {
      let clip = scroll.contentView
      let proposed = NSRect(origin: position, size: clip.bounds.size)
      clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
      scroll.reflectScrolledClipView(clip)
      window.contentView?.layoutSubtreeIfNeeded()
      let before = clip.bounds.origin
      for _ in 0..<100 { refresh() }
      precondition(abs(clip.bounds.origin.x - before.x) < 0.01, "horizontal viewport moved")
      precondition(abs(clip.bounds.origin.y - before.y) < 0.01, "vertical viewport moved")
      precondition(table.selectedRow == 8, "selection changed")
      let rows = table.rows(in: table.visibleRect)
      var checked = 0
      for row in rows.location..<min(count, NSMaxRange(rows)) {
        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView {
          precondition(cell.textField?.stringValue == "\(revision)-\(row)", "visible metric stayed stale")
          checked += 1
        }
      }
      precondition(checked > 0, "fixture did not create visible cells")
      refresh(structureChanged: true)
      precondition(abs(clip.bounds.origin.y - before.y) < 0.01, "structural reload ignored header insets")
      print("PASS: table top/middle/bottom position \(before), 100 updates, selection and text")
    }
    count = 9
    refresh(structureChanged: true)
    precondition(table.numberOfRows == 9 && table.selectedRow == 8, "row removal failed")
  }
}

@main
struct TableRefreshCheck {
  static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    Fixture(style: .legacy).check()
    Fixture(style: .overlay).check()
  }
}
