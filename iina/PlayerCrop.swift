//
//  CropFilter.swift
//  iina
//
//  Created by Matt Svoboda on 4/9/24.
//  Copyright © 2024 lhc. All rights reserved.
//

import Foundation

extension PlayerCore {

  func deriveCropLabel(from filter: MPVFilter) -> String? {
    if let p = filter.params, let wStr = p["w"], let hStr = p["h"],
       let w = Double(wStr), let h = Double(hStr),
       p["x"] == nil && p["y"] == nil {
      // Probably a selection from the Quick Settings panel. See if there are any matches.
      guard w != 0, h != 0 else {
        log.error("Cannot get crop from filter \(filter.label?.quoted ?? ""): w or h is 0")
        return nil
      }
      // Truncate to 2 decimal places precision for comparison.
      let selectedAspect = (w / h).roundedTo2()
      log.verbose("Determined aspect=\(selectedAspect) from filter \(filter.label?.quoted ?? "")")
      if let segmentLabels = Preference.csvStringArray(for: .cropPanelPresets) {
        // Resolve against built-in labels as well as user labels:
        let allRecognizedAspects = AppData.aspectsInMenu + segmentLabels
        for aspectCropLabel in allRecognizedAspects {
          let tokens = aspectCropLabel.split(separator: ":")
          if tokens.count == 2, let width = Double(tokens[0]), let height = Double(tokens[1]) {
            let aspectRatio = (width / height).roundedTo2()
            if aspectRatio == selectedAspect {
              log.verbose("Filter \(filter.label?.quoted ?? "") matches known crop \(aspectCropLabel.quoted)")
              return aspectCropLabel  // Known aspect-based crop
            }
          }
        }
      }
      let customCropBoxLabel = MPVFilter.makeCropBoxParamString(from: NSSize(width: w, height: h))
      log.verbose("Unrecognized aspect-based crop for filter \(filter.label?.quoted ?? ""). Generated label: \(customCropBoxLabel.quoted)")
      return customCropBoxLabel  // Custom aspect-based crop
    } else if let p = filter.params,
              let xStr = p["x"], let x = Int(xStr),
              let yStr = p["y"], let y = Int(yStr),
              let wStr = p["w"], let w = Int(wStr),
              let hStr = p["h"], let h = Int(hStr) {
      // Probably a custom crop. Use mpv formatting
      let cropBoxRect = NSRect(x: x, y: y, width: w, height: h)
      let customCropBoxLabel = MPVFilter.makeCropBoxParamString(from: cropBoxRect)
      log.verbose("Filter \(filter.label?.quoted ?? "") looks like custom crop. Sending selected crop to \(customCropBoxLabel.quoted)")
      return customCropBoxLabel  // Custom cropBox rect crop
    }
    return nil
  }

  func setCrop(fromLabel newCropLabel: String) {
    guard let vf = videoGeo.buildCropFilter(from: newCropLabel) else {
      removeCrop()
      return
    }

    mpv.queue.async { [self] in
      windowController.applyVideoGeoTransform("setCrop", { [self] videoGeo in
        guard videoGeo.selectedCropLabel != newCropLabel else { return nil }

        log.verbose("Changing videoGeo selectedCropLabel \(videoGeo.selectedCropLabel.quoted) → \(newCropLabel.quoted)")

        let osdLabel = newCropLabel.isEmpty ? AppData.customCropIdentifier : newCropLabel
        sendOSD(.crop(osdLabel))

        return videoGeo.clone(selectedCropLabel: newCropLabel)

      }, then: { [self] in
        /// No need to call `updateSelectedCrop` - it will be called by `addVideoFilter`
        let addSucceeded = addVideoFilter(vf)
        if !addSucceeded {
          log.error("Failed to add crop filter \(newCropLabel.quoted); setting crop to None")
          _removeCrop()
        }
        reloadQuickSettingsView()
      })
    }

  }

  func removeCrop() {
    mpv.queue.async { [self] in
      _removeCrop()
    }
  }

  func _removeCrop() {
    // special kludge when removing crop while entering interactive mode
    guard !info.videoFiltersDisabled.keys.contains(Constants.FilterLabel.crop) else {
      log.verbose("Ignoring request to remove crop because looks like we are transitioning to interactive mode")
      return
    }

    windowController.applyVideoGeoTransform("removeCrop", { [self] videoGeo in
      guard let cropFilter = videoGeo.cropFilter else { return nil }
      guard videoGeo.selectedCropLabel != AppData.noneCropIdentifier else { return nil }

      log.verbose("Setting crop to \(AppData.noneCropIdentifier.quoted) and removing crop filter")

      mpv.queue.async { [self] in
        removeVideoFilter(cropFilter, verify: false, notify: false)
      }
      return videoGeo.clone(selectedCropLabel: AppData.noneCropIdentifier)

    }, then: { [self] in
      reloadQuickSettingsView()
    })
  }

  func updateSelectedCrop(to newCropLabel: String) {
    assert(DispatchQueue.isExecutingIn(mpv.queue))

    windowController.applyVideoGeoTransform("updateCrop", { [self] videoGeo in
      guard videoGeo.selectedCropLabel != newCropLabel else { return nil }

      log.verbose("[applyVideoGeo:transform]: changing selectedCropLabel \(videoGeo.selectedCropLabel.quoted) → \(newCropLabel.quoted)")

      let osdLabel = newCropLabel.isEmpty ? AppData.customCropIdentifier : newCropLabel
      sendOSD(.crop(osdLabel))

      return videoGeo.clone(selectedCropLabel: newCropLabel)

    }, then: { [self] in
      reloadQuickSettingsView()
    })
  }
}

