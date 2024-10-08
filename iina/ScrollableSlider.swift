//
//  ScrollableSlider.swift
//
//  Created by Nate Thompson on 10/24/17.
//

import Cocoa

/// Original source: https://github.com/thompsonate/Scrollable-NSSlider
class ScrollableSlider: NSSlider {
  var sensitivity: Double {
    1.0
  }

  override func scrollWheel(with event: NSEvent) {
    guard self.isEnabled else { return }

    let range = Double(self.maxValue - self.minValue)
    var delta = Double(0)

    // Allow horizontal scrolling on horizontal and circular sliders
    if _isVertical && self.sliderType == .linear {
      delta = Double(event.deltaY)
    } else if self.userInterfaceLayoutDirection == .rightToLeft {
      delta = Double(event.deltaY + event.deltaX)
    } else {
      delta = Double(event.deltaY - event.deltaX)
    }

    // Account for natural scrolling
    if event.isDirectionInvertedFromDevice {
      delta *= -1
    }

    let increment = range * delta * sensitivity / 100
    var value = self.doubleValue + increment

    // Wrap around if slider is circular
    if self.sliderType == .circular {
      let minValue = Double(self.minValue)
      let maxValue = Double(self.maxValue)

      if value < minValue {
        value = maxValue - abs(increment)
      } else if value > maxValue {
        value = minValue + abs(increment)
      }
    }

    self.doubleValue = value
    self.sendAction(self.action, to: self.target)
  }


  private var _isVertical: Bool {
    if #available(macOS 10.12, *) {
      return self.isVertical
    } else {
      // isVertical is an NSInteger in versions before 10.12
      return self.value(forKey: "isVertical") as! NSInteger == 1
    }
  }
}