import SwiftUI

// MARK: – Country model

struct Country: Identifiable, Hashable {
    let id:   String  // ISO 3166-1 alpha-2
    let flag: String
    let name: String
    let dial: String  // e.g. "+51"

    /// Normaliza un string de dígitos crudos al número local correcto.
    /// Elimina el prefijo del código de país si el usuario lo incluyó.
    func normalize(digits: String) -> String {
        let code = dial.replacingOccurrences(of: "+", with: "")
        for prefix in [code, "0\(code)", "00\(code)"] {
            if digits.hasPrefix(prefix) {
                let stripped = String(digits.dropFirst(prefix.count))
                // Solo eliminar si lo que queda parece un número local válido (≥6 dígitos)
                if stripped.count >= 6 { return stripped }
            }
        }
        return digits
    }

    /// Número E.164 completo listo para enviar al backend.
    func e164(rawInput: String) -> String {
        let digits = rawInput.filter(\.isNumber)
        return "\(dial)\(normalize(digits: digits))"
    }
}

// MARK: – Country list (principales destinos de turistas + LATAM completo)

extension Country {
    static let all: [Country] = [
        // LATAM
        Country(id: "PE", flag: "🇵🇪", name: "Perú",            dial: "+51"),
        Country(id: "MX", flag: "🇲🇽", name: "México",           dial: "+52"),
        Country(id: "CO", flag: "🇨🇴", name: "Colombia",         dial: "+57"),
        Country(id: "AR", flag: "🇦🇷", name: "Argentina",        dial: "+54"),
        Country(id: "CL", flag: "🇨🇱", name: "Chile",            dial: "+56"),
        Country(id: "EC", flag: "🇪🇨", name: "Ecuador",          dial: "+593"),
        Country(id: "BO", flag: "🇧🇴", name: "Bolivia",          dial: "+591"),
        Country(id: "VE", flag: "🇻🇪", name: "Venezuela",        dial: "+58"),
        Country(id: "PY", flag: "🇵🇾", name: "Paraguay",         dial: "+595"),
        Country(id: "UY", flag: "🇺🇾", name: "Uruguay",          dial: "+598"),
        Country(id: "BR", flag: "🇧🇷", name: "Brasil",           dial: "+55"),
        Country(id: "CR", flag: "🇨🇷", name: "Costa Rica",       dial: "+506"),
        Country(id: "PA", flag: "🇵🇦", name: "Panamá",           dial: "+507"),
        Country(id: "GT", flag: "🇬🇹", name: "Guatemala",        dial: "+502"),
        Country(id: "HN", flag: "🇭🇳", name: "Honduras",         dial: "+504"),
        Country(id: "SV", flag: "🇸🇻", name: "El Salvador",      dial: "+503"),
        Country(id: "NI", flag: "🇳🇮", name: "Nicaragua",        dial: "+505"),
        Country(id: "DO", flag: "🇩🇴", name: "Rep. Dominicana",  dial: "+1"),
        Country(id: "CU", flag: "🇨🇺", name: "Cuba",             dial: "+53"),
        // América del Norte
        Country(id: "US", flag: "🇺🇸", name: "Estados Unidos",   dial: "+1"),
        Country(id: "CA", flag: "🇨🇦", name: "Canadá",           dial: "+1"),
        // Europa
        Country(id: "ES", flag: "🇪🇸", name: "España",           dial: "+34"),
        Country(id: "FR", flag: "🇫🇷", name: "Francia",          dial: "+33"),
        Country(id: "DE", flag: "🇩🇪", name: "Alemania",         dial: "+49"),
        Country(id: "IT", flag: "🇮🇹", name: "Italia",           dial: "+39"),
        Country(id: "GB", flag: "🇬🇧", name: "Reino Unido",      dial: "+44"),
        Country(id: "NL", flag: "🇳🇱", name: "Países Bajos",     dial: "+31"),
        Country(id: "PT", flag: "🇵🇹", name: "Portugal",         dial: "+351"),
        Country(id: "CH", flag: "🇨🇭", name: "Suiza",            dial: "+41"),
        Country(id: "BE", flag: "🇧🇪", name: "Bélgica",          dial: "+32"),
        Country(id: "AT", flag: "🇦🇹", name: "Austria",          dial: "+43"),
        Country(id: "SE", flag: "🇸🇪", name: "Suecia",           dial: "+46"),
        Country(id: "NO", flag: "🇳🇴", name: "Noruega",          dial: "+47"),
        Country(id: "DK", flag: "🇩🇰", name: "Dinamarca",        dial: "+45"),
        Country(id: "PL", flag: "🇵🇱", name: "Polonia",          dial: "+48"),
        // Asia-Pacífico (principales emisores de turistas a LATAM)
        Country(id: "JP", flag: "🇯🇵", name: "Japón",            dial: "+81"),
        Country(id: "CN", flag: "🇨🇳", name: "China",            dial: "+86"),
        Country(id: "KR", flag: "🇰🇷", name: "Corea del Sur",    dial: "+82"),
        Country(id: "AU", flag: "🇦🇺", name: "Australia",        dial: "+61"),
        Country(id: "NZ", flag: "🇳🇿", name: "Nueva Zelanda",    dial: "+64"),
        Country(id: "IN", flag: "🇮🇳", name: "India",            dial: "+91"),
        Country(id: "IL", flag: "🇮🇱", name: "Israel",           dial: "+972"),
        // África / Medio Oriente
        Country(id: "ZA", flag: "🇿🇦", name: "Sudáfrica",        dial: "+27"),
        Country(id: "AE", flag: "🇦🇪", name: "Emiratos Árabes",  dial: "+971"),
    ]

    static let defaultCountry = all.first { $0.id == "PE" }!
}

// MARK: – PhoneCountryField

struct PhoneCountryField: View {
    @Binding var phone:   String
    @Binding var country: Country
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Selector de país
            Menu {
                ForEach(Country.all) { c in
                    Button {
                        country = c
                    } label: {
                        Text("\(c.flag) \(c.name)  \(c.dial)")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(country.flag)
                        .font(.system(size: 20))
                    Text(country.dial)
                        .font(BT.callout)
                        .foregroundStyle(Color.inkMuted)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.inkMuted)
                }
            }

            Rectangle()
                .fill(Color.border)
                .frame(width: 1, height: 22)

            TextField(placeholder, text: $phone)
                .font(.system(size: 20, weight: .regular))
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .focused(focused)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 14)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(focused.wrappedValue ? Color.sand : Color.border,
                              lineWidth: focused.wrappedValue ? 1.5 : 1)
        )
    }

    private var placeholder: String {
        switch country.id {
        case "PE": return "999 312 458"
        case "US", "CA": return "555 867 5309"
        case "MX": return "55 1234 5678"
        case "ES": return "612 345 678"
        case "BR": return "11 91234-5678"
        default:   return "Número de teléfono"
        }
    }
}
