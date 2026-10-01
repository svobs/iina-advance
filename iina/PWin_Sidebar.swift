//
//  PWin_Sidebars.swift
//  iina
//
//  Created by Matt Svoboda on 2023-03-26.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

private func clampPlaylistWidth(_ width: CGFloat) -> CGFloat {
  return width.clamped(to: Constants.Sidebar.minPlaylistWidth...Constants.Sidebar.maxPlaylistWidth).rounded()
}

// Sidebar layout state
struct Sidebar: CustomStringConvertible, Sendable {

  enum Visibility: CustomStringConvertible {
    case open(tabToShow: Sidebar.Tab)
    case closed

    var visibleTab: Sidebar.Tab? {
      switch self {
      case .open(let tab):
        return tab
      case .closed:
        return nil
      }
    }

    var description: String {
      switch self {
      case .open(let tabToShow):
        return "open(tab=\(tabToShow.name))"
      case .closed:
        return "closed"
      }
    }
  }

  /// Type of the view embedded in sidebar.
  enum TabGroup: String, CustomStringConvertible, Equatable {
    case settings
    case playlist
    case plugins

    func width(using sidebarState: SidebarMiscState) -> CGFloat {
      switch self {
      case .settings, .plugins:
        return Constants.Sidebar.settingsWidth
      case .playlist:
        return clampPlaylistWidth(CGFloat(sidebarState.playlistSidebarWidth))
      }
    }

    var description: String {
      self.rawValue
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      return lhs.rawValue == rhs.rawValue
    }

    static func != (lhs: Self, rhs: Self) -> Bool {
      return lhs.rawValue != rhs.rawValue
    }

    static func fromPrefs(for locationID: Preference.SidebarLocation) -> Set<Sidebar.TabGroup> {
      var tabGroups = Set<Sidebar.TabGroup>()
      if Preference.enum(for: .settingsTabGroupLocation) == locationID {
        tabGroups.insert(.settings)
      }
      if Preference.enum(for: .playlistTabGroupLocation) == locationID {
        tabGroups.insert(.playlist)
      }
      if AppDelegate.iinaPluginSystemEnabled, Preference.enum(for: .pluginsTabGroupLocation) == locationID {
        tabGroups.insert(.plugins)
      }
      return tabGroups
    }

    /// Enable basic sorting
    static func isRightGreaterThanLeft(_ lhs: TabGroup, rhs: TabGroup) -> Bool {
      if case .plugins = lhs {
        return true
      }
      if case .plugins = rhs {
        return false
      }
      if case .playlist = rhs {
        return true
      }
      return false
    }
  }

  // Includes all types of tabs possible in all tab groups
  enum Tab: Equatable, CustomStringConvertible {

    case playlist
    case chapters

    case video
    case audio
    case sub

    case anyPlugin
    /// Plugin tabs are serialized in the format `"plugin:\(id)"`.
    /// A plugin cannot have any ID matching `Constants.Sidebar.anyPluginID`, because that is reserved to represent `anyPlugin`.
    case plugin(id: String)

    init?(name: String?) {
      guard let name = name else {
        return nil
      }
      switch name {
      case "playlist":
        self = .playlist
      case "chapters":
        self = .chapters
      case "video":
        self = .video
      case "audio":
        self = .audio
      case "sub":
        self = .sub
      case "nil":
        return nil
      case Constants.Sidebar.anyPluginID:
        self = .anyPlugin
      default:
        if name.hasPrefix("plugin:") {
          let pluginID = name.dropFirst(7)
          self = .plugin(id: String(pluginID))
        } else {
          return nil
        }
      }
    }

    var name: String {
      switch self {
      case .playlist: return "playlist"
      case .chapters: return "chapters"
      case .video: return "video"
      case .audio: return "audio"
      case .sub: return "sub"
      case .anyPlugin: return Constants.Sidebar.anyPluginID
      case .plugin(let id): return "plugin:\(id)"
      }
    }

    var group: Sidebar.TabGroup {
      switch self {
      case .playlist, .chapters:
        return .playlist
      case .video, .audio, .sub:
        return .settings
      case .plugin(id: _), .anyPlugin:
        return .plugins
      }
    }

    var description: String {
      "Sidebar.Tab.\(name)"
    }

  }  // enum Tab


  /// Used by `LayoutState` for a given window. Stores various state which may not be specific to a sidebar instance, but needs to be saved.
  struct SidebarMiscState {
    let playlistSidebarWidth: Int
    let selectedSubSegment: Int
    let selectedPluginTabID: String

    static func fromDefaultPrefs() -> SidebarMiscState {
      return SidebarMiscState(playlistSidebarWidth: Preference.integer(for: .playlistWidth),
                              selectedSubSegment: 0, selectedPluginTabID: Constants.Sidebar.anyPluginID)
    }
  }  // end struct SidebarMiscState


  // MARK: - Sidebar Init

  init(_ locationID: Preference.SidebarLocation, tabGroups: Set<TabGroup>, placement: Preference.PanelPlacement,
       visibility: Sidebar.Visibility, lastVisibleTab: Sidebar.Tab? = nil) {
    self.locationID = locationID
    self.placement = placement
    self.visibility = visibility
    self.tabGroups = tabGroups

    /// some validation before setting `lastVisibleTab`
    if let visibleTab = visibility.visibleTab, tabGroups.contains(visibleTab.group) {
      self.lastVisibleTab = visibleTab
    } else if let lastVisibleTab = lastVisibleTab, tabGroups.contains(lastVisibleTab.group) {
      self.lastVisibleTab = lastVisibleTab
    } else {
      self.lastVisibleTab = nil
    }
  }

  func clone(tabGroups: Set<TabGroup>? = nil, placement: Preference.PanelPlacement? = nil,
             visibility: Sidebar.Visibility? = nil) -> Sidebar {
    let newTabGroups = tabGroups ?? self.tabGroups
    var newVisibility = visibility ?? self.visibility
    if let newVisibleTab = newVisibility.visibleTab, !newTabGroups.contains(newVisibleTab.group) {
      Logger.log.verbose("Can no longer show visible tab \(newVisibleTab.name) in \(self.locationID). The sidebar will close.")
      newVisibility = .closed
    }

    return Sidebar(self.locationID,
                   tabGroups: newTabGroups,
                   placement: placement ?? self.placement,
                   visibility: newVisibility,
                   lastVisibleTab: self.lastVisibleTab)
  }


  // MARK: - Stored Properties

  /// `leadingSidebar` or `trailingSidebar`
  let locationID: Preference.SidebarLocation

  /// One of `show(Sidebar.Tab)` or `hide`:
  let visibility: Visibility

  /// If sidebar is showing, this should be the same as `visibleTab`. Otherwise this matches the last tab
  /// which was shown since the current app launch, if it is still valid with respect to the current `tabGroups`.
  /// Otherwise returns `nil`.
  let lastVisibleTab: Sidebar.Tab?

  // Should match prefs
  let placement: Preference.PanelPlacement
  /// The set of tab groups assigned to this sidebar as configured by prefs. May be empty.
  /// If empty, this sidebar cannot be shown.
  /// If `visibleTab` and `lastVisibleTab` must belong to a tab group in this list, respectively.
  let tabGroups: Set<Sidebar.TabGroup>


  // MARK: - Computed Properties

  /// The currently visible tab, if sidebar is open/visible. Is `nil` if sidebar is closed/hidden.
  /// Use `lastVisibleTab` if the last shown tab needs to be known.
  var visibleTab: Sidebar.Tab? {
    return visibility.visibleTab
  }

  /// The parent `TabGroup` of `visibleTab`
  var visibleTabGroup: Sidebar.TabGroup? {
    return visibleTab?.group
  }

  var isVisible: Bool {
    return visibleTab != nil
  }

  var defaultTabToShow: Sidebar.Tab? {
    // Use last visible tab if still valid:
    if let lastVisibleTab = lastVisibleTab, tabGroups.contains(lastVisibleTab.group) {
      Logger.log.verbose("Returning last visible tab for \(locationID): \(lastVisibleTab.name.quoted)")
      return lastVisibleTab
    }

    // Use highest priority tab group found:
    if let group = tabGroups.sorted(by: Sidebar.TabGroup.isRightGreaterThanLeft).last {
      switch group {
      case .playlist:
        return Sidebar.Tab.playlist
      case .settings:
        return Sidebar.Tab.video
      case .plugins:
        return Sidebar.Tab.anyPlugin
      }
    }

    // If sidebar has no tab groups, can't show anything:
    Logger.log.verbose("No tab groups found for \(locationID); returning nil for defaultTab")
    return nil
  }

  var description: String {
    let tabGroups = tabGroups.map(\.description).joined(separator: ", ")
    return "Sidebar(\(locationID) \(visibility) place=\(placement) lastTab=\(lastVisibleTab.map(\.name.quoted) ?? "nil") groups=[\(tabGroups)])"
  }

}  // end struct Sidebar


/// Enapsulates code relating to leading & trailing sidebars in PlayerWindow.
extension PlayerWindowController {
  // MARK: - Show/Hide functions

  func isOpen(sidebarTabGroup tabGroup: Sidebar.TabGroup) -> Bool {
    let layout = currentLayout
    return layout.leadingSidebar.visibleTabGroup == tabGroup || layout.trailingSidebar.visibleTabGroup == tabGroup
  }

  func isOpen(sidebarTab tab: Sidebar.Tab) -> Bool {
    let layout = currentLayout
    return layout.leadingSidebar.visibleTab == tab || layout.trailingSidebar.visibleTab == tab
  }

  @IBAction func toggleLeadingSidebarVisibility(_ sender: NSButton) {
    toggleVisibility(of: .leadingSidebar)
  }

  @IBAction func toggleTrailingSidebarVisibility(_ sender: NSButton) {
    toggleVisibility(of: .trailingSidebar)
  }

  /// Toggles visibility of given `sidebar`
  func toggleVisibility(of sidebarID: Preference.SidebarLocation) {
    animationPipeline.submitInstantTask { [self] in
      guard currentLayout.canShowSidebars else { return }
      let sidebar = currentLayout.sidebar(withID: sidebarID)
      let isCurrentlyVisible = sidebar.isVisible
      log.verbose("Toggling visibility of sidebar \(sidebarID): \(isCurrentlyVisible.yn) → \((!isCurrentlyVisible).yn)")
      // Do nothing if sidebar has no configured tabs
      guard let tab = sidebar.defaultTabToShow else { return }

      if isCurrentlyVisible {
        changeVisibility(forTab: tab, to: false)
      } else {
        changeVisibility(forTab: tab, to: true)
      }
    }
  }

  /// Shows or toggles visibility of given `tabGroup`
  func showSidebar(forTabGroup tabGroup: Sidebar.TabGroup, force: Bool = false, hideIfAlreadyShown: Bool = true) {
    log.verbose("ShowSidebar for tabGroup=\(tabGroup.rawValue.quoted) force=\(force.yn) hideIfAlreadyShown=\(hideIfAlreadyShown.yn)")
    switch tabGroup {
    case .playlist:
      showSidebar(tab: playlistView.currentTab, force: force, hideIfAlreadyShown: hideIfAlreadyShown)
    case .settings:
      if let tab = Sidebar.Tab(name: quickSettingView.currentTab.name) {
        showSidebar(tab: tab, force: force, hideIfAlreadyShown: hideIfAlreadyShown)
      }
    case .plugins:
      let pluginID = pluginView.currentPluginID
      let tab: Sidebar.Tab = pluginID == Constants.Sidebar.anyPluginID ? .anyPlugin : Sidebar.Tab.plugin(id: pluginID)
      showSidebar(tab: tab, force: force, hideIfAlreadyShown: hideIfAlreadyShown)
    }
  }

  /// Shows or toggles visibility of given `tab`
  func showSidebar(tab: Sidebar.Tab, force: Bool = false, hideIfAlreadyShown: Bool = true) {
    log.verbose("ShowSidebar for tab=\(tab.name.quoted) force=\(force.yn) hideIfAlreadyShown=\(hideIfAlreadyShown.yn)")

    animationPipeline.submitInstantTask { [self] in
      if currentLayout.isMusicMode && tab.group == .playlist {
        // Music mode
        if miniPlayer.playlistShown && playlistView.currentTab == tab {
          if hideIfAlreadyShown {
            miniPlayer.togglePlaylist(nil)
          }
        } else {
          if !miniPlayer.playlistShown {
            miniPlayer.togglePlaylist(nil)
          }
          playlistView.pleaseSwitchToTab(tab)
        }
        return
      }

      guard let destinationSidebar = getConfiguredSidebar(forTabGroup: tab.group) else { return }

      if destinationSidebar.visibleTab == tab {
        if hideIfAlreadyShown {
          log.verbose("Will hide \(destinationSidebar.locationID) instead because it is in state \(destinationSidebar.visibility)")
          changeVisibility(forTab: tab, to: false)
        }
      } else {
        // This will first change the sidebar to the displayed tab group if needed:
        changeVisibility(forTab: tab, to: true)
      }
    }
  }

  // Updates placements (inside or outside) of both sidebars in the UI so they match the prefs.
  // If placement of one/both affected sidebars is open, closes then reopens the affected bar(s) with the new placement.
  func updateSidebarPlacements() {
    animationPipeline.submitInstantTask { [self] in
      let oldLayout = currentLayout
      let leadingSidebar = oldLayout.leadingSidebar.clone(placement: Preference.enum(for: .leadingSidebarPlacement))
      let trailingSidebar = oldLayout.trailingSidebar.clone(placement: Preference.enum(for: .trailingSidebarPlacement))

      guard oldLayout.leadingSidebarPlacement != leadingSidebar.placement ||
              oldLayout.trailingSidebarPlacement != trailingSidebar.placement else {
        return
      }

      let newLayoutState = oldLayout.clone(leadingSidebar: leadingSidebar, trailingSidebar: trailingSidebar)
      let transition = buildLayoutTransition(named: "UpdateSidebarPlacements", from: oldLayout, to: newLayoutState)
      buildTasks(for: transition, thenRun: true)
    }
  }

  /// Hides all visible sidebars
  func hideAllSidebars(animate: Bool = true) {
    player.log.verbose("Hiding all sidebars")

    animationPipeline.submitInstantTask { [self] in
      let oldLayout = currentLayout
      let newLayoutState = oldLayout.withSidebarsHidden()
      let transition = buildLayoutTransition(named: "HideAllSidebars", from: oldLayout, to: newLayoutState)
      let transitionTasks = buildTasks(for: transition, totalEndingDuration: 0)

      if animate {
        animationPipeline.submit(transitionTasks)
      } else {
        IINAAnimation.disableAnimation{
          animationPipeline.submit(transitionTasks)
        }
      }
    }
  }

  /// Shows or hides visibility of given `tab`. If the affected sidebar is showing the wrong `tabGroup`, it will be first be
  /// hidden/closed and then shown again the the correct `tabGroup` & `tab`. Will do nothing if already showing the given `tab`.
  private func changeVisibility(forTab tab: Sidebar.Tab, to shouldShow: Bool) {
    guard !isInInteractiveMode, currentLayout.canShowSidebars else { return }
    log.verbose("Changing visibility of sidebar for tab \(tab.name.quoted) to: \(shouldShow ? "SHOW" : "HIDE")")

    let newVisibilty: Sidebar.Visibility = shouldShow ? .open(tabToShow: tab) : .closed
    let oldLayout = currentLayout

    var leadingSidebar: Sidebar
    var trailingSidebar: Sidebar = oldLayout.trailingSidebar
    if oldLayout.leadingSidebar.tabGroups.contains(tab.group) {  // Leading sidebar
      let isShown = oldLayout.leadingSidebar.isVisible
      if shouldShow != isShown {
        // good
      } else if isShown, let visibleTabGroup = oldLayout.leadingSidebar.visibleTabGroup {
        if visibleTabGroup == tab.group {
          // Already showing the tab group. Just need to change current tab in group
          switchToTabInTabGroup(tab: tab)
          return
        }
        // Otherwise need to change tab group. Drop through.
      } else {
        // Drop request if already animating
        log.verbose("Skipping \(shouldShow ? "SHOW" : "HIDE") for \(tab.name.quoted) because leadingSidebar isShown=\(isShown.yn)")
        return
      }
      leadingSidebar = oldLayout.leadingSidebar.clone(visibility: newVisibilty)
      trailingSidebar = oldLayout.trailingSidebar
    } else if oldLayout.trailingSidebar.tabGroups.contains(tab.group) {  // Trailing sidebar
      let isShown = oldLayout.trailingSidebar.isVisible
      if shouldShow != isShown {
        // good
      } else if isShown, let visibleTabGroup = oldLayout.trailingSidebar.visibleTabGroup {
        if visibleTabGroup == tab.group {
          // Already showing the tab group. Just need to change current tab in group
          switchToTabInTabGroup(tab: tab)
          return
        }
        // Otherwise need to change tab group. Drop through.
      } else {
        // Drop request if already animating or already in desired state
        log.verbose("Skipping \(shouldShow ? "SHOW" : "HIDE") for \(tab.name.quoted) because trailingSidebar isOpen=\(isShown.yn)")
        return
      }
      leadingSidebar = oldLayout.leadingSidebar
      trailingSidebar = oldLayout.trailingSidebar.clone(visibility: newVisibilty)
    } else {
      // Should never get here
      log.error("Internal error: no sidebar found for tab group \(tab.group)!")
      return
    }

    log.verbose("Transitioning to layout with \(leadingSidebar.locationID)=\(leadingSidebar.visibility) \(trailingSidebar.locationID)=\(trailingSidebar.visibility)")
    let newLayoutState = oldLayout.clone(leadingSidebar: leadingSidebar, trailingSidebar: trailingSidebar)
    let transition = buildLayoutTransition(named: shouldShow ? "OpenSidebar": "CloseSidebar", from: oldLayout, to: newLayoutState)
    buildTasks(for: transition, thenRun: true)
  }

  /// Do not call directly. Will be called by `LayoutTransition` via animation tasks.
  func animateShowOrHideSidebars(from geo0: PWinGeometry,
                                 to geo1: PWinGeometry,
                                 outputLayout: LayoutState,
                                 isInitialLayout: Bool, _ log: any Logger.Subsystem) {
    let leadingOpen0 = geo0.isLeadingSidebarShown
    let leadingOpen1 = geo1.isLeadingSidebarShown
    let trailingOpen0 = geo0.isTrailingSidebarShown
    let trailingOpen1 = geo1.isTrailingSidebarShown
    let leadingVisible: Bool? = isInitialLayout && leadingOpen1 ? true : (leadingOpen0 == leadingOpen1 ? nil : leadingOpen1)
    let trailingVisible: Bool? = isInitialLayout && trailingOpen1 ? true : (trailingOpen0 == trailingOpen1 ? nil : trailingOpen1)

    defer {
      trailingSidebarConstraints?.top.animateToConstant(topOffsetFromViewport(outputLayout))
      leadingSidebarConstraints?.top.animateToConstant(topOffsetFromViewport(outputLayout))
    }

    guard leadingVisible != nil || trailingVisible != nil else { return }

    if let leadingVisible, let leadingSidebarPlacement = geo1.leadingSidebarPlacement ?? geo0.leadingSidebarPlacement {
      let sidebarWidth = max(geo0.leadingSidebarWidth, geo1.leadingSidebarWidth)  // one of these should be 0, and the other the sidebarWidth
      let isWindowWidthChanging = geo1.windowFrame.width - geo0.windowFrame.width != 0
      log.verbose("Toggling leadingSidebar openState to \(leadingVisible.yn), width=\(sidebarWidth), wndWidthChanging=\(isWindowWidthChanging)")
      updateLeadingSidebarWidthConstraints(to: sidebarWidth, visible: leadingVisible, leadingSidebarPlacement,
                                           isWindowWidthChanging: isWindowWidthChanging)
      if leadingSidebarPlacement == .outsideViewport {
        leadingSidebarTrailingBorder.isHidden = !leadingVisible
      }
    }

    if let trailingVisible, let trailingSidebarPlacement = geo1.trailingSidebarPlacement ?? geo0.trailingSidebarPlacement {
      let sidebarWidth = max(geo0.trailingSidebarWidth, geo1.trailingSidebarWidth)  // one of these should be 0, and the other the sidebarWidth
      let isWindowWidthChanging = geo1.windowFrame.width - geo0.windowFrame.width != 0
      log.verbose("Toggling trailingSidebar openState to \(trailingVisible.yn), width=\(sidebarWidth), wndWidthChanging=\(isWindowWidthChanging)")
      updateTrailingSidebarWidthConstraints(to: sidebarWidth, visible: trailingVisible, placement: trailingSidebarPlacement,
                                            isWindowWidthChanging: isWindowWidthChanging)
      if trailingSidebarPlacement == .outsideViewport {
        trailingSidebarLeadingBorder.isHidden = !trailingVisible
      }
    }
  }

  // MARK: - Leading Sidebar open/close

  /// Executed prior to opening `leadingSidebar` to the given tab.
  ///
  /// Adds or updates the constraints:
  /// * `viewportLeadingOffsetFromLeading`
  /// * `viewportLeadingOffsetFromTrailing`
  /// * `viewportLeadingClipTrailing`
  /// Updates the contraints:
  /// * `vpLeadingOffsetFromCVLeading`
  ///
  /// Do not call directly. Will be called by `LayoutTransition` via animation tasks.
  func prepareLayoutForOpening(leadingSidebar: Sidebar, layout: LayoutState,
                               isWindowWidthChanging: Bool,
                               addTabGroupView shouldAddTabGroup: Bool,
                               _ log: any Logger.Subsystem) {
    let contentView: NSView
    if #available(macOS 26.0, *), let glassView = leadingSidebarView as? NSGlassEffectView {
      contentView = glassView.contentView!
    } else {
      contentView = leadingSidebarView
    }
    for subview in contentView.subviews {
      // remove clipView without keeping a reference to it
      if subview != leadingSidebarTrailingBorder {
        subview.removeFromSuperview()
      }
    }

    let tabGroupToShow: Sidebar.TabGroup = leadingSidebar.visibleTabGroup!
    let sidebarWidth = tabGroupToShow.width(using: layout.moreSidebarState)
    let tabContainerView: NSView
    let boundaryView: NSView

    let viewportLeadingClipTrailing: NSLayoutConstraint?
    switch leadingSidebar.placement {
    case .insideViewport:
      tabContainerView = contentView
      boundaryView = window!.contentView!
      viewportLeadingClipTrailing = nil
    case .outsideViewport:
      // To provide a smooth "slide" animation for the panel which moves into the viewport but doesn't spill out the other sideq
      // (or end up forcing the window to enlarge!) it is easiest to use its superview as a clip view. We don't know which tab
      // group view will be stored in the sidebar at this point and would rather not add complexity there, so just use a dedicatedp
      // view for this purpose:
      let clipView = NSView()
      clipView.idString = "LeadingSidebarClipView"
      contentView.addSubview(clipView, positioned: .below, relativeTo: leadingSidebarTrailingBorder)
      clipView.translatesAutoresizingMaskIntoConstraints = false
      clipView.addConstraintsToFillSuperview(top: 0, bottom: 0, leading: 0)
      tabContainerView = clipView
      boundaryView = viewportView

      // extra constraint for clipView:
      let clipConstraint = boundaryView.leadingAnchor.constraint(equalTo: leadingSidebarView.trailingAnchor, constant: 0)
      clipConstraint.identifier = "ViewportLeading-LeadingSidebar-ClipTrailing"
      viewportLeadingClipTrailing = clipConstraint
    }

    let coefficients = getLeadingSidebarWidthCoefficients(visible: false, leadingSidebar.placement, isWindowWidthChanging: isWindowWidthChanging)

    let viewportLeadingOffsetFromLeading = boundaryView.leadingAnchor.constraint(
      equalTo: tabContainerView.leadingAnchor, constant: coefficients.0 * sidebarWidth)
    viewportLeadingOffsetFromLeading.identifier = "ViewportLeading-LeadingSidebar-Leading"

    let viewportLeadingOffsetFromTrailing = tabContainerView.trailingAnchor.constraint(
      equalTo: boundaryView.leadingAnchor, constant: coefficients.1 * sidebarWidth)
    viewportLeadingOffsetFromTrailing.identifier = "ViewportLeading-LeadingSidebar-Trailing"

    let topConstraint = leadingSidebarView.topAnchor.constraint(equalTo: viewportView.topAnchor, constant: topOffsetFromViewport(layout))
    let bottomConstraint = viewportView.bottomAnchor.constraint(equalTo: leadingSidebarView.bottomAnchor)

    assert(coefficients.2 * sidebarWidth == 0,
           "vpLeadingOffsetFromCVLeading should be zero: \(coefficients.2 * sidebarWidth)")
    assert(panelConstraints.vpLeadingOffsetFromCVLeading.constraint != nil)
    panelConstraints.vpLeadingOffsetFromCVLeading.animateToConstant(coefficients.2 * sidebarWidth)

    // Will remove old constraints & add the new ones
    leadingSidebarConstraints = LeadingSidebarConstraints(viewportLeadingOffsetFromLeading: viewportLeadingOffsetFromLeading,
                                                          viewportLeadingOffsetFromTrailing: viewportLeadingOffsetFromTrailing,
                                                          viewportLeadingClipTrailing: viewportLeadingClipTrailing,
                                                          top: topConstraint, bottom: bottomConstraint)

    if shouldAddTabGroup {
      log.verbose("Adding tabGroup \(tabGroupToShow.rawValue.quoted) to \(leadingSidebar.locationID), placement=\(leadingSidebar.placement)")
      addTabGroupView(for: tabGroupToShow, to: tabContainerView, effectiveAppearance: AppDelegate.shared.targetWindowAppearance)
    }
  }

  /// When using GlassEffectView, there is 1px border around the inside of the frame, which looks bad when topBar==`outside`. Clip it out.
  private func topOffsetFromViewport(_ layout: LayoutState) -> CGFloat {
    layout.topBarPlacement == .outsideViewport ? -2 : 0
  }

  /**
   For opening/closing `leadingSidebar` via constraints, multiply each times the sidebar width
   Correesponding to:
   (`viewportLeadingOffsetFromLeading`,
   `viewportLeadingOffsetFromTrailing`,
   `vpLeadingOffsetFromCVLeading`)
   */
  private func getLeadingSidebarWidthCoefficients(visible: Bool, _ placement: Preference.PanelPlacement,
                                                  isWindowWidthChanging: Bool) -> (CGFloat, CGFloat, CGFloat) {
    switch placement {
    case .insideViewport:
      if visible {
        return (0, 1, 0)
      } else {
        return (1, 0, 0)
      }
    case .outsideViewport:
      if visible {
        return (1, 0, 1)
      } else {
        if isWindowWidthChanging {
          return (0, 1, 0)
        } else {
          return (1, 0, 0)
        }
      }
    }
  }

  private func updateLeadingSidebarWidthConstraints(to newWidth: CGFloat, visible: Bool, _ placement: Preference.PanelPlacement,
                                                    isWindowWidthChanging: Bool) {
    log.verbose("Updating leadingSidebar constraints for \(visible ? "OPEN" : "CLOSED"), width=\(newWidth), \(placement), wndWidthChanging=\(isWindowWidthChanging.yn)")
    let coefficients = getLeadingSidebarWidthCoefficients(visible: visible, placement, isWindowWidthChanging: isWindowWidthChanging)

    if let cons = leadingSidebarConstraints {
      cons.viewportLeadingOffsetFromLeading.animateToConstant(coefficients.0 * newWidth)
      cons.viewportLeadingOffsetFromTrailing.animateToConstant(coefficients.1 * newWidth)
    }
    assert(panelConstraints.vpLeadingOffsetFromCVLeading.constraint != nil)
    panelConstraints.vpLeadingOffsetFromCVLeading.animateToConstant(coefficients.2 * newWidth)
  }

  // MARK: - Trailing Sidebar open/close

  /// Executed prior to opening `trailingSidebar` to the given tab.
  ///
  /// Adds or updates the constraints:
  /// * `viewportTrailingOffsetFromLeading`
  /// * `viewportTrailingOffsetFromTrailing`
  /// * `viewportTrailingClipLeading`
  /// Updates the contraints:
  /// * `vpTrailingOffsetFromCVTrailing`
  ///
  /// Do not call directly. Will be called by `LayoutTransition` via animation tasks.
  func prepareLayoutForOpening(trailingSidebar: Sidebar, layout: LayoutState,
                               isWindowWidthChanging: Bool,
                               addTabGroupView shouldAddTabGroup: Bool,
                               _ log: any Logger.Subsystem) {
    let contentView: NSView
    if #available(macOS 26.0, *), let glassView = trailingSidebarView as? NSGlassEffectView {
      contentView = glassView.contentView!
    } else {
      contentView = trailingSidebarView
    }
    for subview in contentView.subviews {
      // remove clipView without keeping a reference to it
      if subview != trailingSidebarLeadingBorder {
        subview.removeFromSuperview()
      }
    }

    let tabGroupToShow: Sidebar.TabGroup = trailingSidebar.visibleTabGroup!
    let sidebarWidth = tabGroupToShow.width(using: layout.moreSidebarState)

    let viewportTrailingClipLeading: NSLayoutConstraint?
    let tabContainerView: NSView
    let boundaryView: NSView
    switch trailingSidebar.placement {
    case .insideViewport:
      tabContainerView = contentView
      boundaryView = window!.contentView!
      viewportTrailingClipLeading = nil
    case .outsideViewport:
      let clipView = NSView()
      clipView.identifier = .init("TrailingSidebarClipView")
      contentView.addSubview(clipView, positioned: .below, relativeTo: trailingSidebarLeadingBorder)
      clipView.translatesAutoresizingMaskIntoConstraints = false
      clipView.addConstraintsToFillSuperview(top: 0, bottom: 0, trailing: 0)
      tabContainerView = clipView
      boundaryView = viewportView

      // extra constraint for clipView:
      let con = boundaryView.trailingAnchor.constraint(equalTo: trailingSidebarView.leadingAnchor, constant: 0)
      con.identifier = "ViewportTrailing-TrailingSidebar-ClipLeading"
      viewportTrailingClipLeading = con
    }

    let coefficients = getTrailingSidebarWidthCoefficients(visible: false, trailingSidebar.placement,
                                                           isWindowWidthChanging: isWindowWidthChanging)

    let leadingCon = boundaryView.trailingAnchor.constraint(
      equalTo: tabContainerView.leadingAnchor, constant: coefficients.0 * sidebarWidth)
    leadingCon.identifier = "ViewportTrailing-TrailingSidebar-Leading"

    let trailingCon = tabContainerView.trailingAnchor.constraint(
      equalTo: boundaryView.trailingAnchor, constant: coefficients.1 * sidebarWidth)
    trailingCon.identifier = "ViewportTrailing-TrailingSidebar-Trailing"

    // When using GlassEffectView, there is 1px border around the inside of the frame, which looks bad when topBar==`outside`. Clip it out:
    let topConstraint = trailingSidebarView.topAnchor.constraint(equalTo: viewportView.topAnchor, constant: topOffsetFromViewport(layout))
    let bottomConstraint = viewportView.bottomAnchor.constraint(equalTo: trailingSidebarView.bottomAnchor)

    assert(panelConstraints.vpTrailingOffsetFromCVTrailing.constraint != nil)
    panelConstraints.vpTrailingOffsetFromCVTrailing.constraint?.animateToConstant(coefficients.2 * sidebarWidth)

    // Will remove old constraints & add new ones
    trailingSidebarConstraints = TrailingSidebarConstraints(viewportTrailingOffsetFromLeading: leadingCon,
                                                            viewportTrailingOffsetFromTrailing: trailingCon,
                                                            viewportTrailingClipLeading: viewportTrailingClipLeading,
                                                            top: topConstraint, bottom: bottomConstraint)

    if shouldAddTabGroup {
      log.verbose("Adding tabGroup \(tabGroupToShow.rawValue.quoted) to \(trailingSidebar.locationID), placement=\(trailingSidebar.placement)")
      addTabGroupView(for: tabGroupToShow, to: tabContainerView, effectiveAppearance: AppDelegate.shared.targetWindowAppearance)
    }
  }

  /**
   For opening/closing `trailingSidebar` via constraints, multiply each times the sidebar width
   Correesponding to:
   (`viewportTrailingOffsetFromLeading`,
   `viewportTrailingOffsetFromTrailing`,
   `vpTrailingOffsetFromCVTrailing`)
   */
  private func getTrailingSidebarWidthCoefficients(visible: Bool, _ placement: Preference.PanelPlacement,
                                                   isWindowWidthChanging: Bool) -> (CGFloat, CGFloat, CGFloat) {
    switch placement {
    case .insideViewport:
      if visible {
        return (1, 0, 0)
      } else {
        // Sidebar is offset by its own width outward under the contentView
        return (0, 1, 0)
      }
    case .outsideViewport:
      if visible {
        return (0, 1, 1)
      } else {
        if isWindowWidthChanging {
          // Sidebar is fully inside the window contentView.
          // During the animation, the window will expand/contract along with the sidebar.
          return (1, 0, 0)
        } else {
          // Window is probably maximized.
          // Slide the sidebar outward under the window contentView to maintain the sliding effect:
          return (0, 1, 0)
        }
      }
    }
  }

  private func updateTrailingSidebarWidthConstraints(to newWidth: CGFloat, visible: Bool,
                                                     placement: Preference.PanelPlacement,
                                                     isWindowWidthChanging: Bool) {
    log.verbose("Updating trailingSidebar constraints for \(visible ? "OPEN" : "CLOSED"), width=\(newWidth), \(placement), wndWidthChanging=\(isWindowWidthChanging)")
    let coefficients = getTrailingSidebarWidthCoefficients(visible: visible, placement, isWindowWidthChanging: isWindowWidthChanging)

    if let cons = trailingSidebarConstraints {
      cons.viewportTrailingOffsetFromLeading.animateToConstant(coefficients.0 * newWidth)
      cons.viewportTrailingOffsetFromTrailing.animateToConstant(coefficients.1 * newWidth)
    }
    panelConstraints.vpTrailingOffsetFromCVTrailing.constraint?.animateToConstant(coefficients.2 * newWidth)
  }

  // MARK: Either Sidebar - Open

  /// Prepares those layout components which are generic for either `Sidebar`.
  /// Executed prior to opening the given `Sidebar` with corresponding `sidebarView`
  private func addTabGroupView(for tabGroup: Sidebar.TabGroup, to tabContainerView: NSView, effectiveAppearance: NSAppearance) {
    // Add tab group view
    let viewController: NSViewController
    switch tabGroup {
    case .playlist:
      viewController = playlistView
    case .settings:
      viewController = quickSettingView
    case .plugins:
      viewController = pluginView
    }
    let tabGroupView = viewController.view
    guard !tabContainerView.containsSubview(tabGroupView) else { return }
    tabContainerView.addSubviewAndConstraints(tabGroupView, top: 0, leading: 0, trailing: 0)
    // Do not use `required` priority for bottom, so that it can shrink there when absolutely needed (e.g., entering Music Mode with no viewport)
    let bottomConstraint = tabContainerView.bottomAnchor.constraint(equalTo: tabGroupView.bottomAnchor, constant: 0)
    bottomConstraint.priorityInt = 900
    bottomConstraint.isActive = true
  }

  // MARK: - Changing tabs

  /// Assuming the correct sidebar is already showing, & it is showing the correct tab group, switches to the given tab in the same tab group.
  /// Does nothing if the given tab group is already showing the requested tab.
  func switchToTabInTabGroup(tab: Sidebar.Tab) {
    assert((getConfiguredSidebar(forTabGroup: tab.group)!.visibleTabGroup == tab.group),
           "switchToTabInTabGroup: expected TabGroup \(tab.group) to be visible")

    // Make it the active tab in its parent tab group (can do this whether or not it's shown):
    switch tab.group {
    case .playlist:
      guard playlistView.currentTab != tab else {
        log.verbose("Already showing tab \(tab.name.quoted) in playlistView; no need to change")
        return
      }
      log.verbose("Switching to tab \(tab.name.quoted) in playlistView")
      playlistView.pleaseSwitchToTab(tab)
    case .settings:
      guard quickSettingView.currentTab != tab else {
        log.verbose("Already showing tab \(tab.name.quoted) in quickSettingView; no need to change")
        return
      }
      log.verbose("Switching to tab \(tab.name.quoted) in quickSettingView")
      quickSettingView.pleaseSwitchToTab(tab)
    case .plugins:
      guard tab != .anyPlugin else {
        log.verbose("Tab requested was 'anyPlugin`; nothing to do")
        return
      }

      guard case .plugin(let pluginID) = tab else {
        log.error("Cannot switch to tab \(tab.name.quoted): bad plugin tab object!")
        return
      }

      guard pluginView.currentPluginID != pluginID else {
        log.verbose("Already showing plugin tab \(pluginID.quoted) in pluginView; no need to change")
        return
      }

      log.verbose("Switching to tab \(pluginID.quoted) in pluginView")
      pluginView.pleaseSwitchToTab(pluginID)
    }
  }

  // This is so that sidebar controllers can notify when they changed tabs in their tab groups, so that
  // the tracking information here can be updated.
  func didChangeTab(to tab: Sidebar.Tab, then doAfter: Callback? = nil) {
    log.verbose("Changing to sidebar tab: \(tab.name.quoted)")

    // Try to avoid race conditions if possible
    animationPipeline.submitInstantTask { [self] in
      let newVisibility = Sidebar.Visibility.open(tabToShow: tab)
      let layout = currentLayout
      var leadingSidebar: Sidebar? = nil
      var trailingSidebar: Sidebar? = nil
      if layout.leadingSidebar.tabGroups.contains(tab.group) {
        leadingSidebar = layout.leadingSidebar.clone(visibility: newVisibility)
      } else if layout.trailingSidebar.tabGroups.contains(tab.group) {
        trailingSidebar = layout.trailingSidebar.clone(visibility: newVisibility)
      }
      // Need to update current layout, but no need for animation
      let outputLayout = layout.clone(leadingSidebar: leadingSidebar, trailingSidebar: trailingSidebar)
      currentLayout = outputLayout
      player.saveState()

      if let doAfter {
        doAfter()
      }
    }
  }

  func getConfiguredSidebar(forTabGroup tabGroup: Sidebar.TabGroup) -> Sidebar? {
    for sidebar in [currentLayout.leadingSidebar, currentLayout.trailingSidebar] {
      if sidebar.tabGroups.contains(tabGroup) {
        return sidebar
      }
    }
    log.error("No sidebar found for tab group \(tabGroup.rawValue.quoted)!")
    return nil
  }

  // If location of tab group changed to another sidebar (in user prefs), check if it is showing, and if so, hide it & show it on the other side
  func moveTabGroup(_ tabGroup: Sidebar.TabGroup, toSidebarLocation newLocationID: Preference.SidebarLocation) {
    animationPipeline.submitInstantTask { [self] in
      guard let currentLocationID = getConfiguredSidebar(forTabGroup: tabGroup)?.locationID else { return }
      guard currentLocationID != newLocationID else { return }

      let oldLayout = currentLayout
      let leadingSidebar = oldLayout.leadingSidebar
      var newLeadingTabGroups = leadingSidebar.tabGroups
      var newLeadingSidebarVisibility: Sidebar.Visibility = leadingSidebar.visibility
      let trailingSidebar = oldLayout.trailingSidebar
      var newTrailingTabGroups = trailingSidebar.tabGroups
      var newTraillingSidebarVisibility: Sidebar.Visibility = trailingSidebar.visibility

      if newLocationID == .leadingSidebar {
        newLeadingTabGroups.insert(tabGroup)
        newTrailingTabGroups.remove(tabGroup)
        if trailingSidebar.visibleTabGroup == tabGroup && !leadingSidebar.isVisible {
          newTraillingSidebarVisibility = .closed
          newLeadingSidebarVisibility = trailingSidebar.visibility
        }
      }

      if newLocationID == .trailingSidebar {
        newTrailingTabGroups.insert(tabGroup)
        newLeadingTabGroups.remove(tabGroup)
        if leadingSidebar.visibleTabGroup == tabGroup && !trailingSidebar.isVisible {
          newLeadingSidebarVisibility = .closed
          newTraillingSidebarVisibility = leadingSidebar.visibility
        }
      }

      let newLayoutState = oldLayout.clone(
        leadingSidebar: leadingSidebar.clone(tabGroups: newLeadingTabGroups, visibility: newLeadingSidebarVisibility),
        trailingSidebar: trailingSidebar.clone(tabGroups: newTrailingTabGroups, visibility: newTraillingSidebarVisibility))
      let transition = buildLayoutTransition(named: "MoveTabGroupToSidebar", from: oldLayout, to: newLayoutState)
      buildTasks(for: transition, thenRun: true)
    }
  }

  func isTabGroupVisible(_ tabGroup: Sidebar.TabGroup) -> Bool {
    return getConfiguredSidebar(forTabGroup: tabGroup)?.visibleTabGroup == tabGroup
  }

  // MARK: - Various functions

  func updateSidebarBlendingMode(_ sidebarID: Preference.SidebarLocation, layout: LayoutState) {
    switch sidebarID {
    case .leadingSidebar:
      if let leadingSidebarVE = leadingSidebarView as? NSVisualEffectView {
        // Full screen + "behindWindow" doesn't blend properly and looks ugly
        if layout.leadingSidebarPlacement == .insideViewport || layout.isFullScreen{
          leadingSidebarVE.blendingMode = .withinWindow
        } else {
          leadingSidebarVE.blendingMode = .behindWindow
        }
      }
    case .trailingSidebar:
      if let trailingSidebarVE = leadingSidebarView as? NSVisualEffectView {
        if layout.trailingSidebarPlacement == .insideViewport || layout.isFullScreen {
          trailingSidebarVE.blendingMode = .withinWindow
        } else {
          trailingSidebarVE.blendingMode = .behindWindow
        }
      }
    }
  }

  // MARK: - Sidebar resize via drag

  func isMousePosWithinLeadingSidebarResizeRect(mousePositionInWindow: NSPoint) -> Bool {
    if currentLayout.leadingSidebar.visibleTabGroup == .playlist {
      let sf = leadingSidebarView.frameInWindowCoords

      let dragRectCenterX = videoView.userInterfaceLayoutDirection == .rightToLeft ?
      sf.origin.x : sf.origin.x + sf.width

      let activationRect = NSRect(x: dragRectCenterX - Constants.Sidebar.resizeActivationRadius,
                                  y: sf.origin.y,
                                  width: Constants.Sidebar.resizeActivationRadius + Constants.Sidebar.resizeActivationRadius,
                                  height: sf.height)
      if NSPointInRect(mousePositionInWindow, activationRect) {
        log.trace("Mouse location \(mousePositionInWindow) is within leading sidebar resize rect \(activationRect)")
        return true
      }
    }
    return false
  }

  func isMousePosWithinTrailingSidebarResizeRect(mousePositionInWindow: NSPoint) -> Bool {
    if currentLayout.trailingSidebar.visibleTabGroup == .playlist {
      let sf = trailingSidebarView.frameInWindowCoords
      let dragRectCenterX = videoView.userInterfaceLayoutDirection == .rightToLeft ?
      sf.origin.x + sf.width + Constants.Sidebar.resizeActivationRadius : sf.origin.x

      let activationRect = NSRect(x: dragRectCenterX - Constants.Sidebar.resizeActivationRadius,
                                  y: sf.origin.y,
                                  width: Constants.Sidebar.resizeActivationRadius + Constants.Sidebar.resizeActivationRadius,
                                  height: sf.height)
      
      if NSPointInRect(mousePositionInWindow, activationRect) {
        log.trace("Mouse location \(mousePositionInWindow) is within trailing sidebar resize rect \(activationRect)")
        return true
      }
    }
    return false
  }

  /// Returns `true` if mouse was within either sidebar's resize rect, and resize was started.
  func startResizingSidebar(with event: NSEvent) -> Bool {
    if let currentDragObject  {
      log.warn("Not going to start resizing sidebar(s); already dragging: \(currentDragObject.idString.quoted)")
      return false
    }
    let pointInWindow = mouseLocationInWindow
    if isMousePosWithinLeadingSidebarResizeRect(mousePositionInWindow: pointInWindow) {
      log.verbose("User started resize of leading sidebar")
    } else if isMousePosWithinTrailingSidebarResizeRect(mousePositionInWindow: pointInWindow) {
      log.verbose("User started resize of trailing sidebar")
    } else {
      return false
    }

    currentDragObject = playlistView.view
    if currentLayout.isWindowed {
      // Update to latest frame in case window has moved
      windowedModeGeo = windowedGeoForCurrentFrame()
    }
    return true
  }

  /// Called repeatedly while user is dragging to resize the given sidebar, which is expected to be open &
  /// to contain the "playlist" tab group.
  ///
  /// Changes the mouse cursor appropriately. If in windowed mode, also updates `windowedModeGeo`.
  func continueResizingSidebar(_ id: Preference.SidebarLocation, with dragEvent: NSEvent) {
    let currentLayout = currentLayout
    // TODO: Consolidate duplicate code [#PWinGeoForAnyMode]
    let oldGeo: PWinGeometry
    switch currentLayout.mode {
    case .windowedNormal:
      oldGeo = windowedModeGeo
    case .fullScreenNormal:
      oldGeo = currentLayout.buildFullScreenGeometry(inScreenID: windowedModeGeo.screenID, geo.video)
    case .musicMode, .windowedInteractive, .fullScreenInteractive:
      Logger.fatal("ResizeSidebar: current mode unexpected: \(currentLayout.mode)")
    }

    videoView.displayActive()

    let (newCursor, newGeo): (CursorType, PWinGeometry?)

    switch id {
    case .leadingSidebar:
      let newWidth = (videoView.userInterfaceLayoutDirection == .rightToLeft ?
                      window!.frame.width - dragEvent.locationInWindow.x : dragEvent.locationInWindow.x) - 2
      (newCursor, newGeo) = resizeLeadingSidebar(from: oldGeo, desiredWidth: newWidth, isFS: currentLayout.mode.isFullScreen)
    case .trailingSidebar:
      let newWidth = (videoView.userInterfaceLayoutDirection == .rightToLeft ?
                      dragEvent.locationInWindow.x : window!.frame.width - dragEvent.locationInWindow.x) - 2
      (newCursor, newGeo) = resizeTrailingSidebar(from: oldGeo, desiredWidth: newWidth, isFS: currentLayout.mode.isFullScreen)
    }

    if let newGeo {
      switch currentLayout.mode {
      case .windowedNormal:
        applyPWinGeometry(newGeo)
        // Need to update windowedModeGeo for future operations.
        // New geo will have fit=.noConstraints, but we don't want to keep it
        windowedModeGeo = newGeo.clone(screenFit: windowedModeGeo.screenFit)
      case .fullScreenNormal:
        applyPWinGeometry(newGeo)
      case .musicMode, .windowedInteractive, .fullScreenInteractive:
        Logger.fatal("ResizeSidebar: current mode unexpected: \(currentLayout.mode)")
      }
    }

    applyCustomCursor(newCursor)
  }

  private func resizeLeadingSidebar(from oldGeo: PWinGeometry, desiredWidth: CGFloat, isFS: Bool) -> (CursorType, PWinGeometry?) {
    let newPlaylistWidth: CGFloat
    let newGeo: PWinGeometry
    let currentLayout = currentLayout
    let desiredPlaylistWidth = clampPlaylistWidth(desiredWidth)
    let outputScreenFit: ScreenFit = isFS ? oldGeo.screenFit : .noConstraints

    if currentLayout.leadingSidebar.placement == .insideViewport {
      // Stop sidebar from resizing when the viewportView is not wide enough to fit it.
      let negativeDeficit = min(0, oldGeo.getExcessSpaceBetweenInsideSidebars(leadingSidebarWidth: desiredPlaylistWidth, in: oldGeo.viewportSize.width))
      newPlaylistWidth = desiredPlaylistWidth + negativeDeficit
      if newPlaylistWidth < Constants.Sidebar.minPlaylistWidth {
        // should not happen in theory, because playlist shouldn't have been shown when resize started
        log.error("Cannot resize playlist: desired width \(desiredPlaylistWidth) is below minimum!")
        return (.resized_AtLeftMin, nil)
      }
    } else {  /// `placement == .outsideViewport`
      newPlaylistWidth = desiredPlaylistWidth
    }

    /// Updating the sidebar width when it is in "outside" mode will cause the video width to
    /// grow or shrink, which will require its height to change according to its aspectRatio.
    if currentLayout.leadingSidebar.placement == .outsideViewport {
      let playlistWidthDifference = newPlaylistWidth - oldGeo.outsideBars.leading
      let viewportSize = oldGeo.viewportSize
      let newViewportWidth = viewportSize.width - playlistWidthDifference
      let resizedPlaylistGeo = oldGeo.clone(outsideBars: oldGeo.outsideBars.clone(leading: newPlaylistWidth))

      /// If `lockViewportToVideoSize` is `true`, it is necessary to resize the window's height to
      /// accomodate the change in video height.
      if Preference.bool(for: .lockViewportToVideoSize) {
        let desiredViewportSize = NSSize(width: newViewportWidth, height: round(newViewportWidth / viewportSize.aspect))
        // Do not try to move the window if it's slightly off screen; it looks weird. Use .noConstraints
        newGeo = resizedPlaylistGeo.scalingViewport(to: desiredViewportSize, screenFit: outputScreenFit)
      } else {
        /// If `lockViewportToVideoSize` is `false`, window size won't change.
        /// But call `refit` to recalculate videoSize or other internal vars
        newGeo = resizedPlaylistGeo.refitted(using: outputScreenFit)
      }
    } else {  /// `.insideViewport`: needs to refit in case window is so small that the viewport is larger than the video
      let insideBarsNew = oldGeo.insideBars.clone(leading: newPlaylistWidth)
      let resizedPlaylistGeo = oldGeo.clone(insideBars: insideBarsNew)
      newGeo = resizedPlaylistGeo.refitted(using: outputScreenFit)
    }

    Preference.set(Int(newPlaylistWidth), for: .playlistWidth)

    let isWindowWidthChanging = newGeo.windowFrame.width - oldGeo.windowFrame.width != 0
    updateLeadingSidebarWidthConstraints(to: newPlaylistWidth, visible: true,
                                         currentLayout.leadingSidebarPlacement,
                                         isWindowWidthChanging: isWindowWidthChanging)

    if (newPlaylistWidth < desiredPlaylistWidth) || (newPlaylistWidth == Constants.Sidebar.maxPlaylistWidth) {
      return (.resized_AtRightMax, newGeo)
    } else if (desiredPlaylistWidth > newPlaylistWidth) || (newPlaylistWidth == Constants.Sidebar.minPlaylistWidth) {
      return (.resized_AtLeftMin, newGeo)
    }
    return (.resizing_BothDirections, newGeo)
  }

  private func resizeTrailingSidebar(from oldGeo: PWinGeometry, desiredWidth: CGFloat, isFS: Bool) -> (CursorType, PWinGeometry?) {
    let newPlaylistWidth: CGFloat
    let newGeo: PWinGeometry
    let currentLayout = currentLayout
    let desiredPlaylistWidth = clampPlaylistWidth(desiredWidth)
    let outputScreenFit: ScreenFit = isFS ? oldGeo.screenFit : .noConstraints

    if currentLayout.trailingSidebar.placement == .insideViewport {
      let negativeDeficit = min(0, oldGeo.getExcessSpaceBetweenInsideSidebars(trailingSidebarWidth: desiredPlaylistWidth, in: oldGeo.viewportSize.width))

      newPlaylistWidth = desiredPlaylistWidth + negativeDeficit
      if newPlaylistWidth < Constants.Sidebar.minPlaylistWidth {
        log.error("Cannot resize playlist: desired width \(desiredPlaylistWidth) is below minimum!")
        return (.resized_AtRightMax, nil)
      }
    } else {  /// `placement == .outsideViewport`
      newPlaylistWidth = desiredPlaylistWidth
    }

    /// See comments in `resizeLeadingSidebar()` above
    if currentLayout.trailingSidebar.placement == .outsideViewport {
      let playlistWidthDifference = newPlaylistWidth - oldGeo.outsideBars.trailing
      let viewportSize = oldGeo.viewportSize
      let newViewportWidth = viewportSize.width - playlistWidthDifference
      let resizedPlaylistGeo = oldGeo.clone(outsideBars: oldGeo.outsideBars.clone(trailing: newPlaylistWidth))

      if Preference.bool(for: .lockViewportToVideoSize) {
        let desiredViewportSize = NSSize(width: newViewportWidth, height: round(newViewportWidth / viewportSize.aspect))
        newGeo = resizedPlaylistGeo.scalingViewport(to: desiredViewportSize, screenFit: outputScreenFit)
      } else {
        newGeo = resizedPlaylistGeo.refitted(using: outputScreenFit)
      }
    } else {  /// `.insideViewport`
      let resizedPlaylistGeo = oldGeo.clone(insideBars: oldGeo.insideBars.clone(trailing: newPlaylistWidth))
      newGeo = resizedPlaylistGeo.refitted(using: outputScreenFit)
    }

    Preference.set(Int(newPlaylistWidth), for: .playlistWidth)

    let isWindowWidthChanging = newGeo.outsideBars.trailing - oldGeo.outsideBars.trailing != 0
    updateTrailingSidebarWidthConstraints(to: newPlaylistWidth, visible: true,
                                          placement: currentLayout.trailingSidebarPlacement,
                                          isWindowWidthChanging: isWindowWidthChanging)

    if (newPlaylistWidth < desiredPlaylistWidth) || (newPlaylistWidth == Constants.Sidebar.maxPlaylistWidth) {
      return (.resized_AtLeftMin, newGeo)
    } else if (desiredPlaylistWidth > newPlaylistWidth) || (newPlaylistWidth == Constants.Sidebar.minPlaylistWidth) {
      return (.resized_AtRightMax, newGeo)
    }
    return (.resizing_BothDirections, newGeo)
  }

  /// Ends the sidebar resize session after applying one last drag with the given event.
  ///
  /// It is assumed that a valid resize session exists; it does not check.
  /// The cursor is updated as well, using the current mouse position.
  func finishResizingSidebar(_ id: Preference.SidebarLocation, with dragEvent: NSEvent) {
    continueResizingSidebar(id, with: dragEvent)
    finishResizingSidebar(id)
  }

  func finishResizingSidebar(_ id: Preference.SidebarLocation) {
    let newPlaylistWidth = Preference.integer(for: .playlistWidth)

    // Update layout state. Do this inside the animation pipeline to prevent (more) races
    animationPipeline.submitInstantTask{ [self] in
      let moreSidebarState = Sidebar.SidebarMiscState(playlistSidebarWidth: newPlaylistWidth,
                                                      selectedSubSegment: currentLayout.moreSidebarState.selectedSubSegment,
                                                      selectedPluginTabID: currentLayout.moreSidebarState.selectedPluginTabID)
      self.currentLayout = currentLayout.clone(moreSidebarState: moreSidebarState)
    }

    let pointInWindow = mouseLocationInWindow
    if isMousePosWithinLeadingSidebarResizeRect(mousePositionInWindow: pointInWindow) ||
        isMousePosWithinTrailingSidebarResizeRect(mousePositionInWindow: pointInWindow) {
      /// Hovering within area which can resize a sidebar? Set or unset the cursor to `resizeLeftRight`
      applyCustomCursor(.resizing_BothDirections)
    } else {
      applyCustomCursor(.normalCursor)
    }
    log.verbose("Finished resize of \(id) sidebar; playlistWidth is now \(newPlaylistWidth)")
  }

  // MARK: - Other mouse events

  func hideSidebarsOnClick() -> Bool {
    let oldLayout = currentLayout
    let hideLeading = oldLayout.leadingSidebar.isVisible && Preference.bool(for: .hideLeadingSidebarOnClick)
    let hideTrailing = oldLayout.trailingSidebar.isVisible && Preference.bool(for: .hideTrailingSidebarOnClick)

    if hideLeading || hideTrailing {
      animationPipeline.submitInstantTask { [self] in
        let newLayoutState = oldLayout.clone(leadingSidebar: hideLeading ? oldLayout.leadingSidebar.clone(visibility: .closed) : nil,
                                             trailingSidebar: hideTrailing ? oldLayout.trailingSidebar.clone(visibility: .closed) : nil)
        let transition = buildLayoutTransition(named: "HideSidebarsOnClick", from: oldLayout, to: newLayoutState)
        buildTasks(for: transition, totalEndingDuration: 0, thenRun: true)
      }
      return true
    }
    return false
  }

}

// MARK: - SidebarTabGroupViewController

@MainActor protocol SidebarTabGroupViewController {
  var pwc: PlayerWindowController! { get }
  var customTabHeight: CGFloat? { get }

  // Implementing classes need to define this
  func setVerticalConstraints(downshift: CGFloat, tabHeight: CGFloat)
}

extension SidebarTabGroupViewController {
  var customTabHeight: CGFloat? { return nil }

  func updateTabActiveStatus(for btn: NSButton, isActive: Bool) {
    btn.contentTintColor = isActive ? .sidebarTabTintActive : .sidebarTabTint
  }

}
