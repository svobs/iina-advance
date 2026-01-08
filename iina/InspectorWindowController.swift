//
//  InspectorWindowController.swift
//  iina
//
//  Created by lhc on 21/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

//fileprivate let watchTableBackgroundColor = NSColor(red: 2.0/3, green: 2.0/3, blue: 2.0/3, alpha: 0.1)
fileprivate let watchTableBackgroundColor = NSColor(red: 1, green: 1, blue: 1, alpha: 0.05)
fileprivate let watchTableColumnHeaderColor = NSColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
/*
class InspectorTabButtonGroup: NSSegmentedControl {

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configure()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  private func configure() {
    let customCell = InspectorTabSegmentedCell()
    cell = customCell

    let segmentLabels = ["General", "Tracks", "File", "Status"]
    let totalWidth: CGFloat = 400

    trackingMode = .selectOne
    segmentDistribution = .fillEqually
    customCell.controlSize = .large
    customCell.isBordered = false
    customCell.isBezeled = false
    customCell.font = .boldSystemFont(ofSize: 13)
    segmentStyle = .separated
    segmentCount = segmentLabels.count
    customCell.segmentCount = segmentLabels.count
    for (index, label) in segmentLabels.enumerated() {
      setLabel(label, forSegment: index)
      setTag(index, forSegment: index)
      setWidth((totalWidth * 0.25).rounded(), forSegment: index)
      setTag(index, forSegment: index)
      setEnabled(true, forSegment: index)
      setAlignment(.center, forSegment: index)
    }
    needsLayout = true
    needsDisplay = true
  }

  override func drawFocusRingMask() {
    return
  }


}

class InspectorTabSegmentedCell: NSSegmentedCell {

  override func drawSegment(_ segment: Int, inFrame frame: NSRect, with controlView: NSView) {
    var color: NSColor
    if selectedSegment == segment {
      color = NSColor.red
    } else {
      color = NSColor.clear
    }
    color.setFill()
    frame.fill()
    super.drawSegment(segment, inFrame: frame, with: controlView)
  }
}
*/

fileprivate let inspectorCornerRadius: CGFloat = 14

final class InspectorWindowController: WindowController, NSWindowDelegate, NSTableViewDelegate, NSTableViewDataSource {

  override var windowNibName: NSNib.Name {
    return NSNib.Name("InspectorWindowController")
  }

  var updateTimer: Timer?

  var watchProperties: [String] = []

  private var observers: [NSObjectProtocol] = []

  @IBOutlet weak var tabView: NSTabView!
  @IBOutlet weak var tabButtonGroup: NSSegmentedControl!
  @IBOutlet weak var tabButtonGroupBottomLine: NSBox!
  @IBOutlet weak var trackPopup: NSPopUpButton!

  @IBOutlet weak var pathField: NSTextField!
  @IBOutlet weak var fileSizeField: NSTextField!
  @IBOutlet weak var fileFormatField: NSTextField!
  @IBOutlet weak var chaptersField: NSTextField!
  @IBOutlet weak var editionsField: NSTextField!

  @IBOutlet weak var durationField: NSTextField!
  @IBOutlet weak var vformatField: NSTextField!
  @IBOutlet weak var vcodecField: NSTextField!
  @IBOutlet weak var vdecoderField: NSTextField!
  @IBOutlet weak var vcolorspaceField: NSTextField!
  @IBOutlet weak var vprimariesField: NSTextField!
  @IBOutlet weak var vPixelFormat: NSTextField!

  @IBOutlet weak var voField: NSTextField!
  @IBOutlet weak var vsizeField: NSTextField!
  @IBOutlet weak var vbitrateField: NSTextField!
  @IBOutlet weak var vfpsField: NSTextField!
  @IBOutlet weak var aformatField: NSTextField!
  @IBOutlet weak var acodecField: NSTextField!
  @IBOutlet weak var aoField: NSTextField!
  @IBOutlet weak var achannelsField: NSTextField!
  @IBOutlet weak var abitrateField: NSTextField!
  @IBOutlet weak var asamplerateField: NSTextField!

  @IBOutlet weak var trackIdField: NSTextField!
  @IBOutlet weak var trackDefaultField: NSTextField!
  @IBOutlet weak var trackForcedField: NSTextField!
  @IBOutlet weak var trackSelectedField: NSTextField!
  @IBOutlet weak var trackExternalField: NSTextField!
  @IBOutlet weak var trackSourceIdField: NSTextField!
  @IBOutlet weak var trackTitleField: NSTextField!
  @IBOutlet weak var trackLangField: NSTextField!
  @IBOutlet weak var trackFilePathField: NSTextField!
  @IBOutlet weak var trackCodecField: NSTextField!
  @IBOutlet weak var trackDecoderField: NSTextField!
  @IBOutlet weak var trackFPSField: NSTextField!
  @IBOutlet weak var trackChannelsField: NSTextField!
  @IBOutlet weak var trackSampleRateField: NSTextField!

  @IBOutlet weak var avsyncField: NSTextField!
  @IBOutlet weak var totalAvsyncField: NSTextField!
  @IBOutlet weak var droppedFramesField: NSTextField!
  @IBOutlet weak var mistimedFramesField: NSTextField!
  @IBOutlet weak var displayFPSField: NSTextField!
  @IBOutlet weak var voFPSField: NSTextField!
  @IBOutlet weak var edispFPSField: NSTextField!
  @IBOutlet weak var watchTableView: EditableTableView!
  @IBOutlet weak var deleteButton: NSButton!

  @IBOutlet weak var watchTableContainerView: NSView!
  private var tableDragDelegate: TableDragDelegate<String>? = nil

  init() {
    super.init(window: nil)
    self.windowFrameAutosaveName = WindowAutosaveName.inspector.string
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    ObjcUtils.silenced {
      NotificationCenter.default.removeObserver(self)
    }
  }

  // MARK: - Window Delegate

  override func windowDidLoad() {
    super.windowDidLoad()
    for textField in [pathField, fileSizeField, fileFormatField,
                      chaptersField, editionsField, durationField, vformatField,
                      vcodecField, vdecoderField, vcolorspaceField, vprimariesField,
                      vPixelFormat, voField, vsizeField, vbitrateField, vfpsField,
                      aformatField, acodecField, aoField, achannelsField, abitrateField,
                      asamplerateField, trackIdField, trackDefaultField, trackForcedField,
                      trackSelectedField, trackExternalField, trackSourceIdField,
                      trackTitleField, trackLangField, trackFilePathField, trackCodecField,
                      trackDecoderField, trackFPSField, trackChannelsField, trackSampleRateField,
                      avsyncField, totalAvsyncField, droppedFramesField, mistimedFramesField,
                      displayFPSField, voFPSField, edispFPSField
    ] {
      guard let textField else { continue }
      textField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    // Watch table

    watchProperties = Preference.array(for: .watchProperties) as! [String]
    watchTableView.idString = "WatchTable"
    watchTableView.delegate = self
    watchTableView.dataSource = self
    watchTableView.editableDelegate = self
    watchTableView.selectNextRowAfterDelete = false
    watchTableView.editableTextColumnIndexes = [0]

    tableDragDelegate = TableDragDelegate<String>("Watch", watchTableView,
                                                  acceptableDraggedTypes: [.string],
                                                  tableChangeNotificationName: .pendingUIChangeForInspectorTable,
                                                  getFromPasteboardFunc: readWatchListFromPasteboard,
                                                  getAllCurentFunc: { self.watchProperties },
                                                  moveFunc: moveWatchRows,
                                                  insertFunc: insertWatchRows,
                                                  removeFunc: removeWatchRows)

    let headerFont = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
    for column in watchTableView.tableColumns {
      let headerCell = WatchTableColumnHeaderCell()
      // Use title from the XIB
      let title = column.headerCell.title
      // Use small bold system font
      headerCell.attributedStringValue = NSMutableAttributedString(string: title, attributes: [.font: headerFont])
      column.headerCell = headerCell
    }

    watchTableContainerView.wantsLayer = true
    watchTableContainerView.layer?.backgroundColor = watchTableBackgroundColor.cgColor

    if #available(macOS 26.0, *) {
      watchTableContainerView.layer?.cornerRadius = inspectorCornerRadius

      trackPopup.borderShape = .capsule
      trackPopup.controlSize = .large
    }


    // Other UI init

    // Restore tab selection
    let selectTabIndex: Int = UIState.shared.getSavedValue(for: .uiInspectorWindowTabIndex)
    Logger.log.verbose("Restoring tab selection to index \(selectTabIndex)")
    tabButtonGroup.selectSegment(withTag: selectTabIndex)
    tabView.selectTabViewItem(at: selectTabIndex)
    // Do not select tab by default
    window?.initialFirstResponder = nil
  }

  override func showWindow(_ sender: Any?) {
    updateInfo()
    deleteButton.isEnabled = !watchTableView.selectedRowIndexes.isEmpty
    watchTableView.sizeLastColumnToFit()
    watchTableView.scrollRowToVisible(0)

    removeTimerAndListeners()
    updateTimer = Timer.scheduledTimer(timeInterval: TimeInterval(1), target: self, selector: #selector(dynamicUpdate), userInfo: nil, repeats: true)

    observers.append(NotificationCenter.default.addObserver(forName: .iinaFileLoaded, object: nil, queue: .main, using: self.needsUpdate))
    observers.append(NotificationCenter.default.addObserver(forName: .iinaPlayerWindowChanged, object: nil, queue: .main, using: self.needsUpdate))

    super.showWindow(sender)
  }

  func windowWillClose(_ notification: Notification) {
    Logger.log("Closing Inspector window", level: .verbose)
    // Remove timer & listeners to conserve resources
    removeTimerAndListeners()
  }

  // This is safe to run even if not needed
  private func removeTimerAndListeners() {
    updateTimer?.invalidate()
    updateTimer = nil
    for observer in observers {
      ObjcUtils.silenced {
        NotificationCenter.default.removeObserver(observer)
      }
    }
    observers = []
  }

  // MARK: - Data updates

  func updateInfo(includeStatic: Bool = true) {
    guard let player = PlayerManager.shared.lastActivePlayer, player.isActive else { return }

    DispatchQueue.main.async { [self] in
      _updateInfo(includeStatic: includeStatic, player)
    }
  }

  private func _updateInfo(includeStatic: Bool, _ player: PlayerCore) {
    let controller = player.mpv!
    if includeStatic || self.pathField.stringValue.isEmpty {
      updateStaticInfo(player)
    }

    let vbitrate = controller.getInt(MPVProperty.videoBitrate)
    self.vbitrateField.stringValue = FloatingPointByteCountFormatter.string(fromByteCount: vbitrate) + "bps"

    let abitrate = controller.getInt(MPVProperty.audioBitrate)
    self.abitrateField.stringValue = FloatingPointByteCountFormatter.string(fromByteCount: abitrate) + "bps"

    let dynamicStrProperties: [String: NSTextField] = [
      // At any point in time while the video is playing hardware decoding may fail causing a fall
      // back to software decoding.
      MPVProperty.hwdecCurrent: self.vdecoderField,
      MPVProperty.avsync: self.avsyncField,
      MPVProperty.totalAvsyncChange: self.totalAvsyncField,
      MPVProperty.frameDropCount: self.droppedFramesField,
      MPVProperty.mistimedFrameCount: self.mistimedFramesField,
      MPVProperty.displayFps: self.displayFPSField,
      MPVProperty.estimatedVfFps: self.voFPSField,
      MPVProperty.estimatedDisplayFps: self.edispFPSField,
      MPVProperty.currentAo: self.aoField,
    ]

    for (k, v) in dynamicStrProperties {
      let value = controller.getString(k)
      v.stringValue = value ?? "N/A"
      self.setLabelColor(v, by: value != nil)
    }

    let sigPeak = controller.getDouble(MPVProperty.videoParamsSigPeak);
    self.vprimariesField.stringValue = sigPeak > 0
      ? "\(controller.getString(MPVProperty.videoParamsPrimaries) ?? "?") / \(controller.getString(MPVProperty.videoParamsGamma) ?? "?") (\(sigPeak > 1 ? "H" : "S")DR)"
      : "N/A";
    self.setLabelColor(self.vprimariesField, by: sigPeak > 0)

    let isFileLoaded = player.info.isFileLoaded
    if isFileLoaded {
      if let colorspace = player.pwc.videoView.layerColorspace {
        let screenColorSpace = player.pwc.window?.screen?.colorSpace
        let sdrColorSpace = screenColorSpace?.cgColorSpace ?? VideoView.SRGB
        let isHdr = colorspace != sdrColorSpace
        // Prefer the name of the CGColorSpace of the layer. If the CGColorSpace does not have a
        // name then if the layer is set to the color space of the screen then fall back to the
        // localized name on the NSColorSpace, if present. Otherwise report it as unspecified.
        let name: String = {
          if let name = colorspace.name { return name as String }
          if let screenColorSpace, colorspace == screenColorSpace.cgColorSpace,
              let name = screenColorSpace.localizedName { return name }
          return "Unspecified"
        }()
        self.vcolorspaceField.stringValue = "\(name) (\(isHdr ? "H" : "S")DR)"
      } else {
        self.vcolorspaceField.stringValue = "Unspecified (SDR)"
      }

      if let hwPf = controller.getString(MPVProperty.videoParamsHwPixelformat) {
        self.vPixelFormat.stringValue = "\(hwPf) (HW)"
      } else if let swPf = controller.getString(MPVProperty.videoParamsPixelformat) {
        self.vPixelFormat.stringValue = "\(swPf) (SW)"
      }
    } else {
      self.vcolorspaceField.stringValue = "N/A"
      self.vPixelFormat.stringValue = "N/A"
    }
    self.setLabelColor(self.vcolorspaceField, by: isFileLoaded)
    self.setLabelColor(self.vPixelFormat, by: isFileLoaded)
  }

  private func updateStaticInfo(_ player: PlayerCore) {
    let controller = player.mpv!
    let info = player.info

    // string properties

    let strProperties: [String: NSTextField] = [
      MPVProperty.path: self.pathField,
      MPVProperty.fileFormat: self.fileFormatField,
      MPVProperty.chapters: self.chaptersField,
      MPVProperty.editions: self.editionsField,
      // in mpv 0.38, video-codec-name is an alias of current-tracks/video/codec, etc
      MPVProperty.currentTracksVideoCodec: self.vformatField,
      MPVProperty.currentTracksVideoCodecDesc: self.vcodecField,
      MPVProperty.containerFps: self.vfpsField,
      MPVProperty.currentVo: self.voField,
      MPVProperty.currentTracksAudioCodecDesc: self.acodecField,
      MPVProperty.audioParamsFormat: self.aformatField,
      MPVProperty.audioParamsChannels: self.achannelsField,
      MPVProperty.audioBitrate: self.abitrateField,
      MPVProperty.audioParamsSamplerate: self.asamplerateField
    ]

    for (k, v) in strProperties {
      var value = controller.getString(k)
      if value == "" { value = nil }
      v.stringValue = value ?? "N/A"
      self.setLabelColor(v, by: value != nil)
    }

    // other properties

    let duration = controller.getDouble(MPVProperty.duration)
    self.durationField.stringValue = VideoTime(duration).stringRepresentation

    let vwidth = controller.getInt(MPVProperty.width)
    let vheight = controller.getInt(MPVProperty.height)
    let dwidth = controller.getInt(MPVProperty.dwidth)
    let dheight = controller.getInt(MPVProperty.dheight)
    var sizeDisplayString = "\(vwidth)\u{d7}\(vheight)"
    if vwidth != dwidth || vheight != dheight {
      sizeDisplayString += "  (\(dwidth)\u{d7}\(dheight))"
    }
    self.vsizeField.stringValue = sizeDisplayString
    self.setLabelColor(self.vsizeField, by: vwidth > 0 && vheight > 0)

    let fileSize = controller.getInt(MPVProperty.fileSize)
    self.fileSizeField.stringValue = "\(FloatingPointByteCountFormatter.string(fromByteCount: fileSize))B"

    // track list

    self.trackPopup.removeAllItems()
    var needSeparator = false
    for track in info.videoTracks {
      self.trackPopup.menu?.addItem(withTitle: "Video" + track.readableTitle,
                                    action: nil, tag: nil, obj: track, stateOn: false)
      needSeparator = true
    }
    if needSeparator && !info.audioTracks.isEmpty {
      self.trackPopup.menu?.addItem(NSMenuItem.separator())
    }
    for track in info.audioTracks {
      self.trackPopup.menu?.addItem(withTitle: "Audio" + track.readableTitle,
                                    action: nil, tag: nil, obj: track, stateOn: false)
      needSeparator = true
    }
    if needSeparator && !info.subTracks.isEmpty {
      self.trackPopup.menu?.addItem(NSMenuItem.separator())
    }
    for track in info.subTracks {
      self.trackPopup.menu?.addItem(withTitle: "Subtitle" + track.readableTitle,
                                    action: nil, tag: nil, obj: track, stateOn: false)
    }
    self.trackPopup.selectItem(at: 0)
    self.updateTrack()
  }

  private func needsUpdate(_ notification: Notification) {
    updateInfo()
  }

  @objc func dynamicUpdate() {
    guard !watchTableView.isEditInProgress else { return }
    updateInfo(includeStatic: false)
    guard !watchTableView.isEditInProgress else { return }

    /// Do not call `reloadData()` (no arg version) because it will clear the selection. Also, because we know the number of rows will not change,
    /// calling `reloadData(forRowIndexes:)` will get the same result but much more efficiently
    watchTableView.reloadData(forRowIndexes: IndexSet(0..<watchTableView.numberOfRows), columnIndexes: IndexSet(0..<watchTableView.numberOfColumns))
  }

  func updateTrack() {
    guard let track = trackPopup.selectedItem?.representedObject as? MPVTrack else { return }

    trackIdField.stringValue = "\(track.id)"
    setLabelColor(trackDefaultField, by: track.isDefault)
    setLabelColor(trackForcedField, by: track.isForced)
    setLabelColor(trackSelectedField, by: track.isSelected)
    setLabelColor(trackExternalField, by: track.isExternal)

    let strProperties: [(String?, NSTextField)] = [
      (track.srcId?.description, trackSourceIdField),
      (track.title, trackTitleField),
      (track.lang, trackLangField),
      (track.externalFilename, trackFilePathField),
      (track.codec, trackCodecField),
      (track.decoderDesc, trackDecoderField),
      (track.demuxFps?.description, trackFPSField),
      (track.demuxChannels, trackChannelsField),
      (track.demuxSamplerate?.description, trackSampleRateField)
    ]

    for (str, field) in strProperties {
      field.stringValue = str ?? "N/A"
      setLabelColor(field, by: str != nil)
    }
  }

  // MARK: - NSTableView

  func numberOfRows(in tableView: NSTableView) -> Int {
    return watchProperties.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let identifier = tableColumn?.identifier else { return nil }
    guard let cell = watchTableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView else {
      return nil
    }
    guard let property = watchProperties[at: row] else { return nil }

    switch identifier {
    case .key:
      if let textField = cell.textField {
        textField.stringValue =  property
      }
      return cell
    case .value:
      if let textField = cell.textField {
        guard let player = PlayerManager.shared.lastActivePlayer, player.isActive else {
          // If no active player, just show blank values
          textField.stringValue = ""
          return cell
        }
        
        guard !player.isStopping, let value = player.mpv.getString(property) else {
          let errorString = NSLocalizedString("inspector.error", comment: "Error")

          let mutableString = NSMutableAttributedString(string: errorString)
          mutableString.addItalic(using: textField.font)
          textField.attributedStringValue = mutableString
          textField.textColor = .disabledControlTextColor
          return cell
        }

        textField.stringValue = value
        textField.textColor = .labelColor
      }
      return cell
    default:
      Logger.log.error("Unrecognized column: '\(identifier.rawValue)'")
      return nil
    }
  }

  func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
    /// The background color for a `NSTableRowView` will default to the parent's background color, which results in an
    /// unwanted additive effect for translucent backgrounds. Just make each row transparent.
    rowView.backgroundColor = .clear
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    deleteButton.isEnabled = !watchTableView.selectedRowIndexes.isEmpty
  }

  // MARK: Watch Table Drag & Drop

  @objc func tableView(_ tableView: NSTableView, pasteboardWriterForRow rowIndex: Int) -> NSPasteboardWriting? {
    let watchProperties = watchProperties
    if rowIndex < watchProperties.count {
      return watchProperties[rowIndex] as NSString?
    }
    return nil
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
    return tableDragDelegate!.tableView(tableView, validateDrop: info, proposedRow: rowIndex, proposedDropOperation: dropOperation)
  }

  /// Accept the drop and execute changes, or reject drop.
  ///
  /// Remember that we can expect the following (see notes in `tableView(_, validateDrop, …)`)
  /// 1. `0 <= targetRowIndex <= rowCount`
  /// 2. `dropOperation = .above`.
  @objc func tableView(_ tableView: NSTableView,
                       acceptDrop info: NSDraggingInfo, row targetRowIndex: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
    return tableDragDelegate!.tableView(tableView, acceptDrop: info, row: targetRowIndex, dropOperation: dropOperation)
  }

  // MARK: - Watch Table CRUD

  func insertWatchRows(_ rowList: [String], at targetRowIndex: Int? = nil) {
    let (tableUIChange, allItemsNew) = watchTableView.buildInsert(of: rowList, at: targetRowIndex, in: watchProperties)

    // Save model
    watchProperties = allItemsNew
    saveWatchList()

    // Notify Watch table of update:
    watchTableView.post(tableUIChange)
  }

  func moveWatchRows(from rowIndexes: IndexSet, at targetRowIndex: Int) {
    let (tableUIChange, allItemsNew) = watchTableView.buildMove(rowIndexes, to: targetRowIndex, in: watchProperties)

    // Save model
    watchProperties = allItemsNew
    saveWatchList()

    // Animate update to Watch table UI:
    watchTableView.post(tableUIChange)
  }

  func removeWatchRows(_ rowIndexes: IndexSet) {
    guard !rowIndexes.isEmpty else { return }

    Logger.log.verbose("Removing rows from Watch table: \(rowIndexes)")
    let (tableUIChange, allItemsNew) = watchTableView.buildRemove(rowIndexes, in: watchProperties)

    // Save model
    watchProperties = allItemsNew
    saveWatchList()

    // Animate update to Watch table UI:
    watchTableView.post(tableUIChange)
  }

  // MARK: - Window Geometry

  func resizeTableColumns(forTableWidth tableWidth: CGFloat) {
    guard let keyColumn = watchTableView.tableColumn(withIdentifier: .key),
          let valueColumn = watchTableView.tableColumn(withIdentifier: .value),
          let tableScrollView = watchTableView.enclosingScrollView else {
      return
    }

    let adjustedTableWidth = tableWidth - tableScrollView.verticalScroller!.frame.width
    let keyColumnMaxWidth = adjustedTableWidth - valueColumn.minWidth
    var newKeyColumnWidth = keyColumn.width
    if keyColumn.width > keyColumnMaxWidth {
      newKeyColumnWidth = keyColumnMaxWidth
      keyColumn.width = newKeyColumnWidth
    }
    valueColumn.width = adjustedTableWidth - newKeyColumnWidth
    tableScrollView.needsLayout = true
    tableScrollView.needsDisplay = true
  }

  func windowWillResize(_ sender: NSWindow, to newWindowSize: NSSize) -> NSSize {
    if let window = window, window.inLiveResize {
      /// Table size will change with window size, so need to find the new table width from `newWindowSize`.
      /// We know that our window's width is composed of 2 things: the table width + all other fixed "non-table" stuff.
      /// We first find the non-table width by subtracting current table size from current window size.
      /// Note: `NSTableView` does not give an honest answer for its width, but can use its parent (`NSClipView`) width.
      let oldTableWidth = watchTableView.superview!.frame.width
      let nonTableWidth = window.frame.width - oldTableWidth
      let newTableWidth = newWindowSize.width - nonTableWidth
      resizeTableColumns(forTableWidth: newTableWidth)
    }

    return newWindowSize
  }

  func windowDidResize(_ notification: Notification) {
    if let window = window, window.inLiveResize {
      let tableWidth = watchTableView.superview!.frame.width
      resizeTableColumns(forTableWidth: tableWidth)
    }
  }

  // MARK: - IBActions

  private let optionNameValidator: Utility.InputValidator<String> = { input in
    if input.isEmpty {
      return .valueIsEmpty
    }
    if input.containsWhitespaceOrNewlines() {
      return .custom("Value cannot contain whitespaces or newlines.")
    }
    return .ok
  }

  @IBAction func addWatchAction(_ sender: AnyObject) {
    Utility.quickPromptPanel("add_watch", validator: optionNameValidator, sheetWindow: window) { [self] newWatchKey in
      insertWatchRows([newWatchKey])
    }
  }

  @IBAction func removeWatchAction(_ sender: AnyObject) {
    let rowIndexes = watchTableView.selectedRowIndexes
    removeWatchRows(rowIndexes)
  }

  @IBAction func tabSwitched(_ sender: NSSegmentedControl) {
    tabView.selectTabViewItem(at: sender.selectedSegment)
    UIState.shared.set(sender.selectedSegment, for: .uiInspectorWindowTabIndex)
  }

  @IBAction func trackSwitched(_ sender: AnyObject) {
    updateTrack()
  }


  // MARK: Utils

  private func setLabelColor(_ label: NSTextField, by state: Bool) {
    label.textColor = state ? NSColor.labelColor : NSColor.disabledControlTextColor
  }

  private func saveWatchList() {
    Preference.set(watchProperties, for: .watchProperties)
  }

  class WatchTableColumnHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
      // Override background color
      self.drawsBackground = false
      watchTableColumnHeaderColor.set()
      cellFrame.fill(using: .sourceOver)

      super.draw(withFrame: cellFrame, in: controlView)
    }
  }
}

extension InspectorWindowController: EditableTableViewDelegate {
  var parentTableView: EditableTableView! { watchTableView }

  func userDidDoubleClickOnCell(row rowIndex: Int, column columnIndex: Int) -> Bool {
    // only first column can be edited
    Logger.log.verbose("Double-click: Edit requested for row \(rowIndex) in Watch table")
    watchTableView.editCell(row: rowIndex, column: 0)
    return true
  }

  func userDidPressEnterOnRow(_ rowIndex: Int) -> Bool {
    Logger.log.verbose("Enter key: Edit requested for row \(rowIndex) in Watch table")
    watchTableView.editCell(row: rowIndex, column: 0)
    return true
  }

  func editDidEndWithNewText(newValue: String, row rowIndex: Int, column columnIndex: Int,
                             then doAfter: OnSuccessCallback? = nil) -> Bool {
    Logger.log.verbose("Watch table: user finished editing value for row \(rowIndex), col \(columnIndex): \(newValue.quoted)")
    guard columnIndex == 0 else { return false }
    guard rowIndex < watchProperties.count else { return false }

    var watchProperties = watchProperties
    watchProperties[rowIndex] = newValue
    self.watchProperties = watchProperties
    saveWatchList()

    if let doAfter {
      doAfter()
    }
    return true
  }

  func isDeleteEnabled() -> Bool {
    !watchTableView.selectedRowIndexes.isEmpty
  }

  func doEditMenuDelete() {
    removeWatchRows(watchTableView.selectedRowIndexes)
  }
}

fileprivate func readWatchListFromPasteboard(_ pasteboard: NSPasteboard) -> [String] {
  let stringItems = pasteboard.getStringItems()
  guard stringItems.count <= Constants.inspectorWatchTableMaxRowsPerOperation else { return [] }
  // Strip values from args to support import from mpv Options table
  let sanitizedItems = stringItems.compactMap { String($0.split(separator: "=").first!) }
  // But if any key has a whitespace char or newline, reject entire drop as invalid
  // (should help prevent 95% of accidental imports)
  for stringItem in sanitizedItems {
    guard !stringItem.containsWhitespaceOrNewlines() else {
      return []
    }
  }
  return sanitizedItems
}
