import SwiftUI
import UIKit

enum TutorLetterSize: Int, CaseIterable, Identifiable {
    case standard = 19, large = 23, extraLarge = 28

    static let defaultsKey = "tutorLetterSize"
    var id: Int { rawValue }
    var font: UIFont { UIFont.systemFont(ofSize: CGFloat(rawValue), weight: .medium) }

    var title: String {
        switch self {
        case .standard: return "기본"
        case .large: return "크게"
        case .extraLarge: return "아주 크게"
        }
    }

    static var saved: Self { Self(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .standard }
}

enum TutorInkColor: String, CaseIterable, Identifiable {
    case blue, plum, dark

    static let defaultsKey = "tutorInkColor"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: return "남색"
        case .plum: return "자주색"
        case .dark: return "진한 회색"
        }
    }

    var color: UIColor {
        switch self {
        case .blue: return UIColor(red: 0.10, green: 0.30, blue: 0.62, alpha: 1)
        case .plum: return UIColor(red: 0.49, green: 0.16, blue: 0.35, alpha: 1)
        case .dark: return UIColor(white: 0.18, alpha: 1)
        }
    }

    static var saved: Self { Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .blue }
}
