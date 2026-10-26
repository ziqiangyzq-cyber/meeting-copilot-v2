import Foundation

/// Protocol offsets are Unicode scalar/code point offsets, not grapheme or UTF-16 offsets.
public enum CodePointText {
    public static func slice(_ text: String, start: Int, end: Int) throws -> String {
        let scalars = Array(text.unicodeScalars)
        guard start >= 0, end >= start, end <= scalars.count else { throw CoreError.invalid("CODE_POINT_RANGE") }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }
}
