//
//  PlaylistViewController.swift
//  iina
//
//  Created by lhc on 17/8/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

fileprivate let prefixMinLength = 7
fileprivate let displayNameMinLength = 12

fileprivate let MenuItemTagCut = 601
fileprivate let MenuItemTagCopy = 602
fileprivate let MenuItemTagPaste = 603
fileprivate let MenuItemTagDelete = 604

fileprivate let isPlayingTextBlendFraction: CGFloat = 0.3
fileprivate let isPlayingPrefixTextBlendFraction: CGFloat = 0.4

fileprivate let playlistDraggableTypes: [NSPasteboard.PasteboardType] = [.nsFilenames, .nsURL, .iinaPlaylistItem, .string]

class PlaylistViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, SidebarTabGroupViewController {

  private(set) var currentTab: Sidebar.Tab = .playlist

  /** Similar to the one in `QuickSettingViewController`.
   Since IBOutlet is `nil` when the view is not loaded at first time,
   use this variable to cache which tab it need to switch to when the
   view is ready. The value will be handled after loaded.
   */
  private var pendingSwitchRequest: Sidebar.Tab?
  private var fileExistsMap: [URL: Bool] = [:]
  /// Currently displayed playlist rows. Should always be updated from `player.info.playlist`
  var displayedPlaylist: [PlaybackID] = []

  /// Cannot reliably scroll to current item until after the table finishes loading. So set this flag first.
  /// It will cause `scrollPlaylistToCurrentItem` to be called when done loading.
  var needsScrollToCurrentItem: Bool = true

  unowned var player: PlayerCore!
  unowned var pwc: PlayerWindowController! {
    didSet {
      self.player = pwc.player
    }
  }

  private var draggedRowInfo: (Int, IndexSet)? = nil

  // can't use main queue - it will block
  private var playlistTableReloadDebouncer = Debouncer(delay: 0.1, queue: PlayerCore.backgroundQueue)

  @Atomic private var playlistReloadTicket = 0

  @IBOutlet weak var playlistTableBackgroundView: NSView!
  @IBOutlet weak var chapterTableBackgroundView: NSView!
  @IBOutlet weak var playlistTableView: EditableTableView!
  @IBOutlet weak var chapterTableView: EditableTableView!
  @IBOutlet weak var playlistBtn: NSButton!
  @IBOutlet weak var chaptersBtn: NSButton!
  @IBOutlet weak var tabView: NSTabView!
  @IBOutlet weak var buttonTopConstraint: NSLayoutConstraint!
  @IBOutlet weak var tabHeightConstraint: NSLayoutConstraint!
  @IBOutlet weak var deleteBtn: NSButton!
  @IBOutlet weak var loopBtn: NSButton!
  @IBOutlet weak var shuffleBtn: NSButton!
  @IBOutlet weak var sortBtn: NSButton!
  @IBOutlet weak var totalLengthLabel: NSTextField!
  @IBOutlet var subPopover: NSPopover!
  @IBOutlet var addFileMenu: NSMenu!
  @IBOutlet weak var addBtn: NSButton!
  @IBOutlet weak var removeBtn: NSButton!
  
  @Atomic private var playlistTotalLengthIsReady = false
  @Atomic private var playlistTotalLength: Double? = nil
  private var lastNowPlayingIndex: Int = -1

  private var downshift: CGFloat = 0
  private var tabHeight: CGFloat = 0

  fileprivate var isPlayingTextColor: NSColor = .textColor
  fileprivate var isPlayingPrefixTextColor: NSColor = .secondaryLabelColor

  private var playlistDragDelegate: TableDragDelegate<PlaybackID>!

  override var nibName: NSNib.Name {
    return NSNib.Name("PlaylistViewController")
  }

  private var notiHandler: NotificationHandler!

#if DEBUG
  private let enablePrefetching = Preference.bool(for: .prefetchPlaylistVideoDuration) && !DebugConfig.disableLookaheadCaches
#else
  private let enablePrefetching = Preference.bool(for: .prefetchPlaylistVideoDuration)
#endif

  func updateTableColors() {
    player.log.verbose("Playlist sidebar: updating table colors")
    // Need to use this closure for dark/light mode toggling to get picked up while running (not sure why...)
    let effectiveAppearance = view.window?.effectiveAppearance ?? view.effectiveAppearance
    effectiveAppearance.applyAppearanceFor {
      if #available(macOS 10.14, *) {
        isPlayingTextColor = NSColor.controlAccentColor.blended(withFraction: isPlayingTextBlendFraction, of: .textColor)!
        isPlayingPrefixTextColor = NSColor.controlAccentColor.blended(withFraction: isPlayingPrefixTextBlendFraction, of: .textColor)!

        // Need a dedicated view behind each table to use for background color.
        // NSTableView & its component views don't support translucent background color.
        // Also note: CGColor does not support dark mode, so the view layer needs to be updated
        // explicitly whenever the appearance changes.
        let tableBackgroundColor = NSColor.sidebarTableBackground.cgColor
        playlistTableBackgroundView.wantsLayer = true
        playlistTableBackgroundView.layer?.backgroundColor = tableBackgroundColor
      }
    }
    reloadData(playlist: true, chapters: true, animate: false)
  }

  func setVerticalConstraints(downshift: CGFloat, tabHeight: CGFloat) {
    if (self.downshift != downshift) || (self.tabHeight != tabHeight) {
      self.downshift = downshift
      self.tabHeight = tabHeight
      updateVerticalConstraints()
    }
  }

  private func updateVerticalConstraints() {
    // may not be available until after load
    player.log.verbose("Playlist: updating downshift=\(downshift), tabHeight=\(tabHeight)")
    self.buttonTopConstraint?.animateToConstant(downshift)
    self.tabHeightConstraint?.animateToConstant(tabHeight)
    view.needsLayout = true
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.idString = "PlaylistView"

    withAllTableViews { (view) in
      view.dataSource = self
    }
    playlistTableView.menu?.delegate = self
    playlistTableView.editableDelegate = self
    playlistTableView.selectNextRowAfterDelete = player.playlistTableSelectNextRowAfterDelete
    playlistTableView.drawBackgroundForEmptyRows = true
    chapterTableView.drawBackgroundForEmptyRows = true

    playlistDragDelegate = TableDragDelegate<PlaybackID>("Playlist", playlistTableView,
                                                         acceptableDraggedTypes: playlistDraggableTypes,
                                                         tableChangeNotificationName: player.playlistTableChangeNotificationName,
                                                         getFromPasteboardFunc: readPlaylistItemsFromPasteboard,
                                                         getAllCurentFunc: { self.displayedPlaylist },
                                                         moveFunc: { [self] rowIndexes, targetRowIndex in
      /// Drag & drop within `playlistTableView`
      player.movePlaylistRows(from: rowIndexes, to: targetRowIndex, .registerUndoRedo)

    }, insertFunc: { [self] desiredRowList, targetRowIndex in
      player.insertPlaylistRows(desiredRowList, at: targetRowIndex, .registerUndoRedo)
    },
                                                         removeFunc: { [self] rowIndexes in
      player.removePlaylistRows(rowIndexes, .registerUndoRedo)
    })

    [deleteBtn, loopBtn, shuffleBtn].forEach {
      $0?.image?.isTemplate = true
      $0?.alternateImage?.isTemplate = true
    }

    if #unavailable(macOS 11.0) {
      sortBtn.image = NSImage.init(named: "triangle-down")
      sortBtn.image?.isTemplate = true
    }

    deleteBtn.toolTip = NSLocalizedString("mini_player.delete", comment: "delete")
    loopBtn.toolTip = NSLocalizedString("mini_player.loop", comment: "loop")
    shuffleBtn.toolTip = NSLocalizedString("mini_player.shuffle", comment: "shuffle")
    addBtn.toolTip = NSLocalizedString("mini_player.add", comment: "add")
    removeBtn.toolTip = NSLocalizedString("mini_player.remove", comment: "remove")
    sortBtn.toolTip = NSLocalizedString("mini_player.sort", comment: "sort")

    hideTotalLength()
    updateTableColors()  // this will also load data for tables

    // handle pending switch tab request
    if pendingSwitchRequest == nil {
      // Initial display: need to draw highlight for currentTab
      updateTabButtonSelection()
    } else {
      switchToTab(pendingSwitchRequest!)
      pendingSwitchRequest = nil
    }

    updateVerticalConstraints()

    if !enablePrefetching {
      player.log.debug("Playlist: video duration prefetch is disabled")
    }

    // register for double click action
    let action = #selector(performDoubleAction(sender:))
    playlistTableView.doubleAction = action
    playlistTableView.target = self
    chapterTableView.doubleAction = action
    chapterTableView.target = self

    (subPopover.contentViewController as! SubPopoverViewController).player = player
    if let popoverView = subPopover.contentViewController?.view,
      popoverView.trackingAreas.isEmpty {
      popoverView.addTrackingArea(NSTrackingArea(rect: popoverView.bounds,
                                                 options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                                 owner: pwc, userInfo: [PlayerWindowController.TrackingArea.key: PlayerWindowController.TrackingArea.playerWindow]))
    }

    notiHandler = NotificationHandler(player.log, [], [
      .default: [
        .init(.iinaPlaylistChanged, object: player) { [self] _ in
          guard player.playlistShown else {
            player.log.verbose("Got iinaPlaylistChanged, but playlist is not visible. Ignoring")
            return
          }

          player.log.verbose("Got iinaPlaylistChanged (enablePrefetch=\(enablePrefetching.yn)); reloading playlist table…")
          playlistTotalLengthIsReady = false
          reloadData(playlist: true, chapters: false)
        },

          .init(.iinaFileHistoryDidUpdate) { [self] note in
            guard !AppDelegate.shared.isTerminating else { return }
            guard let url = note.userInfo?["url"] as? URL else {
              player.log.error("Cannot update file history: no url found in userInfo!")
              return
            }
            guard url.isFileURL else { return }
            let playlist = displayedPlaylist
            for (rowIndex, item) in playlist.enumerated() {
              if item.url == url {
                reloadPlaylistRow(rowIndex)
              }
            }
          },

          .init(.iinaFileExistsInfoDidUpdate) { [self] note in
            guard !AppDelegate.shared.isTerminating else { return }
            // Just cache this for local use. Doesn't change the displayed table rows
            self.fileExistsMap = HistoryController.shared.fileExistsMap
          }
      ]
    ])
    notiHandler.addAllObservers()

    // Register this sidebar for dragged files, just so we can deny all drops onto the sidebar
    // not including the Playlist table. See note in QuickSettingsViewController.viewDidLoad().
    view.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL])

    view.configureSubtreeForCoreAnimation()
    view.needsLayout = true
    player.log.verbose("PlaylistView viewDidLoad done")
  }

  deinit {
    notiHandler.removeAllObservers()
  }

  func scrollPlaylistToCurrentItem() {
    // Execute in pipeline task to prevent hiccups if running other animations
    pwc.animationPipeline.submitInstantTask{ [self] in
      guard let playlistTableView else { return }
      if let entryIndex = player.info.currentPlayback?.playlistPos {
        player.log.verbose("Scrolling playlist table to index \(entryIndex)")
        guard isViewLoaded else {
          player.log.verbose("Playlist table not loaded yet, skipping scroll")
          return
        }
        playlistTableView.scrollRowToVisible(entryIndex)
      }
    }
  }

  /// Use `animate: false` only for initial load, to avoid seeing a briefly empty table
  func reloadData(playlist: Bool, chapters: Bool, animate: Bool = true) {
    guard player.isActive else { return }
    guard pwc.currentLayout.isMusicMode || pwc.isOpen(sidebarTabGroup: .playlist) else { return }

    if playlist {
      playlistTableReloadDebouncer.run { [self] in
        player.mpv.queue.async { [self] in
          reloadPlaylistTable(animate: animate)
        }
      }
    }

    if chapters {
      pwc.animationPipeline.submitInstantTask { [self] in
        player.log.verbose("Reloading chapters table for \(player.info.chapters.count) entries")
        chapterTableView.reloadData()
      }
    }
  }

  /// If `animate` is false, does a full reload instantly.
  private func reloadPlaylistTable(animate: Bool) {
    // Be sure to access playlist data only from within mpv queue
    assert(DispatchQueue.isExecutingIn(player.mpv.queue))
    let oldPlaylistRows = displayedPlaylist
    let newPlaylistRows = player.info.playlist
    displayedPlaylist = newPlaylistRows

    let doAfterReload: () -> Void = { [self] in
      refreshNowPlayingIndex()
      updateCachesForAllItems()
      removeBtn.isEnabled = !playlistTableView.selectedRowIndexes.isEmpty
      if needsScrollToCurrentItem {
        needsScrollToCurrentItem = false
        scrollPlaylistToCurrentItem()
      }
    }

    if animate {
      let tableUIChange = TableUIChangeBuilder.shared.buildDiff(oldRows: oldPlaylistRows,
                                                                newRows: newPlaylistRows, completionHandler: { _ in
        self.pwc.animationPipeline.submitInstantTask {
          doAfterReload()
        }
      })
      player.log.verbose("Updating playlist table via diff")
      playlistTableView.post(tableUIChange)
    } else {
      pwc.animationPipeline.submitInstantTask { [self] in
        player.log.trace("Updating playlist table via reloadData")
        playlistTableView.reloadData()
        doAfterReload()
      }
    }
  }

  private func showTotalLength() {
    guard let playlistTotalLength = playlistTotalLength, playlistTotalLengthIsReady else { return }
    totalLengthLabel.isHidden = false
    if playlistTableView.numberOfSelectedRows > 0 {
      let info = player.info
      let selectedDuration = info.calculateTotalDuration(playlistTableView.selectedRowIndexes)
      totalLengthLabel.stringValue = String(format: NSLocalizedString("playlist.total_length_with_selected", comment: "%@ of %@ selected"),
                                            VideoTime(selectedDuration).stringRepresentation,
                                            VideoTime(playlistTotalLength).stringRepresentation)
    } else {
      totalLengthLabel.stringValue = String(format: NSLocalizedString("playlist.total_length", comment: "%@ in total"),
                                            VideoTime(playlistTotalLength).stringRepresentation)
    }
  }

  private func hideTotalLength() {
    totalLengthLabel.isHidden = true
  }

  private func refreshTotalLength() {
    assert(DispatchQueue.isExecutingIn(PlayerCore.backgroundQueue))

    if let totalDuration = player.info.calculateTotalDuration() {
      player.log.trace("Playlist: recalculated total duration: \(totalDuration)")
      playlistTotalLengthIsReady = true
      playlistTotalLength = totalDuration
    } else {
      player.log.verbose("Playlist: failed to recaculate total duration; hiding length label")
    }
    pwc.animationPipeline.submitInstantTask {
      self.showTotalLength()
    }
  }

  func updateLoopBtnStatus() {
    guard isViewLoaded else { return }
    player.mpv.queue.async { [self] in
      let loopMode = player.getLoopMode()
      pwc.animationPipeline.submitInstantTask { [self] in
        switch loopMode {
        case .off:  loopBtn.state = .off
        case .file: loopBtn.state = .on
        default:    loopBtn.state = .mixed
        }
        loopBtn.alternateImage = NSImage.init(named: loopBtn.state == .on ? "loop_file" : "loop_dark")
      }
    }
  }

  // MARK: - Tab switching

  /** Switch tab (call from other objects) */
  func pleaseSwitchToTab(_ tab: Sidebar.Tab) {
    if isViewLoaded {
      switchToTab(tab)
    } else {
      // cache the request
      pendingSwitchRequest = tab
    }
  }

  /** Switch tab (for internal call) */
  private func switchToTab(_ tab: Sidebar.Tab) {
    guard tab.group == .playlist else {
      player.log.error("PlaylistViewController: cannot switch to tab: \(tab)")
      return
    }
    assert(pwc.isInMiniPlayer || pwc.isOpen(sidebarTabGroup: .playlist),
           "switchToTab should not be called when playlist TabGroup is not shown or not in music mode")
    guard currentTab != tab else { return }
    let buttonTag: Int
    switch tab {
    case .playlist:
      reloadData(playlist: true, chapters: false)
      scrollPlaylistToCurrentItem()
      updateLoopBtnStatus()
      /// The observer for `iinaPlaylistChanged` may not have loaded in time to be triggered; kick it off manually.
      PlayerCore.backgroundQueue.asyncAfter(deadline: .now() + Constants.TimeInterval.initialPlaylistDelayBeforePrefetch) { [self] in
        updateCachesForAllItems()
      }
      refreshNowPlayingIndex(thenScrollToVisible: true)
      buttonTag = 0
    case .chapters:
      reloadData(playlist: false, chapters: true)
      buttonTag = 1
    default:
      Logger.fatal("PlaylistViewController: invalid tab requested for switching: \(tab)")
    }
    tabView.selectTabViewItem(at: buttonTag)

    currentTab = tab
    updateTabButtonSelection()
    pwc.didChangeTab(to: tab)
  }

  // Updates display of all tabs buttons to indicate that the given tab is active and the rest are not
  private func updateTabButtonSelection() {
    updateTabActiveStatus(for: playlistBtn, isActive: currentTab == .playlist)
    updateTabActiveStatus(for: chaptersBtn, isActive: currentTab == .chapters)
  }

  // MARK: - NSTableViewDataSource

  func numberOfRows(in tableView: NSTableView) -> Int {
    if tableView == playlistTableView {
      let playlist = displayedPlaylist
      return playlist.count
    } else if tableView == chapterTableView {
      return player.info.chapters.count
    } else {
      return 0
    }
  }

  // MARK: - Drag and Drop

  @objc func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    return playlistDragDelegate.draggingSession(session, sourceOperationMaskFor: context)
  }

  /// Drag start: set session variables.
  @objc func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
    playlistDragDelegate.tableView(tableView, draggingSession: session, willBeginAt: screenPoint, forRowIndexes: rowIndexes)
  }

  @objc func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    playlistDragDelegate.tableView(tableView, draggingSession: session, endedAt: screenPoint, operation: operation)
  }

  @objc func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow rowIndex: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
    return playlistDragDelegate.tableView(tableView, validateDrop: info, proposedRow: rowIndex, proposedDropOperation: dropOperation)
//    return player.acceptFromPasteboard(info, isPlaylist: true)  // FIXME: reconcile with this old code
  }

  /// Accept the drop and execute changes, or reject drop.
  ///
  /// Remember that we can expect the following (see notes in `tableView(_, validateDrop, …)`)
  /// 1. `0 <= targetRowIndex <= rowCount`
  /// 2. `dropOperation = .above`.
  @objc func tableView(_ tableView: NSTableView,
                       acceptDrop info: NSDraggingInfo, row targetRowIndex: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
    return playlistDragDelegate.tableView(tableView, acceptDrop: info, row: targetRowIndex, dropOperation: dropOperation)
  }

  // MARK: - Playlist Table CRUD

  private func validateItemsAreEqual(_ current: [PlaybackID], _ expected: [PlaybackID]) -> Bool {
    let currentPlaylistPaths = current.map{ $0.path }
    return (currentPlaylistPaths.count == expected.count) && expected.map({$0.path}).elementsEqual(currentPlaylistPaths)
  }

  private func copyPlaylistRowsToPasteboard(_ rowIndexes: IndexSet, to pboard: NSPasteboard) {
    player.log.verbose("Copying playlist indexes to pasteboard: \(rowIndexes.toArray())")
    do {
      let indexesData = try NSKeyedArchiver.archivedData(withRootObject: rowIndexes, requiringSecureCoding: true)
      let playlist = displayedPlaylist
      pboard.declareTypes([.iinaPlaylistItem, .nsFilenames, .nsURL], owner: playlistTableView)
      pboard.setData(indexesData, forType: .iinaPlaylistItem)
      let filePaths = rowIndexes.compactMap{ $0 < playlist.count ? playlist[$0].filePath : nil }
      pboard.setPropertyList(filePaths, forType: .nsFilenames)
      let paths = rowIndexes.compactMap{ $0 < playlist.count ? playlist[$0].path : nil }
      pboard.setPropertyList(paths, forType: .nsURL)

    } catch {
      // Internal error, archivedData should not fail.
      player.log.error("Failed to copy from playlist to pasteboard: \(error)")
    }
  }

  private func readPlaylistItemsFromPasteboard(_ pboard: NSPasteboard) -> [PlaybackID] {
    if let filenamePaths = pboard.propertyList(forType: .nsFilenames) as? [String] {
      let playableFiles = Utility.resolveURLs(player.getPlayableFiles(in: filenamePaths.map {
        $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : URL(string: $0)!
      }))
      return playableFiles.map { PlaybackID($0) }
    } else if let urlPaths = pboard.propertyList(forType: .nsURL) as? [String] {
      return urlPaths.compactMap{ PlaybackID(path: $0) }
    } else if let droppedString = pboard.string(forType: .string), Regex.url.matches(droppedString) {
      return [droppedString].compactMap{ PlaybackID(URL(string: $0)) }
    } else {
      return []
    }
  }

  @discardableResult
  func pasteFromPasteboard(from pboard: NSPasteboard) -> Bool {
    let playlistItems = readPlaylistItemsFromPasteboard(pboard)
    player.log.verbose("User pasted \(playlistItems.count) items from pasteboard into playlist")

    guard !playlistItems.isEmpty else {
      return false
    }
    let insertIndex: Int
    if let lastSelectedRowIndex = playlistTableView.selectedRowIndexes.last {
      insertIndex = lastSelectedRowIndex + 1
    } else {
      insertIndex = playlistTableView.numberOfRows
    }
    player.insertPlaylistRows(playlistItems, at: insertIndex, .registerUndoRedo)
    return true
  }

  func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
    if tableView == playlistTableView {
      copyPlaylistRowsToPasteboard(rowIndexes, to: pboard)
      return true
    }
    return false
  }


  // MARK: - private methods

  private func withAllTableViews(_ block: (NSTableView) -> Void) {
    block(playlistTableView)
    block(chapterTableView)
  }

  // MARK: - IBActions

  @IBAction func addToPlaylistBtnAction(_ sender: NSButton) {
    addFileMenu.popUp(positioning: nil, at: .zero, in: sender)
  }

  @IBAction func removeBtnAction(_ sender: NSButton) {
    player.removePlaylistRows(playlistTableView.selectedRowIndexes, .registerUndoRedo)
  }

  @IBAction func addFileAction(_ sender: AnyObject) {
    Utility.quickMultipleOpenPanel(title: "Add to playlist", canChooseDir: true) { [self] urls in
      let rows = urls.map{ PlaybackID($0) }
      player.insertPlaylistRows(rows, at: displayedPlaylist.count, .registerUndoRedo)
    }
  }

  @IBAction func addURLAction(_ sender: AnyObject) {
    Utility.quickPromptPanel("add_url") { [self] url in
      if Regex.url.matches(url) {
        player.appendToPlaylist(url)
      } else {
        Utility.showAlert("wrong_url_format")
      }
    }
  }

  @IBAction func clearPlaylistBtnAction(_ sender: AnyObject) {
    player.clearPlaylist()
    player.sendOSD(.clearPlaylist)
  }

  @IBAction func playlistBtnAction(_ sender: AnyObject) {
    switchToTab(.playlist)
  }

  @IBAction func chaptersBtnAction(_ sender: AnyObject) {
    switchToTab(.chapters)
  }

  @IBAction func loopBtnAction(_ sender: NSButton) {
    player.nextLoopMode()
  }

  @IBAction func shuffleBtnAction(_ sender: AnyObject) {
    player.toggleShuffle()
  }


  @objc func performDoubleAction(sender: AnyObject) {
    guard let tv = sender as? NSTableView, tv.numberOfSelectedRows > 0 else { return }
    if tv == playlistTableView {
      player.playFileInPlaylist(tv.selectedRow)
    } else {
      let index = tv.selectedRow
      player.playChapter(index)
    }
    tv.deselectAll(self)
    tv.reloadData()
  }

  @IBAction func prefixBtnAction(_ sender: PlaylistPrefixButton) {
    sender.isFolded = !sender.isFolded
  }

  @IBAction func subBtnAction(_ sender: NSButton) {
    let row = playlistTableView.row(for: sender)
    guard let vc = subPopover.contentViewController as? SubPopoverViewController else { return }
    let playlist = displayedPlaylist
    guard row < playlist.count else { return }
    vc.filePath = playlist[row].url.path
    vc.tableView.reloadData()
    subPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
  }

  @IBAction func sortingBtnAction(_ sender: NSButton) {
    let menu = NSMenu()
    if #available(macOS 14.0, *) {
      menu.addItem(.sectionHeader(title: NSLocalizedString("playlist.sorting.header", comment: "Sorting")))
    }
    menu.addItem(withTitle: NSLocalizedString("playlist.sorting.filename_ascending", comment: "Filename Ascending"), action: #selector(sortPathAscending), keyEquivalent: "")
    menu.addItem(withTitle: NSLocalizedString("playlist.sorting.filename_descending", comment: "Filename Descending"), action: #selector(sortPathDesecnding), keyEquivalent: "")
    menu.addItem(withTitle: NSLocalizedString("playlist.sorting.path_ascending", comment: "File Path Ascending"), action: #selector(sortPathAscending), keyEquivalent: "")
    menu.addItem(withTitle: NSLocalizedString("playlist.sorting.path_descending", comment: "File Path Descending"), action: #selector(sortPathDesecnding), keyEquivalent: "")
    NSMenu.popUpContextMenu(menu, with: NSApplication.shared.currentEvent!, for: sender)
  }

  @objc func sortNameAscending() { sortName(ascending: true) }
  @objc func sortNameDesecnding() { sortName(ascending: false) }
  @objc func sortPathAscending() { sortPath(ascending: true) }
  @objc func sortPathDesecnding() { sortPath(ascending: false) }

  private func sortName(ascending: Bool) {
    var playlist = player.info.playlist
    playlist.sort(by: {
      let results = $0.displayName < $1.displayName
      return ascending ? results : !results
    })
    player.playlistReorder(newPlaylist: playlist)
  }

  private func sortPath(ascending: Bool) {
    var playlist = player.info.playlist
    playlist.sort(by: {
      let results = $0.path < $1.path
      return ascending ? results : !results
    })
    player.playlistReorder(newPlaylist: playlist)
  }

  // MARK: - Table delegates

  func tableViewSelectionDidChange(_ notification: Notification) {
    let tv = notification.object as! NSTableView
    if tv == playlistTableView {
      showTotalLength()

      removeBtn.isEnabled = !playlistTableView.selectedRowIndexes.isEmpty
      return
    }
  }

  // Updates index of playing item. Don't need to reload whole playlist
  func refreshNowPlayingIndex(setNewIndexTo newNowPlayingIndex: Int? = nil,
                              forceRedraw: Bool = false, thenScrollToVisible: Bool = false) {
    assert(DispatchQueue.isExecutingIn(.main))
    guard isViewLoaded else { return }
    guard !view.isHidden else { return }

    let oldNowPlayingIndex = lastNowPlayingIndex
    let newNowPlayingIndex = newNowPlayingIndex ?? player.info.currentPlayback?.playlistPos ?? oldNowPlayingIndex
    if newNowPlayingIndex != oldNowPlayingIndex {
      player.log.verbose("Updating nowPlayingIndex: \(oldNowPlayingIndex) → \(newNowPlayingIndex)")
      self.lastNowPlayingIndex = newNowPlayingIndex
    } else if !forceRedraw {
      return
    }

    // If "now playing" row changed, make sure the new "now playing" row is redrawn to show its new status...
    loadCachedItem(forRowIndex: newNowPlayingIndex, force: true)
    // ... also make sure the old "now playing" row is redrawn so it loses its status
    loadCachedItem(forRowIndex: oldNowPlayingIndex, force: true)

    // The calls to loadCachedItem should refresh the given indexes, but will go through multiple queues
    // to do so and may be delayed by a minute or more. We need to update the nowPlaying status ASAP,
    // so just add extra redraws right away:
    reloadPlaylistRow(newNowPlayingIndex)
    reloadPlaylistRow(oldNowPlayingIndex)

    if thenScrollToVisible {
      playlistTableView.scrollRowToVisible(newNowPlayingIndex)
    }
  }

  func reloadPlaylistRow(_ rowIndex: Int) {
    assert(DispatchQueue.isExecutingIn(.main))
    reloadPlaylistRows(IndexSet(integer: rowIndex))
  }

  /// Reload all rows if not specified
  func reloadPlaylistRows(_ rows: IndexSet? = nil) {
    // Enqueue this asynchronously to prevent it from causing hiccups if other animations are in progress
    pwc.animationPipeline.submitInstantTask{ [self] in
      let rows = rows ?? IndexSet(integersIn: 0..<playlistTableView.numberOfRows)
      playlistTableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0...1))
    }
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let identifier = tableColumn?.identifier else { return nil }
    let v = tableView.makeView(withIdentifier: identifier, owner: self) as! NSTableCellView

    if tableView == playlistTableView {  // Playlist table
      refreshNowPlayingIndex()  // make sure this is up-to-date
      // use cached value
      let isPlaying = self.lastNowPlayingIndex == row

      switch identifier {
      case .isChosen:
        let pointer = view.userInterfaceLayoutDirection == .rightToLeft ? Constants.String.blackLeftPointingTriangle : Constants.String.blackRightPointingTriangle
        // ▶︎ Is Playing icon
        let text = isPlaying ? pointer : ""
        v.textField?.setFormattedText(stringValue: text, textColor: isPlayingTextColor)
      case .trackName:
        let cellView = v as! PlaylistTrackCellView
        updateCellForPlaylistTrackNameColumn(cellView, rowIndex: row, isPlaying: isPlaying)
      default:
        Logger.fatal("Unknown identifier in Playlist table: \(identifier)")
      }
      return v

    } else if tableView == chapterTableView {  // Chapters table

      let chapters = player.info.chapters
      guard row < chapters.count else { return nil }
      let chapter = chapters[row]

      // next chapter time
      let nextChapterTime = chapters[at: row+1]?.startTime ?? Double.infinity
      let isCurrentChapter = player.info.chapter == row
      let textColor = isCurrentChapter ? isPlayingTextColor : .controlTextColor

      switch identifier {
      case .isChosen:
        // left column
        let pointerGlyph: String
        if isCurrentChapter {
          pointerGlyph = view.userInterfaceLayoutDirection == .rightToLeft ?
          Constants.String.blackLeftPointingTriangle :  Constants.String.blackRightPointingTriangle
        } else {
          pointerGlyph = ""
        }
        v.setTitle(pointerGlyph, textColor: textColor)
      case .trackName:
        // right column
        let titleString = chapter.title.isEmpty ? "Chapter \(row)" : chapter.title
        v.setTitle(titleString, textColor: textColor)
        let cellView = v as! ChapterTableCellView
        let durationText = "\(VideoTime.string(from: chapter.startTime)) → \(VideoTime.string(from: nextChapterTime))"
        cellView.durationTextField.setText(durationText, textColor: textColor)
      default:
        Logger.fatal("Unknown identifier in Chapters table: \(identifier)")
      }
      return v
    }

    return nil
  }

  private var wantsPlaylistTitleDisplayed: Bool {
    guard Preference.bool(for: .playlistShowMetadata) else { return false }
    let onlyInMusicMode = Preference.bool(for: .playlistShowMetadataInMusicMode)
    if onlyInMusicMode {
      return player.isInMiniPlayer
    }
    return true
  }

  /// Rebuilds playlist table's `Track Name` column cell
  private func updateCellForPlaylistTrackNameColumn(_ cellView: PlaylistTrackCellView, rowIndex: Int, isPlaying: Bool) {
    guard let cachedMeta = loadCachedItem(forRowIndex: rowIndex) else {
      player.log.error("No playlist item found for rowIndex \(rowIndex). Skipping cell update")
      return
    }

    let wantsTitleDisplayed = wantsPlaylistTitleDisplayed
    let displayName = (wantsTitleDisplayed ? cachedMeta.title : nil) ?? cachedMeta.id.displayName
    let artist = wantsTitleDisplayed ? cachedMeta.artist : nil

    player.log.trace("Building row \(rowIndex) of playlist: \(displayName.quoted)")

    let textColor = isPlaying ? isPlayingTextColor : .controlTextColor
    let prefixTextColor = isPlaying ? isPlayingPrefixTextColor : .secondaryLabelColor

    // Title, artist, prefix
    if Preference.bool(for: .shortenFileGroupsInPlaylist),
       let prefix = player.info.currentVideosInfo.first(where: { $0.url == cachedMeta.id.url })?.prefix,
       !prefix.isEmpty,
       prefix.count <= displayName.count,  // check whether prefix length > displayName length
       prefix.count >= prefixMinLength,
       displayName.count > displayNameMinLength {
      cellView.setPrefix(prefix, textColor: prefixTextColor)
      cellView.setAdditionalInfo(nil)
      cellView.setTitle(String(displayName[displayName.index(displayName.startIndex, offsetBy: prefix.count)...]), textColor: textColor)
    } else {
      cellView.setPrefix(nil, textColor: prefixTextColor)
      cellView.setAdditionalInfo(artist, textColor: textColor)
      cellView.setTitle(displayName, textColor: textColor)
    }

    // playback progress and duration
    cellView.durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    if let duration = cachedMeta.duration {
      let durationString = VideoTime(duration).stringRepresentation
      let durationTextColor = isPlaying ? isPlayingTextColor : .secondaryLabelColor
      cellView.durationLabel.setFormattedText(stringValue: durationString, textColor: durationTextColor)
    } else {
      cellView.durationLabel.stringValue = ""
    }
    if let progress = cachedMeta.progress, let duration = cachedMeta.duration {
      cellView.playbackProgressView.layerContentsRedrawPolicy = .duringViewResize
      cellView.playbackProgressView.percentage = progress / duration
      cellView.playbackProgressView.isHidden = false
    } else {
      cellView.playbackProgressView.isHidden = true
    }

    // sub button
    if !player.info.isMatchingSubtitles,
       let matchedSubs = player.info.getMatchedSubs(cachedMeta.id.path), !matchedSubs.isEmpty {
      cellView.setDisplaySubButton(true)
    } else {
      cellView.setDisplaySubButton(false)
    }
    // not sure why this line exists, but let's keep it for now
    cellView.subBtn.image?.isTemplate = true
  }

  @discardableResult
  private func loadCachedItem(forRowIndex rowIndex: Int, force: Bool = false) -> MediaMeta? {
    guard rowIndex >= 0 else { return nil }
    let playlistItems = displayedPlaylist
    player.log.trace("Playlist: reloading cache for row \(rowIndex)/\(playlistItems.count)\(force ? " (forced)" : "")")
    guard rowIndex < playlistItems.count else { return nil }
    let playlistItem = playlistItems[rowIndex]
    let url = playlistItem.url

    var existingCachedMeta = MediaMetaCache.shared.getOrAddCachedMeta(for: playlistItem)

    let needsRefresh = force || (url.isFileURL && !existingCachedMeta.triedFFmpeg)
    if needsRefresh {
      // Kick this off, but return the existing (possibly stale) data below for efficiency
      player.mpv.queue.async { [self] in
        guard player.isActive else { return }
        // Get updated title from mpv
        let mpvTitle = player.mpv.getString(MPVProperty.playlistNTitle(rowIndex))

        // Check cache again; we don't know how much time has passed since last access & want to avoid redundant file access
        existingCachedMeta = MediaMetaCache.shared.updateCachedMeta(playlistItem,
                                                                    reloadFromWatchLater: false, reloadFromFFmpeg: false,
                                                                    mpvTitle: mpvTitle)
        guard needsRefresh else { return }

        PlayerCore.backgroundQueue.async { [self] in
          // Get watch-later form file system; get other meta from ffmpeg:
          let cachedMeta = MediaMetaCache.shared.updateCachedMeta(playlistItem, mpvTitle: mpvTitle)
          // Now update the total length if needed (but only if it's already done calculating):
          if playlistTotalLengthIsReady {
            let prevDuration = existingCachedMeta.duration ?? 0
            let updatedDuration = cachedMeta.duration ?? 0
            if updatedDuration != prevDuration {
              // if FFmpeg got the duration successfully
              refreshTotalLength()
            }
          }
          pwc.animationPipeline.submitInstantTask { [self] in
            /// This should trigger a call to `updateCellForPlaylistTrackNameColumn` to rebuild the row
            reloadPlaylistRow(rowIndex)
          }
        }
      }
    }

    return existingCachedMeta
  }

  func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
    /// The background color for a `NSTableRowView` will default to the parent's background color, which results in an
    /// unwanted additive effect for translucent backgrounds. Just make each row transparent.
    rowView.backgroundColor = .clear
  }

  private func updateCachesForAllItems() {
    guard enablePrefetching else { return }

    let sw = Utility.Stopwatch()

    player.mpv.queue.async { [self] in
      guard player.isActive else { return }
      let currentTicket = $playlistReloadTicket.withLock { latestTicket in
        latestTicket += 1
        return latestTicket
      }
      let playlistItems = displayedPlaylist
      var titles: [String?] = []
      player.log.verbose("Playlist: updating caches for \(playlistItems.count) rows…")

      for rowIndex in 0..<playlistItems.count {
        // Get updated title from mpv
        let mpvTitle = player.mpv.getString(MPVProperty.playlistNTitle(rowIndex))
        titles.append(mpvTitle) // may be nil
      }

      PlayerCore.backgroundQueue.async { [self] in
        for (rowIndex, item) in playlistItems.enumerated() {
          if (rowIndex %% 5) == 0 {
            let isTicketValid = $playlistReloadTicket.withLock { $0 == currentTicket }
            guard isTicketValid else {
              player.log.verbose("Playlist: ticket no longer valid; cancelling cache update")
              return
            }
          }
          let updatedTitle = titles[rowIndex]
          let existingCachedMeta = MediaMetaCache.shared.getOrAddCachedMeta(for: item)
          let needsRefresh = (item.url.isFileURL && !existingCachedMeta.triedFFmpeg) || (updatedTitle != nil && updatedTitle != existingCachedMeta.title)
          guard needsRefresh else { continue }
          // Get watch-later form file system; get other meta from ffmpeg:
          MediaMetaCache.shared.updateCachedMeta(item, mpvTitle: updatedTitle)
          // Refresh each row as it gets updated. May take a while to refresh all
          pwc.animationPipeline.submit(.init{ [self] in
            /// This should trigger a call to `updateCellForPlaylistTrackNameColumn` to rebuild the row
            reloadPlaylistRow(rowIndex)
          })
        }

        // Finally, append a task to recalculate the total length. Do not show it until it is done!
        player.log.verbose("Playlist: finished cache updates for \(playlistItems.count) rows in \(sw.secElapsedString)")
        refreshTotalLength()
      }
    }
  }

  // MARK: - Context menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    buildContextMenu(menu)
  }

  private func getTargetRowsForContextMenu() -> IndexSet {
    let selectedRows = playlistTableView.selectedRowIndexes
    let clickedRow = playlistTableView.clickedRow
    guard clickedRow != -1 else {
      return IndexSet()
    }

    if selectedRows.contains(clickedRow) {
      return selectedRows
    } else {
      return IndexSet(integer: clickedRow)
    }
  }

  @IBAction func contextMenuPlayNext(_ sender: ContextMenuItem) {
    player.playNextInPlaylist(sender.targetRows)
    playlistTableView.deselectAll(nil)
  }

  @IBAction func contextMenuPlayInNewWindow(_ sender: ContextMenuItem) {
    let playlistItems = displayedPlaylist

    let urlList: [URL] = sender.targetRows.compactMap{ playlistRowIndex in
      guard playlistRowIndex < playlistItems.count else { return nil }
      return playlistItems[playlistRowIndex].url
    }
    PlayerManager.shared.getIdleOrCreateNew().openURLs(urlList)
  }

  @IBAction func contextMenuRemove(_ sender: ContextMenuItem) {
    player.log.verbose("User chose to remove rows \(sender.targetRows.map{$0}) from playlist")
    player.removePlaylistRows(sender.targetRows, .registerUndoRedo)
  }

  @IBAction func contextMenuDeleteFile(_ sender: ContextMenuItem) {
    player.log.debug("User chose to delete files from playlist at indexes: \(sender.targetRows.map{$0})")

    let playlistItems = displayedPlaylist
    var successes = IndexSet()
    for index in sender.targetRows {
      guard index < playlistItems.count else { continue }
      guard !playlistItems[index].isNetworkResource else { continue }
      let url = playlistItems[index].url
      do {
        player.log.debug("Trashing row \(index): \(url.standardizedFileURL)")
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        successes.insert(index)
      } catch let error {
        Utility.showAlert("playlist.error_deleting", arguments: [error.localizedDescription])
      }
    }
    if !successes.isEmpty {
      player.removePlaylistRows(successes, .clearUndoStack)
    }
  }

  @IBAction func contextMenuDeleteFileAfterPlayback(_ sender: NSMenuItem) {
    // WIP
    // TODO: WIP, really?
  }

  private func getFiles(fromPlaylistRows rows: IndexSet) -> [URL] {
    var urls: [URL] = []
    let playlistItems = displayedPlaylist
    for index in rows {
      guard index < playlistItems.count else { continue }
      if !playlistItems[index].isNetworkResource {
        urls.append(playlistItems[index].url)
      }
    }

    return urls
  }

  @IBAction func contextMenuShowInFinder(_ sender: ContextMenuItem) {
    let urls: [URL] = getFiles(fromPlaylistRows: sender.targetRows)
    guard !urls.isEmpty else {
      player.log.error("Show in Finder failed: found no files in \(sender.targetRows.count) provided rows!")
      return
    }
    playlistTableView.deselectAll(nil)
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  @IBAction func contextMenuAddSubtitle(_ sender: ContextMenuItem) {
    guard let index = sender.targetRows.first else { return }
    let playlistItems = displayedPlaylist
    guard index < playlistItems.count else { return }
    let filename = playlistItems[index].path
    let fileURL = playlistItems[index].url.deletingLastPathComponent()
    Utility.quickMultipleOpenPanel(title: NSLocalizedString("alert.choose_media_file.title", comment: "Choose Media File"), dir: fileURL, canChooseDir: true) { subURLs in
      for subURL in subURLs {
        guard Utility.supportedFileExt[.sub]!.contains(subURL.pathExtension.lowercased()) else { return }
        self.player.info.$matchedSubs.withLock { $0[filename, default: []].append(subURL) }
      }
      self.reloadPlaylistRows(sender.targetRows)
    }
  }

  @IBAction func contextMenuWrongSubtitle(_ sender: ContextMenuItem) {
    let playlistItems = displayedPlaylist
    for index in sender.targetRows {
      guard index < playlistItems.count else { continue }
      let filename = playlistItems[index].path
      player.info.$matchedSubs.withLock { $0[filename]?.removeAll() }
      self.reloadPlaylistRows(sender.targetRows)
    }
  }

  @IBAction func contextOpenInBrowser(_ sender: ContextMenuItem) {
    let playlistItems = displayedPlaylist
    for i in sender.targetRows {
      guard i < playlistItems.count else { continue }

      let info = playlistItems[i]
      if info.isNetworkResource {
        NSWorkspace.shared.open(info.url)
      }
    }
  }

  @IBAction func contextCopyURL(_ sender: ContextMenuItem) {
    let playlistItems = displayedPlaylist
    let urls = sender.targetRows.compactMap { i -> String? in
      guard i < playlistItems.count else { return nil }
      let item = playlistItems[i]
      return item.networkPath
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([urls.joined(separator: "\n") as NSString])
  }

  @MainActor
  private func buildContextMenu(_ menu: NSMenu) {
    let playlistItems = displayedPlaylist
    let rows = getTargetRowsForContextMenu()
    player.log.verbose("Building context menu for rows: \(rows.map{ $0 })")

    menu.removeAllItems()

    let isSingleItem = rows.count == 1

    if !rows.isEmpty {
      let firstItem = playlistItems[rows.first!]
      let matchedSubCount = player.info.getMatchedSubs(firstItem.path)?.count ?? 0
      let title: String = isSingleItem ? firstItem.displayName :
        String(format: NSLocalizedString("pl_menu.title_multi", comment: "%d Items"), rows.count)

      menu.addItem(withTitle: title)
      menu.addItem(NSMenuItem.separator())
      menu.addItem(forRows: rows, withTitle: NSLocalizedString("pl_menu.play_next", comment: "Play Next"), action: #selector(self.contextMenuPlayNext(_:)))
      menu.addItem(forRows: rows, withTitle: NSLocalizedString("pl_menu.play_in_new_window", comment: "Play in New Window"), action: #selector(self.contextMenuPlayInNewWindow(_:)))
      menu.addItem(forRows: rows, withTitle: NSLocalizedString(isSingleItem ? "pl_menu.remove" : "pl_menu.remove_multi", comment: "Remove"), action: #selector(self.contextMenuRemove(_:)))

      if !player.isInMiniPlayer {
        menu.addItem(NSMenuItem.separator())
        if isSingleItem {
          menu.addItem(forRows: rows, withTitle: String(format: NSLocalizedString("pl_menu.matched_sub", comment: "Matched %d Subtitle(s)"), matchedSubCount))
          menu.addItem(forRows: rows, withTitle: NSLocalizedString("pl_menu.add_sub", comment: "Add Subtitle…"), action: #selector(self.contextMenuAddSubtitle(_:)))
        }
        if matchedSubCount != 0 {
          menu.addItem(forRows: rows, withTitle: NSLocalizedString("pl_menu.wrong_sub", comment: "Wrong Subtitle"), action: #selector(self.contextMenuWrongSubtitle(_:)))
        }
      }

      menu.addItem(NSMenuItem.separator())
      // network resources related operations
      let networkCount = rows.filter {
        playlistItems[$0].isNetworkResource
      }.count
      if networkCount != 0 {
        menu.addItem(forRows: rows, withTitle: NSLocalizedString("pl_menu.browser", comment: "Open in Browser"), action: #selector(self.contextOpenInBrowser(_:)))
        menu.addItem(forRows: rows, withTitle: NSLocalizedString(networkCount == 1 ? "pl_menu.copy_url" : "pl_menu.copy_url_multi", comment: "Copy URL(s)"), action: #selector(self.contextCopyURL(_:)))
        menu.addItem(NSMenuItem.separator())
      }
      // file related operations
      let localCount = rows.count - networkCount
      if localCount != 0 {
        menu.addItem(forRows: rows, withTitle: NSLocalizedString(localCount == 1 ? "pl_menu.delete" : "pl_menu.delete_multi", comment: "Delete"), action: #selector(self.contextMenuDeleteFile(_:)))
        // menu.addItem(forRows: rows, withTitle: NSLocalizedString(isSingleItem ? "pl_menu.delete_after_play" : "pl_menu.delete_after_play_multi", comment: "Delete After Playback"), action: #selector(self.contextMenuDeleteFileAfterPlayback(_:)))

        menu.addItem(forRows: rows, withTitle: NSLocalizedString("pl_menu.show_in_finder", comment: "Show in Finder"), action: #selector(self.contextMenuShowInFinder(_:)))
        menu.addItem(NSMenuItem.separator())
      }
    }

    // menu items from plugins
    var hasPluginMenuItems = false
    let filenames = Array(rows)
    let plugins = player.plugins
    let pluginMenuItems = plugins.map {
      plugin -> (JavascriptPluginInstance, [JavascriptPluginMenuItem]) in
      if let builder = (plugin.apis["playlist"] as! JavascriptAPIPlaylist).menuItemBuilder?.value,
        let value = builder.call(withArguments: [filenames]),
        value.isObject,
        let items = value.toObject() as? [JavascriptPluginMenuItem] {
        hasPluginMenuItems = true
        return (plugin, items)
      }
      return (plugin, [])
    }
    if hasPluginMenuItems {
      menu.addItem(withTitle: NSLocalizedString("preference.plugins", comment: "Plugins"))
      for (plugin, items) in pluginMenuItems {
        for item in items {
          add(menuItemDef: item, to: menu, for: plugin)
        }
      }
      menu.addItem(NSMenuItem.separator())
    }

    menu.addItem(withTitle: NSLocalizedString("pl_menu.add_file", comment: "Add File"), action: #selector(self.addFileAction(_:)))
    menu.addItem(withTitle: NSLocalizedString("pl_menu.add_url", comment: "Add URL"), action: #selector(self.addURLAction(_:)))
    menu.addItem(withTitle: NSLocalizedString("pl_menu.clear_playlist", comment: "Clear Playlist"), action: #selector(self.clearPlaylistBtnAction(_:)))
  }

  @discardableResult
  private func add(menuItemDef item: JavascriptPluginMenuItem,
                   to menu: NSMenu,
                   for plugin: JavascriptPluginInstance) -> NSMenuItem {
    if (item.isSeparator) {
      let item = NSMenuItem.separator()
      menu.addItem(item)
      return item
    }

    let menuItem: NSMenuItem
    if item.action == nil {
      menuItem = menu.addItem(withTitle: item.title, action: nil, target: plugin, obj: item)
    } else {
      menuItem = menu.addItem(withTitle: item.title,
                              action: #selector(plugin.playlistMenuItemAction(_:)),
                              target: plugin,
                              obj: item)
    }

    menuItem.isEnabled = item.enabled
    menuItem.state = item.selected ? .on : .off
    if !item.items.isEmpty {
      menuItem.submenu = NSMenu()
      for submenuItem in item.items {
        add(menuItemDef: submenuItem, to: menuItem.submenu!, for: plugin)
      }
    }
    return menuItem
  }
}

// MARK: - EditableTableViewDelegate

/// `EditableTableViewDelegate`
extension PlaylistViewController: EditableTableViewDelegate {
  var parentTableView: EditableTableView! { playlistTableView }

  // Allows for sidebar resize to happen from inside the table, by giving it higher priority than row drag & drop.
  // If this returns false, table will proceed to process normally
  func handleMouseDown(with event: NSEvent) -> Bool {
    return pwc.startResizingSidebar(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    if let pwc = pwc, pwc.currentDragObject == view,
       let sidebar = pwc.getConfiguredSidebar(forTabGroup: .playlist) {

      // Do not animate. It will cause lag while dragging
      IINAAnimation.disableAnimation {
        pwc.continueResizingSidebar(sidebar.locationID, with: event)
      }
      return
    }

    super.mouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if let pwc = pwc, pwc.currentDragObject == view,
       let sidebar = pwc.getConfiguredSidebar(forTabGroup: .playlist) {
      pwc.finishResizingSidebar(sidebar.locationID, with: event)
      pwc.currentDragObject = nil
      return
    }
    super.mouseUp(with: event)
  }

  // MARK: - Edit Menu Support

  func isCutEnabled() -> Bool {
    return hasSelectionInPlaylistTable()
  }

  func isCopyEnabled() -> Bool {
    return hasSelectionInPlaylistTable()
  }

  func isPasteEnabled() -> Bool {
    (currentTab == .playlist) && (NSPasteboard.general.types?.contains(.nsFilenames) ?? false)
  }

  func isDeleteEnabled() -> Bool {
    return hasSelectionInPlaylistTable()
  }

  func isSelectAllEnabled() -> Bool {
    (currentTab == .playlist) && (playlistTableView.numberOfRows > 0)
  }

  func doEditMenuCopy() {
    copyPlaylistRowsToPasteboard(playlistTableView.selectedRowIndexes, to: .general)
  }

  func doEditMenuCut() {
    doEditMenuCopy()
    doEditMenuDelete()
  }

  func doEditMenuPaste() {
    pasteFromPasteboard(from: .general)
  }

  func doEditMenuDelete() {
    player.removePlaylistRows(playlistTableView.selectedRowIndexes, .registerUndoRedo)
  }

  private func hasSelectionInPlaylistTable() -> Bool {
    (currentTab == .playlist) && !playlistTableView.selectedRowIndexes.isEmpty
  }
}

class PlaylistTrackCellView: NSTableCellView {
  @IBOutlet weak var subBtn: NSButton!
  @IBOutlet weak var subBtnWidthConstraint: NSLayoutConstraint!
  @IBOutlet weak var subBtnTrailingConstraint: NSLayoutConstraint!
  @IBOutlet weak var prefixBtn: PlaylistPrefixButton!
  @IBOutlet weak var infoLabel: EditableTextField!  /// use `EditableTextField` class for proper highlight color
  @IBOutlet weak var infoLabelTrailingConstraint: NSLayoutConstraint!
  @IBOutlet weak var durationLabel: EditableTextField!
  @IBOutlet weak var playbackProgressView: PlaylistPlaybackProgressView!

  func setPrefix(_ prefix: String?, textColor: NSColor? = nil) {
    if #available(macOS 10.14, *) {
      prefixBtn.contentTintColor = textColor
    } else {
      // Sorry earlier versions, no color for you
    }
    
    if let prefix {
      prefixBtn.hasPrefix = true
      prefixBtn.text = prefix
      prefixBtn.isHidden = false
    } else {
      prefixBtn.hasPrefix = false
      prefixBtn.isHidden = true
    }
  }

  func setDisplaySubButton(_ show: Bool) {
    if show {
      subBtn.isHidden = false
      subBtnWidthConstraint.constant = 12
      subBtnTrailingConstraint.constant = 4
    } else {
      subBtn.isHidden = true
      subBtnWidthConstraint.constant = 0
      subBtnTrailingConstraint.constant = 0
    }
  }

  func setAdditionalInfo(_ string: String?, textColor: NSColor? = nil) {
    if let string = string {
      infoLabel.isHidden = false
      infoLabelTrailingConstraint.constant = 4
      infoLabel.setFormattedText(stringValue: string, textColor: textColor)
      infoLabel.stringValue = string
      infoLabel.toolTip = string
    } else {
      infoLabel.isHidden = true
      infoLabelTrailingConstraint.constant = 0
      infoLabel.stringValue = ""
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    playbackProgressView.percentage = 0
    playbackProgressView.isHidden = true
    playbackProgressView.needsDisplay = true
    setPrefix(nil)
    setAdditionalInfo(nil)
  }
}


class PlaylistPrefixButton: NSButton {

  var text = "" {
    didSet {
      refresh()
    }
  }

  var hasPrefix = true {
    didSet {
      refresh()
    }
  }

  var isFolded = true {
    didSet {
      refresh()
    }
  }

  private func refresh() {
    self.title = hasPrefix ? (isFolded ? "…" : text) : ""
  }

}


class SubPopoverViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {

  @IBOutlet weak var tableView: NSTableView!
  @IBOutlet weak var playlistTableView: NSTableView!

  unowned var player: PlayerCore!
  var pwc: PlayerWindowController! { player.pwc }

  var filePath: String = ""

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    return false
  }

  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    guard let matchedSubs = player.info.getMatchedSubs(filePath) else { return nil }
    return matchedSubs[row].lastPathComponent
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    return player.info.getMatchedSubs(filePath)?.count ?? 0
  }

  @IBAction func wrongSubBtnAction(_ sender: AnyObject) {
    player.info.$matchedSubs.withLock { $0[filePath]?.removeAll() }
    tableView.reloadData()
    let playlist = pwc.playlistView.displayedPlaylist
    if let row = playlist.firstIndex(where: { $0.path == filePath }) {
      playlistTableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0...1))
    }
  }
}

class ChapterTableCellView: NSTableCellView {
  @IBOutlet weak var durationTextField: EditableTextField!
}

class PlaylistView: NSView, DraggableObject {
  override func mouseDragged(with event: NSEvent) {
    // Send to view controller (above)
    nextResponder?.mouseDragged(with: event)
  }

  func cancelDrag() {
    guard let pwc, let sidebar = pwc.getConfiguredSidebar(forTabGroup: .playlist) else { return }
    pwc.log.verbose("Cancelled drag of playlist sidebar")
    pwc.finishResizingSidebar(sidebar.locationID)
  }

}
