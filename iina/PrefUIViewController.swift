//
//  PrefUIViewController.swift
//  iina
//
//  Created by lhc on 25/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

fileprivate let SizeWidthTag = 0
fileprivate let SizeHeightTag = 1
fileprivate let UnitPointTag = 0
fileprivate let UnitPercentTag = 1
fileprivate let SideLeftTag = 0
fileprivate let SideRightTag = 1
fileprivate let SideTopTag = 0
fileprivate let SideBottomTag = 1
fileprivate let maxToolbarPreviewSingleRowBarHeight: CGFloat = 52

/// KVC doesn't support Bool natively and it's too hard to figure out how to interpret as char*.
/// Just use a dummy object instead and interpret via NSIsNil transformer.
/// - `nil`: `false`
/// - non-`nil`: `true`
fileprivate func boolToObjectKludge(_ value: Bool) -> NSNumber? {
  return value ? NSNumber(value: 1) : nil
}

/// If `useMpvOsd` is enabled, we want to disable the OSD section.
fileprivate func isUsingMpvOSD() -> Bool {
  Preference.bool(for: .enableAdvancedSettings) && Preference.bool(for: .useMpvOsd)
}

fileprivate func isUsingThumbfastIntegration() -> Bool {
  Preference.bool(for: .enableAdvancedSettings) && Preference.bool(for: .integrateWithThumbfast)
}

@objcMembers
class PrefUIViewController: PreferenceViewController, PreferenceWindowEmbeddable {
  private var lastAppliedGeo = ControlBarGeometry(mode: .windowedNormal) {
    didSet {
      Logger.log.verbose("PrefUIViewController.lastAppliedGeo was updated")
    }
  }

  /// See `isUsingMpvOSD()`
  @objc dynamic var usingMpvOSD: NSNumber? = nil

  /// See `isUsingThumbfastIntegration()`
  @objc dynamic var usingThumbfast: NSNumber? = nil

  override var nibName: NSNib.Name {
    return NSNib.Name("PrefUIViewController")
  }

  var preferenceTabTitle: String {
    return NSLocalizedString("preference.ui", comment: "UI")
  }

  var preferenceTabImage: NSImage {
    return makeSymbol("macwindow", fallbackImage: "pref_ui")
  }

  static var oscToolbarButtons: [Preference.ToolBarButton] {
    return (Preference.array(for: .controlBarToolbarButtons) as? [Int] ?? []).compactMap(Preference.ToolBarButton.init(rawValue:))
  }

  override var sectionViews: [NSView] {
    return [sectionWindowView, sectionFullScreenView, sectionAppearanceView, sectionOSCView, sectionSidebarsView, sectionOSDView,
            sectionThumbnailView, sectionPictureInPictureView, sectionAccessibilityView]
  }

  var notiHandler: NotificationHandler! = nil

  private let toolbarSettingsSheetController = PrefOSCToolbarSettingsSheetController()

  private var oscToolbarStackViewHeightConstraint: NSLayoutConstraint!
  private var oscToolbarStackViewWidthConstraint: NSLayoutConstraint!

  @IBOutlet weak var toolIconSizeSlider: NSSlider!
  @IBOutlet weak var toolIconSpacingSlider: NSSlider!
  @IBOutlet weak var playIconSizeSlider: NSSlider!
  @IBOutlet weak var playIconSpacingSlider: NSSlider!

  @IBOutlet weak var aspectPresetsTokenField: AspectTokenField!
  @IBOutlet weak var cropPresetsTokenField: AspectTokenField!

  @IBOutlet weak var resetAspectPresetsButton: NSButton!
  @IBOutlet weak var resetCropPresetsButton: NSButton!
  @IBOutlet weak var usePressureForArrowsButton: NSButton!

  @IBOutlet var sectionAppearanceView: NSView!
  @IBOutlet var sectionFullScreenView: NSView!
  @IBOutlet var sectionWindowView: NSView!
  @IBOutlet var sectionOSCView: NSView!
  @IBOutlet var sectionOSDView: NSView!
  @IBOutlet var sectionSidebarsView: NSView!
  @IBOutlet var sectionThumbnailView: NSView!
  @IBOutlet var sectionPictureInPictureView: NSView!
  @IBOutlet var sectionAccessibilityView: NSView!

  @IBOutlet weak var themeMenu: NSMenu!
  @IBOutlet weak var topBarPositionContainerView: NSView!
  @IBOutlet weak var showTopBarTriggerContainerView: NSView!
  @IBOutlet weak var windowPreviewImageView: NSImageView!
  @IBOutlet weak var arrowButtonActionPopUpButton: NSPopUpButton!
  @IBOutlet weak var oscBottomPlacementContainerView: NSView!
  @IBOutlet weak var oscSnapToCenterContainerView: NSView!
  @IBOutlet weak var oscWidthStackView: NSStackView!
  @IBOutlet weak var oscHeightStackView: NSStackView!
  @IBOutlet weak var oscBarHeightTextField: NSTextField!
  @IBOutlet weak var playbackBtnDimensionsHStackView: NSStackView!
  @IBOutlet weak var toolbarSectionVStackView: NSStackView!
  @IBOutlet weak var toolbarIconDimensionsHStackView: NSStackView!
  @IBOutlet weak var oscToolbarStackView: NSStackView!
  @IBOutlet weak var oscToolbarPreviewBox: NSBox!

  @IBOutlet weak var oscTimeLabelsAlwaysWrapSliderStackView: NSStackView!

  @IBOutlet weak var autoHideAfterCheckBox: NSButton!
  @IBOutlet weak var oscAutoHideTimeoutTextField: NSTextField!
  @IBOutlet weak var hideFadeableViewsOutsideWindowCheckBox: NSButton!
  @IBOutlet weak var keepVideoAwayFromBarsCheckBox: NSButton!

  @IBOutlet weak var oscColorSchemeHStackView: NSStackView!
  @IBOutlet weak var oscForceSingleRowContainerView: NSStackView!

  @IBOutlet weak var leftSidebarLabel: NSTextField!
  @IBOutlet weak var leftSidebarPlacement: NSSegmentedControl!
  @IBOutlet weak var leftSidebarSettingsTabsRadioButton: NSButton!
  @IBOutlet weak var rightSidebarSettingsTabsRadioButton: NSButton!
  @IBOutlet weak var leftSidebarPlaylistTabsRadioButton: NSButton!
  @IBOutlet weak var rightSidebarPlaylistTabsRadioButton: NSButton!
  @IBOutlet weak var leftSidebarPluginTabsRadioButton: NSButton!
  @IBOutlet weak var rightSidebarPluginTabsRadioButton: NSButton!
  @IBOutlet weak var leftSidebarShowToggleButton: NSButton!
  @IBOutlet weak var leftSidebarClickToCloseButton: NSButton!
  @IBOutlet weak var rightSidebarLabel: NSTextField!
  @IBOutlet weak var rightSidebarPlacement: NSSegmentedControl!
  @IBOutlet weak var rightSidebarShowToggleButton: NSButton!
  @IBOutlet weak var rightSidebarClickToCloseButton: NSButton!

  @IBOutlet weak var resizeWindowWhenOpeningFileCheckbox: NSButton!
  @IBOutlet weak var resizeWindowTimingPopUpButton: NSPopUpButton!
  @IBOutlet weak var unparsedGeometryLabel: NSTextField!
  @IBOutlet weak var mpvWindowSizeCollapseView: CollapseView!
  @IBOutlet weak var mpvWindowPositionCollapseView: CollapseView!
  @IBOutlet weak var windowSizeCheckBox: NSButton!
  @IBOutlet weak var simpleVideoSizeRadioButton: NSButton!
  @IBOutlet weak var mpvGeometryRadioButton: NSButton!
  @IBOutlet weak var spacer0: NSView!
  @IBOutlet weak var windowSizeTypePopUpButton: NSPopUpButton!
  @IBOutlet weak var windowSizeValueTextField: NSTextField!
  @IBOutlet weak var windowSizeUnitPopUpButton: NSPopUpButton!
  @IBOutlet weak var windowSizeBox: NSBox!
  @IBOutlet weak var windowPosCheckBox: NSButton!
  @IBOutlet weak var windowPosXOffsetTextField: NSTextField!
  @IBOutlet weak var windowPosXUnitPopUpButton: NSPopUpButton!
  @IBOutlet weak var windowPosXAnchorPopUpButton: NSPopUpButton!
  @IBOutlet weak var windowPosYOffsetTextField: NSTextField!
  @IBOutlet weak var windowPosYUnitPopUpButton: NSPopUpButton!
  @IBOutlet weak var windowPosYAnchorPopUpButton: NSPopUpButton!
  @IBOutlet weak var windowPosBox: NSBox!

  @IBOutlet weak var seekPreviewWhiteShadowCheckbox: NSButton!
  @IBOutlet weak var currentThumbCacheSizeTextField: NSTextField!

  @IBOutlet weak var pipDoNothing: NSButton!
  @IBOutlet weak var pipHideWindow: NSButton!
  @IBOutlet weak var pipMinimizeWindow: NSButton!

  /// Weak reference to `PreferenceWindowController.animationPipeline`.
  private unowned var animationPipeline: IINAAnimation.Pipeline!

  // MARK: Init

  override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
    super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    animationPipeline = AppDelegate.shared.preferenceWindowController.animationPipeline

    for sectionView in sectionViews {
      // helps with show/hide animations
      sectionView.clipsToBounds = true
    }

    configureObservers()

    // Init with dummy values for now
    let hConstraint = oscToolbarStackView.heightAnchor.constraint(equalToConstant: maxToolbarPreviewSingleRowBarHeight)
    hConstraint.priority = .defaultHigh  // avoid conflicting constraints
    hConstraint.isActive = true
    oscToolbarStackViewHeightConstraint = hConstraint

    let wConstraint = oscToolbarStackView.widthAnchor.constraint(equalToConstant: 0)
    wConstraint.priority = .defaultHigh  // avoid conflicting constraints
    wConstraint.isActive = true
    oscToolbarStackViewWidthConstraint = wConstraint

    IINAAnimation.disableAnimation {
      // Initial update: do now to prevent unexpected animations during restore
      updateAllSectionsFromPrefs()
    }
  }

  override func viewWillAppear() {
    super.viewWillAppear()

    notiHandler.addAllObservers()
    // Set up key-value observing for changes to this view's properties:
    addObserver(self, forKeyPath: #keyPath(view.effectiveAppearance), options: [.old, .new], context: nil)

    animationPipeline.submitInstantTask{ [self] in
      updateAllSectionsFromPrefs()
    }
  }

  override func viewWillDisappear() {
    notiHandler.removeAllObservers()
    ObjcUtils.silenced {
      UserDefaults.standard.removeObserver(self, forKeyPath: #keyPath(view.effectiveAppearance))
    }
  }

  // MARK: Observers

  private func configureObservers() {
    notiHandler = NotificationHandler(Logger.log, prefDidChange: prefDidChange, [
      .enableAdvancedSettings,
      .useMpvOsd,
      .integrateWithThumbfast,
      .showTopBarTrigger,
      .topBarPlacement,
      .bottomBarPlacement,
      .enableOSC,
      .oscPosition,
      .oscColorScheme,
      .oscForceSingleRow,
      .themeMaterial,
      .settingsTabGroupLocation,
      .playlistTabGroupLocation,
      .pluginsTabGroupLocation,
      .controlBarToolbarButtons,
      .lockViewportToVideoSize,
      .oscBarHeight,
      .oscBarPlayIconSizeTicks,
      .oscBarPlayIconSpacingTicks,
      .oscBarToolIconSizeTicks,
      .oscBarToolIconSpacingTicks,
      .arrowButtonAction,
      .useLegacyWindowedMode,
      .aspectRatioPanelPresets,
      .cropPanelPresets,
      .enableThumbnailPreview,
      .thumbnailBorderStyle,
    ])
  }

  /// Called each time a pref `key`'s value is set
  func prefDidChange(_ key: Preference.Key, _ newValue: Any?) {
    switch key {
    case PK.aspectRatioPanelPresets:
      updateAspectControlsFromPrefs()
    case PK.cropPanelPresets:
      updateCropControlsFromPrefs()
    case PK.showTopBarTrigger,
      PK.arrowButtonAction,
      PK.enableOSC,
      PK.topBarPlacement,
      PK.bottomBarPlacement,
      PK.oscPosition,
      PK.useLegacyWindowedMode,
      PK.themeMaterial,
      PK.enableAdvancedSettings:

      usingMpvOSD = boolToObjectKludge(isUsingMpvOSD())
      usingThumbfast = boolToObjectKludge(isUsingThumbfastIntegration())

      // Use animation where possible to make the transition less jarring
      animationPipeline.submitInstantTask{ [self] in
        refreshTitleBarAndOSCSection()
        updateWindowGeometrySectionFromPrefs()
      }
    case .useMpvOsd:
      usingMpvOSD = boolToObjectKludge(isUsingMpvOSD())
    case .integrateWithThumbfast:
      usingThumbfast = boolToObjectKludge(isUsingThumbfastIntegration())
    case PK.settingsTabGroupLocation, PK.playlistTabGroupLocation, PK.pluginsTabGroupLocation:
      updateSidebarSectionFromPrefs()
    case PK.oscBarHeight,
      PK.controlBarToolbarButtons,
      PK.oscForceSingleRow,
      PK.oscColorScheme,
      PK.lockViewportToVideoSize,
      PK.oscBarPlayIconSizeTicks,
      PK.oscBarPlayIconSpacingTicks,
      PK.oscBarToolIconSizeTicks,
      PK.oscBarToolIconSpacingTicks:

      animationPipeline.submitInstantTask{ [self] in
        refreshTitleBarAndOSCSection()
      }
    case .enableThumbnailPreview,
        .thumbnailBorderStyle:
      animationPipeline.submitTask { [self] in
        refreshSeekPreviewShadow()
      }
    default:
      break
    }
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                             change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath = keyPath, let _ = change else { return }

    switch keyPath {
    case #keyPath(view.effectiveAppearance):
      if Preference.enum(for: .themeMaterial) == Preference.Theme.system {
        Task { @MainActor in
          // Refresh image in case dark mode changed
          let ib = PWinPreviewImageBuilder(self.view)
          windowPreviewImageView.image = ib.buildPWinPreviewImage()
        }
      }
    default:
      break
    }
  }

  private func updateAllSectionsFromPrefs() {
    // Update KVC vars
    usingMpvOSD = boolToObjectKludge(isUsingMpvOSD())
    usingThumbfast = boolToObjectKludge(isUsingThumbfastIntegration())

    // Update sliders from prefs:
    let geo = ControlBarGeometry(mode: .windowedNormal)
    updateOSCSliders(from: geo)

    updateSidebarSectionFromPrefs()
    refreshTitleBarAndOSCSection(from: geo)
    _updateWindowGeometrySectionFromPrefs()
    updatePictureInPictureSection()

    reloadThumbnailCacheStat()
    updateAspectControlsFromPrefs()
    updateCropControlsFromPrefs()
  }

  // MARK: - Sidebars

  private func updateSidebarSectionFromPrefs() {
    let settingsTabGroup: Preference.SidebarLocation = Preference.enum(for: .settingsTabGroupLocation)
    let playlistTabGroup: Preference.SidebarLocation = Preference.enum(for: .playlistTabGroupLocation)
    let pluginTabGroup: Preference.SidebarLocation = Preference.enum(for: .pluginsTabGroupLocation)
    let isUsingLeadingSidebar = settingsTabGroup == .leadingSidebar || playlistTabGroup == .leadingSidebar || pluginTabGroup == .leadingSidebar
    let isUsingTrailingSidebar = settingsTabGroup == .trailingSidebar || playlistTabGroup == .trailingSidebar || pluginTabGroup == .trailingSidebar

    leftSidebarSettingsTabsRadioButton.state = (settingsTabGroup == .leadingSidebar) ? .on : .off
    rightSidebarSettingsTabsRadioButton.state = (settingsTabGroup == .trailingSidebar) ? .on : .off

    leftSidebarPlaylistTabsRadioButton.state = (playlistTabGroup == .leadingSidebar) ? .on : .off
    rightSidebarPlaylistTabsRadioButton.state = (playlistTabGroup == .trailingSidebar) ? .on : .off

    leftSidebarPluginTabsRadioButton.state = (pluginTabGroup == .leadingSidebar) ? .on : .off
    rightSidebarPluginTabsRadioButton.state = (pluginTabGroup == .trailingSidebar) ? .on : .off

    leftSidebarPlacement.isEnabled = isUsingLeadingSidebar
    leftSidebarShowToggleButton.isEnabled = isUsingLeadingSidebar
    leftSidebarClickToCloseButton.isEnabled = isUsingLeadingSidebar

    rightSidebarPlacement.isEnabled = isUsingTrailingSidebar
    rightSidebarShowToggleButton.isEnabled = isUsingTrailingSidebar
    rightSidebarClickToCloseButton.isEnabled = isUsingTrailingSidebar
    refreshSeekPreviewShadow()
  }

  func refreshSeekPreviewShadow() {
    let thumbBorderStyle: Preference.ThumnailBorderStyle = Preference.enum(for: .thumbnailBorderStyle)
    seekPreviewWhiteShadowCheckbox.isHidden = !(Preference.bool(for: .enableThumbnailPreview) && !isUsingThumbfastIntegration() && thumbBorderStyle.hasShadow)
    let shadow: Preference.Shadow = Preference.enum(for: .seekPreviewShadow)
    seekPreviewWhiteShadowCheckbox.state = (shadow == .glow) ? .on : .off
  }

  @IBAction func whiteShadowCheckboxAction(_ sender: NSButton) {
    let useWhiteShadow = sender.state == .on
    let shadow: Preference.Shadow = useWhiteShadow ? .glow : .dark
    Preference.set(shadow.rawValue, for: .seekPreviewShadow)
  }

  @IBAction func settingsSidebarTabGroupAction(_ sender: NSButton) {
    Preference.set(sender.tag, for: .settingsTabGroupLocation)
  }

  @IBAction func playlistSidebarTabGroupAction(_ sender: NSButton) {
    Preference.set(sender.tag, for: .playlistTabGroupLocation)
  }

  @IBAction func pluginsSidebarTabGroupAction(_ sender: NSButton) {
    Preference.set(sender.tag, for: .pluginsTabGroupLocation)
  }

  @IBAction func saveAspectPresets(_ sender: AspectTokenField) {
    let csv = sender.commaSeparatedValues
    if Preference.string(for: .aspectRatioPanelPresets) != csv {
      Logger.log("Saving \(Preference.Key.aspectRatioPanelPresets.rawValue): \"\(csv)\"", level: .verbose)
      Preference.set(csv, for: .aspectRatioPanelPresets)
    }
  }

  @IBAction func saveCropPresets(_ sender: AspectTokenField) {
    let csv = sender.commaSeparatedValues
    if Preference.string(for: .cropPanelPresets) != csv {
      Logger.log("Saving \(Preference.Key.cropPanelPresets.rawValue): \"\(csv)\"", level: .verbose)
      Preference.set(csv, for: .cropPanelPresets)
    }
  }

  @IBAction func resetAspectPresets(_ sender: NSButton) {
    let defaultValue = Preference.defaultPreference[.aspectRatioPanelPresets]
    Preference.set(defaultValue, for: .aspectRatioPanelPresets)
  }

  @IBAction func resetCropPresets(_ sender: NSButton) {
    let defaultValue = Preference.defaultPreference[.cropPanelPresets]
    Preference.set(defaultValue, for: .cropPanelPresets)
  }

  private func updateAspectControlsFromPrefs() {
    let newAspects = Preference.string(for: .aspectRatioPanelPresets) ?? ""
    aspectPresetsTokenField.commaSeparatedValues = newAspects
    let defaultAspects = Preference.defaultPreference[.aspectRatioPanelPresets] as? String
    resetAspectPresetsButton.isHidden = (defaultAspects == newAspects)
  }

  private func updateCropControlsFromPrefs() {
    let newCropPresets = Preference.string(for: .cropPanelPresets) ?? ""
    cropPresetsTokenField.commaSeparatedValues = newCropPresets
    let defaultCropPresets = Preference.defaultPreference[.cropPanelPresets] as? String
    resetCropPresetsButton.isHidden = defaultCropPresets == newCropPresets
  }

  // MARK: - Title Bar & OSC

  private func refreshTitleBarAndOSCSection(from geo: ControlBarGeometry? = nil) {
    let newGeo = geo ?? ControlBarGeometry(mode: .windowedNormal)
    lastAppliedGeo = newGeo
    let ib = PWinPreviewImageBuilder(self.view)

    let titleBarIsOverlay = ib.hasTitleBar && ib.topBarPlacement == .insideViewport
    let oscIsOverlay = ib.oscEnabled && (ib.oscPosition == .floating ||
                                         (ib.oscPosition == .top && ib.topBarPlacement == .insideViewport) ||
                                         (ib.oscPosition == .bottom && ib.bottomBarPlacement == .insideViewport))
    let hasOverlay = titleBarIsOverlay || oscIsOverlay
    let oscIsFloating = ib.oscEnabled && ib.oscPosition == .floating
    let oscIsBottom = ib.oscEnabled && ib.oscPosition == .bottom
    let oscIsTop = ib.oscEnabled && ib.oscPosition == .top
    let hasBarOSC = oscIsBottom || oscIsTop
    let hasSingleLineOSCConfig = oscIsTop || (oscIsBottom && newGeo.forceSingleRowStyle)
    let arrowButtonAction: Preference.ArrowButtonAction = Preference.enum(for: .arrowButtonAction)
    let isAdvancedEnabled = Preference.bool(for: .enableAdvancedSettings)
    let showForceSingleRowCheckbox = isAdvancedEnabled && oscIsBottom
    let showOverlayStyleTrigger = oscIsBottom && oscIsOverlay
    let hasTopBar = ib.hasTopBar
    let showTopBarTrigger = hasTopBar && ib.topBarPlacement == .insideViewport && isAdvancedEnabled

    // Update enablement, various state (except isHidden state)
    arrowButtonActionPopUpButton.selectItem(withTag: arrowButtonAction.rawValue)
    autoHideAfterCheckBox.isEnabled = hasOverlay
    oscAutoHideTimeoutTextField.isEnabled = hasOverlay
    hideFadeableViewsOutsideWindowCheckBox.isEnabled = hasOverlay
    windowPreviewImageView.image = ib.buildPWinPreviewImage()
    // Update if invalid value was entered in text field:
    oscBarHeightTextField.integerValue = Int(newGeo.barHeight)

    /// Build list of views which need a change to their visible state.
    /// Each entry contains a ref to a view & intended `isHidden` state:
    var viewHidePairs: [(NSView, Bool)] = []

    viewHidePairs.append((topBarPositionContainerView, !hasTopBar))

    viewHidePairs.append((showTopBarTriggerContainerView, !showTopBarTrigger))

    viewHidePairs.append((oscForceSingleRowContainerView, !showForceSingleRowCheckbox))
    viewHidePairs.append((oscTimeLabelsAlwaysWrapSliderStackView, Preference.bool(for: .oscForceSingleRow)))

    viewHidePairs.append((oscColorSchemeHStackView, !showOverlayStyleTrigger))
    viewHidePairs.append((oscBottomPlacementContainerView, !oscIsBottom))

    viewHidePairs.append((oscSnapToCenterContainerView, !oscIsFloating))

    viewHidePairs.append((toolbarIconDimensionsHStackView, !hasSingleLineOSCConfig))
    viewHidePairs.append((toolbarSectionVStackView, !ib.oscEnabled))
    viewHidePairs.append((oscHeightStackView, !hasBarOSC))
    viewHidePairs.append((oscWidthStackView, !oscIsFloating))
    viewHidePairs.append((playbackBtnDimensionsHStackView, !hasSingleLineOSCConfig))


    let arrowButtonActionIsSpeed = arrowButtonAction == .speed
    viewHidePairs.append((usePressureForArrowsButton, !arrowButtonActionIsSpeed))


    // Two-phase animation. First show/hide the subviews of each container view with no animation.
    for (view, shouldHide) in viewHidePairs {
      guard view as? NSControl == nil else { continue }
      for subview in view.subviews {
        if subview.isHidden != shouldHide {
          subview.animator().isHidden = shouldHide
        }
      }
    }

    animationPipeline.submitTask { [self] in
      // Need to call this here to get proper fade effect instead of jump:
      oscBottomPlacementContainerView.superview?.needsLayout = true

      updateOSCToolbarPreview(from: newGeo)

      // Second phase: hide or show each container view.
      // AppKit will use a fade-in effect.
      for (view, shouldHide) in viewHidePairs {
        view.animator().isHidden = shouldHide
      }
    }
  }

  private func updateOSCSliders(from newGeo: ControlBarGeometry) {
    guard newGeo.isValid else {
      Logger.log.error("Cannot update Settings UI; OSC geometry is invalid: \(newGeo)")
      return
    }
    toolIconSizeSlider.intValue = Int32(newGeo.toolIconSizeTicks)
    toolIconSpacingSlider.intValue = Int32(newGeo.toolIconSpacingTicks)
    playIconSizeSlider.intValue = Int32(newGeo.playIconSizeTicks)
    playIconSpacingSlider.intValue = Int32(newGeo.playIconSpacingTicks)
  }

  private func updateOSCToolbarPreview(from newGeo: ControlBarGeometry) {
    let toolIconSizeTicks = newGeo.toolIconSizeTicks
    let toolIconSpacingTicks = newGeo.toolIconSpacingTicks
    let playIconSizeTicks = newGeo.playIconSizeTicks
    let playIconSpacingTicks = newGeo.playIconSpacingTicks

    // Constrain sizes for prefs preview
    var previewBarHeight = newGeo.barHeight
    if !newGeo.isTwoRowBarOSC {
      previewBarHeight = min(maxToolbarPreviewSingleRowBarHeight, newGeo.barHeight)
    }
    let previewGeo = ControlBarGeometry(mode: .windowedNormal, barHeight: previewBarHeight,
                                        toolIconSizeTicks: toolIconSizeTicks, toolIconSpacingTicks: toolIconSpacingTicks,
                                        playIconSizeTicks: playIconSizeTicks, playIconSpacingTicks: playIconSpacingTicks)
    let previewTotalToolbarWidth = previewGeo.totalToolbarWidth

    Logger.log.verbose("Updating OSC toolbar preview geometry: origBarHeight=\(newGeo.barHeight) toolIconSize=\(previewGeo.toolIconSize), toolIconSpacing=\(previewGeo.toolIconSpacing) previewToolbarWidth=\(previewTotalToolbarWidth) previewToolbarHeight=\(previewGeo.fullIconHeight)")

    // Prevent constraint violations by lowering these briefly...
    oscToolbarStackViewHeightConstraint.priority = .defaultHigh
    oscToolbarStackViewWidthConstraint.priority = .defaultHigh
    let toolbarButtonTypes = previewGeo.toolbarItems

    oscToolbarStackViewHeightConstraint.animateToConstant(previewGeo.fullIconHeight)
    oscToolbarStackViewWidthConstraint.animateToConstant(previewTotalToolbarWidth)

    // If button count hasn't changed, we'll reuse existing buttons. Otherwise delete all & replace
    var btns = oscToolbarStackView.views.compactMap{ $0 as? OSCToolbarButton }
    if btns.count != toolbarButtonTypes.count {
      for btn in oscToolbarStackView.views {
        oscToolbarStackView.removeView(btn)
      }
      var newBtns = [OSCToolbarButton]()
      for _ in 0..<toolbarButtonTypes.count {
        let button = OSCToolbarButton()
        oscToolbarStackView.addView(button, in: .center)
        newBtns.append(button)
      }
      btns = newBtns
    }
    for(buttonType, button) in zip(toolbarButtonTypes, btns) {
      button.setStyle(buttonType: buttonType, iconSize: previewGeo.toolIconSize, iconSpacing: previewGeo.toolIconSpacing)
      button.widthConstraint?.priority = .required
      button.heightConstraint?.priority = .required
    }

    oscToolbarStackView.spacing = 2 * previewGeo.toolIconSpacing
    if previewGeo.toolIconSpacing == 0 {
      oscToolbarStackView.edgeInsets = .init(top: 0, left: 4, bottom: 0, right: 4)
    } else {
      oscToolbarStackView.edgeInsets = .init(top: 0, left: 0, bottom: 0, right: 0)
    }

    // Update sheet preview also (both available items & current items)
    toolbarSettingsSheetController.updateToolbarButtonHeight()

    oscToolbarStackViewHeightConstraint.priority = .required
    // Do not set oscToolbarStackViewWidthConstraint to "required" - avoid constraint errors

    oscToolbarPreviewBox.updateConstraints()
    oscToolbarPreviewBox.layout()
  }

  @IBAction func oscPositionAction(_ sender: NSPopUpButton) {
    guard let oscPosition = Preference.OSCPosition(rawValue: sender.selectedTag()) else { return }
    // need to update this immediately because it is referenced by player windows for icon sizes, spacing
    Preference.set(oscPosition.rawValue, for: .oscPosition)
  }

  @IBAction func oscColorSchemeAction(_ sender: NSPopUpButton) {
    guard let oscColorScheme = Preference.OSCColorScheme(rawValue: sender.selectedTag()) else { return }
    Preference.set(oscColorScheme.rawValue, for: .oscColorScheme)
  }

  @IBAction func customizeOSCToolbarAction(_ sender: Any) {
    toolbarSettingsSheetController.currentItemsView?.initItems(fromItems: ControlBarGeometry.oscToolbarItems)
    toolbarSettingsSheetController.currentButtonTypes = ControlBarGeometry.oscToolbarItems
    toolbarSettingsSheetController.updateFromPrefs()
    view.window?.beginSheet(toolbarSettingsSheetController.window!) { response in
      guard response == .OK else { return }
      let newItems = self.toolbarSettingsSheetController.currentButtonTypes
      let intArray = newItems.map { $0.rawValue }
      Preference.set(intArray, for: .controlBarToolbarButtons)
    }
  }

  // TODO: this can get very slow/laggy if user drags the slider too long. Add throttling or other fix
  @IBAction func oscBarHeightAction(_ sender: NSControl) {
    animationPipeline.submitInstantTask { [self] in
      let newBarHeight = sender.doubleValue
      guard newBarHeight != Preference.double(for: .oscBarHeight) else {
        Logger.log.verbose("No change to oscBarHeight (\(newBarHeight)); aborting oscBarHeightAction")
        return
      }
      let geo = ControlBarGeometry(mode: .windowedNormal, barHeight: sender.doubleValue)
      Logger.log.verbose("New OSC geometry from barHeight=\(geo.barHeight): toolIconSize=\(geo.toolIconSize), toolIconSpacing=\(geo.toolIconSpacing) playIconSize=\(geo.playIconSize) playIconSpacing=\(geo.playIconSpacing)")
      Preference.set(geo.barHeight, for: .oscBarHeight)
      // Try not to trigger pref changed listeners if no change:
      if geo.toolIconSize != Preference.double(for: .oscBarToolIconSize) {
        Preference.set(geo.toolIconSize, for: .oscBarToolIconSize)
      }
      if geo.toolIconSpacing != Preference.double(for: .oscBarToolIconSpacing) {
        Preference.set(geo.toolIconSpacing, for: .oscBarToolIconSpacing)
      }
      if geo.playIconSize != Preference.double(for: .oscBarPlayIconSize) {
        Preference.set(geo.playIconSize, for: .oscBarPlayIconSize)
      }
      if geo.playIconSpacing != Preference.double(for: .oscBarPlayIconSpacing) {
        Preference.set(geo.playIconSpacing, for: .oscBarPlayIconSpacing)
      }

      refreshTitleBarAndOSCSection(from: geo)
    }
  }

  @IBAction func toolIconSizeAction(_ sender: NSSlider) {
    let ticks = sender.integerValue
    let geo = ControlBarGeometry(mode: .windowedNormal, toolIconSizeTicks: ticks)
    Logger.log.verbose("Updating oscBarToolIconSize: \(ticks) ticks, \(Preference.float(for: .oscBarToolIconSize)) -> \(geo.toolIconSize)")
    Preference.set(ticks, for: .oscBarToolIconSizeTicks)
    Preference.set(geo.toolIconSize, for: .oscBarToolIconSize)
  }

  @IBAction func toolIconSpacingAction(_ sender: NSSlider) {
    let ticks = sender.integerValue
    let geo = ControlBarGeometry(mode: .windowedNormal, toolIconSpacingTicks: ticks)
    Logger.log.verbose("Updating oscBarToolIconSpacing: \(ticks) ticks, \(geo.toolIconSpacing)")
    Preference.set(ticks, for: .oscBarToolIconSpacingTicks)
    Preference.set(geo.toolIconSpacing, for: .oscBarToolIconSpacing)
  }

  @IBAction func playIconSizeAction(_ sender: NSSlider) {
    let ticks = sender.integerValue
    let geo = ControlBarGeometry(mode: .windowedNormal, playIconSizeTicks: ticks)
    Logger.log.verbose("Updating oscBarPlayIconSize: \(ticks) ticks, \(geo.playIconSize)")
    Preference.set(ticks, for: .oscBarPlayIconSizeTicks)
    Preference.set(geo.playIconSize, for: .oscBarPlayIconSize)
  }

  @IBAction func playIconSpacingAction(_ sender: NSSlider) {
    let ticks = sender.integerValue
    let geo = ControlBarGeometry(mode: .windowedNormal, playIconSpacingTicks: ticks)
    Logger.log.verbose("Updating oscBarPlayIconSpacing: \(ticks) ticks, \(geo.playIconSpacing)")
    Preference.set(ticks, for: .oscBarPlayIconSpacingTicks)
    Preference.set(geo.playIconSpacing, for: .oscBarPlayIconSpacing)
  }

  @IBAction func arrowButtonActionAction(_ sender: NSPopUpButton) {
    let arrowButtonAction: Preference.ArrowButtonAction = .init(rawValue: sender.selectedTag()) ?? .defaultValue
    let geo = ControlBarGeometry(mode: .windowedNormal, arrowButtonAction: arrowButtonAction)
    Logger.log.verbose("Updating arrowButtonAction to: \(geo.arrowButtonAction)")
    let val = geo.arrowButtonAction.rawValue
    guard val != Preference.integer(for: .arrowButtonAction) else { return }
    Preference.set(val, for: .arrowButtonAction)
  }

  // MARK: - PiP

  @IBAction func setupPipBehaviorRelatedControls(_ sender: NSButton) {
    Preference.set(sender.tag, for: .windowBehaviorWhenPip)
  }

  private func updatePictureInPictureSection() {
    let pipBehaviorOption = Preference.enum(for: .windowBehaviorWhenPip) as Preference.WindowBehaviorWhenPip
    ([pipDoNothing, pipHideWindow, pipMinimizeWindow] as [NSButton])
      .first { $0.tag == pipBehaviorOption.rawValue }?.state = .on
  }

  // MARK: - Window Geometry

  @IBAction func updateWindowResizeScheme(_ sender: AnyObject) {
    guard let scheme = Preference.ResizeWindowScheme(rawValue: sender.tag) else {
      let tag: String = String(sender.tag ?? -1)
      Logger.log("Could not find ResizeWindowScheme matching rawValue \(tag)", level: .error)
      return
    }
    Preference.set(scheme.rawValue, for: .resizeWindowScheme)
    updateWindowGeometrySectionFromPrefs()
  }

  // Called by a UI control. Updates prefs + any dependent UI controls
  @IBAction func updateGeometryValue(_ sender: AnyObject) {
    if resizeWindowWhenOpeningFileCheckbox.state == .off {
      Preference.set(Preference.ResizeWindowTiming.never.rawValue, for: .resizeWindowTiming)
      Preference.set("", for: .initialWindowSizePosition)

    } else {
      if let timing = Preference.ResizeWindowTiming(rawValue: resizeWindowTimingPopUpButton.selectedTag()) {
        Preference.set(timing.rawValue, for: .resizeWindowTiming)
      }

      var geometry = ""
      // size
      if windowSizeCheckBox.state == .on {
        // either width or height, but not both
        if windowSizeTypePopUpButton.selectedTag() == SizeHeightTag {
          geometry += "x"
        }

        let isPercentage = windowSizeUnitPopUpButton.selectedTag() == UnitPercentTag
        if isPercentage {
          geometry += normalizePercentage(windowSizeValueTextField.stringValue)
        } else {
          geometry += windowSizeValueTextField.stringValue
        }
      }
      // position
      if windowPosCheckBox.state == .on {
        // X
        geometry += windowPosXAnchorPopUpButton.selectedTag() == SideLeftTag ? "+" : "-"

        if windowPosXUnitPopUpButton.selectedTag() == UnitPercentTag {
          geometry += normalizePercentage(windowPosXOffsetTextField.stringValue)
        } else {
          geometry += normalizeSignedInteger(windowPosXOffsetTextField.stringValue)
        }

        // Y
        geometry += windowPosYAnchorPopUpButton.selectedTag() == SideTopTag ? "+" : "-"

        if windowPosYUnitPopUpButton.selectedTag() == UnitPercentTag {
          geometry += normalizePercentage(windowPosYOffsetTextField.stringValue)
        } else {
          geometry += normalizeSignedInteger(windowPosYOffsetTextField.stringValue)
        }
      }
      Logger.log("Saving pref \(Preference.Key.initialWindowSizePosition.rawValue.quoted) with geometry: \(geometry.quoted)")
      Preference.set(geometry, for: .initialWindowSizePosition)
    }

    updateWindowGeometrySectionFromPrefs()
  }

  private func normalizeSignedInteger(_ string: String) -> String {
    let intValue = Int(string) ?? 0
    return intValue < 0 ? "\(intValue)" : "+\(intValue)"
  }

  private func normalizePercentage(_ string: String) -> String {
    let sizeInt = (Int(string) ?? 100).clamped(to: 0...100)
    return "\(sizeInt)%"
  }

  // Updates UI from prefs. Uses a nice fade or sliding animation depending on the panel.
  private func updateWindowGeometrySectionFromPrefs() {
    animationPipeline.submitTask { [self] in
      _updateWindowGeometrySectionFromPrefs()
    }
  }

  private func _updateWindowGeometrySectionFromPrefs() {
    let resizeOption = Preference.enum(for: .resizeWindowTiming) as Preference.ResizeWindowTiming
    let scheme: Preference.ResizeWindowScheme = Preference.enum(for: .resizeWindowScheme)

    let isAnyResizeEnabled: Bool
    switch resizeOption {
    case .never:
      resizeWindowWhenOpeningFileCheckbox.state = .off
      isAnyResizeEnabled = false
    case .always, .onlyWhenOpen:
      resizeWindowWhenOpeningFileCheckbox.state = .on
      isAnyResizeEnabled = true
      resizeWindowTimingPopUpButton.selectItem(withTag: resizeOption.rawValue)

      switch scheme {
      case .mpvGeometry:
        mpvGeometryRadioButton.state = .on
        simpleVideoSizeRadioButton.state = .off
      case .simpleVideoSizeMultiple:
        mpvGeometryRadioButton.state = .off
        simpleVideoSizeRadioButton.state = .on
      }
    }

    mpvGeometryRadioButton.isHidden = !isAnyResizeEnabled
    simpleVideoSizeRadioButton.superview?.isHidden = !isAnyResizeEnabled

    // mpv
    let isMpvGeometryEnabled = isAnyResizeEnabled && scheme == .mpvGeometry
    var isUsingMpvSize = false
    var isUsingMpvPos = false

    if isMpvGeometryEnabled {
      let geometryString = Preference.string(for: .initialWindowSizePosition) ?? ""
      if let geometry = MPVGeometryDef.parse(geometryString) {
        Logger.log("Parsed \(Preference.quoted(.initialWindowSizePosition))=\(geometryString.quoted) ➤ \(geometry)")
        unparsedGeometryLabel.stringValue = "\"\(geometryString)\""
        // size
        if let h = geometry.h {
          isUsingMpvSize = true
          windowSizeTypePopUpButton.selectItem(withTag: SizeHeightTag)
          windowSizeUnitPopUpButton.selectItem(withTag: geometry.hIsPercentage ? UnitPercentTag : UnitPointTag)
          windowSizeValueTextField.stringValue = h
        } else if let w = geometry.w {
          isUsingMpvSize = true
          windowSizeTypePopUpButton.selectItem(withTag: SizeWidthTag)
          windowSizeUnitPopUpButton.selectItem(withTag: geometry.wIsPercentage ? UnitPercentTag : UnitPointTag)
          windowSizeValueTextField.stringValue = w
        }
        // position
        if var x = geometry.x, var y = geometry.y {
          let xSign = geometry.xSign ?? "+"
          let ySign = geometry.ySign ?? "+"
          x = x.hasPrefix("+") ? String(x.dropFirst()) : x
          y = y.hasPrefix("+") ? String(y.dropFirst()) : y
          isUsingMpvPos = true
          windowPosXAnchorPopUpButton.selectItem(withTag: xSign == "+" ? SideLeftTag : SideRightTag)
          windowPosXOffsetTextField.stringValue = x
          windowPosXUnitPopUpButton.selectItem(withTag: geometry.xIsPercentage ? UnitPercentTag : UnitPointTag)
          windowPosYAnchorPopUpButton.selectItem(withTag: ySign == "+" ? SideTopTag : SideBottomTag)
          windowPosYOffsetTextField.stringValue = y
          windowPosYUnitPopUpButton.selectItem(withTag: geometry.yIsPercentage ? UnitPercentTag : UnitPointTag)
        }
      } else {
        if !geometryString.isEmpty {
          Logger.log("Failed to parse string \(geometryString.quoted) from \(Preference.quoted(.initialWindowSizePosition)) pref", level: .error)
        }
        unparsedGeometryLabel.stringValue = ""
      }
    }
    unparsedGeometryLabel.isHidden = !(Preference.isAdvancedEnabled && isMpvGeometryEnabled)
    spacer0.isHidden = !isMpvGeometryEnabled
    mpvWindowSizeCollapseView.isHidden = !isMpvGeometryEnabled
    mpvWindowPositionCollapseView.isHidden = !isMpvGeometryEnabled
    windowSizeCheckBox.state = isUsingMpvSize ? .on : .off
    windowPosCheckBox.state = isUsingMpvPos ? .on : .off
    mpvWindowSizeCollapseView.setCollapsed(!isUsingMpvSize, animated: true)
    mpvWindowPositionCollapseView.setCollapsed(!isUsingMpvPos, animated: true)
  }

  // MARK: - Other

  @IBAction func disableAnimationsHelpAction(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: AppData.disableAnimationsHelpLink)!)
  }

  private func reloadThumbnailCacheStat() {
    let cacheSizeBytes = ThumbnailCache.shared.getCacheSize()
    let newString = "\(FloatingPointByteCountFormatter.string(fromByteCount: cacheSizeBytes, countStyle: .binary))B"
    DispatchQueue.main.async { [self] in
      currentThumbCacheSizeTextField.stringValue = newString
    }
  }

}

// MARK: - Transformers

@objc(IntEqualsZeroTransformer) class IntEqualsZeroTransformer: ValueTransformer {

  static override func allowsReverseTransformation() -> Bool {
    return false
  }

  static override func transformedValueClass() -> AnyClass {
    return NSNumber.self
  }

  override func transformedValue(_ value: Any?) -> Any? {
    guard let number = value as? NSNumber else { return nil }
    return number == 0
  }
}

@objc(IntEqualsOneTransformer) class IntEqualsOneTransformer: IntEqualsZeroTransformer {

  override func transformedValue(_ value: Any?) -> Any? {
    guard let number = value as? NSNumber else { return nil }
    return number == 1
  }
}

@objc(IntEqualsTwoTransformer) class IntEqualsTwoTransformer: IntEqualsZeroTransformer {

  override func transformedValue(_ value: Any?) -> Any? {
    guard let number = value as? NSNumber else { return nil }
    return number == 2
  }
}

@objc(IntNotEqualsOneTransformer) class IntNotEqualsOneTransformer: IntEqualsZeroTransformer {

  override func transformedValue(_ value: Any?) -> Any? {
    guard let number = value as? NSNumber else { return nil }
    return number != 1
  }
}

@objc(IntNotEqualsTwoTransformer) class IntNotEqualsTwoTransformer: IntEqualsZeroTransformer {

  override func transformedValue(_ value: Any?) -> Any? {
    guard let number = value as? NSNumber else { return nil }
    return number != 2
  }
}


@objc(ResizeTimingTransformer) class ResizeTimingTransformer: ValueTransformer {

  static override func allowsReverseTransformation() -> Bool {
    return false
  }

  static override func transformedValueClass() -> AnyClass {
    return NSNumber.self
  }

  override func transformedValue(_ value: Any?) -> Any? {
    guard let timing = value as? Int else { return nil }
    return timing != Preference.ResizeWindowTiming.never.rawValue
  }
}

@objc(InverseResizeTimingTransformer) class InverseResizeTimingTransformer: ValueTransformer {

  static override func allowsReverseTransformation() -> Bool {
    return false
  }

  static override func transformedValueClass() -> AnyClass {
    return NSNumber.self
  }

  override func transformedValue(_ value: Any?) -> Any? {
    guard let timing = value as? Int else { return nil }
    return timing == Preference.ResizeWindowTiming.never.rawValue
  }
}


class PlayerWindowPreviewView: NSView {

  override func awakeFromNib() {
    self.layer?.cornerRadius = 6
    self.layer?.masksToBounds = true
    self.layer?.borderWidth = 1
    self.layer?.borderColor = CGColor(gray: 0.6, alpha: 0.5)
  }

}
