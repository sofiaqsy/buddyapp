import Foundation

struct Memory: Identifiable, Codable {
    let id: UUID
    let destinationName: String
    let date: Date
    let coverEmoji: String
    let placesVisited: Int
    let buddyName: String
    let stickers: [String]   // SF Symbol names collected
    let note: String
    let gradientStart: String // hex
    let gradientEnd: String

    var formattedDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_PE")
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date).capitalized
    }
}

extension Memory {
    static let samples: [Memory] = [
        Memory(id: UUID(), destinationName: "Villa Rica",
               date: Calendar.current.date(byAdding: .month, value: -2, to: Date())!,
               coverEmoji: "☕", placesVisited: 4, buddyName: "María",
               stickers: ["cup.and.saucer", "leaf", "building.columns", "mountain.2"],
               note: "El café más increíble que he probado. María me llevó a su finca favorita.",
               gradientStart: "0D4F49", gradientEnd: "0F766E"),
        Memory(id: UUID(), destinationName: "Cuzco",
               date: Calendar.current.date(byAdding: .month, value: -5, to: Date())!,
               coverEmoji: "🏔️", placesVisited: 6, buddyName: "Carlos",
               stickers: ["mountain.2", "sun.max", "basket", "sparkles"],
               note: "Machu Picchu al amanecer. Carlos sabía exactamente dónde pararse.",
               gradientStart: "4a2a0a", gradientEnd: "7C4A1E"),
        Memory(id: UUID(), destinationName: "Lima",
               date: Calendar.current.date(byAdding: .month, value: -8, to: Date())!,
               coverEmoji: "🌊", placesVisited: 3, buddyName: "Rosa",
               stickers: ["cup.and.saucer", "building.columns", "leaf"],
               note: "Rosa me mostró el Barranco real, no el de las guías.",
               gradientStart: "1e3a5f", gradientEnd: "2a6b7a"),
    ]
}
