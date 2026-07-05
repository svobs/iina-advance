//
//  PWin_LayoutTxSteps.swift
//  iina
//
//  Created by Matt Svoboda on 10/4/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/// This file contains tasks to run in the animation queue, which form a `LayoutTransition`.
/// Each task is a separate `CATransaction`. Some tasks are assumed to have animations (although they can also be run immediately),
/// but others are expected to always be immediate.
extension PlayerWindowController {

  /// --------------------------------------------------------------------------------------------------
  /// PRE TRANSITION
  /// Setup work. Always immediate (i.e., not animated).
  func doPreTransitionWork(_ transition: LayoutTransition) throws {
    let log = Logger.addPreamble(transition.logPreamble(for: .preTransitionSetup), toSubsystem: log)
    log.verbose("Start")
    isAnimatingLayoutTransition = true
    // When playback is paused the display link is stopped in order to avoid wasting energy on
    // needless processing. It must be running while transitioning to/from full screen mode.
    videoView.displayActive()

    /// Some methods where reference `currentLayout` get called as a side effect of the transition animations.
    /// To avoid possible bugs as a result, let's update this at the very beginning.
    currentLayout = transition.outputLayout

    if !player.isRestoring {
      if !transition.outputLayout.isWindowed && transition.inputLayout.isWindowed {
        /// `inputGeometry` may contain the most up-to-date `windowFrame` for `windowedModeGeo`, which `windowedModeGeo` does not have.
        /// Make sure to save it for later use, or later references may use an older version which the user will not expect
        windowedModeGeo = transition.inputGeometry
      } else if !transition.outputLayout.isMusicMode && transition.inputLayout.isMusicMode {
        // Ditto with musicMode
        musicModeGeo = transition.inputGeometry
      }

      /// Set this here because we are setting `currentLayout`
      switch transition.outputLayout.mode {
      case .windowedNormal, .windowedInteractive:
        windowedModeGeo = transition.outputGeometry
      case .fullScreenNormal, .fullScreenInteractive:
        // Close loophole when changing crop to None via FS interactive mode
        windowedModeGeo = windowedModeGeo.clone(video: transition.outputGeometry.video)
      case .musicMode:
        musicModeGeo = transition.outputGeometry
      }
    }

    guard let window = window else { return }

    if transition.isEnteringNativeFullScreen && isWindowInNativeFullScreen {
      log.debug("Already in native full screen! Aborting transition")
      throw IINAError.cancelAnimationTransaction
    }

    // Call this early! Before rebuildPanelConstraints
    if transition.isExitingPiP {
      exitPIP(force: true)
      pip.showOrHidePipOverlayView()
    }

    if transition.outputLayout.isInteractiveMode || transition.outputLayout.isFullScreen {
      // Disable; can cause problems in interactive mode. Set this ASAP because there is sometimes a small delay
      window.isMovableByWindowBackground = false
    }

    if let customTitleBar, transition.isEnteringFullScreen || transition.isTogglingLegacyStyle {
      // Workaround: for some reason, rebuildPanelConstraints() causes custom title bar's title text to lose centering. Just get rid of it now.
      customTitleBar.removeAndCleanUp()
      self.customTitleBar = nil
    }

    // Skip for initial layout: not all panels have been init'd yet.
    if !transition.isWindowInitialLayout {
      rebuildPanelConstraints(transition, stage: .preTransitionSetup)
    }

    // Need to call this here to avoid border being drawn incorrectly during FS transition.
    // But don't want to interfere with special effects such as fade-in
    let opacity = window.contentView?.layer?.opacity ?? -1
    updateWindowBorderAndOpacity(using: transition.outputLayout, windowOpacity: opacity)

    if transition.isEnteringFullScreen {
      /// `windowedModeGeo` should already be kept up to date. Might be hard to track down bugs...
      log.verbose("Entering full screen; priorWindowedGeometry = \(windowedModeGeo)")

      setWindowFloatingOnTop(false, from: transition.inputLayout, updateOnTopStatus: false)

      if transition.isEnteringLegacyFullScreen {
        // Hide traffic light buttons & title during the animation.
        // Do not move this block. It needs to go here.
        hideNativeTitleBarViews(andSetAlpha: true)

        setStyleMaskForLegacyFS(log)

        /// When restoring, it's possible this window is not actually topmost.
        /// Make sure to check before putting it on top.
        refreshKeyWindowStatus()
      }

    } else if transition.isExitingFullScreen {
      // Exiting Full Screen
      fadeableViews.applyVisibility(.hidden, to: osd.additionalInfoView)
    }

    // Interactive mode
    if transition.isEnteringInteractiveMode {
      isPausedPriorToInteractiveMode = player.info.isPaused
      player.pause()
    }

    // Music mode
    if transition.isExitingMusicMode && !transition.inputGeometry.isViewportShown {
      // Video was disabled in music mode, but need to restore it now
      player.setVideoTrackEnabled()
    }

  }

  /// --------------------------------------------------------------------------------------------------
  /// FADE OUT OLD VIEWS
  /// Expected to be animated.
  func fadeOutOldViews(_ transition: LayoutTransition) {
    let outputLayout = transition.outputLayout
    log.verbose("[\(transition.name)] FadeOutOldViews")

    // Title bar & title bar accessories:

    // Hide all title bar items if top bar placement is changing
    if transition.needsToHideTopBar {
      // Native & custom title bar components
      fadeableViews.applyVisibility(.hidden, documentIconButton, titleTextField, customTitleBar?.view)
      miniPlayerTrafficLightsBGView.alphaValue = 0

      // native windowed or full screen
      for button in trafficLightButtons {
        button.alphaValue = 0
      }

      // Hide all title bar accessories (if needed):
      leadingTitleBarAccessoryView.alphaValue = 0
      trailingTitleBarAccessoryView.alphaValue = 0

    } else {
      /// We may have gotten here in response to one of these buttons' visibility being toggled in the prefs,
      /// so we need to allow for showing/hiding these individually.
      /// Setting `.isHidden = true` for these icons visibly messes up their layout.
      /// So just set alpha value for now, and hide later in `updateHiddenViewsAndConstraints()`
      if outputLayout.leadingSidebarToggleButton == .hidden {
        leadingSidebarToggleButton.alphaValue = 0
        // Match behavior for custom title bar's copy:
        customTitleBar?.leadingSidebarToggleButton.alphaValue = 0
      }
      if outputLayout.trailingSidebarToggleButton == .hidden {
        trailingSidebarToggleButton.alphaValue = 0
        customTitleBar?.trailingSidebarToggleButton.alphaValue = 0
      }

      let onTopButtonVisibility = transition.outputLayout.computeOnTopButtonVisibility(isOnTop: isOnTop)
      if onTopButtonVisibility == .hidden {
        onTopButton.alphaValue = 0

        if let customTitleBar {
          customTitleBar.onTopButton.alphaValue = 0
        }
      }
    }

    if transition.inputLayout.hasFloatingOSC && !outputLayout.hasFloatingOSC {
      // Hide floating OSC
      fadeableViews.applyVisibility(outputLayout.controlBarFloating, to: controlBarFloating.view)
    }

    if transition.isTogglingMusicMode || transition.isTogglingInteractiveMode {
      hideOSD()
    }

    if !transition.outputGeometry.shouldHaveAdditionalInfo {
      fadeableViews.applyVisibility(.hidden, to: osd.additionalInfoView)
    }


    // Change blending modes
    if transition.isTogglingFullScreen {
      let fsLayout = transition.inputLayout.isFullScreen ? transition.inputLayout : transition.outputLayout
      /// Need to use `.withinWindow` during animation or else panel tint can change in odd ways
      updatePanelBlendingModes(to: fsLayout)
    }

    if transition.isExitingInteractiveMode, let cropController = self.cropSettingsView {
      cropController.view.alphaValue = 0
      cropController.view.isHidden = true
      cropController.cropBoxView.isHidden = true
      cropController.cropBoxView.alphaValue = 0
      // Need to remove these ASAP. Their constraints can interfere with window resize animation (e.g. during crop).
      removeCropControls()
    }

    // Hide seek preview for mode transitions or large animations
    let isChangingMode = transition.outputLayout.mode != transition.inputLayout.mode
    if isChangingMode || transition.isTopBarPlacementOrStyleChanging
        || transition.isBottomBarPlacementOrStyleChanging || transition.isOpeningOrClosingAnySidebar {
      hideSeekPreviewImmediately()
    }

    if outputLayout.isInteractiveMode || outputLayout.isMusicMode {
      // Fade out OSC
      if !outputLayout.enableOSC || outputLayout.controlBarGeo.isTwoRowBarOSC, oscOneRowView.superview != nil {
        log.verbose("[\(transition.name)] Removing oscOneRowView from window")
        oscOneRowView.dispose()
      }
      if !outputLayout.enableOSC || !outputLayout.controlBarGeo.isTwoRowBarOSC, oscTwoRowView.superview != nil  {
        log.verbose("[\(transition.name)] Removing oscTwoRowView from window")
        oscTwoRowView.dispose()
      }
    }

    if transition.isTogglingNativeFullScreen {
      // (Kludge) Do this now because this step is duration=0.
      applyPWinGeometry(transition.closeOldPanelsGeometry!, updateViewportConstraints: false)
    }
  }

  /// --------------------------------------------------------------------------------------------------
  /// CLOSE OLD PANELS
  /// This step is not always executed (e.g.: not for initial layout or for full screen toggle).
  /// Expected to be animated.
  func closeOldPanels(_ transition: LayoutTransition) {
    assert(!transition.isWindowInitialLayout)
    let log = Logger.addPreamble(transition.logPreamble(for: .closeOldPanels), toSubsystem: log)
    let outputLayout = transition.outputLayout
    let isClosingBarOSC = transition.isClosingBarOSC
    let isOpeningBarOSC = transition.isOpeningBarOSCFromZero
    // Special case for exiting native FS's unique animation
    log.verbose("Start: title_H=\(outputLayout.titleBarHeight) topOSC_H=\(outputLayout.topOSCHeight) isClosingBarOSC=\(isClosingBarOSC.yn) isOpeningBarOSC=\(isOpeningBarOSC.yn) hasControlBar=\(outputLayout.hasControlBar.yn)")

    if transition.isEnteringNativeFullScreen {
      // - Auto-hide menu bar & Dock. This may result in a hiccup if these areas are still shown when the
      //   window expands over it, so do it just before the animation starts.
      // - Also note that this is not required when entering native FS, but leaving it out results in terrible
      //   slowdown on MacOS 26 (Tahoe).
      // - Seems we need to call this prior to `rebuildPanelConstraints`
      updatePresentationOptions(windowIsFS: true)
    }

    // - OSC Subviews
    // TODO: incorporate controlBarGeo into closeOldPanelsGeometry for cleaner code
    if isOpeningBarOSC || isClosingBarOSC {
      // Shrink all the buttons vertically to create cool animated effect.
      // Don't worry about horizontal.
      for toolbarItem in oscToolbarView.views {
        (toolbarItem as! OSCToolbarButton).setStyle(iconSize: 0, iconSpacing: 0)
      }

      // Volume icon
      volumeIconHeightConstraint.animateToConstant(0)
      // Play & arrow buttons
      playBtnHeightConstraint.animateToConstant(0)
      arrowBtnWidthConstraint.animateToConstant(0)
      oscPlaybackBtnsHeightConstraint.animateToConstant(0)
      playSliderHeightConstraint.animateToConstant(0)

    } else if outputLayout.hasControlBar {
      // Reduce size of icons if they are smaller. This is needed to look pleasant when panels are also shrinking.
      let oldGeo = transition.inputLayout.controlBarGeo
      let newGeo = outputLayout.controlBarGeo

      // - Vertical

      if oldGeo.volumeIconHeight > newGeo.volumeIconHeight {
        volumeIconHeightConstraint.animateToConstant(newGeo.volumeIconHeight)
      }

      if oldGeo.volumeSliderWidth > newGeo.volumeSliderWidth {
        volumeSliderWidthConstraint.animateToConstant(newGeo.volumeSliderWidth)
      }

      if oldGeo.playIconSize > newGeo.playIconSize {
        playBtnHeightConstraint.animateToConstant(newGeo.playIconSize)
      }

      if oldGeo.fullIconHeight > newGeo.fullIconHeight {
        oscPlaybackBtnsHeightConstraint.animateToConstant(newGeo.fullIconHeight)
      }

      if transition.inputLayout.controlBarGeo.playSliderHeight > outputLayout.controlBarGeo.playSliderHeight {
        playSliderHeightConstraint.animateToConstant(outputLayout.controlBarGeo.playSliderHeight)
      }

      // - Horizontal

      if oldGeo.arrowIconHeight > newGeo.arrowIconHeight {
        arrowBtnWidthConstraint.animateToConstant(newGeo.arrowIconWidth)
      }

      if oldGeo.totalPlayControlsWidth > newGeo.totalPlayControlsWidth {
        oscPlaybackBtnsWidthConstraint.animateToConstant(newGeo.totalPlayControlsWidth)
      }

      // `leftArrowCenterXOffset` is always negative! Need to reverse sign.
      if oldGeo.leftArrowCenterXOffset < newGeo.leftArrowCenterXOffset {
        leftArrowBtn_CenterXOffsetConstraint.animateToConstant(newGeo.leftArrowCenterXOffset)
      }

      if oldGeo.rightArrowCenterXOffset > newGeo.rightArrowCenterXOffset {
        rightArrowBtn_CenterXOffsetConstraint.animateToConstant(newGeo.rightArrowCenterXOffset)
      }

      let toolSize = min(newGeo.toolIconSize, oldGeo.toolIconSize)
      let toolSpacing = min(newGeo.toolIconSpacing, oldGeo.toolIconSpacing)
      for toolbarItem in oscToolbarView.views {
        (toolbarItem as! OSCToolbarButton).setStyle(iconSize: toolSize, iconSpacing: toolSpacing)
      }
      updateToolbarHStack(iconSpacing: toolSpacing)
    }

    rebuildPanelConstraints(transition, stage: .closeOldPanels)

    // - Middle Geometry
    if let closeOldPanelsGeo = transition.closeOldPanelsGeometry {
      // Need to call this for initial layout also, or if toggling video:
      updateMusicModeButtonOffsets(using: closeOldPanelsGeo)
    }
  }


  /// --------------------------------------------------------------------------------------------------
  /// MIDPOINT: MOVE & RESIZE VIDEO FRAME
  /// Only executed for certain transitions (windowed mode <-> either music mode or interactive mode).
  /// All bars are expected to be closed at this point, leaving only the viewportView.
  /// This animation moves & resizes the video frame for a nice effect.
  /// May execute either before or after `updateHiddenViewsAndConstraints`.
  func moveAndScaleVideoFrame(_ transition: LayoutTransition) {
    rebuildPanelConstraints(transition, stage: .moveAndScale)
  }


  /// --------------------------------------------------------------------------------------------------
  /// MIDPOINT: UPDATE INVISIBLES
  /// This is needed as its own transaction in case constraints need to be replaced or views need to be added or replaced in the window such that
  /// there is not an appropriate animation which should be seen.
  func updateHiddenViewsAndConstraints(_ transition: LayoutTransition) {
    guard let window = window, let contentView = window.contentView else { return }
    let log = Logger.addPreamble(transition.logPreamble(for: .midTransitionHiddenUpdates), toSubsystem: log)
    let outputLayout = transition.outputLayout
    log.verbose("Start")

    fadeableViews.clearFadeableSets()

    let oldAppearance = window.effectiveAppearance
    let targetWindowAppearance = AppDelegate.shared.targetWindowAppearance
    let appearanceDidChange = oldAppearance != targetWindowAppearance

    // Do this here so that (1) BarRenderer regenerates close enough to mid-animation (so bar thickness changes pleasantly),
    // & (2) window.appearance is updated before updating styling of any window views!
    if let screen = window.screen {
      applyThemeMaterial(using: transition.outputLayout, window, screen)
    } else {
      // In some rare cases, window might be off screen its frame size is zero (the latter can happen when exiting music mode with no
      // playlist & no video), in which case window.screen will be nil. Just log & continue. In principle, applyThemeMaterial will still
      // be called via windowDidChangeScreen.
      log.verbose("Skipped applyThemeMaterial due to missing window or screen")
    }

    switch transition.outputLayout.mode {
    case .fullScreenInteractive, .windowedInteractive:
      // Show cursor always in these modes
      setCursorToNormalAlwaysShown()
    case .windowedNormal, .fullScreenNormal, .musicMode:
      // TODO: hide cursor now if configured to always hide
      break
    }

    if !transition.isTogglingFullScreen, transition.isTogglingLegacyStyle {

      switch transition.outputLayout.mode {
      case .windowedNormal, .windowedInteractive, .musicMode:
        // Transitioning to/from native & windowed modes (but not while toggling FS)
        if transition.outputLayout.isLegacyStyle {
          // Set legacy style
          setStyleForLegacyWindowed(log)

          /// if `isTogglingLegacyStyle==true && isExitingFullScreen==true`, we are toggling out of legacy FS
          /// -> don't change `styleMask` to `.titled` here - it will look bad if screen has camera housing. Change at end of animation
        } else {
          // Native style
          setStyleMaskForNativeWindowed(log)
          // Hide initially, so they can fade in
          hideNativeTitleBarViews(andSetAlpha: true)
        }

        if transition.outputLayout.isMusicMode {
          miniPlayer.hideControls()
        }
      case .fullScreenInteractive, .fullScreenNormal:
        break
      }

    }

    if transition.isOpeningViewport {
      videoView.displayActive()

      // Show default album art if no video track selected
      if player.info.shouldShowDefaultArt == true {
        updateDefaultArtVisibility(to: true)
      }
      pip.showOrHidePipOverlayView()
    }

    if !transition.isExitingFullScreen && transition.needsMpvKeepaspectUpdate {
      if transition.isWindowInitialLayout {
        // Do not use synchronous version - it can deadlock with the sync call in openPlayerWindow()
        player.updateMpvKeepaspectWindowAsync()
      } else {
        // Block until done for a better animation
        player.updateMpvKeepaspectWindowSynchronously()
      }
    }

    if transition.isSidebarsStyleChanging {
      rebuildLeadingSidebarView(transition.outputLayout.sidebarsColorScheme)
      rebuildTrailingSidebarView(transition.outputLayout.sidebarsColorScheme)
    }

    // - Bottom Bar

    // Unclear why bottomBar.view sometimes fails to update its appearance along with the other views.
    // Workaround: force redraw when appearanceDidChange
    let needsBottomBarRebuild = transition.isWindowInitialLayout || appearanceDidChange
    || transition.isBottomBarPlacementOrStyleChanging || transition.isBottomBarOpening
    if needsBottomBarRebuild {
      let bottomBarAppearance = outputLayout.bottomBarAppearance(targetWindowAppearance: targetWindowAppearance)
      bottomBarAppearance.performAsCurrentDrawingAppearance { [self] in
        bottomBar.rebuildBottomBarView(colorScheme: transition.outputLayout.oscColorScheme, log)
      }
      /// It will be added to window.contentView & its Z order corrected in `rebuildPanelConstraints`.
    }

    /// Show dividing line only for `.outsideViewport` bottom bar. Don't show in music mode as it doesn't look good
    let showBottomBarTopBorder = (outputLayout.bottomBarPlacement == .outsideViewport) || (outputLayout.hasBottomOSC && (outputLayout.oscColorScheme == .visualEffectView))
    bottomBar.topBorder.isHidden = !showBottomBarTopBorder

    /// These should all be either 0 height or unchanged from `transition.inputLayout`.
    /// But may need to add or remove from fadeableViews
    fadeableViews.applyVisibility(outputLayout.bottomBarView, to: bottomBar.view)

    osd.rebuildOSDView()
    osd.rebuildAdditionalInfoView()

    // - Top Bar

    let topBarAppearance = outputLayout.topBarAppearance(targetWindowAppearance: targetWindowAppearance)
    topBarAppearance.performAsCurrentDrawingAppearance { [self] in
      let needsTopBarRebuild = transition.isWindowInitialLayout || appearanceDidChange
      || (transition.inputLayout.topBarColorScheme != outputLayout.topBarColorScheme)
      // Unlike the other panels, do not set the topBar's appearance explicitly.
      // It will inherit from window.contentView's appearance, which must be set to the desired topBar
      // appearance to ensure that the native title bar's appearance is set correctly.
      topBar.rebuildTopBarViewIfNeeded(targetLayout: outputLayout, force: needsTopBarRebuild, log)

      let topBarColorScheme = outputLayout.topBarColorScheme
      topBar.bottomBorder.isHidden = topBarColorScheme != .visualEffectView

      // Colors for native controls. Do this after applying theme!
      if outputLayout.leadingSidebarToggleButton.isShowable {
        leadingSidebarToggleButton.setColors(for: topBarColorScheme, .titleBarButton)
        leadingSidebarToggleButton.needsDisplay = true
      }
      if outputLayout.trailingSidebarToggleButton.isShowable {
        trailingSidebarToggleButton.setColors(for: topBarColorScheme, .titleBarButton)
        trailingSidebarToggleButton.needsDisplay = true
      }
      onTopButton.setColors(for: topBarColorScheme, .titleBarButton)
      onTopButton.needsDisplay = true

      if let titleTextField {
        titleTextField.addShadow(topBarColorScheme, .titleText)
        titleTextField.needsDisplay = true
      }

      // Colors for custom title bar controls
      customTitleBar?.setColors(topBarColorScheme: topBarColorScheme)
    }

    log.verbose("TopBarAppearance: target=\(topBarAppearance.isDark ? "DARK" : "LIGHT") "
                + "actual=\(topBar.view.effectiveAppearance.isDark ? "DARK" : "LIGHT")")

    rebuildPanelConstraints(transition, stage: .midTransitionHiddenUpdates)

    // - - Title bar views

    // For some reason, transitioning to/from interactive mode messes up the alignment of CustomTitleBar's title text.
    // Removing the whole CustomTitleBar view hierarchy & recreating it seems to be a valid workaround.
    if outputLayout.titleBar == .hidden || transition.isTopBarPlacementOrStyleChanging || (transition.inputLayout.mode != transition.outputLayout.mode) {
      if !transition.isTogglingNativeFullScreen {
        hideNativeTitleBarViews(andSetAlpha: true)
      }

      if let customTitleBar {
        customTitleBar.removeAndCleanUp()
        self.customTitleBar = nil
      }
    }

    // Allow for showing/hiding each button individually
    let onTopButtonVisibility = transition.outputLayout.computeOnTopButtonVisibility(isOnTop: isOnTop)

    if outputLayout.titleBar.isShowable, transition.outputLayout.isLegacyStyle {
      topBarAppearance.performAsCurrentDrawingAppearance { [self] in
        let legacyTitleBar: CustomTitleBarViewController
        // Custom title bar
        if let customTitleBar {
          legacyTitleBar = customTitleBar
        } else {
          legacyTitleBar = CustomTitleBarViewController(transition.outputLayout, self)
          customTitleBar = legacyTitleBar

          // Prep views to fade in later
          legacyTitleBar.view.alphaValue = 0
          for btn in legacyTitleBar.trafficLightButtons {
            btn.alphaValue = 0
            btn.isHidden = true
          }
        }

        if transition.outputLayout.mode == .musicMode {
          legacyTitleBar.addViewTo(superview: contentView)
        } else {
          legacyTitleBar.addViewTo(superview: topBar.titleBarView)
        }
        fadeableViews.applyOnlyIfHidden(outputLayout.leadingSidebarToggleButton, to: legacyTitleBar.leadingSidebarToggleButton)
        fadeableViews.applyOnlyIfHidden(outputLayout.trailingSidebarToggleButton, to: legacyTitleBar.trailingSidebarToggleButton)
        fadeableViews.applyOnlyIfHidden(onTopButtonVisibility, to: legacyTitleBar.onTopButton)
        fadeableViews.applyOnlyIfHidden(outputLayout.titleIconAndText, to: legacyTitleBar.titleIconAndTextStackView)
      }
    }

    fadeableViews.applyOnlyIfHidden(outputLayout.leadingSidebarToggleButton, to: leadingSidebarToggleButton)
    fadeableViews.applyOnlyIfHidden(outputLayout.trailingSidebarToggleButton, to: trailingSidebarToggleButton)
    fadeableViews.applyOnlyIfHidden(onTopButtonVisibility, to: onTopButton)
    fadeableViews.applyOnlyIfHidden(outputLayout.titleIconAndText, documentIconButton, titleTextField)
    if outputLayout.mode != .musicMode {
      miniPlayerTrafficLightsBGView.isHidden = true
    }

    // - Music mode: entering or continuing)

    miniPlayer.loadIfNeeded()
    pip.showOrHidePipOverlayView()

    if transition.outputLayout.isMusicMode && (!bottomBar.view.subviews.contains(miniPlayer.view) || transition.isWindowInitialLayout || !transition.inputLayout.isMusicMode) {
      // If initial layout, bottomBar has been rebuilt, so we need to repopulate it
      log.verbose("Adding miniPlayer view to bottomBar.view")
      bottomBar.contentView.addSubview(miniPlayer.view, positioned: .below, relativeTo: bottomBar.topBorder)
      miniPlayer.view.addAllConstraintsToFillSuperview()

      // Now confiure various subviews
      playSliderCell.knobHeight = Constants.Slider.musicModeKnobHeight

      // move playback buttons
      if !miniPlayer.playbackBtnsWrapperView.subviews.contains(oscPlaybackBtnsView) {
        miniPlayer.playbackBtnsWrapperView.addSubview(oscPlaybackBtnsView)
        miniPlayer.playbackBtnsWrapperView.centerXAnchor.constraint(equalTo: oscPlaybackBtnsView.centerXAnchor).isActive = true
        miniPlayer.playbackBtnsWrapperView.centerYAnchor.constraint(equalTo: oscPlaybackBtnsView.centerYAnchor).isActive = true
      }

      if !miniPlayer.volumeSliderView.subviews.contains(oscVolumeView) {
        miniPlayer.volumeSliderView.addSubview(oscVolumeView)
        oscVolumeView.centerYAnchor.constraint(equalTo: miniPlayer.volumeSliderView.centerYAnchor).isActive = true
        volumeSlider.leadingAnchor.constraint(equalTo: miniPlayer.volumeSliderView.leadingAnchor, constant: 40).isActive = true
        miniPlayer.volumeSliderView.trailingAnchor.constraint(equalTo: volumeSlider.trailingAnchor, constant: 40).isActive = true
        muteButton.target = self
        muteButton.action = #selector(muteButtonAction(_:))
      }

      // Update music mode UI
      updateTitle()

      // move playback position slider & time labels
      let wasAlreadyPresent = miniPlayer.positionSliderWrapperView.subviews.contains(playSliderAndTimeLabelsView)
      miniPlayer.positionSliderWrapperView.addSubview(playSliderAndTimeLabelsView)
      addSubviewsToPlaySliderAndTimeLabelsView(using: transition.outputLayout.controlBarGeo)
      if !wasAlreadyPresent {
        playSliderAndTimeLabelsView.addAllConstraintsToFillSuperview()
        playSliderAndTimeLabelsView.isHidden = false
      }

    } else if transition.isExitingMusicMode {
      // If exiting music mode, need to restore views early in this step
      log.verbose("Cleaning up for music mode exit")
      miniPlayer.loadIfNeeded()
      miniPlayer.view.removeFromSuperview()

      // Make sure to reset constraints for OSD
      miniPlayer.hideControls()
    }

    if transition.outputLayout.isMusicMode {
      miniPlayer.addPlaylistViewIfMissing()

      // FIXME: refactor to put most of this into `rebuildPanelConstraints`
      if !transition.outputGeometry.isViewportShown && !transition.outputLayout.isInPiP {
        viewportView.removeViewportConstraints()
        videoView.removeFromSuperview()
        viewportView.removeSpacers()
        updateDefaultArtVisibility(to: false)  // hide defaultAlbumArt

        player.setVideoTrackDisabled()
      }
    }

    // - OSC

    // [Re-]add OSC:
    if outputLayout.enableOSC {
      assert(!outputLayout.isMusicMode)
      let oscAppearance = outputLayout.oscBarAppearance(targetWindowAppearance: targetWindowAppearance)
      let newGeo = outputLayout.controlBarGeo
      log.verbose("Setting up OSC: pos=\(outputLayout.oscPosition) musicMode=\(outputLayout.isMusicMode.yn) playIconSize=\(newGeo.playIconSize) playIconSpacing=\(newGeo.playIconSpacing)")

      rebuildOSCToolbar(transition, .midTransitionHiddenUpdates, hasColorChange: appearanceDidChange || transition.isOSCStyleChanging)

      switch outputLayout.oscPosition {
      case .top:
        currentControlBar = topBar.controlBarTop

        let oscContentView: NSView
        if newGeo.isTwoRowBarOSC {
          oscContentView = oscTwoRowView
          log.verbose("Adding subviews to oscTwoRowView for top bar, topBarHeight=\(outputLayout.topBarHeight)")
          oscTwoRowView.updateSubviews(from: self, newGeo)
        } else {
          oscContentView = oscOneRowView
          log.verbose("Adding subviews to oscOneRowView for top bar")
          oscOneRowView.updateSubviews(from: self, newGeo)
        }
        oscContentView.appearance = oscAppearance

        if !topBar.controlBarTop.subviews.contains(oscContentView) {
          log.verbose("Adding \(oscContentView.idString) to topBarView")
          topBar.controlBarTop.addSubview(oscContentView, positioned: .below, relativeTo: topBar.bottomBorder)
          // Match leading/trailing spacing of title bar icons above
          oscContentView.addConstraintsToFillSuperview(top: 0, bottom: 0,
                                                       leading: Constants.titleBarIconHSpacing,
                                                       trailing: Constants.titleBarIconHSpacing)
        }

      case .bottom:
        currentControlBar = bottomBar.view

        let oscContentView: NSView
        if newGeo.isTwoRowBarOSC {
          oscContentView = oscTwoRowView
          log.verbose("Adding subviews to oscTwoRowView for bottom bar, bottomBarHeight=\(outputLayout.bottomBarHeight)")
          oscTwoRowView.updateSubviews(from: self, newGeo)
        } else {
          oscContentView = oscOneRowView
          log.verbose("Adding subviews to oscOneRowView for bottom bar")
          oscOneRowView.updateSubviews(from: self, newGeo)
        }
        oscContentView.appearance = oscAppearance

        if !bottomBar.contentView.subviews.contains(oscContentView) {
          log.verbose("Adding \(oscContentView.idString) to bottomBar.view")
          bottomBar.contentView.addSubview(oscContentView, positioned: .below, relativeTo: bottomBar.topBorder)
          // Match leading/trailing spacing of title bar icons above
          oscContentView.addConstraintsToFillSuperview(top: 0, bottom: 0,
                                                       leading: Constants.titleBarIconHSpacing,
                                                       trailing: Constants.titleBarIconHSpacing)
        }

      case .floating:
        controlBarFloating.rebuildView()
        currentControlBar = controlBarFloating.view
        addFloatingControlBarToViewportView()
        controlBarFloating.updatePreferredBarWidth()

        let oscAppearance = outputLayout.oscColorScheme.hasClearBG ? NSAppearance(iinaTheme: .dark)! : targetWindowAppearance
        controlBarFloating.view.appearance = oscAppearance

        let floatingUpperView = controlBarFloating.topRowView
        if !floatingUpperView.views.contains(oscToolbarView) {
          floatingUpperView.addView(oscToolbarView, in: .trailing)
          floatingUpperView.setVisibilityPriority(.detachEarlier, for: oscToolbarView)
          oscToolbarView.isHidden = false
        }
      }

      seekPreview.updateLabelFont(using: outputLayout)

    } else if outputLayout.isMusicMode {

      // Music mode always has a control bar
      currentControlBar = miniPlayer.musicModeControlBarView

      seekPreview.updateLabelFont(using: outputLayout)

    } else {  // No OSC & not music mode
      currentControlBar = nil
    }

    if !outputLayout.hasFloatingOSC {
      // Not floating OSC!
      controlBarFloating.removeFloatingControlBar()
      updateSpeedLabelFont(for: transition)
    }

    if outputLayout.hasControlBar {
      // Has OSC, or music mode
      let newGeo = outputLayout.controlBarGeo

      // Update arrow buttons layout (but not width: that will be animated in the next step)
      leftArrowButton.replaceSymbolImage(with: newGeo.leftArrowImage)
      rightArrowButton.replaceSymbolImage(with: newGeo.rightArrowImage)

      switch newGeo.arrowButtonAction {
      case .playlist, .speed, .unused:
        leftArrowButton.actionSymbolEffectFunc = SymButton.bounceEffectFunc(_:)
        rightArrowButton.actionSymbolEffectFunc = SymButton.bounceEffectFunc(_:)
      case .seek:
        leftArrowButton.actionSymbolEffectFunc = SymButton.rotateEffectFunc(_:)
        rightArrowButton.actionSymbolEffectFunc = SymButton.rotateEffectFunc(_:)
      }

      rightTimeLabel.mode = Preference.bool(for: .showRemainingTime) ? .remaining : .duration

      let hideArrowBtns = !newGeo.hasArrowButtons
      leftArrowButton.isHidden = hideArrowBtns
      rightArrowButton.isHidden = hideArrowBtns

      let timeLabelFont: NSFont = newGeo.timeLabelFont
      leftTimeLabel.font = timeLabelFont
      rightTimeLabel.font = timeLabelFont
      oscTwoRowView.timeSlashLabel.font = timeLabelFont

      let sliderKnobWidth = newGeo.sliderKnobWidth
      let sliderKnobHeight = newGeo.sliderKnobHeight
      playSliderCell.knobWidth = sliderKnobWidth
      playSliderCell.knobHeight = sliderKnobHeight
      playSliderCell.abLoopA.updateKnobImage(to: .loopKnob)
      playSliderCell.abLoopB.updateKnobImage(to: .loopKnob)

      let volumeSliderCell = volumeSliderCell
      volumeSliderCell.knobWidth = sliderKnobWidth
      volumeSliderCell.knobHeight = sliderKnobHeight
      volumeSlider.needsDisplay = true

      if appearanceDidChange || transition.isWindowInitialLayout || transition.isOSCPositionChanging || transition.isOSCStyleChanging ||
          (transition.inputLayout.controlBarGeo.barHeight != transition.outputLayout.controlBarGeo.barHeight) {
        let oscColorScheme = transition.outputLayout.oscColorScheme
        log.verbose("Updating OSC colors: hasClearBG=\(oscColorScheme.hasClearBG.yn) colorScheme=\(oscColorScheme.description)")

        playButton.setColors(for: oscColorScheme)
        leftArrowButton.setColors(for: oscColorScheme)
        rightArrowButton.setColors(for: oscColorScheme)
        muteButton.setColors(for: oscColorScheme)
        leftTimeLabel.setColors(oscColorScheme, .text)
        rightTimeLabel.setColors(oscColorScheme, .text)
        oscTwoRowView.timeSlashLabel.setColors(oscColorScheme, .text)

        if oscColorScheme.hasClearBG {
          oscKnobRenderer.mainKnobColor = NSColor.controlForClearBG
        } else {
          oscKnobRenderer.mainKnobColor = NSColor.mainSliderKnob
        }

        // Invalidate all cached knob images so they are rebuilt with new style
        oscKnobRenderer.invalidateCachedKnobs()

        if outputLayout.isMusicMode {
          miniPlayer.setColors(oscColorScheme)
        }
      }
    }

    if transition.isWindowInitialLayout || transition.isOpeningAnySidebar
        || (transition.inputLayout.sidebarsColorScheme != transition.outputLayout.sidebarsColorScheme) {
      if quickSettingView.isViewLoaded {
        quickSettingView.setColors(outputLayout)
      }
      if playlistView.isViewLoaded {
        playlistView.setColors(outputLayout)
      }
    }

    // - Interactive mode

    if transition.outputLayout.isInteractiveMode {
      let prevSelectedRect: NSRect?
      if let cropController = self.cropSettingsView {
        prevSelectedRect = cropController.cropBoxView.selectedRect
      } else {
        prevSelectedRect = nil
      }

      removeCropControls()

      // Need videoView to have superview before adding shadow
      videoView.addShadowForInteractiveMode()

      // Entering interactive mode
      setEmptySpaceColor(to: Constants.Color.interactiveModeBackground)

      // Add crop settings at bottom
      let cropController = self.cropSettingsView ?? transition.outputLayout.interactiveMode!.viewController()
      cropController.pwc = self
      self.cropSettingsView = cropController
      bottomBar.contentView.addSubview(cropController.view, positioned: .below, relativeTo: bottomBar.topBorder)
      cropController.view.addAllConstraintsToFillSuperview()
      cropController.view.alphaValue = 0
      let videoSizeRaw = transition.outputGeometry.video.videoSizeRaw
      // Hide for now, to prepare for a nice fade-in animation
      cropController.cropBoxView.isHidden = true
      cropController.cropBoxView.alphaValue = 0
      cropController.cropBoxView.needsLayout = true

      /// `selectedRect` should be subrect of`actualSize`
      let selectedRect: NSRect
      if let prevSelectedRect {
        selectedRect = prevSelectedRect
      } else {
        switch currentLayout.interactiveMode {
        case .crop:
          if let prevCropFilter = player.info.videoFiltersDisabled[Constants.FilterLabel.crop] {
            selectedRect = prevCropFilter.cropRect(origVideoSize: videoSizeRaw, flipY: true)
            log.verbose("Setting crop box selectedRect from prevFilter: \(selectedRect)")
          } else {
            selectedRect = NSRect(origin: .zero, size: videoSizeRaw)
            log.verbose("Setting crop box selectedRect to default whole videoSize: \(selectedRect)")
          }
        case .freeSelecting, .none:
          selectedRect = .zero
        }
      }
      cropController.cropBoxView.selectedRect = selectedRect

    } else if transition.isExitingInteractiveMode {
      // Exiting interactive mode
      setEmptySpaceColor(to: Constants.Color.defaultWindowBackgroundColor)
      removeCropControls()
    }

    if transition.outputGeometry.mode.isInteractiveMode {
      if cropSettingsView != nil {
        let videoSizeRaw = transition.outputGeometry.video.videoSizeRaw
        addOrReplaceCropBoxSelection(rawVideoSize: videoSizeRaw)
      } else if !player.isRestoring, player.info.isFileLoaded, !player.info.isVideoTrackSelected {
        // if restoring, there will be a brief delay before getting player info, which is ok
        Utility.showAlert("no_video_track")
      }
    }

    // So that panels toggling between "inside" and "outside" don't change until they need to (but FS is OK)
    if !transition.isTogglingFullScreen {
      updatePanelBlendingModes(to: outputLayout)
    }

    // Other misc views
    _updateVolumeUI()
    playSlider.needsDisplay = true

    log.verbose("Done")
  }  /// end `updateHiddenViewsAndConstraints`


  /// --------------------------------------------------------------------------------------------------
  /// OPEN PANELS & FINALIZE OFFSETS
  func openNewPanelsAndFinalizeOffsets(_ transition: LayoutTransition) {
    let outputLayout = transition.outputLayout
    let log = Logger.addPreamble(transition.logPreamble(for: .openNewPanels), toSubsystem: log)
    log.verbose("Start: TitleBar_H=\(outputLayout.titleBarHeight) TopOSC_H=\(outputLayout.topOSCHeight)")

    if transition.isEnteringLegacyFullScreen {
      // Call this here in case there was no `.extraAnimationBeforeOpenNewPanels` stage
      updatePresentationOptions(windowIsFS: true)
    } else if transition.isExitingNativeFullScreen {
      /// Seems this needs to be called before the final `setFrame` call, or else the window can end up incorrectly sized at the end.
      /// Do this also for native FS. It will kick off an independent animation which will last about as long as this step's
      /// animation.
      updatePresentationOptions(windowIsFS: false)
    }

    rebuildPanelConstraints(transition, stage: .openNewPanels)

    // Need to call this for initial layout also, or if toggling video:
    updateMusicModeButtonOffsets(using: transition.outputGeometry)

    if outputLayout.hasControlBar {
      // Increase size of icons if they are larger
      let newGeo = outputLayout.controlBarGeo

      // Weaken constraints temporarily
      leftArrowBtn_CenterXOffsetConstraint.priority = .defaultLow
      rightArrowBtn_CenterXOffsetConstraint.priority = .defaultLow
      oscPlaybackBtnsHeightConstraint.priority = .defaultLow
      oscPlaybackBtnsWidthConstraint.priority = .defaultLow

      playSliderHeightConstraint.animateToConstant(newGeo.playSliderHeight)

      volumeIconHeightConstraint.animateToConstant(newGeo.volumeIconHeight)
      volumeSliderWidthConstraint.animateToConstant(newGeo.volumeSliderWidth)
      log.trace("TotalPlayControls.width=\(newGeo.totalPlayControlsWidth) leftArrowXOffset=\(newGeo.leftArrowCenterXOffset) rightArrowXOffset=\(newGeo.rightArrowCenterXOffset)")

      arrowBtnWidthConstraint.animateToConstant(newGeo.arrowIconWidth)
      playBtnHeightConstraint.animateToConstant(newGeo.playIconSize)
      oscPlaybackBtnsWidthConstraint.animateToConstant(newGeo.totalPlayControlsWidth)
      oscPlaybackBtnsHeightConstraint.animateToConstant(newGeo.fullIconHeight)
      leftArrowBtn_CenterXOffsetConstraint.animateToConstant(newGeo.leftArrowCenterXOffset)
      rightArrowBtn_CenterXOffsetConstraint.animateToConstant(newGeo.rightArrowCenterXOffset)

      // Finalize
      leftArrowBtn_CenterXOffsetConstraint.priority = .required
      rightArrowBtn_CenterXOffsetConstraint.priority = .required
      oscPlaybackBtnsWidthConstraint.priority = .required
      oscPlaybackBtnsHeightConstraint.priority = .required

      // Animate toolbar icons to full size now
      for toolbarItem in oscToolbarView.views {
        (toolbarItem as! OSCToolbarButton).setStyle(using: transition.outputLayout)
      }
      updateToolbarHStack(iconSpacing: newGeo.toolIconSpacing)
      if outputLayout.hasFloatingOSC {
        // Animate constraints update as we open the panel
        // Must execute this *after* rebuildPanelConstraints: needs constraints to have been added
        controlBarFloating.addOrUpdateMarginConstraints(for: transition.outputLayout)
        // Wait until now to set up floating OSC views. Doing this in prev or next task while animating results in visibility bugs
        let topRowView = controlBarFloating.topRowView
        if transition.isWindowInitialLayout || !transition.inputLayout.hasFloatingOSC {
          controlBarFloating.topRowView.addView(oscPlaybackBtnsView, in: .center)
          // There sweems to be a race condition when adding to these StackViews.
          // Sometimes it still contains the old view, and then trying to add again will cause a crash.
          // Must check if it already contains the view before adding.
          if !topRowView.views(in: .leading).contains(oscVolumeView) {
            topRowView.addView(oscVolumeView, in: .leading)
            oscVolumeView.isHidden = false
          }
          topRowView.setVisibilityPriority(.detachEarly, for: oscVolumeView)

          topRowView.setClippingResistancePriority(.defaultLow, for: .horizontal)

          addSubviewsToPlaySliderAndTimeLabelsView(using: transition.outputLayout.controlBarGeo)
          controlBarFloating.bottomRowView.addSubview(playSliderAndTimeLabelsView)
          playSliderAndTimeLabelsView.isHidden = false
          playSliderAndTimeLabelsView.addAllConstraintsToFillSuperview()
        }
        updateSpeedLabelFont(for: transition)
      }

      // Why does this fail to show up sometimes when opening new window??
      playSliderAndTimeLabelsView.needsDisplay = true
      playSlider.needsDisplay = true
    }

    log.verbose("Done")
  }

  /// --------------------------------------------------------------------------------------------------
  /// FADE IN NEW VIEWS
  /// Expected to be animated.
  func fadeInNewViews(_ transition: LayoutTransition) {
    guard let window else { return }
    let log = Logger.addPreamble("[\(transition.name)-FadeInNewViews", toSubsystem: log)
    let outputLayout = transition.outputLayout
    log.verbose("Start")

    fadeableViews.applyVisibility(outputLayout.controlBarFloating, to: controlBarFloating.view)
    fadeableViews.applyVisibility(outputLayout.topBarView, to: topBar.view)

    if outputLayout.titleBar.isShowable {
      if transition.outputLayout.mode == .musicMode {
        if let customTitleBar {
          customTitleBar.view.alphaValue = 1
          customTitleBar.view.isHidden = false
        }
        miniPlayer.showOrHideControls()
        if trafficLightButtons.count >= 3 {
          let zoomBtn = trafficLightButtons[2]
          zoomBtn.alphaValue = 0
          zoomBtn.isHidden = true
        }
      } else {
        if outputLayout.isLegacyStyle {
          // Legacy windowed mode
          if let customTitleBar {
            for view in [customTitleBar.view] + customTitleBar.trafficLightButtons {
              view.alphaValue = 1
              view.isHidden = false
            }
            fadeableViews.applyVisibility(outputLayout.titleBar, to: customTitleBar.view)
          }
        } else {  // Native windowed or FS
          showNativeTitleBarViews(outputLayout, log)
          /// Title bar accessories may be missing if window `styleMask` did not include `.titled`. Add them back:
          addTitleBarAccessoryViews()
        }

        // covers both native & custom variants
        updateColorsForKeyWindowStatus(isKey: window.isKeyWindow)
        let enableGlow = Preference.bool(for: .titleBarBtnsGlow)
        log.verbose("Updating title bar UI for \(outputLayout.mode): enableGlow=\(enableGlow.yn), docIconAndText=\(outputLayout.titleIconAndText)")

        // Leading sidebar toggle button
        for button in [leadingSidebarToggleButton, customTitleBar?.leadingSidebarToggleButton].compactMap({$0}) {
          if enableGlow, outputLayout.leadingSidebarToggleButton.isShowable {
            button.setGlowForTitleBar(enabled: outputLayout.leadingSidebar.isVisible)
          }
          fadeableViews.applyVisibility(outputLayout.leadingSidebarToggleButton, button)
        }
        // Trailing sidebar toggle button
        for button in [trailingSidebarToggleButton, customTitleBar?.trailingSidebarToggleButton].compactMap({$0}) {
          if enableGlow, outputLayout.trailingSidebarToggleButton.isShowable {
            button.setGlowForTitleBar(enabled: outputLayout.trailingSidebar.isVisible)
          }
          fadeableViews.applyVisibility(outputLayout.trailingSidebarToggleButton, button)
        }

        if let customTitleBar {
          fadeableViews.applyVisibility(outputLayout.titleIconAndText, to: customTitleBar.titleIconAndTextStackView)
        } else {
          fadeableViews.applyVisibility(outputLayout.titleIconAndText, titleTextField, documentIconButton)
        }

        updateOnTopButton(from: outputLayout, showIfFadeable: false)

        // Title bar accessories (to cover native windowed mode):
        fadeableViews.applyVisibility(outputLayout.titlebarAccessoryViewControllers, to: leadingTitleBarAccessoryView)
        fadeableViews.applyVisibility(outputLayout.titlebarAccessoryViewControllers, to: trailingTitleBarAccessoryView)
      }
    }

    if let cropController = cropSettingsView, transition.outputLayout.isInteractiveMode {
      // show crop settings view
      cropController.view.alphaValue = 1
      cropController.cropBoxView.isHidden = false
      cropController.cropBoxView.alphaValue = 1
    }

    if !transition.isWindowInitialLayout || transition.outputLayout.isFullScreen {
      updateWindowBorderAndOpacity(using: transition.outputLayout)
    }
  }

  /// --------------------------------------------------------------------------------------------------
  /// POST TRANSITION: UPDATE INVISIBLES
  /// Cleanup & variable state updates. Always instantaneous (not animated).
  func doPostTransitionWork(_ transition: LayoutTransition) {
    let log = Logger.addPreamble(transition.logPreamble(for: .postTransition), toSubsystem: log)
    log.verbose("Start")

    if transition.isExitingLegacyFullScreen {
      /// Seems this needs to be called before the final `setFrame` call, or else the window can end up incorrectly sized at the end.
      /// Do this also for native FS. It will kick off an independent animation which will last about as long as this step's
      /// animation.
      updatePresentationOptions(windowIsFS: false)
    }

    fadeableViews.animationState = .shown
    fadeableViews.topBarAnimationState = .shown

    // Invalidate all old fadeable views actions as they are probably stale.
    fadeableViews.$showHideTicketCount.withLock { $0 += 1 }
    hideCursorTimer.restart()  // may need to re-evaluate
    fadeableViews.hideTimer.restart()  // start new fadeable countdown

    log.verbose({
      let fadeableIDs = fadeableViews.fadeables.map{$0.idString}
      let fadeablesTopBarIDs = fadeableViews.fadeablesInTopBar.map{$0.idString}
      return "FadeableViews=\(fadeableIDs) InTopBar=\(fadeablesTopBarIDs)"
    }())

    guard let window else { return }

    if transition.isExitingMusicMode || transition.isClosingPlaylistInMusicMode {
      // move playist view
      miniPlayer.removePlaylistViewIfPresent()
    }

    if transition.outputGeometry.shouldHaveAdditionalInfo {
      fadeableViews.applyVisibility(.showFadeableNonTopBar, to: osd.additionalInfoView)
    }

    if !transition.outputLayout.isLegacyStyle, !window.styleMask.contains(.titled) {
      setStyleMaskForNativeWindowed(log)
      showNativeTitleBarViews(transition.outputLayout, log)
      addTitleBarAccessoryViews()
      updateTitle()
    }

    if transition.isTogglingFullScreen {
      updatePanelBlendingModes(to: transition.outputLayout)
    }

    if transition.isEnteringFullScreen {
      if Preference.bool(for: .blackOutMonitor) {
        blackOutOtherMonitors()
      }

      player.touchBarSupport.toggleTouchBarEsc(enteringFullScr: true)

      player.mpv.queue.async { [self] in
        guard !player.isStopping else { return }
        if player.info._isPaused {
          if !player.isRestoring && Preference.bool(for: .playWhenEnteringFullScreen) {
            player._resume()
          } else {
            DispatchQueue.main.async { [self] in
              // When playback is paused the display link is stopped in order to avoid wasting energy on
              // needless processing. It must be running while transitioning to full screen mode. Now that
              // the transition has completed it can be stopped.
              videoView.displayIdle()
            }
          }
        }

        player.mpv.setFlag(MPVOption.Window.fullscreen, true)
        player.didEnterFullScreenViaUserToggle = true
      }

      player.events.emit(.windowFullscreenChanged, data: true)
      // End Entering FS

    } else if transition.isExitingFullScreen {
      // Exited FS

      if transition.needsMpvKeepaspectUpdate {
        player.updateMpvKeepaspectWindowSynchronously()
      }

      if transition.inputLayout.isLegacyFullScreen {
        window.level = .normal
      }

      if transition.outputLayout.isLegacyStyle {  // legacy windowed
        setStyleForLegacyWindowed(log)
        if let customTitleBar {
          customTitleBar.view.alphaValue = 1
        }
        updateTitle()
      }

      if Preference.bool(for: .blackOutMonitor) {
        removeBlackWindows()
      }

      // Restore ontop status / set proper window level
      setWindowFloatingOnTop(isOnTop, from: transition.outputLayout, updateOnTopStatus: false)

      player.touchBarSupport.toggleTouchBarEsc(enteringFullScr: false)

      player.mpv.queue.async { [self] in
        guard !player.isStopping else { return }
        if Preference.bool(for: .pauseWhenLeavingFullScreen) && !player.info._isPaused {
          player._pause()
        }

        if player.info._isPaused {
          DispatchQueue.main.async { [self] in
            // When playback is paused the display link is stopped in order to avoid wasting energy on
            // needless processing. It must be running while transitioning from full screen mode. Now that
            // the transition has completed it can be stopped.
            videoView.displayIdle()
          }
        }

        player.mpv.setFlag(MPVOption.Window.fullscreen, false)
        player.didEnterFullScreenViaUserToggle = false
      }

      player.events.emit(.windowFullscreenChanged, data: false)
    }  // End Exiting FS

    if transition.isExitingInteractiveMode, !isPausedPriorToInteractiveMode {
      player.resume()
    }

    // Need to execute this *after* calling updatePresentationOptions (if calling it)
    rebuildPanelConstraints(transition, stage: .postTransition)

    if transition.isTogglingMusicMode {
      if Preference.bool(for: .playlistShowMetadataInMusicMode) {
        /// Need to toggle music metadata due to music mode switch.
        /// Do this even if playlist is not visible now, because it will not be be reloaded when toggled.
        playlistView.needsScrollToCurrentItem = true
        playlistView.reloadAllPlaylistRows()
      } else if transition.outputLayout.isMusicMode && transition.outputGeometry.isMusicModePlaylistShown {
        // Music mode playlist is visible: need to scroll to current item again due to size change
        playlistView.scrollPlaylistToCurrentItem()
      } else if transition.outputLayout.playlistShown {
        // Playlist sidebar is visible: need to scroll to current item again due to size change
        playlistView.scrollPlaylistToCurrentItem()
      }

      // May need to re-evaluate these if video shown or thumbnails enabled in normal mode but not music mode
      player.reloadThumbnails()
    }

    refreshHidesOnDeactivateStatus()

#if DEBUG
    // Do not run sanity checks for initial layout, because in that case all task funcs combined into a single
    // animation task, which means that frames will not be updated yet & can't be measured correctly
    if DebugConfig.validatePWinGeometry, Logger.isEnabled(.error),
       !transition.isWindowInitialLayout, !transition.outputLayout.isInPiP,
       player.state.isNotYet(.stopping), player.info.isVideoTrackSelected {
      let vidSizeA = videoView.frame.size
      let vidSizeE = transition.outputGeometry.videoSize
      let viewportSizeA = viewportView.frame.size
      let viewportSizeE = transition.outputGeometry.viewportSize
      let winSizeA = window.frame.size
      let winSizeE = transition.outputGeometry.windowFrame.size

      let enableVidCheck = !player.info.currentMediaAudioStatus.isAudio
      let isWrongVidSize = enableVidCheck && (vidSizeE.area > 0 && vidSizeA.area > 0) &&
      ((vidSizeE.width != vidSizeA.width) || (vidSizeE.height != vidSizeA.height))
      let isWrongWinSize = (winSizeE.width != winSizeA.width) || (winSizeE.height != winSizeA.height)

      if isWrongVidSize || isWrongWinSize {
        /// Now that the transition is done and layout is complete, it is useful to check that our calculations are consistent with the result.
        /// In AppKit, `NSWindow` is the root object for the view hierarchy, so its size is easiest to get right. We start our calculations with
        /// the outermost panels & build inward (see `PWinGeometry`), so errors accumulate along the way & will result in `videoView.frame.size`
        /// (i.e. actual video size) since it is innermost.
        /// NOTE: this verifies (A) the AppKit NSView hierarchy with (B) `VideoGeometry` & `PWinGeometry`' layout calculations, but does not
        /// verify them against (C) mpv's internal video size calculations. Those are checked in `PWin_Resize.swift`
        /// (search for another instance of the UTF "X" like the one below).
        let wrong = "ⓧ"
        let lines = ["❌ SanityCheck-C failed!",
                     "  VidAspect: Expect=\(vidSizeE.mpvAspect) Actual=\(vidSizeA.mpvAspect) Constraint=\(viewportView.videoViewAspect?.logStr ?? "nil")",
                     "  VideoSize: Expect=\(enableVidCheck ? vidSizeE.description : "NA") Actual=\(vidSizeA)  \(isWrongVidSize ? wrong : "")",
                     "  Viewport:  Expect=\(viewportSizeE) Actual=\(viewportSizeA)",
                     "  WinFrame:  Expect=\(transition.outputGeometry.windowFrame) Actual=\(window.frame)  \(isWrongWinSize ? wrong : "")",
                     "  VidMargins: \(transition.outputGeometry.viewportMargins)",  // Size should == viewport - video. (Unless video is wrong)
        ]
        log.error(lines.joined(separator: "\n"))
      }
    }
#endif

    if !transition.isWindowInitialLayout,  // The initial layout case is covered in `GeometryTransform.doPostApplyWork`
        transition.outputGeometry.mode.isWindowed || transition.isTogglingFullScreen || transition.isTogglingMusicMode {
      log.verbose(" Calling sendWindowScaleToMPV for output mode=\(currentLayout.mode)")
      sendWindowScaleToMPV(basedOn: transition.outputGeometry)
    }

    // abort any queued screen updates
    screenChangedDebouncer.invalidate()
    screenParamsChangedDebouncer.invalidate()
    isAnimatingLayoutTransition = false

    log.verbose("Done with transition: isLegacy=\(transition.outputLayout.isLegacyStyle.yn) mode=\(currentLayout.mode)")

    player.saveState()
  }
  // End of steps

  // MARK: - Title bar items

  /// Hides all the various buttons of the built-in title bar, some of which can have strange quirks.
  ///
  /// Note: there is an Apple bug (as of MacOS 13.3.1) where setting `alphaValue=0` on `miniaturizeButton` will
  /// cause `window.performMiniaturize()` to be ignored. So to hide these, use `isHidden=true` + `alphaValue=1`
  /// (except for temporary animations).
  ///
  /// Note 2: do not touch `titleVisibility` if at all possible. There seems to be no reliable way to toggle it
  /// while also guaranteeing that `documentIcon` & `titleTextField` are shown/hidden consistently.
  /// Setting `isHidden=true` on `titleTextField` and `documentIcon` do not animate and do not always work.
  /// We can use `alphaValue=0` to fade out in `fadeOutOldViews()`, but `titleVisibility` is needed to remove them.
  /// We can work around the problem by (1) inserting or removing `.titled` from the window's style mask, which
  /// effectively swaps the whole title bar in or out), and (2) in native windowed mode, *always* show the title bar when
  /// the mouse hovers over it, because even if we set the document icon's alpha to 0, the user can still click on it.
  func hideNativeTitleBarViews(andSetAlpha setAlpha: Bool) {
    log.verbose("Hiding native title bar views, setAlpha=\(setAlpha.yn)")
    if setAlpha {
      documentIconButton?.alphaValue = 0
      titleTextField?.alphaValue = 0
    }
    documentIconButton?.isHidden = true
    titleTextField?.isHidden = true
    for button in trafficLightButtons {
      /// Special case for fullscreen transition due to quirks of `trafficLightButtons`.
      /// In most cases it's best to avoid setting `alphaValue = 0` for these because doing so will disable their menu items,
      /// but should be ok for brief animations
      if setAlpha {
        button.alphaValue = 0
      }
      button.isHidden = false
    }
  }

  // Legacy FS
  private func setStyleMaskForLegacyFS(_ log: any Logger.Subsystem) {
    guard let window = window else { return }
    if window.styleMask.contains(.titled) {
      log.verbose("Removing styleMask '.titled' from window (entering legacy FS)")
      window.styleMask.remove(.titled)
    }
    if !window.styleMask.contains(.borderless) {
      window.styleMask.insert(.borderless)
    }
    if window.styleMask.contains(.miniaturizable) {
      window.styleMask.remove(.miniaturizable)
    }
    if window.styleMask.contains(.resizable) {
      window.styleMask.remove(.resizable)
    }
    window.hasShadow = false
  }

  /// Legacy windowed
  private func setStyleForLegacyWindowed(_ log: any Logger.Subsystem) {
    guard let window = window else { return }
    if window.styleMask.contains(.titled) {
      log.verbose("Removing styleMask '.titled' from window (entering legacy FS)")
      window.styleMask.remove(.titled)
    }
    if window.styleMask.contains(.borderless) {
      window.styleMask.remove(.borderless)
    }
    if !window.styleMask.contains(.closable) {
      window.styleMask.insert(.closable)
    }
    if !window.styleMask.contains(.resizable) {
      window.styleMask.insert(.resizable)
    }
    if !window.styleMask.contains(.miniaturizable) {
      window.styleMask.insert(.miniaturizable)
    }
    window.hasShadow = true
  }

  /// "Native" == `.titled` style mask
  private func setStyleMaskForNativeWindowed(_ log: any Logger.Subsystem) {
    guard let window = window else { return }

    if !window.styleMask.contains(.titled) {
      log.verbose("Inserting window styleMask.titled for native windowed")
      window.styleMask.insert(.titled)
    }
    if window.styleMask.contains(.borderless) {
      window.styleMask.remove(.borderless)
    }
    if !window.styleMask.contains(.closable) {
      window.styleMask.insert(.closable)
    }
    if !window.styleMask.contains(.resizable) {
      window.styleMask.insert(.resizable)
    }
    if !window.styleMask.contains(.miniaturizable) {
      window.styleMask.insert(.miniaturizable)
    }
    window.hasShadow = true
  }

  /// Special case for traffic light buttons because their instances may change.
  /// Do not use `fadeableViews`. Always set `alphaValue = 1`.
  func showNativeTitleBarViews(_ targetLayout: LayoutState, _ log: any Logger.Subsystem) {
    guard let window = window else { return }
    guard !targetLayout.isLegacyStyle else { return }
    let iconAndTitleText: VisibilityMode = targetLayout.titleIconAndText
    log.verbose("Showing native title bar views: iconAndTitleText=\(iconAndTitleText)")

    closeButton?.alphaValue = 1
    closeButton?.isHidden = false
    miniaturizeButton?.alphaValue = 1
    miniaturizeButton?.isHidden = false

    if targetLayout.mode != .musicMode {
      zoomButton?.alphaValue = 1
      zoomButton?.isHidden = false
    }

    fadeableViews.applyVisibility(iconAndTitleText, titleTextField, documentIconButton)

    window.titlebarSeparatorStyle = .automatic  // or .line, .none, .shadow
  }

  private func addTitleBarAccessoryViews() {
    guard let window = window else { return }
    // This check prevents a constraint violation in MacOS 26 Tahoe when entering native full screen from custom windowed mode.
    // (When entering full screen, the system appears to transfer the title bar & its itens to a special faux window drops down when hovering
    // at the top of the screen. It appears that title bar accessories must be added to the window prior to entering (native) full screen for
    // this mechanism to work properly. But if we try to add both the `titled` style and the title bar accessories right before/during the
    // full screen transition, we seem to be asking too much. Some kind of race condition?
    // As a result, title bar accessories will not be available in full screen if custom windowed mode is used. Another reason to stick
    // to custom+custom or native+native pairing...
    guard window.styleMask.contains(.titled) && !isWindowInNativeFullScreen else {
      log.trace("Not adding title bar accessories: window is not .titled style, or is in native FS")
      return
    }

    if leadingTitlebarAccesoryViewController == nil {
      log.verbose("Creating leadingTitlebarAccesoryViewController")
      let accessory = NSTitlebarAccessoryViewController()
      leadingTitlebarAccesoryViewController = accessory
      accessory.view = leadingTitleBarAccessoryView
      accessory.fullScreenMinHeight = Constants.standardTitleBarHeight
      accessory.layoutAttribute = .leading
      accessory.automaticallyAdjustsSize = false
    }

    if trailingTitlebarAccesoryViewController == nil {
      log.verbose("Creating trailingTitlebarAccesoryViewController")
      let accessory = NSTitlebarAccessoryViewController()
      trailingTitlebarAccesoryViewController = accessory
      accessory.view = trailingTitleBarAccessoryView
      accessory.fullScreenMinHeight = Constants.standardTitleBarHeight
      accessory.layoutAttribute = .trailing
      accessory.automaticallyAdjustsSize = false
    }

    if window.titlebarAccessoryViewControllers.count == 1 {
      log.error("Found only 1 title bar accessory view in window! Will remove & repopulate")
      window.titlebarAccessoryViewControllers.removeAll()
    }

    if window.titlebarAccessoryViewControllers.isEmpty {
      log.verbose("Adding leadingTitlebarAccesory to window")
      window.addTitlebarAccessoryViewController(leadingTitlebarAccesoryViewController!)
      leadingTitleBarAccessoryView.translatesAutoresizingMaskIntoConstraints = false
      leadingTitleBarAccessoryView.addConstraintsToFillSuperview(top: 0, bottom: 0, leading: 0)

      log.verbose("Adding trailingTitleBarAccessory to window")
      window.addTitlebarAccessoryViewController(trailingTitlebarAccesoryViewController!)
      trailingTitleBarAccessoryView.translatesAutoresizingMaskIntoConstraints = false
      trailingTitleBarAccessoryView.addConstraintsToFillSuperview(top: 0, bottom: 0, leading: 0)
    }

    leadingTitleBarAccessoryView.isHidden = false
    leadingTitleBarAccessoryView.alphaValue = 1

    trailingTitleBarAccessoryView.isHidden = false
    trailingTitleBarAccessoryView.alphaValue = 1
  }

  // MARK: - Support Functions: Interactive Mode Controls

  /// Call this when `origVideoSize` is known.
  /// Assumes `videoRect == videoView.frame`
  private func addOrReplaceCropBoxSelection(rawVideoSize: NSSize) {
    guard let cropController = self.cropSettingsView else { return }

    if !videoView.subviews.contains(cropController.cropBoxView) {
      videoView.addSubview(cropController.cropBoxView)
      cropController.cropBoxView.addAllConstraintsToFillSuperview()
    }

    cropController.cropBoxView.originalVideoSize = rawVideoSize
  }

  private func removeCropControls() {
    guard let cropController = self.cropSettingsView else { return }

    cropController.cropBoxView.removeFromSuperview()
    cropController.view.removeFromSuperview()
    self.cropSettingsView = nil
  }

  // MARK: - Support Functions: OSC Layout

  private func updateSpeedLabelFont(for transition: LayoutTransition) {
    let oscGeo = transition.outputLayout.controlBarGeo
    let speedLabelFontSize = oscGeo.speedLabelFontSize
    log.trace("Updating speed label fontSize=\(speedLabelFontSize)")
    speedLabel.font = .messageFont(ofSize: speedLabelFontSize)
  }

  func highlight(_ button: OSCToolbarButton, _ buttonType: Preference.ToolBarButton, _ isHighlighted: Bool) {
    button.image = isHighlighted ? buttonType.alternateImage() : buttonType.image()
  }

  /// Recreates the toolbar with the latest icons with the latest sizes & padding from prefs
  private func rebuildOSCToolbar(_ transition: LayoutTransition, _ stage: LayoutTransition.Stage, hasColorChange: Bool) {
    let oldGeo = transition.inputLayout.controlBarGeo
    let newGeo = transition.outputLayout.controlBarGeo
    let newButtonTypes = newGeo.toolbarItems

    let hasSizeChange = oldGeo.toolIconSize != newGeo.toolIconSize || oldGeo.toolIconSpacing != newGeo.toolIconSpacing
    var needsButtonsUpdate = hasSizeChange || hasColorChange

    let isOpeningBarOSCFromZero = transition.isOpeningBarOSCFromZero
    let zeroOut = isOpeningBarOSCFromZero && !transition.isWindowInitialLayout
    let iconSize: CGFloat = zeroOut ? 0 : newGeo.toolIconSize
    let iconSpacing: CGFloat = zeroOut ? 0 : newGeo.toolIconSpacing
    if transition.outputLayout.hasControlBar {
      oscToolbarView.views.forEach { oscToolbarView.removeView($0) }

      if newButtonTypes.count > 0 {
        log.verbose("\(transition.logPreamble(for: stage)) Updating OSC toolbar: iconSize=\(iconSize) iconSpacing=\(iconSpacing) barHeight=\(newGeo.barHeight) fullIconHeight=\(newGeo.fullIconHeight) btns=[\(newButtonTypes.map({$0.keyString}).joined(separator: ","))]")
        let oscColorScheme = transition.outputLayout.oscColorScheme
        for buttonType in newButtonTypes {
          let button = OSCToolbarButton()
          button.setStyle(buttonType: buttonType, iconSize: iconSize, iconSpacing: iconSpacing)
          button.setColors(for: oscColorScheme)
          button.action = #selector(self.toolBarButtonAction(_:))
          oscToolbarView.addView(button, in: .trailing)
          oscToolbarView.setVisibilityPriority(.detachOnlyIfNecessary, for: button)

          // Highlight buttons with modes
          switch buttonType {
          case .pip:
            highlight(button, buttonType, transition.outputLayout.isInPiP)
          case .fullScreen:
            highlight(button, buttonType, transition.outputLayout.isFullScreen)
          case .settings:
            highlight(button, buttonType, transition.outputLayout.isVisible(sidebarTabGroup: .settings))
          case .plugins:
            highlight(button, buttonType, transition.outputLayout.isVisible(sidebarTabGroup: .plugins))
          case .playlist:
            highlight(button, buttonType, transition.outputLayout.isVisible(sidebarTabGroup: .playlist))
          default:
            break
          }
        }
        needsButtonsUpdate = false
      }
    }

    if needsButtonsUpdate {
      log.verbose("\(transition.logPreamble(for: stage)) Updating OSC toolbar: iconSize=\(newGeo.toolIconSize) iconSpacing=\(newGeo.toolIconSpacing) barHeight=\(newGeo.barHeight) fullIconHeight=\(newGeo.fullIconHeight) btns=[\(newButtonTypes.map({$0.keyString}).joined(separator: ","))]")
      let oscColorScheme = transition.outputLayout.oscColorScheme
      for button in oscToolbarView.views.compactMap({ $0 as? OSCToolbarButton }) {
        button.setStyle(iconSize: iconSize, iconSpacing: iconSpacing)
        button.setColors(for: oscColorScheme)
      }
    }

    // Do not zero this out:
    updateToolbarHStack(iconSpacing: newGeo.toolIconSpacing)
    log.verbose("\(transition.logPreamble(for: stage)) Toolbar spacing=\(oscToolbarView.spacing) edgeInsets=\(oscToolbarView.edgeInsets)")
  }

  // It's not possible to control the icon padding from inside the buttons in all cases.
  // Instead we can get the same effect with a little more work, by using the stack view's features.
  private func updateToolbarHStack(iconSpacing: CGFloat) {
    log.verbose("Updating toolbar hstack using spacing=\(iconSpacing)*2")
    oscToolbarView.spacing = 2 * iconSpacing
    let sideInset = (iconSpacing * 0.5).rounded()
    oscToolbarView.edgeInsets = .init(top: iconSpacing, left: sideInset,
                                       bottom: iconSpacing, right: sideInset)
    oscToolbarView.needsUpdateConstraints = true
  }

  // MARK: - Support Functions: Style

  private func updatePanelBlendingModes(to outputLayout: LayoutState) {
    if outputLayout.topBarHeight > 0 {
      if let topBarVE = topBar.view as? NSVisualEffectView {
        // Full screen + "behindWindow" doesn't blend properly and looks ugly
        if outputLayout.topBarPlacement == .insideViewport || outputLayout.isFullScreen {
          topBarVE.blendingMode = .withinWindow
        } else {
          topBarVE.blendingMode = .behindWindow
        }
      }
    }

    if outputLayout.bottomBarHeight > 0 {
      if let bottomBarView = bottomBar.view as? NSVisualEffectView {
        // Full screen + "behindWindow" doesn't blend properly and looks ugly
        if outputLayout.bottomBarPlacement == .insideViewport || outputLayout.isFullScreen {
          bottomBarView.blendingMode = .withinWindow
        } else {
          bottomBarView.blendingMode = .behindWindow
        }
      }
    }

    if outputLayout.leadingSidebar.isVisible {
      updateSidebarBlendingMode(.leadingSidebar, layout: outputLayout)
    }

    if outputLayout.trailingSidebar.isVisible {
      updateSidebarBlendingMode(.trailingSidebar, layout: outputLayout)
    }
  }
}
