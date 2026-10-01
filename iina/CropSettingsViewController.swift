//
//  CropSettingsViewController.swift
//  iina
//
//  Created by lhc on 22/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

class CropSettingsViewController: CropBoxViewController {

  @IBOutlet weak var cropRectLabel: NSTextField!
  @IBOutlet weak var aspectPresetsSegment: NSSegmentedControl!
  @IBOutlet weak var aspectEntryTextField: NSTextField!

  override func viewDidLoad() {
    super.viewDidLoad()
    self.view.idString = "CropSettingsView"
    // The target view will be destroyed & recreated each time interactive mode is entered
    updateSegmentLabels()
  }

  func updateSegmentLabels() {
    if let segmentLabels = Preference.csvStringArray(for: .cropPanelPresets) {
      aspectPresetsSegment.segmentCount = segmentLabels.count + 1
      for segmentIndex in 1..<aspectPresetsSegment.segmentCount {
        if segmentIndex <= segmentLabels.count {
          let newLabel = segmentLabels[segmentIndex - 1]
          aspectPresetsSegment.setLabel(newLabel, forSegment: segmentIndex)
        }
      }
    }
  }

  override func selectedRectUpdated() {
    super.selectedRectUpdated()
    guard view.superview != nil else { return }

    defer {
      cropBoxView.needsLayout = true
      cropBoxView.needsDisplay = true
    }

    cropRectLabel.stringValue = readableCropString

    let originalVideoSize = cropBoxView.originalVideoSize
    if cropx == 0, cropy == 0, (cropw == 0 && croph == 0) || (cropw == originalVideoSize.widthInt && croph == originalVideoSize.heightInt) {
      // No crop
      pwc.log.verbose("Selecting crop preset segment 0 (no crop)")
      aspectPresetsSegment.selectedSegment = 0
      aspectEntryTextField.stringValue = ""
      return
    }

    // Try to match to segment:
    for segmentIndex in 1..<aspectPresetsSegment.segmentCount {
      guard let segmentLabel = aspectPresetsSegment.label(forSegment: segmentIndex) else { continue }
      guard let aspect = Aspect(string: segmentLabel) else { continue }

      if isCropRectMatchedWithAsepct(aspect) {
        pwc.log.verbose("Selecting crop preset segment \(segmentIndex)")
        aspectPresetsSegment.selectedSegment = segmentIndex
        aspectEntryTextField.stringValue = ""
        return
      }
    }

    // Freeform selection or text entry
    pwc.log.verbose("Selecting crop preset segment: N/A (freeform or text entry)")
    aspectPresetsSegment.selectedSegment = -1

    let textEntryString = aspectEntryTextField.stringValue
    if !textEntryString.isEmpty {
      if let aspect = Aspect(string: textEntryString), !isCropRectMatchedWithAsepct(aspect) {
        aspectEntryTextField.stringValue = ""
      }
    }
  }

  private func isCropRectMatchedWithAsepct(_ aspect: Aspect) -> Bool {
    let cropped = cropBoxView.originalVideoSize.getCropRect(withAspect: aspect)
    return abs(Int(cropped.size.width) - cropw) <= 1 &&
    abs(Int(cropped.size.height) - croph) <= 1 &&
    abs(Int(cropped.origin.x) - cropx) <= 1 &&
    abs(Int(cropped.origin.y) - cropy) <= 1
  }

  override func handleKeyDown(mpvKeyCode: String) {
    switch mpvKeyCode {
    case "ESC":
      cancelBtnAction(self)
    case "ENTER":
      doneBtnAction(self)
    default:
      break
    }
  }

  func submitCrop() {
    let cropBox = NSRect(x: cropx, y: cropy, width: cropw, height: croph)
    // If crop is too tall, the aspect will round to zero, which won't work=
    guard cropBox.size.mpvAspect > 0 else {
      Utility.showAlert("crop_too_extreme")
      return
    }

    // Start drawing again for the sake of animation
    pwc.videoView.displayActive()

    let player = pwc.player
    // Remove saved crop (if any)
    player.info.videoFiltersDisabled.removeValue(forKey: Constants.FilterLabel.crop)

    let videoSizeRaw = cropBoxView.originalVideoSize
    // Use <=, >= to account for imprecision
    let isAllSelected = cropBox.origin.x <= 0 && cropBox.origin.y <= 0 && cropBox.width >= videoSizeRaw.width && cropBox.height >= videoSizeRaw.height
    let isNoSelection = cropBox.width <= 0 || cropBox.height <= 0
    let vidGeo = player.pwc.geo.video

    player.mpv.queue.async { [self] in
      let newVidGeo: VideoGeometry
      if isAllSelected || isNoSelection {
        player.log.verbose("Interactive mode submit: isAllSelected=\(isAllSelected.yn) isNoSelection=\(isNoSelection.yn) → setting crop to None")
        newVidGeo = vidGeo.clone(selectedCropLabel: StringConstants.noneCropIdentifier, videoSizeDisplayOverride: nil)
      } else {
        // FIXME: account for codec rotation
        let newCropFilter = MPVFilter.crop(w: cropBox.widthInt, h: cropBox.heightInt, x: cropBox.xInt, y: cropBox.yInt)
        player.log.verbose("Submitting from interactive mode with new crop: (\(cropBox)")

        guard let newCropLabel = player.deriveCropLabel(from: newCropFilter, rawVideoSize: videoSizeRaw) else {
          player.log.error("Could not generate crop label from the newly created filter!")
          return
        }
        newVidGeo = vidGeo.clone(selectedCropLabel: newCropLabel, videoSizeDisplayOverride: nil)
      }
      pwc.exitInteractiveMode(newVidGeo: newVidGeo)
    }
  }

  @IBAction func doneBtnAction(_ sender: AnyObject) {
    pwc.player.log.verbose("Interactive mode: user chose Done button")

    submitCrop()
  }

  @IBAction func cancelBtnAction(_ sender: AnyObject) {
    let player = pwc.player
    if let prevCropFilter = player.info.videoFiltersDisabled[Constants.FilterLabel.crop] {
      /// Prev filter exists. Re-apply it
      player.log.verbose("User chose Cancel button from interactive mode: restoring prev crop and exiting interactive mode")
      let cropBoxRect = prevCropFilter.cropRect(origVideoSize: cropBoxView.originalVideoSize)
      /// Need to update these because they will be read when `video-reconfig` is received
      cropw = Int(cropBoxRect.width)
      croph = Int(cropBoxRect.height)
      cropx = Int(cropBoxRect.origin.x)
      cropy = Int(cropBoxRect.origin.y)
    } else {
      player.log.verbose("User chose Cancel button from interactive mode (no prev crop)")
      let videoSizeRaw = cropBoxView.originalVideoSize
      cropw = Int(videoSizeRaw.width)
      croph = Int(videoSizeRaw.height)
      cropx = 0
      cropy = 0
    }
    submitCrop()
  }

  @IBAction func predefinedAspectValueAction(_ sender: NSSegmentedControl) {
    guard let str = sender.label(forSegment: sender.selectedSegment) else { return }
    adjustCropBoxView(ratio: str)
  }

  @IBAction func customCropEditFinishedAction(_ sender: NSTextField) {
    adjustCropBoxView(ratio: sender.stringValue)
  }

  private func adjustCropBoxView(ratio: String) {
    guard let aspect = Aspect(string: ratio) else {
      // Fall back to selecting all
      pwc.log.error("Failed to get aspect from string \(ratio.quoted); falling back to select all")
      cropBoxView.setSelectedRect(to: NSRect(origin: CGPointZero, size: cropBoxView.originalVideoSize))
      return
    }

    let originalVideoSize = cropBoxView.originalVideoSize
    let cropped = originalVideoSize.getCropRect(withAspect: aspect)
    pwc.log.error("Adjusting cropBoxView to \(cropped)")
    cropBoxView.setSelectedRect(to: cropped)
  }

}
