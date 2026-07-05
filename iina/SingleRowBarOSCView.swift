//
//  SingleRowBarOSCView.swift
//  iina
//
//  Created by Matt Svoboda on 2025-01-30.
//  Copyright © 2025 lhc. All rights reserved.
//

/// For "bar"-type OSCs: `bottom` and `top` only - not `floating` or music mode.
class SingleRowBarOSCView: ClickThroughStackView {
  static let id = "OSC_1RowView"

  init() {
    super.init(frame: .zero)
    idString = SingleRowBarOSCView.id
    orientation = .horizontal
    alignment = .centerY
    distribution = .gravityAreas
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = .clear
    setClippingResistancePriority(.defaultLow, for: .horizontal)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func dispose() {
    // Not much to do here presently
    removeAllSubviews()
    removeFromSuperview()
  }

  func updateSubviews(from pwc: PlayerWindowController, _ oscGeo: ControlBarGeometry) {
    spacing = oscGeo.hStackSpacing

    pwc.addSubviewsToPlaySliderAndTimeLabelsView(using: oscGeo)
    
    var newViews: [NSView] = [pwc.oscPlaybackBtnsView, pwc.playSliderAndTimeLabelsView, pwc.oscVolumeView]

    // Exclude toolbar if it has no items. Otherwise it will still be padded on both sides & will look bad
    let hasToolbar = !pwc.oscToolbarView.subviews.isEmpty
    if hasToolbar {
      newViews.append(pwc.oscToolbarView)
    }
    setViews(newViews, in: .leading)
    // Seems to help restore views which have been detached from other stack views before being added here
    for view in newViews {
      view.isHidden = false
    }

    setVisibilityPriority(.mustHold, for: pwc.oscPlaybackBtnsView)
    setVisibilityPriority(.detachLessEarly, for: pwc.playSliderAndTimeLabelsView)
    setVisibilityPriority(.detachEarly, for: pwc.oscVolumeView)
    if hasToolbar {
      setVisibilityPriority(.detachEarlier, for: pwc.oscToolbarView)
    }
    edgeInsets = .init(top: 0, left: 0, bottom: 0, right: hasToolbar ? 0 : oscGeo.trailingSpace_Row1)
  }

}
