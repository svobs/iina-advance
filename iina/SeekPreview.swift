//
//  SeekPreview.swift
//  iina
//
//  Created by Matt Svoboda on 2024-11-21.
//  Copyright © 2024 lhc. All rights reserved.
//

// TODO: pull out SeekPreview; do not nest
extension PlayerWindowController {
  // TODO: PK.seekPreviewHasTimeDelta

  /// Encapsulates state & objects needed for seek preview UI.
  /// This class is not a view in itself.
  @MainActor
  final class SeekPreview {
    /// Min distance between `thumbnailPeekView` & sides of `viewportView`.
    /// For the side which includes `timeLabel`, the margin is split 1/2 above & 1/2 below the label,
    /// and does not include the offset added by the label's height itself.
    static let minThumbMargins = MarginQuad(top: Constants.Thumbnail.extraOffsetY,
                                            trailing: Constants.Thumbnail.extraOffsetX,
                                            bottom: Constants.Thumbnail.extraOffsetY,
                                            leading: Constants.Thumbnail.extraOffsetX)

    // Components:
    let timeLabel = NSTextField()
    let chapterLabel = NSTextField()
    let thumbnailPeekView = ThumbnailPeekView()

    var timeLabelHorizontalCenterConstraint: NSLayoutConstraint!
    var timeLabelVerticalSpaceConstraint: NSLayoutConstraint!
    var chapterLabelVerticalSpaceConstraint: NSLayoutConstraint!

    fileprivate var useThumbfast = Preference.bool(for: .enableAdvancedSettings) && Preference.bool(for: .integrateWithThumbfast)

    unowned var player: PlayerCore!
    var pwc: PlayerWindowController! { player.pwc }
    var log: any Logger.Subsystem { player.log }

    var animationState: UIAnimationState = .hidden {
      didSet {
        if animationState == .willHide || animationState == .hidden {
          currentPreviewTimeSec = nil
        }
        // Trigger redraw of PlaySlider, in case knob needs to be shown or hidden
        thumbnailPeekView.pwc?.playSlider.needsDisplay = true
      }
    }
    // Only non-nil when SeekPreview is shown
    var currentPreviewTimeSec: Double? = nil

    /// For auto hiding seek time & thumbnail after a timeout.
    /// Calls `PlayerWindowController.seekPreviewTimeout` on timeout.
    let hideTimer = TimeoutTimer(timeout: TimeConstants.seekPreviewHideTimeout)

    func refreshThumbfastFromPrefs() {
      let useThumbfastOld = useThumbfast
      let useThumbfastNew = Preference.bool(for: .enableAdvancedSettings) && Preference.bool(for: .integrateWithThumbfast)
      useThumbfast = useThumbfastNew

      if useThumbfastOld && !useThumbfastNew {
        // Disabled thumbfast: make sure we clear any existing thumbfast thumbnail:
        player.mpv.clearThumbfast()
        // Now make sure to load traditional thumbs:
        player.reloadThumbnails()
      }
    }

    init() {
      timeLabel.identifier = .init("SeekTimeLabel")
      timeLabel.translatesAutoresizingMaskIntoConstraints = false
      timeLabel.isBordered = false
      timeLabel.drawsBackground = false
      timeLabel.isBezeled = false
      timeLabel.isEditable = false
      timeLabel.isSelectable = false
      timeLabel.isEnabled = true
      timeLabel.refusesFirstResponder = true
      timeLabel.alignment = .center
      timeLabel.textColor = .white  // always
      timeLabel.setContentHuggingPriority(.required, for: .horizontal)
      timeLabel.setContentHuggingPriority(.required, for: .vertical)
      timeLabel.isHidden = true
      timeLabel.alphaValue = 0.0

      chapterLabel.identifier = .init("SeekChapterLabel")
      chapterLabel.translatesAutoresizingMaskIntoConstraints = false
      chapterLabel.isBordered = false
      chapterLabel.drawsBackground = false
      chapterLabel.isBezeled = false
      chapterLabel.isEditable = false
      chapterLabel.isSelectable = false
      chapterLabel.isEnabled = true
      chapterLabel.refusesFirstResponder = true
      chapterLabel.alignment = .center
      chapterLabel.textColor = .white  // always
      chapterLabel.setContentHuggingPriority(.required, for: .horizontal)
      chapterLabel.setContentHuggingPriority(.required, for: .vertical)
      chapterLabel.isHidden = true
      chapterLabel.alphaValue = 0.0

      thumbnailPeekView.identifier = .init("ThumbnailPeekView")
      thumbnailPeekView.isHidden = true

      updateStyle()
    }

    func restartHideTimer() {
      guard animationState == .shown else { return }
      hideTimer.restart()
    }

    func updateStyle() {
      timeLabel.addShadow(blurRadiusConstant: Constants.seekPreviewTimeLabel_ShadowRadiusConstant,
                          xOffsetConstant: Constants.seekPreviewTimeLabel_xOffsetConstant,
                          yOffsetConstant: Constants.seekPreviewTimeLabel_yOffsetConstant,
                          color: .black)
      chapterLabel.addShadow(blurRadiusConstant: Constants.seekPreviewTimeLabel_ShadowRadiusConstant,
                             xOffsetConstant: Constants.seekPreviewTimeLabel_xOffsetConstant,
                             yOffsetConstant: Constants.seekPreviewTimeLabel_yOffsetConstant,
                             color: .black)
      thumbnailPeekView.updateColors()
    }

    /// This is expected to be called at first layout
    func updateLabelFont(using layout: LayoutState) {
      let timeFont, chapterFont: NSFont
      if layout.isMusicMode {
        timeFont = NSFont.systemFont(ofSize: 9)
        chapterFont = timeFont
      } else {
        let oscGeo = layout.controlBarGeo
        timeFont = NSFont.monospacedDigitSystemFont(ofSize: oscGeo.seekPreviewTimeLabelFontSize, weight: .bold)
        chapterFont = NSFont.monospacedDigitSystemFont(ofSize: oscGeo.seekPreviewChapterLabelFontSize, weight: .regular)
      }
      timeLabel.font = timeFont
      chapterLabel.font = chapterFont
    }

    /// `posInWindowX` is where center of timeLabel, thumbnailPeekView should be
    // TODO: Investigate using CoreAnimation!
    // https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CoreAnimationBasics/CoreAnimationBasics.html
    func showPreview(withThumbnail showThumbnail: Bool,
                     forTime previewTimeSec: Double, mediaDuration: Double,
                     posInWindowX: CGFloat, currentControlBar: NSView,
                     _ currentGeo: PWinGeometry) {

      let margins = SeekPreview.minThumbMargins
      let thumbStore = player.currentMediaThumbnails
      let ffThumbnail = thumbStore?.getThumbnail(forSecond: previewTimeSec)
      let viewportSize = currentGeo.viewportSize
      let currentLayout = pwc.currentLayout

      var showThumbnail = showThumbnail
      var usingThumbfast = false
      var thumbWidth: Double
      var thumbHeight: Double
      if showThumbnail, useThumbfast, let thumbfastInfo = player.mpv.thumbfastInfo, thumbfastInfo.isReady {
        usingThumbfast = true
        thumbWidth = Double(thumbfastInfo.width)
        thumbHeight = Double(thumbfastInfo.height)
      } else if showThumbnail, let ffThumbnail {
        let rotatedImage = ffThumbnail.image
        thumbWidth = Double(rotatedImage.width)
        thumbHeight = Double(rotatedImage.height)
        if thumbWidth <= 0 || thumbHeight <= 0 {
          showThumbnail = false
        }
      } else {
        if showThumbnail {
          log.verbose("[SeekPreview] No thumbnail for \(previewTimeSec)s: hasStore=\((thumbStore != nil).yn) thumbCount=\(thumbStore?.thumbnails.count ?? 0)")
        }
        showThumbnail = false
        thumbWidth = 0
        thumbHeight = 0
      }

      let showChapter: Bool = Preference.bool(for: .seekPreviewHasChapter) && !player.info.chapters.isEmpty

      if showChapter {
        // Use a space even if hovered time does not belong to a named chapter, so that the height stays consistent.
        let chapterTitle = player.info.chapter(forPlaybackTime: previewTimeSec)?.title ?? " "
        if chapterLabel.stringValue != chapterTitle {
          chapterLabel.stringValue = chapterTitle
          chapterLabel.sizeToFit()
        }
      }
      let chapterLabelHeight = showChapter ? chapterLabel.attributedStringValue.size().height.rounded() : 0.0

      let timeLabelString = VideoTime.string(from: previewTimeSec)
      if timeLabel.stringValue != timeLabelString {
        timeLabel.stringValue = timeLabelString
        timeLabel.sizeToFit()
      }
      currentPreviewTimeSec = previewTimeSec

      // Get size *after* stringValue is set:
      let timeLabelSize = timeLabel.attributedStringValue.size().rounded()

      // Subtract some height for less margin before time label
      let adjustedMarginTotalHeight = margins.totalHeight * 0.75

      /// Calculate `availableHeight`: viewport height, minus top & bottom bars, minus extra space
      let availableHeight = viewportSize.height - currentGeo.insideBars.totalHeight - adjustedMarginTotalHeight - timeLabelSize.height - chapterLabelHeight
      /// `availableWidth`: entire window width, minus extra space
      let availableWidth = currentGeo.windowFrame.width - margins.totalWidth
      let oscOriginInWindowY = currentControlBar.superview!.convert(currentControlBar.frame.origin, to: nil).y
      let oscHeight = currentControlBar.frame.size.height

      var thumbAspect = showThumbnail ? (thumbWidth / thumbHeight) : 1.0

      if showThumbnail && !usingThumbfast {
        // The aspect ratio of some videos is different at display time. Resize thumbs on-the-fly
        // once the actual aspect ratio is known.
        let videoAspectCAR = currentGeo.video.videoAspectCAR
        if thumbAspect != videoAspectCAR {
          thumbHeight = (thumbWidth / videoAspectCAR).rounded()
          /// Recalculate this for later use (will use it and `thumbHeight`, and derive width)
          thumbAspect = thumbWidth / thumbHeight
        }

        let sizeOption: Preference.ThumbnailSizeOption = Preference.enum(for: .thumbnailSizeOption)
        switch sizeOption {
        case .fixedSize:
          // Stored thumb size should be correct (but may need to be scaled down)
          break
        case .scaleWithViewport:
          // Scale thumbnail as percentage of available height
          let percentage = min(1, max(0, Preference.double(for: .thumbnailDisplayedSizePercentage) / 100.0))
          thumbHeight = availableHeight * percentage
        }

        // Thumb too small?
        if thumbHeight < Constants.Thumbnail.minHeight {
          thumbHeight = Constants.Thumbnail.minHeight
        }

        // Thumb too tall?
        if thumbHeight > availableHeight {
          // Scale down thumbnail so it doesn't overlap top or bottom bars
          thumbHeight = availableHeight
        }
        thumbWidth = thumbHeight * thumbAspect

        // Also scale down thumbnail if it's wider than the viewport
        if thumbWidth > availableWidth {
          thumbWidth = availableWidth
          thumbHeight = thumbWidth / thumbAspect
        }
      }  // end if showThumbnail

      let showAbove: Bool
      if currentLayout.isMusicMode {
        showAbove = true  // always show above in music mode

        if showThumbnail && !usingThumbfast {
          let totalExtraVerticalSpace = adjustedMarginTotalHeight + timeLabelSize.height + chapterLabelHeight
          let availableHeightAbove = max(0, viewportSize.height - totalExtraVerticalSpace)
          if thumbHeight > availableHeightAbove {
            // Scale down thumbnail so it doesn't get clipped by the side of the window
            thumbHeight = availableHeightAbove
            thumbWidth = thumbHeight * thumbAspect
          }
        }
      } else {
        switch currentLayout.oscPosition {
        case .top:
          showAbove = false
        case .bottom:
          showAbove = true
        case .floating:
          // Need to check available space in viewport above & below OSC
          let totalExtraVerticalSpace = adjustedMarginTotalHeight + timeLabelSize.height + chapterLabelHeight
          let availableHeightBelowOSC = max(0, oscOriginInWindowY - currentGeo.insideBars.bottom - totalExtraVerticalSpace)
          if availableHeightBelowOSC > thumbHeight {
            // Show below by default, if there is space for the desired size
            showAbove = false
          } else {
            // If not enough space to show the full-size thumb below, then show above if it has more space
            let availableHeightAboveOSC = max(0, viewportSize.height - (oscOriginInWindowY + oscHeight + totalExtraVerticalSpace + currentGeo.insideBars.top))
            showAbove = availableHeightAboveOSC > availableHeightBelowOSC
            if showThumbnail && !usingThumbfast, showAbove, thumbHeight > availableHeightAboveOSC {
              // Scale down thumbnail so it doesn't get clipped by the side of the window
              thumbHeight = availableHeightAboveOSC
              thumbWidth = thumbHeight * thumbAspect
            }
          }

          if showThumbnail && !usingThumbfast, !showAbove, thumbHeight > availableHeightBelowOSC {
            thumbHeight = availableHeightBelowOSC
            thumbWidth = thumbHeight * thumbAspect
          }
        }
      }

      // Constrain X origin so that it stays entirely inside the window and doesn't spill off the sides
      let isRightToLeft = player.videoView.userInterfaceLayoutDirection == .rightToLeft
      let minX = isRightToLeft ? margins.trailing : margins.leading
      let maxX = minX + availableWidth
      let halfMargin: CGFloat
      if showAbove {
        halfMargin = (margins.bottom * 0.5).rounded()
      } else {
        halfMargin = (margins.top * 0.5).rounded()
      }
      let quarterMargin = (halfMargin * 0.5).rounded()

      // Calculate timeLabel Y position
      let timeLabelOriginY: CGFloat
      if showAbove {
        let oscTopY = oscOriginInWindowY + oscHeight
        // Show thumbnail above seek time, which is above slider
        if currentLayout.oscPosition == .floating || currentLayout.isMusicMode {
          timeLabelOriginY = oscTopY + quarterMargin
        } else {
          let sliderFrameInWindowCoords = pwc.playSlider.frameInWindowCoords
          let sliderCenterY = sliderFrameInWindowCoords.origin.y + (sliderFrameInWindowCoords.height * 0.5)
          let halfKnobHeight = pwc.playSliderCell.knobHeight * 0.5
          // If clear background, align the label consistently close to the slider bar.
          // Else if using gray panel, try to align the label either wholly inside or outside the panel.
          if currentLayout.oscColorScheme != .clearGradient, sliderCenterY + halfKnobHeight + timeLabelSize.height >= oscTopY {
            timeLabelOriginY = oscTopY + quarterMargin
          } else {
            timeLabelOriginY = (sliderCenterY + halfKnobHeight + quarterMargin).rounded()
          }
        }
      } else {  // Show below PlaySlider
        if currentLayout.oscPosition == .floating {
          timeLabelOriginY = (oscOriginInWindowY - quarterMargin - timeLabelSize.height).rounded()
        } else {
          let sliderFrameInWindowCoords = pwc.playSlider.frameInWindowCoords
          let sliderCenterY = (sliderFrameInWindowCoords.origin.y + (sliderFrameInWindowCoords.height * 0.5)).rounded()
          // See note for the Above case (but use ½ margin instead of ¼).
          let halfKnobHeight = (pwc.playSliderCell.knobHeight * 0.5).rounded()
          if currentLayout.oscColorScheme != .clearGradient, sliderCenterY - halfKnobHeight - quarterMargin - timeLabelSize.height <= oscOriginInWindowY {
            timeLabelOriginY = (oscOriginInWindowY - quarterMargin - timeLabelSize.height).rounded()
          } else {
            timeLabelOriginY = (sliderCenterY - halfKnobHeight - quarterMargin - timeLabelSize.height).rounded()
          }
        }
      }
      timeLabelVerticalSpaceConstraint.constant = timeLabelOriginY

      // Keep timeLabel centered with seek time location, which should usually match center of thumbnailPeekView.
      // But keep text fully inside window.
      let timeLabelWidth_Halved = timeLabelSize.width * 0.5
      let timeLabelCenterX = posInWindowX.clamped(to: (minX + timeLabelWidth_Halved)...(maxX - timeLabelWidth_Halved)).rounded()
      timeLabelHorizontalCenterConstraint.constant = timeLabelCenterX

      timeLabel.alphaValue = 1.0
      timeLabel.isHidden = false

      var yOrigin: CGFloat = timeLabelOriginY
      if showAbove {
        yOrigin += timeLabelSize.height + quarterMargin
      }

      // Done with timeLabel.
      log.verbose("[SeekPreview] Showing Time: centerX=\(Int(timeLabelCenterX)) originY=\(Int(timeLabelOriginY)) size=\(timeLabelSize). Thumb=\(showThumbnail.yn)"
                  + (showThumbnail ? " thumbfast=\(usingThumbfast.yn)" : ""))

      // - Thumbnail
      if showThumbnail {
        // Need integers.
        thumbWidth = round(thumbWidth)
        thumbHeight = round(thumbHeight)

        if thumbWidth < Constants.Thumbnail.minHeight || thumbHeight < Constants.Thumbnail.minHeight {
          log.verbose("Not enough space to display thumbnail")
        } else {
          if !showAbove {
            yOrigin -= thumbHeight + quarterMargin
          }

          let thumbWidth_Halved = (thumbWidth / 2).rounded()

          if usingThumbfast {
            // Experiment with Thumbfast Lua script as an alternative (https://github.com/po5/thumbfast)
            guard player.isActive else { return }
            // Need DisplayLink running to draw the thumbnails over the video
            player.videoView.displayActive()
            thumbnailPeekView.isHidden = true

            // TODO: move the following into mpv queue

            let osdWidth = player.mpv.getDouble(MPVProperty.osdWidth)

            let viewportSize = currentGeo.viewportSize
            // Thumbfast expects X,Y to represent top-left corner of thumbnail
            let scaleRatio = osdWidth / viewportSize.width
            let viewportFrameInWindowCoords = currentGeo.viewportFrameInWindowCoords
            let thumbOriginInViewportX = posInWindowX - viewportFrameInWindowCoords.minX
            let thumbOriginX = ((thumbOriginInViewportX * scaleRatio) - (thumbWidth_Halved)).clamped(to: 0...(max(0, osdWidth - thumbWidth))).rounded()
            let thumbOriginInViewportY = yOrigin - viewportFrameInWindowCoords.minY
            var yConverted = ((viewportSize.height - thumbOriginInViewportY) * scaleRatio) - thumbHeight
            if !showAbove {
              yConverted -= thumbHeight
            }
            let thumbOriginY = yConverted.clamped(to: 0...(max(0, (viewportSize.height * scaleRatio) - thumbHeight))).rounded()
            player.mpv.showThumbfast(hoveredSecs: previewTimeSec, x: thumbOriginX, y: thumbOriginY)
          } else {  // !usingThumbfast
            let thumbOriginX = (posInWindowX - thumbWidth_Halved).clamped(to: minX...(maxX - thumbWidth)).rounded()
            let thumbFrame = NSRect(x: thumbOriginX, y: yOrigin, width: thumbWidth, height: thumbHeight)
            updateThumbnailPeekView(to: ffThumbnail!, thumbFrame: thumbFrame, thumbStore!, currentGeo, previewTimeSec: previewTimeSec)
            thumbnailPeekView.isHidden = false
            thumbnailPeekView.alphaValue = 1
          }
          if showAbove {
            yOrigin += thumbHeight + quarterMargin
          }
        }
      }

      // - Chapter
      if showChapter {
        if !showAbove {
          yOrigin -= chapterLabelHeight + quarterMargin
        }

        chapterLabelVerticalSpaceConstraint.constant = yOrigin

        chapterLabel.alphaValue = 1
      }
      chapterLabel.isHidden = !showChapter

      animationState = .shown
      // Start timer (or reset it), even if just hovering over the play slider. The Cocoa "mouseExited" event doesn't fire
      // reliably, so using a timer works well as a failsafe.
      restartHideTimer()
    }

    private func updateThumbnailPeekView(to ffThumbnail: Thumbnail, thumbFrame: NSRect, _ thumbStore: SingleMediaThumbnailsLoader,
                                         _ currentGeo: PWinGeometry, previewTimeSec: CGFloat) {
      thumbStore.currentDisplayedThumbFFTimestamp = ffThumbnail.timestamp
      let cornerRadius = thumbnailPeekView.updateBorderStyle(thumbSize: thumbFrame.size, previewTimeSec: previewTimeSec)

      // Apply crop first. Then aspect
      let croppedImage: CGImage
      if let normalizedCropRect = currentGeo.video.cropRectNormalized {
        croppedImage = ffThumbnail.image.cropped(normalizedCropRect: normalizedCropRect)
      } else {
        croppedImage = ffThumbnail.image
      }
      // The calculations for thumbFrame reflect the final image coordinates. But for faster speed we are going
      // to use the unflipped, unrotated thumbnail & apply rotation & mirroring/flipping via CoreAnimation transformations.
      let unrotatedImageSize: CGSize
      if currentGeo.video.isWidthSwappedWithHeightByTotalRotation {
        unrotatedImageSize = CGSize(width: thumbFrame.height, height: thumbFrame.width)
      } else {
        unrotatedImageSize = thumbFrame.size
      }
      let affineImage = croppedImage.resized(newWidth: unrotatedImageSize.widthInt, newHeight: unrotatedImageSize.heightInt,
                                             cornerRadius: cornerRadius)
      thumbnailPeekView.image = NSImage.from(affineImage)
      thumbnailPeekView.widthConstraint.constant = unrotatedImageSize.width
      thumbnailPeekView.heightConstraint.constant = unrotatedImageSize.height

      thumbnailPeekView.frame.origin = thumbFrame.origin

      // Apply flip, mirror, & rotate using CoreAnimation for blazing fast transformations
      if player.info.isFlippedHorizontal || player.info.isFlippedVertical || currentGeo.video.totalRotation != 0 {
        let xFlip: CGFloat = player.info.isFlippedHorizontal ? -1 : 1
        let yFlip: CGFloat = player.info.isFlippedVertical ? -1 : 1
        var sumTF = CATransform3DMakeScale(xFlip, yFlip, 1)

        if currentGeo.video.totalRotation != 0 {
          let rotationRadians = CGFloat(-currentGeo.video.totalRotation).degreesToRadians
          let rotateTF = CATransform3DMakeRotation(rotationRadians, 0, 0, 1)
          sumTF = CATransform3DConcat(sumTF, rotateTF)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let layer = thumbnailPeekView.layer!
        let centerPoint = CGPointMake(NSMidX(thumbFrame), NSMidY(thumbFrame))
        layer.position = centerPoint
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.transform = sumTF

        CATransaction.commit()
      }

      log.trace("Displaying thumbnail: frame=\(thumbFrame) in windowFrame=\(thumbnailPeekView.window?.frame.description ?? "nil"), calcWinFrame=\(currentGeo.windowFrame)")
      thumbnailPeekView.alphaValue = 1.0
    }

  } // end class SeekPreview


  // MARK: - PlayerWindowController methods


  /// Called on `PlayerWindow` load: `contentView` is `window.contentView`.
  func initSeekPreview(in contentView: NSView) {
    seekPreview.player = player
    contentView.addSubview(seekPreview.thumbnailPeekView, positioned: .above, relativeTo: viewportView)
    contentView.addSubview(seekPreview.chapterLabel, positioned: .above, relativeTo: seekPreview.thumbnailPeekView)
    contentView.addSubview(seekPreview.timeLabel, positioned: .above, relativeTo: seekPreview.timeLabel)
    // This is above the play slider and by default, will swallow clicks. Send events to play slider instead
    seekPreview.timeLabel.nextResponder = playSlider

    let chapterCenterXConstraint = seekPreview.chapterLabel.centerXAnchor.constraint(equalTo: seekPreview.timeLabel.centerXAnchor)
    chapterCenterXConstraint.isActive = true

    // Yes, left, not leading!
    seekPreview.timeLabelHorizontalCenterConstraint = seekPreview.timeLabel.centerXAnchor.constraint(equalTo: contentView.leftAnchor, constant: 0) // dummy value for now
    seekPreview.timeLabelHorizontalCenterConstraint.identifier =  "SeekTimeHoverLabel_CenterXCon"
    seekPreview.timeLabelHorizontalCenterConstraint.isActive = true

    // This is a bit confusing but the constant here can be thought of as the X value in window,
    // not flipped (so, larger values toward the top)
    seekPreview.timeLabelVerticalSpaceConstraint = contentView.bottomAnchor.constraint(equalTo: seekPreview.timeLabel.bottomAnchor, constant: 0)
    seekPreview.timeLabelVerticalSpaceConstraint.identifier = "SeekTimeHoverLabel_YOffsetCon"
    seekPreview.timeLabelVerticalSpaceConstraint.isActive = true

    seekPreview.chapterLabelVerticalSpaceConstraint = contentView.bottomAnchor.constraint(equalTo: seekPreview.chapterLabel.bottomAnchor, constant: 0)
    seekPreview.chapterLabelVerticalSpaceConstraint.identifier = "SeekChapterHoverLabel_YOffsetCon"
    seekPreview.chapterLabelVerticalSpaceConstraint.isActive = true

    seekPreview.hideTimer.action = seekPreviewTimeout
  }

  func shouldSeekPreviewBeVisible(forPointInWindow pointInWindow: NSPoint) -> Bool {
    guard !player.disableUI,
          !isAnimatingLayoutTransition, !isApplyingPWinGeo,
          !osd.isShowingUserInteractiveOSD,
          currentLayout.hasControlBar else {
      return false
    }
    return isScrollingOrDraggingPlaySlider || isPointInPlaySliderAndNotOtherViews(pointInWindow: pointInWindow)
  }

  /// Called by `seekPreview.hideTimer`.
  @MainActor
  func seekPreviewTimeout() {
    let pointInWindow = window!.convertPoint(fromScreen: NSEvent.mouseLocation)
    log.trace("SeekPreview timed out: current mouseLoc=\(pointInWindow)")
    guard !isScrollingOrDraggingPlaySlider else {
      // Do not step on the toes of the scroll wheel / play slider during seek.
      // Just push the timeout further out in case it's needed after seek ends
      seekPreview.hideTimer.restart()
      return
    }
    refreshSeekPreviewAsync(forPointInWindow: pointInWindow)
  }

  /// With animation. For non-animated version, see: `hideSeekPreviewImmediately()`.
  fileprivate func hideSeekPreviewWithAnimation() {
    var tasks: [IINAAnimation.Task] = []

    tasks.append(.init(duration: Constants.AnimationDuration.hideSeekPreview) { [self] in
      guard seekPreview.animationState == .shown else {
        // Try not to pile up duplicate animations. But call the next task.
        return
      }
      fadeOutSeekPreview()
      playSliderCell.hoverIndicator?.isHidden = true
      if fadeableViews.isShowingFadeableViewsForSeek {
        fadeableViews.isShowingFadeableViewsForSeek = false
        fadeableViews.hideTimer.restart()
      }

      playSliderCell.hoverIndicator?.alphaValue = 0
    })

    tasks.append(.instantTask { [self] in
      // if no interrupt then hide animation
      hideSeekPreviewImmediately()
    })

    animationPipeline.submit(tasks)
  }

  func fadeOutSeekPreview() {
    seekPreview.animationState = .willHide
    seekPreview.thumbnailPeekView.animator().alphaValue = 0
    seekPreview.chapterLabel.animator().alphaValue = 0
    seekPreview.timeLabel.animator().alphaValue = 0
  }

  /// Without animation. For animated version, see `hideSeekPreviewWithAnimation()`, which will call this func (DRY).
  func hideSeekPreviewImmediately() {
    guard seekPreview.animationState == .shown || seekPreview.animationState == .willHide else { return }
    log.verbose("Hiding SeekPreview")
    seekPreview.hideTimer.cancel()
    seekPreview.animationState = .hidden
    seekPreview.thumbnailPeekView.isHidden = true
    seekPreview.chapterLabel.isHidden = true
    seekPreview.timeLabel.isHidden = true
    seekPreview.currentPreviewTimeSec = nil
    playSliderCell.hoverIndicator?.isHidden = true

    if seekPreview.useThumbfast {
      player.mpv.clearThumbfast()
    }
  }

  /// Makes fake point in window to position seek time & thumbnail as though hovering over play slider.
  /// See: `refreshSeekPreviewAsync(forPointInWindow:)`
  func refreshSeekPreviewAsync(forWindowCoordX windowCoordX: CGFloat) {
    let sliderMidY = playSlider.frameInWindowCoords.midY
    let pointInWindow = CGPoint(x: windowCoordX, y: sliderMidY)
    refreshSeekPreviewAsync(forPointInWindow: pointInWindow)
  }

  /// Display time label & thumbnail when mouse over slider.
  func refreshSeekPreviewAsync(forPointInWindow pointInWindow: NSPoint) {
    thumbDisplayDebouncer.run { [self] in
      log.trace("RefreshSeekPreviewAsync @ \(pointInWindow)")
      if shouldSeekPreviewBeVisible(forPointInWindow: pointInWindow),
         let duration = player.info.playbackTime.durationSec,
         showSeekPreview(forPointInWindow: pointInWindow, mediaDuration: duration) {
        return
      }

      if seekPreview.animationState == .shown {
        hideSeekPreviewWithAnimation()
      }
    }
  }

  /// Should only be called by `refreshSeekPreviewAsync`
  private func showSeekPreview(forPointInWindow pointInWindow: NSPoint, mediaDuration: CGFloat) -> Bool {
    let notInMusicModeDisabled = !currentLayout.isMusicMode || (Preference.bool(for: .enableThumbnailForMusicMode) && musicModeGeo.isViewportShown)

    // First check if both time & thumbnail are disabled
    guard let currentControlBar, notInMusicModeDisabled else {
      return false
    }

    // May need to adjust X to account for knob width
    let centerOfKnobInSliderCoordX = playSlider.computeCenterOfKnobInSliderCoordXGiven(pointInWindow: pointInWindow)
    let pointInSlider = NSPoint(x: centerOfKnobInSliderCoordX, y: 0)
    let pointInWindowCorrected = NSPoint(x: playSlider.convert(pointInSlider, to: nil).x, y: pointInWindow.y)

    // - 2. Thumbnail Preview

    let showThumbnail = Preference.bool(for: .enableThumbnailPreview) && player.info.isVideoTrackSelected
    let isShowingThumbnailForSeek = isScrollingOrDraggingPlaySlider
    if (isShowingThumbnailForSeek || playSliderCell.isDraggingLoopKnob) && !(Preference.bool(for: .enableThumbnailPreview) && Preference.bool(for: .showThumbnailDuringSliderSeek)) {
      // Do not show any preview if preview for seeking is disabled
      return false
    }

    // Need to ensure OSC is displayed if showing thumbnail preview
    if currentLayout.hasFadeableOSC {
      let hasTopBarFadeableOSC = currentLayout.oscPosition == .top && currentLayout.topBarView == .showFadeableTopBar
      let isOSCHidden = hasTopBarFadeableOSC ? fadeableViews.topBarAnimationState == .hidden : fadeableViews.animationState == .hidden

      if isShowingThumbnailForSeek {
        if isOSCHidden {
          showFadeableViews(thenRestartFadeTimer: false, duration: 0, forceShowTopBar: hasTopBarFadeableOSC)
        } else {
          fadeableViews.hideTimer.cancel()
        }
        // Set this to remind ourselves to restart the fade timer when seek is done
        fadeableViews.isShowingFadeableViewsForSeek = true

      } else if isOSCHidden {
        // Do not show any preview if OSC is hidden and is not a showable seek
        return false
      }
    }

    let playbackPositionRatio = playSlider.computeProgressRatioGiven(centerOfKnobInSliderCoordX: centerOfKnobInSliderCoordX)
    let previewTimeSec = (mediaDuration * playbackPositionRatio).roundedTo6()

    // Get X coord of hover (not the knob center)!
    let pointInWindowX: CGFloat = playSlider.convert(pointInWindow, from: nil).x
    playSliderCell.showHoverIndicator(atSliderCoordX: pointInWindowX)

    let currentGeo: PWinGeometry
    switch currentLayout.mode {
    case .musicMode:
      currentGeo = musicModeGeoForCurrentFrame()
    case .windowedNormal, .windowedInteractive:
      currentGeo = windowedGeoForCurrentFrame()
    case .fullScreenNormal, .fullScreenInteractive:
      currentGeo = currentLayout.buildFullScreenGeometry(inScreenID: windowedModeGeo.screenID, geo.video)
    }

    seekPreview.showPreview(withThumbnail: showThumbnail, forTime: previewTimeSec, mediaDuration: mediaDuration,
                            posInWindowX: pointInWindowCorrected.x, currentControlBar: currentControlBar, currentGeo)
    return true
  }

}
