//
//  PrefUtilsViewController.swift
//  iina
//
//  Created by Collider LI on 9/7/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa
import UniformTypeIdentifiers

class PrefUtilsViewController: PreferenceViewController, PreferenceWindowEmbeddable {

  override var nibName: NSNib.Name {
    return NSNib.Name("PrefUtilsViewController")
  }

  var preferenceTabTitle: String {
    return NSLocalizedString("preference.utilities", comment: "Utilities")
  }

  var preferenceTabImage: NSImage {
    return makeSymbol("wrench.and.screwdriver", fallbackImage: "pref_utils")
  }

  override var sectionViews: [NSView] {
    return [sectionDefaultAppView, sectionRestoreAlertsView, sectionBrowserExtView]
  }

  @IBOutlet var sectionDefaultAppView: NSView!
  @IBOutlet var sectionRestoreAlertsView: NSView!
  @IBOutlet var sectionBrowserExtView: NSView!
  @IBOutlet var setAsDefaultSheet: NSWindow!
  @IBOutlet weak var setAsDefaultVideoCheckBox: NSButton!
  @IBOutlet weak var setAsDefaultAudioCheckBox: NSButton!
  @IBOutlet weak var setAsDefaultPlaylistCheckBox: NSButton!
  @IBOutlet weak var restoreAlertsRestoredLabel: NSTextField!

  @IBAction func setIINAAsDefaultAction(_ sender: Any) {
    view.window!.beginSheet(setAsDefaultSheet)
  }

  @IBAction func setAsDefaultOKBtnAction(_ sender: Any) {

    guard
      let utiImportedTypes = Bundle.main.infoDictionary?["UTImportedTypeDeclarations"] as? [[String: Any]],
      let cfBundleID = Bundle.main.bundleIdentifier as CFString?
    else { return }

    Logger.log("Setting this app as default")

    var successCount = 0
    var failedCount = 0

    let utiChecked = [
      "public.movie": setAsDefaultVideoCheckBox.state == .on,
      "public.audio": setAsDefaultAudioCheckBox.state == .on,
      "public.text": setAsDefaultPlaylistCheckBox.state == .on
    ]

    var utiTargetSet: Set<String> = []
    for utiImportedType in utiImportedTypes {
      guard
        let identifier = utiImportedType["UTTypeIdentifier"] as? String,
        let conformsTo = utiImportedType["UTTypeConformsTo"] as? [String],
        let tagSpec = utiImportedType["UTTypeTagSpecification"] as? [String: Any],
        let exts = tagSpec["public.filename-extension"] as? [String]
      else {
        return
      }

      // make sure that `conformsTo` contains a checked UTI type
      guard utiChecked.map({ (uti, checked) in checked && conformsTo.contains(uti) }).contains(true) else {
        continue
      }

      Logger.log.verbose("UTImportedType: \(identifier.quoted) ➤ \(exts)")
      for ext in exts {
        if #available(macOS 11.0, *) {
          let uttypesForExt = UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil)
          for uttype in uttypesForExt {
            utiTargetSet.insert(uttype.identifier)
          }
        } else {
          let unmanagedArray = UTTypeCreateAllIdentifiersForTag(kUTTagClassFilenameExtension, ext as CFString, nil)
          let utiArray = unmanagedArray!.takeUnretainedValue() as NSArray as! [String]
          for uti in utiArray {
            utiTargetSet.insert(uti)
          }
        }
      }
    }

    for identifier in utiTargetSet {
      Logger.log.verbose("Setting default for UTI: \(identifier.quoted)")
      let status = LSSetDefaultRoleHandlerForContentType(identifier as CFString, .all, cfBundleID)
      if status == kOSReturnSuccess {
        successCount += 1
      } else {
        Logger.log.error("Failed for \(identifier.quoted): return value \(status)")
        failedCount += 1
      }
    }

    Utility.showAlert("set_default.success", arguments: [successCount, failedCount], style: .informational,
                      sheetWindow: view.window)
    view.window!.endSheet(setAsDefaultSheet)
  }

  @IBAction func setAsDefaultCancelBtnAction(_ sender: Any) {
    view.window!.endSheet(setAsDefaultSheet)
  }

  @IBAction func resetSuppressedAlertsBtnAction(_ sender: Any) {
    Utility.quickAskPanel("restore_alerts", sheetWindow: view.window) { respond in
      guard respond == .alertFirstButtonReturn else { return }
      // This operation used to restore an alert about preventing display sleeping failing. That
      // alert has been removed so at this time we do not have any alerts that can be suppressed.
      // That might change in the future, so for now we are retaining this operation.
      self.restoreAlertsRestoredLabel.isHidden = false
    }
  }

  @IBAction func extChromeBtnAction(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: AppData.chromeExtensionLink)!)
  }

  @IBAction func extFirefoxBtnAction(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: AppData.firefoxExtensionLink)!)
  }
}
