import SwiftUI
import WalkingPadKit

struct PanelView: View {
    let pad: Treadmill
    @AppStorage("weightKg") private var weightKg = 75.0
    @AppStorage("showSettings") private var showSettings = false

    private var miles: Bool { pad.usesMiles }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if pad.phase == .ready {
                if pad.mode == .standby {
                    standbyBlock
                } else {
                    speedControl
                    presets
                    stats
                    beltButtons
                }
                if showSettings { settings }
            } else {
                connectionHint
            }
            if let error = pad.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { pad.weightKg = weightKg }
        .onChange(of: weightKg) { pad.weightKg = weightKg }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(pad.deviceName ?? "WalkingPad").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if pad.busy { ProgressView().controlSize(.small) }
        }
    }

    private var statusText: String {
        switch pad.phase {
        case .bluetoothOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth access denied"
        case .idle: "Not connected"
        case .scanning: "Searching…"
        case .connecting: "Connecting…"
        case .ready:
            if pad.mode == .standby { "Standby" }
            else if pad.isRunning { "Walking" }
            else if pad.isPaused { "Paused" }
            else { "Ready" }
        }
    }

    private var statusColor: Color {
        switch pad.phase {
        case .ready: pad.isRunning ? .green : pad.isPaused ? .yellow : .blue
        case .scanning, .connecting: .orange
        default: .gray
        }
    }

    // MARK: Speed

    private var speedControl: some View {
        let shown = pad.targetSpeedKmh ?? pad.speedKmh
        return HStack {
            speedButton("minus", step: -1)
            Spacer()
            VStack(spacing: 0) {
                Text(Units.speed(shown, miles: miles))
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(speedCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            speedButton("plus", step: 1)
        }
        .disabled(!pad.isRunning)
        // Hidden buttons for the bigger keyboard steps.
        .background {
            Group {
                Button("") { nudge(5) }.keyboardShortcut(.upArrow, modifiers: .shift)
                Button("") { nudge(-5) }.keyboardShortcut(.downArrow, modifiers: .shift)
            }
            .hidden()
            .disabled(!pad.isRunning)
        }
    }

    private var speedCaption: String {
        let unit = Units.speedUnit(miles: miles)
        guard pad.isRunning, let target = pad.targetSpeedKmh, abs(target - pad.speedKmh) >= 0.05 else { return unit }
        return "\(unit) · now \(Units.speed(pad.speedKmh, miles: miles))"
    }

    private func speedButton(_ symbol: String, step: Int) -> some View {
        Button { nudge(step) } label: {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .buttonRepeatBehavior(.enabled)
        .keyboardShortcut(step > 0 ? .upArrow : .downArrow, modifiers: [])
        .help(step > 0 ? "Faster: ↑ = 0.1, ⇧↑ = 0.5" : "Slower: ↓ = 0.1, ⇧↓ = 0.5")
    }

    /// Change speed by `tenths` of a display unit (mph or km/h), snapping to a clean value.
    private func nudge(_ tenths: Int) {
        let current = Units.toDisplay(pad.targetSpeedKmh ?? pad.speedKmh, miles: miles)
        let snapped = ((current * 10).rounded() + Double(tenths)) / 10
        pad.setSpeed(Units.fromDisplay(snapped, miles: miles))
    }

    /// One-tap speeds; when the belt is stopped they also start it.
    private var presets: some View {
        let values: [Double] = miles ? [1, 1.5, 2, 2.5, 3, 3.5] : [2, 3, 4, 5, 6]
        let current = Units.toDisplay(pad.targetSpeedKmh ?? pad.speedKmh, miles: miles)
        return HStack(spacing: 4) {
            ForEach(values, id: \.self) { value in
                let active = pad.isRunning && abs(current - value) < 0.05
                Button { pad.start(at: Units.fromDisplay(value, miles: miles)) } label: {
                    Text(value.formatted(.number.precision(.fractionLength(0 ... 1))))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(active ? .accentColor : nil)
                .help("Walk at \(value.formatted()) \(Units.speedUnit(miles: miles))")
            }
        }
        .controlSize(.small)
    }

    // MARK: Stats

    private var stats: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 2) {
            GridRow {
                stat(Units.duration(pad.elapsedS), "time")
                stat(Units.distance(pad.distanceM, miles: miles), "distance")
                stat("\(pad.steps)", "steps")
                stat("\(Int(pad.calories))", "kcal")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Belt

    private var beltButtons: some View {
        HStack(spacing: 8) {
            if pad.isRunning {
                Button { pad.pause() } label: { Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.space, modifiers: [])
            } else {
                Button { pad.start() } label: {
                    Label(pad.isPaused ? "Resume" : "Start", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.space, modifiers: [])
                .tint(.green)
            }
            Button { pad.stop() } label: { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                .help("Stop and end the session (resets the counters)")
                .disabled(!pad.isRunning && !pad.isPaused)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var standbyBlock: some View {
        Button { pad.setStandby(false) } label: {
            Label("Wake up", systemImage: "sun.max.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.space, modifiers: [])
        .help("Wake the treadmill (the belt stays still)")
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            toggle("Show miles", .miles)
            toggle("Beep", .beep)
            toggle("Indicator light", .light)
            toggle("Child lock", .childLock)
            toggle("Auto-stop when idle", .autoStop)
            if !pad.padReportsCalories {
                HStack {
                    Text("Weight (for kcal)")
                    Spacer()
                    TextField("", value: $weightKg, format: .number.precision(.fractionLength(0)))
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                    Text("kg").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func toggle(_ title: String, _ setting: Treadmill.Setting) -> some View {
        Toggle(title, isOn: Binding(get: { pad.isOn(setting) }, set: { pad.set(setting, $0) }))
            .toggleStyle(.switch)
            .controlSize(.mini)
    }

    // MARK: Not connected

    @ViewBuilder
    private var connectionHint: some View {
        switch pad.phase {
        case .idle:
            Button { pad.connect() } label: { Text("Connect").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .unauthorized:
            Text("Allow Bluetooth for Treadmill in System Settings → Privacy & Security → Bluetooth.")
                .font(.callout).foregroundStyle(.secondary)
        case .bluetoothOff:
            Text("Turn Bluetooth on to connect.").font(.callout).foregroundStyle(.secondary)
        default:
            Text("Make sure the treadmill is on and the KS Fit app isn't connected to it.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if pad.phase == .ready {
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .help(showSettings ? "Hide settings" : "Settings")
                if pad.mode != .standby {
                    Button { pad.setStandby(true) } label: { Label("Standby", systemImage: "power") }
                        .help("Put the treadmill to sleep (stops the belt first)")
                }
                Button { pad.disconnect() } label: { Label("Disconnect", systemImage: "antenna.radiowaves.left.and.right.slash") }
                    .labelStyle(.iconOnly)
                    .help("Disconnect")
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
