import Foundation

struct HostProfile: Identifiable, Codable {
    let id: UUID
    let name: String
    let bio: String
    let avatar: String       // emoji placeholder
    let city: String
    let rating: Double
    let tripsHosted: Int
    let isOnline: Bool
    let specialties: [String]
    let lastSeen: String
    let lastMessage: String
    let isActive: Bool       // current active connection
}

extension HostProfile {
    static let samples: [HostProfile] = [
        HostProfile(
            id: UUID(), name: "María",
            bio: "Guía local. Conozco cada rincón de Villa Rica y los mejores cafés de altura.",
            avatar: "👩‍🦱", city: "Villa Rica", rating: 4.9, tripsHosted: 34,
            isOnline: true, specialties: ["Café", "Naturaleza", "Cultura local"],
            lastSeen: "en línea", lastMessage: "¿llegaste bien? cualquier cosa me escribes",
            isActive: true
        ),
        HostProfile(
            id: UUID(), name: "Don César",
            bio: "Agricultor de café. Te llevo a ver cómo nace tu taza.",
            avatar: "👨‍🌾", city: "Villa Rica", rating: 4.8, tripsHosted: 21,
            isOnline: false, specialties: ["Finca", "Café", "Naturaleza"],
            lastSeen: "lun",
            lastMessage: "listo, te espero en la finca el sábado",
            isActive: false
        ),
        HostProfile(
            id: UUID(), name: "Lucía",
            bio: "Artesana y cocinera. Hago el mejor mazamorra del pueblo.",
            avatar: "👩‍🍳", city: "Villa Rica", rating: 4.7, tripsHosted: 18,
            isOnline: false, specialties: ["Gastronomía", "Artesanía", "Mercado"],
            lastSeen: "3 jun",
            lastMessage: "gracias por venir al mercado, vuelve pronto",
            isActive: false
        ),
    ]
}
