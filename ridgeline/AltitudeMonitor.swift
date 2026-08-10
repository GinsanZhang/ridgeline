import Combine
import CoreLocation
import CoreMotion
import Foundation

@MainActor
final class AltitudeMonitor: NSObject, ObservableObject {
    static let shared = AltitudeMonitor()

    @Published private(set) var currentAltitude: Double?
    @Published private(set) var verticalSpeed: Double?
    @Published private(set) var slope: Double?
    @Published private(set) var horizontalSpeed: Double?
    @Published private(set) var isAuthorizationDenied = false
    @Published private(set) var isTracking = false

    private let locationManager = CLLocationManager()
    private let altimeter = CMAltimeter()

    private var trackingRequested = false
    private var gpsBaselineAltitude: Double?
    private var barometerBaselineAltitude: Double?
    private var latestRelativeAltitude: Double?
    private var previousRelativeAltitude: Double?
    private var previousBarometerTimestamp: TimeInterval?

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 2
        locationManager.activityType = .fitness
    }

    func start() {
        updateAuthorizationState()
        trackingRequested = true

        let authorizationStatus = locationManager.authorizationStatus
        if authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if isAuthorized(authorizationStatus) {
            locationManager.startUpdatingLocation()
        } else {
            trackingRequested = false
            isTracking = false
            return
        }

        isTracking = true
        startAltimeterUpdates()
    }

    func stop() {
        trackingRequested = false
        isTracking = false
        locationManager.stopUpdatingLocation()
        altimeter.stopRelativeAltitudeUpdates()
        resetTransientMeasurements()
    }

    private func startAltimeterUpdates() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            return
        }

        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            Task { @MainActor in
                self.process(
                    relativeAltitude: data.relativeAltitude.doubleValue,
                    timestamp: data.timestamp
                )
            }
        }
    }

    private func process(relativeAltitude: Double, timestamp: TimeInterval) {
        latestRelativeAltitude = relativeAltitude

        if barometerBaselineAltitude == nil {
            barometerBaselineAltitude = relativeAltitude
        }

        if let gpsBaselineAltitude, let barometerBaselineAltitude {
            currentAltitude = gpsBaselineAltitude + relativeAltitude - barometerBaselineAltitude
        }

        if let previousRelativeAltitude,
           let previousBarometerTimestamp {
            let elapsed = timestamp - previousBarometerTimestamp
            if elapsed > 0 {
                verticalSpeed = (relativeAltitude - previousRelativeAltitude) / elapsed * 60
                updateSlope()
            }
        }

        self.previousRelativeAltitude = relativeAltitude
        previousBarometerTimestamp = timestamp
    }

    private func updateSlope() {
        guard let verticalSpeed,
              let horizontalSpeed,
              horizontalSpeed > 0.1 else {
            slope = nil
            return
        }

        slope = (verticalSpeed / 60) / horizontalSpeed * 100
    }

    private func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways || status == .authorizedWhenInUse
    }

    private func updateAuthorizationState() {
        isAuthorizationDenied = locationManager.authorizationStatus == .denied
            || locationManager.authorizationStatus == .restricted
    }

    private func resetTransientMeasurements() {
        currentAltitude = nil
        verticalSpeed = nil
        slope = nil
        horizontalSpeed = nil
        gpsBaselineAltitude = nil
        previousRelativeAltitude = nil
        previousBarometerTimestamp = nil
        barometerBaselineAltitude = nil
        latestRelativeAltitude = nil
    }
}

extension AltitudeMonitor: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateAuthorizationState()

        guard trackingRequested else {
            return
        }

        if isAuthorized(manager.authorizationStatus) {
            isTracking = true
            manager.startUpdatingLocation()
        } else if manager.authorizationStatus == .denied
                    || manager.authorizationStatus == .restricted {
            stop()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last,
              location.verticalAccuracy >= 0 else {
            return
        }

        gpsBaselineAltitude = location.altitude
        barometerBaselineAltitude = latestRelativeAltitude
        currentAltitude = location.altitude
        horizontalSpeed = location.speed >= 0 ? location.speed : nil
        updateSlope()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let locationError = error as? CLError, locationError.code == .denied {
            updateAuthorizationState()
            stop()
        }
    }
}
