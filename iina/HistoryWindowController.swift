//
//  HistoryWindowController.swift
//  iina
//
//  Created by lhc on 28/4/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa
import SwiftUI
extension ToolbarItemPlacement {
  @available(macOS 13.0, *)
  static let toolOptionsBar = ToolbarItemPlacement(id: "com.companyname.toolOptions")
}
fileprivate extension NSUserInterfaceItemIdentifier {
  static let time = NSUserInterfaceItemIdentifier("Time")
  static let filename = NSUserInterfaceItemIdentifier("Filename")
  static let progress = NSUserInterfaceItemIdentifier("Progress")
  static let group = NSUserInterfaceItemIdentifier("Group")
  static let contextMenu = NSUserInterfaceItemIdentifier("ContextMenu")
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

// MARK: Constants

fileprivate let loadingKey = "Loading..."
fileprivate let noResultsKeyFormat = "No results found for \"%@\"."
fileprivate let loadingPlaceholderLabel = ""  // displayed next to the loading spinner

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

// 1. Create your SwiftUI toolbar view
struct HistoryToolbarView: View {
  @Binding var searchText: String
  @Binding var groupBy: Preference.HistoryGroupBy

  var onSearchTypeChange: (Preference.HistorySearchType) -> Void

  var body: some View {
    HStack(spacing: 4) {
      // Group by picker
      Picker("Group by:", selection: $groupBy) {
        Text("Day").tag(Preference.HistoryGroupBy.lastPlayedDay)
        Text("Folder").tag(Preference.HistoryGroupBy.parentFolder)
      }
      .pickerStyle(.segmented)

      Spacer().frame(width: 8)

      // Search field
      TextField("Search", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .frame(width: 200)

      Menu {
        Button("Filename") {
          onSearchTypeChange(.filename)
        }
        Button("Full Path") {
          onSearchTypeChange(.fullPath)
        }
      } label: {
        Image(systemName: "line.3.horizontal.decrease.circle")
          .imageScale(.large)
      }
      .menuStyle(.borderlessButton)
      .frame(width: 30, height: 20)
    }
    .padding(.horizontal, 8)
  }
}

class HistoryWindowController: WindowController, NSOutlineViewDelegate, NSOutlineViewDataSource,
                               NSMenuDelegate, NSMenuItemValidation, NSWindowDelegate {

  override var windowNibName: NSNib.Name {
    return NSNib.Name("HistoryWindowController")
  }

  // Add a hosting view property
  private var toolbarHostingView: NSHostingView<AnyView>?


  @IBOutlet weak var titleBarAccessoryContentView: NSView!
  @IBOutlet weak var outlineView: OutlineView!
  @IBOutlet weak var historySearchField: NSSearchField!
  @IBOutlet weak var groupByButton: NSPopUpButton!

  @IBOutlet weak var historyTableVerticalOffsetConstraint: NSLayoutConstraint!

  private var fileExistsMap: [URL: Bool] = [:]

  private let log: Logger.Subsystem
  private var notiHandler: NotificationHandler!

  @Atomic private var reloadTicketCounter: Int = 0
  private var isInitialLoadDone = false

  /// Calls `self.showLoadingUI` on timeout.
  private let showLoadingMsgTimer = TimeoutTimer(timeout: Constants.TimeInterval.historyTableDelayBeforeLoadingMsgDisplay)

  private var backgroundQueue = DispatchQueue.newDQ(label: "HistoryWindow-BG", qos: .background)

  // How the data is sorted
  var groupBy: Preference.HistoryGroupBy
  var searchType: Preference.HistorySearchType
  var searchString: String

  // These must only be updated in the main queue
  // There are still some possible races where data can go stale... Fix in a future version
  private var historyLookup: [URL: PlaybackHistory] = [LoadingPlaceholder.shared.url: LoadingPlaceholder.shared]
  private var historyData: [String: [URL]] = loadingData
  private var historyDataKeys: [String] = [loadingKey]

  private var selectedEntries: [PlaybackHistory] = []

  init() {
    log = HistoryController.shared.log

    groupBy = HistoryWindowController.getGroupByFromPrefs() ?? Preference.HistoryGroupBy.defaultValue
    searchType = HistoryWindowController.getHistorySearchTypeFromPrefs() ?? Preference.HistorySearchType.defaultValue
    searchString = HistoryWindowController.getSearchStringFromPrefs() ?? ""

    super.init(window: nil)
    windowFrameAutosaveName = WindowAutosaveName.playbackHistory.string

    showLoadingMsgTimer.action = showLoadingUI

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

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // History changed in a big or ambiguous way, requiring a full table reload
  private func onHistoryListUpdated(_ note: Notification) {
    log.verbose("History window received iinaHistoryListUpdated; will reload data")
    reloadHistoryData(useLoadingMsg: false)
  }

  // Individual history added or updated
  private func onFileHistoryDidUpdate(_ note: Notification) {
    assert(DispatchQueue.isExecutingIn(.main))
    guard !AppDelegate.shared.isTerminating else { return }

    guard let url = note.userInfo?["url"] as? URL else {
      log.error("Cannot update file history: no url found in userInfo!")
      return
    }

    // Enqueue in backgroundQueue to ensure happens-before relationship
    backgroundQueue.async { [self] in
      guard let entry = HistoryController.shared.history(forURL: url) else {
        log.error("Cannot update file history: no entry found for URL: \(url)")
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

  private func onFileExistsInfoDidUpdate(_ note: Notification) {
    assert(DispatchQueue.isExecutingIn(.main))
    guard !AppDelegate.shared.isTerminating else { return }

    // Reload table again to refresh statuses
    log.verbose("Reloading History table with updated fileExists data")
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

  func windowWillEnterFullScreen(_ notification: Notification) {
    historyTableVerticalOffsetConstraint.constant = 0
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    historyTableVerticalOffsetConstraint.constant = Constants.Distance.standardTitleBarHeight
  }

  override func windowDidLoad() {
    super.windowDidLoad()
    guard let window else { return }
    historySearchField.stringValue = searchString
    outlineView.delegate = self
    outlineView.dataSource = self
    outlineView.menu?.delegate = self
    outlineView.target = self
    outlineView.doubleAction = #selector(doubleAction)
    outlineView.sizeLastColumnToFit()

    // Create SwiftUI toolbar
    setupSwiftUIToolbar()

    // Add this to prevent vertical overlap with title
    historyTableVerticalOffsetConstraint.constant = Constants.Distance.standardTitleBarHeight

//    if #available(macOS 26.0, *) {
//      groupByButton.wantsLayer = true
//      groupByButton.borderShape = .capsule
//      groupByButton.layer?.cornerRadius = 10
//    }
//
//    // Add the visual effect as a title bar accessory
//    let accessory = NSTitlebarAccessoryViewController()
//    accessory.view = titleBarAccessoryContentView
//    accessory.layoutAttribute = .trailing
//    window.addTitlebarAccessoryViewController(accessory)
//
//    if #available(macOS 11.0, *) {
//      window.titlebarSeparatorStyle = .automatic  // or .line, .none, .shadow
//      accessory.automaticallyAdjustsSize = false
//    }

    window.backgroundColor = .clear
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)

    // Move your existing content into it
    if let visualEffectCV = window.contentView as? NSVisualEffectView {
      visualEffectCV.material = .titlebar
      visualEffectCV.blendingMode = .withinWindow
      visualEffectCV.state = .active
      visualEffectCV.autoresizingMask = [.width, .height]
    }

    // Workaround for problem: "group by" popup getting highlighted when window opens: make table first responder
    window.makeFirstResponder(outlineView)

    log.verbose("History windowDidLoad done")
  }

  private func setupSwiftUIToolbar() {
    guard let window else { return }

    let searchTextBinding = Binding(
      get: { self.searchString },
      set: { newValue in
        self.searchString = newValue
        UIState.shared.set(newValue, for: .uiHistoryTableSearchString)
        self.reloadHistoryData()
      }
    )

    let groupByBinding = Binding(
      get: { self.groupBy },
      set: { newValue in
        self.groupBy = newValue
        UIState.shared.set(newValue.rawValue, for: .uiHistoryTableGroupBy)
        self.reloadHistoryData()
      }
    )

    let onSearchTypeChange: (Preference.HistorySearchType) -> Void = { [weak self] newType in
      self?.setSearchType(newType)
    }

    // Create the SwiftUI view with bindings
    let toolbarView = HistoryToolbarView(
      searchText: searchTextBinding,
      groupBy: groupByBinding,
      onSearchTypeChange: onSearchTypeChange
    )

    let toolbarViewAnonymous = HStack(spacing: 4) {
      // Group by picker
      Picker("Group by:", selection: groupByBinding) {
        Text("Day").tag(Preference.HistoryGroupBy.lastPlayedDay)
        Text("Folder").tag(Preference.HistoryGroupBy.parentFolder)
      }
      .pickerStyle(.segmented)

      Spacer().frame(width: 8)

      // Search field
      TextField("Search", text: searchTextBinding)
        .textFieldStyle(.roundedBorder)
        .frame(width: 200)

      Menu {
        Button("Filename") {
          onSearchTypeChange(.filename)
        }
        Button("Full Path") {
          onSearchTypeChange(.fullPath)
        }
      } label: {
        Image(systemName: "line.3.horizontal.decrease.circle")
          .imageScale(.large)
      }
      .menuStyle(.borderlessButton)
      .frame(width: 30, height: 20)
    }
      .padding(.horizontal, 8)
    let accessory = NSTitlebarAccessoryViewController()
    let hostingView = NSHostingView(rootView: AnyView(toolbarViewAnonymous))
    accessory.view = hostingView
    accessory.layoutAttribute = .trailing
    accessory.isHidden = false
    hostingView.frame.size = hostingView.fittingSize
    // Set constraints for size
    NSLayoutConstraint.activate([
      hostingView.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
    ])

    log.debug("TOOLBAR HEIGHT: \(hostingView.fittingSize.height)")

    window.addTitlebarAccessoryViewController(accessory)

    // Store reference
    toolbarHostingView = hostingView

  }

  class OutlineColumnHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
      // Override background color
      drawsBackground = false

      super.draw(withFrame: cellFrame, in: controlView)
    }
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
      if HistoryController.shared.historyListVersion > 0 {
        reloadHistoryData()
      } else {
        // Load history if not started already:
        HistoryController.shared.start()
      }
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

  private func isTicketStillValid(_ ticket: Int) -> Bool {
    return ticket == reloadTicketCounter && !HistoryController.shared.isAppTerminating
  }

  func invalidateTicket() {
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
    if hasFilter && historyDataUpdated.isEmpty {
      log.trace("History window: showing No Results placeholder")
      let noResultsKey = String(format: noResultsKeyFormat, searchString)
      historyDataUpdated[noResultsKey] = []
      historyDataKeysUpdated = [noResultsKey]
    }

    DispatchQueue.main.async { [self] in
      guard isInitialLoad || isTicketStillValid(ticket) else { return }  // check ticket

      showLoadingMsgTimer.cancel()

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

  private func removeAfterConfirmation(_ entries: [PlaybackHistory]) {
    Utility.quickAskPanel("delete_history", sheetWindow: window) { respond in
      guard respond == .alertFirstButtonReturn else { return }
      HistoryController.shared.async {
        HistoryController.shared.remove(entries)
      }
    }
  }

  func updateProgressColumnVisibility() {
    let showProgressCol = Preference.bool(for: .resumeLastPosition)
    let progressColIndex = outlineView.column(withIdentifier: .progress)
    guard progressColIndex >= 0 else { return }
    outlineView.tableColumns[progressColIndex].isHidden = !showProgressCol
  }

  @objc func doubleAction() {
    if let selected = outlineView.item(atRow: outlineView.clickedRow) as? PlaybackHistory {
      let player = PlayerManager.shared.getActiveOrCreateNew()
      player.openURL(selected.url)
    }
  }

  // MARK: Key event

  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command  {
      switch event.charactersIgnoringModifiers! {
      case "f":
        window!.makeFirstResponder(historySearchField)
      case "a":
        outlineView.selectAll(nil)
      default:
        break
      }
    } else {
      let key = KeyCodeHelper.mpvKeyCode(from: event)
      if key == "DEL" || key == "BS" {
        let entries = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? PlaybackHistory }
        removeAfterConfirmation(entries)
      }
    }
  }

  // MARK: NSOutlineViewDelegate

  func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
    return isInitialLoadDone
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    return item is String
  }

  func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
    return item is String
  }

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    if let item = item {
      return historyData[item as! String]!.count
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
    rowView.backgroundColor = .clear
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let tableColumn else {
      // group header
      guard let groupCell: NSTableCellView = outlineView.makeView(withIdentifier: .group, owner: nil) as? NSTableCellView else { return nil }
      groupCell.wantsLayer = true
      groupCell.layer?.backgroundColor = .clear
      for subview in groupCell.subviews {
        subview.wantsLayer = true
        subview.layer?.backgroundColor = .clear
      }
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

  private func setSearchType(_ newValue: Preference.HistorySearchType) {
    // avoid reload if no change:
    guard searchType != newValue else { return }
    searchType = newValue
    UIState.shared.set(newValue.rawValue, for: .uiHistoryTableSearchType)
    reloadHistoryData()
  }

  @IBAction func searchFieldAction(_ sender: NSSearchField) {
    // avoid reload if no change:
    guard searchString != sender.stringValue else { return }
    self.searchString = sender.stringValue
    UIState.shared.set(sender.stringValue, for: .uiHistoryTableSearchString)
    reloadHistoryData()
  }

  // MARK: Misc support functions

  private static func getGroupByFromPrefs() -> Preference.HistoryGroupBy? {
    return UIState.shared.isRestoreEnabled ? Preference.enum(for: .uiHistoryTableGroupBy) : nil
  }

  private static func getHistorySearchTypeFromPrefs() -> Preference.HistorySearchType? {
    return UIState.shared.isRestoreEnabled ? Preference.enum(for: .uiHistoryTableSearchType) : nil
  }

  private static func getSearchStringFromPrefs() -> String? {
    return UIState.shared.isRestoreEnabled ? Preference.string(for: .uiHistoryTableSearchString) : nil
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

}


// MARK: - Other classes

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
