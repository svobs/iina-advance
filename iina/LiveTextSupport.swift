//
//  LiveTextSupport.swift
//  iina
//
//  Created by Yuze Jiang on 5/26/25.
//  Copyright © 2025 lhc. All rights reserved.
//

import Cocoa
import VisionKit

fileprivate let subsystem = Logger.makeSubsystem("livetext", symbolName: ["text.viewfinder"])
fileprivate func liveTextLog(_ str: @autoclosure () -> String, level: Logger.Level = .debug) {
  Logger.log(str, level: level, subsystem: subsystem)
}


@preconcurrency
@MainActor
class LiveTextController {
  private weak var pwc: PlayerWindowController!

  var overlayView: ImageAnalysisOverlayView?
  var analysisTask: Task<Void, Never>?

  var isSelected: Bool = false
  var isMenuOpen: Bool = false
  var isHighlighted: Bool = false
  var isActive: Bool {
    isSelected || isMenuOpen || isHighlighted
  }
  var isShown: Bool {
    overlayView != nil
  }
  private var wasUIHiddenByLiveText: Bool = false

  init(pwc: PlayerWindowController) {
    self.pwc = pwc
  }

  func updateOverlayInsets() {
    guard let view = overlayView else { return }
    let isBottom = Preference.enum(for: .oscPosition) as Preference.OSCPosition == .bottom
    view.supplementaryInterfaceContentInsets = NSEdgeInsets(top: 8, left: 8, bottom: isBottom ? 48 : 8, right: 8)
  }

  @MainActor
  func requestAnalysis() {
    guard Preference.isLiveTextEnabled,
          !pwc.isInInteractiveMode else { return }
    requestAnalysisImpl()
  }

  @MainActor
  func clearAnalysis() {
    guard isShown else { return }
    clearAnalysisImpl()
  }

  fileprivate func refreshUI() {
    if isActive {
      if !wasUIHiddenByLiveText {
        pwc.hideFadeableViews()
        wasUIHiddenByLiveText = true
      }
    } else if wasUIHiddenByLiveText {
      wasUIHiddenByLiveText = false
      let pointInWindow = pwc.mouseLocationInWindow
      if pwc.isMouseInsideFadeableView(pointInWindow) {
        pwc.showFadeableViewsForMouseLocation(pointInWindow)
      }
    }
  }
}


extension LiveTextController: ImageAnalysisOverlayViewDelegate {
  @discardableResult
  fileprivate func setupLiveTextOverlay() -> ImageAnalysisOverlayView {
    let view = ImageAnalysisOverlayView()
    view.preferredInteractionTypes = .automatic
    view.delegate = self
    view.translatesAutoresizingMaskIntoConstraints = false
    overlayView = view
    updateOverlayInsets()
    return view
  }

  fileprivate func requestAnalysisImpl() {
    guard pwc.player.info.isPaused, Preference.isLiveTextEnabled else { return }
    liveTextLog("Image analysis requested")
    clearAnalysisImpl()

    let videoView = pwc.videoView
    analysisTask = Task { [weak self] in
      guard let self else { return }
      do {
        guard let image = await videoView.glLayer?.captureSnapshot() else {
          liveTextLog("Failed to capture frame for image analysis", level: .warning)
          return
        }
        try Task.checkCancellation()
        let analysis = try await ImageAnalyzer().analyze(image, orientation: .up, configuration: .init([.text]))
        liveTextLog("Image analysis results acquired")
        await MainActor.run {
          let overlay = self.setupLiveTextOverlay()
          overlay.analysis = analysis
          overlay.frame = videoView.bounds
          videoView.addSubview(overlay)
          overlay.padding(.all(0))
          liveTextLog("Image analysis overlay view inserted to video view")
          self.refreshUI()
        }
      } catch is CancellationError {
        liveTextLog("Image analysis cancelled")
      } catch {
        liveTextLog("Image analysis failed: \(error)", level: .warning)
      }
    }
  }

  fileprivate func clearAnalysisImpl() {
    analysisTask?.cancel()
    analysisTask = nil
    overlayView?.analysis = nil
    overlayView?.removeFromSuperview()
    overlayView = nil
    isSelected = false
    isMenuOpen = false
    isHighlighted = false
    liveTextLog("Image analysis invalidated and overlay view removed from video view")
    refreshUI()
  }

  func overlayView(_ overlayView: ImageAnalysisOverlayView,
                   shouldBeginAt point: CGPoint,
                   forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes) -> Bool {
    return true
  }

  func overlayView(_ overlayView: ImageAnalysisOverlayView, willOpen menu: NSMenu) {
    isMenuOpen = true
    refreshUI()
  }

  func overlayView(_ overlayView: ImageAnalysisOverlayView, didClose menu: NSMenu) {
    isMenuOpen = false
    refreshUI()
  }

  func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
    isSelected = overlayView.hasActiveTextSelection
    refreshUI()
  }

  func overlayView(_ overlayView: ImageAnalysisOverlayView,
                   highlightSelectedItemsDidChange highlightSelectedItems: Bool) {
    isHighlighted = highlightSelectedItems
    refreshUI()
  }
}
