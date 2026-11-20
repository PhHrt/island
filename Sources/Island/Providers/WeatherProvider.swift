import Foundation
import Intents
import IslandCore

/// Météo de la ville choisie dans les réglages, via Open-Meteo (gratuit, sans clé, sans compte).
/// Seules les coordonnées de la ville partent sur le réseau, toutes les 15 minutes.
@MainActor
final class WeatherProvider {
    private let model: IslandModel
    private var timer: Timer?
    private var lastKey = ""
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    init(model: IslandModel) { self.model = model }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Ville ou activation changées dans les réglages -> rafraîchit tout de suite.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let key = "\(Prefs.weather)|\(Prefs.weatherCoordinates)"
                if key != self.lastKey { self.refresh() }
            }
        }
    }

    func refresh() {
        let (lat, lon) = Prefs.weatherCoordinates
        lastKey = "\(Prefs.weather)|\(Prefs.weatherCoordinates)"
        guard Prefs.weather else { model.weather = nil; return }
        let place = Prefs.weatherPlace.components(separatedBy: ",").first ?? ""
        Task { [weak self] in
            guard let self else { return }
            do {
                let (data, _) = try await self.session.data(from: OpenMeteoForecast.url(latitude: lat, longitude: lon))
                let forecast = try JSONDecoder().decode(OpenMeteoForecast.self, from: data)
                self.model.weather = forecast.report(place: place)
            } catch {
                // On garde la dernière météo connue ; nouvel essai au prochain tick.
            }
        }
    }

    /// Recherche de villes pour l'écran de réglages.
    static func searchPlaces(_ query: String) async -> [OpenMeteoGeocoding.Place] {
        guard query.trimmingCharacters(in: .whitespaces).count >= 2,
              let (data, _) = try? await URLSession.shared.data(from: OpenMeteoGeocoding.url(query: query)),
              let result = try? JSONDecoder().decode(OpenMeteoGeocoding.self, from: data) else { return [] }
        return result.results ?? []
    }
}

/// Indicateur « mode Concentration actif » via INFocusStatusCenter.
/// macOS ne notifie pas les changements : on relit toutes les 20 s. Sans autorisation, l'indicateur reste masqué.
@MainActor
final class FocusProvider {
    private let model: IslandModel
    private var timer: Timer?

    init(model: IslandModel) { self.model = model }

    func start() {
        let center = INFocusStatusCenter.default
        center.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                DebugLog.write("focus authorization: \(status.rawValue)")
                guard status == .authorized else { return }
                self.read()
                self.timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.read() }
                }
            }
        }
    }

    private func read() {
        let focused = INFocusStatusCenter.default.focusStatus.isFocused ?? false
        if focused != model.isFocusActive { model.isFocusActive = focused }
    }
}
