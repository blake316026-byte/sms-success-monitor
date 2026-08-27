import AppKit

enum MonitorTableRefresh {
  static func apply(
    to tableView: NSTableView,
    structureChanged: Bool,
    selectedRow: Int?,
    configureCell: (NSTableCellView, NSTableColumn, Int) -> Void
  ) {
    if structureChanged {
      let scrollView = tableView.enclosingScrollView
      let originalBounds = scrollView?.contentView.bounds
      tableView.reloadData()
      if let selectedRow, selectedRow != tableView.selectedRow {
        tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
      }
      tableView.layoutSubtreeIfNeeded()
      if let scrollView, let originalBounds {
        let clipView = scrollView.contentView
        // AppKit includes the table header and scroll insets in its valid range.
        let constrained = clipView.constrainBoundsRect(originalBounds)
        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
      }
      return
    }

    // Metrics updates must not reload rows, reselect a row or move the viewport.
    let visibleRows = tableView.rows(in: tableView.visibleRect)
    guard visibleRows.location != NSNotFound else { return }
    let end = min(tableView.numberOfRows, NSMaxRange(visibleRows))
    guard visibleRows.location < end else { return }
    for row in visibleRows.location..<end {
      for (columnIndex, column) in tableView.tableColumns.enumerated() {
        if let cell = tableView.view(atColumn: columnIndex, row: row, makeIfNecessary: false)
          as? NSTableCellView
        {
          configureCell(cell, column, row)
        }
      }
    }
  }
}
