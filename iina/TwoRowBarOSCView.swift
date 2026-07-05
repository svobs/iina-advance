//
//  TwoRowBarOSCView.swift
//  iina
//
//  Created by Matt Svoboda on 2025-01-30.
//  Copyright © 2025 lhc. All rights reserved.
//

///  ```
///
/// ┌───────────────────────────────────────────────┐
/// │ TwoRowBarOSCView (oscPosition=.bottom)        │
/// │ ┌───────────────────────────────────────────┐ │
/// │ │                                           │ │
/// │ │ Row 1:                                    │ │
/// │ │ PlaySlider[andTimeLabels] Container View  │ │
/// │ │                                           │ │
/// │ ├───────────────────────────────────────────┤ │
/// │ │ Row 2: hStackView                         │ │
/// │ │ ┌─────┐┌──┐┌─┐┌──┐ ─ ─ ─ ─ ┌─────┐┌─────┐ │ │
/// │ │ │Play ││00││/││00│ Central │ Vol ││Tool │ │ │
/// │ │ └─────┘└──┘└─┘└──┘ Spacer  └─────┘└─────┘ │ │
/// │ └───────────────────────────────────────────┘ │
/// └───────────────────────────────────────────────┘
/// ```

class TwoRowBarOSCView: ClickThroughView {
  static let id = "OSC_2RowView"
  static let hStackViewID = "\(TwoRowBarOSCView.id)-HStackView"

  private var oscPosition: Preference.OSCPosition? = nil

  // - Various views

  let hStackView = ClickThroughStackView()
  let centralSpacerView = SpacerView(id: "\(TwoRowBarOSCView.id)-CentralSpacer")
  /// Used only if `PK.oscTimeLabelsAlwaysWrapSlider` is enabled.
  let timeSlashLabel = ClickThroughTextField()

  // - Constraints

  let hStackView_HeightConstraint = OptionalConstraint("\(hStackViewID)_Height")
  /// This subtracts from the height of the icons, but is needed to balance out the space above
  let hStackView_BottomMarginConstraint = OptionalConstraint("\(TwoRowBarOSCView.id)-HStackView-BtmOffset")
  var hStackViewLeadingConstraint: NSLayoutConstraint!
  var hStackViewTrailingConstraint: NSLayoutConstraint!

  init() {
    super.init(frame: .zero)
    idString = TwoRowBarOSCView.id
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = .clear

    hStackView.idString = TwoRowBarOSCView.hStackViewID
    hStackView.orientation = .horizontal
    hStackView.alignment = .centerY
    hStackView.translatesAutoresizingMaskIntoConstraints = false
    hStackView.setClippingResistancePriority(.defaultLow, for: .horizontal)

    addSubview(hStackView)

    timeSlashLabel.idString = "PlayPos-TimeSlashLabel"
    timeSlashLabel.isBordered = false
    timeSlashLabel.drawsBackground = false
    timeSlashLabel.isEditable = false
    timeSlashLabel.refusesFirstResponder = true
    timeSlashLabel.baseWritingDirection = .leftToRight
    timeSlashLabel.stringValue = "/"

    hStackViewLeadingConstraint = hStackView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 0)
    hStackViewLeadingConstraint.identifier = "\(hStackView.idString)_Lead-Offset"

    hStackViewTrailingConstraint = self.trailingAnchor.constraint(equalTo: hStackView.trailingAnchor, constant: 0)
    hStackViewTrailingConstraint.identifier = "\(hStackView.idString)_Trail-Offset"

    hStackViewLeadingConstraint.isActive = true
    hStackViewTrailingConstraint.isActive = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Should be called when no longer needed (for now anyway).
  /// Discards enough of the state to prevent this view & its constraints from causing problems with other layout.
  func dispose() {
    relaxConstraints()
    if let pwc {
      if subviews.contains(pwc.playSliderAndTimeLabelsView) {
        pwc.playSliderAndTimeLabelsView.removeFromSuperview()
      }
    }
    hStackView.removeAllSubviews()
    removeFromSuperview()
  }

  func updateSubviews(from pwc: PlayerWindowController, _ oscGeo: ControlBarGeometry) {
    // Avoid constraint violations while we change things below
    relaxConstraints()

    hStackView.spacing = oscGeo.hStackSpacing

    // Start building subviews list for hStackView
    var viewsForHStack: [NSView] = [pwc.oscPlaybackBtnsView]

    // Choose either playSlider or playSliderAndTimeLabelsView based on pref
    let playSliderTypeView: NSView
    if oscGeo.timeLabelsWrapSlider {
      // Option 2: Both PlaySlider & time labels go in Row 1 (via playSliderAndTimeLabelsView)
      pwc.addSubviewsToPlaySliderAndTimeLabelsView(using: oscGeo)
      playSliderTypeView = pwc.playSliderAndTimeLabelsView
    } else {
      // Option 1: PlaySlider goes in Row 1; time labels in Row 2
      pwc.playSliderAndTimeLabelsView.removeFromSuperview()
      if !Preference.bool(for: .showRemainingTime) {
        viewsForHStack.append(pwc.leftTimeLabel)
        viewsForHStack.append(timeSlashLabel)
      }
      viewsForHStack.append(pwc.rightTimeLabel)
      playSliderTypeView = pwc.playSlider
    }

    playSliderTypeView.removeFromSuperview()
    // Make sure to put PlaySlider below other controls. Older MacOS versions may clip overlapping views
    addSubview(playSliderTypeView, positioned: .below, relativeTo: hStackView)

    switch oscGeo.position {
    case .bottom:
      playSliderTypeView.addConstraintsToFillSuperview(top: 0, leading: oscGeo.leadingSpace_Row1,
                                                       trailing: oscGeo.trailingSpace_Row1)

      if oscPosition != .bottom {
        hStackView_HeightConstraint.createOrReplace(to: 0, priorityInt: 1, pwc.log) { [self] c in
          hStackView.topAnchor.constraint(equalTo: bottomAnchor, constant: c)
        }

        hStackView_BottomMarginConstraint.createOrReplace(to: 0, priorityInt: 1, pwc.log) { [self] c in
          bottomAnchor.constraint(equalTo: hStackView.bottomAnchor, constant: c)
        }
      }
    case .top:
      playSliderTypeView.addConstraintsToFillSuperview(bottom: 0, leading: oscGeo.leadingSpace_Row1,
                                                       trailing: oscGeo.trailingSpace_Row1)

      if oscPosition != .top {
        hStackView_HeightConstraint.createOrReplace(to: 0, priorityInt: 1, pwc.log) { [self] c in
          topAnchor.constraint(equalTo: hStackView.bottomAnchor, constant: c)
        }

        hStackView_BottomMarginConstraint.createOrReplace(to: 0, priorityInt: 1, pwc.log) { [self] c in
          hStackView.topAnchor.constraint(equalTo: topAnchor, constant: c)
        }
      }
    default:
      Logger.fatal("Unsupported position for TwoRowBarOSCView: \(oscGeo.position.description)")
    }
    oscPosition = oscGeo.position

    let bottomMargin = ControlBarGeometry.twoRowOSC_BottomMargin(playSliderHeight: oscGeo.playSliderHeight)
    let hStackViewHeight = oscGeo.fullIconHeight + bottomMargin
    hStackView_HeightConstraint.animateToConstant(hStackViewHeight)

    hStackViewLeadingConstraint.animateToConstant(oscGeo.leadingSpace_Row2)  // TODO: fix play icon spacing
    hStackViewTrailingConstraint.animateToConstant(oscGeo.trailingSpace_Row2)

    viewsForHStack.append(centralSpacerView)
    viewsForHStack.append(pwc.oscVolumeView)
    // Exclude toolbar if it has no items. Otherwise it will still be padded on both sides & will look bad
    let hasToolbar = !pwc.oscToolbarView.subviews.isEmpty
    if hasToolbar {
      viewsForHStack.append(pwc.oscToolbarView)
    }

    // - [Re-]add views to hStack

    hStackView.setViews(viewsForHStack, in: .leading)

    // In case any were previously hidden via stack view clip, restore:
    for view in viewsForHStack {
      view.isHidden = false
    }

    // - Set visibility priorities

    if hasToolbar {
      hStackView.setVisibilityPriority(.detachEarlier, for: pwc.oscToolbarView)
    }

    hStackView.setVisibilityPriority(.detachEarly, for: pwc.oscVolumeView)

    if viewsForHStack.contains(pwc.leftTimeLabel) {
      hStackView.setVisibilityPriority(.detachLessEarly, for: pwc.rightTimeLabel)
      hStackView.setVisibilityPriority(.detachLessEarly, for: timeSlashLabel)
    }

    pwc.log.verbose("Updating TwoRowOSC barH=\(oscGeo.barHeight) sliderH=\(oscGeo.playSliderHeight) btmMargin=\(bottomMargin) hStackH=\(hStackViewHeight) toolIconH=\(oscGeo.toolIconSize)")
    // Although space is stolen from the icons to give to the bottom margin, it is given right back by adding to the top
    // (and overlapping with the btm of the play slider, but that is just empty space not being used anyway).
    hStackView_BottomMarginConstraint.animateToConstant(bottomMargin * 2)

    // Restore enforcement of consraints now that we're done. Do not use .required: the superiew may not be updated at
    // exactly the same time and can result in constraint conflict errors.
    hStackView_BottomMarginConstraint.priority = 1000
    hStackView_HeightConstraint.priority = 900

    pwc.oscToolbarView.needsUpdateConstraints = true
  }

  func relaxConstraints() {
    hStackView_BottomMarginConstraint.weaken()
    hStackView_HeightConstraint.weaken()
  }
}
