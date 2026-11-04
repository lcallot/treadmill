import SwiftUI
import WalkingPadKit

@main
struct TreadmillApp: App {
    @State private var pad = Treadmill()

    var body: some Scene {
        MenuBarExtra {
            PanelView(pad: pad)
        } label: {
            MenuBarLabel(pad: pad)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Walking figure, plus the live speed while the belt moves.
struct MenuBarLabel: View {
    let pad: Treadmill

    var body: some View {
        if pad.isRunning {
            Text("\(Image(systemName: "figure.walk")) \(Units.speed(pad.speedKmh, miles: pad.usesMiles))")
        } else {
            Image(systemName: pad.phase == .ready ? "figure.walk" : "figure.stand")
        }
    }
}

enum Units {
    static let kmPerMile = 1.609344

    static func toDisplay(_ kmh: Double, miles: Bool) -> Double { miles ? kmh / kmPerMile : kmh }
    static func fromDisplay(_ value: Double, miles: Bool) -> Double { miles ? value * kmPerMile : value }

    static func speed(_ kmh: Double, miles: Bool) -> String {
        String(format: "%.1f", toDisplay(kmh, miles: miles))
    }

    static func speedUnit(miles: Bool) -> String { miles ? "mph" : "km/h" }

    static func distance(_ meters: Int, miles: Bool) -> String {
        let value = Double(meters) / 1000 / (miles ? kmPerMile : 1)
        return String(format: "%.2f %@", value, miles ? "mi" : "km")
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
