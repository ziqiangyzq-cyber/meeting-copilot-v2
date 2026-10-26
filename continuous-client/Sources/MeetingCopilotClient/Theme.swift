import SwiftUI

/// White functional areas on a faint blue-gray canvas, following Meeting Copilot.
enum MeetingCopilotTheme {
    static let background = Color(red: 244 / 255, green: 246 / 255, blue: 250 / 255)
    static let card = Color.white
    static let accent = Color(red: 54 / 255, green: 94 / 255, blue: 136 / 255)
    static let selection = Color(red: 237 / 255, green: 243 / 255, blue: 249 / 255)
    static let line = Color(red: 227 / 255, green: 232 / 255, blue: 239 / 255)
    static let ink = Color(red: 38 / 255, green: 52 / 255, blue: 66 / 255)
}

extension View {
    func meetingCopilotCard() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MeetingCopilotTheme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(MeetingCopilotTheme.line, lineWidth: 1))
    }
}
