//
//  PWin_WinDidLoad.swift
//  iina
//
//  Created by Matt Svoboda on 2024-10-23.
//  Copyright © 2024 lhc. All rights reserved.
//

import Foundation

extension PlayerWindowController {

  /// Called when window is initially loaded. Add all subviews here.
  ///
  /// Can be called more than once, but will only execute if `loaded` is false. When it finishes, it will set `loaded` to true.
  ///
  /// This was formerly `windowDidLoad`, but we no longer load the window via XIB, so we are free to control
  /// the loading process ourselves.
  @MainActor
  func finishLoading() {
    guard !loaded else { return }
    log.verbose("[Load] PWin_WinDidLoad starting")

    guard let window else { return }
    guard let contentView = window.contentView else { return }

    miniPlayer = MiniPlayerViewController()
    miniPlayer.pwc = self

    undoHelper = PlayerWindowUndoHelper(self, window.undoManager)

    viewportView.player = player

    // Must call this before buildObservers
    playSliderCell.initLoopKnobs()

    notiHandler = buildObservers()

    // The fade timer is only used if auto-hide is enabled
    fadeableViews.hideTimer.action = hideTimeoutAction
    fadeableViews.hideTimer.startCondition = { _ in Preference.bool(for: .enableControlBarAutoHide) }

    // Cursor hide timer
    hideCursorTimer.action = hideCursorAsConfigured
    hideCursorTimer.startCondition = { [self] timer in
      guard player.canHideCursor else {
        log.trace("HideCursorTimer: aborting start (cannot hide cursor)")
        return false
      }
      let newTimeout = max(TimeConstants.hideCursorMinTimeoutMS, Double(player.info.cursorAutoHideTimeoutMs))
      timer.timeout = newTimeout / 1000.0
      log.trace("HideCursorTimer: [re-]starting timeout=\(timer.timeout)s")
      return true
    }

    /// Set base options for `collectionBehavior` here, and then insert/remove full screen options
    /// using `resetCollectionBehavior`. Do not mess with the base options again because doing so seems
    /// to cause flickering while animating.
    /// For now, always use option `.fullScreenDisallowsTiling`.
    // FIXME: support tiling for native full screen
    window.collectionBehavior = [.managed, .fullScreenDisallowsTiling]

    window.initialFirstResponder = nil
    window.minSize = Constants.Window.minWindowSize
    contentView.idString = "PWinCV"

    leftTimeLabel.mode = .current
    rightTimeLabel.mode = Preference.bool(for: .showRemainingTime) ? .remaining : .duration

    // gesture recognizers
    rotationHandler.pwc = self
    magnificationHandler.pwc = self
    viewportView.addGestureRecognizer(magnificationHandler.magnificationGestureRecognizer)
    viewportView.addGestureRecognizer(rotationHandler.rotationGestureRecognizer)

    // scroll wheel
    playSlider.scrollWheelDelegate = PlaySliderScrollWheel(slider: playSlider, log)
    volumeSlider.scrollWheelDelegate = VolumeSliderScrollWheel(slider: volumeSlider, log)
    windowScrollWheel = PWinScrollWheel(self)

    playlistView.pwc = self
    pluginView.pwc = self
    quickSettingView.pwc = self

    /// Use an animation task to init views in a single CATransaction, which should prevent partial/redundant draws.
    animationPipeline.submitInstantTask{ [self] in
      window.preservesContentDuringLiveResize = false

      let oscGeo = currentLayout.controlBarGeo
      initSeekPreview(in: contentView)
      initTitleBar()
      initOSCToolbar()
      initPlaybackBtnsView(using: oscGeo)
      initPlaySliderAndTimeLabelsView()
      initVolumeView(using: oscGeo)
      initSidebars()
      initPluginOverlayViewContainer()
      initExitMusicModeButton(in: contentView)
      initHdrWorkaroundView(in: contentView)

      log.verbose("[Load] Configuring window for CoreAnimation")
      contentView.configureSubtreeForCoreAnimation()

      if !currentLayout.isMusicMode || geo.musicMode.isViewportShown {
        // When restoring, need to set size of video ASAP or else it will briefly display with wrong initial size.
        // Also, can hangs result if video is not added to window by the time fileLoaded is called?
        addViewportAndSubviewsToWindowIfNeeded()
        if currentLayout.isMusicMode {
          log.verbose("[Load] Configuring viewport for music mode")
          viewportView.apply(geo.musicMode)
        } else {
          log.verbose("[Load] Configuring viewport for windowed mode")
          viewportView.apply(geo.windowed)
        }
      }

      // Make sure to set this inside the animation task! See note above
      loaded = true

      if player.disableUI { hideFadeableViews() }

      // Must wait until *after* loaded==true to load plugins!
      player.loadPlugins()

      MemoryUsage.shared.logUsage("after window loaded")

      log.verbose("[Load] PWin_WinDidLoad done")
      player.events.emit(.windowLoaded)
    }
  }

  /// Workaround for a bug in macOS Ventura where HDR content becomes dimmed when playing in full
  /// screen mode once overlaying views are fully hidden (issue #3844). After applying this
  /// workaround another bug in Ventura where an external monitor goes black could not be
  /// reproduced (issue #4015). The workaround adds a tiny subview with such a low alpha level it
  /// is invisible to the human eye. This workaround may not be effective in all cases.
  ///
  /// Update in MacOS Tahoe: discovered another problem. Setup: go into full screen (native or leacy),
  /// when the OSD is hidden and no other elements are shown on screen other than the "bottom"
  /// OSC configured for `inside` placement (i.e., fadeable overlay) with "Clear Black Gradient" style.
  /// When the bottom bar & cursor are hidden & video is playing (i.e., not paused): move the mouse to
  /// trigger the bottom OSC to show. About 1/3 of the time the entire screen will briefly flicker black,
  /// & sometimes there is brief but noticable tearing around where the cursor appears.
  /// Lengthy testing revealed that this workaround, which was originally intended for HDR issues,
  /// also wards against this bug!
  private func initHdrWorkaroundView(in contentView: NSView) {
    guard Preference.bool(for: .enableHdrWorkaround) else { return }
    log.debug("[Load] Adding HDR full screen workaround")

    hdrWorkaroundView.wantsLayer = true
    hdrWorkaroundView.layer?.backgroundColor = NSColor.black.cgColor
    hdrWorkaroundView.layer?.opacity = 0.01
    contentView.addSubview(hdrWorkaroundView)
    // Use constraints to guarantee the view will not move off screen. When placed in the upper-leading corner,
    // this view will be clipped out entirely due by the rounded corner of the Macbook screen, yet it remains
    // effective (though it does need to be half a pixel in diameter).
    hdrWorkaroundView.translatesAutoresizingMaskIntoConstraints = false
    hdrWorkaroundView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor).isActive = true
    hdrWorkaroundView.topAnchor.constraint(equalTo: contentView.topAnchor).isActive = true
    // Don't use priority of 1000: allow it to squeeze just in case window needs to be resized to 0 during an animation.
    let widthConstraint = hdrWorkaroundView.trailingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0.5)
    widthConstraint.priority = .defaultHigh
    widthConstraint.isActive = true
    let heightConstraint = hdrWorkaroundView.bottomAnchor.constraint(equalTo: contentView.topAnchor, constant: 0.5)
    heightConstraint.priority = .defaultHigh
    heightConstraint.isActive = true
  }

  // MARK: - Building Components

  @MainActor
  private func initTitleBar() {
    let builder = CustomTitleBar.shared
    let iconSpacingH = Constants.titleBarIconHSpacing
    // - LEADING

    builder.configureTitleBarButton(leadingSidebarToggleButton,
                                    Images.sidebarLeading,
                                    identifier: "LeadingSidebarBtn_Native",
                                    target: self,
                                    action: #selector(toggleLeadingSidebarVisibility(_:)),
                                    actionSymbolEffectFunc: SymButton.bounceEffectFunc)

    // Need to add trailing padding for each . But can't use edgeInsets of stack view because that seems to result in constraint errors.
    // Use a spacer instead
    let leadingAccTrailingSpacer = SpacerView(id: "LeadingTBAccTrailingSpacer")
    leadingAccTrailingSpacer.setContentHuggingPriority(.required, for: .horizontal)  // do not expand horizontally
    let leadingAccTrailingSpaceConstraint = leadingAccTrailingSpacer.widthAnchor.constraint(equalToConstant: 0)
    // Unclear why we get constraint errors when using priority=1000 here. Just reduce to 750.
    // In the future, would be better to get rid of horizontal stack views in title bar
    leadingAccTrailingSpaceConstraint.priority = .defaultHigh
    leadingAccTrailingSpaceConstraint.isActive = true

    leadingTitleBarAccessoryView.idString = "leadingTBAccView"
    leadingTitleBarAccessoryView.orientation = .horizontal
    leadingTitleBarAccessoryView.alignment = .centerY
    leadingTitleBarAccessoryView.distribution = .fill
    leadingTitleBarAccessoryView.spacing = iconSpacingH
    leadingTitleBarAccessoryView.detachesHiddenViews = true
    leadingTitleBarAccessoryView.translatesAutoresizingMaskIntoConstraints = false

    leadingTitleBarAccessoryView.addArrangedSubview(leadingSidebarToggleButton)
    leadingTitleBarAccessoryView.addArrangedSubview(leadingAccTrailingSpacer)

    // - TRAILING

    builder.configureTitleBarButton(onTopButton,
                                    Images.onTopOff,
                                    identifier: "OnTopButton_Native",
                                    target: self, action: #selector(toggleOnTop(_:)),
                                    actionSymbolEffectFunc: SymButton.nullEffectFunc) // Do not bounce (looks weird)

    builder.configureTitleBarButton(trailingSidebarToggleButton,
                                    Images.sidebarTrailing,
                                    identifier: "TrailingSidebarBtn_Native",
                                    target: self,
                                    action: #selector(toggleTrailingSidebarVisibility(_:)),
                                    actionSymbolEffectFunc: SymButton.bounceEffectFunc)

    let trailingAccTrailingSpacer = SpacerView(id: "TrailingTBAccTrailingSpacer")
    trailingAccTrailingSpacer.setContentHuggingPriority(.required, for: .horizontal)  // do not expand horizontally
    let trailingAccTrailingSpaceConstraint = trailingAccTrailingSpacer.widthAnchor.constraint(equalToConstant: 0)
    trailingAccTrailingSpaceConstraint.priority = .defaultHigh  // see note above
    trailingAccTrailingSpaceConstraint.isActive = true

    trailingTitleBarAccessoryView.idString = "trailingTBAccView"
    trailingTitleBarAccessoryView.orientation = .horizontal
    trailingTitleBarAccessoryView.alignment = .centerY
    trailingTitleBarAccessoryView.distribution = .fill
    trailingTitleBarAccessoryView.spacing = iconSpacingH
    trailingTitleBarAccessoryView.detachesHiddenViews = true
    trailingTitleBarAccessoryView.translatesAutoresizingMaskIntoConstraints = false

    trailingTitleBarAccessoryView.addArrangedSubview(trailingSidebarToggleButton)
    trailingTitleBarAccessoryView.addArrangedSubview(onTopButton)
    trailingTitleBarAccessoryView.addArrangedSubview(trailingAccTrailingSpacer)
  }

  private func initOSCToolbar() {
    oscToolbarView.idString = "OSC-ToolbarView"
    oscToolbarView.translatesAutoresizingMaskIntoConstraints = false
    oscToolbarView.orientation = .horizontal
    oscToolbarView.distribution = .fill
  }

  private func initExitMusicModeButton(in contentView: NSView) {
    miniPlayerTrafficLightsBGView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(miniPlayerTrafficLightsBGView)
    miniPlayerTrafficLightsBGView.isHidden = true  // initially
    miniPlayerTrafficLightsBGView.addSubview(exitMusicModeButton)
    exitMusicModeButton.target = self
    exitMusicModeButton.action = #selector(backBtnAction(_:))

    let trafficLightBtnSize: NSSize = Constants.trafficLightButtonSize
    let btnPadding: CGFloat
    if #available(macOS 26.0, *) {
      btnPadding = 1.0
    } else {
      btnPadding = 0.0
    }

    let bgPadding = 4.0
    let bgViewHeight = trafficLightBtnSize.height + ((btnPadding + bgPadding) * 2)
    let btnWidth = trafficLightBtnSize.width + (btnPadding * 2)
    let bgViewTopOffset: CGFloat = (Constants.standardTitleBarHeight - bgViewHeight) * 0.5
    let bgViewLeadingOffset = bgViewTopOffset
    miniPlayerTrafficLightsBGView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: bgViewLeadingOffset).isActive = true
    var bgViewTrailingOffset: CGFloat
    if window!.styleMask.contains(.titled) {
      let zoomBtn = trafficLightButtons.last!
      let zoomBtnOriginLocalCoords = zoomBtn.bounds.origin
      let zoomBtnOriginInWinX = window!.contentView!.convert(zoomBtnOriginLocalCoords, from: zoomBtn).x
      bgViewTrailingOffset = zoomBtnOriginInWinX + btnWidth + bgViewLeadingOffset
      if #unavailable(macOS 26.0) {
        bgViewTrailingOffset += 2
      }
    } else {
      bgViewTrailingOffset = 74
      if #unavailable(macOS 26.0) {
        bgViewTrailingOffset -= 10
      }
    }
    miniPlayerTrafficLightsBGView.trailingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: bgViewTrailingOffset).isActive = true
    miniPlayerTrafficLightsBGView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: bgViewTopOffset).isActive = true
    miniPlayerTrafficLightsBGView.bottomAnchor.constraint(equalTo: miniPlayerTrafficLightsBGView.topAnchor, constant: bgViewHeight).isActive = true
    miniPlayerTrafficLightsBGView.roundCorners(withRadius: bgViewHeight * 0.5)

    // Add Exit Music Mode button to traffic light buttons
    miniPlayerTrafficLightsBGView.trailingAnchor.constraint(equalTo: exitMusicModeButton.trailingAnchor, constant: bgPadding).isActive = true
    // Center vertically with traffic light buttons
    exitMusicModeButton.centerYAnchor.constraint(equalTo: miniPlayerTrafficLightsBGView.centerYAnchor).isActive = true

    exitMusicModeButton.widthAnchor.constraint(equalToConstant: btnWidth).isActive = true
    exitMusicModeButton.heightAnchor.constraint(equalTo: exitMusicModeButton.widthAnchor).isActive = true
  }

  private func initSidebars() {
    log.verbose("[Load] Init sidebars")
    rebuildLeadingSidebarView(.tintedGlass)
    rebuildTrailingSidebarView(.tintedGlass)
  }

  func rebuildLeadingSidebarView(_ colorScheme: Preference.PanelColorScheme) {
    leadingSidebarView.removeFromSuperview()

    switch colorScheme {
    case .clearGlass, .tintedGlass:
      if #available(macOS 26.0, *) {
        let desiredStyle: NSGlassEffectView.Style = colorScheme == .clearGlass ? .clear : .regular
        let glassView = ClickThroughGlassEffectView(desiredStyle)
        glassView.cornerRadius = 0
        leadingSidebarView = glassView
        // No top border in this case; it already provides a border
      } else {
        fallthrough
      }
    default:
      let veView = ClickThroughVisualEffectView()
      veView.state = .active
      leadingSidebarView = veView

      // Leading sidebar border
      leadingSidebarView.addSubview(leadingSidebarTrailingBorder)
      leadingSidebarTrailingBorder.addConstraintsToFillSuperview(top: 0, bottom: 0, trailing: 0)
      // Avoid constraint error by setting priority = .defaultHigh (see similar notes for bottomBarTopBorder_HeightConstraint, et al.)
      let leadingSidebarTrailingBorder_WidthConstraint = leadingSidebarTrailingBorder.leadingAnchor.constraint(equalTo: leadingSidebarView.trailingAnchor, constant: -0.5)
      leadingSidebarTrailingBorder_WidthConstraint.identifier = .init("LeadingSidebarTrailingBorder-WidthConstraint")
      leadingSidebarTrailingBorder_WidthConstraint.priority = .defaultHigh
      leadingSidebarTrailingBorder_WidthConstraint.isActive = true
    }

    leadingSidebarView.idString = "LeadingSidebarView"
    addShadow(toSidebar: leadingSidebarView)
    leadingSidebarView.translatesAutoresizingMaskIntoConstraints = false
    leadingSidebarView.autoresizesSubviews = false
  }

  func rebuildTrailingSidebarView(_ colorScheme: Preference.PanelColorScheme) {
    trailingSidebarView.removeFromSuperview()

    switch colorScheme {
    case .clearGlass, .tintedGlass:
      if #available(macOS 26.0, *) {
        let desiredStyle: NSGlassEffectView.Style = colorScheme == .clearGlass ? .clear : .regular
        let glassView = ClickThroughGlassEffectView(desiredStyle)
        glassView.cornerRadius = 0
        trailingSidebarView = glassView
        // No top border in this case; it already provides a border
      } else {
        fallthrough
      }
    default:
      let veView = ClickThroughVisualEffectView()
      veView.state = .active
      trailingSidebarView = veView

      // Trailing sidebar border
      trailingSidebarView.addSubview(trailingSidebarLeadingBorder)
      trailingSidebarLeadingBorder.addConstraintsToFillSuperview(top: 0, bottom: 0, leading: 0)
      // Avoid constraint error by setting priority = .defaultHigh (see similar notes for bottomBarTopBorder_HeightConstraint, et al.)
      let trailingSidebarLeadingBorder_WidthConstraint = trailingSidebarLeadingBorder.trailingAnchor.constraint(equalTo: trailingSidebarView.leadingAnchor, constant: 0.5)
      trailingSidebarLeadingBorder_WidthConstraint.identifier = .init("TrailingSidebarLeadingBorder-WidthConstraint")
      trailingSidebarLeadingBorder_WidthConstraint.priority = .defaultHigh
      trailingSidebarLeadingBorder_WidthConstraint.isActive = true
    }

    trailingSidebarView.idString = "TrailingSidebarView"
    addShadow(toSidebar: trailingSidebarView)
    trailingSidebarView.translatesAutoresizingMaskIntoConstraints = false
    trailingSidebarView.autoresizesSubviews = false
  }

  private func initPluginOverlayViewContainer() {
    pluginOverlayViewContainer.translatesAutoresizingMaskIntoConstraints = false
    viewportView.addSubviewAndConstraints(pluginOverlayViewContainer, top: 0, bottom: 0, leading: 0, trailing: 0)
  }

  private func addShadow(toSidebar sidebarView: NSView) {
    sidebarView.wantsLayer = true
    let layer = sidebarView.layer!
    layer.shadowColor = Constants.Color.defaultShadow.cgColor
    layer.shadowOffset = .zero
    layer.shadowOpacity = 1
    layer.shadowRadius = Constants.sidebarShadowRadius
  }

  /// Init `oscPlaybackBtnsView` & its subviews
  private func initPlaybackBtnsView(using oscGeo: ControlBarGeometry) {
    log.verbose("[Load] Init playback buttons")

    // Play button
    playButton.image = Images.play
    playButton.target = self
    playButton.action = #selector(playButtonAction(_:))
    playButton.idString = "PlayBtn"  // helps with debug logging
    playButton.actionSymbolEffectFunc = SymButton.nullEffectFunc(_:)
    // Set to 0 at load time to be safe:
    let playAspectConstraint = playButton.widthAnchor.constraint(equalTo: playButton.heightAnchor)
    playAspectConstraint.isActive = true

    playBtnHeightConstraint = playButton.heightAnchor.constraint(equalToConstant: 0)
    playBtnHeightConstraint.identifier = "PlayBtnVStack-HeightConstraint"
    playBtnHeightConstraint.priority = .init(900)
    playBtnHeightConstraint.isActive = true

    // Left Arrow button
    leftArrowButton.image = oscGeo.leftArrowImage
    leftArrowButton.target = self
    leftArrowButton.action = #selector(leftArrowButtonAction(_:))
    leftArrowButton.idString = "LeftArrowBtn"

    updateArrowButtonAccelerationFromPrefs()

    // Right Arrow button
    rightArrowButton.image = oscGeo.rightArrowImage
    rightArrowButton.target = self
    rightArrowButton.action = #selector(rightArrowButtonAction(_:))
    rightArrowButton.idString = "RightArrowBtn"

    initSpeedLabel()

    oscPlaybackBtnsView.idString = "oscPlaybackBtnsView"
    oscPlaybackBtnsView.addSubview(leftArrowButton)
    oscPlaybackBtnsView.addSubview(playButton)
    oscPlaybackBtnsView.addSubview(speedLabel)
    oscPlaybackBtnsView.addSubview(rightArrowButton)

    let playBtnHorizOffsetConstraint = playButton.centerXAnchor.constraint(equalTo: oscPlaybackBtnsView.centerXAnchor)
    playBtnHorizOffsetConstraint.isActive = true

    speedLabel.centerXAnchor.constraint(equalTo: playButton.centerXAnchor).isActive = true
    // Snip off 2 pts from top & btm to reduce margin:
    let speedLabelTopConstraint = oscPlaybackBtnsView.topAnchor.constraint(equalTo: speedLabel.topAnchor, constant: 2)
    speedLabelTopConstraint.identifier = "SpeedLabel-TopConstraint"
    speedLabelTopConstraint.isActive = true
    speedLabelBtmConstraint = speedLabel.bottomAnchor.constraint(equalTo: playButton.topAnchor, constant: 2)
    speedLabelBtmConstraint.identifier = "SpeedLabel-BtmConstraint"
    speedLabelBtmConstraint.isActive = false

    oscPlaybackBtnsView.translatesAutoresizingMaskIntoConstraints = false

    oscPlaybackBtnsHeightConstraint = oscPlaybackBtnsView.heightAnchor.constraint(equalToConstant: 0)
    oscPlaybackBtnsHeightConstraint.identifier = "fragPlaybackBtns-HeightConstraint"
    oscPlaybackBtnsHeightConstraint.isActive = true

    oscPlaybackBtnsWidthConstraint = oscPlaybackBtnsView.widthAnchor.constraint(equalToConstant: oscGeo.totalPlayControlsWidth)
    oscPlaybackBtnsWidthConstraint.identifier = "fragPlaybackBtns-WidthConstraint"
    oscPlaybackBtnsWidthConstraint.isActive = true

    // Try to make sure the buttons' bounding boxes reach the full height, for activation
    // (their images will be limited by the width constraint & will stop scaling before this)
    let leftArrowAspectConstraint = leftArrowButton.heightAnchor.constraint(equalTo: leftArrowButton.widthAnchor)
    leftArrowAspectConstraint.identifier = .init("leftArrowBtn-AspectConstraint")
    leftArrowAspectConstraint.isActive = true
    let rightArrowAspectConstraint = rightArrowButton.heightAnchor.constraint(equalTo: rightArrowButton.widthAnchor)
    rightArrowAspectConstraint.identifier = .init("rightArrowBtn-AspectConstraint")
    rightArrowAspectConstraint.isActive = true

    // Video controllers and timeline indicators should not flip in a right-to-left language.
    oscPlaybackBtnsView.userInterfaceLayoutDirection = .leftToRight

    let playBtnVertOffsetConstraint = playButton.centerYAnchor.constraint(equalTo: oscPlaybackBtnsView.centerYAnchor)
    playBtnVertOffsetConstraint.isActive = true

    leftArrowBtn_CenterXOffsetConstraint = leftArrowButton.centerXAnchor.constraint(equalTo: oscPlaybackBtnsView.centerXAnchor,
                                                                                    constant: oscGeo.leftArrowCenterXOffset)
    leftArrowBtn_CenterXOffsetConstraint.identifier = .init("leftArrowBtn-HorizOffsetConstraint")
    leftArrowBtn_CenterXOffsetConstraint.isActive = true

    let leftArrowBtn_LeadingXOffsetConstraint = leftArrowButton.leadingAnchor.constraint(greaterThanOrEqualTo: oscPlaybackBtnsView.leadingAnchor)
    leftArrowBtn_LeadingXOffsetConstraint.identifier = .init("leftArrowBtn-LeadingXOffset")
    leftArrowBtn_LeadingXOffsetConstraint.isActive = true

    arrowBtnWidthConstraint = leftArrowButton.widthAnchor.constraint(equalToConstant: 0)
    arrowBtnWidthConstraint.identifier = .init("arrowBtn-WidthConstraint")
    arrowBtnWidthConstraint.isActive = true

    rightArrowBtn_CenterXOffsetConstraint = rightArrowButton.centerXAnchor.constraint(equalTo: oscPlaybackBtnsView.centerXAnchor,
                                                                                      constant: oscGeo.rightArrowCenterXOffset)
    rightArrowBtn_CenterXOffsetConstraint.identifier = .init("rightArrowBtn_CenterXOffsetConstraint")
    rightArrowBtn_CenterXOffsetConstraint.isActive = true

    // Left & Right arrow buttons are always same size
    let arrowBtnsEqualWidthConstraint = leftArrowButton.widthAnchor.constraint(equalTo: rightArrowButton.widthAnchor, multiplier: 1)
    arrowBtnsEqualWidthConstraint.identifier = .init("arrowBtnsEqualWidthConstraint")
    arrowBtnsEqualWidthConstraint.isActive = true

    let leftArrowBtnVertCenterConstraint = leftArrowButton.centerYAnchor.constraint(equalTo: oscPlaybackBtnsView.centerYAnchor)
    leftArrowBtnVertCenterConstraint.isActive = true
    let rightArrowBtnVertCenterConstraint = rightArrowButton.centerYAnchor.constraint(equalTo: oscPlaybackBtnsView.centerYAnchor)
    rightArrowBtnVertCenterConstraint.isActive = true
  }

  private func initSpeedLabel() {
    speedLabel.idString = "SpeedLabel"  // helps with debug logging
    speedLabel.translatesAutoresizingMaskIntoConstraints = false
    speedLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
    speedLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    speedLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    speedLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    speedLabel.setContentHuggingPriority(.required, for: .vertical)
    speedLabel.font = NSFont.messageFont(ofSize: 10)
    speedLabel.textColor = .textColor
    speedLabel.alphaValue = 0.75
    speedLabel.isBordered = false
    speedLabel.drawsBackground = false
    speedLabel.isBezeled = false
    speedLabel.isEditable = false
    speedLabel.isSelectable = false
    speedLabel.isEnabled = true
    speedLabel.refusesFirstResponder = true
    speedLabel.alignment = .center
  }

  private func initPlaySliderAndTimeLabelsView() {
    log.verbose("[Load] Init play slider & time labels")
    // - Configure playSliderAndTimeLabelsView
    playSliderAndTimeLabelsView.idString = "PlaySliderAndTimeLabelsView"
    playSliderAndTimeLabelsView.translatesAutoresizingMaskIntoConstraints = false
    playSliderAndTimeLabelsView.userInterfaceLayoutDirection = .leftToRight
    playSliderAndTimeLabelsView.setContentHuggingPriority(.init(249), for: .horizontal)
    playSliderAndTimeLabelsView.setContentCompressionResistancePriority(.init(249), for: .horizontal)
    playSliderAndTimeLabelsView.widthAnchor.constraint(greaterThanOrEqualToConstant: 150.0).isActive = true

    // - Configure subviews

    leftTimeLabel.idString = "PlayPos-LeftTimeLabel"
    leftTimeLabel.alignment = .right
    leftTimeLabel.isBordered = false
    leftTimeLabel.drawsBackground = false
    leftTimeLabel.isEditable = false
    leftTimeLabel.refusesFirstResponder = true
    leftTimeLabel.translatesAutoresizingMaskIntoConstraints = false
    leftTimeLabel.setContentHuggingPriority(.init(501), for: .horizontal)
    leftTimeLabel.setContentCompressionResistancePriority(.init(501), for: .horizontal)

    playSlider.idString = "PlaySlider"
    playSliderCell.pwc = self
    playSlider.target = self
    playSlider.action = #selector(playSliderAction(_:))
    playSlider.minValue = 0
    playSlider.maxValue = 100
    playSlider.translatesAutoresizingMaskIntoConstraints = false
    let widthConstraint = playSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 50)
    widthConstraint.identifier = "PlaySlider-MinWidthConstraint"
    widthConstraint.isActive = true

    playSliderHeightConstraint = playSlider.heightAnchor.constraint(equalToConstant: 20)
    playSliderHeightConstraint.identifier = "PlaySlider-HeightConstraint"
    playSliderHeightConstraint.priority = .init(900)
    playSliderHeightConstraint.isActive = true

    rightTimeLabel.idString = "PlayPos-RightTimeLabel"
    rightTimeLabel.alignment = .left
    rightTimeLabel.isBordered = false
    rightTimeLabel.drawsBackground = false
    rightTimeLabel.isEditable = false
    rightTimeLabel.refusesFirstResponder = true
    rightTimeLabel.translatesAutoresizingMaskIntoConstraints = false
    rightTimeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    rightTimeLabel.setContentCompressionResistancePriority(.init(749), for: .horizontal)
  }

  /// Can be called redundantly without ill effect
  func addSubviewsToPlaySliderAndTimeLabelsView(using oscGeo: ControlBarGeometry) {
    // Assume that if all subviews are inside, the constraints are properly configured as well, & no more work is needed.
    playSliderAndTimeLabelsView.removeAllSubviews()

    playSliderAndTimeLabelsView.subviews = [leftTimeLabel, playSlider, rightTimeLabel]
    // In case these were detached while in a stack view, restore their visibility:
    leftTimeLabel.isHidden = false
    playSlider.isHidden = false
    rightTimeLabel.isHidden = false

    // - Add constraints to subviews

    let hSpacing = oscGeo.hSpacingAroundSliders
    leftTimeLabel.leadingAnchor.constraint(equalTo: playSliderAndTimeLabelsView.leadingAnchor).isActive = true
    playSlider.leadingAnchor.constraint(equalTo: leftTimeLabel.trailingAnchor, constant: hSpacing).isActive = true

    // See also: playSliderHeightConstraint
    playSlider.addConstraintsToFillSuperview(top: 0, bottom: 0)

    playSlider.centerYAnchor.constraint(equalTo: leftTimeLabel.centerYAnchor).isActive = true
    playSlider.centerYAnchor.constraint(equalTo: rightTimeLabel.centerYAnchor).isActive = true

    rightTimeLabel.leadingAnchor.constraint(equalTo: playSlider.trailingAnchor, constant: hSpacing).isActive = true
    rightTimeLabel.trailingAnchor.constraint(equalTo: playSliderAndTimeLabelsView.trailingAnchor).isActive = true
  }

  private func initVolumeView(using oscGeo: ControlBarGeometry) {
    let hSpacing: CGFloat = 2

    // Volume view
    oscVolumeView.idString = "oscVolumeView"
    oscVolumeView.translatesAutoresizingMaskIntoConstraints = false
    oscVolumeView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

    // Mute button
    muteButton.idString = "MuteBtn"
    muteButton.image = Images.volume3
    muteButton.target = self
    muteButton.action = #selector(muteButtonAction(_:))
    muteButton.toolTip = "Toggle mute"
    muteButton.actionSymbolEffectFunc = SymButton.nullEffectFunc
    oscVolumeView.addSubview(muteButton)
    muteButton.translatesAutoresizingMaskIntoConstraints = false
    muteButton.addConstraintsToFillSuperview(leading: 0)
    muteButton.centerYAnchor.constraint(equalTo: oscVolumeView.centerYAnchor).isActive = true
    volumeIconHeightConstraint = muteButton.heightAnchor.constraint(equalToConstant: oscGeo.volumeIconHeight)
    volumeIconHeightConstraint.priority = .init(900)
    volumeIconHeightConstraint.isActive = true
    // Give enough space for widest volume image, and don't change it, so that the volume bar doesn't move
    volumeIconAspectConstraint = muteButton.widthAnchor.constraint(equalTo: muteButton.heightAnchor, multiplier: 1.8)
    volumeIconAspectConstraint.isActive = true

    // Volume slider
    oscVolumeView.addSubview(volumeSlider)
    volumeSlider.cell = volumeSliderCell
    volumeSliderCell.pwc = self
    // For some reason this needs to be set here, instead of in volumeSliderCell init.
    // Otherwise action will continue to be nil...
    volumeSliderCell.hoverTimer.action = volumeSliderCell.refreshVolumeSliderHoverEffect
    volumeSlider.idString = "VolSlider"
    volumeSlider.controlSize = .regular
    volumeSlider.translatesAutoresizingMaskIntoConstraints = false
    volumeSliderWidthConstraint = volumeSlider.widthAnchor.constraint(equalToConstant: oscGeo.volumeSliderWidth)
    volumeSliderWidthConstraint.identifier = "VolSlider-WidthConstraint"
    volumeSliderWidthConstraint.isActive = true
    volumeSlider.addConstraintsToFillSuperview(top: 0, bottom: 0, trailing: 0)
    volumeSlider.leadingAnchor.constraint(equalTo: muteButton.trailingAnchor, constant: hSpacing).isActive = true
    volumeSlider.target = self
    volumeSlider.action = #selector(volumeSliderAction(_:))
  }

}
