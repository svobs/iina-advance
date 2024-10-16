//
//  MiniPlayerController.swift
//  iina
//
//  Created by lhc on 30/7/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

class MiniPlayerController: NSViewController, NSPopoverDelegate {
  static let controlViewHeight: CGFloat = 72
  static let defaultWindowWidth: CGFloat = 280
  static let minWindowWidth: CGFloat = 260
  // Hide playlist if its height is too small to display at least 3 items:
  static let PlaylistMinHeight: CGFloat = 138
  static private let animationDurationShowControl: TimeInterval = 0.2

  override var nibName: NSNib.Name {
    return NSNib.Name("MiniPlayerController")
  }

  @objc let monospacedFont: NSFont = {
    let fontSize = NSFont.systemFontSize(for: .mini)
    return NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
  }()

  @IBOutlet weak var volumeSlider: NSSlider!
  @IBOutlet weak var muteButton: NSButton!
  @IBOutlet weak var playButton: NSButton!
  @IBOutlet weak var playSlider: PlaySlider!
  @IBOutlet weak var rightLabel: DurationDisplayTextField!
  @IBOutlet weak var leftLabel: DurationDisplayTextField!

  @IBOutlet weak var volumeButton: NSButton!
  @IBOutlet var volumePopover: NSPopover!
  @IBOutlet weak var volumeSliderView: NSView!
  @IBOutlet weak var backgroundView: NSVisualEffectView!
  @IBOutlet weak var playlistWrapperView: NSVisualEffectView!
  @IBOutlet weak var mediaInfoView: NSView!
  @IBOutlet weak var controlView: NSView!
  @IBOutlet weak var titleLabel: ScrollingTextField!
  @IBOutlet weak var titleLabelTopConstraint: NSLayoutConstraint!
  @IBOutlet weak var artistAlbumLabel: ScrollingTextField!
  @IBOutlet weak var volumeLabel: NSTextField!
  @IBOutlet weak var togglePlaylistButton: NSButton!
  @IBOutlet weak var toggleAlbumArtButton: NSButton!

  unowned var windowController: PlayWindowController!
  var player: PlayerCore {
    return windowController.player
  }

  var window: NSWindow? {
    return windowController.window
  }

  var log: Logger.Subsystem {
    return windowController.log
  }

  var isPlaylistVisible: Bool {
    get {
      windowController.musicModeGeometry.isPlaylistVisible
    }
  }

  var isVideoVisible: Bool {
    get {
      return windowController.musicModeGeometry.isVideoVisible
    }
  }

  static var maxWindowWidth: CGFloat {
    return CGFloat(Preference.float(for: .musicModeMaxWidth))
  }

  lazy var hideVolumePopover: DispatchWorkItem = {
    DispatchWorkItem {
      self.volumePopover.animates = true
      self.volumePopover.performClose(self)
    }
  }()

  var currentDisplayedPlaylistHeight: CGFloat {
    // most reliable first-hand source for this is a constraint:
    let bottomBarHeight = -windowController.videoContainerBottomOffsetFromBottomBarBottomConstraint.constant
    return bottomBarHeight - MiniPlayerController.controlViewHeight
  }

  // MARK: - Initialization

  override func viewDidLoad() {
    super.viewDidLoad()

    backgroundView.heightAnchor.constraint(equalToConstant: MiniPlayerController.controlViewHeight).isActive = true

    /// Set up tracking area to show controller when hovering over it
    windowController.videoContainerView.addTrackingArea(NSTrackingArea(rect: windowController.videoContainerView.bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil))
    backgroundView.addTrackingArea(NSTrackingArea(rect: backgroundView.bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil))

    // close button
    windowController.closeButtonVE.action = #selector(windowController.close)
    windowController.closeButtonBox.action = #selector(windowController.close)
    windowController.closeButtonBackgroundViewVE.roundCorners(withRadius: 8)

    // hide controls initially
    windowController.closeButtonBackgroundViewBox.isHidden = true
    windowController.closeButtonBackgroundViewVE.isHidden = true
    windowController.closeButtonView.alphaValue = 0
    controlView.alphaValue = 0
    
    // tool tips
    togglePlaylistButton.toolTip = Preference.ToolBarButton.playlist.description()
    toggleAlbumArtButton.toolTip = NSLocalizedString("mini_player.album_art", comment: "album_art")
    volumeButton.toolTip = NSLocalizedString("mini_player.volume", comment: "volume")
    windowController.closeButtonVE.toolTip = NSLocalizedString("mini_player.close", comment: "close")
    windowController.backButtonVE.toolTip = NSLocalizedString("mini_player.back", comment: "back")

    volumePopover.delegate = self

    leftLabel.mode = .current
    rightLabel.mode = Preference.bool(for: .showRemainingTime) ? .remaining : .duration

    log.verbose("MiniPlayer viewDidLoad done")
  }

  // MARK: - Mouse / Trackpad events

  override func mouseEntered(with event: NSEvent) {
    showControl()
  }

  override func mouseExited(with event: NSEvent) {
    guard !volumePopover.isShown else { return }
    /// The goal is to always show the control when the cursor is hovering over either of the 2 tracking areas.
    /// Although they are adjacent to each other, `mouseExited` can still be called when moving from one to the other.
    /// Detect and ignore this case.
    guard !windowController.isMouseEvent(event, inAnyOf: [backgroundView, windowController.videoContainerView]) else {
      return
    }

    hideControl()
  }

  // MARK: - UI: Show / Hide

  private func showControl() {
    windowController.animationQueue.run(CocoaAnimation.Task(duration: MiniPlayerController.animationDurationShowControl, { [self] in
      windowController.closeButtonView.animator().alphaValue = 1
      controlView.animator().alphaValue = 1
      mediaInfoView.animator().alphaValue = 0
    }))
  }

  private func hideControl() {
    windowController.animationQueue.run(CocoaAnimation.Task(duration: MiniPlayerController.animationDurationShowControl, { [self] in
      windowController.closeButtonView.animator().alphaValue = 0
      controlView.animator().alphaValue = 0
      mediaInfoView.animator().alphaValue = 1
    }))
  }

  // MARK: - UI

  func updateScrollingLabels() {
    titleLabel.stepNext()
    artistAlbumLabel.stepNext()
  }

  private func resetScrollingLabels() {
    _ = view  // make sure views load to avoid crashes from unwrapping nil Optionals
    titleLabel.reset()
    artistAlbumLabel.reset()
  }

  private func saveDefaultPlaylistHeight() {
    let playlistHeight = round(currentDisplayedPlaylistHeight)
    guard playlistHeight >= MiniPlayerController.PlaylistMinHeight else { return }

    // save playlist height
    log.verbose("Saving playlist height: \(playlistHeight)")
    Preference.set(playlistHeight, for: .musicModePlaylistHeight)
  }

  func updateTitle(mediaTitle: String, mediaAlbum: String, mediaArtist: String) {
    titleLabel.stringValue = mediaTitle
    // hide artist & album label when info not available
    if mediaArtist.isEmpty && mediaAlbum.isEmpty {
      titleLabelTopConstraint.constant = 6 + 10
      artistAlbumLabel.stringValue = ""
    } else {
      titleLabelTopConstraint.constant = 6
      if mediaArtist.isEmpty || mediaAlbum.isEmpty {
        artistAlbumLabel.stringValue = "\(mediaArtist)\(mediaAlbum)"
      } else {
        artistAlbumLabel.stringValue = "\(mediaArtist) - \(mediaAlbum)"
      }
    }
  }

  func updateVolumeUI() {
    let vol = player.info.volume
    volumeSlider.doubleValue = vol
    volumeLabel.intValue = Int32(vol)
    if player.info.isMuted {
      volumeButton.image = NSImage(named: "mute")
    } else {
      switch volumeLabel.intValue {
      case 0:
        volumeButton.image = NSImage(named: "volume-0")
      case 1...33:
        volumeButton.image = NSImage(named: "volume-1")
      case 34...66:
        volumeButton.image = NSImage(named: "volume-2")
      case 67...1000:
        volumeButton.image = NSImage(named: "volume")
      default:
        break
      }
    }
  }

  // MARK: - NSPopoverDelegate

  func popoverWillClose(_ notification: Notification) {
    if NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) != window!.windowNumber {
      hideControl()
    }
  }

  func handleVolumePopover(_ isTrackpadBegan: Bool, _ isTrackpadEnd: Bool, _ isMouse: Bool) {
    hideVolumePopover.cancel()
    hideVolumePopover = DispatchWorkItem {
      self.volumePopover.animates = true
      self.volumePopover.performClose(self)
    }
    if isTrackpadBegan {
       // enabling animation here causes user not seeing their volume changes during popover transition
       volumePopover.animates = false
       volumePopover.show(relativeTo: volumeButton.bounds, of: volumeButton, preferredEdge: .minY)
     } else if isTrackpadEnd {
       DispatchQueue.main.asyncAfter(deadline: .now(), execute: hideVolumePopover)
     } else if isMouse {
       // if it's a mouse, simply show popover then hide after a while when user stops scrolling
       if !volumePopover.isShown {
         volumePopover.animates = false
         volumePopover.show(relativeTo: volumeButton.bounds, of: volumeButton, preferredEdge: .minY)
       }
       let timeout = Preference.double(for: .osdAutoHideTimeout)
       DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: hideVolumePopover)
     }
  }

  // MARK: - IBActions

  @IBAction func playSliderChanges(_ sender: NSSlider) {
    windowController.playSliderChanges(sender)
  }

  @IBAction func volumeSliderChanges(_ sender: NSSlider) {
    windowController.volumeSliderChanges(sender)
  }

  @IBAction func muteButtonAction(_ sender: NSButton) {
    player.toggleMute()
  }

  @IBAction func playButtonAction(_ sender: NSButton) {
    windowController.playButtonAction(sender)
  }

  @IBAction func nextBtnAction(_ sender: NSButton) {
    player.navigateInPlaylist(nextMedia: true)
  }

  @IBAction func prevBtnAction(_ sender: NSButton) {
    player.navigateInPlaylist(nextMedia: false)
  }

  @IBAction func volumeBtnAction(_ sender: NSButton) {
    if volumePopover.isShown {
      volumePopover.performClose(self)
    } else {
      updateVolumeUI()
      volumePopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
  }

  @IBAction func togglePlaylist(_ sender: Any) {
    guard let window = windowController.window else { return }
    let showPlaylist = !isPlaylistVisible
    Logger.log("Toggling playlist visibility from \((!showPlaylist).yn) to \(showPlaylist.yn)", level: .verbose)
    let currentDisplayedPlaylistHeight = currentDisplayedPlaylistHeight
    let oldGeometry = windowController.musicModeGeometry
    var newWindowFrame = window.frame

    if showPlaylist {
      windowController.playlistView.reloadData(playlist: true, chapters: true)

      // Try to show playlist using previous height
      let desiredPlaylistHeight = oldGeometry.playlistHeight
      // The window may be in the middle of a previous toggle, so we can't just assume window's current frame
      // represents a state where the playlist is fully shown or fully hidden. Instead, start by computing the height
      // we want to set, and then figure out the changes needed to the window's existing frame.
      let targetHeightToAdd = desiredPlaylistHeight - currentDisplayedPlaylistHeight
      // Fill up screen if needed
      newWindowFrame.size.height += targetHeightToAdd
    } else { // hide playlist
      // Save playlist height first
      saveDefaultPlaylistHeight()
      newWindowFrame.size.height -= currentDisplayedPlaylistHeight
    }

    let heightDifference = newWindowFrame.height - window.frame.height
    // adjust window origin to expand downwards
    newWindowFrame.origin.y = newWindowFrame.origin.y - heightDifference

    // Constrain window so that it doesn't expand below bottom of screen, or fall offscreen
    let newGeometry = oldGeometry.clone(windowFrame: newWindowFrame, isPlaylistVisible: showPlaylist)

    windowController.animationQueue.run(CocoaAnimation.Task(duration: CocoaAnimation.DefaultDuration, timing: .easeInEaseOut, { [self] in
      Preference.set(showPlaylist, for: .musicModeShowPlaylist)
      windowController.applyMusicModeGeometry(newGeometry)
    }))
  }

  @IBAction func toggleVideoView(_ sender: Any) {
    let showVideo = !isVideoVisible
    log.verbose("Toggling videoView visibility from \((!showVideo).yn) to \(showVideo.yn)")

    let oldGeometry = windowController.musicModeGeometry
    var newWindowFrame = oldGeometry.windowFrame
    if showVideo {
      newWindowFrame.size.height += oldGeometry.videoHeightIfVisible
    } else {
      newWindowFrame.size.height -= oldGeometry.videoHeightIfVisible
    }
    let newGeometry = oldGeometry.clone(windowFrame: newWindowFrame, isVideoVisible: showVideo)

    /// If needing to reactivate this constraint, do it before the toggle animation, so that window doesn't jump.
    /// (See note in `applyMusicModeGeometry` for why this constraint needed to be disabled in the first place)
    if showVideo {
      windowController.animationQueue.runZeroDuration({ [self] in
        windowController.videoContainerBottomOffsetFromContentViewBottomConstraint.isActive = true
        windowController.videoView.updateSizeConstraints(newGeometry.videoSize)
      })
    }

    windowController.animationQueue.run(CocoaAnimation.Task(duration: CocoaAnimation.DefaultDuration, timing: .easeInEaseOut, { [self] in
      Preference.set(showVideo, for: .musicModeShowAlbumArt)

      log.verbose("VideoView setting visible=\(showVideo), videoHeight=\(newGeometry.videoHeight)")
      windowController.window?.contentView?.layout()
      windowController.applyMusicModeGeometry(newGeometry, animate: false)
    }))

  }

  // MARK: - Window size & layout

  func windowDidResize() {
    _ = view
    resetScrollingLabels()
    // Do not save musicModeGeometry here! Pinch gesture will handle itself. Drag-to-resize will be handled below.
  }

  // Presumable playlist size was affected by the resize. Update the default playlist size to match
  func windowDidEndLiveResize() {
    if isPlaylistVisible {
      saveDefaultPlaylistHeight()
    }
    applyGeometryAfterResize(newWindowFrame: window!.frame)
  }

  func windowWillResize(_ window: NSWindow, to requestedSize: NSSize) -> NSSize {
    resetScrollingLabels()

    if !window.inLiveResize && requestedSize.width <= MiniPlayerController.minWindowWidth {
      // Responding with the current size seems to work much better with certain window management tools
      // (e.g. BetterTouchTool's window snapping) than trying to respond with the min size,
      // which seems to result in the window manager retrying with different sizes, which results in flickering.
      player.log.verbose("WindowWillResize: requestedSize smaller than min \(MiniPlayerController.minWindowWidth); returning existing size")
      return window.frame.size
    }

    let requestedWindowFrame = NSRect(origin: windowController.musicModeGeometry.windowFrame.origin, size: requestedSize)
    applyGeometryAfterResize(newWindowFrame: requestedWindowFrame)

    return windowController.musicModeGeometry.windowFrame.size
  }

  private func applyGeometryAfterResize(newWindowFrame: NSRect) {
    let newGeometry = windowController.musicModeGeometry.clone(windowFrame: newWindowFrame)
    CocoaAnimation.disableAnimation{
      /// this will set `windowController.musicModeGeometry` after applying any necessary constraints
      windowController.applyMusicModeGeometry(newGeometry, setFrame: false)
    }
  }

  func cleanUpForMusicModeExit() {
    log.verbose("Cleaning up for music mode exit")
    view.removeFromSuperview()

    /// Remove `playlistView` from wrapper. It will be added elsewhere if/when it is needed there
    windowController.playlistView.view.removeFromSuperview()

    // make sure this is enabled
    windowController.videoContainerBottomOffsetFromContentViewBottomConstraint.isActive = true
  }

  func applyVideoViewVisibilityConstraints(isVideoVisible: Bool) {
    log.verbose("Applying videoView visibility=\(isVideoVisible.yesno)")
    player.disableUI = !isVideoVisible

    if isVideoVisible {
      // Remove zero-height constraint
      if let heightContraint = windowController.videoContainerViewHeightContraint {
        heightContraint.isActive = false
        windowController.videoContainerViewHeightContraint = nil
      }
    } else {
      // Add or reactivate zero-height constraint
      if let heightConstraint = windowController.videoContainerViewHeightContraint {
        heightConstraint.isActive = true
      } else {
        let heightConstraint = windowController.videoContainerView.heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
        windowController.videoContainerViewHeightContraint = heightConstraint
      }
    }

    windowController.videoContainerView.layoutSubtreeIfNeeded()
    windowController.videoView.videoLayer.draw(forced: true)
  }

  func adjustLayoutForVideoChange(newVideoAspectRatio: CGFloat) {
    resetScrollingLabels()

    windowController.animationQueue.run(CocoaAnimation.Task{ [self] in
      /// Keep prev `windowFrame`. Just adjust height to fit new video aspect ratio
      /// (unless it doesn't fit in screen; see `applyMusicModeGeometry()`)
      let newGeometry = windowController.musicModeGeometry.clone(videoAspectRatio: newVideoAspectRatio)
      log.verbose("Updating music mode geometry for video change")
      windowController.applyMusicModeGeometry(newGeometry)
    })
  }

  func buildMusicModeGeometryFromPrefs() -> MusicModeGeometry {
    // Default to left-top of screen. Try to use last-saved playlist height and visibility settings.
    // TODO: just save the whole struct in a prefs entry
    let isPlaylistVisible = Preference.bool(for: .musicModeShowPlaylist)
    let isVideoVisible = Preference.bool(for: .musicModeShowAlbumArt)
    let desiredPlaylistHeight = CGFloat(Preference.float(for: .musicModePlaylistHeight))
    let videoAspectRatio = windowController.videoAspectRatio
    let desiredWindowWidth = MiniPlayerController.defaultWindowWidth
    let desiredVideoHeight = isVideoVisible ? desiredWindowWidth / videoAspectRatio : 0
    let desiredWindowHeight = desiredVideoHeight + MiniPlayerController.controlViewHeight + (isPlaylistVisible ? desiredPlaylistHeight : 0)

    let screenFrame = windowController.bestScreen.visibleFrame
    let windowSize = NSSize(width: desiredWindowWidth, height: desiredWindowHeight)
    let windowOrigin = NSPoint(x: screenFrame.origin.x, y: screenFrame.maxY - windowSize.height)
    let windowFrame = NSRect(origin: windowOrigin, size: windowSize)
    let desiredGeo = MusicModeGeometry(windowFrame: windowFrame, playlistHeight: desiredPlaylistHeight,
                                       isVideoVisible: isVideoVisible, isPlaylistVisible: isPlaylistVisible,
                                       videoAspectRatio: videoAspectRatio)
    // Resize as needed to fit on screen:
    return desiredGeo.constrainWithin(screenFrame)
  }
}
