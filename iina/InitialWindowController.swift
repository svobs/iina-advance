//
//  InitialWindowController.swift
//  iina
//
//  Created by lhc on 27/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

fileprivate let cornerRadius: CGFloat = {
  if #available(macOS 26.0, *) {
    return 12
  } else {
    return 4
  }
}()

fileprivate extension NSUserInterfaceItemIdentifier {
  static let openFile = NSUserInterfaceItemIdentifier("openFile")
  static let openURL = NSUserInterfaceItemIdentifier("openURL")
}

fileprivate class GrayHighlightRowView: NSTableRowView {

  override func drawSelection(in dirtyRect: NSRect) {
    if self.selectionHighlightStyle != .none {
      NSColor.initialWindowLastFileBackground.setFill()
      let selectionPath = NSBezierPath.init(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
      selectionPath.fill()
    }
  }

  fileprivate func setPressedHighlight() {
    layer?.cornerRadius = cornerRadius  // not sure why but this needs to be set again to redraw the background properly
    self.layer?.backgroundColor = NSColor.initialWindowActionButtonBackgroundPressed.cgColor
    needsDisplay = true
  }

  fileprivate func setHoverHighlight() {
    layer?.cornerRadius = cornerRadius  // not sure why but this needs to be set again to redraw the background properly
    self.layer?.backgroundColor = NSColor.initialWindowActionButtonBackgroundHover.cgColor
    needsDisplay = true
  }

  fileprivate func unsetHoverHighlight() {
    layer?.cornerRadius = cornerRadius  // not sure why but this needs to be set again to draw the background properly
    self.layer?.backgroundColor = NSColor.initialWindowActionButtonBackground.cgColor
    needsDisplay = true
  }
}

// MARK: Cursor

// TODO: make global
@MainActor
fileprivate var customCursor: NSCursor? = nil

@MainActor
fileprivate func setCustomCursor(to newCursor: NSCursor?) {
  assert(DispatchQueue.isExecutingIn(.main))

  guard NSCursor.current != newCursor else { return }
  if let newCursor {
    if customCursor == nil {
      newCursor.push()
    } else {
      newCursor.set()
    }
  } else {
    NSCursor.pop()
  }
  customCursor = newCursor
}

extension InitialWindowController: EditableTableViewDelegate {
  var parentTableView: EditableTableView! { recentFilesTableView }

  func handleMouseDown(with event: NSEvent) -> Bool {
    onMouseDownInTable()
    return true
  }

  func handleMouseUp(with event: NSEvent) -> Bool {
    onMouseUpInTable()
    return true
  }
}

class InitialWindowController: WindowController, NSWindowDelegate {

  override var windowNibName: NSNib.Name {
    return NSNib.Name("InitialWindowController")
  }

  var isFirstLoad = true

  let reloadDebouncer = Debouncer()

  @IBOutlet weak var recentFilesTableView: EditableTableView!
  @IBOutlet weak var appIcon: NSImageView!
  @IBOutlet weak var versionLabel: NSTextField!
  @IBOutlet weak var visualEffectView: NSVisualEffectView!
  @IBOutlet weak var leftOverlayView: NSView!
  @IBOutlet weak var mainView: NSView!
  @IBOutlet weak var betaIndicatorView: BetaIndicatorView!
  @IBOutlet weak var betaTextField: NSTextField!
  @IBOutlet weak var lastFileContainerView: InitialWindowViewActionButton!
  @IBOutlet weak var lastFileIcon: NSImageView!
  @IBOutlet weak var lastFileNameLabel: NSTextField!
  @IBOutlet weak var lastPositionLabel: NSTextField!
  @IBOutlet weak var recentFilesTableTopConstraint: NSLayoutConstraint!

  private let observedPrefKeys: [Preference.Key] = [.themeMaterial]
  private var currentlyHoveredRow: GrayHighlightRowView?

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath = keyPath else { return }

    switch keyPath {

    case Preference.Key.themeMaterial.rawValue:
      setMaterial()

    default:
      return
    }
  }

  fileprivate var recentDocuments: [URL] = []
  fileprivate var lastPlaybackURL: URL?

  init() {
    super.init(window: nil)
    self.windowFrameAutosaveName = WindowAutosaveName.welcome.string
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func openWindow(_ sender: Any?) {
    // Load window if not already loaded:
    guard let _ = window else { return }

    /// If welcome window is shown at startup, recentDocuments may not be finished loading.
    /// We want to wait until recentDocuments are done loading before displaying the window.
    assert(isWindowLoaded, "Expected WelcomeWindow to be loaded!")

    Logger.log.verbose("Open WelcomeWindow: start, firstLoad=\(isFirstLoad.yn)")

    if isFirstLoad {
      let sw = Utility.Stopwatch()
      // Start history if not already started
      HistoryController.shared.start()
      /// Enquque in `HistoryController.shared.queue` to establish a happens-after relationship with recentDocuments load:
      HistoryController.shared.async {
        DispatchQueue.main.async {
          guard !AppDelegate.shared.isTerminating else { return }
          self.refreshUI()  // async!
          super.openWindow(sender)
          // Do this after super.openWindow, to ensure zoom animation is activated
          self.isFirstLoad = false
          Logger.log.verbose("Open WelcomeWindow (firstLoad): done in \(sw.secElapsed)")
        }
      }
    } else {
      super.openWindow(sender)
      Logger.log.verbose("Open WelcomeWindow: done")
    }
  }

  override func windowDidLoad() {
    Logger.log.verbose("WelcomeWindow windowDidLoad starting")
    super.windowDidLoad()

    // "utility" style doesn't animate well with VisualEffectView. No good options
    window?.isMovableByWindowBackground = true

    appIcon.unregisterDraggedTypes()
    window?.contentView?.registerForDraggedTypes([.nsFilenames, .nsURL, .string])

    let infoDict = InfoDictionary.shared
    let (version, build) = infoDict.version

    betaTextField.stringValue = infoDict.buildType.description

    switch infoDict.buildType {
    case .release:
      versionLabel.stringValue = version
    case .beta:
      versionLabel.stringValue = "\(version) (build \(build))"
      betaIndicatorView.isHidden = false
    case .nightly:
      versionLabel.stringValue = "\(version)+g\(InfoDictionary.shared.shortCommitSHA ?? "")"
      betaIndicatorView.isHidden = false
    case .debug:
      versionLabel.stringValue = "\(version)+g\(InfoDictionary.shared.shortCommitSHA ?? "")"
      betaIndicatorView.isHidden = false
    }

    recentFilesTableView.delegate = self
    recentFilesTableView.editableDelegate = self
    recentFilesTableView.dataSource = self
    recentFilesTableView.action = #selector(onMouseUpInTable)
    updateTrackingAreas()
    setMaterial()

    observedPrefKeys.forEach { key in
      UserDefaults.standard.addObserver(self, forKeyPath: key.rawValue, options: .new, context: nil)
    }

    NotificationCenter.default.addObserver(forName: .recentDocumentsDidChange, object: nil, queue: .main) { [self] _ in
      Logger.log("WelcomeWindow received recentDocumentsDidChange; will reload data")
      refreshUI()
    }

    Logger.log.verbose("WelcomeWindow windowDidLoad done")
  }

  func windowDidBecomeKey(_ notification: Notification) {
    updateTrackingAreas()
  }

  func windowWillClose(_ notification: Notification) {
    removeTrackingAreasIfPresent()
  }

  private func updateTrackingAreas() {
    removeTrackingAreasIfPresent()
    addTrackingAreasIfMissing()
  }

  private func addTrackingAreasIfMissing() {
    if recentFilesTableView.trackingAreas.isEmpty {
      recentFilesTableView.addTrackingArea(NSTrackingArea(rect: recentFilesTableView.bounds,
                                                          options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self,
                                                          userInfo: ["key" : "recentFilesTable"]))
    }
  }

  private func removeTrackingAreasIfPresent() {
    let trackingAreas = recentFilesTableView.trackingAreas
    for trackingArea in trackingAreas {
      recentFilesTableView.removeTrackingArea(trackingArea)
    }
  }

  private func setMaterial() {
    guard let window = window else { return }
    let theme: Preference.Theme = Preference.enum(for: .themeMaterial)
    window.appearance = NSAppearance(iinaTheme: theme)
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = window.effectiveAppearance.isDark ?
    [NSColor.black.withAlphaComponent(0.4).cgColor, NSColor.black.withAlphaComponent(0).cgColor] :
    [NSColor.black.withAlphaComponent(0.1).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
    leftOverlayView.layer = gradientLayer
  }

  fileprivate func openInNewPlayer(_ url: URL) {
    PlayerManager.shared.getIdleOrCreateNew().openURL(url)
  }

  fileprivate func onMouseDownInTable() {
    let clickedPoint = recentFilesTableView.convert(mouseLocationInWindow, from: nil)
    let clickedRow = recentFilesTableView.row(at: clickedPoint)
    if clickedRow >= 0 {
      guard let rowView = recentFilesTableView.rowView(atRow: clickedRow, makeIfNecessary: false) as? GrayHighlightRowView else {
        return
      }
      rowView.setPressedHighlight()
      if let prevHoveredRow = currentlyHoveredRow {
        if prevHoveredRow != rowView {
          currentlyHoveredRow?.unsetHoverHighlight()
        }
      }
      currentlyHoveredRow = rowView
    }
  }

  @objc func onMouseUpInTable() {
    // Do not use recentFilesTableView.clickedRow. It always returns -1 when window is not main
    let clickedPoint = recentFilesTableView.convert(mouseLocationInWindow, from: nil)
    let clickedRow = recentFilesTableView.row(at: clickedPoint)
    if clickedRow >= 0 {
      openRecentItemFromTable(clickedRow)
    } else {
      mouseDidExitRowHover()
    }
  }

  private func openRecentItemFromTable(_ rowIndex: Int) {
    if let url = recentDocuments[at: rowIndex] {
      Logger.log.verbose("Opening recentDocuments[\(rowIndex)] in new player window")
      openInNewPlayer(url)
    }
  }

  private func refreshLastFileDisplay() {
    if let lastFile = lastPlaybackURL {
      // if last file exists
      lastFileContainerView.isHidden = false
      lastFileContainerView.normalBackground = NSColor.initialWindowLastFileBackground
      lastFileContainerView.hoverBackground = NSColor.initialWindowLastFileBackgroundHover
      lastFileContainerView.pressedBackground = NSColor.initialWindowLastFileBackgroundPressed
      lastFileIcon.image = #imageLiteral(resourceName: "history")
      lastFileNameLabel.stringValue = lastFile.lastPathComponent
      let lastPosition = Preference.double(for: .iinaLastPlayedFilePosition)
      lastPositionLabel.stringValue = VideoTime(lastPosition).stringRepresentation
      recentFilesTableTopConstraint.constant = 42
    } else {
      lastFileContainerView.isHidden = true
      recentFilesTableTopConstraint.constant = 24
    }
  }

  private func getLastPlaybackIfValid() -> URL? {
    guard Preference.bool(for: .recordRecentFiles) && Preference.bool(for: .resumeLastPosition),
          let lastFile = Preference.url(for: .iinaLastPlayedFilePath) else {
      return nil
    }

    guard FileManager.default.fileExists(atPath: lastFile.path) else {
      Logger.log.debug("File does not exist at lastPlaybackURL: \(lastFile.path.pii.quoted)")
      return nil
    }
    return lastFile
  }

  fileprivate func refreshUI() {
    reloadDebouncer.run { [self] in
      assert(DispatchQueue.isExecutingIn(.main))
      guard isWindowLoaded else { return }

      // Reload data:

      let sw = Utility.Stopwatch()
      let loadSavedRecentDocs = Preference.bool(for: .enableRecentDocumentsWorkaround)
      let recentsUnfiltered = loadSavedRecentDocs ? HistoryController.shared.cachedRecentDocumentURLs : NSDocumentController.shared.recentDocumentURLs
      /// Make sure to resolve symlinks in `lastPlaybackURL`
      lastPlaybackURL = getLastPlaybackIfValid()?.resolvingSymlinksInPath() ?? nil
      if let lastURL = lastPlaybackURL {

        // Need to call resolvingSymlinksInPath() on both sides, because it changes "/private/var" to "/var" as a special case,
        // even though "/var" points to "/private/var" (i.e. it changes it the opposite direction from what is expected).
        // This is probably a kludge on Apple's part to avoid breaking legacy FreeBSD code.
        recentDocuments = recentsUnfiltered.filter { $0.resolvingSymlinksInPath() != lastURL }
      } else {
        recentDocuments = recentsUnfiltered
      }

      Logger.log.verbose("[ReloadWelcomeWindow] Resolved \(self.recentDocuments.count) recentDocuments (w/workaround=\(loadSavedRecentDocs.yn)) in \(sw) ms")

      // Refresh UI:

      refreshLastFileDisplay()
      recentFilesTableView.reloadData()

      if lastFileContainerView.isHidden && recentFilesTableView.numberOfRows > 0 {
        recentFilesTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      }

      // Debug logging:
      if Logger.isEnabled(.verbose) {
        let last = lastPlaybackURL?.path.pii.quoted ?? "nil"
        Logger.log.verbose("[ReloadWelcomeWindow] Recents displayed=\(recentDocuments.count)/\(recentsUnfiltered.count) lastPlaybackURL=\(last)")

        for (index, url) in recentDocuments.enumerated() {
          Logger.log.verbose("Recents[\(index)]: \(url.path.pii.quoted)")
        }
      }
    }
  }

  // MARK: - Window delegate

  // Video is about to start playing in a new window, but welcome window needs to be closed first.
  // Need to add special logic around `close()` so that it doesn't think the last window is being closed, and decide to quit.
  func closePriorToOpeningPlayerWindow() {
    guard let window, window.isOpen else { return }
    Logger.log.verbose("Welcome window closing prior to opening player window")
    self.close()
  }
}

extension InitialWindowController: NSTableViewDelegate, NSTableViewDataSource {

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    // uses custom highlight for table row
    return GrayHighlightRowView()
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    updateLastFileButtonHighlight()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    return recentDocuments.count
  }

  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    let url = recentDocuments[row]
    return [
      "filename": url.lastPathComponent,
      "docIcon": NSWorkspace.shared.icon(forFile: url.path)
    ] as [String: Any]
  }

  // facilitates highlight on hover
  override func mouseMoved(with event: NSEvent) {
    guard !isLeftMouseButtonDown else { return }

    // Do not use `event.locationInWindow`: it can be very stale
    let mouseLocation = mouseLocationInWindow
    let point = recentFilesTableView.convert(mouseLocation, from: nil)
    let rowIndex = recentFilesTableView.row(at: point)

    if rowIndex >= 0 {
      setCustomCursor(to: .pointingHand)
      guard let rowView = recentFilesTableView.rowView(atRow: rowIndex, makeIfNecessary: false) as? GrayHighlightRowView else {
        return
      }

      if currentlyHoveredRow == rowView {
        return
      }

      rowView.setHoverHighlight()
      currentlyHoveredRow?.unsetHoverHighlight()
      currentlyHoveredRow = rowView
    } else {
      mouseDidExitRowHover()
    }
  }

  override func mouseExited(with event: NSEvent) {
    guard let area = event.trackingArea?.userInfo?["key"] as? String, area == "recentFilesTable" else { return }
    guard !isLeftMouseButtonDown else { return }

    mouseDidExitRowHover()
  }

  fileprivate func mouseDidExitRowHover() {
    currentlyHoveredRow?.unsetHoverHighlight()
    currentlyHoveredRow = nil
    setCustomCursor(to: nil)
  }

  override func keyDown(with event: NSEvent) {
    let keyChar = KeyCodeHelper.keyMap[event.keyCode]?.0
    switch keyChar {
      case "ENTER", "KP_ENTER":  // RETURN or (keypad ENTER)
        if recentFilesTableView.selectedRow >= 0 {
          // If user selected a row in the table using the keyboard, use that
          openRecentItemFromTable(recentFilesTableView.selectedRow)
        } else if let lastURL = lastPlaybackURL {
          // If no row selected in table, most recent file button is selected. Use that if it exists
          Logger.log.debug("Opening lastPlaybackURL in new player window")
          openInNewPlayer(lastURL)
        } else if recentFilesTableView.numberOfRows > 0 {
          // Most recent file no longer exists? Try to load next one
          openRecentItemFromTable(0)
        }
      case "DOWN":  // DOWN arrow
        if recentDocuments.count == 0 || (recentFilesTableView.selectedRow >= recentFilesTableView.numberOfRows - 1) {
          super.keyDown(with: event)  // invalid command: beep at user
        } else {
          // default: let recentFilesTableView handle it
          recentFilesTableView.keyDown(with: event)
        }
      case "UP":  // UP arrow
        if !lastFileContainerView.isHidden {   // recent file btn is displayed?
          if recentFilesTableView.selectedRow == -1 {  // ...and recent file btn already highlighted?
            super.keyDown(with: event)  // invalid command: beep at user
            return
          } else if recentFilesTableView.selectedRow == 0 {  // ... top row of table is highlighted?
            // yes: deselect all rows of table. This will fire selectionChanged which will highlight lastFileContainerView
            recentFilesTableView.selectRowIndexes(IndexSet(), byExtendingSelection: false)
            return
          }
        } else if recentFilesTableView.selectedRow == 0 || recentDocuments.isEmpty {
          super.keyDown(with: event)  // invalid command: beep at user
          return
        }
        // default: let recentFilesTableView handle it
        recentFilesTableView.keyDown(with: event)
      default:
        super.keyDown(with: event)
    }
  }

  func updateLastFileButtonHighlight() {
    if recentFilesTableView.selectedRow >= 0 {
      // remove "LastFile" button highlight
      lastFileContainerView.setBackgroundColor(.initialWindowActionButtonBackground)
    } else {
      // re-highlight "LastFile" button
      lastFileContainerView.setBackgroundColor(.initialWindowLastFileBackground)
    }
  }

}


class InitialWindowContentView: NSView {

  var player: PlayerCore {
    return PlayerManager.shared.getIdleOrCreateNew()
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    return player.acceptFromPasteboard(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return player.openFromPasteboard(sender)
  }

}


/// "Open…" and "Open URL…" buttons
class InitialWindowViewActionButton: NSView {

  var normalBackground = NSColor.initialWindowActionButtonBackground {
    didSet {
      setBackgroundColor(normalBackground)
    }
  }
  fileprivate var hoverBackground = NSColor.initialWindowActionButtonBackgroundHover
  fileprivate var pressedBackground = NSColor.initialWindowActionButtonBackgroundPressed

  fileprivate func setBackgroundColor(_ color: NSColor) {
    layer?.cornerRadius = cornerRadius  // not sure why but this needs to be set again to draw the background properly
    self.layer?.backgroundColor = color.cgColor
  }

  override var mouseDownCanMoveWindow: Bool {
    false
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func awakeFromNib() {
    layer?.cornerRadius = cornerRadius
    self.layer?.backgroundColor = normalBackground.cgColor
    self.addTrackingArea(NSTrackingArea(rect: self.bounds, options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate], owner: self, userInfo: ["key": self.idString]))  // make sure identifier is set in the XIB for each button!
  }

  override func cursorUpdate(with event: NSEvent) {
    setCustomCursor(to: .pointingHand)
  }

  override func mouseEntered(with event: NSEvent) {
    guard let area = event.trackingArea?.userInfo?["key"] as? String, area == idString else { return }
    if let wc = window?.windowController as? WindowController, wc.isLeftMouseButtonDown {
      setBackgroundColor(pressedBackground)
      return
    }
    setCustomCursor(to: .pointingHand)
    if let windowController = window?.windowController as? InitialWindowController {
      if windowController.recentFilesTableView.selectedRow >= 0 {
        setBackgroundColor(.initialWindowActionButtonBackgroundHover)
      } else {
        setBackgroundColor(hoverBackground)
      }
    }
  }

  override func mouseExited(with event: NSEvent) {
    guard let area = event.trackingArea?.userInfo?["key"] as? String, area == idString else { return }
    mouseDidExit()
  }

  fileprivate func mouseDidExit() {
    if let wc = window?.windowController as? WindowController, wc.isLeftMouseButtonDown {
      setBackgroundColor(hoverBackground)
      return
    }
    setCustomCursor(to: nil)
    setBackgroundColor(normalBackground)
    if let windowController = window?.windowController as? InitialWindowController {
      windowController.updateLastFileButtonHighlight()
    }
  }

  override func mouseDown(with event: NSEvent) {
    setBackgroundColor(pressedBackground)
  }

  override func mouseUp(with event: NSEvent) {
    guard let wc = window?.windowController as? WindowController, isInsideViewFrame(pointInWindow: wc.mouseLocationInWindow) else {
      // Click did not end up over button: cancel action
      mouseDidExit()
      return
    }

    setBackgroundColor(hoverBackground)

    if self.identifier == .openFile {
      Logger.log("User clicked the Open File button", level: .verbose)
      AppDelegate.shared.openFile(self)
    } else if self.identifier == .openURL {
      Logger.log("User clicked the Open URL button", level: .verbose)
      AppDelegate.shared.openURL(self)
    } else {
      // Make sure to load the same file which is displayed: get from window controller.
      // Do not load from prefs because that may have changed since the window was opened (by another IINA instance, most likely)
      if let windowController = window?.windowController as? InitialWindowController,
         let lastURL = windowController.lastPlaybackURL {
        Logger.log("Opening lastPlaybackURL by default for mouse click", level: .verbose)
        PlayerManager.shared.getIdleOrCreateNew().openURL(lastURL)
      }
    }
  }

}


class BetaIndicatorView: NSView {

  @IBOutlet var betaPopover: NSPopover!
  @IBOutlet var announcementLabel: NSTextField!
  @IBOutlet var text1: NSTextField!
  @IBOutlet var text2: NSTextField!

  override func awakeFromNib() {
    let buildType = InfoDictionary.shared.buildType
    switch buildType {
    case .nightly:
      self.layer?.backgroundColor = NSColor.initialWindowNightlyLabel.cgColor
    case .beta:
      self.layer?.backgroundColor = NSColor.initialWindowBetaLabel.cgColor
    case .debug:
      self.layer?.backgroundColor = NSColor.initialWindowDebugLabel.cgColor
    default:
      break
    }

    announcementLabel.stringValue = String(format: NSLocalizedString("initial.announcement", comment: "Version announcement"), buildType.rawValue)
    text1.setHTMLValue(NSLocalizedString("initial." + buildType.rawValue.lowercased() + ".desc", comment: "Build type desc"))
    text2.setHTMLValue(NSLocalizedString("initial.bug_report", comment: "Bug report desc"))

    self.layer?.cornerRadius = 4
    self.addTrackingArea(NSTrackingArea(rect: self.bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self, userInfo: ["key": "beta"]))
  }

  override func mouseEntered(with event: NSEvent) {
    guard let area = event.trackingArea?.userInfo?["key"] as? String, area == "beta" else { return }
    guard InfoDictionary.shared.buildType != .debug else { return }
    setCustomCursor(to: .pointingHand)
  }

  override func mouseExited(with event: NSEvent) {
    guard let area = event.trackingArea?.userInfo?["key"] as? String, area == "beta" else { return }
    guard InfoDictionary.shared.buildType != .debug else { return }
    setCustomCursor(to: nil)
  }

  override func mouseUp(with event: NSEvent) {
    guard InfoDictionary.shared.buildType != .debug else { return }
    if betaPopover.isShown {
      betaPopover.close()
    } else {
      betaPopover.show(relativeTo: self.bounds, of: self, preferredEdge: .maxX)
    }
  }

}
