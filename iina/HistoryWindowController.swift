//
//  HistoryWindowController.swift
//  iina
//
//  Created by lhc on 28/4/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

fileprivate extension NSUserInterfaceItemIdentifier {
  static let time = NSUserInterfaceItemIdentifier("Time")
  static let filename = NSUserInterfaceItemIdentifier("Filename")
  static let progress = NSUserInterfaceItemIdentifier("Progress")
  static let group = NSUserInterfaceItemIdentifier("Group")
  static let contextMenu = NSUserInterfaceItemIdentifier("ContextMenu")
}

fileprivate let sectionHighlightColor = NSColor(name: nil) { appearance in
  if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
    // Dark mode
    return NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.16)
  } else {
    // Light mode
    return NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.6)
  }
}

// MARK: Constants

fileprivate let loadingKey = "Loading..."
fileprivate let noResultsKeyFormat = "No results found for \"%@\"."
fileprivate let noHistoryKey = "No history exists."
fileprivate let loadingPlaceholderLabel = ""  // displayed next to the loading spinner
fileprivate let noHistoryPlaceholderLabel  = ""  // displayed next to the loading spinner

fileprivate let MenuItemTagShowInFinder = 100
fileprivate let MenuItemTagDelete = 101
fileprivate let MenuItemTagSearchFilename = 200
fileprivate let MenuItemTagSearchFullPath = 201
fileprivate let MenuItemTagPlay = 300
fileprivate let MenuItemTagPlayInNewWindow = 301

fileprivate let loadingData = [loadingKey: [LoadingPlaceholder.shared.url]]

fileprivate let timeColMinWidths: [Preference.HistoryGroupBy: CGFloat] = [
  .lastPlayedDay: 60,
  .parentFolder: 145
]

/// Header panel in History table (`outlineView`).
///
/// This class exists solely so that a gray background is drawn under the header.
/// The background doesn't seem to be customizable...
class HistoryTableHeaderView: NSTableHeaderView {
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
  }
}

final class HistoryWindowController: WindowController, NSOutlineViewDelegate, NSOutlineViewDataSource,
                                     NSMenuDelegate, NSMenuItemValidation, NSWindowDelegate {

  // - XIB

  override var windowNibName: NSNib.Name {
    return NSNib.Name("HistoryWindowController")
  }

  @IBOutlet weak var titleBarAccessoryContentView: NSView!
  @IBOutlet weak var outlineView: OutlineView!
  @IBOutlet weak var historySearchField: NSSearchField!
  @IBOutlet weak var groupByButton: NSPopUpButton!

  @IBOutlet weak var historyTableVerticalOffsetConstraint: NSLayoutConstraint!

  // - Service objects

  private let log: any Logger.Subsystem
  private var notiHandler: NotificationHandler!

  private var backgroundQueue = DispatchQueue.newDQ(label: "HistoryWindow-BG", qos: .background)

  /// Calls `self.showLoadingUI` on timeout.
  private let showLoadingMsgTimer = TimeoutTimer(timeout: Constants.TimeInterval.historyTableDelayBeforeLoadingMsgDisplay)

  // - State

  @Atomic private var reloadTicketCounter: Int = 0
  private var isInitialLoadDone = false

  // How the data is sorted
  var groupBy: Preference.HistoryGroupBy
  var searchType: Preference.HistorySearchType
  var searchString: String

  // These must only be updated in the main queue
  // There are still some possible races where data can go stale... Fix in a future version
  private var historyLookup: [URL: PlaybackHistory] = [LoadingPlaceholder.shared.url: LoadingPlaceholder.shared]
  private var historyData: [String: [URL]] = loadingData
  private var historyDataKeys: [String] = [loadingKey]

  private var historyVersion: Int = 0
  /// List of "file exists" metadata from `HistoryController`. Cached to prevent races.
  private var fileExistsMap: [URL: Bool] = [:]

  /// Cached list of selected items in table. Only for use by menus!
  ///
  /// Populated when menu needs to be shown, then referenced in `validateMenuItem` & menu item actions.
  private var selectedEntries: [PlaybackHistory] = []

  // MARK: - Init

  init() {
    log = HistoryController.shared.log
    groupBy = HistoryWindowController.getGroupByFromPrefs() ?? Preference.HistoryGroupBy.defaultValue
    searchType = HistoryWindowController.getHistorySearchTypeFromPrefs() ?? Preference.HistorySearchType.defaultValue
    searchString = HistoryWindowController.getSearchStringFromPrefs() ?? ""
    super.init(window: nil)
    if let window {
      window.tabbingMode = .disallowed
    }

    windowFrameAutosaveName = WindowAutosaveName.playbackHistory.string
    showLoadingMsgTimer.action = showLoadingUI

    initNotificationHandler()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - Window lifecycle

  override func windowDidLoad() {
    super.windowDidLoad()
    guard let window else { return }
    outlineView.delegate = self
    outlineView.dataSource = self
    outlineView.menu?.delegate = self
    outlineView.target = self
    outlineView.doubleAction = #selector(doubleAction)
    outlineView.sizeLastColumnToFit()

    // Add this to prevent vertical overlap with title
    historyTableVerticalOffsetConstraint.constant = Constants.standardTitleBarHeight

    if #available(macOS 26.0, *) {
      groupByButton.wantsLayer = true
      groupByButton.borderShape = .capsule
      groupByButton.layer?.cornerRadius = 10
    }

    window.backgroundColor = .clear
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)

    if let visualEffectCV = window.contentView as? NSVisualEffectView {
      visualEffectCV.material = .contentBackground
      visualEffectCV.blendingMode = .behindWindow
      visualEffectCV.state = .active
      visualEffectCV.autoresizingMask = [.width, .height]
    }

    // replace with split view when all subviews are properly loaded
    if #available(macOS 26.0, *) {
      setupForLiquidGlass()
    } else {
      // Add the visual effect as a title bar accessory
      let accessory = NSTitlebarAccessoryViewController()
      accessory.view = titleBarAccessoryContentView
      accessory.layoutAttribute = .trailing
      window.addTitlebarAccessoryViewController(accessory)

      if #available(macOS 11.0, *) {
        window.titlebarSeparatorStyle = .automatic  // or .line, .none, .shadow
        accessory.automaticallyAdjustsSize = false
      }
    }

    // Override the automatic key-view loop to ensure correct order
    self.outlineView.nextKeyView = self.groupByButton
    self.groupByButton.nextKeyView = self.historySearchField
    self.historySearchField.nextKeyView = self.outlineView
    // Focus on table when window opens, becuase the other views show a glaring ring when focused
    window.initialFirstResponder = self.outlineView

    DispatchQueue.main.async { [self] in
      historySearchField.stringValue = searchString
      historySearchField.sendAction(historySearchField.action, to: historySearchField.target)
    }
    log.verbose("History windowDidLoad done")
  }

  override func openWindow(_ sender: Any?) {
    guard let _ = window else { return }  // load window
    assert(isWindowLoaded, "Expected History window to be loaded!")

    notiHandler.addAllObservers()

    // Cannot rely on `iinaFileExistsInfoDidUpdate` being sent anytime soon, so pull down the latest copy now
    fileExistsMap = HistoryController.shared.fileExistsMap

    if !isInitialLoadDone {
      showLoadingUI()
      // If app is starting up, need to prevent reload from happening before the history has finished loading,
      // or else it will immediately show as an empty list.
      if HistoryController.shared.started && HistoryController.shared.historyListVersion > 0 {
        reloadHistoryData()
      } else {
        // Load history if not started already:
        HistoryController.shared.start()
      }
    } else {
      // Refresh this if needed. This will not be refreshed while the History window is closed and may be very stale.
      HistoryController.shared.startAsyncReloadOfFileExistsAndProgress(forVersion: historyVersion)
    }

    updateProgressColumnVisibility()

    // Reload may take a long time. Send signal to open right away, and refresh when load is done.
    super.openWindow(sender)
  }

  func windowWillClose(_ notification: Notification) {
    log.verbose("History window will close")
    invalidateTicket()
    notiHandler.removeAllObservers()
  }

  func windowWillEnterFullScreen(_ notification: Notification) {
    historyTableVerticalOffsetConstraint.constant = 0
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    historyTableVerticalOffsetConstraint.constant = Constants.standardTitleBarHeight
  }

  // MARK: - History (re)-loading

  private func isTicketStillValid(_ ticket: Int) -> Bool {
    return ticket == reloadTicketCounter && !HistoryController.shared.isAppTerminating
  }

  private func invalidateTicket() {
    $reloadTicketCounter.withLock { $0 += 1 }
  }

  /// Can be called from any DispatchQueue
  private func reloadHistoryData(useLoadingMsg: Bool = true) {
    // Reloads are expensive and many things can trigger them.
    // Use a counter + a delay to reduce duplicated work (except for initial load)
    let ticket: Int = $reloadTicketCounter.withLock {
      $0 += 1
      return $0
    }

    if useLoadingMsg {
      DispatchQueue.main.async { [self] in
        guard isTicketStillValid(ticket) else { return }
        // Schedule timer to show loading msg if loading takes too long
        showLoadingMsgTimer.restart()

        _reloadHistoryDataBG(ticket: ticket)
      }
    } else {
      _reloadHistoryDataBG(ticket: ticket)
    }
  }

  private func _reloadHistoryDataBG(ticket: Int) {
    backgroundQueue.async { [self] in
      guard !isInitialLoadDone || isTicketStillValid(ticket) else { return }
      _reloadHistoryData(ticket: ticket)
    }
  }

  private func _reloadHistoryData(ticket: Int) {
    assert(DispatchQueue.isExecutingIn(backgroundQueue))

    let isInitialLoad = !isInitialLoadDone
    log.trace("History window: reloading History data, tkt=\(ticket)")
    // reconstruct data
    let sw = Utility.Stopwatch()
    let unfilteredHistory = HistoryController.shared.history
    let searchString = searchString

    guard HistoryController.shared.started else {
      log.warn("History window: failed to reload data. History service is stopped! Something is wrong. Aborting")
      // History service should not be stopped here. Something went wrong.
      DispatchQueue.main.async { [self] in
        showLoadingMsgTimer.cancel()
        // TODO: show error message instead of appearing to hang on load
        showLoadingUI()
      }
      return
    }

    let historyList: [PlaybackHistory]
    if searchString.isEmpty {
      historyList = unfilteredHistory
    } else {
      historyList = unfilteredHistory.filter { entry in
        let string = searchType == .filename ? entry.name : entry.url.path
        // Do a locale-aware, case and diacritic insensitive search:
        return string.localizedStandardContains(searchString)
      }
    }
    var historyDataUpdated: [String: [URL]] = [:]
    var historyDataKeysUpdated: [String] = []

    for entry in historyList {
      let key = getKey(entry)

      if historyDataUpdated[key] == nil {
        historyDataUpdated[key] = [entry.url]
        historyDataKeysUpdated.append(key)
      } else {
        historyDataUpdated[key]!.append(entry.url)
      }
    }

    let hasFilter = !searchString.isEmpty
    if historyDataUpdated.isEmpty {
      log.trace("History window: showing No Results placeholder, hasFilter=\(hasFilter.yn)")
      if hasFilter {
        let noResultsKey = String(format: noResultsKeyFormat, searchString)
        historyDataUpdated[noResultsKey] = []
        historyDataKeysUpdated = [noResultsKey]
      } else {
        historyDataUpdated[noHistoryKey] = []
        historyDataKeysUpdated = [noHistoryKey]
      }
    }

    DispatchQueue.main.async { [self] in
      guard isInitialLoad || isTicketStillValid(ticket) else { return }  // check ticket
      
      showLoadingMsgTimer.cancel()

      // Save selection to restore later
      let prevSelectedItems = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? PlaybackHistory }

      // Store latest history in lookup table. Do not remove any entries, to ensure that lookup will never fail
      for entry in unfilteredHistory {
        historyLookup[entry.url] = entry
      }
      // Update data and reload UI
      historyData = historyDataUpdated
      historyDataKeys = historyDataKeysUpdated

      adjustTimeColumnMinWidth()
      outlineView.reloadData()
      outlineView.expandItem(nil, expandChildren: true)
      // Restore selection
      let newSelectionIndexes = prevSelectedItems.map{ outlineView.row(forItem: $0) }.filter{ $0 >= 0 }
      var newSelectionIndexSet = IndexSet()
      for rowIndex in newSelectionIndexes {
        newSelectionIndexSet.insert(rowIndex)
      }
      outlineView.selectRowIndexes(newSelectionIndexSet, byExtendingSelection: false)

      log.verbose("Reloaded history table: \(historyList.count) entries, filter=\(searchString.quoted) in \(sw.secElapsedString) (tkt \(reloadTicketCounter))")

      if isInitialLoad {
        isInitialLoadDone = true
      }
    }
  }

  /// Resets table to loading msg.
  private func showLoadingUI() {
    log.verbose("History window: showing Loading placeholder")
    historyData = loadingData
    historyDataKeys = [loadingKey]
    outlineView.reloadData()
    // Expand to show loading placeholder
    outlineView.expandItem(nil, expandChildren: true)
  }

  // MARK: - Notifications

  private func initNotificationHandler() {
    notiHandler = NotificationHandler(log, prefDidChange: prefDidChange, [
      .uiHistoryTableGroupBy,
      .uiHistoryTableSearchType,
      .uiHistoryTableSearchString,
      .resumeLastPosition,
    ], [
      .default: [
        .init(.iinaHistoryListUpdated, self.onHistoryListUpdated),
        .init(.iinaFileHistoryDidUpdate, self.onFileHistoryDidUpdate),
        .init(.iinaFileExistsInfoDidUpdate, self.onFileExistsInfoDidUpdate)
      ]
    ])
  }

  /// Notification callback: History changed in a big or ambiguous way, requiring a full table reload
  private func onHistoryListUpdated(_ note: Notification) {
    log.verbose("History window received iinaHistoryListUpdated; will reload data")
    reloadHistoryData(useLoadingMsg: false)
  }

  /// Notification callback: Individual history added or updated
  private func onFileHistoryDidUpdate(_ note: Notification) {
    assert(DispatchQueue.isExecutingIn(.main))
    guard !AppDelegate.shared.isTerminating else { return }

    guard let url = note.userInfo?["url"] as? URL else {
      log.error("Cannot update file history: no url found in userInfo!")
      return
    }

    /// Notification callback: Enqueue in backgroundQueue to ensure happens-before relationship
    backgroundQueue.async { [self] in
      guard let entry = HistoryController.shared.history(forURL: url) else {
        // No history for URL. Can happen if URL was removed from history, or simply never played
        log.trace("Ignoring update, not in history: \(url.path.pii.quoted)")
        return
      }

      DispatchQueue.main.async { [self] in
        // Now trigger UI to update
        let rowKey = getKey(entry)
        // Update our copy
        historyLookup[url] = entry
        let itemRow = outlineView.row(forItem: rowKey)
        if itemRow != NSNotFound {
          // This will reload the parent of the target row. Not ideal, but still much faster than full table reload
          outlineView.reloadItem(rowKey, reloadChildren: true)
        }
      }
    }
  }

  /// Notification callback
  private func onFileExistsInfoDidUpdate(_ note: Notification) {
    assert(DispatchQueue.isExecutingIn(.main))
    guard !AppDelegate.shared.isTerminating else { return }

    // Reload table again to refresh statuses
    let historyVersion = HistoryController.shared.historyListVersion
    log.verbose("Reloading History table with updated fileExists data (v\(historyVersion))")
    self.historyVersion = historyVersion
    self.fileExistsMap = HistoryController.shared.fileExistsMap
    outlineView.reloadExistingRows(reselectRowsAfter: true)
    log.verbose("Reloaded History table with fileExists data: done")
  }

  /// Called each time a pref `key`'s value is set
  private func prefDidChange(_ key: Preference.Key, _ newValue: Any?) {
    switch key {
    case .uiHistoryTableGroupBy:
      guard let groupByNew = HistoryWindowController.getGroupByFromPrefs(), groupByNew != groupBy else { return }
      groupBy = groupByNew
    case .uiHistoryTableSearchType:
      guard let searchTypeNew = HistoryWindowController.getHistorySearchTypeFromPrefs(), searchTypeNew != searchType else { return }
      searchType = searchTypeNew
    case .uiHistoryTableSearchString:
      guard let searchStringNew = HistoryWindowController.getSearchStringFromPrefs(), searchStringNew != searchString else { return }
      searchString = searchStringNew
      historySearchField.stringValue = searchString
    case .resumeLastPosition:
      updateProgressColumnVisibility()

    default:
      break
    }
    guard isWindowLoaded else { return }
    reloadHistoryData()
  }

  // MARK: Key event

  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command  {
      switch event.charactersIgnoringModifiers! {
      case "f":
        window!.makeFirstResponder(historySearchField)
        return
      case "a":
        outlineView.selectAll(nil)
        return
      default:
        break
      }
    } else {
      let key = KeyCodeHelper.mpvKeyCode(from: event)
      if key == "DEL" || key == "BS" {
        let entries = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? PlaybackHistory }
        removeAfterConfirmation(entries)
        return
      }
    }

    super.keyDown(with: event)
  }

  // MARK: - NSOutlineViewDelegate

  func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
    return item as? PlaybackHistory != nil
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    return item is String
  }

  func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
    return item is String
  }

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    if let item = item {
      if let category = item as? String, let children = historyData[category] {
        return children.count
      } else {
        return 0
      }
    } else {
      return historyData.count
    }
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    if let item = item {
      let url = historyData[item as! String]![index]
      return historyLookup[url]!
    } else {
      return historyDataKeys[index]
    }
  }

  func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
    if let entry = item as? PlaybackHistory {
      if item as? LoadingPlaceholder != nil {
        return ""
      } else if let tableColumn {
        if tableColumn.identifier == .time {
          return getTimeString(from: entry)
        } else if tableColumn.identifier == .progress {
          if !tableColumn.isHidden {
            return VideoTime.string(from: entry.duration)
          }
        }
      }
    }
    return item
  }

  func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
    /// The background color for a `NSTableRowView` will default to the parent's background color, which results in an
    /// unwanted additive effect for translucent backgrounds. Just make each row transparent.
    rowView.wantsLayer = true
    let item = outlineView.item(atRow: row)
    // do not color bg of Loading placeholder
    if let item, item as? PlaybackHistory == nil, (item as? String) != loadingKey {
      rowView.backgroundColor = sectionHighlightColor
    } else {
      rowView.backgroundColor = .clear
    }
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let tableColumn else {
      // group header
      guard let groupCell: NSTableCellView = outlineView.makeView(withIdentifier: .group, owner: nil) as? NSTableCellView else { return nil }
      return groupCell
    }

    let columnID = tableColumn.identifier
    guard let cell: NSTableCellView = outlineView.makeView(withIdentifier: columnID, owner: nil) as? NSTableCellView else { return nil }
    guard let entry = item as? PlaybackHistory else { return cell }

    switch columnID {
    case .filename:
      let filenameView = cell as! HistoryFilenameCellView

      let isLoadingPlaceholder = item as? LoadingPlaceholder != nil
      if isLoadingPlaceholder {
        if let textField = filenameView.textField {
          // Loading placeholder for initial load
          let mutableString = NSMutableAttributedString(string: loadingPlaceholderLabel)
          mutableString.addItalic(using: textField.font)
          textField.attributedStringValue = mutableString
          textField.textColor = .controlTextColor
        }
        if #available(macOS 15.0, *),
           let spinImage = NSImage(systemSymbolName: "progress.indicator", accessibilityDescription: "Loading...") {
          filenameView.docImage.setSymbolImage(spinImage, contentTransition: .automatic)
          let effect = VariableColorSymbolEffect.variableColor.iterative.dimInactiveLayers.nonReversing
          filenameView.docImage.addSymbolEffect(effect, options: .repeat(.continuous))
        } else {
          // Just show loading text
          filenameView.docImage.image = nil
        }

      } else {
        filenameView.textField?.stringValue = entry.url.isFileURL ? entry.name : entry.url.absoluteString
        let fileExistsMap = fileExistsMap
        let fileExists = fileExistsMap[entry.url] ?? true
        filenameView.textField?.textColor = fileExists ? .controlTextColor : .disabledControlTextColor
        filenameView.docImage.image = Utility.icon(for: entry.url)
      }

    case .progress:
      guard !tableColumn.isHidden else { break }

      let progressView = cell as! HistoryProgressCellView
      // Do not animate! Causes unneeded slowdown
      progressView.indicator.usesThreadedAnimation = false

      if let progress = entry.mpvProgress {
        progressView.textField?.stringValue = VideoTime.string(from: progress)
        progressView.indicator.isHidden = false
        progressView.indicator.doubleValue = progress / entry.duration
      } else {
        progressView.textField?.stringValue = ""
        progressView.indicator.isHidden = true
      }
    case .time:
      break
    default:
      break
    }

    return cell
  }

  private func getTimeString(from entry: PlaybackHistory) -> String {
    if groupBy == .lastPlayedDay {
      return DateFormatter.localizedString(from: entry.addedDate, dateStyle: .none, timeStyle: .short)
    } else {
      return DateFormatter.localizedString(from: entry.addedDate, dateStyle: .short, timeStyle: .short)
    }
  }

  // MARK: - Menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    var indexSet = IndexSet()
    let selectedRowIndexes = outlineView.selectedRowIndexes
    let clickedRow = outlineView.clickedRow
    if clickedRow != -1 {
      if selectedRowIndexes.contains(clickedRow) {
        indexSet = selectedRowIndexes
      } else {
        indexSet.insert(clickedRow)
      }
    }
    selectedEntries = indexSet.compactMap { outlineView.item(atRow: $0) as? PlaybackHistory }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.tag {
    case MenuItemTagShowInFinder:
      if selectedEntries.isEmpty { return false }
      let fileExistsMap = fileExistsMap
      return selectedEntries.contains { $0.url.isFileURL && (fileExistsMap[$0.url] ?? false) }
    case MenuItemTagDelete:
      // "Delete" in this case only removes from history
      return !selectedEntries.isEmpty
    case MenuItemTagPlay, MenuItemTagPlayInNewWindow:
      if selectedEntries.isEmpty { return false }
      let fileExistsMap = fileExistsMap
      return selectedEntries.contains { !$0.url.isFileURL || (fileExistsMap[$0.url] ?? false) }
    case MenuItemTagSearchFilename:
      menuItem.state = searchType == .filename ? .on : .off
    case MenuItemTagSearchFullPath:
      menuItem.state = searchType == .fullPath ? .on : .off
    default:
      break
    }
    return menuItem.isEnabled
  }

  // MARK: - IBActions

  @objc func doubleAction() {
    if let selected = outlineView.item(atRow: outlineView.clickedRow) as? PlaybackHistory {
      let player = PlayerManager.shared.getActiveOrCreateNew()
      player.openURL(selected.url)
    }
  }

  @IBAction func playAction(_ sender: AnyObject) {
    guard let firstEntry = selectedEntries.first else { return }
    PlayerManager.shared.getActiveOrCreateNew().openURL(firstEntry.url)
  }

  @IBAction func playInNewWindowAction(_ sender: AnyObject) {
    guard let firstEntry = selectedEntries.first else { return }
    PlayerManager.shared.getIdleOrCreateNew().openURL(firstEntry.url)
  }

  @IBAction func showInFinderAction(_ sender: AnyObject) {
    let urls = selectedEntries.compactMap { FileManager.default.fileExists(atPath: $0.url.path) ? $0.url: nil }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  @IBAction func deleteAction(_ sender: AnyObject) {
    removeAfterConfirmation(self.selectedEntries)
  }

  @IBAction func searchTypeFilenameAction(_ sender: AnyObject) {
    setSearchType(.filename)
  }

  @IBAction func searchTypeFullPathAction(_ sender: AnyObject) {
    setSearchType(.fullPath)
  }

  @IBAction func searchFieldAction(_ sender: NSSearchField) {
    // avoid reload if no change:
    guard searchString != sender.stringValue else { return }
    self.searchString = sender.stringValue
    UIState.shared.set(sender.stringValue, for: .uiHistoryTableSearchString)
    reloadHistoryData()
  }

  // MARK: Misc support functions

  private func setSearchType(_ newValue: Preference.HistorySearchType) {
    // avoid reload if no change:
    guard searchType != newValue else { return }
    searchType = newValue
    UIState.shared.set(newValue.rawValue, for: .uiHistoryTableSearchType)
    reloadHistoryData()
  }
  private func removeAfterConfirmation(_ entries: [PlaybackHistory]) {
    Utility.quickAskPanel("delete_history", sheetWindow: window) { respond in
      guard respond == .alertFirstButtonReturn else { return }
      HistoryController.shared.async {
        HistoryController.shared.remove(entries)
      }
    }
  }

  private static func getGroupByFromPrefs() -> Preference.HistoryGroupBy? {
    return UIState.shared.isRestoreEnabled ? Preference.enum(for: .uiHistoryTableGroupBy) : nil
  }

  private static func getHistorySearchTypeFromPrefs() -> Preference.HistorySearchType? {
    return UIState.shared.isRestoreEnabled ? Preference.enum(for: .uiHistoryTableSearchType) : nil
  }

  private static func getSearchStringFromPrefs() -> String? {
    return UIState.shared.isRestoreEnabled ? Preference.string(for: .uiHistoryTableSearchString) : nil
  }

  private func updateProgressColumnVisibility() {
    let showProgressCol = Preference.bool(for: .resumeLastPosition)
    let progressColIndex = outlineView.column(withIdentifier: .progress)
    guard progressColIndex >= 0 else { return }
    outlineView.tableColumns[progressColIndex].isHidden = !showProgressCol
  }

  // Change min width of "Played at" column
  private func adjustTimeColumnMinWidth() {
    guard let timeColumn = outlineView.tableColumn(withIdentifier: .time) else { return }
    let newMinWidth = timeColMinWidths[groupBy]!
    guard newMinWidth != timeColumn.minWidth else { return }
    if timeColumn.width < newMinWidth {
      if let filenameColumn = outlineView.tableColumn(withIdentifier: .filename) {
        donateColWidth(to: timeColumn, targetWidth: newMinWidth, from: filenameColumn)
      }
      if timeColumn.width < timeColumn.minWidth {
        if let progressColumn = outlineView.tableColumn(withIdentifier: .progress) {
          donateColWidth(to: timeColumn, targetWidth: newMinWidth, from: progressColumn)
        }
      }
    }
    // Do not set this until after width has been adjusted! Otherwise AppKit will change its width property
    // but will not actually resize it:
    timeColumn.minWidth = newMinWidth
    outlineView.needsLayout = true
    log.verbose("Updated \(timeColumn.identifier.rawValue.quoted) col width: \(timeColumn.width), minWidth: \(timeColumn.minWidth)")
  }

  private func donateColWidth(to targetColumn: NSTableColumn, targetWidth: CGFloat, from donorColumn: NSTableColumn) {
    let extraWidthNeeded = targetWidth - targetColumn.width
    // Don't take more than needed, or more than possible:
    let widthToDonate = min(extraWidthNeeded, max(donorColumn.width - donorColumn.minWidth, 0))
    if widthToDonate > 0 {
      log.verbose("Donating \(widthToDonate) pts width to col \(targetColumn.identifier.rawValue.quoted) from \(donorColumn.identifier.rawValue.quoted) width (\(donorColumn.width))")
      donorColumn.width -= widthToDonate
      targetColumn.width += widthToDonate
    }
  }

  private func getKey(_ entry: PlaybackHistory) -> String {
    switch groupBy {
    case .lastPlayedDay:
      return DateFormatter.localizedString(from: entry.addedDate, dateStyle: .medium, timeStyle: .none)
    case .parentFolder:
      return entry.url.deletingLastPathComponent().path
    }
  }

  func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
    var approvedSelectionIndexes = IndexSet()
    for index in proposedSelectionIndexes {
      let item = outlineView.item(atRow: index)
      // Allow selection only if item is a PlaybackHistory entry (not a String group header)
      if item is PlaybackHistory {
        approvedSelectionIndexes.insert(index)
      }
    }
    return approvedSelectionIndexes
  }
}

// MARK: - Liquid Glass

#if compiler(>=6.2)

extension HistoryWindowController {
  @available(macOS 26.0, *)
  func setupForLiquidGlass() {
    window?.titleVisibility = .visible
    window?.titlebarAppearsTransparent = false
    window?.collectionBehavior = .fullScreenAuxiliary
    let toolbar = NSToolbar(identifier: "history.window.toolbar") // dummy toolbar to make sidebar merge with titlebar
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsDisplayModeCustomization = false
    toolbar.allowsUserCustomization = false
    window?.toolbar = toolbar
  }
}

// MARK: - Toolbar for macOS 26+
@available(macOS 26.0, *)
private extension NSToolbarItem.Identifier {
  static let historySearchItem = NSToolbarItem.Identifier("HistorySearchItem")
  static let historyGroupByLabelItem = NSToolbarItem.Identifier("HistoryGroupByLabelItem")
  static let historyGroupByPopupItem = NSToolbarItem.Identifier("HistoryGroupByPopupItem")
}

@available(macOS 26.0, *)
extension HistoryWindowController: NSToolbarDelegate {
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      .sidebarTrackingSeparator,
      .flexibleSpace,
      .historyGroupByLabelItem,
      .historyGroupByPopupItem,
      .historySearchItem,
    ]
  }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    switch itemIdentifier {

    case .historyGroupByLabelItem:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      let label = NSTextField(labelWithString: "Group by:")
      label.textColor = .secondaryLabelColor
      item.view = label
      return item

    case .historyGroupByPopupItem:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)

      // Reuse the existing pop-up from the XIB
      let popup = groupByButton!
      popup.translatesAutoresizingMaskIntoConstraints = false
      popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
      
      item.view = popup
      return item

    case .historySearchItem:
      let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
      item.searchField.target = self
      item.searchField.action = #selector(searchFieldAction(_:))
      // replace the on in xib
      historySearchField = item.searchField
      return item

    default:
      return nil
    }
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(_ toolbar: NSToolbar, itemIdentifier: NSToolbarItem.Identifier, canBeInsertedAt index: Int) -> Bool {
    true
  }
}
#endif // compiler(>=6.2)


// MARK: - Other classes

class HistoryOutlineView: OutlineView {
  override func frameOfOutlineCell(atRow row: Int) -> NSRect {
    if row == 0 {
      // Disable disclosure triangle if showing No Results msg (which has no children)
      if let firstItem = item(atRow: row), numberOfChildren(ofItem: firstItem) == 0 {
        return .zero
      }
    }
    return super.frameOfOutlineCell(atRow: row)
  }

}

class HistoryFilenameCellView: NSTableCellView {
  @IBOutlet var docImage: NSImageView!
}

class HistoryProgressCellView: NSTableCellView {
  @IBOutlet var indicator: NSProgressIndicator!

  /// Prepares the receiver for service after it has been loaded from an Interface Builder archive, or nib file.
  /// - Important: As per Apple's [Internationalization and Localization Guide](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPInternational/SupportingRight-To-LeftLanguages/SupportingRight-To-LeftLanguages.html)
  ///     timeline indicators should not flip in a right-to-left language. This can not be set in the XIB.
  override func awakeFromNib() {
    indicator.userInterfaceLayoutDirection = .leftToRight
  }
}

fileprivate class LoadingPlaceholder: PlaybackHistory {
  init() {
    super.init(id: PlaybackID(URL(fileURLWithPath: "/dev/null")), duration: 0)
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  static let shared = LoadingPlaceholder()
}
