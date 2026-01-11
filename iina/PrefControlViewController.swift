//
//  PrefControlViewController.swift
//  iina
//
//  Created by lhc on 20/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

@objcMembers
class PrefControlViewController: PreferenceViewController, PreferenceWindowEmbeddable {

  override var nibName: NSNib.Name {
    return NSNib.Name("PrefControlViewController")
  }

  var preferenceTabTitle: String {
    return NSLocalizedString("preference.control", comment: "Control")
  }

  var preferenceTabImage: NSImage {
    return makeSymbol("computermouse", fallbackImage: "pref_control")
  }

  override var sectionViews: [NSView] {
    return [sectionTrackpadView, sectionMouseView]
  }

  @IBOutlet var sectionTrackpadView: NSView!
  @IBOutlet var sectionMouseView: NSView!

  @IBOutlet var videoZoomContainerView: NSView!
  @IBOutlet var touchpadGridView: NSGridView!

  @IBOutlet weak var forceTouchLabel: NSTextField!
  @IBOutlet weak var scrollVerticallyLabel: NSTextField!

  @IBOutlet weak var seekScrollSensitivityLabel: NSTextField!
  @IBOutlet weak var volumeScrollSensitivityLabel: NSTextField!

  @IBOutlet var relativeSeekAmountSlider: NSSlider!
  @IBOutlet var volumeScrollAmountSlider: NSSlider!

  /// Weak reference to `PreferenceWindowController.animationPipeline`.
  private unowned var animationPipeline: IINAAnimation.Pipeline!

  var notiHandler: NotificationHandler! = nil

  private let prefsToWatch: [Preference.Key] = [
    .relativeSeekAmount,
    .volumeScrollAmount,
    .pinchAction,
    .enablePinchToVideoZoom,
  ]

  override func viewDidLoad() {
    super.viewDidLoad()

    animationPipeline = AppDelegate.shared.preferenceWindowController.animationPipeline
    configureObservers()

    IINAAnimation.disableAnimation {
      updateUIFromPrefs()
    }
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    notiHandler.addAllObservers()
    updateUIFromPrefs()
  }

  override func viewWillDisappear() {
    notiHandler.removeAllObservers()
  }

  // MARK: Observers

  private func configureObservers() {
    notiHandler = NotificationHandler(Logger.log, prefDidChange: prefDidChange, prefsToWatch)
  }

  /// Called each time a pref `key`'s value is set
  func prefDidChange(_ key: Preference.Key, _ newValue: Any?) {
    guard prefsToWatch.contains(key) else { return }

    updateUIFromPrefs()
  }

  private func updateUIFromPrefs() {
    let pinchAction: Preference.PinchAction = Preference.enum(for: .pinchAction)
    let hideZoomControls: Bool
    switch pinchAction {
    case .windowSize, .windowSizeOrFullScreen:
      hideZoomControls = false
    default:
      hideZoomControls = true
    }

    // 2-phase animation
    let hideTaks: [IINAAnimation.Task] = [
      .instantTask{ [self] in
        videoZoomContainerView.animator().isHidden = hideZoomControls
      },

        .init{ [self] in
          touchpadGridView.row(at: 1).isHidden = hideZoomControls
        },
    ]
    animationPipeline.submit(hideZoomControls ? hideTaks : hideTaks.reversed())

    updateLabels()
  }

  private func updateLabels() {
    seekScrollSensitivityLabel.stringValue = Preference.seekScrollSensitivity().stringMaxFrac2 + "x"
    volumeScrollSensitivityLabel.stringValue = Preference.volumeScrollSensitivity().stringMaxFrac2 + "x"
  }
}
