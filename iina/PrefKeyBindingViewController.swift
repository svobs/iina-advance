//
//  PrefKeyBindingViewController.swift
//  iina
//
//  Created by lhc on 12/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

/// Root view for all `Settings` > `Key Bindings` UI.
///
/// For the Configuration ("Conf") table, see `ConfTableViewController`.
/// For the Key Bindings ("Binding") table, see `BindingTableViewController`
@objcMembers
class PrefKeyBindingViewController: PreferenceViewController, PreferenceWindowEmbeddable {

  override var nibName: NSNib.Name {
    return NSNib.Name("PrefKeyBindingViewController")
  }

  var preferenceTabTitle: String {
    return NSLocalizedString("preference.keybindings", comment: "Keybindings")
  }

  var preferenceTabImage: NSImage {
    return makeSymbol("keyboard.badge.ellipsis", fallbackImage: "pref_kb")
  }

  var preferenceContentIsScrollable: Bool {
    return false
  }

  private var confTableState: ConfTableState {
    return ConfTableState.current
  }

  private var bindingTableState: BindingTableState {
    return BindingTableState.current
  }

  private var confTableController: ConfTableViewController? = nil
  private var bindingTableController: BindingTableViewController? = nil

  private var observers: [NSObjectProtocol] = []

  private var searchActionDebouncer = Debouncer(delay: Constants.TimeInterval.keyBindingsSearchDebounceDelay)

  private var notiHandler: NotificationHandler!

  // MARK: - Outlets

  @IBOutlet weak var confTableView: EditableTableView!
  @IBOutlet weak var bindingTableView: EditableTableView!
  @IBOutlet weak var confHintLabel: NSTextField!
  @IBOutlet weak var bindingTotalsLabel: NSTextField!
  @IBOutlet weak var addBindingBtn: NSButton!
  @IBOutlet weak var removeBindingBtn: NSButton!
  @IBOutlet weak var showConfFileBtn: NSButton!
  @IBOutlet weak var deleteConfFileBtn: NSButton!
  @IBOutlet weak var newConfBtn: NSButton!
  @IBOutlet weak var duplicateConfBtn: NSButton!
  @IBOutlet weak var useMediaKeysButton: NSButton!
  @IBOutlet weak var bindingSearchField: NSSearchField!
  @IBOutlet weak var showFromAllSourcesBtn: NSButton!

  deinit {
    ObjcUtils.silenced { [self] in
      removeObserver(self, forKeyPath: #keyPath(view.effectiveAppearance))
    }
  }

  override func viewWillAppear() {
    Logger.log.verbose("Key Bindings pref pane will appear")
    super.viewWillAppear()
    BindingTableState.manager.notiHandler.addAllObservers()
    notiHandler.addAllObservers()
    BindingTableState.manager.applyStateUpdate(AppInputConfig.current)
    // Seems there is a race condition between the observer setup & the table update above?
    // Just patch it for now...
    updateBindingTotalsLabel()

    if DebugConfig.logBindingsRebuild {
      let keyList = PlayerManager.shared.getOrCreateDemo().mpv.getInputKeyList()
      Logger.log.debug("Key List (count=\(keyList.count)): \(keyList)")
    }
  }

  override func viewWillDisappear() {
    // Disable observers when not in use to save CPU
    Logger.log.verbose("Key Bindings pref pane will disappear")
    super.viewWillDisappear()
    notiHandler.removeAllObservers()
    BindingTableState.manager.notiHandler.removeAllObservers()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    bindingTableView.idString = "BindingTable"
    confTableView.idString = "ConfTable"

    // Need table updates to execute in serial queue
    let animationPipeline = AppDelegate.shared.preferenceWindowController.animationPipeline
    bindingTableView.animationPipeline = animationPipeline
    confTableView.animationPipeline = animationPipeline

    let currentState = ConfTableState.current

    // Load files into cache all at once; it should be fast enough (and doing so on an as-needed basis was not originally tested...)
    // But do not load them unless the user navigates to the Key Bindings preference pane.
    InputConfFileCache.fileDQ.async {
      let defaults = Constants.InputConf.defaults
      AppInputConfig.log.debug("Loading \(defaults.count) builtin conf files into cache")
      for confName in defaults.keys {
        InputConfFile.cache.getOrLoadConfFile(confName: confName)
      }

      AppInputConfig.log.debug("Loading \(currentState.userConfDict.count) user conf files into cache")
      for confName in currentState.userConfDict.keys {
        InputConfFile.cache.getOrLoadConfFile(confName: confName)
      }
    }

    let bindingTableController = BindingTableViewController(bindingTableView, selectionDidChangeHandler: updateTableButtonVisibilities)
    self.bindingTableController = bindingTableController
    confTableController = ConfTableViewController(confTableView, bindingTableController, selectionDidChangeHandler: updateTableButtonVisibilities)
    setCustomTableColors()

    bindingSearchField.placeholderString = "Search bindings"
    bindingSearchField.stringValue = bindingTableState.filterString

    useMediaKeysButton.title = NSLocalizedString("preference.system_media_control", comment: "Use system media control")
    bindingTableView.sizeLastColumnToFit()


    notiHandler = NotificationHandler(AppInputConfig.log, [], [
      .default: [

        .init(.iinaPendingUIChangeForConfTable) { _ in
          self.updateTableButtonVisibilities()
        },

        .init(.iinaPendingUIChangeForBindingTable) { [self] noti in
          updateBindingTotalsLabel()
        },

        .init(.iinaKeyBindingSearchFieldShouldUpdate) { [self] notification in
          guard let newStringValue = notification.object as? String else {
            Logger.log.error("Received \(notification.name.rawValue.quoted) with invalid object: \(type(of: notification.object))")
            return
          }
          guard bindingSearchField.stringValue != newStringValue else { return }
          bindingSearchField.stringValue = newStringValue
        }
      ]
    ])

    addObserver(self, forKeyPath: #keyPath(view.effectiveAppearance), options: [], context: nil)

    confTableController?.selectCurrentConfRow()
    self.updateTableButtonVisibilities()

    // FIXME: need to change this to *after* first data load
    // Set initial scroll, and set up to save scroll value across launches
    if let scrollView = bindingTableView.enclosingScrollView {
      let observer = scrollView.restoreAndObserveVerticalScroll(key: .uiPrefBindingsTableScrollOffsetY, defaultScrollAction: {
        bindingTableView.scrollRowToVisible(0)
      })
      // Change vertical scroll elastisticity of tables in Key Bindings prefs from "yes" to "allowed"
      observers.append(observer)
    }
  }

  fileprivate let blendFraction: CGFloat = 0.2
  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath = keyPath else { return }

    switch keyPath {
    case #keyPath(view.effectiveAppearance):
      // Need to use this closure for dark/light mode toggling to get picked up while running (not sure why...)
      view.effectiveAppearance.applyAppearanceFor {
        setCustomTableColors()
      }
    default:
      return
    }
  }

  // MARK: - IBActions

  @IBAction func addBindingBtnAction(_ sender: AnyObject) {
    bindingTableController?.addNewBinding()
  }

  @IBAction func removeBindingBtnAction(_ sender: AnyObject) {
    bindingTableController?.removeSelectedBindings()
  }

  @IBAction func newConfFileAction(_ sender: AnyObject) {
    confTableController?.createNewConf()
  }

  @IBAction func duplicateConfFileAction(_ sender: AnyObject) {
    confTableController?.duplicateConf(confTableState.selectedConfName)
  }
  
  @IBAction func showConfFileAction(_ sender: AnyObject) {
    confTableController?.showInFinder(confTableState.selectedConfName)
  }

  @IBAction func deleteConfFileAction(_ sender: AnyObject) {
    confTableController?.deleteConf(confTableState.selectedConfName)
  }

  @IBAction func importConfBtnAction(_ sender: Any) {
    Utility.quickOpenPanel(title: "Select Conf File to Import", chooseDir: false, sheetWindow: view.window,
                           allowedFileTypes: [Constants.InputConf.fileExtension]) { url in
      guard url.isFileURL, url.lastPathComponent.hasSuffix(Constants.InputConf.fileExtension) else { return }
      self.confTableController?.importConfFiles([url.path])
    }
  }

  @IBAction func displayRawValueAction(_ sender: NSButton) {
    bindingTableView.reloadExistingRows(reselectRowsAfter: true)
  }

  @IBAction func openKeyBindingsHelpAction(_ sender: AnyObject) {
    NSWorkspace.shared.open(URL(string: AppData.wikiLink.appending("/Manage-Key-Bindings"))!)
  }

  @IBAction func searchAction(_ sender: NSSearchField) {
    searchActionDebouncer.run { [self] in
      bindingTableState.applyFilter(sender.stringValue)
    }
  }

  // MARK: - UI

  private func updateBindingTotalsLabel() {
    let bindingState = BindingTableState.current
    let allRowsTotal = bindingState.allRows.count
    let displayedRows = bindingState.displayedRows
    let userRowsTotal = bindingState.allRows.filter{ $0.origin == .confFile }.count
    let disabledRowsTotal = bindingState.allRows.filter{ !$0.isEnabled }.count
    let customRowsTotal = allRowsTotal - bindingState.allRows.filter{ $0.origin == .staticMenuItem }.count - userRowsTotal
    let displayedUserRows = displayedRows.filter{ $0.origin == .confFile }
    let displayedDisabledUserRows = displayedUserRows.filter{ !$0.isEnabled }.count

    let msg: String
    if !bindingState.filterString.isEmpty {
      let customRowsDisplayed = disabledRowsTotal - displayedRows.filter{ $0.origin == .staticMenuItem }.count - displayedUserRows.count
      if bindingState.showAllBindings {
        let disabledMsg = displayedDisabledUserRows <= 0 ? "" : ", \(displayedDisabledUserRows) disabled"
        let customRowsMsg = customRowsDisplayed <= 0 ? "" : ", \(customRowsDisplayed) other custom"
        msg = "Showing \(displayedRows.count) of \(allRowsTotal) total bindings (\(displayedUserRows.count) from config\(disabledMsg)\(customRowsMsg))"
      } else {
        let disabledMsg = displayedDisabledUserRows <= 0 ? "" : " (including \(displayedDisabledUserRows) disabled)"
        msg = "Showing \(displayedRows.count) of \(userRowsTotal) bindings\(disabledMsg)"
      }
    } else {
      if bindingState.showAllBindings {
        let disabledMsg = disabledRowsTotal <= 0 ? "" : " (including \(disabledRowsTotal) disabled)"
        let customRowsMsg = customRowsTotal <= 0 ? "" : ", \(customRowsTotal) other custom"
        msg = "\(userRowsTotal) bindings from config\(disabledMsg)\(customRowsMsg), \(allRowsTotal) total"
      } else {
        let disabledMsg = displayedDisabledUserRows <= 0 ? "" : " (including \(displayedDisabledUserRows) disabled)"
        msg = "\(userRowsTotal) bindings\(disabledMsg)"
      }
    }

    bindingTotalsLabel.stringValue = msg
    bindingTotalsLabel.layout() // Re-layout in case width changed due to formatting changes
  }

  private func updateTableButtonVisibilities() {
    let isSelectedConfReadOnly = confTableState.isSelectedConfReadOnly
    [deleteConfFileBtn, addBindingBtn].forEach { btn in
      btn?.isHidden = isSelectedConfReadOnly
    }
    showConfFileBtn.isHidden = isSelectedConfReadOnly
    confHintLabel.stringValue = NSLocalizedString("preference.key_binding_hint_\(isSelectedConfReadOnly ? "1" : "2")", comment: "preference.key_binding_hint")

    // re-evaluate this each time either table changed selection:
    removeBindingBtn.isHidden = confTableState.isSelectedConfReadOnly || bindingTableView.selectedRowIndexes.isEmpty
  }

  private func setCustomTableColors() {
    let builtInItemTextColor: NSColor = .controlAccentColor.blended(withFraction: blendFraction, of: .textColor)!
    confTableController?.setCustomColors(builtInItemTextColor: builtInItemTextColor)
    confTableView.reloadExistingRows(reselectRowsAfter: true)

    bindingTableController?.setCustomColors(builtInItemTextColor: builtInItemTextColor)
    bindingTableView.reloadExistingRows(reselectRowsAfter: true)

    let lastPlayerStr = NSLocalizedString("preference.show_all_bindings.last_player", comment: "last player window")
    let allSourcesStr = NSLocalizedString("preference.show_all_bindings.other_sources", comment: "other bindings")
    let btnTitle = String(format: NSLocalizedString("preference.show_all_bindings", comment: "Include %@ which are present in %@"), allSourcesStr, lastPlayerStr)
    let attrString = NSMutableAttributedString(string: btnTitle, attributes: [:])

    // Add special formatting for "from all sources" substring
    if let nsRange = btnTitle.range(of: allSourcesStr)?.nsRange(in: btnTitle) {
      attrString.addAttributes([.foregroundColor: builtInItemTextColor], range: nsRange)

      // Add italic
      if let buttonFont = showFromAllSourcesBtn.font {
        let italicDescriptor: NSFontDescriptor = buttonFont.fontDescriptor.withSymbolicTraits(NSFontDescriptor.SymbolicTraits.italic)
        if let italicFont = NSFont(descriptor: italicDescriptor, size: 0) {
          attrString.addAttributes([.font: italicFont], range: nsRange)
        }
      }
    }

    // TODO: add link to last player window, and update it as it changes

    showFromAllSourcesBtn.attributedTitle = attrString
    showFromAllSourcesBtn.layout() // Re-layout in case width changed due to formatting changes
  }
}
