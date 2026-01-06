//
//  QuickSettingViewController.swift
//  iina
//
//  Created by lhc on 12/8/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

fileprivate let eqUserDefinedProfileMenuItemTag = 0
fileprivate let eqPresetProfileMenuItemTag = 1
fileprivate let eqDeleteMenuItemTag = -1
fileprivate let eqRenameMenuItemTag = -2
fileprivate let eqSaveMenuItemTag = -3
fileprivate let eqCustomMenuItemTag = 1000

/// Formatter for `customSpeedTextField`.
///
/// Configure the number formatter in code instead of the XIB so it is easier to follow.
fileprivate let speedFormatter: NumberFormatter = {
  let fmt = NumberFormatter()
  fmt.numberStyle = .decimal
  fmt.usesGroupingSeparator = true
  fmt.maximumSignificantDigits = 25  // just make very big
  fmt.minimumFractionDigits = 0
  fmt.maximumFractionDigits = 6  // matches mpv behavior
  fmt.usesSignificantDigits = false
  fmt.roundingMode = .halfDown   // matches mpv behavior
  fmt.minimum = NSNumber(floatLiteral: AppData.mpvMinPlaybackSpeed)
  return fmt
}()

fileprivate let speedSliderStepCount = 24.0

class QuickSettingViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, SidebarTabGroupViewController {

  override var nibName: NSNib.Name {
    return NSNib.Name("QuickSettingViewController")
  }

  /// Calls `refreshDenialPeriodDidEnd` at timeout
  private let refreshDenialPeriodTimer = TimeoutTimer(timeout: Constants.TimeInterval.quickSettingsUpdateGracePeriod)
  private var isInRefreshDenialPeriod: Bool {
    refreshDenialPeriodTimer.isValid
  }

  /**
   Similar to the one in `PlaylistViewController`.
   Since IBOutlet is `nil` when the view is not loaded at first time,
   use this variable to cache which tab it need to switch to when the
   view is ready. The value will be handled after loaded.
   */
  private var pendingSwitchRequest: Sidebar.Tab?

  // TODO: clean this up. It's super kludgey
  /// is showing secondary sub if `false`.
  private var isShowingPrimarySubPanel: Bool {
    get {
      guard let pwc else { return true }
      return pwc.currentLayout.moreSidebarState.selectedSubSegment == 0
    }
    set {
      guard let pwc else { return }
      let selectedSegment = newValue ? 0 : 1  // convert from bool to segment selection

      // Put inside task to protect from race
      pwc.animationPipeline.submitInstantTask{
        let prevLayout = pwc.currentLayout
        let moreSidebarState = Sidebar.SidebarMiscState(playlistSidebarWidth: prevLayout.moreSidebarState.playlistSidebarWidth,
                                                        selectedSubSegment: selectedSegment,
                                                        selectedPluginTabID: prevLayout.moreSidebarState.selectedPluginTabID)
        pwc.currentLayout = prevLayout.clone(moreSidebarState: moreSidebarState)
      }
    }
  }

  weak var player: PlayerCore!
  weak var pwc: PlayerWindowController! {
    didSet {
      self.player = pwc.player
    }
  }

  private(set) var currentTab: Sidebar.Tab = .video

  var observers: [NSObjectProtocol] = []

  @IBOutlet weak var tabHeightConstraint: NSLayoutConstraint!

  @IBOutlet weak var videoTabScrollView: NSScrollView!
  @IBOutlet weak var audioTabScrollView: NSScrollView!
  @IBOutlet weak var subtitlesTabScrollView: NSScrollView!

  @IBOutlet weak var videoTabBtn: NSButton!
  @IBOutlet weak var audioTabBtn: NSButton!
  @IBOutlet weak var subTabBtn: NSButton!
  @IBOutlet weak var tabView: NSTabView!

  @IBOutlet weak var buttonTopConstraint: NSLayoutConstraint!

  @IBOutlet weak var videoTableView: NSTableView!
  @IBOutlet weak var audioTableView: NSTableView!
  @IBOutlet weak var subTableView: NSTableView!
  @IBOutlet weak var secSubTableView: NSTableView!

  @IBOutlet weak var rotateSegment: NSSegmentedControl!

  @IBOutlet weak var aspectPresetsSegment: NSSegmentedControl!
  @IBOutlet weak var customAspectTextField: NSTextField!

  @IBOutlet weak var cropPresetsSegment: NSSegmentedControl!
  @IBOutlet weak var customCropTextField: NSTextField!

  @IBOutlet weak var speedSlider: NSSlider!
  @IBOutlet weak var speedSliderIndicator: NSTextField!
  @IBOutlet weak var speedSliderConstraint: NSLayoutConstraint!
  @IBOutlet weak var speedSliderContainerView: NSView!

  @IBOutlet weak var speedSlider0_25xLabel: NSTextField!
  @IBOutlet weak var speedSlider1xLabel: NSTextField!
  @IBOutlet weak var speedSlider4xLabel: NSTextField!
  @IBOutlet weak var speedSlider16xLabel: NSTextField!
  @IBOutlet var speedSlider1xLabelCenterXConstraint: NSLayoutConstraint!
  @IBOutlet var speedSlider4xLabelCenterXConstraint: NSLayoutConstraint!
  @IBOutlet var speedSlider1xLabelPrevLabelConstraint: NSLayoutConstraint!
  @IBOutlet var speedSlider4xLabelPrevLabelConstraint: NSLayoutConstraint!
  @IBOutlet var speedSlider16xLabelPrevLabelConstraint: NSLayoutConstraint!

  @IBOutlet weak var customSpeedTextField: NSTextField!
  @IBOutlet weak var speedResetBtn: NSButton!

  @IBOutlet weak var switchHorizontalLine: NSBox!
  @IBOutlet weak var switchHorizontalLine2: NSBox!
  @IBOutlet weak var hardwareDecodingSwitch: NSSwitch!
  @IBOutlet weak var deinterlaceSwitch: NSSwitch!
  @IBOutlet weak var hdrSwitch: NSSwitch!
  @IBOutlet weak var hardwareDecodingLabel: NSTextField!
  @IBOutlet weak var deinterlaceLabel: NSTextField!
  @IBOutlet weak var hdrLabel: NSTextField!

  @IBOutlet weak var brightnessSlider: NSSlider!
  @IBOutlet weak var contrastSlider: NSSlider!
  @IBOutlet weak var saturationSlider: NSSlider!
  @IBOutlet weak var gammaSlider: NSSlider!
  @IBOutlet weak var hueSlider: NSSlider!

  @IBOutlet weak var brightnessResetBtn: NSButton!
  @IBOutlet weak var contrastResetBtn: NSButton!
  @IBOutlet weak var saturationResetBtn: NSButton!
  @IBOutlet weak var gammaResetBtn: NSButton!
  @IBOutlet weak var hueResetBtn: NSButton!

  @IBOutlet weak var audioDelaySlider: NSSlider!
  @IBOutlet weak var audioDelaySliderIndicator: NSTextField!
  @IBOutlet weak var audioDelaySliderConstraint: NSLayoutConstraint!
  @IBOutlet weak var customAudioDelayTextField: NSTextField!
  @IBOutlet weak var audioDelayResetBtn: NSButton!
  @IBOutlet weak var hideSwitch: NSSwitch!
  @IBOutlet weak var secHideSwitch: NSSwitch!
  @IBOutlet weak var subLoadSegmentedControl: NSSegmentedControl!
  @IBOutlet weak var subDelaySlider: NSSlider!
  @IBOutlet weak var subDelaySliderIndicator: NSTextField!
  @IBOutlet weak var subDelaySliderConstraint: NSLayoutConstraint!
  @IBOutlet weak var customSubDelayTextField: NSTextField!
  @IBOutlet weak var subDelayResetBtn: NSButton!
  @IBOutlet weak var subSegmentedControl: NSSegmentedControl!

  @IBOutlet weak var eqPopUpButton: NSPopUpButton!
  @IBOutlet weak var audioEqSlider1: NSSlider!
  @IBOutlet weak var audioEqSlider2: NSSlider!
  @IBOutlet weak var audioEqSlider3: NSSlider!
  @IBOutlet weak var audioEqSlider4: NSSlider!
  @IBOutlet weak var audioEqSlider5: NSSlider!
  @IBOutlet weak var audioEqSlider6: NSSlider!
  @IBOutlet weak var audioEqSlider7: NSSlider!
  @IBOutlet weak var audioEqSlider8: NSSlider!
  @IBOutlet weak var audioEqSlider9: NSSlider!
  @IBOutlet weak var audioEqSlider10: NSSlider!

  @IBOutlet weak var audioEQResetBtn: NSButton!

  @IBOutlet weak var subScaleSlider: NSSlider!
  @IBOutlet weak var subScaleResetBtn: NSButton!
  @IBOutlet weak var subPosSlider: NSSlider!

  var subTextColorWell: NSColorWell!
  var subTextBorderColorWell: NSColorWell!
  var subTextBgColorWell: NSColorWell!

  @IBOutlet weak var subTextColorWellContainer: NSView!
  @IBOutlet weak var subTextSizePopUp: NSPopUpButton!
  @IBOutlet weak var subTextBorderColorWellContainer: NSView!
  @IBOutlet weak var subTextBorderWidthPopUp: NSPopUpButton!
  @IBOutlet weak var subTextBgColorWellContainer: NSView!
  @IBOutlet weak var subTextFontBtn: NSButton!

  @IBOutlet weak var subtitleSwitch: NSSwitch!
  @IBOutlet weak var secondarySubtitleSwitch: NSSwitch!

  private lazy var audioEQSliders: [NSSlider] = [
    audioEqSlider1, audioEqSlider2, audioEqSlider3, audioEqSlider4, audioEqSlider5,
    audioEqSlider6, audioEqSlider7, audioEqSlider8, audioEqSlider9, audioEqSlider10
  ]

  private lazy var videoEQSliders: [NSSlider] = [
    brightnessSlider, contrastSlider, saturationSlider, gammaSlider, hueSlider
  ]

  private var lastUsedProfileName: String = ""
  private var inputString: String = ""

  private var downshift: CGFloat = 0
  private var tabHeight: CGFloat = 0

  func setVerticalConstraints(downshift: CGFloat, tabHeight: CGFloat) {
    if (self.downshift != downshift) || (self.tabHeight != tabHeight) {
      self.downshift = downshift
      self.tabHeight = tabHeight
      updateVerticalConstraints()
    }
  }

  private func updateVerticalConstraints() {
    player.log.verbose("QuickSettings: updating downshift=\(downshift), tabHeight=\(tabHeight)")
    self.buttonTopConstraint?.animateToConstant(downshift)
    self.tabHeightConstraint?.animateToConstant(tabHeight)
    view.needsLayout = true
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.idString = "QuickSettingsView"

    refreshDenialPeriodTimer.action = refreshDenialPeriodDidEnd

    updateVerticalConstraints()

    withAllTableViews { (tableView, _) in
      tableView.delegate = self
      tableView.dataSource = self
      tableView.superview?.superview?.layer?.cornerRadius = 4
      tableView.backgroundColor = NSColor.sidebarTableBackground
    }

    let tabScrollViews = [videoTabScrollView, audioTabScrollView, subtitlesTabScrollView]
    for (view, item) in zip(tabScrollViews, tabView.tabViewItems) {
      item.view = view
    }

    // Color Wells
    if #available(macOS 13.0, *) {
      subTextColorWell = NSColorWell(style: .default)
      subTextBgColorWell = NSColorWell(style: .default)
      subTextBorderColorWell = NSColorWell(style: .default)
    } else {
      subTextColorWell = RoundedColorWell()
      subTextBgColorWell = RoundedColorWell()
      subTextBorderColorWell = RoundedColorWell()
    }
    [(subTextColorWellContainer, subTextColorWell),
     (subTextBgColorWellContainer, subTextBgColorWell),
     (subTextBorderColorWellContainer, subTextBorderColorWell)].forEach { (view, well) in
      well.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(well)
      Utility.quickConstraints(["H:|[v]|", "V:|[v]|"], ["v": well])
    }

    // Wire color wells to IBAction handlers
    subTextColorWell.target = self
    subTextColorWell.action = #selector(subTextColorAction(_:))

    subTextBgColorWell.target = self
    subTextBgColorWell.action = #selector(subTextBgColorAction(_:))

    subTextBorderColorWell.target = self
    subTextBorderColorWell.action = #selector(subTextBorderColorAction(_:))


    if #available(macOS 26, *) {
      speedSlider.neutralValue = 8
      speedSlider.controlSize = .mini
      subPosSlider.controlSize = .mini
      for slider in audioEQSliders + videoEQSliders + [audioDelaySlider, subDelaySlider, subScaleSlider] {
        guard let slider else { continue }
        slider.controlSize = .mini
        slider.neutralValue = 0
      }

      subPosSlider.tintProminence = .none
    }

    if pendingSwitchRequest == nil {
      updateTabButtonSelection()
    } else {
      switchToTab(pendingSwitchRequest!)
      pendingSwitchRequest = nil
    }

    subLoadSegmentedControl.image(forSegment: 1)?.isTemplate = true
    switchHorizontalLine.layer?.opacity = 0.5
    switchHorizontalLine2.layer?.opacity = 0.5

    speedResetBtn.toolTip = NSLocalizedString("quicksetting.reset_speed", comment: "Reset speed to 1x")
    // Localize decimal format of numbers
    speedSlider0_25xLabel.stringValue = "\(0.25.groupedStringUpTo6Decimals)x"
    // Unclear if these need to be localized. Better to be safe?
    speedSlider1xLabel.stringValue = "\(1.groupedStringUpTo6Decimals)x"
    speedSlider4xLabel.stringValue = "\(4.groupedStringUpTo6Decimals)x"
    speedSlider16xLabel.stringValue = "\(16.groupedStringUpTo6Decimals)x"

    customSpeedTextField.formatter = speedFormatter

    let videoGeo = player.videoGeo
    updateSegmentLabelsForVideoTab(using: videoGeo)

    // EQs

    if let data = UserDefaults.standard.data(forKey: Preference.Key.userEQPresets.rawValue),
       let dict = try? JSONDecoder().decode(Dictionary<String, EQProfile>.self, from: data) {
      userEQs = dict
    }

    presetEQs.forEach { preset in
      eqPopUpButton.menu?.addItem(withTitle: preset.name, tag: eqPresetProfileMenuItemTag, obj: preset.localizationKey)
    }

    func observe(_ name: Notification.Name, using callback: @escaping (Notification) -> Void) {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: player, queue: .main, using: callback))
    }

    // - Notifications
    // Do not even listen to `iinaTracklistChanged`! The following listeners are finer-grained.
    observe(.iinaVIDChanged) { [self] _ in
      pwc.animationPipeline.submitInstantTask{ [self] in
        reloadVideoTabIfShown(using: player.videoGeo)
      }
    }
    observe(.iinaAIDChanged) { [self] _ in
      pwc.animationPipeline.submitInstantTask{ [self] in
        reloadAudioTabIfShown()
      }
    }
    func subReloadCallback(_ notification: Notification) {
      pwc.animationPipeline.submitInstantTask{ [self] in
        reloadSubTabIfShown()
      }
    }
    observe(.iinaSIDChanged, using: subReloadCallback)
    observe(.iinaSSIDChanged, using: subReloadCallback)
    observe(.iinaSecondSubVisibilityChanged, using: subReloadCallback)
    observe(.iinaSubVisibilityChanged, using: subReloadCallback)

    view.configureSubtreeForCoreAnimation()
    view.needsLayout = true

    // We register some of the tables for drag & drop (see below), so users will drag over the
    // sidebar to get to them. However, ViewportView & VideoView both also accept fileURLs, and
    // will do so even if occluded by the sidebar! We don't want (e.g.) audio files to be accidentally
    // dropped onto the sidebar instead of the audio table, because that will replace the current video
    // being played! Solution: register the sidebar for drops too, so it receives them before ViewportView,
    // and then just deny all of them. The denial will happen by default for NSViews.
    view.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL])

    if #available(OSX 10.13, *) {
      subTableView.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL])
      secSubTableView.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL])
      audioTableView.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL])
    }

    player.log.verbose("QuickSettings viewDidLoad done")
  }

  // MARK: - Right to Left Constraints

  /// Prepares the receiver for service after it has been loaded from an Interface Builder archive, or nib file.
  ///
  /// If the user interface layout direction is right to left then certain layout constraints that assume a left to right layout will need to be
  /// replaced. That will be handled by the `viewWillLayout` method. This method will disable these constraints to avoid triggering
  /// constraint errors before the constraints can be replaced.
  override func awakeFromNib() {
    super.awakeFromNib()
    guard speedSlider.userInterfaceLayoutDirection == .rightToLeft else { return }
    NSLayoutConstraint.deactivate([
      speedSlider1xLabelCenterXConstraint,
      speedSlider4xLabelCenterXConstraint,
      speedSlider1xLabelPrevLabelConstraint,
      speedSlider4xLabelPrevLabelConstraint,
      speedSlider16xLabelPrevLabelConstraint])
  }

  /// Calculate the constraint multiplier for a speed slider label.
  ///
  /// This method calculates the appropriate multiplier to use in a
  /// [centerX](https://developer.apple.com/documentation/uikit/nslayoutconstraint/attribute/centerx)
  /// constraint for a text field that sits under the speed slider and displays the speed associated with a particular tick mark.
  /// - Parameter speed: Playback speed the label indicates.
  /// - Returns: Multiplier to use in the constraint.
  private func calculateSliderLabelMultiplier(speed: Double) -> CGFloat {
    let tickIndex = Int(convertSpeedToSliderValue(speedSlider.closestTickMarkValue(toValue: speed)))
    let tickRect = speedSlider.rectOfTickMark(at: tickIndex)
    let tickCenterX = tickRect.origin.x + tickRect.width / 2
    let containerViewX = speedSlider.frame.origin.x + tickCenterX
    return containerViewX / speedSliderContainerView.frame.width
  }

  /// Called just before the `layout()` method of the view controller's view is called.
  ///
  /// If the user interface layout direction is right to left then this method will replace certain layout constraints with ones that properly
  /// position the reversed views.
  override func viewWillLayout() {
    // When the layout is right to left the first time this method is called the views will not have
    // been reversed. Once the views have been repositioned this method will be called again. Must
    // wait for that to happen before adjusting constraints to avoid triggering constraint errors.
    // Detect this based on the order of the speed slider labels.
    guard speedSliderContainerView.userInterfaceLayoutDirection == .rightToLeft,
          speedSlider16xLabel.frame.origin.x < speedSlider0_25xLabel.frame.origin.x else {
      super.viewWillLayout()
      return
    }

    // Deactivate the layout constraints that will be replaced.
    NSLayoutConstraint.deactivate([
      speedSlider1xLabelCenterXConstraint,
      speedSlider4xLabelCenterXConstraint,
      speedSlider1xLabelPrevLabelConstraint,
      speedSlider4xLabelPrevLabelConstraint,
      speedSlider16xLabelPrevLabelConstraint])

    // The multiplier in the constraints that position the 1x and 4x labels must be changed to
    // reflect the reversed views.
    speedSlider1xLabelCenterXConstraint = NSLayoutConstraint(
      item: speedSlider1xLabel as Any, attribute: .centerX, relatedBy: .equal, toItem: speedSlider,
      attribute: .right, multiplier: calculateSliderLabelMultiplier(speed: 1), constant: 0)
    speedSlider4xLabelCenterXConstraint = NSLayoutConstraint(
      item: speedSlider4xLabel as Any, attribute: .centerX, relatedBy: .equal, toItem: speedSlider,
      attribute: .right, multiplier: calculateSliderLabelMultiplier(speed: 4), constant: 0)

    // The constraints that impose an order on the labels must be changed to reflect the reversed
    // views.
    speedSlider1xLabelPrevLabelConstraint = NSLayoutConstraint(
      item: speedSlider1xLabel as Any, attribute: .right, relatedBy: .lessThanOrEqual,
      toItem: speedSlider0_25xLabel, attribute: .left, multiplier: 1, constant: 0)
    speedSlider4xLabelPrevLabelConstraint = NSLayoutConstraint(
      item: speedSlider4xLabel as Any, attribute: .right, relatedBy: .lessThanOrEqual,
      toItem: speedSlider1xLabel, attribute: .left, multiplier: 1, constant: 0)
    speedSlider16xLabelPrevLabelConstraint = NSLayoutConstraint(
      item: speedSlider16xLabel as Any, attribute: .right, relatedBy: .lessThanOrEqual,
      toItem: speedSlider4xLabel, attribute: .left, multiplier: 1, constant: 0)

    NSLayoutConstraint.activate([
      speedSlider1xLabelCenterXConstraint,
      speedSlider4xLabelCenterXConstraint,
      speedSlider1xLabelPrevLabelConstraint,
      speedSlider4xLabelPrevLabelConstraint,
      speedSlider16xLabelPrevLabelConstraint])
    super.viewWillLayout()
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    reloadCurrentTab()
  }

  deinit {
    ObjcUtils.silenced { [self] in
      for observer in observers {
        NotificationCenter.default.removeObserver(observer)
      }
    }
    observers = []
  }

  /// Return the slider value that represents the given playback speed.
  /// - Parameter speed: Playback speed.
  /// - Returns: Appropriate slider value.
  private func convertSpeedToSliderValue(_ speed: Double) -> Double {
    log(speed / AppData.minSpeed) / log(AppData.maxSpeed / AppData.minSpeed) * speedSliderStepCount
  }

  // TODO: should probably call this to change crop label every time a change to custom crop filter is detected
  /// Updates the segment labels from prefs for the Video tab's presets.
  ///
  /// This is only needed at first load and in response to changes to the relevant pref values.
  /// But make sure to call `updateAspectControls` & `updateCropControls` *after* this - not before!
  func updateSegmentLabelsForVideoTab(using videoGeo: VideoGeometry) {
    guard isViewLoaded else { return }

    if let segmentLabels = Preference.csvStringArray(for: .aspectRatioPanelPresets) {
      aspectPresetsSegment.segmentCount = segmentLabels.count + 1
      for segmentIndex in 1...cropPresetsSegment.segmentCount {
        if segmentIndex <= segmentLabels.count {
          let newLabel = segmentLabels[segmentIndex-1]
          aspectPresetsSegment.setLabel(newLabel, forSegment: segmentIndex)
        }
      }
    }

    if let segmentLabels = Preference.csvStringArray(for: .cropPanelPresets) {
      // save custom label
      let customLabel = cropPresetsSegment.label(forSegment: cropPresetsSegment.segmentCount - 1)!

      cropPresetsSegment.segmentCount = segmentLabels.count + 2
      for segmentIndex in 1..<cropPresetsSegment.segmentCount {
        if segmentIndex <= segmentLabels.count {
          let newLabel = segmentLabels[segmentIndex-1]
          cropPresetsSegment.setLabel(newLabel, forSegment: segmentIndex)
        }
      }
      cropPresetsSegment.setLabel(customLabel, forSegment: cropPresetsSegment.segmentCount - 1)
    }
  }

  /// Reload Aspect settings controls
  private func updateAspectControls(using videoGeo: VideoGeometry) {
    guard isViewLoaded else { return }

    let userAspectLabel = videoGeo.userAspectLabel
    aspectPresetsSegment.selectSegment(withLabel: userAspectLabel)
    let isAspectInPanel = aspectPresetsSegment.selectedSegment >= 0
    customAspectTextField.stringValue = isAspectInPanel ? "" : userAspectLabel
  }

  /// Reload Crop settings controls
  private func updateCropControls(using videoGeo: VideoGeometry) {
    guard isViewLoaded else { return }

    guard videoGeo.hasCrop else {
      player.log.verbose("Selecting crop preset segment: None")
      cropPresetsSegment.selectSegment(withTag: 0)
      customCropTextField.isHidden = true
      return
    }

    let cropLabel: String = videoGeo.selectedCropLabel
    cropPresetsSegment.selectSegment(withLabel: cropLabel)
    let isCropInPanel = cropPresetsSegment.selectedSegment >= 0
    if isCropInPanel {
      player.log.verbose("Selected crop preset segment matching label \(cropLabel.quoted)")
    } else {
      player.log.verbose("Selecting crop preset segment: Custom (for mpvLabel \(cropLabel.quoted))")
      cropPresetsSegment.selectSegment(withTag: cropPresetsSegment.segmentCount - 1)
      if let cropRect = videoGeo.cropRect {
        let customCropString = MPVFilter.makeCropBoxDisplayString(from: cropRect)
        player.log.verbose("Setting custom crop label string: \(customCropString.quoted)")
        customCropTextField.stringValue = customCropString
        customCropTextField.isHidden = false
        return
      }
    }
    customCropTextField.isHidden = true
  }

  /// Reload `Video` tab
  private func updateVideoTabControls(using videoGeo: VideoGeometry) {
    updateAspectControls(using: videoGeo)
    updateCropControls(using: videoGeo)

    if let knownRotationIndex = AppData.rotations.firstIndex(of: videoGeo.userRotation) {
      rotateSegment.selectSegment(withTag: knownRotationIndex)
    } else {
      // Not a right-angle rotation: deselect all segments
      rotateSegment.selectSegment(withLabel: "")
    }

    hardwareDecodingSwitch.state = player.info.hwdecEnabled ? .on : .off
    deinterlaceSwitch.state = player.info.deinterlace ? .on : .off
    hdrSwitch.isEnabled = player.info.hdrAvailable
    hdrSwitch.state = (player.info.hdrAvailable && player.info.hdrEnabled) ? .on : .off

    // These strings are also contained in the strings file of this view. Remove these lines if the localization of these strings are complete enough.
    hardwareDecodingLabel.stringValue = NSLocalizedString("quicksetting.hwdec", comment: "Hardware Decoding")
    deinterlaceLabel.stringValue = NSLocalizedString("quicksetting.deinterlace", comment: "Deinterlace")
    hdrLabel.stringValue = NSLocalizedString("quicksetting.hdr", comment: "HDR")

    updateSpeedControls(to: player.info.playSpeed)
  }

  /// Reload `Audio` tab
  private func updateAudioTabControls() {
    let audioDelay = player.info.audioDelay
    audioDelaySlider.doubleValue = audioDelay
    customAudioDelayTextField.doubleValue = audioDelay
    audioDelayResetBtn.isHidden = audioDelay == 0.0
    redraw(indicator: audioDelaySliderIndicator, constraint: audioDelaySliderConstraint, slider: audioDelaySlider, value: "\(customAudioDelayTextField.stringValue)s")
  }

  /// Reload `Subtitles` tab
  private func updateSubTabControls() {
    let isSubVisible = player.info.isSubVisible
    hideSwitch.state = isSubVisible ? .on : .off
    subTableView.isEnabled = isSubVisible

    let isSecondSubVisible = player.info.isSecondSubVisible
    secHideSwitch.state = isSecondSubVisible ? .on : .off
    secSubTableView.isEnabled = isSecondSubVisible

    if let currSub = player.info.currentTrack(.sub) {
      // FIXME: CollorWells cannot be disable?
      let enableTextSettings = !(currSub.isAssSub || currSub.isImageSub)
      [subTextColorWell, subTextSizePopUp, subTextBgColorWell, subTextBorderColorWell, subTextBorderWidthPopUp, subTextFontBtn].forEach { $0.isEnabled = enableTextSettings }
    }

    // controls can apply to either primary or secondary sub
    let isPrimary = isShowingPrimarySubPanel

    player.mpv.queue.async { [self] in
      guard !player.isStopping else { return }

      let subColorString = player.mpv.getString(MPVOption.Subtitles.subColor)
      let subBorderColorString = player.mpv.getString(MPVOption.Subtitles.subBorderColor)
      let subBgColorString = player.mpv.getString(MPVOption.Subtitles.subBackColor)

      let currSubScale = player.mpv.getDouble(MPVOption.Subtitles.subScale).clamped(to: 0.1...10)
      let displaySubScale = Utility.toDisplaySubScale(fromRealSubScale: currSubScale)
      player.log.trace("Current subScale: \(currSubScale) -> display: \(displaySubScale)")

      let currSubPos = isPrimary ? player.info.subPos : player.info.sub2Pos
      let subDelay = isPrimary ? player.info.subDelay : player.info.sub2Delay

      let fontSize = player.mpv.getInt(MPVOption.Subtitles.subFontSize)
      let borderWidth = player.mpv.getDouble(MPVOption.Subtitles.subBorderSize)

      DispatchQueue.main.async { [self] in
        subSegmentedControl.setSelected(true, forSegment: isPrimary ? 0 : 1)

        if let subColorString, let subTextColor = NSColor(mpvColorString: subColorString) {
          subTextColorWell.color = subTextColor
        }
        if let subBorderColorString, let subBorderColor = NSColor(mpvColorString: subBorderColorString) {
          subTextBorderColorWell.color = subBorderColor
        }
        if let subBgColorString, let subBgColor = NSColor(mpvColorString: subBgColorString) {
          subTextBgColorWell.color = subBgColor
        }

        subPosSlider.intValue = Int32(currSubPos)
        subScaleSlider.doubleValue = displaySubScale + (displaySubScale > 0 ? -1 : 1)

        subScaleResetBtn.isHidden = displaySubScale == 1.0

        subDelaySlider.doubleValue = subDelay
        customSubDelayTextField.doubleValue = subDelay
        subDelayResetBtn.isHidden = subDelay == 0.0
        redraw(indicator: subDelaySliderIndicator, constraint: subDelaySliderConstraint, slider: subDelaySlider, value: "\(customSubDelayTextField.stringValue)s")

        subTextSizePopUp.selectItem(withTitle: fontSize.description)

        subTextBorderWidthPopUp.selectItem(at: -1)
        for item in subTextBorderWidthPopUp.itemArray {
          if borderWidth == Double(item.title) {
            subTextBorderWidthPopUp.select(item)
          }
        }
      }
    }
  }

  private func updateSpeedControls(to newSpeed: Double) {
    let newSpeed = constrainSpeed(newSpeed)
    speedSlider.doubleValue = convertSpeedToSliderValue(newSpeed)
    customSpeedTextField.doubleValue = newSpeed
    speedResetBtn.isHidden = newSpeed == 1.0
    /// Use `customSpeedTextField.stringValue` to take advantage of its formatter
    /// (e.g. `16` will be displayed instead of `16.0`)
    redraw(indicator: speedSliderIndicator, constraint: speedSliderConstraint, slider: speedSlider, value: "\(customSpeedTextField.stringValue)x")
  }

  private func updateVideoEqState() {
    brightnessSlider.intValue = Int32(player.info.brightness)
    contrastSlider.intValue = Int32(player.info.contrast)
    saturationSlider.intValue = Int32(player.info.saturation)
    gammaSlider.intValue = Int32(player.info.gamma)
    hueSlider.intValue = Int32(player.info.hue)

    brightnessResetBtn.isHidden = player.info.brightness == 0
    contrastResetBtn.isHidden = player.info.contrast == 0
    saturationResetBtn.isHidden = player.info.saturation == 0
    gammaResetBtn.isHidden = player.info.gamma == 0
    hueResetBtn.isHidden = player.info.hue == 0
  }

  private func startRefreshDenialPeriod() {
    refreshDenialPeriodTimer.restart()
  }

  /// Called by `refreshDenialPeriodTimer`.
  private func refreshDenialPeriodDidEnd() {
    player.setQuickSettingsViewNeedsUpdate()
  }

  private func switchToTab(_ tab: Sidebar.Tab) {
    guard isViewLoaded else { return }
    assert(player.pwc.isOpen(sidebarTabGroup: .settings),
           "switchToTab should not be called when settings TabGroup is not shown")
    guard currentTab != tab else { return }
    guard tab.group == .settings else {
      player.log.error("QuickSettings: cannot switch to tab: \(tab)")
      return
    }

    // See also: tabBtnAction()
    let buttonTag: Int
    switch tab {
    case .video:
      buttonTag = 0
    case .audio:
      buttonTag = 1
    case .sub:
      buttonTag = 2
    default:
      Logger.fatal("QuickSettings: Invalid tab: \(tab)")
    }
    currentTab = tab
    tabView.selectTabViewItem(at: buttonTag)
    pwc.didChangeTab(to: tab, then: { [self] in
      updateTabButtonSelection()
      reloadCurrentTab()
    })
  }

  /// Reload Quick Settings controls for the current tab.
  ///
  /// Do not call this directly. Call `player.setQuickSettingsViewNeedsUpdate()` instead.
  func reloadCurrentTab() {
    guard isViewLoaded else { return }
    guard !isInRefreshDenialPeriod else { return }

    switch currentTab {

    case .audio:
      reloadAudioTabIfShown()

    case .video:
      reloadVideoTabIfShown(using: player.videoGeo)

    case .sub:
      guard pwc.isOpen(sidebarTab: .sub) else { return }
      reloadSubTabIfShown()

    default:
      player.log.error("QuickSettings.reload(): currentTab is invalid: \(currentTab)")
    }
  }

  /// Redraws the set of tab buttons (at top). The button corresponding to `currentTab` will
  /// be drawn with a special tint to indicate it is the active tab.
  private func updateTabButtonSelection() {
    updateTabActiveStatus(for: videoTabBtn, isActive: currentTab == .video)
    updateTabActiveStatus(for: audioTabBtn, isActive: currentTab == .audio)
    updateTabActiveStatus(for: subTabBtn, isActive: currentTab == .sub)
  }

  private func reloadVideoTabIfShown(using videoGeo: VideoGeometry) {
    guard isViewLoaded else { return }
    guard currentTab == .video else { return }
    guard pwc.isOpen(sidebarTab: .video) else { return }
    player.log.verbose("QuickSettings: reloading Video tab")
    // Easiest place to put this - need to call it when setting equalizers
    player.videoView.displayActive()
    videoTableView.reloadData()
    updateVideoTabControls(using: videoGeo)
    updateVideoEqState()
  }

  private func reloadAudioTabIfShown() {
    guard isViewLoaded else { return }
    guard pwc.isOpen(sidebarTab: .audio) else { return }
    player.log.verbose("QuickSettings: reloading tab \(currentTab.name.quoted)")
    updateAudioTabControls()
    updateAudioEqState()
    audioTableView.reloadData()
  }

  private func reloadSubTabIfShown() {
    guard isViewLoaded else { return }
    guard currentTab == .sub else { return }
    player.log.verbose("QuickSettings: reloading Subtitles tab")
    updateSubTabControls()  // do this before reloading tables, in case isEnabled changes
    subTableView.reloadData()
    secSubTableView.reloadData()
  }

  func setHdrAvailability(to available: Bool) {
    guard isViewLoaded else { return }
    pwc.animationPipeline.submitInstantTask{ [self] in
      hdrSwitch.isEnabled = available
      hdrSwitch.state = (available && player.info.hdrEnabled) ? .on : .off
    }
  }

  // MARK: - Switch tab

  /// Switch tab (call from other objects)
  func pleaseSwitchToTab(_ tab: Sidebar.Tab) {
    if isViewLoaded {
      switchToTab(tab)
    } else {
      // cache the request
      pendingSwitchRequest = tab
    }
  }

  // MARK: - NSTableView delegate

  func numberOfRows(in tableView: NSTableView) -> Int {
    if tableView == videoTableView {
      return player.info.videoTracks.count + 1
    } else if tableView == audioTableView {
      return player.info.audioTracks.count + 1
    } else if tableView == subTableView || tableView == secSubTableView {
      let subTracks = player.info.subTracks
      return subTracks.count + 1
    } else {
      return 0
    }
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let columnName = tableColumn?.identifier else { return nil }
    guard let cell = tableView.makeView(withIdentifier: columnName, owner: self) as? NSTableCellView else {
      return nil
    }

    guard let textField = cell.textField else { return cell }

    // get track according to tableview
    // row=0: <None> row=1~: tracks[row-1]
    let track: MPVTrack?
    let activeId: Int
    if tableView == videoTableView {
      track = row == 0 ? nil : player.info.videoTracks[at: row-1]
      activeId = player.info.vid ?? -1
    } else if tableView == audioTableView {
      track = row == 0 ? nil : player.info.audioTracks[at: row-1]
      activeId = player.info.aid ?? -1
    } else if tableView == subTableView {
      track = row == 0 ? nil : player.info.subTracks[at: row-1]
      activeId = player.info.sid ?? -1
    } else if tableView == secSubTableView {
      track = row == 0 ? nil : player.info.subTracks[at: row-1]
      activeId = player.info.secondSid ?? -1
    } else {
      return nil
    }

    let mutableString: NSMutableAttributedString

    switch columnName {
    case .isChosen:
      let isChosen = track == nil ? (activeId == 0) : (track!.id == activeId)
      mutableString = NSMutableAttributedString(string: isChosen ? Constants.String.dot : "")
    case .trackName:
      if let track {
        mutableString = NSMutableAttributedString(string: track.infoString)
      } else {
        // "<None>"
        mutableString = NSMutableAttributedString(string: Constants.String.trackNone)
        mutableString.addItalic(using: textField.font)
      }
    case .trackId:
      mutableString = NSMutableAttributedString(string: track?.idString ?? "")
    default:
      return nil
    }

    var rowEnabled: Bool = tableView.isEnabled

    // Gray out table entries if table is disabled, and for secondary subtitles already selected
    if tableView == subTableView {
      if row > 0, let activeSSID = player.info.secondSid, row == activeSSID {
        rowEnabled = false
      }
    } else if tableView == secSubTableView {
      if row > 0, let activeSID = player.info.sid, row == activeSID {
        rowEnabled = false
      }
    }
    textField.textColor = rowEnabled ? .controlTextColor : .disabledControlTextColor
    textField.attributedStringValue = mutableString
    return cell
  }

  func tableView(_ tableView: NSTableView,
                 validateDrop info: NSDraggingInfo, proposedRow row: Int,
                 proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
    if (tableView == subTableView || tableView == secSubTableView) {
      // Subtitles / Secondary Subtitles tables

      let pb = info.draggingPasteboard
      if pb.pasteboardItems?.count != 1 { // multiple items are not supported
        return []
      }

      let classes = [ NSURL.self ]
      guard let filePathURL = (pb.readObjects(forClasses: classes, options: nil)?.first as? NSURL)?.filePathURL else {
        return []
      }

      var existingTrack: MPVTrack? = nil
      if (player.info.subTracks.contains(where: { (track) -> Bool in
        if (track.externalFilename == filePathURL.path) {
          existingTrack = track
          return true
        }
        return false
      })) {

        let existingRow = player.info.subTracks.firstIndex(of: existingTrack!)! + 1
        tableView.setDropRow(existingRow, dropOperation: NSTableView.DropOperation.on)
        return .copy
      }

      // only subTableView may load new files
      guard tableView == subTableView else {
        return []
      }

      if (Utility.supportedFileExt[.sub]!.contains(filePathURL.pathExtension)) {
        tableView.setDropRow(player.info.subTracks.count + 1, dropOperation: NSTableView.DropOperation.above)
        return .copy
      }

    } else if (tableView == audioTableView) {
      // Audio table

      let pb = info.draggingPasteboard
      if pb.pasteboardItems?.count != 1 { // multiple items are not supported
        return []
      }

      let classes = [ NSURL.self ]
      guard let filePathURL = (pb.readObjects(forClasses: classes, options: nil)?.first as? NSURL)?.filePathURL else {
        return []
      }

      var existingTrack: MPVTrack? = nil
      if (player.info.audioTracks.contains(where: { (track) -> Bool in
        if (track.externalFilename == filePathURL.path) {
          existingTrack = track
          return true
        }
        return false
      })) {
        let existingRow = player.info.audioTracks.firstIndex(of: existingTrack!)! + 1
        tableView.setDropRow(existingRow, dropOperation: NSTableView.DropOperation.on)
        return .copy
      }

      if (Utility.supportedFileExt[.audio]!.contains(filePathURL.pathExtension)) {
        tableView.setDropRow(player.info.audioTracks.count + 1, dropOperation: NSTableView.DropOperation.above)
        return .copy
      }
    }

    return [] // NSDragOperationNone
  }

  func tableView(_ tableView: NSTableView,
                 acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
    if (tableView == subTableView || tableView == secSubTableView) {

      let pb = info.draggingPasteboard
      let classes = [ NSURL.self ]
      guard let filePathURL = (pb.readObjects(forClasses: classes, options: nil)?.first as? NSURL)?.filePathURL else {
        return false
      }

      if let track = player.info.subTracks.first(where: { (track) -> Bool in
        track.externalFilename == filePathURL.path
      }) {
        tableView.scrollRowToVisible(row)
        if tableView == subTableView {
          if track.id == player.info.secondSid {
            player.setTrack(0, forType: .secondSub)
          }
          player.setTrack(track.id, forType: .sub)
        } else if tableView == secSubTableView {
          if track.id == player.info.sid {
            player.setTrack(0, forType: .sub)
          }
          player.setTrack(track.id, forType: .secondSub)
        }
        return true
      }

      player.loadExternalSubFile(filePathURL, delay: true)
      subTableView.reloadData()
      secSubTableView.reloadData()

      DispatchQueue.main.async {
        tableView.scrollRowToVisible(row)
      }
      return true

    } else if (tableView == audioTableView) {

      let pb = info.draggingPasteboard
      let classes = [ NSURL.self ]
      guard let filePathURL = (pb.readObjects(forClasses: classes, options: nil)?.first as? NSURL)?.filePathURL else {
        return false
      }

      if let track = player.info.audioTracks.first(where: { (track) -> Bool in
        track.externalFilename == filePathURL.path
      }) {
        tableView.scrollRowToVisible(row)
        player.setTrack(track.id, forType: .audio)
        return true
      }

      player.loadExternalAudioFile(filePathURL)
      audioTableView.reloadData()

      DispatchQueue.main.async {
        tableView.scrollRowToVisible(row)
      }

      return true
    }

    return false
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    let originatingTableView = notification.object as! NSTableView
    withAllTableViews { (tableView, type) in
      guard originatingTableView === tableView else { return }
      player.log.verbose("Selection changed for table \(type.rawValue.quoted)")

      if tableView.numberOfSelectedRows > 0 {
        var trackID = 0  // default
        if tableView.selectedRow > 0 {
          // note that track ids start from 1
          let trackIndex = tableView.selectedRow - 1
          let trackList = player.info.trackList(type)
          if trackIndex < trackList.count {
            trackID = trackList[trackIndex].id
          }
        }
        // This should fire a callback for the relavant tab, assuming the track actually changed
        player.setTrack(trackID, forType: type)
        tableView.deselectAll(self)
      }
    }
  }

  private func withAllTableViews(_ block: (NSTableView, MPVTrack.TrackType) -> Void) {
    block(audioTableView, .audio)
    block(subTableView, .sub)
    block(secSubTableView, .secondSub)
    block(videoTableView, .video)
  }

  // MARK: - Actions

  // MARK: Tab buttons

  @IBAction func tabBtnAction(_ sender: NSButton) {
    let tab: Sidebar.Tab
    let buttonTag = sender.tag
    switch buttonTag {
    case 0:
      tab = .video
    case 1:
      tab = .audio
    case 2:
      tab = .sub
    default:
      player.log.error("QuickSettings: Invalid button tag: \(sender.tag)")
      return
    }
    switchToTab(tab)
  }

  // MARK: Video tab

  @IBAction func aspectChangedAction(_ sender: NSSegmentedControl) {
    guard let aspect = sender.label(forSegment: sender.selectedSegment) else {
      player.log.error("Bad aspect segment: \(sender.selectedSegment)")
      return
    }
    player.log.verbose("Setting aspect from segmented control: \(aspect.quoted)")
    startRefreshDenialPeriod()

    player.mpv.queue.async { [self] in
      player.setVideoAspectOverride(aspect)
    }
  }

  @IBAction func cropChangedAction(_ sender: NSSegmentedControl) {
    player.log.verbose("QuickSettings cropChangedAction entered")
    if sender.selectedSegment == sender.segmentCount - 1 {
      // User clicked on "Custom...": show custom crop UI
      pwc.enterInteractiveMode(.crop)
    } else {
      guard let selectedCropString = sender.label(forSegment: sender.selectedSegment) else {
        player.log.error("Bad crop segment: \(sender.selectedSegment)")
        return
      }

      player.log.verbose("Setting crop from segmented control: \(selectedCropString.quoted)")
      startRefreshDenialPeriod()
      player.setCrop(fromLabel: selectedCropString)
    }
  }

  // Sets mpv's `MPVOption.Video.videoRotate` property if it is one of the 4 `AppData.rotations` values
  @IBAction func rotationChangedAction(_ sender: NSSegmentedControl) {
    startRefreshDenialPeriod()
    let value = AppData.rotations[sender.selectedSegment]
    player.setVideoRotate(value)
  }

  @IBAction func customAspectEditFinishedAction(_ sender: AnyObject?) {
    let aspectString = customAspectTextField.stringValue
    guard aspectString != "" else { return }
    player.log.verbose("Setting aspect from text field: \(aspectString.quoted)")
    player.mpv.queue.async { [self] in
      player.setVideoAspectOverride(aspectString)
    }
  }

  @IBAction func hardwareDecodingAction(_ sender: NSSwitch) {
    player.toggleHardwareDecoding(sender.state == .on)
  }

  @IBAction func deinterlaceAction(_ sender: NSSwitch) {
    player.toggleDeinterlace(sender.state == .on)
  }

  @IBAction func hdrAction(_ sender: NSSwitch) {
    self.player.info.hdrEnabled = sender.state == .on
    player.refreshEdrMode()
  }

  private func redraw(indicator: NSTextField, constraint: NSLayoutConstraint, slider: NSSlider, value: String) {
    indicator.stringValue = value
    let offset: CGFloat = 6
    let sliderInnerWidth = slider.frame.width - offset * 2
    constraint.constant = offset + sliderInnerWidth * CGFloat((slider.doubleValue - slider.minValue) / (slider.maxValue - slider.minValue))
    view.layout()
  }

  @IBAction func resetSpeedAction(_ sender: AnyObject) {
    updateSpeed(to: 1.0)
  }

  @IBAction func speedChangedAction(_ sender: NSSlider) {
    // Each step is 64^(1/24)
    //   0       1   ..    7      8      9   ..   24
    // 0.250x 0.297x .. 0.841x 1.000x 1.189x .. 16.00x
    let eventType = NSApp.currentEvent!.type
    if eventType == .leftMouseDown {
      sender.allowsTickMarkValuesOnly = true
    }
    if eventType == .leftMouseUp {
      sender.allowsTickMarkValuesOnly = false
    }
    let sliderValue = sender.doubleValue
    // Attempt to round speed to 2 decimal places. If user is using the slider, any more
    // precision than that is just a distraction
    let newSpeed = (AppData.minSpeed * pow(AppData.maxSpeed / AppData.minSpeed, sliderValue / speedSliderStepCount)).roundedTo2()
    player.log.verbose("Speed slider changed to \(sliderValue) → newSpeed = \(newSpeed)")
    updateSpeed(to: newSpeed)
  }

  @IBAction func customSpeedEditFinishedAction(_ sender: NSTextField) {
    if sender.stringValue.isEmpty {
      sender.stringValue = "1"
    }

    player.log.verbose("Speed text field changed to: \(sender.stringValue)")
    /// Unfortunately, the text field has not applied validation/formatting to the number at this point.
    /// We will do that manually via `constrainSpeed`.
    updateSpeed(to: sender.doubleValue)
  }

  /// Ensure that the given `Double` is a speed which is valid for mpv.
  ///
  /// - This is necessary because libmpv cannot be relied on to report the correct number & will reply
  /// with a property change event which echoes the number which was submitted, even if it is not the
  /// same as the number which mpv is actually using (it will internally round the number to 6 digits
  /// after the decimal but tell us that it used the non-rounded number).
  /// - `NumberFormatter` doesn't provide APIs to validate or correct an `NSNumber`.
  /// But we can get the same effect by converting to a `String` and back again.
  private func constrainSpeed(_ inputSpeed: Double) -> Double {
    let newSpeedString: String = speedFormatter.string(from: inputSpeed as NSNumber) ?? "1"
    return Double(truncating: speedFormatter.number(from: newSpeedString)!)
  }

  private func updateSpeed(to inputSpeed: Double) {
    let newSpeed = constrainSpeed(inputSpeed)
    updateSpeedControls(to: newSpeed)
    if player.info.playSpeed != newSpeed {
      player.setSpeed(newSpeed)
    }
  }

  @IBAction func equalizerSliderAction(_ sender: NSSlider) {
    let type: PlayerCore.VideoEqualizerType
    switch sender {
    case brightnessSlider:
      type = .brightness
    case contrastSlider:
      type = .contrast
    case saturationSlider:
      type = .saturation
    case gammaSlider:
      type = .gamma
    case hueSlider:
      type = .hue
    default:
      return
    }
    player.setVideoEqualizer(forOption: type, value: Int(sender.intValue))
  }

  // use tag for buttons
  @IBAction func resetEqualizerBtnAction(_ sender: NSButton) {
    let type: PlayerCore.VideoEqualizerType
    let slider: NSSlider?
    switch sender.tag {
    case 0:
      type = .brightness
      slider = brightnessSlider
    case 1:
      type = .contrast
      slider = contrastSlider
    case 2:
      type = .saturation
      slider = saturationSlider
    case 3:
      type = .gamma
      slider = gammaSlider
    case 4:
      type = .hue
      slider = hueSlider
    default:
      return
    }
    player.setVideoEqualizer(forOption: type, value: 0)
    slider?.intValue = 0
  }

  // MARK: Audio tab

  @IBAction func loadExternalAudioAction(_ sender: NSButton) {
    let currentDir = player.info.currentURL?.deletingLastPathComponent()
    Utility.quickOpenPanel(
      title: "Load external audio file",
      chooseDir: false,
      dir: currentDir,
      sheetWindow: player.window,
      allowedFileTypes: Utility.playableFileExt
    ) { url in
      self.player.loadExternalAudioFile(url)
      self.audioTableView.reloadData()
    }
  }

  @IBAction func audioDelayChangedAction(_ sender: NSSlider) {
    let eventType = NSApp.currentEvent!.type
    let sliderValue: Double
    switch eventType {
    case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
      // When dragging slider with the mouse, snap to the nearest 50ms (1/20 sec)
      // Although it is possible to show tick marks at every step of 0.05 in the slider, it is visually unpleasant.
      // So we draw less tick marks, and keep "Only stop on tick marks" disabled, and add our own logic to stop on
      // "virtual tick marks" for these values.
      sliderValue = (sender.doubleValue * 20.0).rounded() / 20.0
      sender.doubleValue = sliderValue
    default:
      sliderValue = sender.doubleValue
    }
    // Use Decimal to avoid negative zero ("-0")
    customAudioDelayTextField.stringValue = "\(Decimal(sliderValue))"
    audioDelayResetBtn.isHidden = sliderValue == 0.0
    redraw(indicator: audioDelaySliderIndicator, constraint: audioDelaySliderConstraint, slider: audioDelaySlider, value: "\(sliderValue)s")
    if let event = NSApp.currentEvent {
      if event.type == .leftMouseUp {
        player.setAudioDelay(sliderValue)
      }
    }
  }

  @IBAction func resetAudioDelayAction(_ sender: AnyObject) {
    player.setAudioDelay(0.0)
  }

  @IBAction func customAudioDelayEditFinishedAction(_ sender: NSTextField) {
    if sender.stringValue.isEmpty {
      sender.stringValue = "0"
    }
    let value = sender.doubleValue
    player.setAudioDelay(value)
    audioDelaySlider.doubleValue = value
    redraw(indicator: audioDelaySliderIndicator, constraint: audioDelaySliderConstraint, slider: audioDelaySlider, value: "\(sender.stringValue)s")
  }

  private func applyEQ(_ profile: EQProfile) {
    zip(audioEQSliders, profile.gains).forEach { (slider, gain) in
      slider.doubleValue = gain
    }
    player.setAudioEq(fromGains: profile.gains)
  }

  private func findProfileFromSliders() -> (String, EQProfile)? {
    player.log.trace("EQ Sliders: \(audioEQSliders.map{String($0.doubleValue.truncatedTo1())}.joined(separator: " "))")
    for presetProfile in presetEQs {
      if matchesSliders(presetProfile.name, presetProfile) {
        return (presetProfile.name, presetProfile)
      }
    }

    for (name, userProfile) in userEQs {
      if matchesSliders(name, userProfile) {
        return (name, userProfile)
      }
    }

    return nil
  }

  private func matchesSliders(_ profileName: String, _ profile: EQProfile) -> Bool {
    for (slider, gain) in zip(audioEQSliders, profile.gains) {
      player.log.trace("Matching EQ profile \(profileName.quoted): \(gain.roundedTo2()) v \(slider.doubleValue.roundedTo2())")
      if slider.doubleValue.roundedTo2() != gain.roundedTo2() {
        return false
      }
    }
    return true
  }

  @IBAction func resetAudioEqAction(_ sender: AnyObject) {
    player.removeAudioEqFilter()
    updateAudioEqState()
  }

  @IBAction func audioEqSliderAction(_ sender: NSSlider) {
    player.setAudioEq(fromGains: audioEQSliders.map { $0.doubleValue })
    updateAudioEqState()
  }

  private func refreshAudioEqResetButton() {
    var isAllDefault = true
    for audioEqSlider in audioEQSliders {
      if audioEqSlider.doubleValue != 0.0 {
        isAllDefault = false
      }
    }
    audioEQResetBtn.isHidden = isAllDefault
  }

  // MARK: Sub tab

  @IBAction func hideSubAction(_ sender: NSSwitch) {
    player.toggleSubVisibility()
  }

  @IBAction func hideSecSubAction(_ sender: NSSwitch) {
    player.toggleSecondSubVisibility()
  }

  @IBAction func loadExternalSubAction(_ sender: NSSegmentedControl) {
    if sender.selectedSegment == 0 {
      let currentDir = player.info.currentURL?.deletingLastPathComponent()
      // In addition to subtitle files allow the user to choose video files as mpv will look for
      // and load embedded subtitle streams in the video file.
      Utility.quickOpenPanel(title: "Load external subtitle", chooseDir: false, dir: currentDir,
                             sheetWindow: player.window,
                             allowedFileTypes: Utility.containsSubExt) { url in
        // set a delay
        self.player.loadExternalSubFile(url, delay: true)
        self.subTableView.reloadData()
        self.secSubTableView.reloadData()
      }
    } else if sender.selectedSegment == 1 {
      showSubChooseMenu(forView: sender)
    }
  }

  func showSubChooseMenu(forView view: NSView, showLoadedSubs: Bool = false) {
    let activeSubs = player.info.trackList(.sub) + player.info.trackList(.secondSub)
    let menu = NSMenu()
    menu.autoenablesItems = false
    // loaded subtitles
    if showLoadedSubs {
      if player.info.subTracks.isEmpty {
        menu.addItem(withTitle: NSLocalizedString("subtrack.no_loaded", comment: "No subtitles loaded"), enabled: false)
      } else {
        menu.addItem(withTitle: NSLocalizedString("track.none", comment: "<None>"),
                     action: #selector(self.chosenSubFromMenu(_:)), target: self,
                     stateOn: player.info.sid == 0 ? true : false)

        for sub in player.info.subTracks {
          menu.addItem(withTitle: sub.readableTitle,
                       action: #selector(self.chosenSubFromMenu(_:)),
                       target: self,
                       obj: sub,
                       stateOn: sub.id == player.info.sid ? true : false)
        }
      }
      menu.addItem(NSMenuItem.separator())
    }
    // external subtitles
    let addMenuItem = { (sub: FileInfo) -> Void in
      let isActive = !showLoadedSubs && activeSubs.contains { $0.externalFilename == sub.path }
      menu.addItem(withTitle: "\(sub.filename).\(sub.ext)",
                   action: #selector(self.chosenSubFromMenu(_:)),
                   target: self,
                   obj: sub,
                   stateOn: isActive ? true : false)

    }
    if player.info.currentSubsInfo.isEmpty {
      menu.addItem(withTitle: NSLocalizedString("subtrack.no_external", comment: "No external subtitles found"),
                   enabled: false)
    } else {
      if let videoInfo = player.info.currentVideosInfo.first(where: { $0.url == player.info.currentURL }),
        !videoInfo.relatedSubs.isEmpty {
        videoInfo.relatedSubs.forEach(addMenuItem)
        menu.addItem(NSMenuItem.separator())
      }
      player.info.currentSubsInfo.sorted { (f1, f2) in
        return f1.filename.localizedStandardCompare(f2.filename) == .orderedAscending
      }.forEach(addMenuItem)
    }
    NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: view)
  }

  @objc func chosenSubFromMenu(_ sender: NSMenuItem) {
    if let fileInfo = sender.representedObject as? FileInfo {
      player.loadExternalSubFile(fileInfo.url)
    } else if let sub = sender.representedObject as? MPVTrack {
      player.setTrack(sub.id, forType: .sub)
    } else {
      player.setTrack(0, forType: .sub)
    }
  }

  @IBAction func searchOnlineAction(_ sender: AnyObject) {
    pwc.menuFindOnlineSub(self)
  }

  @IBAction func subSegmentedControlAction(_ sender: NSSegmentedControl) {
    isShowingPrimarySubPanel = sender.selectedSegment == 0
    DispatchQueue.main.async { [self] in
      updateSubTabControls()
    }
  }

  @IBAction func subDelayChangedAction(_ sender: NSSlider) {
    let eventType = NSApp.currentEvent!.type
    if eventType == .leftMouseDown {
      sender.allowsTickMarkValuesOnly = true
    }
    if eventType == .leftMouseUp {
      sender.allowsTickMarkValuesOnly = false
    }
    let sliderValue = sender.doubleValue
    customSubDelayTextField.doubleValue = sliderValue
    redraw(indicator: subDelaySliderIndicator, constraint: subDelaySliderConstraint, slider: subDelaySlider, value: "\(customSubDelayTextField.stringValue)s")
    subDelayResetBtn.isHidden = sliderValue == 0.0
    if let event = NSApp.currentEvent {
      if event.type == .leftMouseUp {
        player.setSubDelay(sliderValue, forPrimary: isShowingPrimarySubPanel)
      }
    }
  }

  @IBAction func resetSubDelayAction(_ sender: AnyObject) {
    player.setSubDelay(0.0, forPrimary: isShowingPrimarySubPanel)
  }

  @IBAction func customSubDelayEditFinishedAction(_ sender: NSTextField) {
    if sender.stringValue.isEmpty {
      sender.stringValue = "0"
    }
    let value = sender.doubleValue
    player.setSubDelay(value, forPrimary: isShowingPrimarySubPanel)
    subDelaySlider.doubleValue = value
    redraw(indicator: subDelaySliderIndicator, constraint: subDelaySliderConstraint, slider: subDelaySlider, value: "\(sender.stringValue)s")
  }

  @IBAction func subScaleReset(_ sender: AnyObject) {
    player.setSubScale(1)
    subScaleSlider.doubleValue = 0
  }

  @IBAction func subPosSliderAction(_ sender: NSSlider) {
    player.setSubPos(Int(sender.intValue), forPrimary: isShowingPrimarySubPanel)
  }

  @IBAction func subScaleSliderAction(_ sender: NSSlider) {
    let value = sender.doubleValue
    let mappedValue: Double, realValue: Double
    // map [-10, -1], [1, 10] to [-9, 9], bounds may change in future
    if value > 0 {
      mappedValue = round((value + 1) * 20) / 20
      realValue = mappedValue
    } else {
      mappedValue = round((value - 1) * 20) / 20
      realValue = 1 / abs(mappedValue)
    }
    player.setSubScale(realValue)
  }

  @objc func subTextColorAction(_ sender: AnyObject) {
    player.setSubTextColor(subTextColorWell.color.mpvColorString)
  }

  @IBAction func subTextSizeAction(_ sender: AnyObject) {
    if let selectedItem = subTextSizePopUp.selectedItem, let value = Double(selectedItem.title) {
      player.setSubTextSize(value)
    }
  }

  @objc func subTextBorderColorAction(_ sender: AnyObject) {
    player.setSubTextBorderColor(subTextBorderColorWell.color.mpvColorString)
  }

  @IBAction func subTextBorderWidthAction(_ sender: AnyObject) {
    if let selectedItem = subTextBorderWidthPopUp.selectedItem, let value = Double(selectedItem.title) {
      player.setSubTextBorderSize(value)
    }
  }

  @objc func subTextBgColorAction(_ sender: AnyObject) {
    player.setSubTextBgColor(subTextBgColorWell.color.mpvColorString)
  }

  @IBAction func subFontAction(_ sender: AnyObject) {
    player.chooseSubFont()
  }

}

// MARK: - Audio Equalizer

extension QuickSettingViewController {

  private func updateAudioEqState() {
    // EQ filter (if there is one) -> sliders
    if let filter = player.info.audioEqFilter {
      if let arrayOfParamDictDicts = filter.lavfiParse() {
        for (paramDictDict, slider) in zip(arrayOfParamDictDicts, audioEQSliders) {
          if let paramDict = paramDictDict["equalizer"], let gain = paramDict["g"] {
            slider.doubleValue = Double(gain) ?? 0
          } else {
            slider.doubleValue = 0
          }
        }
      } else {
        player.log.error("Failed to parse audio EQ filter: \(filter.stringFormat.quoted)")
      }
    } else {  // No filter
      audioEQSliders.forEach { $0.doubleValue = 0 }
    }
    eqPopUpButton.selectItem(withTag: eqCustomMenuItemTag)
    refreshAudioEqResetButton()

    // Update menu
    updateEQPopupMenu()
  }

  /// Do not call this. Call `updateAudioEqState` instead.
  private func updateEQPopupMenu() {
    guard let menu = eqPopUpButton.menu else { return }

    // Rebuild items for user presets
    var items = menu.items
    items.removeAll { $0.tag == eqUserDefinedProfileMenuItemTag }
    eqPopUpButton.itemArray.forEach { $0.state = .off }
    if !userEQs.isEmpty {
      items.append(NSMenuItem.separator())
      userEQs.forEach { (name, eq) in
        items.append(menu.addItem(withTitle: name, tag: eqUserDefinedProfileMenuItemTag))
      }
    }
    menu.items = items

    // Find & select the current preset in popup which matches the current slider values.
    if let (profileName, profile) = findProfileFromSliders() {
      // Select the first item which matches.
      // Match against user presets before built-in presets. In case of exact match (though rare), the user can choose to remove it.
      if let item = findItem(profileName, eqUserDefinedProfileMenuItemTag) {
        eqPopUpButton.select(item)
      } else if profile is PresetEQProfile, let item = findItem(profileName, eqPresetProfileMenuItemTag) {
        eqPopUpButton.select(item)
      }
      lastUsedProfileName = profileName
      // Gray out "manual" option. Selecting it wouldn't do anything anyway
      setEnabledState(ofItemWithTag: eqCustomMenuItemTag, in: menu, to: false)
    } else {
      // Fall back to "manual" item if no match
      setEnabledState(ofItemWithTag: eqCustomMenuItemTag, in: menu, to: true)
      eqPopUpButton.selectItem(withTag: eqCustomMenuItemTag)
      lastUsedProfileName = ""
    }
    eqPopUpButton.selectedItem?.state = .on

    // Update enablement

    let selectedItemTag = eqPopUpButton.selectedTag()

    let enableSave = selectedItemTag == eqCustomMenuItemTag
    setEnabledState(ofItemWithTag: eqSaveMenuItemTag, in: menu, to: enableSave)

    let enableEdit = selectedItemTag == eqUserDefinedProfileMenuItemTag
    setEnabledState(ofItemWithTag: eqRenameMenuItemTag, in: menu, to: enableEdit)
    setEnabledState(ofItemWithTag: eqDeleteMenuItemTag, in: menu, to: enableEdit)
  }

  private func setEnabledState(ofItemWithTag tag: Int, in menu: NSMenu, to newValue: Bool) {
    let saveItem = menu.item(withTag: tag)
    saveItem?.isEnabled = newValue
  }

  private func promptAudioEQProfileName(isNewProfile: Bool) -> String? {
    let key = isNewProfile ? "eq.new_profile" : "eq.rename"
    let nameList = eqPopUpButton.itemArray
      .filter{ $0.tag == eqPresetProfileMenuItemTag || $0.tag == eqUserDefinedProfileMenuItemTag }
      .map{ $0.title }
    let validator: Utility.InputValidator<String> = { input in
      if input.isEmpty {
        return .valueIsEmpty
      }
      if nameList.contains( where: { $0 == input } ) {
        return .valueAlreadyExists
      } else {
        return .ok
      }
    }
    var inputString: String?
    Utility.quickPromptPanel(key, validator: validator, callback: { inputString = $0 })
    return inputString
  }

  /// Find item in audio EQ popup menu which matches both name & tag
  private func findItem(_ name: String, _ tag: Int = eqUserDefinedProfileMenuItemTag) -> NSMenuItem? {
    return eqPopUpButton.itemArray.filter{ $0.tag == tag }.first { $0.title == name }
  }

  /// Is called when any item in `eqPopUpButton`'s menu is chosen by the user
  @IBAction func eqPopUpButtonAction(_ sender: NSPopUpButton) {
    let tag = sender.selectedTag()
    let name = sender.titleOfSelectedItem
    let representedObject = sender.selectedItem?.representedObject as? String
    switch tag {
    case eqSaveMenuItemTag:
      if let inputString = promptAudioEQProfileName(isNewProfile: true) {
        let newProfile = EQProfile(fromCurrentSliders: audioEQSliders)
        userEQs[inputString] = newProfile
      }
    case eqRenameMenuItemTag:
      if let inputString = promptAudioEQProfileName(isNewProfile: false) {
        if let profile = userEQs.removeValue(forKey: lastUsedProfileName) {
          userEQs[inputString] = profile
        }
      }
    case eqDeleteMenuItemTag:
      userEQs.removeValue(forKey: lastUsedProfileName)
    case eqCustomMenuItemTag:
      break
    case eqPresetProfileMenuItemTag:
      guard let preset = presetEQs.first(where: { $0.localizationKey == representedObject }) else { break }
      applyEQ(preset)
    default: // user defined EQ Profiles
      guard let pair = userEQs.first(where: { $0.0 == name }) else { break }
      applyEQ(pair.1)
    }

    updateAudioEqState()
  }
}
