import Foundation
import Testing
@testable import IslandCore

@Suite("Météo Open-Meteo")
struct WeatherTests {
    @Test func decodesForecast() throws {
        let json = """
        {"latitude":48.86,"longitude":2.35,"current":{"time":"2026-11-20T22:00","interval":900,
         "temperature_2m":7.4,"weather_code":3,"is_day":0},
         "daily":{"time":["2026-11-20"],"temperature_2m_max":[10.2],"temperature_2m_min":[4.1]}}
        """
        let f = try JSONDecoder().decode(OpenMeteoForecast.self, from: Data(json.utf8))
        let r = f.report(place: "Paris")
        #expect(r.temperature == 7.4)
        #expect(r.high == 10.2 && r.low == 4.1)
        #expect(!r.isDay)
        #expect(r.symbol == "cloud.fill")
        #expect(r.label == "Couvert")
    }

    @Test func dayAndNightSymbols() {
        #expect(WeatherCode.symbol(0, isDay: true) == "sun.max.fill")
        #expect(WeatherCode.symbol(0, isDay: false) == "moon.stars.fill")
        #expect(WeatherCode.symbol(1234, isDay: true) == "cloud.fill")
    }

    @Test func geocodingDisplayName() throws {
        let json = """
        {"results":[{"name":"Jouy-en-Josas","latitude":48.76,"longitude":2.17,"country":"France","admin1":"Île-de-France"}]}
        """
        let g = try JSONDecoder().decode(OpenMeteoGeocoding.self, from: Data(json.utf8))
        #expect(g.results?.first?.displayName == "Jouy-en-Josas, Île-de-France, France")
    }

    @Test func forecastURL() {
        let url = OpenMeteoForecast.url(latitude: 48.8566, longitude: 2.3522).absoluteString
        #expect(url.contains("latitude=48.857"))
        #expect(url.contains("current=temperature_2m,weather_code,is_day"))
    }
}
