//
//  Extensions.swift
//  iina
//
//  Created by lhc on 12/8/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa
import UniformTypeIdentifiers
import CryptoKit

infix operator %%

// MARK: Simple data types

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

  func isBetweenInclusive(_ lowerBound: Int, and upperBound: Int) -> Bool {
    return self >= lowerBound && self <= upperBound
  }

  var signString: String {
    self >= 0 ? "+" : "-"
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


extension Array {
  subscript(at index: Index) -> Element? {
    if indices.contains(index) {
      return self[index]
    } else {
      return nil
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


extension URL {
  var creationDate: Date? {
    (try? resourceValues(forKeys: [.creationDateKey]))?.creationDate
  }

  var isExistingDirectory: Bool {
    return (try? self.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
  }
}


extension Date {
  var timeIntervalToNow: TimeInterval {
    return Date().timeIntervalSince(self)
  }
}


extension NSColor {
  var mpvColorString: String {
    // Normalize to sRGB before extracting cmponents
    let rgb = self.usingColorSpace(.sRGB) ?? self

    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0

    rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

    return "\(red)/\(green)/\(blue)/\(alpha)"
  }

  convenience init?(mpvColorString: String) {
    if mpvColorString.first == "#" {
      // Hex format
      let hex = String(mpvColorString.dropFirst())

      let hasAlpha: Bool
      switch hex.count {
      case 6:
        // RRGGBB
        hasAlpha = false
      case 8:
        // AARRGGBB
        hasAlpha = true
      default:
        // Invalid format!
        return nil
      }

      var rgba: UInt64 = 0
      guard Scanner(string: hex).scanHexInt64(&rgba) else { return nil }

      let a = hasAlpha ? (CGFloat((rgba & 0xFF000000) >> 24) / 255.0) : 1.0
      let r = CGFloat((rgba & 0x00FF0000) >> 16) / 255.0
      let g = CGFloat((rgba & 0x0000FF00) >> 8) / 255.0
      let b = CGFloat(rgba & 0x000000FF) / 255.0
      self.init(red: r, green: g, blue: b, alpha: a)
    } else {
      // Assume slashes format
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
}


// MARK: - Basic geometery types

extension CGPoint {
  func constrained(to rect: NSRect) -> NSPoint {
    return NSMakePoint(x.clamped(to: rect.minX...rect.maxX), y.clamped(to: rect.minY...rect.maxY))
  }

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


extension CGSize: @retroactive CustomStringConvertible {
  public var description: String {
    return "\(width.logStr)⨉\(height.logStr)"
  }

  var widthInt: Int { Int(width) }
  var heightInt: Int { Int(height) }

  /// Returns a new `CGSize` which equals this `CGSize` but with both `width` &
  /// `height` rounded to the the nearest integer.
  func rounded() -> CGSize {
    return CGSize(width: width.rounded(), height: height.rounded())
  }

  var area: CGFloat {
    return width * height
  }

  /**
   Returns the aspect ratio (width divided by height) of the size.

   This property asserts that neither width nor height is zero, and then calculates the aspect ratio.

   - Returns: The aspect ratio of the size as a `CGFloat`.
   */
  var aspect: CGFloat {
    if width == 0 || height == 0 {
      Logger.log("Returning 1 for NSSize aspectRatio because width or height is 0", level: .warning)
      return 1
    }
    return width / height
  }

  var mpvAspect: CGFloat {
    return Aspect.mpvPrecision(of: aspect)
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
  func crop(withAspect targetAspect: CGFloat) -> NSSize {
    if aspect > targetAspect {  // self is wider, crop width, use same height
      return NSSize(width: round(height * targetAspect), height: height)
    } else {
      return NSSize(width: width, height: round(width / targetAspect))
    }
  }

  func getCropRect(withAspect aspect: CGFloat) -> NSRect {
    let croppedSize = crop(withAspect: aspect)
    let cropped = NSMakeRect(round((width - croppedSize.width) / 2),
                             round((height - croppedSize.height) / 2),
                             croppedSize.width,
                             croppedSize.height)
    return cropped
  }

  func getCropRect(withAspect aspect: Aspect) -> NSRect {
    let croppedSize = crop(withAspect: aspect.value)
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

  /// Finds the smallest box whose size matches the given `aspect` but with width >= `minWidth` & height >= `minHeight`.
  /// Note: `minWidth` & `minHeight` can be any positive integers. They do not need to match `aspect`.
  static func computeMinSize(withAspect aspect: CGFloat, minWidth: CGFloat, minHeight: CGFloat) -> CGSize {
    let sizeKeepingMinWidth = CGSize(width: minWidth, height: round(minWidth / aspect))
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

  func scalingWidth(to newWidth: CGFloat) -> CGSize {
    return CGSize(width: newWidth, height: (newWidth / aspect).rounded())
  }

  func scalingHeight(to newHeight: CGFloat) -> CGSize {
    return CGSize(width: (newHeight * aspect).rounded(), height: newHeight)
  }
}


extension CGRect: @retroactive CustomStringConvertible {
  public var description: String {
    return "(\(origin.x.logStr),\(origin.y.logStr)):\(size)"
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

  var xInt: Int { Int(origin.x) }
  var yInt: Int { Int(origin.y) }
  var widthInt: Int { Int(width) }
  var heightInt: Int { Int(height) }

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

  /// Alters origin if necessary to keep this rect entirely inside the larger rect.
  /// Does not alter the size of this rect. It is assumed that the developer has already done so.
  func constrainOrigin(in biggerRect: NSRect) -> NSRect {
    if size.width > biggerRect.width || size.height > biggerRect.height {
      /// This indicates a programmer error.
      /// If in debug environment, fail fast. Otherwise log and continue.
      assert(false, "Rect \(size) is not smaller than rect in which it is being constrained (\(biggerRect))")
      Logger.log.error("Rect \(size) is not smaller than rect in which it is being constrained (\(biggerRect))")
    }
    // new origin
    var newOrigin = origin
    if newOrigin.x < biggerRect.origin.x {
      newOrigin.x = biggerRect.origin.x
    }
    if newOrigin.y < biggerRect.origin.y {
      newOrigin.y = biggerRect.origin.y
    }
    if newOrigin.x + size.width > biggerRect.origin.x + biggerRect.width {
      newOrigin.x = biggerRect.origin.x + biggerRect.width - size.width
    }
    if newOrigin.y + size.height > biggerRect.origin.y + biggerRect.height {
      newOrigin.y = biggerRect.origin.y + biggerRect.height - size.height
    }
    return NSRect(origin: newOrigin, size: size)
  }
}


// MARK: - Floating point types

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
    let scaledUpRounded = scaledUp.rounded(.toNearestOrAwayFromZero)
    let finalVal = scaledUpRounded / 1e1
    return finalVal
  }

  /// Returns this value rounded half down to an integral value.
  ///
  /// For example 0.5 will be rounded to 0.0, 0.51 will be rounded to 1.0.
  /// - Note: This method is needed because at this time the Swift
  ///     [rounded](https://developer.apple.com/documentation/swift/double/rounded(_:)) method does not
  ///     support a [rounding rule](https://developer.apple.com/documentation/swift/floatingpointroundingrule)
  ///     for [rounding half down](https://en.wikipedia.org/wiki/Rounding#Rounding_half_down).
  /// - Returns: The integral value found by rounding this value.
  func roundedHalfDown() -> Double {
    let floor = floor(self)
    return self <= floor + 0.5 ? floor : ceil(self)
  }

  func roundedTo2() -> Double {
    let scaledUp = self * 1e2
    let scaledUpRounded = scaledUp.rounded(.toNearestOrAwayFromZero)
    let finalVal = scaledUpRounded / 1e2
    return finalVal
  }

  func roundedTo3() -> Double {
    let scaledUp = self * 1e3
    let scaledUpRounded = scaledUp.rounded(.toNearestOrAwayFromZero)
    let finalVal = scaledUpRounded / 1e3
    return finalVal
  }

  func roundedTo5() -> Double {
    let scaledUp = self * 1e5
    let scaledUpRounded = scaledUp.rounded(.toNearestOrAwayFromZero)
    let finalVal = scaledUpRounded / 1e5
    return finalVal
  }

  func roundedTo6() -> Double {
    let scaledUp = self * 1e6
    let scaledUpRounded = scaledUp.rounded(.toNearestOrAwayFromZero)
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
  /// let badStr = "Value is \(num)"                              // badStr will *always* be "Value is 12.34"
  /// let goodStr = "Value is \(num.groupedStringUpTo6Decimals)"  // goodStr will be "Value is 12,34"
  /// ```
  ///
  /// Currently the output string is limited to 6 digits after the decimal. This matches the precision used by mpv's APIs.
  var groupedStringUpTo6Decimals: String {
    return fmtDecimalGroupingMaxFractionDigits6.string(from: self as NSNumber) ?? "NaN"
  }

  var logStr: String {
    return fmtDecimalNoGroupingMaxFractionDigits15.string(from: self as NSNumber) ?? "NaN"
  }

  /// Returns a "normalized" number string for the exclusive purpose of comparing two mpv aspect ratios while avoiding precision errors.
  /// Not pretty to put this here, but need to make this searchable & don't have time for a larger refactor.
  /// Addendum: we now assume 6 digits of precision.
  var mpvAspectString: String {
    return fmtStdDecimal.roundHalfDown_exactFracDigits[6].string(for: self)!
  }
}

extension CGFloat {
  var groupedStringUpTo6Decimals: String {
    return Double(self).groupedStringUpTo6Decimals
  }

  func roundedTo6() -> Double {
    let scaledUp = self * 1e6
    let scaledUpRounded = scaledUp.rounded(.toNearestOrAwayFromZero)
    let finalVal = scaledUpRounded / 1e6
    return finalVal
  }

  func roundedTo2() -> Double {
    let scaledUp = self * 1e2
    let scaledUpRounded = scaledUp.rounded(.toNearestOrAwayFromZero)
    let finalVal = scaledUpRounded / 1e2
    return finalVal
  }

  /// Formats the decimal for logging. Omits trailing zeroes & grouping separator.
  var logStr: String {
    return Double(self).logStr
  }

  var isInteger: Bool {
    return CGFloat(Int(self)) == self
  }

  func isBetweenInclusive(_ lowerBound: CGFloat, and upperBound: CGFloat) -> Bool {
    return self >= lowerBound && self <= upperBound
  }

  static func degToRad(_ degrees: CGFloat) -> CGFloat {
    return degrees * CGFloat.pi / 180
  }
}

/// All the formatters here use "standardized" punctuation across locales. The formatted numbers:
/// - Always use period (".") for the decimal separator.
/// - Never use any punctuation to group large numbers.
struct StandardizedDecimalFormatters {
  /// Formats a number up to N digits after the decimal, truncated.
  let truncate_maxFracDigits: [NumberFormatter]
  /// Formats a number to exactly N digits after the decimal, truncated.
  let truncate_exactFracDigits: [NumberFormatter]

  /// Formats a number up to N digits after the decimal, rounded half down.
  let roundHalfDown_maxFracDigits: [NumberFormatter]

  /// Formats a number to exactly N digits after the decimal, rounded half down.
  let roundHalfDown_exactFracDigits: [NumberFormatter]

  init() {
    let decimalSeparator = "."
    var truncate_maxFracDigits: [NumberFormatter] = []
    for i in 0...6 {
      let fmt = NumberFormatter()
      fmt.decimalSeparator = decimalSeparator
      fmt.numberStyle = .decimal
      fmt.maximumFractionDigits = i
      fmt.usesGroupingSeparator = false
      fmt.roundingMode = .floor
      truncate_maxFracDigits.append(fmt)
    }
    self.truncate_maxFracDigits = truncate_maxFracDigits

    var truncate_exactFracDigits: [NumberFormatter] = []
    for i in 0...6 {
      let fmt = NumberFormatter()
      fmt.decimalSeparator = decimalSeparator
      fmt.numberStyle = .decimal
      fmt.minimumFractionDigits = i
      fmt.maximumFractionDigits = i
      fmt.usesGroupingSeparator = false
      fmt.roundingMode = .floor
      truncate_exactFracDigits.append(fmt)
    }
    self.truncate_exactFracDigits = truncate_exactFracDigits

    var roundHalfDown_exactFracDigits: [NumberFormatter] = []
    for i in 0...6 {
      let fmt = NumberFormatter()
      fmt.decimalSeparator = decimalSeparator
      fmt.numberStyle = .decimal
      fmt.minimumFractionDigits = i
      fmt.maximumFractionDigits = i
      fmt.usesGroupingSeparator = false
      fmt.roundingMode = .halfDown
      roundHalfDown_exactFracDigits.append(fmt)
    }
    self.roundHalfDown_exactFracDigits = roundHalfDown_exactFracDigits

    var roundHalfDown_maxFracDigits: [NumberFormatter] = []
    for i in 0...6 {
      let fmt = NumberFormatter()
      fmt.decimalSeparator = decimalSeparator
      fmt.numberStyle = .decimal
      fmt.maximumFractionDigits = i
      fmt.usesGroupingSeparator = false
      fmt.roundingMode = .halfDown
      roundHalfDown_maxFracDigits.append(fmt)
    }
    self.roundHalfDown_maxFracDigits = roundHalfDown_maxFracDigits
  }
}

fileprivate let fmtStdDecimal = StandardizedDecimalFormatters()

/// Formatter for `Double`, `CGFloat`.
/// - Displays up to 6 digits after the decimal before rounding.
/// - Omits trailing zeroes.
/// - Uses grouping separator (e.g. comma) for large numbers.
fileprivate let fmtDecimalGroupingMaxFractionDigits6: NumberFormatter = {
  let fmt = NumberFormatter()
  fmt.numberStyle = .decimal
  fmt.usesGroupingSeparator = true
  fmt.minimumFractionDigits = 0
  fmt.maximumFractionDigits = 6
  fmt.usesSignificantDigits = false
  return fmt
}()

/// Formatter for `Double`, `CGFloat`. Similar to `fmtDecimalGroupingMaxFractionDigits6` but no gropuing separator.
/// - Displays up to 15 digits after the decimal before rounding.
/// - Omits trailing zeroes.
/// - Does not use grouping separator (e.g. comma) for large numbers.
fileprivate let fmtDecimalNoGroupingMaxFractionDigits15: NumberFormatter = {
  let fmt = NumberFormatter()
  fmt.numberStyle = .decimal
  fmt.usesGroupingSeparator = false
  fmt.maximumSignificantDigits = 25
  fmt.minimumFractionDigits = 0
  fmt.maximumFractionDigits = 15
  fmt.usesSignificantDigits = false
  return fmt
}()

extension FloatingPoint {
  // TODO: replace with "bounded"
  func clamped(to range: Range<Self>) -> Self {
    if self < range.lowerBound {
      return range.lowerBound
    } else if self >= range.upperBound {
      return range.upperBound.nextDown
    } else {
      return self
    }
  }

  func clamped(to minRange: PartialRangeFrom<Self>) -> Self {
    return max(self, minRange.lowerBound)
  }

#if DEBUG
  /// Formats as String, rounding the number to 2 digits after the decimal.
  /// Always displays 2 digits after the decimal.
  var string2FractionDigits: String {
    return fmtStdDecimal.truncate_exactFracDigits[2].string(for: self)!
  }
#endif

  /// Formats as String, truncating the number to 2 digits after the decimal
  var stringTrunc2f: String {
    return fmtStdDecimal.truncate_maxFracDigits[2].string(for: self)!
  }

  /// Formats as String, truncating the number to 3 digits after the decimal
  var stringTrunc3f: String {
    return fmtStdDecimal.truncate_maxFracDigits[3].string(for: self)!
  }

  /// Formats as String, truncating the number to 5 digits after the decimal
  var stringTrunc5f: String {
    return fmtStdDecimal.truncate_maxFracDigits[5].string(for: self)!
  }

  /// Formats as String, truncating the number to 6 digits after the decimal
  var stringTrunc6f: String {
    return fmtStdDecimal.truncate_maxFracDigits[6].string(for: self)!
  }

  /// Formats as String, rounding the number to 2 digits after the decimal
  var stringMaxFrac2: String {
    return fmtStdDecimal.roundHalfDown_maxFracDigits[2].string(for: self)!
  }

  /// Formats as String, rounding the number to 4 digits after the decimal
  var stringMaxFrac4: String {
    return fmtStdDecimal.roundHalfDown_maxFracDigits[4].string(for: self)!
  }

  /// Formats as String, rounding the number to 6 digits after the decimal
  var stringMaxFrac6: String {
    return fmtStdDecimal.roundHalfDown_maxFracDigits[6].string(for: self)!
  }
}

// MARK: - Text types

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


extension String {
  /// Allows an optional Int to be printed more easily (e.g., by using `String(optionalValue)`).
  init(_ optionalInt: Int?) {
    if let optionalInt {
      self.init(optionalInt)
    } else {
      self.init("nil")
    }
  }

  /// Allows an optional Double to be printed more easily (e.g., by using `String(optionalValue)`).
  init(_ optionalDouble: Double?) {
    if let optionalDouble {
      self.init(optionalDouble)
    } else {
      self.init("nil")
    }
  }

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

  func droppingPrefix(_ prefix: String) -> String {
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


extension RangeExpression where Bound == String.Index  {
  func nsRange<S: StringProtocol>(in string: S) -> NSRange { .init(self, in: string) }
}

extension IndexSet {
  func toArray() -> [Int] {
    map{$0}
  }
}

// MARK: - Data

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


// MARK: - Drawing


extension CALayer {

  /// Get `NSImage` representation of the layer.
  ///
  /// - Returns: `NSImage` of the layer.
  /// Original source: https://stackoverflow.com/a/41387514/1347529
  func image() -> NSImage {
    let width = Int(bounds.width * contentsScale)
    let height = Int(bounds.height * contentsScale)
    let imageRepresentation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    imageRepresentation.size = bounds.size

    let context = NSGraphicsContext(bitmapImageRep: imageRepresentation)!

    render(in: context.cgContext)

    return NSImage(cgImage: imageRepresentation.cgImage!, size: bounds.size)
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

  // https://github.com/venj/Cocoa-blog-code/blob/master/Round%20Corner%20Image/Round%20Corner%20Image/NSImage%2BRoundCorner.m
  func roundCorners(cornerWidth: CGFloat, cornerHeight: CGFloat) -> CGImage {
    let size = CGSize(width: width, height: height)
    let rect = CGRect(origin: NSPoint.zero, size: size)
    if let ctx = CGContext(data: nil,
                           width: Int(size.width),
                           height: Int(size.height),
                           bitsPerComponent: 8,
                           bytesPerRow: 4 * Int(size.width),
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
      ctx.beginPath()
      ctx.addPath(CGPath(roundedRect: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight, transform: nil))
      ctx.closePath()
      ctx.clip()
      ctx.draw(self, in: rect)

      if let composedImage = ctx.makeImage() {
        return composedImage
      }
    }
    return self
  }

  /// This uses CoreGraphics calls, which in tests was ~5x faster than using `NSAffineTransform` on `NSImage` directly
  func rotated(degrees: Int) -> CGImage {
    let imgRect = CGRect(origin: CGPointZero, size: CGSize(width: width, height: height))

    let angleRadians = degToRad(CGFloat(degrees))
    let imgRotateTransform = rotateTransformRectAroundCenter(rect: imgRect, angle: angleRadians)
    let rotatedImgFrame = CGRectApplyAffineTransform(imgRect, imgRotateTransform)


    let drawingCalls: (CGContext) -> Void = { [self] cgContext in
      let rotateContext = rotateTransformRectAroundCenter(rect: rotatedImgFrame, angle: angleRadians)
      cgContext.concatenate(rotateContext)
      cgContext.draw(self, in: imgRect)
    }
    return CGImage.buildBitmapImage(width: rotatedImgFrame.size.widthInt, height: rotatedImgFrame.size.heightInt, drawingCalls)
  }

  private func degToRad(_ degrees: CGFloat) -> CGFloat {
    return degrees * CGFloat.pi / 180
  }

  /// `cornerRadius`: if greater than 0, round the corners by this radius
  func resized(newWidth: Int, newHeight: Int, cornerRadius: CGFloat = 0) -> CGImage {
    guard newWidth != width || newHeight != height else {
      return self
    }

    guard newWidth > 0, newHeight > 0 else {
      Logger.fatal("NSImage.resized: invalid width (\(newWidth)) or height (\(newHeight)) - both must be greater than 0")
    }

    // Use raw CoreGraphics calls instead of their NS equivalents. They are > 10x faster, and only downside is that the image's
    // dimensions must be integer values instead of decimals.
    let newImage = CGImage.buildBitmapImage(width: Int(newWidth), height: Int(newHeight)) { cgContext in
      let outputRect = CGRect(x: 0, y: 0, width: newWidth, height: newHeight)
      if cornerRadius > 0.0 {
        cgContext.beginPath()
        cgContext.addPath(CGPath(roundedRect: outputRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        cgContext.closePath()
        cgContext.clip()
      }
      cgContext.draw(self, in: outputRect)
    }

    return newImage
  }

  func cropped(normalizedCropRect nRect: CGRect) -> CGImage {
    // Scale cropRect to handle images larger than shown-on-screen size
    let w = Double(width)
    let h = Double(height)
    let cropRect = CGRect(x: nRect.origin.x * w,
                          y: nRect.origin.y * h,
                          width: nRect.size.width * w,
                          height: nRect.size.height * h)

    if let croppedImage: CGImage = cropping(to:cropRect) {
      return croppedImage
    }
    return self
  }


  func toNSImage() -> NSImage {
    NSImage(cgImage: self, size: size())
  }

  func size() -> CGSize {
    return CGSize(width: width, height: height)
  }

  /// Builds a bitmap image efficiently using CoreGraphics APIs.
  ///
  /// If it's found useful for any more situations, should put in its own class
  static func buildBitmapImage(width: Int, height: Int, _ drawingCalls: (CGContext) -> Void) -> CGImage {
    guard let compositeImageRep = CGImage.makeNewImgRep(width: width, height: height) else {
      Logger.fatal("DrawImageInBitmapImageContext: Failed to create NSBitmapImageRep!")
    }

    guard let context = NSGraphicsContext(bitmapImageRep: compositeImageRep) else {
      Logger.fatal("DrawImageInBitmapImageContext: Failed to create NSGraphicsContext!")
    }

    context.cgContext.interpolationQuality = .high
    drawingCalls(context.cgContext)

    return compositeImageRep.cgImage!
  }

  /// Creates RGB image with alpha channel
  static func makeNewImgRep(width: Int, height: Int) -> NSBitmapImageRep? {
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

  static func buildCompositeBarImg(barImg: CGImage, highlightOverlayImg: CGImage,
                                   _ drawingCalls: ((CGContext) -> Void)? = nil) -> CGImage {
    let compositeImg = CGImage.buildBitmapImage(width: barImg.width, height: barImg.height) { ctx in
      let bounds = CGRect(origin: .zero, size: barImg.size())

      ctx.setBlendMode(.normal)
      ctx.draw(barImg, in: bounds)

      ctx.setBlendMode(.overlay)
      ctx.draw(highlightOverlayImg, in: bounds)

      if let drawingCalls {
        ctx.setBlendMode(.normal)
        drawingCalls(ctx)
      }
    }
    return compositeImg
  }


  /// returns the transform equivalent of rotating a rect around its center
  private func rotateTransformRectAroundCenter(rect:CGRect, angle:CGFloat) -> CGAffineTransform {
    let t = CGAffineTransformConcat(
      CGAffineTransformMakeTranslation(-rect.origin.x-rect.size.width*0.5, -rect.origin.y-rect.size.height*0.5),
      CGAffineTransformMakeRotation(angle)
    )
    return CGAffineTransformConcat(t, CGAffineTransformMakeTranslation(rect.size.width*0.5, rect.size.height*0.5))
  }

}

extension NSImage {
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

  static func from(_ cgi: CGImage) -> NSImage {
    return NSImage(cgImage: cgi, size: NSSize(width: cgi.width, height: cgi.height))
  }

  var cgImage: CGImage? {
    var rect = CGRect.init(origin: .zero, size: self.size)
    return self.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }

  /// Derives a new width from the given height using this image's existing aspect.
  func deriveWidth(fromHeight height: CGFloat) -> CGFloat {
    return round(height * aspect)
  }

  var aspect: CGFloat {
    if size.width > 0 && size.height > 0 {
      let imageAspect = size.width / size.height
      return imageAspect
    }
    let cgImage = self.cgImage
    let imageAspect = CGFloat(cgImage!.width) / CGFloat(cgImage!.height)
    return imageAspect
  }

  func clipToCircle() -> NSImage {
    return roundCorners(cornerWidth: size.width * 0.5, cornerHeight: size.height * 0.5)
  }

  func roundCorners(withRadius radius: CGFloat) -> NSImage {
    return roundCorners(cornerWidth: radius, cornerHeight: radius)
  }

  func roundCorners(cornerWidth: CGFloat, cornerHeight: CGFloat) -> NSImage {
    if let cgImageNew = cgImage?.roundCorners(cornerWidth: cornerWidth, cornerHeight: cornerHeight) {
      return NSImage(cgImage: cgImageNew, size: self.size)
    }
    return self
  }

  /// This uses CoreGraphics calls, which in tests was ~5x faster than using `NSAffineTransform` on `NSImage` directly
  func rotated(degrees: Int) -> NSImage {
    if let cgImageNew = cgImage?.rotated(degrees: degrees) {
      return NSImage(cgImage: cgImageNew, size: size)
    }
    return self
  }

  func cropped(normalizedCropRect nRect: NSRect) -> NSImage {
    let croppedImage = cgImage!.cropped(normalizedCropRect: nRect)
    return NSImage(cgImage: croppedImage, size: NSSize(width: croppedImage.width, height: croppedImage.height))
  }

  /// `cornerRadius`: if greater than 0, round the corners by this radius
  func resized(newWidth: Int, newHeight: Int, cornerRadius: CGFloat = 0) -> NSImage {
    if let cgImageNew = cgImage?.resized(newWidth: newWidth, newHeight: newHeight, cornerRadius: cornerRadius) {
      return NSImage(cgImage: cgImageNew, size: NSSize(width: newWidth, height: newHeight))
    }
    return self
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


// MARK: - Menus

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

extension NSMenuItem {

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


// MARK: - AppKit - Various

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


extension NSSlider {

  /// Range of values the slider is configured to return.
  var range: ClosedRange<Double> { minValue...maxValue }

  /// Span of the range of values the slider is configured to return.
  var span: Double { maxValue - minValue }

  var progressRatio: Double {
    (doubleValue - minValue) / span
  }

  /**
   Returns the position of the knob's center point along the slider's track in window coordinates.

   This method calculates the horizontal position of the center of the slider's knob based on the slider's current value (`doubleValue`), the minimum and maximum values, and the slider's dimensions. It can be useful for custom drawing, animations, or hit detection related to the knob's position.

   - Returns: A `CGFloat` representing the x-coordinate of the knob's center along the slider's width.

   - Important: Ensure that the slider's `maxValue` is greater than `minValue`. An assertion is used to validate this.

   Example usage:
   ```swift
   let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
   let knobPosition = slider.centerOfKnobInWindowCoordX()
   print("The knob is positioned at x-coordinate: \(knobPosition)")
   ```
   */
  func centerOfKnobInWindowCoordX() -> CGFloat {
    let knobCenterInSliderCoordX = centerOfKnobInSliderCoordX()
    let knobCenterInWindowCoordX = self.convert(NSPoint(x: knobCenterInSliderCoordX, y: 0), to: nil).x
    return knobCenterInWindowCoordX
  }

  /// Returns the position of the knob's center point along the slider's track.
  /// See also `centerOfKnobInWindowX()`.
  func centerOfKnobInSliderCoordX() -> CGFloat {
    // The knob must always be within the bounds of the slider. With respect to the center of the knob,
    // this means that there is a space of (knobThickness / 2) at both sides where the center can never go.
    let knobCenterMinX = knobThickness / 2
    let knobRangeWidth = frame.width - knobThickness
    assert(maxValue > minValue)
    let knobPosX = knobCenterMinX + knobRangeWidth * CGFloat((doubleValue - minValue) / span)
    assert(knobPosX.clamped(to: knobCenterMinX...(knobCenterMinX + knobRangeWidth)) == knobPosX,
           "Invalid calculated centerOfKnobInSliderCoordX for slider: \(knobPosX)")
    return knobPosX
  }

  func computeProgressRatioGiven(centerOfKnobInSliderCoordX: CGFloat) -> CGFloat {
    let knobCenterMinX = knobThickness / 2
    let knobRangeWidth = frame.width - knobThickness
    let knobCenterMaxX = knobCenterMinX + knobRangeWidth
    // It's valid for the given X value to be in the (knobThickness / 2) regions near minX & maxX where the
    // knob can't go. This can happen if the user clicks near in this area. Just check & clamp to valid values.
    let centerOfKnobCorrected = centerOfKnobInSliderCoordX.clamped(to: knobCenterMinX...knobCenterMaxX)
    let ratio = Double((centerOfKnobCorrected - knobCenterMinX) / knobRangeWidth)
    assert(ratio.clamped(to: 0...1) == ratio, "Invalid calculated ratio for slider: \(ratio)")
    return ratio
  }

  func computeValueGiven(centerOfKnobInSliderCoordX: CGFloat) -> CGFloat {
    let ratio = computeProgressRatioGiven(centerOfKnobInSliderCoordX: centerOfKnobInSliderCoordX)
    let val = (ratio * span) + minValue
    assert(val.clamped(to: minValue...maxValue) == val,
           "Invalid calculated value for slider: \(val)")
    return val
  }

  func computeCenterOfKnobInSliderCoordXGiven(pointInWindow: NSPoint) -> CGFloat {
    let xOffsetInSlider = convert(pointInWindow, from: nil).x
    let knobCenterMinX = knobThickness / 2
    let knobRangeWidth = frame.width - knobThickness
    let knobCenterMaxX = knobCenterMinX + knobRangeWidth
    return xOffsetInSlider.clamped(to: knobCenterMinX...knobCenterMaxX)
  }
}


// For scrolling
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


extension NSSegmentedControl {
  @discardableResult
  func selectSegment(withLabel label: String) -> Bool {
    for i in 0..<segmentCount {
      let iLabel = self.label(forSegment: i)
      if iLabel == label {
        self.selectedSegment = i
        return true
      }
    }
    Logger.log.verbose("Could not find segment with label \(label.quoted). Setting selection to -1")
    self.selectedSegment = -1
    return false
  }
}



extension NSBox {
  static func horizontalLine() -> NSBox {
    let box = NSBox(frame: NSRect(origin: .zero, size: NSSize(width: 100, height: 1)))
    box.boxType = .separator
    return box
  }
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
    Logger.log.verbose("ViewRect=\(viewRect) → point=(\(x), \(y)) → owner screen is \(ownerScreenID?.debugDescription ?? "nil")")
    return ownerScreenID
  }

  static func getOwnerOrDefaultScreenID(forViewRect viewRect: NSRect, fallbackScreenID: String) -> String {
    if let ownerScreenID = getOwnerScreenID(forViewRect: viewRect) {
      return ownerScreenID
    }
    if screens.contains(where: {$0.screenID == fallbackScreenID}) {
      return fallbackScreenID
    }
    return screens[0].screenID
  }

  static func getOwnerOrDefaultScreenID(forPoint point: NSPoint, fallbackScreenID: String) -> String {
    if let ownerScreenID = getOwnerScreenID(forPoint: point) {
      return ownerScreenID
    }
    if screens.contains(where: {$0.screenID == fallbackScreenID}) {
      return fallbackScreenID
    }
    return screens[0].screenID
  }

  static func forScreenID(_ screenID: String) -> NSScreen? {
    let splitted = screenID.split(separator: ":")
    guard splitted.count > 0, let displayID = UInt32(splitted[0]) else { return nil }
    if let screen = forDisplayID(displayID) {
      // TODO: better matching logic. There is no guarantee that displayId will be consistent for the same screen across launches
      if screen.screenID != screenID {
        Logger.log.error("NSScreen with displayID \(displayID) is not exact match! Search target was \(screenID.quoted), but found \(screen.screenID.quoted). It is possible the wrong screen is being returned")
      }
      return screen
    }
    Logger.log.error("Failed to find an NSScreen for screenID \(screenID.quoted); returning nil")
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

    Logger.log.debug("Failed to find an NSScreen for screenID \(screenID.quoted); returning default screen")
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

  var cameraHeightToFrameHeightRatio: CGFloat {
    if #available(macOS 12.0, *) {
      return safeAreaInsets.top / frame.height
    } else {
      return 0
    }
  }

  /// • `nonCameraHeightToFrameHeightRatio >= cameraHeightToFrameHeightRatio` (or should be).
  /// • `nonCameraHeightToFrameHeightRatio + cameraHeightToFrameHeightRatio == 1`.
  var nonCameraHeightToFrameHeightRatio: CGFloat {
    if #available(macOS 12.0, *) {
      return 1 - (safeAreaInsets.top / frame.height)
    } else {
      return 1
    }
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
      Logger.log.warn("Failed to get CGDisplayModes for displayID \(displayId)! Returning nil")
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

  /// Log the given `NSScreen` object.
  ///
  /// Due to issues with multiple monitors and how the screen to use for a window is selected detailed logging has been added in this
  /// area in case additional problems are encountered in the future.
  /// - parameter label: Label to include in the log message.
  /// - parameter screen: The `NSScreen` object to log.
  static func log(_ label: String, _ screen: NSScreen?, subsystem: any Logger.Subsystem = Logger.general) {
    guard let screen = screen else {
      Logger.log("\(label): nil", level: .warning, subsystem: subsystem)
      return
    }
    var message = "\(label), \(screen.localizedName)"
    if screen == NSScreen.main {
      message += " (main screen)"
    }
    let screenNumberKey = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
    if let displayId = screen.deviceDescription[screenNumberKey] as? CGDirectDisplayID {
      message += ", on display \(displayId)"
    }
    message += ":"
    message += "\n  Frame: \(screen.frame), visible \(screen.visibleFrame)"
    message += "\n  \(formEDRMessage(screen))"
    Logger.log(message, subsystem: subsystem)
  }

  /// Log EDR aspects of the given `NSScreen` object.
  /// - parameter screen: The `NSScreen` object to log EDR aspects of.
  static func logEDR(_ label: String, _ screen: NSScreen?, subsystem: any Logger.Subsystem = Logger.general) {
    guard let screen = screen else {
      Logger.log("\(label): nil", level: .warning, subsystem: subsystem)
      return
    }
    var message = "\(label), \(screen.localizedName)"
    if screen == NSScreen.main {
      message += " (main screen)"
    }
    let screenNumberKey = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
    if let displayId = screen.deviceDescription[screenNumberKey] as? CGDirectDisplayID {
      message += ", on display \(displayId)"
    }
    message += ":"
    message += "\n  Frame: \(screen.frame), visible \(screen.visibleFrame)"
    message += "\n  \(formEDRMessage(screen))"
    Logger.log(message, subsystem: subsystem)
  }

  /// Return a string describing EDR aspects of the given screen.
  /// - Parameter screen: The `NSScreen` object to form EDR aspects of.
  /// - Returns: A string with EDR related details of the given screen for use in a log message.
  private static func formEDRMessage(_ screen: NSScreen) -> String {
    let maxPossibleEDR = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
    let canEnableEDR = maxPossibleEDR > 1.0
    return """
      EDR: \(canEnableEDR ? "Supported" : "Not supported"), max potential \(maxPossibleEDR), \
      max current \(screen.maximumExtendedDynamicRangeColorComponentValue)
      """
  }
}

extension NSWindow {

  /// Provides a unique window ID for reference by `UIState`. Use this instead of `frameAutosaveName` (although in most cases
  /// it will be the same string).
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
    for winCon in AppDelegate.shared.playerWindows {
      if winCon.window != self, winCon.currentLayout.isFullScreen {
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
    Logger.log.verbose("Window is the only window currently open: \(savedStateName.quoted)")
    return true
  }

  var isOpen: Bool {
    if let pwc = self.windowController as? PlayerWindowController, pwc.isOpen {
      return true
    } else if self.isVisible || self.isMiniaturized {
      return true
    }
    return false
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
    if UIState.shared.isRestoreEnabled {
      if let offsetY: Double = Preference.value(for: key) as? Double {
        Logger.log.verbose("Restoring vertical scroll to: \(offsetY)")
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
        UIState.shared.set(scrollOffsetY, for: key)
      }
    }
    return observer
  }

  // Combines the previous 2 functions into one
  func restoreAndObserveVerticalScroll(key: Preference.Key, defaultScrollAction: () -> Void) -> NSObjectProtocol {
    if !restoreVerticalScroll(key: key) {
      Logger.log.verbose("Did not restore scroll (key: \(key.rawValue.quoted), isRestoreEnabled: \(UIState.shared.isRestoreEnabled)); will use default scroll action")
      defaultScrollAction()
    }
    return addVerticalScrollObserver(key: key)
  }
}

extension NSViewController {
  /// Polyfill for MacOS 14.0's `loadViewIfNeeded()`.
  /// Load XIB if not already loaded. Prevents unboxing nils for `@IBOutlet` properties.
  func loadIfNeeded() {
    _ = self.view
  }
}

extension NSLayoutConstraint {
  var priorityInt: Int {
    get {
      return Int(priority.rawValue)
    }
    set {
      priority = .init(rawValue: Float(newValue))
    }
  }
}

extension NSLayoutConstraint.Priority {
  static let minimum: NSLayoutConstraint.Priority = NSLayoutConstraint.Priority(rawValue: 1)
}

/// `NSShadow.shadowColor` is not dark enough. Use pure black.
fileprivate let defaultShadowColor: NSColor = .black
fileprivate let iconDefaultShadowBlurRadiusConstant: CGFloat = 0.5
extension NSControl {

  func addShadow(blurRadiusMultiplier: CGFloat = 0.0, blurRadiusConstant: CGFloat = iconDefaultShadowBlurRadiusConstant,
                 shadowOffsetMultiplier: CGFloat = 0.0,
                 xOffsetConstant: CGFloat = 0.0, yOffsetConstant: CGFloat = 0.0,
                 color: NSColor = defaultShadowColor) {
    let controlHeight = fittingSize.height
    let shadow = NSShadow()
    // Amount of blur (in pixels) applied to the shadow.
    let blurRadius = controlHeight * blurRadiusMultiplier + blurRadiusConstant
    shadow.shadowBlurRadius = blurRadius
    shadow.shadowColor = color
    // the distance from the text the shadow is dropped (+X = to the right; -Y = below the text):
    shadow.shadowOffset = NSSize(width: controlHeight * shadowOffsetMultiplier + xOffsetConstant, height: controlHeight * shadowOffsetMultiplier + yOffsetConstant)
    self.shadow = shadow
  }

}

extension NSSize {
  func canFitInside(_ enclosingSize: NSSize) -> Bool {
    width <= enclosingSize.width && height <= enclosingSize.height
  }
}

extension NSView {
  var pwc: PlayerWindowController? {
    window?.windowController as? PlayerWindowController
  }

  var associatedPlayer: PlayerCore? {
    return pwc?.player
  }

  /// Obviously, make sure this view has been added to the window first.
  var frameInWindowCoords: NSRect {
    return convert(bounds, to: nil)
  }

  var idString: String {
    get {
      return self.identifier?.rawValue ?? "<unnamed>"
    }
    set {
      self.identifier = .init(newValue)
#if DEBUG
      // Sometimes these are shown in the View Debugger
      self.setAccessibilityTitle(newValue)
      self.setAccessibilityIdentifier(newValue)
#endif
    }
  }

  func roundCorners(withRadius cornerRadius: CGFloat) {
    wantsLayer = true
    layer?.cornerRadius = cornerRadius
  }

  func roundCorners() {
    wantsLayer = true
    let radius = suggestedRoundedCornerRadius()
    roundCorners(withRadius: radius)
  }

  func suggestedRoundedCornerRadius() -> CGFloat {
    // Set corner radius to betwen 10 and 20
    return 10 + min(10, max(0, (frame.height - 400) * 0.01))
  }

  func isInsideViewFrame(pointInWindow: CGPoint) -> Bool {
    let pointInView = convert(pointInWindow, from: nil)
    return isMousePoint(pointInView, in: bounds)
  }

  func hasSharedAncestor(with otherView: NSView) -> Bool {
    return ancestorShared(with: otherView) != nil
  }

  func containsAllSubviews(_ views: [NSView]) -> Bool {
    for view in views {
      if !subviews.contains(view) {
        return false
      }
    }
    return true
  }

  func containsSubview(_ view: NSView) -> Bool {
    subviews.contains(view)
  }

  func setContentHugging(h: Float, v: Float) {
    setContentHuggingPriority(.init(h), for: .horizontal)
    setContentHuggingPriority(.init(v), for: .vertical)
  }

  func setCCResistance(h: Float, v: Float) {
    setContentCompressionResistancePriority(.init(h), for: .horizontal)
    setContentCompressionResistancePriority(.init(v), for: .vertical)
  }

  /// Recursive func which configures all views in the given subtree for smoother animation.
  ///
  /// By configuring each view to use a layer with the correct redraw policy, AppKit will use Core Animation to draw
  /// them, which uses a dedicated background thread instead of the main thread.
  /// For more explanation, see https://jwilling.com/blog/osx-animations/
  func configureSubtreeForCoreAnimation() {
    // Certain controls still need to be redrawn on every resize or they get very buggy
    if (self as? NSButton != nil) || (self as? NSSlider != nil) || (self as? NSProgressIndicator != nil) {
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

#if DEBUG
  func configureSubtreeForClipping() {
    self.clipsToBounds = true
    for subview in self.subviews {
      subview.configureSubtreeForClipping()
    }
  }
#endif

  func removeAllSubviews() {
    for subview in subviews {
      subview.removeFromSuperview()
    }
  }

  func addAllConstraintsToFillSuperview() {
    addConstraintsToFillSuperview(top: 0, bottom: 0, leading: 0, trailing: 0)
  }

  func addConstraintsToFillSuperview(top: CGFloat? = nil, _ topPriority: NSLayoutConstraint.Priority? = nil,
                                     bottom: CGFloat? = nil, _ btmPriority: NSLayoutConstraint.Priority? = nil,
                                     leading: CGFloat? = nil, _ leadPriority: NSLayoutConstraint.Priority? = nil,
                                     trailing: CGFloat? = nil, _ trailPriority: NSLayoutConstraint.Priority? = nil) {
    guard let superview else { return }
    assert(!(top == nil && bottom == nil && leading == nil && trailing == nil),
           "addConstraintsToFillSuperview should never be called with no args! Try addAllConstraintsToFillSuperview instead")

    let idPrefix: String?
    if idString.isEmpty {
      idPrefix = nil
    } else {
      let superviewID = superview.idString.isEmpty ? "Superview" : "\(superview.idString)"
      idPrefix = "\(idString)_\(superviewID)_"
    }

    if let top = top {
      let topConstraint = topAnchor.constraint(equalTo: superview.topAnchor, constant: top)
      if let idPrefix {
        topConstraint.identifier = "\(idPrefix)_Top-Offset"
      }
      if let topPriority {
        topConstraint.priority = topPriority
      }
      topConstraint.isActive = true
    }
    if let leading = leading {
      let leadingConstraint = leadingAnchor.constraint(equalTo: superview.leadingAnchor, constant: leading)
      if let idPrefix {
        leadingConstraint.identifier = "\(idPrefix)_Lead-Offset"
      }
      if let leadPriority {
        leadingConstraint.priority = leadPriority
      }
      leadingConstraint.isActive = true
    }
    if let trailing = trailing {
      let trailingConstraint = superview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: trailing)
      if let idPrefix {
        trailingConstraint.identifier = "\(idPrefix)_Trail-Offset"
      }
      if let trailPriority {
        trailingConstraint.priority = trailPriority
      }
      trailingConstraint.isActive = true
    }
    if let bottom = bottom {
      let bottomConstraint = superview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: bottom)
      if let idPrefix {
        bottomConstraint.identifier = "\(idPrefix)_Btm-Offset"
      }
      if let btmPriority {
        bottomConstraint.priority = btmPriority
      }
      bottomConstraint.isActive = true
    }
  }

  /// Adds the given NSView to this view's subviews, then adds the given offset constraints.
  func addSubviewAndConstraints(_ subview: NSView,
                                top: CGFloat? = nil, _ topPriority: NSLayoutConstraint.Priority? = nil,
                                bottom: CGFloat? = nil, _ btmPriority: NSLayoutConstraint.Priority? = nil,
                                leading: CGFloat? = nil, _ leadPriority: NSLayoutConstraint.Priority? = nil,
                                trailing: CGFloat? = nil, _ trailPriority: NSLayoutConstraint.Priority? = nil) {
    addSubview(subview)
    subview.addConstraintsToFillSuperview(top: top, topPriority,
                                          bottom: bottom, btmPriority,
                                          leading: leading, leadPriority,
                                          trailing: trailing, trailPriority)
  }

  /// Get `NSImage` representation of the view.
  ///
  /// - Returns: `NSImage` of view
  func image() -> NSImage {
    let imageRepresentation = bitmapImageRepForCachingDisplay(in: bounds)!
    cacheDisplay(in: bounds, to: imageRepresentation)
    return NSImage(cgImage: imageRepresentation.cgImage!, size: bounds.size)
  }

  /// Returns the current NSAppearance using IINA & MacOS settings.
  /// Expected to always return either light or dark. (Not guaranteed though?)
  var iinaAppearance: NSAppearance {
    if #available(macOS 10.14, *) {
      var theme: Preference.Theme = Preference.enum(for: .themeMaterial)
      if theme == .system {
        if effectiveAppearance.isDark {
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
    return effectiveAppearance
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


// MARK: - DispatchQueue

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

  // MARK: public functionality

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

  public static func execOrAsyncIfNotIn(_ dq: DispatchQueue, execute work: @escaping @Sendable @convention(block) () -> Void) {
    if DispatchQueue.isExecutingIn(dq, logError: false) {
      work()
    } else {
      dq.async {
        work()
      }
    }
  }

  public func execOrAsync(execute work: @escaping @convention(block) () -> Void) {
    if DispatchQueue.isExecutingIn(self, logError: false) {
      work()
    } else {
      async {
        work()
      }
    }
  }

  public func execOrSync<R>(execute work: () -> R) -> R {
    if DispatchQueue.isExecutingIn(self, logError: false) {
      return work()
    } else {
      return sync {
        work()
      }
    }
  }
}


// MARK: - Other

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
