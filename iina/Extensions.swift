//
//  Extensions.swift
//  iina
//
//  Created by lhc on 12/8/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa
import UniformTypeIdentifiers

infix operator %%

extension Int {
  /** Modulo operator. Swift's remainder operator (%) can return negative values, which is rarely what we want. */
  static  func %% (_ left: Int, _ right: Int) -> Int {
    return (left % right + right) % right
  }

  var isEven: Bool {
    return self % 2 == 0
  }
  var isOdd: Bool {
    return self % 2 != 0
  }
}
import CryptoKit

extension NSSlider {
  /**
   Returns the position of the knob's center point along the slider's track.

   This method calculates the horizontal position of the center of the slider's knob based on the slider's current value (`doubleValue`), the minimum and maximum values, and the slider's dimensions. It can be useful for custom drawing, animations, or hit detection related to the knob's position.

   - Returns: A `CGFloat` representing the x-coordinate of the knob's center along the slider's width.

   - Important: Ensure that the slider's `maxValue` is greater than `minValue`. An assertion is used to validate this.

   Example usage:
   ```swift
   let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
   let knobPosition = slider.knobPointPosition()
   print("The knob is positioned at x-coordinate: \(knobPosition)")
   ```
   */
  func knobPointPosition() -> CGFloat {
    let sliderOrigin = frame.origin.x + knobThickness / 2
    let sliderWidth = frame.width - knobThickness
    assert(maxValue > minValue)
    let knobPos = sliderOrigin + sliderWidth * CGFloat((doubleValue - minValue) / (maxValue - minValue))
    return knobPos
  }
}

extension NSSegmentedControl {
  @discardableResult
  func selectSegment(withLabel label: String) -> Bool {
    for i in 0..<segmentCount {
      if self.label(forSegment: i) == label {
        self.selectedSegment = i
        return true
      }
    }
    Logger.log("Could not find segment with label \(label.quoted). Setting selection to -1", level: .verbose)
    self.selectedSegment = -1
    return false
  }
}

func - (lhs: NSPoint, rhs: NSPoint) -> NSPoint {
  return NSMakePoint(lhs.x - rhs.x, lhs.y - rhs.y)
}

extension CGPoint {
  /**
   Uses the Pythagorean theorem to calculate the distance between two points.

   This method calculates the straight-line distance (Euclidean distance) between the current point and another `CGPoint`. It is useful for measuring distances in a two-dimensional coordinate system, such as when working with points on a canvas or in a graphics context.

   - Parameter to: The target `CGPoint` to which the distance will be calculated.
   - Returns: A `CGFloat` representing the distance between the two points.

   Example usage:
   ```swift
   let pointA = CGPoint(x: 0, y: 0)
   let pointB = CGPoint(x: 3, y: 4)
   let distance = pointA.distance(to: pointB)
   print("Distance between pointA and pointB is \(distance)")  // Output: 5.0
   ```
   */
  func distance(to: CGPoint) -> CGFloat {
    return sqrt(pow(self.x - to.x, 2) + pow(self.y - to.y, 2))
  }
}

extension NSSize {

  var area: CGFloat {
    return width * height
  }

  /**
   Returns the aspect ratio (width divided by height) of the size.

   This property asserts that neither width nor height is zero, and then calculates the aspect ratio.

   - Returns: The aspect ratio of the size as a `CGFloat`.
   */
  var aspect: CGFloat {
    get {
      if width == 0 || height == 0 {
        Logger.log("Returning 1 for NSSize aspectRatio because width or height is 0", level: .warning)
        return 1
      }
      return width / height
    }
  }

  var mpvAspect: CGFloat {
    get {
      return Aspect.mpvPrecision(of: aspect)
    }
  }

  /**
   Resizes the current size to be no smaller than a given minimum size while maintaining the same aspect ratio.

   This method checks if the current size is already larger than the given minimum size, and if not, it resizes the current size to the minimum size, preserving the aspect ratio.

   - Parameter minSize: The minimum size that the current size should satisfy.
   - Returns: The resized `NSSize` that satisfies the minimum size requirement while keeping the same aspect ratio.
   */
  func satisfyMinSizeWithSameAspectRatio(_ minSize: NSSize) -> NSSize {
    if width >= minSize.width && height >= minSize.height {
      return self
    } else {
      return grow(toSize: minSize)
    }
  }

  /**
   Resizes the current size to be no larger than a given maximum size while maintaining the same aspect ratio.

   This method checks if the current size is already smaller than the given maximum size, and if not, it resizes the current size to the maximum size, preserving the aspect ratio.

   - Parameter maxSize: The maximum size that the current size should satisfy.
   - Returns: The resized `NSSize` that satisfies the maximum size requirement while keeping the same aspect ratio.
   */
  func satisfyMaxSizeWithSameAspectRatio(_ maxSize: NSSize) -> NSSize {
    if width <= maxSize.width && height <= maxSize.height {
      return self
    } else {
      return shrink(toSize: maxSize)
    }
  }

  /**
   Crops the current size to fit within a target aspect ratio, reducing either the width or height to match the aspect ratio of the target rectangle.

   - Parameter aspectRect: A rectangle or size structure that contains the desired aspect ratio.
   - Returns: The cropped `NSSize` that fits within the given aspect ratio.
   */
  func crop(withAspect aspectRect: Aspect) -> NSSize {
    let targetAspect = aspectRect.value
    if aspect > targetAspect {  // self is wider, crop width, use same height
      return NSSize(width: round(height * targetAspect), height: height)
    } else {
      return NSSize(width: width, height: round(width / targetAspect))
    }
  }

  func getCropRect(withAspect aspect: Aspect) -> NSRect {
    let croppedSize = crop(withAspect: aspect)
    let cropped = NSMakeRect(round((width - croppedSize.width) / 2),
                             round((height - croppedSize.height) / 2),
                             croppedSize.width,
                             croppedSize.height)
    return cropped
  }

  func expand(withAspect targetAspect: Double) -> NSSize {
    if aspect < targetAspect {  // self is taller, expand width, use same height
      return NSSize(width: height * targetAspect, height: height)
    } else {
      return NSSize(width: width, height: width / targetAspect)
    }
  }

  /**
   Given another size S, returns a size that:

   - maintains the same aspect ratio;
   - has same height or/and width as S;
   - always bigger than S.

   - parameter toSize: The given size S.

   ```
   +--+------+--+
   |  |      |  |
   |  |  S   |  |<-- The result size
   |  |      |  |
   +--+------+--+
   ```
   */
  func grow(toSize size: NSSize) -> NSSize {
    if width == 0 || height == 0 {
      return size
    }
    let sizeAspect = size.aspect
    var newSize: NSSize
    if aspect > sizeAspect {  // self is wider, grow to meet height
      newSize = NSSize(width: size.height * aspect, height: size.height)
    } else {
      newSize = NSSize(width: size.width, height: size.width / aspect)
    }
    Logger.log("Growing \(self) to size \(size). Derived aspect: \(sizeAspect); result: \(newSize)", level: .verbose)
    return newSize
  }

  /**
   Given another size S, returns a size that:

   - maintains the same aspect ratio;
   - has same height or/and width as S;
   - always smaller than S.

   - parameter toSize: The given size S.

   ```
   +--+------+--+
   |  |The   |  |
   |  |result|  |<-- S
   |  |size  |  |
   +--+------+--+
   ```
   */
  func shrink(toSize size: NSSize) -> NSSize {
    if width == 0 || height == 0 {
      return size
    }
    let sizeAspect = size.aspect
    var newSize: NSSize
    if aspect < sizeAspect { // self is taller, shrink to meet height
      newSize = NSSize(width: size.height * aspect, height: size.height)
    } else {
      newSize = NSSize(width: size.width, height: size.width / aspect)
    }
    Logger.log("Shrinking \(self) to size \(size). Derived aspect: \(sizeAspect); result: \(newSize)", level: .verbose)
    return newSize
  }
  /**
   Returns a `NSRect` that represents the size centered within the given `NSRect`.

   This method calculates a new rectangle (`NSRect`) where the current size (`NSSize`) is centered inside the provided rectangle (`rect`). It is useful when you need to center one view or size within another, maintaining its dimensions.

   - Parameter rect: The rectangle within which to center the current size.
   - Returns: A `NSRect` where the current size is centered inside the given rectangle.

   Example usage:
   ```swift
   let size = NSSize(width: 100, height: 50)
   let containerRect = NSRect(x: 0, y: 0, width: 300, height: 200)
   let centeredRect = size.centeredRect(in: containerRect)
   print(centeredRect)  // Output: NSRect(x: 100.0, y: 75.0, width: 100.0, height: 50.0)
   ```
   */
  func centeredRect(in rect: NSRect) -> NSRect {
    return NSRect(x: rect.origin.x + (rect.width - width) / 2,
                  y: rect.origin.y + (rect.height - height) / 2,
                  width: width,
                  height: height)
  }
  /**
   Multiplies both the width and height of the current size by a given multiplier.
   */
  static func * (operand: NSSize, multiplier: CGFloat) -> NSSize {
    return NSSize(width: operand.width * multiplier, height: operand.height * multiplier)
  }
  /**
   Adds a given value to both the width and height of the current size.
   */
  func multiplyThenRound(_ multiplier: CGFloat) -> NSSize {
    return NSSize(width: (width * multiplier).rounded(), height: (height * multiplier).rounded())
  }

  static func + (augend: NSSize, addend: CGFloat) -> NSSize {
    return NSSize(width: augend.width + addend, height: augend.height + addend)
  }

  static func - (minuend: NSSize, subtrahend: NSSize) -> NSSize {
    return NSSize(width: minuend.width - subtrahend.width, height: minuend.height - subtrahend.height)
  }
}


extension NSRect {

  init(vertexPoint pt1: NSPoint, and pt2: NSPoint) {
    self.init(x: min(pt1.x, pt2.x),
              y: min(pt1.y, pt2.y),
              width: abs(pt1.x - pt2.x),
              height: abs(pt1.y - pt2.y))
  }

  func clone(size newSize: NSSize) -> NSRect {
    return NSRect(origin: self.origin, size: newSize)
  }

  func addingTo( top: CGFloat = 0,  trailing: CGFloat = 0, bottom: CGFloat = 0,  leading: CGFloat = 0) -> NSRect {
    return NSRect(x: origin.x - leading, y: origin.y - bottom, width: width + leading + trailing, height: height + top + bottom)
  }

  func subtractingFrom( top: CGFloat = 0,  trailing: CGFloat = 0, bottom: CGFloat = 0,  leading: CGFloat = 0) -> NSRect {
    return addingTo(top: -top, trailing: -trailing, bottom: -bottom, leading: -leading)
  }

  func centeredResize(to newSize: NSSize) -> NSRect {
    var newX = origin.x - (newSize.width - size.width) / 2
    var newY = origin.y - (newSize.height - size.height) / 2
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect.zero
    
    // resizes x and y values so the window always stays within a valid screenFrame
    if screenFrame != NSRect.zero {
      newX = max(min(newX, screenFrame.maxX - newSize.width), screenFrame.minX)
      newY = max(min(newY, screenFrame.maxY - newSize.height), screenFrame.minY)
    }
    return NSRect(x: newX, y: newY, width: newSize.width, height: newSize.height)
  }

  func constrain(in biggerRect: NSRect) -> NSRect {
    // new size, keeping aspect ratio
    var newSize = size
    if newSize.width > biggerRect.width || newSize.height > biggerRect.height {
      /// We should have adjusted the rect's size before getting here. Using `shrink()` is not always 100% correct.
      /// If in debug environment, fail fast. Otherwise log and continue.
      assert(false, "Rect \(newSize) should already be <= rect in which it is being constrained (\(biggerRect))")
      Logger.log("Rect \(newSize) is larger than rect in which it is being constrained (\(biggerRect))! Will attempt to resize but it may be imprecise.")
      newSize = size.shrink(toSize: biggerRect.size)
    }
    // new origin
    var newOrigin = origin
    if newOrigin.x < biggerRect.origin.x {
      newOrigin.x = biggerRect.origin.x
    }
    if newOrigin.y < biggerRect.origin.y {
      newOrigin.y = biggerRect.origin.y
    }
    if newOrigin.x + width > biggerRect.origin.x + biggerRect.width {
      newOrigin.x = biggerRect.origin.x + biggerRect.width - width
    }
    if newOrigin.y + height > biggerRect.origin.y + biggerRect.height {
      newOrigin.y = biggerRect.origin.y + biggerRect.height - height
    }
    return NSRect(origin: newOrigin, size: newSize)
  }
}

extension NSPoint {
  func constrained(to rect: NSRect) -> NSPoint {
    return NSMakePoint(x.clamped(to: rect.minX...rect.maxX), y.clamped(to: rect.minY...rect.maxY))
  }
}

extension Array {
  subscript(at index: Index) -> Element? {
    if indices.contains(index) {
      return self[index]
    } else {
      return nil
    }
  }
}

class ContextMenuItem: NSMenuItem {
  let targetRows: IndexSet

  init(targetRows: IndexSet, title: String, action: Selector?, keyEquivalent: String) {
    self.targetRows = targetRows
    super.init(title: title, action: action, keyEquivalent: keyEquivalent)
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented for ContextMenuItem")
  }
}

extension NSMenu {
  @discardableResult
  func addItem(forRows targetRows: IndexSet? = nil, withTitle string: String, action selector: Selector? = nil, target: AnyObject? = nil,
               tag: Int? = nil, obj: Any? = nil, stateOn: Bool = false, enabled: Bool = true) -> NSMenuItem {
    let menuItem: NSMenuItem
    if let targetRows = targetRows {
      menuItem = ContextMenuItem(targetRows: targetRows, title: string, action: selector, keyEquivalent: "")
    } else {
      menuItem = NSMenuItem(title: string, action: selector, keyEquivalent: "")
    }
    menuItem.tag = tag ?? -1
    menuItem.representedObject = obj
    menuItem.target = target
    menuItem.state = stateOn ? .on : .off
    menuItem.isEnabled = enabled
    self.addItem(menuItem)
    return menuItem
  }
}

extension CGFloat {
  var unifiedDouble: Double {
    get {
      return Double(copysign(1, self))
    }
  }

  var isInteger: Bool {
    return CGFloat(Int(self)) == self
  }

  /// Do not use trailing zeros
  var strMin: String {
    fmtDecimalOmitTrailingZeroes.string(for: self)!
  }
}

extension Bool {
  var yn: String {
    self ? "Y" : "N"
  }

  var yesno: String {
    self ? "YES" : "NO"
  }

  static func yn(_ yn: String?) -> Bool? {
    guard let yn = yn else { return nil }
    switch yn {
    case "Y", "y":
      return true
    case "N", "n":
      return false
    default:
      return nil
    }
  }
}

// Try to use Double instead of CGFloat as declared type - more compatible
extension Double {
  func prettyFormat() -> String {
    let rounded = (self * 1000).rounded() / 1000
    if rounded.truncatingRemainder(dividingBy: 1) == 0 {
      return "\(Int(rounded))"
    } else {
      return "\(rounded)"
    }
  }

  var isInteger: Bool {
    return Double(Int(self)) == self
  }

  var twoDecimalPlaces: String {
    return String(format: "%.2f", self)
  }

  var twoDigitHex: String {
    String(format: "%02X", self)
  }

  func isWithin(_ threshold: CGFloat, of other: CGFloat) -> Bool {
    return abs(self - other) <= threshold
  }

  func isBetweenInclusive(_ lowerBound: Double, and upperBound: Double) -> Bool {
    return self >= lowerBound && self <= upperBound
  }

  func truncatedTo1() -> Double {
    return Double(Int(self * 10)) / 10
  }

  func truncatedTo3() -> Double {
    return Double(Int(self * 1e3)) / 1e3
  }

  func truncatedTo5() -> Double {
    return Double(Int(self * 1e5)) / 1e5
  }

  func truncatedTo6() -> Double {
    return Double(Int(self * 1e6)) / 1e6
  }

  func roundedTo1() -> Double {
    let scaledUp = self * 1e1
    let scaledUpRounded = scaledUp.rounded(.down)
    let finalVal = scaledUpRounded / 1e1
    return finalVal
  }

  func roundedTo2() -> Double {
    let scaledUp = self * 1e2
    let scaledUpRounded = scaledUp.rounded(.down)
    let finalVal = scaledUpRounded / 1e2
    return finalVal
  }

  func roundedTo3() -> Double {
    let scaledUp = self * 1e3
    let scaledUpRounded = scaledUp.rounded(.down)
    let finalVal = scaledUpRounded / 1e3
    return finalVal
  }

  func roundedTo5() -> Double {
    let scaledUp = self * 1e5
    let scaledUpRounded = scaledUp.rounded(.down)
    let finalVal = scaledUpRounded / 1e5
    return finalVal
  }

  func roundedTo6() -> Double {
    let scaledUp = self * 1e6
    let scaledUpRounded = scaledUp.rounded(.down)
    let finalVal = scaledUpRounded / 1e6
    return finalVal
  }

  /// Formats this number as a decimal string, using the default locale.
  ///
  /// This should be used in most places where decimal numbers need to be printed. Do not rely on string interpolation alone
  /// because the number will not be localized.
  ///
  /// For example, if the user's locale formats numbers like `1.234.567,89` (in particular, using
  /// a comma to signify the decimal):
  /// ```
  /// let num: Double = 12.34
  /// let badStr = "Value is \(num)"          // badStr will *always* be "Value is 12.34"
  /// let goodStr = "Value is \(num.string)"  // goodStr will be "Value is 12,34"
  /// ```
  ///
  /// Currently the output string is limited to 15 digits after the decimal. This should be more than
  /// enough for any imaginable use right now, but the limit can and should be increased in the future if
  /// needed. (It's not clear what the maximum allowed value for `NumberFormatter.maximumFractionDigits`
  /// actually is. An attempt to set it equal to `NSIntegerMax` seemed to result in it being silently set to
  /// `6` instead.)
  var string: String {
    return fmtDecimalMaxFractionDigits15.string(from: self as NSNumber) ?? "NaN"
  }
}

extension NSInteger {
  func clamped(to range: Range<Self>) -> Self {
    if self < range.lowerBound {
      return range.lowerBound
    } else if self >= range.upperBound {
      return range.upperBound - 1
    } else {
      return self
    }
  }
}

extension Comparable {

  func clamped(to range: ClosedRange<Self>) -> Self {
    if self < range.lowerBound {
      return range.lowerBound
    } else if self > range.upperBound {
      return range.upperBound
    } else {
      return self
    }
  }
}

fileprivate let fmtDecimalMaxFractionDigits2Truncated: NumberFormatter = {
  let fmt = NumberFormatter()
  fmt.numberStyle = .decimal
  fmt.usesGroupingSeparator = false
  fmt.maximumFractionDigits = 2
  fmt.roundingMode = .floor
  return fmt
}()

fileprivate let fmtDecimalMaxFractionDigits3Truncated: NumberFormatter = {
  let fmt = NumberFormatter()
  fmt.numberStyle = .decimal
  fmt.usesGroupingSeparator = false
  fmt.maximumFractionDigits = 3
  fmt.roundingMode = .floor
  return fmt
}()

fileprivate let fmtDecimalMaxFractionDigits5Truncated: NumberFormatter = {
  let fmt = NumberFormatter()
  fmt.numberStyle = .decimal
  fmt.usesGroupingSeparator = false
  fmt.maximumFractionDigits = 5
  fmt.roundingMode = .floor
  return fmt
}()

fileprivate let fmtDecimalMaxFractionDigits6Truncated: NumberFormatter = {
  let fmt = NumberFormatter()
  fmt.numberStyle = .decimal
  fmt.usesGroupingSeparator = false
  fmt.maximumFractionDigits = 6
  fmt.roundingMode = .floor
  return fmt
}()

// Formats a number to max 2 digits after the decimal, rounded, but will omit trailing zeroes, and no commas or other formatting for large numbers
fileprivate let fmtDecimalMaxFractionDigits2: NumberFormatter = {
  let fmt = NumberFormatter()
  fmt.numberStyle = .decimal
  fmt.usesGroupingSeparator = false
  fmt.maximumFractionDigits = 2
  return fmt
}()

// Formats a number to max 6 digits after the decimal, rounded, but will omit trailing zeroes, and no commas or other formatting for large numbers
fileprivate let fmtDecimalMaxFractionDigits6: NumberFormatter = {
  let fmt = NumberFormatter()
  fmt.numberStyle = .decimal
  fmt.usesGroupingSeparator = false
  fmt.maximumFractionDigits = 6
  return fmt
}()

/// Applies to `Double`, `CGFloat`, ...
fileprivate let fmtDecimalMaxFractionDigits15: NumberFormatter = {
  let fmt = NumberFormatter()
  fmt.numberStyle = .decimal
  fmt.usesGroupingSeparator = true
  fmt.maximumSignificantDigits = 25
  fmt.minimumFractionDigits = 0
  fmt.maximumFractionDigits = 15
  fmt.usesSignificantDigits = false
  return fmt
}()

// Formats a decimal number but will omit trailing zeroes, and will not use commas or other formatting for large numbers
fileprivate let fmtDecimalOmitTrailingZeroes: NumberFormatter = {
  let fmt = NumberFormatter()
  fmt.numberStyle = .decimal
  fmt.usesGroupingSeparator = false
  return fmt
}()

extension CGRect: @retroactive CustomStringConvertible {
  public var description: String {
    return "(\(origin.x.strMin), \(origin.y.strMin), \(size.width.strMin) x \(size.height.strMin))"
  }
}

extension CGSize: @retroactive CustomStringConvertible {
  public var description: String {
    return "(\(width.strMin) x \(height.strMin))"
  }

  /// Finds the smallest box whose size matches the given `aspect` but with width >= `minWidth` & height >= `minHeight`.
  /// Note: `minWidth` & `minHeight` can be any positive integers. They do not need to match `aspect`.
  static func computeMinSize(withAspect aspect: CGFloat, minWidth: CGFloat, minHeight: CGFloat) -> CGSize {
    let sizeKeepingMinWidth = NSSize(width: minWidth, height: round(minWidth / aspect))
    if sizeKeepingMinWidth.height >= minHeight {
      return sizeKeepingMinWidth
    }

    let sizeKeepingMinHeight = NSSize(width: round(minHeight * aspect), height: minHeight)
    if sizeKeepingMinHeight.width >= minWidth {
      return sizeKeepingMinHeight
    }

    // Negative aspect, but just barely?
    if minWidth < minHeight {
      let width = round(minWidth * aspect)
      let sizeScalingUpWidth = NSSize(width: width, height: round(width / aspect))
      if sizeScalingUpWidth.width >= minWidth, sizeScalingUpWidth.height >= minHeight {
        return sizeScalingUpWidth
      }
    }
    let scaledUpHeight = round(minHeight * aspect)
    let sizeScalingUpHeight = NSSize(width: round(scaledUpHeight * aspect), height: scaledUpHeight)
    assert(sizeScalingUpHeight.width >= minWidth && sizeScalingUpHeight.height >= minHeight, "sizeScalingUpHeight \(sizeScalingUpHeight) < \(minWidth)x\(minHeight)")
    return sizeScalingUpHeight
  }

}

extension FloatingPoint {
  func clamped(to range: Range<Self>) -> Self {
    if self < range.lowerBound {
      return range.lowerBound
    } else if self >= range.upperBound {
      return range.upperBound.nextDown
    } else {
      return self
    }
  }

  /// Formats as String, truncating the number to 2 digits after the decimal
  var stringTrunc2f: String {
    return fmtDecimalMaxFractionDigits2Truncated.string(for: self)!
  }

  /// Formats as String, truncating the number to 3 digits after the decimal, and omitting any trailing zeroes
  var stringTrunc3f: String {
    return fmtDecimalMaxFractionDigits3Truncated.string(for: self)!
  }

  /// Formats as String, truncating the number to 5 digits after the decimal, and omitting any trailing zeroes
  var stringTrunc5f: String {
    return fmtDecimalMaxFractionDigits5Truncated.string(for: self)!
  }

  /// Formats as String, truncating the number to 6 digits after the decimal, and omitting any trailing zeroes
  var stringTrunc6f: String {
    return fmtDecimalMaxFractionDigits6Truncated.string(for: self)!
  }

  /// Formats as String, rounding the number to 2 digits after the decimal
  var stringMaxFrac2: String {
    return fmtDecimalMaxFractionDigits2.string(for: self)!
  }

  /// Formats as String, rounding the number to 6 digits after the decimal
  var stringMaxFrac6: String {
    return fmtDecimalMaxFractionDigits6.string(for: self)!
  }

  /// Returns a "normalized" number string for the exclusive purpose of comparing two mpv aspect ratios while avoiding precision errors.
  /// Not pretty to put this here, but need to make this searchable & don't have time for a larger refactor
  var mpvAspectString: String {
    return stringTrunc2f
  }
}

extension NSColor {
  var mpvColorString: String {
    get {
      return "\(self.redComponent)/\(self.greenComponent)/\(self.blueComponent)/\(self.alphaComponent)"
    }
  }

  convenience init?(mpvColorString: String) {
    let splitted = mpvColorString.split(separator: "/").map { (seq) -> Double? in
      return Double(String(seq))
    }
    // check nil
    if (!splitted.contains {$0 == nil}) {
      if splitted.count == 3 {  // if doesn't have alpha value
        self.init(red: CGFloat(splitted[0]!), green: CGFloat(splitted[1]!), blue: CGFloat(splitted[2]!), alpha: CGFloat(1))
      } else if splitted.count == 4 {  // if has alpha value
        self.init(red: CGFloat(splitted[0]!), green: CGFloat(splitted[1]!), blue: CGFloat(splitted[2]!), alpha: CGFloat(splitted[3]!))
      } else {
        return nil
      }
    } else {
      return nil
    }
  }
}


extension NSMutableAttributedString {
  convenience init?(linkTo url: String, text: String, font: NSFont) {
    self.init(string: text)
    let range = NSRange(location: 0, length: self.length)
    let nsurl = NSURL(string: url)!
    self.beginEditing()
    self.addAttribute(.link, value: nsurl, range: range)
    self.addAttribute(.font, value: font, range: range)
    self.endEditing()
  }

  // Adds the given attribute for the entire string
  func addAttrib(_ key: NSAttributedString.Key, _ value: Any) {
    self.addAttributes([key: value], range: NSRange(location: 0, length: self.length))
  }

  func addItalic(using font: NSFont?) {
    if let italicFont = makeItalic(font) {
      self.addAttrib(NSAttributedString.Key.font, italicFont)
    }
  }

  private func makeItalic(_ font: NSFont?) -> NSFont? {
    if let font = font {
      let italicDescriptor: NSFontDescriptor = font.fontDescriptor.withSymbolicTraits(NSFontDescriptor.SymbolicTraits.italic)
      return NSFont(descriptor: italicDescriptor, size: 0)
    }
    return nil
  }
}


extension NSData {
  var md5: String { Insecure.MD5.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}

extension Data {
  init<T> (bytesOf thing: T) where T: FixedWidthInteger {
    var copyOfThing = thing
    self.init(bytes: &copyOfThing, count: MemoryLayout<T>.size)
  }

  init(bytesOf num: Double) {
    var numCopy = num
    self.init(bytes: &numCopy, count: MemoryLayout<Double>.size)
  }

  init(bytesOf ts: timespec) {
    var mutablePointer = ts
    self.init(bytes: &mutablePointer, count: MemoryLayout<timespec>.size)
  }

  var md5: String {
    get {
      return (self as NSData).md5
    }
  }

  var chksum64: UInt64 {
    return withUnsafeBytes {
      $0.bindMemory(to: UInt64.self).reduce(0, &+)
    }
  }

  func saveToFolder(_ url: URL, filename: String) -> URL? {
    let fileUrl = url.appendingPathComponent(filename)
    do {
      try self.write(to: fileUrl)
    } catch {
      Utility.showAlert("error_saving_file", arguments: ["data", filename])
      return nil
    }
    return fileUrl
  }
}

extension FileHandle {
  func read<T>(type: T.Type /* To prevent unintended specializations */) -> T? {
    let size = MemoryLayout<T>.size
    let data = readData(ofLength: size)
    guard data.count == size else {
      return nil
    }
    return data.withUnsafeBytes {
      $0.bindMemory(to: T.self).first!
    }
  }
}

extension String {
  var md5: String {
    get {
      return self.data(using: .utf8)!.md5
    }
  }

  // Returns a lookup token for the given string, which can be used in its place to privatize the log.
  // The pii.txt file is required to match the lookup token with the privateString.
  var pii: String {
    Logger.getOrCreatePII(for: self)
  }

  var isDirectoryAsPath: Bool {
    get {
      var re = ObjCBool(false)
      FileManager.default.fileExists(atPath: self, isDirectory: &re)
      return re.boolValue
    }
  }

  var lowercasedPathExtension: String {
    return (self as NSString).pathExtension.lowercased()
  }

  var mpvFixedLengthQuoted: String {
    return "%\(count)%\(self)"
  }

  func equalsIgnoreCase(_ other: String) -> Bool {
    return localizedCaseInsensitiveCompare(other) == .orderedSame
  }

  var quoted: String {
    return "\"\(self)\""
  }

  func containsWhitespaceOrNewlines() -> Bool {
    return rangeOfCharacter(from: .whitespacesAndNewlines) != nil
  }

  func deletingPrefix(_ prefix: String) -> String {
    guard self.hasPrefix(prefix) else { return self }
    return String(self.dropFirst(prefix.count))
  }

  mutating func deleteLast(_ num: Int) {
    removeLast(Swift.min(num, count))
  }

  func countOccurrences(of str: String, in range: Range<Index>?) -> Int {
    if let firstRange = self.range(of: str, options: [], range: range, locale: nil) {
      let nextRange = firstRange.upperBound..<self.endIndex
      return 1 + countOccurrences(of: str, in: nextRange)
    } else {
      return 0
    }
  }
}


extension CharacterSet {
  static let urlAllowed: CharacterSet = {
    var set = CharacterSet.urlHostAllowed
      .union(.urlUserAllowed)
      .union(.urlPasswordAllowed)
      .union(.urlPathAllowed)
      .union(.urlQueryAllowed)
      .union(.urlFragmentAllowed)
    set.insert(charactersIn: "%")
    return set
  }()
}


extension NSMenuItem {
  static let dummy = NSMenuItem(title: "Dummy", action: nil, keyEquivalent: "")

  var menuPathDescription: String {
    var ancestors: [String] = [self.title]
    var parent = self.parent
    while let parentItem = parent {
      ancestors.append(parentItem.title)
      parent = parentItem.parent
    }
    return ancestors.reversed().joined(separator: " → ")
  }

}


extension URL {
  var creationDate: Date? {
    (try? resourceValues(forKeys: [.creationDateKey]))?.creationDate
  }

  var isExistingDirectory: Bool {
    return (try? self.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
  }
}

extension RangeExpression where Bound == String.Index  {
  func nsRange<S: StringProtocol>(in string: S) -> NSRange { .init(self, in: string) }
}

extension NSTextField {

  func setHTMLValue(_ html: String) {
    let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let color = self.textColor ?? NSColor.labelColor
    if let data = html.data(using: .utf8), let str = NSMutableAttributedString(html: data,
                                                                               options: [.textEncodingName: "utf8"],
                                                                               documentAttributes: nil) {
      str.addAttributes([.font: font, .foregroundColor: color], range: NSMakeRange(0, str.length))
      self.attributedStringValue = str
    }
  }

  func setText(_ textContent: String, textColor: NSColor) {
    setFormattedText(stringValue: textContent, textColor: textColor)
    stringValue = textContent
    toolTip = textContent
  }

  func setFormattedText(stringValue: String, textColor: NSColor? = nil,
                        strikethrough: Bool = false, italic: Bool = false) {
    let attrString = NSMutableAttributedString(string: stringValue)

    let fgColor: NSColor
    if let textColor = textColor {
      // If using custom text colors, need to make sure `EditableTextFieldCell` is specified
      // as the class of the child cell in Interface Builder.
      fgColor = textColor
    } else {
      fgColor = NSColor.controlTextColor
    }
    self.textColor = fgColor

    if strikethrough {
      attrString.addAttrib(NSAttributedString.Key.strikethroughStyle, NSUnderlineStyle.single.rawValue)
    }

    if italic {
      attrString.addItalic(using: self.font)
    }
    self.attributedStringValue = attrString
  }

}

extension CGContext {
  /// Decorator which encloses `closure` with `saveGState` at start and `restoreGState` at end
  func withNestedGState<T>(_ closure: () throws -> T) rethrows -> T {
    saveGState()
    defer {
      restoreGState()
    }
    return try closure()
  }

  func drawRoundedRect(_ rect: NSRect, cornerRadius: CGFloat, fillColor: CGColor) {
    setFillColor(fillColor)
    // Clip its corners to round it:
    beginPath()
    addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
    closePath()
    clip()
    fill([rect])
  }
}


extension CGImage {
  /// Returns this image's data in PNG format, suitable for writing to a `.png` file on disk
  var pngData: Data? {
    guard let mutableData = CFDataCreateMutable(nil, 0),
          let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, self, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return mutableData as Data
  }

  @discardableResult
  func saveAsPNG(fileURL: URL) -> Bool {
    let path = fileURL.path
    guard FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil) else {
      Logger.log("Could not create PNG file: \(path.pii.quoted)", level: .error)
      return false
    }
    guard let file = try? FileHandle(forWritingTo: fileURL) else {
      Logger.log("Could not create PNG file for writing: \(path.pii.quoted)", level: .error)
      return false
    }

    guard let pngData else {
      Logger.log("Could not get PNG data from CGImage!", level: .error)
      return false
    }

    file.write(pngData)

    if #available(macOS 10.15, *) {
      do {
        try file.close()
      } catch {
        Logger.log("Failed to close file: \(path.pii.quoted)", level: .error)
      }
    }
    return true
  }
}

extension NSImage {
  @available(macOS 11.0, *)
  static func documentIcon(forSuffix fileSuffix: String, height: CGFloat) -> NSImage {
    var baseIcon: NSImage
    if fileSuffix == "" {
      baseIcon = NSWorkspace.shared.icon(for: .data)
    } else {
      if let uttype = UTType.types(tag: fileSuffix, tagClass: .filenameExtension, conformingTo: nil).first {
        baseIcon = NSWorkspace.shared.icon(for: uttype)
      } else {
        baseIcon = NSWorkspace.shared.icon(for: .data)
      }
    }
    return baseIcon.getBestRepresentation(height: height)
  }

  /// Assuming this image is a file icon, gets the appropriate size with given height
  /// Thanks to "Sweeper" at https://stackoverflow.com/questions/62525921/how-to-get-a-high-resolution-app-icon-for-any-application-on-a-mac
  func getBestRepresentation(height: CGFloat) -> NSImage {
    var bestRep: NSImage = self
    if let imageRep = self.bestRepresentation(for: NSRect(x: 0, y: 0, width: height, height: height), context: nil, hints: nil) {
      bestRep = NSImage(size: imageRep.size)
      bestRep.addRepresentation(imageRep)
    }

    bestRep.size = NSSize(width: height, height: height)
    return bestRep
  }

  func tinted(_ tintColor: NSColor) -> NSImage {
    guard self.isTemplate else { return self }

    let image = self.copy() as! NSImage
    image.lockFocus()

    tintColor.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)

    image.unlockFocus()
    image.isTemplate = false

    return image
  }

  func rounded() -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()

    let frame = NSRect(origin: .zero, size: size)
    NSBezierPath(ovalIn: frame).addClip()
    draw(at: .zero, from: frame, operation: .sourceOver, fraction: 1)

    image.unlockFocus()
    return image
  }

  var cgImage: CGImage? {
    var rect = CGRect.init(origin: .zero, size: self.size)
    return self.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }

  // https://github.com/venj/Cocoa-blog-code/blob/master/Round%20Corner%20Image/Round%20Corner%20Image/NSImage%2BRoundCorner.m
  func roundCorners(withRadius radius: CGFloat) -> NSImage {
    let rect = NSRect(origin: NSPoint.zero, size: size)
    if
      let cgImage = self.cgImage,
      let context = CGContext(data: nil,
                              width: Int(size.width),
                              height: Int(size.height),
                              bitsPerComponent: 8,
                              bytesPerRow: 4 * Int(size.width),
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
      context.beginPath()
      context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
      context.closePath()
      context.clip()
      context.draw(cgImage, in: rect)

      if let composedImage = context.makeImage() {
        return NSImage(cgImage: composedImage, size: size)
      }
    }

    return self
  }

  /// This uses CoreGraphics calls, which in tests was ~5x faster than using `NSAffineTransform` on `NSImage` directly
  func rotated(degrees: Int) -> NSImage {
    let currentImage = self.cgImage!
    let imgRect = CGRect(origin: CGPointZero, size: CGSize(width: currentImage.width, height: currentImage.height))

    let angleRadians = degToRad(CGFloat(degrees))
    let imgRotateTransform = rotateTransformRectAroundCenter(rect: imgRect, angle: angleRadians)
    let rotatedImgFrame = CGRectApplyAffineTransform(imgRect, imgRotateTransform)


    let drawingCalls: (CGContext) -> Void = { [self] cgContext in
      let rotateContext = rotateTransformRectAroundCenter(rect: rotatedImgFrame, angle: angleRadians)
      cgContext.concatenate(rotateContext)
      cgContext.draw(currentImage, in: imgRect)
    }
    return NSImage.buildBitmapImage(width: Int(rotatedImgFrame.size.width), height: Int(rotatedImgFrame.size.height), drawingCalls: drawingCalls)!
  }

  private func degToRad(_ degrees: CGFloat) -> CGFloat {
    return degrees * CGFloat.pi / 180
  }

  /// returns the transform equivalent of rotating a rect around its center
  private func rotateTransformRectAroundCenter(rect:CGRect, angle:CGFloat) -> CGAffineTransform {
    let t = CGAffineTransformConcat(
      CGAffineTransformMakeTranslation(-rect.origin.x-rect.size.width*0.5, -rect.origin.y-rect.size.height*0.5),
      CGAffineTransformMakeRotation(angle)
    )
    return CGAffineTransformConcat(t, CGAffineTransformMakeTranslation(rect.size.width*0.5, rect.size.height*0.5))
  }

  func cropped(normalizedCropRect: NSRect) -> NSImage {
    let cropOrigin = NSPoint(x: round(size.width * normalizedCropRect.origin.x), y: round(size.height * normalizedCropRect.origin.y))
    let cropSize = NSSize(width: round(size.width * normalizedCropRect.size.width), height: round(size.height * normalizedCropRect.size.height))
    let cropRect = CGRect(origin: cropOrigin, size: cropSize)

    if Logger.isTraceEnabled {
      Logger.log("Cropping image size \(size) using cropRect \(cropRect)", level: .verbose)
    }
    guard let currentImage = self.cgImage else {
      Logger.log("Failed to crop image: could not get cgImage", level: .error)
      return self
    }
    let croppedImage = currentImage.cropping(to: cropRect)!
    return NSImage(cgImage: croppedImage, size: cropSize)
  }

  /// `cornerRadius`: if greater than 0, round the corners by this radius
  func resized(newWidth: Int, newHeight: Int, cornerRadius: CGFloat = 0) -> NSImage {
    guard CGFloat(newWidth) != self.size.width || CGFloat(newHeight) != self.size.height else {
      return self
    }

    guard newWidth > 0, newHeight > 0 else {
      Logger.fatal("NSImage.resized: invalid width (\(newWidth)) or height (\(newHeight)) - both must be greater than 0")
    }

    // Use raw CoreGraphics calls instead of their NS equivalents. They are > 10x faster, and only downside is that the image's
    // dimensions must be integer values instead of decimals.
    guard let currentImage = self.cgImage else {
      Logger.log("Failed to resize image: could not get cgImage", level: .error)
      return self
    }

    let newImage = NSImage.buildBitmapImage(width: Int(newWidth), height: Int(newHeight), drawingCalls: { cgContext in
      let outputRect = CGRect(x: 0, y: 0, width: newWidth, height: newHeight)
      if cornerRadius > 0.0 {
        cgContext.beginPath()
        cgContext.addPath(CGPath(roundedRect: outputRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        cgContext.closePath()
        cgContext.clip()
      }
      cgContext.draw(currentImage, in: outputRect)
    })

    guard let newImage else { return self }
    return newImage
  }

  /// Builds a bitmap image efficiently using CoreGraphics APIs.
  ///
  /// If it's found useful for any more situations, should put in its own class
  static func buildBitmapImage(width: Int, height: Int, drawingCalls: (CGContext) -> Void) -> NSImage? {

    guard let compositeImageRep = NSImage.makeNewImgRep(width: width, height: height) else {
      Logger.log("DrawImageInBitmapImageContext: Failed to create NSBitmapImageRep!", level: .error)
      return nil
    }

    guard let context = NSGraphicsContext(bitmapImageRep: compositeImageRep) else {
      Logger.log("DrawImageInBitmapImageContext: Failed to create NSGraphicsContext!", level: .error)
      return nil
    }

    drawingCalls(context.cgContext)

    let outputImage = NSImage(size: CGSize(width: width, height: height))
    // Create the CGImage from the contents of the bitmap context.
    outputImage.addRepresentation(compositeImageRep)

    return outputImage
  }

  /// Creates RGB image with alpha channel
  private static func makeNewImgRep(width: Int, height: Int) -> NSBitmapImageRep? {
    return NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: NSColorSpaceName.calibratedRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0)
  }

  /// Try to find a SF Symbol. This function will iterate through the provided list of SF Symbol name list to and return the
  /// first available SF Symbol at runtime.
  ///
  /// Even though SF Symbol is available from macOS 11, we require at macOS 14 to use SF Symbol for the sake of consistency. On
  /// older systems (macOS 13 and below), because SF Symbols are not complete enough for our usage, we don't use them at all.
  /// If a better symbol is found in a later release of SF Symbol, place it at the first of the name list, so that IINA running
  /// on the latest version of macOS can make use of it; IINA running on a older version of macOS will fallback to a symbol
  /// in a previous release of SF Symbol. But the list of name must contain a symbol which is available in macOS 14 (SF Symbol 5).
  ///
  /// - Parameters:
  ///   - names: A list name of the SF Symbol. The name requires higher SF Symbol version must be at front, with fallback SF Symbol
  ///   names at later indexes. The last one must be available in macOS 14 (SF Symbol 5), otherwise a fatal error will occur.
  ///   - configuration: The symbol configuration for the SF symbol. Optional.
  @available(macOS 14.0, *)
  static func findSFSymbol(_ names: [String], withConfiguration configuration: NSImage.SymbolConfiguration? = nil) -> NSImage {
    for name in names {
      if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
        if let configuration, let configured = symbol.withSymbolConfiguration(configuration) {
          return configured
        }
        return symbol
      }
    }
    fatalError("Could not find SF Symbol: \(names)")
  }

}


extension NSVisualEffectView {
  func roundCorners(withRadius cornerRadius: CGFloat) {
    layer?.cornerRadius = cornerRadius
  }

  func roundCorners() {
    let radius = suggestedRoundedCornerRadius()
    roundCorners(withRadius: radius)
  }
}


extension NSBox {
  static func horizontalLine() -> NSBox {
    let box = NSBox(frame: NSRect(origin: .zero, size: NSSize(width: 100, height: 1)))
    box.boxType = .separator
    return box
  }
}

extension NSEvent.Phase {
  var name: String {
    if self.contains(.began) {
      return "began"
    }
    if self.contains(.stationary) {
      return "stationary"
    }
    if self.contains(.changed) {
      return "changed"
    }
    if self.contains(.ended) {
      return "ended"
    }
    if self.contains(.mayBegin) {
      return "mayBegin"
    }
    if self.contains(.cancelled) {
      return "cancelled"
    }
    if self.isEmpty {
      return "none"
    }

    return "UNKNOWN"
  }
}

extension NSPasteboard {

  func getStringItems() -> [String] {
    guard let pasteboardItems else { return [] }
    return pasteboardItems.compactMap{$0.string(forType: .string)}
  }
}


extension NSPasteboard.PasteboardType {
  static let nsURL = NSPasteboard.PasteboardType("NSURL")
  static let nsFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
  static let iinaPlaylistItem = NSPasteboard.PasteboardType("IINAPlaylistItem")
}


extension NSWindow.Level {
  static let iinaFloating = NSWindow.Level(NSWindow.Level.floating.rawValue - 1)
  static let iinaBlackScreen = NSWindow.Level(NSWindow.Level.mainMenu.rawValue + 1)
}

extension NSUserInterfaceItemIdentifier {
  static let isChosen = NSUserInterfaceItemIdentifier("IsChosen")
  static let trackId = NSUserInterfaceItemIdentifier("TrackId")
  static let trackName = NSUserInterfaceItemIdentifier("TrackName")
  static let key = NSUserInterfaceItemIdentifier("Key")
  static let value = NSUserInterfaceItemIdentifier("Value")
}

extension NSAppearance {
  convenience init?(iinaTheme theme: Preference.Theme) {
    switch theme {
    case .dark:
      self.init(named: .darkAqua)
    case .light:
      self.init(named: .aqua)
    default:
      return nil
    }
  }

  var isDark: Bool {
    return name == .darkAqua || name == .vibrantDark || name == .accessibilityHighContrastDarkAqua || name == .accessibilityHighContrastVibrantDark
  }

  // Performs the given closure with this appearance by temporarily making this the current appearance.
  func applyAppearanceFor<T>(_ closure: ()  -> T) -> T {
    if #available(macOS 11.0, *) {
      var result: T?
      self.performAsCurrentDrawingAppearance {
        result = closure()
      }
      return result!
    } else {
      let previousAppearance = NSAppearance.current
      NSAppearance.current = self
      defer {
        NSAppearance.current = previousAppearance
      }
      return closure()
    }
  }
}

extension NSApplication {
  /// Returns `PlayerWindowController` array for all open player windows.
  static var playerWindows: [PlayerWindowController] {
    return NSApp.windows.compactMap{ $0.windowController as? PlayerWindowController }.filter{ $0.isOpen }
  }
}

extension NSScreen {
  static func getOwnerScreenID(forPoint point: NSPoint) -> String? {
    for screen in NSScreen.screens {
      if screen.frame.contains(point) {
        return screen.screenID
      }
    }
    return nil
  }

  /// Apple's documentation says to use the origin (lower-left corner) to determine which screen the rect belongs to.
  /// But this doesn't seem intuitive because the window's title bar is traditionally the most important part of the window,
  /// and that is at the top of the rect. Let's use the upper-left corner instead.
  static func getOwnerScreenID(forViewRect viewRect: NSRect) -> String? {
    var x = viewRect.origin.x
    /// Subtract 1 from `maxY`. Seems that `contains(point)` will return `nil` for points at the very top (i.e., it excludes the topmost row).
    /// However, this only seems to happen if the screen being tested is directly above another one.
    let y = viewRect.maxY - 1
    var ownerScreenID = getOwnerScreenID(forPoint: NSPoint(x: x, y: y))
    if ownerScreenID == nil {
      // If upper-left corner is off screen, try using upper-right corner.
      // Should help avoid case where left side of window is slightly off screen & window ends up defaulting to main screen
      x = viewRect.maxX
      ownerScreenID = getOwnerScreenID(forPoint: NSPoint(x: x, y: y))
    }
    Logger.log("ViewRect=\(viewRect) → point=(\(x), \(y)) → owner screen is \(ownerScreenID?.debugDescription ?? "nil")", level: .verbose)
    return ownerScreenID
  }

  static func getOwnerOrDefaultScreenID(forViewRect viewRect: NSRect) -> String {
    return getOwnerScreenID(forViewRect: viewRect) ?? screens[0].screenID
  }

  static func getOwnerOrDefaultScreenID(forPoint point: NSPoint) -> String {
    return getOwnerScreenID(forPoint: point) ?? screens[0].screenID
  }

  static func forScreenID(_ screenID: String) -> NSScreen? {
    let splitted = screenID.split(separator: ":")
    guard splitted.count > 0, let displayID = UInt32(splitted[0]) else { return nil }
    if let screen = forDisplayID(displayID) {
      // TODO: better matching logic. There is no guarantee that displayId will be consistent for the same screen across launches
      if screen.screenID != screenID {
        Logger.log("NSScreen with displayID \(displayID) is not exact match! Search target was \(screenID.quoted), but found \(screen.screenID.quoted). It is possible the wrong screen is being returned", level: .error)
      }
      return screen
    }
    Logger.log("Failed to find an NSScreen for screenID \(screenID.quoted). Returning nil", level: .error)
    return nil
  }

  static func forDisplayID(_ displayID: UInt32) -> NSScreen? {
    for screen in NSScreen.screens {
      if screen.displayId == displayID {
        return screen
      }
    }
    return nil
  }

  static func getScreenOrDefault(screenID: String) -> NSScreen {
    if let screen = forScreenID(screenID) {
      return screen
    }

    Logger.log("Failed to find an NSScreen for screenID \(screenID.quoted). Returning default screen", level: .debug)
    return NSScreen.screens[0]
  }

  /// Height of the camera housing on this screen if this screen has an embedded camera.
  var cameraHousingHeight: CGFloat? {
    if #available(macOS 12.0, *) {
      return safeAreaInsets.top == 0.0 ? nil : safeAreaInsets.top
    } else {
      return nil
    }
  }

  var frameWithoutCameraHousing: NSRect {
    if #available(macOS 12.0, *) {
      let frame = self.frame
      return NSRect(origin: frame.origin, size: CGSize(width: frame.width, height: frame.height - safeAreaInsets.top))
    } else {
      return self.frame
    }
  }

  var hasCameraHousing: Bool {
    return (cameraHousingHeight ?? 0) > 0
  }

  var displayId: UInt32 {
    return deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! UInt32
  }

  var screenID: String {
    if #available(macOS 10.15, *) {
      return "\(displayId):\(localizedName)"
    }
    return "\(displayId)"
  }

  // Returns nil on failure (not sure if success is guaranteed)
  var nativeResolution: CGSize? {
    // if there's a native resolution found in this method, that's more accurate than above
    guard let displayModes = CGDisplayCopyAllDisplayModes(displayId, nil) as? [CGDisplayMode] else {
      Logger.log("Failed to get CGDisplayModes for displayID \(displayId)! Returning nil", level: .warning)
      return nil
    }
    for mode in displayModes {
      let isNative = mode.ioFlags & UInt32(kDisplayModeNativeFlag) > 0
      if isNative {
        return CGSize(width: mode.width, height: mode.height)
      }
    }

    return nil
  }

  /// Gets the actual scale factor, because `NSScreen.backingScaleFactor` does not provide this.
  var screenScaleFactor: CGFloat {
    if let nativeSize = nativeResolution {
      return CGFloat(nativeSize.width) / frame.size.width
    }
    return 1.0  // default fallback
  }
}

extension NSWindow {

  /// Provides a unique window ID for reference by `UIState`.
  var savedStateName: String {
    if let playerController = windowController as? PlayerWindowController {
      // Not using AppKit autosave for player windows. Instead build ID based on player label
      return WindowAutosaveName.playerWindow(id: playerController.player.label).string
    }
    // Default to the AppKit autosave ID for all other windows.
    return frameAutosaveName
  }

  /// Return the screen to use by default for this window.
  ///
  /// This method searches for a screen to use in this order:
  /// - `window!.screen` The screen where most of the window is on; it is `nil` when the window is offscreen.
  /// - `NSScreen.main` The screen containing the window that is currently receiving keyboard events.
  /// - `NSScreen.screens[0]` The primary screen of the user’s system.
  ///
  /// `PlayerCore` caches players along with their windows. This window may have been previously used on an external monitor
  /// that is no longer attached. In that case the `screen` property of the window will be `nil`.  Apple documentation is silent
  /// concerning when `NSScreen.main` is `nil`.  If that is encountered the primary screen will be used.
  ///
  /// - returns: The default `NSScreen` for this window
  func selectDefaultScreen() -> NSScreen {
    if screen != nil {
      return screen!
    }
    if NSScreen.main != nil {
      return NSScreen.main!
    }
    return NSScreen.screens[0]
  }

  var screenScaleFactor: CGFloat {
    return selectDefaultScreen().screenScaleFactor
  }

  var isAnotherWindowInFullScreen: Bool {
    for winCon in NSApplication.playerWindows {
      if winCon.window != self, winCon.isFullScreen {
        return true
      }
    }
    return false
  }

  /// Excludes the Inspector window
  var isOnlyOpenWindow: Bool {
    if savedStateName == WindowAutosaveName.openFile.string && AppDelegate.shared.isShowingOpenFileWindow {
      return false
    }
    for window in NSApp.windows {
      if window != self, let knownWindowName = WindowAutosaveName(window.savedStateName), knownWindowName != .inspector, window.isOpen {
        return false
      }
    }
    Logger.log("Window is the only window currently open: \(savedStateName.quoted)", level: .verbose)
    return true
  }

  var isOpen: Bool {
    if let windowController = self.windowController as? PlayerWindowController, windowController.isOpen {
      return true
    } else if self.isVisible || self.isMiniaturized {
      return true
    }
    return false
  }

  func postWindowIsReadyToShow() {
    NotificationCenter.default.post(Notification(name: .windowIsReadyToShow, object: self))
  }

  func postWindowMustCancelShow() {
    NotificationCenter.default.post(Notification(name: .windowMustCancelShow, object: self))
  }
}


class IINAWindowController: NSWindowController {

  func openWindow(_ sender: Any?) {
    guard let window else {
      Logger.log("Cannot open window: no window object!", level: .error)
      return
    }

    /// Make sure `windowsOpen` is updated. This patches certain possible race conditions during launch
    let windowName = window.savedStateName
    if !windowName.isEmpty {
      Preference.UIState.windowsOpen.insert(windowName)
    }

    window.postWindowIsReadyToShow()
  }
}

extension NSTableCellView {
  func setTitle(_ title: String, textColor: NSColor) {
    textField?.setText(title, textColor: textColor)
  }
}

extension NSScrollView {
  // Note: if false is returned, no scroll occurred, and the caller should pick a suitable default.
  // This is because NSScrollViews containing NSTableViews can be screwy and
  // have some arbitrary negative value as their "no scroll".
  func restoreVerticalScroll(key: Preference.Key) -> Bool {
    if Preference.UIState.isRestoreEnabled {
      if let offsetY: Double = Preference.value(for: key) as? Double {
        Logger.log("Restoring vertical scroll to: \(offsetY)", level: .verbose)
        // Note: *MUST* use scroll(to:), not scroll(_)! Weird that the latter doesn't always work
        self.contentView.scroll(to: NSPoint(x: 0, y: offsetY))
        return true
      }
    }
    return false
  }

  // Adds a listener to record scroll position for next launch
  func addVerticalScrollObserver(key: Preference.Key) -> NSObjectProtocol {
    let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                          object: self.contentView, queue: .main) { note in
      if let clipView = note.object as? NSClipView {
        let scrollOffsetY = clipView.bounds.origin.y
//        Logger.log("Saving Y scroll offset \(key.rawValue.quoted): \(scrollOffsetY)", level: .verbose)
        Preference.UIState.set(scrollOffsetY, for: key)
      }
    }
    return observer
  }
  
  // Combines the previous 2 functions into one
  func restoreAndObserveVerticalScroll(key: Preference.Key, defaultScrollAction: () -> Void) -> NSObjectProtocol {
    if !restoreVerticalScroll(key: key) {
      Logger.log("Did not restore scroll (key: \(key.rawValue.quoted), isRestoreEnabled: \(Preference.UIState.isRestoreEnabled)); will use default scroll action", level: .verbose)
      defaultScrollAction()
    }
    return addVerticalScrollObserver(key: key)
  }
}

extension Process {
  @discardableResult
  static func run(_ cmd: [String], at currentDir: URL? = nil) -> (process: Process, stdout: Pipe, stderr: Pipe) {
    guard cmd.count > 0 else {
      fatalError("Process.launch: the command should not be empty")
    }

    let (stdout, stderr) = (Pipe(), Pipe())
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cmd[0])
    process.currentDirectoryURL = currentDir
    process.arguments = [String](cmd.dropFirst())
    process.standardOutput = stdout
    process.standardError = stderr
    process.launch()
    process.waitUntilExit()

    return (process, stdout, stderr)
  }
}
/**
 Adds functionality to detect & report which queue the calling thread is in.
 From: https://stackoverflow.com/questions/17475002/get-current-dispatch-queue
 */
extension DispatchQueue {

  private struct QueueReference { weak var queue: DispatchQueue? }

  private static let key: DispatchSpecificKey<QueueReference> = {
    let key = DispatchSpecificKey<QueueReference>()
    setupSystemQueuesDetection(key: key)
    return key
  }()

  private static func _registerDetection(of queues: [DispatchQueue], key: DispatchSpecificKey<QueueReference>) {
    queues.forEach { $0.setSpecific(key: key, value: QueueReference(queue: $0)) }
  }

  private static func setupSystemQueuesDetection(key: DispatchSpecificKey<QueueReference>) {
    let queues: [DispatchQueue] = [
      .main,
      .global(qos: .background),
      .global(qos: .default),
      .global(qos: .unspecified),
      .global(qos: .userInitiated),
      .global(qos: .userInteractive),
      .global(qos: .utility)
    ]
    _registerDetection(of: queues, key: key)
  }
}

// MARK: public functionality

extension DispatchQueue {
  static func newDQ(label: String, qos: DispatchQoS) -> DispatchQueue {
    let q = DispatchQueue(label: label, qos: qos)
    registerDetection(of: q)
    return q
  }

  public static func registerDetection(of queue: DispatchQueue) {
    _registerDetection(of: [queue], key: key)
  }

  public static var currentQueueLabel: String? { current?.label }
  public static var current: DispatchQueue? { getSpecific(key: key)?.queue }

  /**
   USE THIS instead of `DispatchQueue.isExecutingIn(...))`: this will at least show an error msg.
   To work, the desired queue must first be registered with `registerDetection()` (or use `newDQ` to init)
   */
  public static func isExecutingIn(_ dq: DispatchQueue, logError: Bool = true) -> Bool {
    let isExpected = DispatchQueue.current == dq
    if !isExpected && logError {
      Logger.log.error("ERROR We are in the wrong queue: '\(DispatchQueue.currentQueueLabel ?? "nil")' (expected: \(dq.label))")
    }
    return isExpected
  }

  public static func isNotExecutingIn(_ dq: DispatchQueue, logError: Bool = true) -> Bool {
    let isExpected = DispatchQueue.current != dq
    if !isExpected && logError {
      Logger.log.error("ERROR We should not be executing in: '\(DispatchQueue.currentQueueLabel ?? "nil")'")
    }
    return isExpected
  }
}

extension NSViewController {
  /// Polyfill for MacOS 14.0's `loadViewIfNeeded()`.
  /// Load XIB if not already loaded. Prevents unboxing nils for `@IBOutlet` properties.
  func loadIfNeeded() {
    _ = self.view
  }
}

extension NSLayoutConstraint.Priority {
  static let minimum: NSLayoutConstraint.Priority = NSLayoutConstraint.Priority(rawValue: 1)
}

extension NSView {

  func suggestedRoundedCornerRadius() -> CGFloat {
    // Set corner radius to betwen 10 and 20
    return 10 + min(10, max(0, (frame.height - 400) * 0.01))
  }


  /// Recursive func which configures all views in the given subtree for smoother animation.
  ///
  /// By configuring each view to use a layer with the correct redraw policy, AppKit will use Core Animation to draw
  /// them, which uses a dedicated background thread instead of the main thread.
  /// For more explanation, see https://jwilling.com/blog/osx-animations/
  func configureSubtreeForCoreAnimation() {
    if self is NSButton || self is NSSlider || self is NSProgressIndicator {
      // these still need to be redrawn on every resize or they get very buggy
      return
    }
    if self is VideoView {
      // Don't mess with these
      return
    }
    self.layerContentsRedrawPolicy = .onSetNeedsDisplay
    for subview in self.subviews {
      subview.configureSubtreeForCoreAnimation()
    }
  }

  func addConstraintsToFillSuperview(v: Bool = true, h: Bool = true, priority: NSLayoutConstraint.Priority = .required) {
    guard let superview = superview else { return }

    if h {
      let leadingConstraint = leadingAnchor.constraint(equalTo: superview.leadingAnchor)
      leadingConstraint.priority = priority
      leadingConstraint.isActive = true
      let trailingConstraint = trailingAnchor.constraint(equalTo: superview.trailingAnchor)
      trailingConstraint.priority = priority
      trailingConstraint.isActive = true
    }
    if v {
      let topConstraint = topAnchor.constraint(equalTo: superview.topAnchor)
      topConstraint.priority = priority
      topConstraint.isActive = true
      let bottomConstraint = bottomAnchor.constraint(equalTo: superview.bottomAnchor)
      bottomConstraint.priority = priority
      bottomConstraint.isActive = true
    }
  }

  func addConstraintsToFillSuperview(top: CGFloat? = nil, bottom: CGFloat? = nil, leading: CGFloat? = nil, trailing: CGFloat? = nil) {
    guard let superview = superview else { return }

    if let top = top {
      let topConstraint = topAnchor.constraint(equalTo: superview.topAnchor, constant: top)
//      topConstraint.priority = priority
      topConstraint.isActive = true
    }
    if let leading = leading {
      let leadingConstraint = leadingAnchor.constraint(equalTo: superview.leadingAnchor, constant: leading)
//      leadingConstraint.priority = priority
      leadingConstraint.isActive = true
    }
    if let trailing = trailing {
      let trailingConstraint = superview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: trailing)
//      trailingConstraint.priority = priority
      trailingConstraint.isActive = true
    }
    if let bottom = bottom {
      let bottomConstraint = superview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: bottom)
//      bottomConstraint.priority = priority
      bottomConstraint.isActive = true
    }
  }

  func snapshotImage() -> CGImage? {
    guard let window = window, let screen = window.screen, let contentView = window.contentView else { return nil }
    if #available(macOS 10.15, *) {
      CGRequestScreenCaptureAccess()
    } else {
      // Fallback on earlier versions
    }
    let originRect = self.convert(self.bounds, to:contentView)
    var rect = originRect
    rect.origin.x += window.frame.origin.x
    rect.origin.y = 0
    rect.origin.y += screen.frame.size.height - window.frame.origin.y - window.frame.size.height
    rect.origin.y += window.frame.size.height - originRect.origin.y - originRect.size.height
    guard window.windowNumber > 0 else { return nil }
    return CGWindowListCreateImage(rect, .optionIncludingWindow, CGWindowID(window.windowNumber), CGWindowImageOption.bestResolution)
  }

  var iinaAppearance: NSAppearance {
    if #available(macOS 10.14, *) {
      var theme: Preference.Theme = Preference.enum(for: .themeMaterial)
      if theme == .system {
        if self.effectiveAppearance.isDark {
          // For some reason, "system" dark does not result in the same colors as "dark".
          // Just override it with "dark" to keep it consistent.
          theme = .dark
        } else {
          theme = .light
        }
      }
      if let themeAppearance = NSAppearance(iinaTheme: theme) {
        return themeAppearance
      }
    }
    return self.effectiveAppearance
  }

}
