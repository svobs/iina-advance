//
//  PrefAdvancedViewController.swift
//  iina
//
//  Created by lhc on 14/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

fileprivate let tableCellFontSize: CGFloat = 13

@objcMembers
class PrefAdvancedViewController: PreferenceViewController, PreferenceWindowEmbeddable {

  override var nibName: NSNib.Name {
    return NSNib.Name("PrefAdvancedViewController")
  }

  var viewIdentifier: String = "PrefAdvancedViewController"

  private var undoHelper = PrefAdvancedUndoHelper()

  var preferenceTabTitle: String {
    return NSLocalizedString("preference.advanced", comment: "Advanced")
  }

  var preferenceTabImage: NSImage {
    return makeSymbol("flask", fallbackImage: "pref_advanced")
  }

  var preferenceContentIsScrollable: Bool {
    return false
  }

  var hasResizableWidth: Bool = false

  var optionsList: [MPVOptPair] = []

  override var sectionViews: [NSView] {
    return [headerView, loggingSettingsView, mpvSettingsView]
  }

  var notiHandler: NotificationHandler! = nil

  private var tableDragDelegate: TableDragDelegate<MPVOptPair>? = nil

  @IBOutlet var headerView: NSView!
  @IBOutlet var loggingSettingsView: NSView!
  @IBOutlet var mpvSettingsView: NSView!

  @IBOutlet weak var enableAdvancedSettingsLabel: NSTextField!
  @IBOutlet weak var optionsTableView: EditableTableView!
  @IBOutlet weak var useAnotherConfigDirBtn: NSButton!
  @IBOutlet weak var chooseConfigDirBtn: NSButton!
  @IBOutlet weak var removeButton: NSButton!

  /// Message string which is Cocoa-bound to a text field below the thumbast checkbox
  @objc dynamic var thumbfastStatus: String = ""

  override func viewDidLoad() {
    super.viewDidLoad()
    
    guard let userOptions = MPVOptPair.readFromPrefs() else {
      Utility.showAlert("extra_option.cannot_read", sheetWindow: view.window)
      return
    }
    optionsList = userOptions

    optionsTableView.idString = "mpvOptionsTable"
    optionsTableView.dataSource = self
    optionsTableView.delegate = self
    optionsTableView.editableDelegate = self
    optionsTableView.editableTextColumnIndexes = [0, 1]
    optionsTableView.selectNextRowAfterDelete = false
    optionsTableView.animationPipeline = AppDelegate.shared.preferenceWindowController.animationPipeline
    refreshRemoveButton()
    
    tableDragDelegate = TableDragDelegate<MPVOptPair>("mpvOptions",
                                                    optionsTableView,
                                                    acceptableDraggedTypes: [.string],
                                                    tableChangeNotificationName: .pendingUIChangeForMpvOptionsTable,
                                                    getFromPasteboardFunc: MPVOptPair.readOptionsListFromPasteboard,
                                                    getAllCurentFunc: { self.optionsList },
                                                    moveFunc: moveOptionRows,
                                                    insertFunc: { self.insertOptionRows($0, at: $1) },
                                                    removeFunc: removeOptionRows)

    optionsTableView.sizeLastColumnToFit()

    if #available(macOS 26.0, *) {
      chooseConfigDirBtn.borderShape = .capsule
      chooseConfigDirBtn.wantsLayer = true
      chooseConfigDirBtn.layer?.cornerRadius = 12
    }

    enableAdvancedSettingsLabel.stringValue = NSLocalizedString("preference.enable_adv_settings",
                                                                comment: "Enable advanced settings")

    notiHandler = NotificationHandler(Logger.log, prefDidChange: prefDidChange, [
      .enableAdvancedSettings,
      .integrateWithThumbfast,
      .useUserDefinedConfDir,
    ], [.default: [
      .init(.thumbfastInfoDidChange, { [self] noti in
        updateThumbfastStatus()
      }),
    ]])
  }

  /// Called each time a pref `key`'s value is set
  func prefDidChange(_ key: Preference.Key, _ newValue: Any?) {
    switch key {
    case PK.enableAdvancedSettings, PK.integrateWithThumbfast, PK.useUserDefinedConfDir:
      updateThumbfastStatus()
    default:
      break
    }
  }

  override func viewWillAppear() {
    Logger.log.trace("Advanced pref pane will appear")
    super.viewWillAppear()
    notiHandler.addAllObservers()
    updateThumbfastStatus()
  }

  override func viewWillDisappear() {
    super.viewWillDisappear()
    Logger.log.trace("Advanced pref pane will disappear")
    notiHandler.removeAllObservers()
  }

  func updateThumbfastStatus() {
    guard Preference.isAdvancedEnabled && Preference.bool(for: .integrateWithThumbfast) else {
      thumbfastStatus = ""
      return
    }

    let startedPlayers = PlayerManager.shared.playerCores.filter({ $0.isInteractivePlayer && $0.state.isAtLeast(.started) })
    if startedPlayers.isEmpty {
      thumbfastStatus = "⚠️ Unknown status. Make sure you have at least one player window open."
      return
    }

    for player in startedPlayers {
      if let thumbfastInfo = player.mpv.thumbfastInfo {
        if thumbfastInfo.isReady {
          thumbfastStatus = "✅ Found thumbfast-info. ✅ Ready"
        } else {
          thumbfastStatus = "✅ Found thumbfast-info. ❌ Not Ready"
        }
        return
      }
    }

    // If we got here, something is wrong. Try to help troubleshoot.

    guard Preference.bool(for: .useUserDefinedConfDir) else {
      setThumbfastError("Need to enable config directory (checkbox below).")
      return
    }

    guard let confDirString = Preference.string(for: .userDefinedConfDir) else {
      setThumbfastError("Bad value for config directory (below).")
      return
    }
    let userConfDir = NSString(string: confDirString).standardizingPath
    guard FileManager.default.fileExists(atPath: userConfDir) else {
      // Could be a permissions problem. Use careful language
      setThumbfastError("(Cannot read mpv config directory. Check the path?)")
      return
    }
    let thumbfastScriptPath = "\(userConfDir)/scripts/thumbfast.lua"
    guard FileManager.default.isReadableFile(atPath: thumbfastScriptPath) else {
      setThumbfastError("(Can't read scripts/thumbfast.lua in config directory. Make sure it is installed?)")
      return
    }
    setThumbfastError("Check that thumbfast.lua is installed & configured properly, then restart IINAA.")
  }

  private func setThumbfastError(_ msg: String) {
    thumbfastStatus = "❌ No thumbfast-info received. " + msg
  }

  // MARK: Options Table Drag & Drop

  @objc func tableView(_ tableView: NSTableView, pasteboardWriterForRow rowIndex: Int) -> NSPasteboardWriting? {
    let optionsList = optionsList
    guard rowIndex < optionsList.count else { return nil }

    let rowString = optionsList[rowIndex].undashedString
    return rowString as NSString?
  }

  @objc func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    return tableDragDelegate!.draggingSession(session, sourceOperationMaskFor: context)
  }

  @objc func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
    tableDragDelegate!.tableView(tableView, draggingSession: session, willBeginAt: screenPoint, forRowIndexes: rowIndexes)
  }

  @objc func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    tableDragDelegate!.tableView(tableView, draggingSession: session, endedAt: screenPoint, operation: operation)
  }

  @objc func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow rowIndex: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
    return tableDragDelegate!.tableView(tableView, validateDrop: info, proposedRow: rowIndex,
                                        proposedDropOperation: dropOperation)
  }

  @objc func tableView(_ tableView: NSTableView,
                       acceptDrop info: NSDraggingInfo, row targetRowIndex: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
    return tableDragDelegate!.tableView(tableView, acceptDrop: info, row: targetRowIndex, dropOperation: dropOperation)
  }

  // MARK: - Options Table CRUD

  func doAtomicTableUpdate(_ tableUIChange: TableUIChange, _ allItemsNew: [MPVOptPair]) {
    optionsList = allItemsNew             // update cached data
    MPVOptPair.writeToPrefs(optionsList)  // update saved data
    optionsTableView.post(tableUIChange)  // update UI
  }

  func insertOptionRows(_ newItems: [MPVOptPair], at targetRowIndex: Int? = nil, thenStartEdit: Bool = false) {
    let (tableUIChange, allItemsNew) = optionsTableView.buildInsert(of: newItems, at: targetRowIndex, in: optionsList,
                                                                    completionHandler: { [self] tableUIChange in
      // We don't know beforehand exactly which row it will end up at, but we can get this info from the TableUIChange object
      if thenStartEdit, let insertedRowIndex = tableUIChange.toInsert?.first {
        optionsTableView.editCell(row: insertedRowIndex, column: 0)
      }
      // Do not query table directly here. It seems to interfere with the row animations.
      // Easy enough to get the selection from the TableUIChange object.
      removeButton.isHidden = !tableUIChange.hasSelectionAfterChange
    })

    let allItemsOld = optionsList         // needed for Undo

    let doAction = { [self] in
      doAtomicTableUpdate(tableUIChange, allItemsNew)
    }

    doAction()

    undoHelper.register(undoHelper.buildActionName(basedOn: tableUIChange), undo: { [self] in
      let tableUIChangeUndo = TableUIChangeBuilder.shared.inverted(from: tableUIChange,
                                                             selectNextRowAfterDelete: optionsTableView.selectNextRowAfterDelete,
                                                             useFlashForChangedRows: true)
      doAtomicTableUpdate(tableUIChangeUndo, allItemsOld)
    }, redo: {
      doAction()
    })

  }

  func moveOptionRows(from rowIndexes: IndexSet, to targetRowIndex: Int) {
    let (tableUIChange, allItemsNew) = optionsTableView.buildMove(rowIndexes, to: targetRowIndex, in: optionsList,
                                                                  completionHandler: { [self] tableUIChange in
      removeButton.isHidden = !tableUIChange.hasSelectionAfterChange
    })

    let allItemsOld = optionsList         // needed for Undo

    let doAction = { [self] in
      doAtomicTableUpdate(tableUIChange, allItemsNew)
    }

    doAction()

    undoHelper.register(undoHelper.buildActionName(basedOn: tableUIChange), undo: { [self] in
      let tableUIChangeUndo = TableUIChangeBuilder.shared.inverted(from: tableUIChange, selectNextRowAfterDelete: optionsTableView.selectNextRowAfterDelete)
      doAtomicTableUpdate(tableUIChangeUndo, allItemsOld)
    }, redo: {
      doAction()
    })
  }

  func removeOptionRows(_ rowIndexes: IndexSet) {
    guard !rowIndexes.isEmpty else { return }

    Logger.log.verbose("Removing rows from Options table: \(rowIndexes)")
    let (tableUIChange, allItemsNew) = optionsTableView.buildRemove(rowIndexes, in: optionsList,
                                                                    completionHandler: { [self] tableUIChange in
      removeButton.isHidden = !tableUIChange.hasSelectionAfterChange
    })

    let allItemsOld = optionsList         // needed for Undo

    let doAction = { [self] in
      doAtomicTableUpdate(tableUIChange, allItemsNew)
    }

    doAction()

    undoHelper.register(undoHelper.buildActionName(basedOn: tableUIChange), undo: { [self] in
      let tableUIChangeUndo = TableUIChangeBuilder.shared.inverted(from: tableUIChange, selectNextRowAfterDelete: optionsTableView.selectNextRowAfterDelete)
      doAtomicTableUpdate(tableUIChangeUndo, allItemsOld)
    }, redo: {
      doAction()
    })
  }

  // MARK: - IBAction

  @IBAction func openLogDir(_ sender: AnyObject) {
    NSWorkspace.shared.open(Logger.logDirectory)
  }
  
  @IBAction func showLogWindow(_ sender: AnyObject) {
    AppDelegate.shared.logWindow.showWindow(self)
  }

  @IBAction func addOptionBtnAction(_ sender: AnyObject) {
    let selectedRowIndexes = optionsTableView.selectedRowIndexes
    let insertIndex = selectedRowIndexes.isEmpty ? optionsTableView.numberOfRows : selectedRowIndexes.max()! + 1
    insertOptionRows([MPVOptPair.empty], at: insertIndex, thenStartEdit: true)
  }

  @IBAction func removeOptionBtnAction(_ sender: AnyObject) {
    removeOptionRows(optionsTableView.selectedRowIndexes)
  }

  @IBAction func chooseDirBtnAction(_ sender: AnyObject) {
    let existingDir: URL?
    if let prefValue = Preference.string(for: .userDefinedConfDir) {
      existingDir = URL(fileURLWithPath: prefValue)
    } else {
      existingDir = nil
    }
    Utility.quickOpenPanel(title: "Choose config directory", chooseDir: true, dir: existingDir, sheetWindow: view.window) { url in
      Preference.set(url.path, for: .userDefinedConfDir)
    }
  }

  @IBAction func helpBtnAction(_ sender: AnyObject) {
    NSWorkspace.shared.open(URL(string: AppData.wikiLink)!.appendingPathComponent("MPV-Options-and-Properties"))
  }

  @IBAction func thumbfastHelpBtnAction(_ sender: AnyObject) {
    NSWorkspace.shared.open(URL(string: AppData.wikiLinkAdvance)!.appendingPathComponent("thumbfast-integration"))
  }
}

extension PrefAdvancedViewController: NSTableViewDelegate, NSTableViewDataSource, NSControlTextEditingDelegate {

  func numberOfRows(in tableView: NSTableView) -> Int {
    return optionsList.count
  }

  /**
   Make cell view when asked
   */
  @objc func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let identifier = tableColumn?.identifier else { return nil }

    guard let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView else {
      return nil
    }
    let columnName = identifier.rawValue

    guard row < optionsList.count else { return nil }
    let opt = optionsList[row]

    let columnText: String
    switch columnName {
    case "Key":
      columnText = opt.key

    case "Value":
      columnText = opt.val

    default:
      Logger.log("Unrecognized column: '\(columnName)'", level: .error)
      return nil
    }

    guard let textField = cell.textField else { return nil }

    var useItalic = false
    let textColor: NSColor
    if !tableView.isEnabled {
      textColor = .disabledControlTextColor
    } else {
      if optionsList[row].hasValidKey {
        textColor = .controlTextColor
      } else {
        textColor = .systemRed
        useItalic = true
      }
    }
    textField.font = .monospacedSystemFont(ofSize: tableCellFontSize, weight: .regular)
    textField.setFormattedText(stringValue: columnText, textColor: textColor, italic: useItalic)
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    refreshRemoveButton()
  }

  private func refreshRemoveButton() {
    removeButton.isHidden = optionsTableView.selectedRowIndexes.isEmpty
  }
}

extension PrefAdvancedViewController: EditableTableViewDelegate {
  var parentTableView: EditableTableView! { optionsTableView }

  func userDidDoubleClickOnCell(row rowIndex: Int, column columnIndex: Int) -> Bool {
    Logger.log.verbose("Double-click: Edit requested for row \(rowIndex), col \(columnIndex)")
    optionsTableView.editCell(row: rowIndex, column: columnIndex)
    return true
  }

  func userDidPressEnterOnRow(_ rowIndex: Int) -> Bool {
    Logger.log.verbose("Enter key: Edit requested for row \(rowIndex)")
    optionsTableView.editCell(row: rowIndex, column: 0)
    return true
  }

  func editDidEndWithNewText(newValue: String, row rowIndex: Int, column columnIndex: Int, then doAfter: OnSuccessCallback? = nil) -> Bool {
    Logger.log.verbose("User finished editing option value for row \(rowIndex), col \(columnIndex): \(newValue.quoted)")
    guard rowIndex < optionsList.count else {
      return false
    }

    var userString = newValue

    let lines = userString.split(separator: "\n")
    if lines.count > 1 {
      Logger.log.debug("Entry for col \(columnIndex) has a newline in it: only the text before it will be used.")
      userString = String(lines[0])
    }

    let optOld = optionsList[rowIndex]
    let optNew: MPVOptPair
    if columnIndex == 0 {
      // Key column.
      // Delete unnecessary prefix from confused users
      let optParsed = MPVOptPair.parseLine(userString)

      if optParsed.val.isEmpty {
        optNew = MPVOptPair(key: optParsed.key, val: optOld.val)
      } else {
        Logger.log.debug("User entered a key=value pair in the Name field: will split into Name & Value and changing both columns.")
        optNew = optParsed
      }
    } else {
      optNew = MPVOptPair(key: optOld.key, val: userString)
    }

    let (tableUIChange, allItemsNew) = optionsTableView.buildUpdate(ofRow: rowIndex, to: optNew, in: optionsList,
                                                                    completionHandler: { [self] tableUIChange in
      removeButton.isHidden = !tableUIChange.hasSelectionAfterChange
      if let doAfter {
        doAfter()
      }
    })
    let allItemsOld = optionsList         // needed for Undo

    let doAction = { [self] in
      doAtomicTableUpdate(tableUIChange, allItemsNew)
    }

    doAction()

    undoHelper.register(undoHelper.buildActionName(basedOn: tableUIChange), undo: { [self] in
      let tableUIChangeUndo = TableUIChangeBuilder.shared.inverted(from: tableUIChange,
                                                                   selectNextRowAfterDelete: optionsTableView.selectNextRowAfterDelete,
                                                                   useFlashForChangedRows: true, completionHandler: { [self] tableUIChange in
        removeButton.isHidden = !tableUIChange.hasSelectionAfterChange
      })
      doAtomicTableUpdate(tableUIChangeUndo, allItemsOld)
    }, redo: {
      doAction()
    })

    return true
  }

  var hasSelectedRows: Bool {
    return !optionsTableView.selectedRowIndexes.isEmpty
  }

  func isDeleteEnabled() -> Bool {
    return hasSelectedRows
  }

  func doEditMenuDelete() {
    removeOptionRows(optionsTableView.selectedRowIndexes)
  }

  func isCutEnabled() -> Bool {
    return hasSelectedRows
  }

  func isCopyEnabled() -> Bool {
    return hasSelectedRows
  }

  func isPasteEnabled() -> Bool {
    return !MPVOptPair.readOptionsFromClipboard().isEmpty
  }

  // Edit menu action handlers. Delegates should override these if they want to support the standard operations.

  func doEditMenuCut() {
    doEditMenuCopy()
    doEditMenuDelete()
  }

  func doEditMenuCopy() {
    MPVOptPair.copyOptionsToClipboard(selectedOptions)
  }

  func doEditMenuPaste() {
    let optionsToInsert = MPVOptPair.readOptionsFromClipboard()
    guard !optionsToInsert.isEmpty else { return }
    let insertIndex: Int
    if let lastSelectedRow = optionsTableView.selectedRowIndexes.last {
      insertIndex = lastSelectedRow + 1
    } else {
      insertIndex = optionsTableView.numberOfRows
    }

    insertOptionRows(optionsToInsert, at: insertIndex)
  }

  fileprivate var selectedOptions: [MPVOptPair] {
    return optionsTableView.selectedRowIndexes.map { optionsList[$0] }
  }

}
