import SwiftUI

enum ShelfTagColor: String, CaseIterable, Identifiable {
  case crimson
  case orange
  case amber
  case lime
  case emerald
  case teal
  case blue
  case indigo

  var id: String { rawValue }

  var color: Color {
    switch self {
    case .crimson:
      return Color(red: 0.86, green: 0.22, blue: 0.33)
    case .orange:
      return Color(red: 0.95, green: 0.47, blue: 0.20)
    case .amber:
      return Color(red: 0.95, green: 0.72, blue: 0.18)
    case .lime:
      return Color(red: 0.60, green: 0.78, blue: 0.20)
    case .emerald:
      return Color(red: 0.20, green: 0.70, blue: 0.43)
    case .teal:
      return Color(red: 0.12, green: 0.69, blue: 0.67)
    case .blue:
      return Color(red: 0.22, green: 0.55, blue: 0.92)
    case .indigo:
      return Color(red: 0.35, green: 0.38, blue: 0.89)
    }
  }
}
