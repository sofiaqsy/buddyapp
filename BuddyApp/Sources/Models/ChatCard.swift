import Foundation

/// Contenido rico dentro de un mensaje de chat.
///
/// POR QUÉ UN PREFIJO Y NO UN message_type NUEVO
///
/// `message.type` es un ENUM de Postgres (`text, audio, image, system`).
/// Insertar un valor que el enum no conoce no falla en el cliente: falla en la
/// base con un 500. Si la app se publica antes que la migración, ENVIAR DEJA DE
/// FUNCIONAR — y ya nos pasó esta misma semana con `match_status: "active"`.
///
/// La app ya resolvió esto: los mensajes ricos viajan como `type='text'` con un
/// prefijo en `content`. Había tres convenciones sueltas (`place:`,
/// `location:`, `category_card:`), cada una con su propio formato posicional.
///
/// `card:` las generaliza. Un solo prefijo, un sobre con `kind`, y las tarjetas
/// futuras —un trip, un itinerario, un evento— entran sin inventar otro
/// prefijo ni otro parser.
///
/// COMPATIBILIDAD
///
/// Las tres convenciones viejas siguen vivas y se siguen renderizando: hay
/// mensajes con ese formato en la base y un chat es un registro histórico.
/// `card:` es adicional, no un reemplazo.
enum ChatCard {
    static let prefix = "card:"

    /// Un lugar recomendado, compartido dentro del chat.
    ///
    /// Los datos van DENORMALIZADOS a propósito. Un mensaje es lo que se dijo
    /// en ese momento: si el lugar se renombra o se borra, la tarjeta debe
    /// seguir leyéndose como se envió, no convertirse en un hueco.
    struct Place: Codable {
        /// Versión del sobre. Un lector viejo que no la reconozca cae al texto
        /// de respaldo en vez de dibujar una tarjeta a medias.
        var v: Int = 1
        /// Discriminador del sobre — "place" hoy, "trip"/"event" mañana.
        var kind: String = "place"

        /// El spot del catálogo. Es lo que permite abrir LA FICHA del lugar y
        /// no un pin suelto: sin id, lo máximo que se puede hacer con unas
        /// coordenadas es centrar un mapa.
        let spotId: String
        /// El destino al que pertenece — la guía que hay que cargar para poder
        /// enfocar el spot dentro de ella.
        let destinationId: String?
        let name: String
        /// Qué ES el lugar ("Café", "Alojamiento"). Opcional: no todos los
        /// spots del catálogo tienen categoría.
        let category: String?
        /// La foto que se ve en la tarjeta. Se guarda la URL enviada y no se
        /// resuelve al abrir: si el autor borra esa foto, el mensaje sigue
        /// mostrando lo que se compartió.
        let photoUrl: String?
        let lat: Double?
        let lng: Double?
        /// Quién recomienda el lugar — la prueba social de la tarjeta.
        let authorName: String?
    }

    /// Serializa a `card:{json}` para mandarlo como `content`.
    static func encode(_ place: Place) -> String? {
        guard let data = try? JSONEncoder().encode(place),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return prefix + json
    }

    /// Devuelve la tarjeta si `content` es un sobre `card:` de tipo place.
    ///
    /// Nil ante cualquier duda —prefijo ausente, JSON roto, `kind` desconocido,
    /// versión futura—. Quien llama pinta entonces el texto de respaldo: es
    /// preferible una frase a una tarjeta rota, y sobre todo a un JSON crudo
    /// dentro de una burbuja.
    static func decodePlace(_ content: String?) -> Place? {
        guard let content, content.hasPrefix(prefix) else { return nil }
        let json = String(content.dropFirst(prefix.count))
        guard let data = json.data(using: .utf8),
              let card = try? JSONDecoder().decode(Place.self, from: data),
              card.kind == "place", card.v == 1 else { return nil }
        return card
    }

    /// Lo que se lee donde no hay sitio para una tarjeta: la lista de
    /// conversaciones, el CTA del Home, una notificación push.
    ///
    /// Solo el nombre, sin emoji. En el CTA del Home la línea ya llega
    /// prefijada con "Tú: ", y un pin delante lo dejaba en «Tú: 📍 Cafetería
    /// Rosal» — tres señales compitiendo en un renglón que solo tiene que
    /// recordar de qué se habló.
    static func resumen(_ content: String?) -> String? {
        decodePlace(content)?.name
    }
}
