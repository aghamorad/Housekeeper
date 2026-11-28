import Foundation

/// A measurement taken with no tunnel up, for comparison against the routes.
struct BaselineSample: Codable, Sendable {
    var pingMs: Double?
    var jitterMs: Double?
    var packetLoss: Double?
    var fetchSeconds: Double?
    var fetchSucceeded: Bool = false
    var testedAt: Date = Date()
}

/// Drives a provider through a list of routes, one at a time.
///
/// Sequential by necessity: a VPN client holds one tunnel, so two connects
/// cannot overlap without the second tearing down the first. Everything that
/// varies between providers lives behind `VPNProvider`; what is left here is
/// the timing, the polling and the ordering.
@MainActor
final class RouteEngine: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var phase: RoutePhase = .idle
    @Published private(set) var currentTarget: RouteTarget?
    @Published private(set) var results: [RouteResult] = []
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var activity: String = ""
    @Published private(set) var baseline: BaselineSample?
    @Published private(set) var startedAt: Date?
    @Published var errorMessage: String?
    /// Set when a run ended but the tunnel would not let go. The UI shows this
    /// beside a one-click network rescue, because "the test is over" and "your
    /// internet works" are not the same claim.
    @Published private(set) var cleanupMessage: String?
    @Published private(set) var isCleaningUp = false

    /// Called once when a run ends, after the app has been returned to its
    /// resting state. The flag is `true` when the run reached the end and
    /// `false` when the user stopped it part-way.
    var onFinish: ((Bool) -> Void)?

    private var task: Task<Void, Never>?
    /// The provider whose tunnel this engine currently owns. Kept so Stop can
    /// close the tunnel even after the run loop has been cancelled.
    private var activeProvider: (any VPNProvider)?

    /// True from the moment a run starts until its tunnel is confirmed closed.
    /// Read at quit, when there is no run loop left to ask the engine directly.
    nonisolated(unsafe) static var tunnelMayBeOpen = false

    /// The app's terminate hook. No await is possible there, so the helper is
    /// asked synchronously to put the network back — but only when a run was in
    /// flight, so quitting Housekeeper never disconnects a VPN the reader chose.
    nonisolated static func rescueAtQuitIfNeeded() {
        guard tunnelMayBeOpen else { return }
        _ = PrivilegedHelper.send(HelperRequest(command: .resetNetwork), timeout: 20)
    }
    /// How often the tunnel state is re-read while waiting for it to settle.
    private let pollInterval: Double = 0.25

    // MARK: - Public control

    func start(
        provider: any VPNProvider,
        targets: [RouteTarget],
        options: RouteOptions,
        probeHost: String,
        probeURL: String
    ) {
        guard !isRunning, !targets.isEmpty else { return }

        results = []
        completedCount = 0
        totalCount = targets.count
        errorMessage = nil
        startedAt = Date()
        isRunning = true

        let order = options.randomizeOrder ? targets.shuffled() : targets

        task = Task { [weak self] in
            guard let self else { return }
            await self.run(provider: provider, targets: order,
                           options: options, probeHost: probeHost, probeURL: probeURL)
        }
    }

    func stop() {
        let provider = activeProvider
        let managedTunnel = provider?.managesSystemTunnel ?? false
        task?.cancel()
        task = nil
        isRunning = false
        phase = .idle
        currentTarget = nil

        guard managedTunnel, let provider else {
            RouteEngine.tunnelMayBeOpen = false
            activeProvider = nil
            activity = "Stopped"
            onFinish?(false)
            return
        }

        activity = "Closing the tunnel…"
        Task { [weak self] in
            guard let self else { return }
            await self.ensureTunnelDown(provider, allowNetworkReset: true)
            self.activeProvider = nil
            RouteEngine.tunnelMayBeOpen = false
            self.activity = "Stopped"
            self.onFinish?(false)
        }
    }



    /// Measure the network with no tunnel up, so every route has a reference.
    func measureBaseline(probeHost: String, probeURL: String, options: RouteOptions) {
        guard !isRunning else { return }
        isRunning = true
        phase = .measuring
        activity = "Measuring this connection with no tunnel…"

        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false; self.phase = .idle; self.activity = "" }

            let ping = await RouteProbes.ping(host: probeHost, count: options.pingCount,
                                              timeout: options.connectTimeout)
            var sample = BaselineSample(
                pingMs: ping?.avgMs, jitterMs: ping?.stddevMs, packetLoss: ping?.loss
            )
            if options.runFetchProbe {
                let fetch = await RouteProbes.fetch(url: probeURL, timeout: 15)
                sample.fetchSeconds = fetch?.seconds
                sample.fetchSucceeded = fetch?.succeeded ?? false
            }
            if !Task.isCancelled { self.baseline = sample }
        }
    }

    func clearCleanupMessage() {
        cleanupMessage = nil
    }

    func clearResults() {
        guard !isRunning else { return }
        results = []
        completedCount = 0
        totalCount = 0
        currentTarget = nil
    }

    // MARK: - The run

    private func run(
        provider: any VPNProvider,
        targets: [RouteTarget],
        options: RouteOptions,
        probeHost: String,
        probeURL: String
    ) async {
        activeProvider = provider
        cleanupMessage = nil

        // Direct endpoint providers (e.g. Surfshark) probe cluster hostnames
        // directly without touching the OS tunnel or disconnecting an active VPN.
        if !provider.managesSystemTunnel {
            RouteEngine.tunnelMayBeOpen = false
            for (index, target) in targets.enumerated() {
                if Task.isCancelled { break }
                currentTarget = target
                activity = "Checking \(index + 1) of \(targets.count) · \(target.location.city)"
                phase = .measuring

                if let sample = await provider.probeDirectRoute(
                    target, options: options, probeHost: probeHost, probeURL: probeURL
                ) {
                    if Task.isCancelled { break }
                    results.append(sample)
                    completedCount = index + 1
                }

                if Task.isCancelled { break }
                if index < targets.count - 1 {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
            }

            guard !Task.isCancelled else { return }
            activity = "Finished"
            activeProvider = nil
            finish(completed: true)
            return
        }

        RouteEngine.tunnelMayBeOpen = true

        // Start from a known state; a tunnel left up by an earlier run would
        // make the first connect a no-op and its timing meaningless. If the
        // provider's own tunnel will not close, do not start — and never flush
        // the whole Mac's network before a sweep has even begun.
        await provider.disconnect()
        if !(await waitForSettled(provider, target: .disconnected, timeout: 10, options: options)) {
            if Task.isCancelled { return }
            let state = await provider.tunnelState()
            if state != .disconnected {
                errorMessage = "\(provider.displayName) still reports \(state.rawValue) and did not disconnect cleanly, so the sweep did not start."
                cleanupMessage = "Nothing was tested. Disconnect \(provider.displayName) manually or press Fix My Internet Now."
                activeProvider = nil
                finish(completed: false)
                return
            }
        }

        var openedTunnel = false
        for (index, target) in targets.enumerated() {
            if Task.isCancelled { break }

            currentTarget = target
            activity = "Route \(index + 1) of \(targets.count)"
            phase = .connecting
            openedTunnel = true

            var result = RouteResult(target: target)
            let failure = await sweep(provider: provider, target: target,
                                      options: options, probeHost: probeHost,
                                      probeURL: probeURL, into: &result)

            if Task.isCancelled { break }
            result.failureReason = failure
            results.append(result)
            completedCount = index + 1

            phase = .cooling
            if options.cooldownSeconds > 0, index < targets.count - 1 {
                try? await Task.sleep(nanoseconds: UInt64(options.cooldownSeconds * 1_000_000_000))
            }
        }

        // If `stop()` cancelled this task, `stop()` owns teardown so we never
        // race two simultaneous `ensureTunnelDown` calls.
        guard !Task.isCancelled else { return }

        // Never leave the machine on a route the user did not pick — and do not
        // take the provider's word for it.
        phase = .disconnecting
        activity = "Closing the tunnel…"
        await ensureTunnelDown(provider, allowNetworkReset: openedTunnel)

        activity = "Finished"
        activeProvider = nil
        finish(completed: true)
    }

    private func finish(completed: Bool) {
        RouteEngine.tunnelMayBeOpen = false
        isRunning = false
        phase = .idle
        currentTarget = nil
        onFinish?(completed)
    }

    /// Ask the provider to disconnect, wait for it, and only if this sweep's
    /// tunnel refuses to close, restore the network through the helper.
    private func ensureTunnelDown(_ provider: any VPNProvider, allowNetworkReset: Bool = true) async {
        guard provider.managesSystemTunnel else { return }
        isCleaningUp = true
        defer { isCleaningUp = false }

        await provider.disconnect()
        if await waitForSettled(provider, target: .disconnected,
                                timeout: 10,
                                options: RouteOptions()) {
            return
        }

        let state = await provider.tunnelState()
        guard state == .connected || state == .connecting || state == .disconnecting else {
            return
        }
        guard allowNetworkReset else { return }

        let report = await VPNTunnelEngine.shared.forceRestoreInternet()
        cleanupMessage = "The client said it disconnected but a tunnel was still up. " + report.summary
    }

    /// Returns a failure description, or nil when the route came up.
    private func sweep(
        provider: any VPNProvider,
        target: RouteTarget,
        options: RouteOptions,
        probeHost: String,
        probeURL: String,
        into result: inout RouteResult
    ) async -> String? {

        do {
            try await provider.prepare(target)
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        if Task.isCancelled { return "Cancelled" }

        let started = Date()
        do {
            try await provider.beginConnect(target)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            result.connectSeconds = nil
            return message
        }

        let connected = await waitForSettled(
            provider, target: .connected, timeout: options.connectTimeout, options: options
        )
        if !connected {
            let state = await provider.tunnelState()
            result.connectSeconds = nil
            return "Did not connect within \(Int(options.connectTimeout))s (state: \(state.rawValue))"
        }

        result.connectSeconds = Date().timeIntervalSince(started)
        if Task.isCancelled { return "Cancelled" }

        // Give the interface a moment to take routes and DNS before probing,
        // or the first packets race the tunnel and look like packet loss.
        if options.settleSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(options.settleSeconds * 1_000_000_000))
        }
        if Task.isCancelled { return "Cancelled" }

        phase = .measuring
        if let ping = await RouteProbes.ping(host: probeHost, count: options.pingCount,
                                             timeout: 12) {
            result.pingMs = ping.received > 0 ? ping.avgMs : nil
            result.jitterMs = ping.stddevMs
            result.packetLoss = ping.loss
        }
        if Task.isCancelled { return "Cancelled" }

        if options.runFetchProbe {
            let fetch = await RouteProbes.fetch(url: probeURL, timeout: 20)
            result.fetchSeconds = fetch?.seconds
            result.fetchSucceeded = fetch?.succeeded ?? false
            result.exitIP = fetch?.exitIP
            result.exitCountry = fetch?.exitCountry
            if !result.fetchSucceeded, result.pingMs == nil {
                phase = .disconnecting
                await provider.disconnect()
                _ = await waitForSettled(provider, target: .disconnected,
                                         timeout: 12, options: options)
                return "Tunnel came up but carried no traffic"
            }
        } else {
            // Without the fetch probe, ping is the only evidence available.
            result.fetchSucceeded = result.pingMs != nil && (result.packetLoss ?? 1) < 1.0
        }

        phase = .disconnecting
        await provider.disconnect()
        _ = await waitForSettled(provider, target: .disconnected, timeout: 12, options: options)
        return nil
    }

    // MARK: - Waiting

    /// Polls until the tunnel reports the state we want, or the deadline passes.
    private func waitForSettled(
        _ provider: any VPNProvider,
        target: TunnelState,
        timeout: Double,
        options: RouteOptions
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var consecutiveUnknown = 0
        while Date() < deadline {
            if Task.isCancelled { return false }
            let state = await provider.tunnelState()
            if Task.isCancelled { return false }
            if state == target { return true }
            if state == .unknown {
                consecutiveUnknown += 1
                // Bail out early if the client CLI isn't answering instead of
                // burning the full 45-second timeout.
                if consecutiveUnknown >= 6 { return false }
            } else {
                consecutiveUnknown = 0
            }
            // A route that has fallen back to Disconnected will never reach
            // Connected, so stop burning the deadline. Confirmed one poll
            // later, because providers report Disconnected for a beat before
            // they flip to Connecting.
            if target == .connected, state == .disconnected,
               await confirmStillDisconnected(provider) {
                return false
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return false
    }

    /// A single extra look, one poll later, to be sure the state really is
    /// settled rather than mid-transition.
    private func confirmStillDisconnected(_ provider: any VPNProvider) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(pollInterval * 2 * 1_000_000_000))
        return await provider.tunnelState() == .disconnected
    }
}
