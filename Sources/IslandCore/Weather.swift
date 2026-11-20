import Foundation

public struct WeatherReport: Equatable, Sendable {
    public var temperature: Double
    public var code: Int
    public var isDay: Bool
    public var high: Double?
    public var low: Double?
    public var place: String

    public init(temperature: Double, code: Int, isDay: Bool, high: Double?, low: Double?, place: String) {
        self.temperature = temperature
        self.code = code
        self.isDay = isDay
        self.high = high
        self.low = low
        self.place = place
    }

    public var symbol: String { WeatherCode.symbol(code, isDay: isDay) }
    public var label: String { WeatherCode.label(code) }
}

/// Codes météo WMO utilisés par Open-Meteo → symbole SF et libellé français.
public enum WeatherCode {
    public static func symbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 66, 80, 81: "cloud.rain.fill"
        case 65, 67, 82: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 95: "cloud.bolt.rain.fill"
        case 96, 99: "cloud.bolt.fill"
        default: "cloud.fill"
        }
    }

    public static func label(_ code: Int) -> String {
        switch code {
        case 0: "Ciel dégagé"
        case 1: "Peu nuageux"
        case 2: "Partiellement nuageux"
        case 3: "Couvert"
        case 45, 48: "Brouillard"
        case 51, 53, 55: "Bruine"
        case 56, 57: "Bruine verglaçante"
        case 61: "Pluie faible"
        case 63: "Pluie"
        case 65: "Forte pluie"
        case 66, 67: "Pluie verglaçante"
        case 71, 73, 75, 77: "Neige"
        case 80, 81, 82: "Averses"
        case 85, 86: "Averses de neige"
        case 95: "Orage"
        case 96, 99: "Orage avec grêle"
        default: "Météo inconnue"
        }
    }
}

/// Réponse de `api.open-meteo.com/v1/forecast` (champs `current` + `daily`).
public struct OpenMeteoForecast: Decodable, Sendable {
    public struct Current: Decodable, Sendable {
        public var temperature_2m: Double
        public var weather_code: Int
        public var is_day: Int
    }
    public struct Daily: Decodable, Sendable {
        public var temperature_2m_max: [Double?]?
        public var temperature_2m_min: [Double?]?
    }
    public var current: Current
    public var daily: Daily?

    public func report(place: String) -> WeatherReport {
        WeatherReport(temperature: current.temperature_2m, code: current.weather_code, isDay: current.is_day == 1,
                      high: daily?.temperature_2m_max?.first ?? nil, low: daily?.temperature_2m_min?.first ?? nil,
                      place: place)
    }

    public static func url(latitude: Double, longitude: Double) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        return c.url!
    }
}

/// Réponse de `geocoding-api.open-meteo.com/v1/search`.
public struct OpenMeteoGeocoding: Decodable, Sendable {
    public struct Place: Decodable, Equatable, Sendable {
        public var name: String
        public var latitude: Double
        public var longitude: Double
        public var country: String?
        public var admin1: String?

        public var displayName: String {
            [name, admin1, country].compactMap { $0 }.filter { !$0.isEmpty }.reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            }.joined(separator: ", ")
        }
    }
    public var results: [Place]?

    public static func url(query: String) -> URL {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "5"),
            URLQueryItem(name: "language", value: "fr"),
        ]
        return c.url!
    }
}
