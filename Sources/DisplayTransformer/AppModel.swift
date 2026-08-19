import AppKit
import CoreGraphics
import Foundation
import OSLog
import ServiceManagement
import TransformerCore

private let lifecycleLogger = Logger(
    subsystem: "com.github.trsdn.DisplayTransformer",
    category: "lifecycle"
)

private enum AppModelError: LocalizedError {
    case displayConfigurationChangedDuringStart
    case captureStoppedDuringStart(String)
    case renderingFailedDuringStart(String)

    var errorDescription: String? {
        switch self {
        case .displayConfigurationChangedDuringStart:
            return "Die Monitorkonfiguration hat sich während des Starts geändert."
        case let .captureStoppedDuringStart(message):
            return "Die Bildschirmaufnahme wurde beim Start beendet: \(message)"
        case let .renderingFailedDuringStart(message):
            return "Die Bildausgabe ist beim Start fehlgeschlagen: \(message)"
        }
    }
}

private enum SettingsStore {
    static let key = "app-settings-v1"

    static func load(from defaults: UserDefaults) -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            return .defaults
        }
        do {
            return try AppSettingsCodec.decode(data)
        } catch {
            NSLog(
                "Gespeicherte Einstellungen sind ungültig; Standardwerte werden verwendet: %@",
                error.localizedDescription
            )
            return .defaults
        }
    }

    static func save(_ settings: AppSettings, to defaults: UserDefaults) {
        do {
            defaults.set(try AppSettingsCodec.encode(settings), forKey: key)
        } catch {
            NSLog(
                "Einstellungen konnten nicht gespeichert werden: %@",
                error.localizedDescription
            )
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var displays: [DisplayDescriptor] = []
    @Published private(set) var selectedSourceID: CGDirectDisplayID?
    @Published private(set) var selectedTargetID: CGDirectDisplayID?
    @Published private(set) var transform: DisplayTransform
    @Published private(set) var presets: [PresetSlot]
    @Published private(set) var activePresetIndex: Int
    @Published private(set) var configurationIsDirty = false
    @Published private(set) var autoStartOutput: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var permissionGranted = false
    @Published private(set) var statusText = "Monitore werden gesucht …"
    @Published private(set) var statusIsError = false
    @Published private(set) var loginItemEnabled = false
    @Published private(set) var loginItemBusy = false
    @Published private(set) var loginItemNeedsApproval = false
    @Published private(set) var loginItemStatusText =
        "Anmeldestatus wird geprüft …"
    @Published private(set) var loginItemStatusIsError = false

    private enum Lifecycle: Equatable {
        case idle
        case waiting
        case starting(UInt64)
        case running
        case stopping
        case blocked
    }

    private enum BlockReason: Equatable {
        case permission
        case capture
    }

    private let defaults: UserDefaults
    private let isSelfTest =
        CommandLine.arguments.contains("--self-test")
    private var settings: AppSettings
    private var workingSourceIdentity: PersistentDisplayIdentity?
    private var workingTargetIdentity: PersistentDisplayIdentity?
    private var lifecycle: Lifecycle = .idle
    private var blockReason: BlockReason?
    private var desiredOutput = false
    private var manualStopSuppressed = false
    private var operationEpoch: UInt64 = 0
    private var pendingCaptureStop: (epoch: UInt64, message: String)?
    private var pendingRenderingFailure: (epoch: UInt64, message: String)?
    private var captureSession: CaptureSession?
    private var outputController: OutputWindowController?
    private var activeSource: DisplayDescriptor?
    private var activeTarget: DisplayDescriptor?
    private var displayChangeTask: Task<Void, Never>?
    private var selfTestTimeoutTask: Task<Void, Never>?
    private var didLaunch = false
    private var selfTestRenderedFrame = false

    init(defaults: UserDefaults = .standard) {
        let loaded = SettingsStore.load(from: defaults).normalized()
        self.defaults = defaults
        settings = loaded
        presets = loaded.presets
        activePresetIndex = loaded.activePresetIndex
        autoStartOutput = loaded.autoStartOutput

        let configuration =
            loaded.presets[loaded.activePresetIndex].configuration
        workingSourceIdentity = configuration.source
        workingTargetIdentity = configuration.target
        transform = configuration.transform
        permissionGranted = CGPreflightScreenCaptureAccess()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        refreshDisplaySnapshot()
        updateIdleStatus()
    }

    deinit {
        displayChangeTask?.cancel()
        selfTestTimeoutTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    var canStart: Bool {
        guard !isRunning,
              !isBusy,
              let workingSourceIdentity,
              let workingTargetIdentity else {
            return false
        }
        return workingSourceIdentity != workingTargetIdentity
    }

    var canSavePreset: Bool {
        guard let sourceID = selectedSourceID,
              let targetID = selectedTargetID else {
            return false
        }
        return sourceID != targetID
    }

    var selectionsAreIdentical: Bool {
        selectedSourceID != nil && selectedSourceID == selectedTargetID
    }

    var activePresetName: String {
        presets[activePresetIndex].name
    }

    var sourceConnectionHint: String? {
        connectionHint(
            identity: workingSourceIdentity,
            resolvedID: selectedSourceID
        )
    }

    var targetConnectionHint: String? {
        connectionHint(
            identity: workingTargetIdentity,
            resolvedID: selectedTargetID
        )
    }

    var appIsInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path == "/Applications"
            || path.hasPrefix("/Applications/")
    }

    func appDidLaunch() {
        guard !didLaunch else {
            return
        }
        didLaunch = true
        updatePermissionStatus()
        refreshLoginItemStatus()

        if isSelfTest {
            Task { @MainActor [weak self] in
                await self?.startSelfTestIfRequested()
            }
        } else if autoStartOutput {
            desiredOutput = true
            Task { @MainActor [weak self] in
                await self?.reconcileOutput()
            }
        }
    }

    func selectSource(_ displayID: CGDirectDisplayID?) {
        guard !isRunning, !isBusy else {
            return
        }
        selectedSourceID = displayID
        workingSourceIdentity = displayID.flatMap { id in
            displays.first(where: { $0.id == id })?.identity
        }
        updateDirtyFlag()
        updateIdleStatus()
    }

    func selectTarget(_ displayID: CGDirectDisplayID?) {
        guard !isRunning, !isBusy else {
            return
        }
        selectedTargetID = displayID
        workingTargetIdentity = displayID.flatMap { id in
            displays.first(where: { $0.id == id })?.identity
        }
        updateDirtyFlag()
        updateIdleStatus()
    }

    func setTransform(_ newTransform: DisplayTransform) {
        transform = newTransform
        outputController?.updateTransform(newTransform)
        updateDirtyFlag()
    }

    func resetTransform() {
        setTransform(.identity)
    }

    func selectPreset(_ index: Int) {
        guard settings.presets.indices.contains(index) else {
            return
        }

        let shouldContinueRunning =
            desiredOutput || isRunning || autoStartOutput
        invalidateStartIfNeeded()
        settings.activePresetIndex = index
        activePresetIndex = index
        persistSettings()
        loadActivePreset()
        manualStopSuppressed = false
        blockReason = nil
        desiredOutput = shouldContinueRunning

        Task { @MainActor [weak self] in
            await self?.reconcileOutput()
        }
    }

    func reloadActivePreset() {
        selectPreset(activePresetIndex)
    }

    func renameActivePreset(_ name: String) {
        let limited = String(name.prefix(40))
        settings.presets[activePresetIndex].name = limited
        presets = settings.presets
        persistSettings()
    }

    func saveCurrentConfigurationToActivePreset() {
        guard canSavePreset else {
            setStatus(
                "Quelle und Ziel müssen verbunden und unterschiedlich sein.",
                isError: true
            )
            return
        }

        settings.presets[activePresetIndex].configuration =
            currentConfiguration
        if settings.presets[activePresetIndex].name
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.presets[activePresetIndex].name =
                "Preset \(activePresetIndex + 1)"
        }
        presets = settings.presets
        persistSettings()
        updateDirtyFlag()
        setStatus(
            "„\(activePresetName)“ wurde ausdrücklich gespeichert.",
            isError: false
        )
    }

    func setAutoStartOutput(_ enabled: Bool) {
        autoStartOutput = enabled
        settings.autoStartOutput = enabled
        persistSettings()

        if enabled {
            manualStopSuppressed = false
            blockReason = nil
            desiredOutput = true
        } else {
            desiredOutput = false
            invalidateStartIfNeeded()
        }
        Task { @MainActor [weak self] in
            await self?.reconcileOutput(
                stopMessage: "Automatische Ausgabe wurde deaktiviert."
            )
        }
    }

    func refreshDisplays() {
        refreshDisplaySnapshot()
        Task { @MainActor [weak self] in
            await self?.reconcileOutput()
        }
    }

    func updatePermissionStatus() {
        permissionGranted = CGPreflightScreenCaptureAccess()
        if permissionGranted {
            let wasBlockedOnPermission = blockReason == .permission
            if wasBlockedOnPermission {
                blockReason = nil
            }
            if lifecycle == .idle || wasBlockedOnPermission {
                setStatus(
                    "Bildschirmaufnahme ist erlaubt.",
                    isError: false
                )
            }
            if didLaunch, desiredOutput {
                Task { @MainActor [weak self] in
                    await self?.reconcileOutput()
                }
            }
        } else if lifecycle != .running {
            setStatus(
                "Bildschirmaufnahme ist nicht erlaubt. Zugriff in den Systemeinstellungen freigeben.",
                isError: true
            )
        }
    }

    func requestPermission() {
        let granted = CGRequestScreenCaptureAccess()
        permissionGranted = granted || CGPreflightScreenCaptureAccess()

        if permissionGranted {
            if blockReason == .permission {
                blockReason = nil
            }
            setStatus(
                "Berechtigung erteilt. Die Ausgabe kann jetzt starten.",
                isError: false
            )
            if desiredOutput {
                Task { @MainActor [weak self] in
                    await self?.reconcileOutput()
                }
            }
        } else {
            blockReason = .permission
            setLifecycle(.blocked)
            setStatus(
                "Berechtigung wurde nicht erteilt. Systemeinstellungen → Datenschutz & Sicherheit → Bildschirmaufnahme öffnen.",
                isError: true
            )
        }
    }

    func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ), NSWorkspace.shared.open(url) else {
            setStatus(
                "Die Systemeinstellungen konnten nicht geöffnet werden.",
                isError: true
            )
            return
        }
    }

    func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        loginItemNeedsApproval = false
        loginItemStatusIsError = false

        switch status {
        case .enabled:
            loginItemEnabled = true
            loginItemStatusText = "Start bei Anmeldung ist registriert."
        case .notRegistered:
            loginItemEnabled = false
            loginItemStatusText = "Start bei Anmeldung ist deaktiviert."
        case .requiresApproval:
            loginItemEnabled = true
            loginItemNeedsApproval = true
            loginItemStatusIsError = true
            loginItemStatusText =
                "Registriert, aber noch in den Systemeinstellungen zu erlauben."
        case .notFound:
            loginItemEnabled = false
            loginItemStatusIsError = true
            loginItemStatusText =
                "Der Anmeldedienst wurde für dieses App-Bundle nicht gefunden."
        @unknown default:
            loginItemEnabled = false
            loginItemStatusIsError = true
            loginItemStatusText = "Unbekannter Anmeldestatus."
        }
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        guard !loginItemBusy else {
            return
        }
        loginItemBusy = true

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try await SMAppService.mainApp.unregister()
                }
                refreshLoginItemStatus()
            } catch {
                refreshLoginItemStatus()
                loginItemStatusIsError = true
                loginItemStatusText =
                    "Änderung fehlgeschlagen: \(error.localizedDescription)"
            }
            loginItemBusy = false
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func start() async {
        manualStopSuppressed = false
        blockReason = nil
        desiredOutput = true
        await reconcileOutput()
    }

    func requestStop(message: String = "Übertragung beendet.") {
        manualStopSuppressed = true
        desiredOutput = false
        blockReason = nil
        invalidateStartIfNeeded()

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if lifecycle == .running || captureSession != nil {
                await stopCommittedOutput(
                    message: message,
                    isError: false
                )
            } else if !isBusy {
                setLifecycle(.idle)
                setStatus(message, isError: false)
            } else {
                setStatus(message, isError: false)
            }
        }
    }

    func shutdown() async {
        displayChangeTask?.cancel()
        selfTestTimeoutTask?.cancel()
        manualStopSuppressed = true
        desiredOutput = false
        blockReason = nil
        invalidateStartIfNeeded()

        if captureSession != nil || lifecycle == .running {
            await stopCommittedOutput(
                message: "App wird beendet.",
                isError: false
            )
        }
    }

    func prepareForTermination() {
        outputController?.close()
        outputController = nil
        captureSession = nil
        activeSource = nil
        activeTarget = nil
    }

    func startSelfTestIfRequested() async {
        guard isSelfTest else {
            return
        }
        refreshDisplaySnapshot()
        guard displays.count >= 2 else {
            setStatus(
                "SELF_TEST_FAIL: Mindestens zwei Monitore werden benötigt.",
                isError: true
            )
            lifecycleLogger.error(
                "SELF_TEST_FAIL: zu wenige Monitore"
            )
            return
        }

        // Use rotation-independent physical/native dimensions so a HiDPI 4K
        // source is not mistaken for a smaller display because its current
        // UI coordinate space is 1920×1080.
        let orderedByArea = displays.sorted {
            ($0.identity.nativeLongEdge * $0.identity.nativeShortEdge)
                < ($1.identity.nativeLongEdge
                    * $1.identity.nativeShortEdge)
        }
        guard let target = orderedByArea.first,
              let source = orderedByArea.last(where: {
                  $0.id != target.id
              }) else {
            return
        }

        workingSourceIdentity = source.identity
        workingTargetIdentity = target.identity
        selectedSourceID = source.id
        selectedTargetID = target.id
        updateDirtyFlag()
        manualStopSuppressed = false
        blockReason = nil
        desiredOutput = true

        lifecycleLogger.notice(
            "SELF_TEST_START: Quelle ID \(source.id, privacy: .public) (\(source.pixelWidth, privacy: .public)x\(source.pixelHeight, privacy: .public)), Ziel ID \(target.id, privacy: .public) (\(target.pixelWidth, privacy: .public)x\(target.pixelHeight, privacy: .public))"
        )
        selfTestTimeoutTask?.cancel()
        selfTestTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !self.selfTestRenderedFrame else {
                return
            }
            self.setStatus(
                "SELF_TEST_FAIL: Innerhalb von 15 Sekunden wurde kein Frame dargestellt.",
                isError: true
            )
            lifecycleLogger.error(
                "SELF_TEST_FAIL: kein dargestellter Frame"
            )
        }

        await reconcileOutput()
    }

    private var currentConfiguration: PresetConfiguration {
        PresetConfiguration(
            source: workingSourceIdentity,
            target: workingTargetIdentity,
            transform: transform
        )
    }

    private func persistSettings() {
        SettingsStore.save(settings, to: defaults)
    }

    private func loadActivePreset() {
        let configuration =
            settings.presets[settings.activePresetIndex].configuration
        workingSourceIdentity = configuration.source
        workingTargetIdentity = configuration.target
        transform = configuration.transform
        outputController?.updateTransform(transform)
        refreshDisplaySnapshot()
        updateDirtyFlag()
    }

    private func updateDirtyFlag() {
        configurationIsDirty =
            currentConfiguration
            != settings.presets[activePresetIndex].configuration
    }

    private func connectionHint(
        identity: PersistentDisplayIdentity?,
        resolvedID: CGDirectDisplayID?
    ) -> String? {
        guard resolvedID == nil, let identity else {
            return nil
        }
        return "Gespeichert, derzeit nicht verbunden: \(identity.localizedName) — \(identity.nativeLongEdge)×\(identity.nativeShortEdge)"
    }

    private func refreshDisplaySnapshot() {
        displays = DisplayCatalog.connectedDisplays()

        if workingSourceIdentity == nil, let first = displays.first {
            workingSourceIdentity = first.identity
        }
        selectedSourceID = DisplayCatalog.resolve(
            workingSourceIdentity,
            among: displays
        )?.id

        if workingTargetIdentity == nil,
           let target = displays.first(where: { $0.id != selectedSourceID }) {
            workingTargetIdentity = target.identity
        }
        selectedTargetID = DisplayCatalog.resolve(
            workingTargetIdentity,
            among: displays
        )?.id

        updateDirtyFlag()
    }

    private func resolvedDisplays()
        -> (source: DisplayDescriptor, target: DisplayDescriptor, screen: NSScreen)? {
        guard let source = DisplayCatalog.resolve(
            workingSourceIdentity,
            among: displays
        ),
        let target = DisplayCatalog.resolve(
            workingTargetIdentity,
            among: displays
        ),
        source.id != target.id,
        let targetScreen = DisplayCatalog.screen(withID: target.id) else {
            return nil
        }
        return (source, target, targetScreen)
    }

    private func reconcileOutput(
        stopMessage: String = "Übertragung beendet."
    ) async {
        guard didLaunch || isSelfTest else {
            return
        }

        guard desiredOutput, !manualStopSuppressed else {
            if lifecycle == .running || captureSession != nil {
                await stopCommittedOutput(
                    message: stopMessage,
                    isError: false
                )
            } else if !isBusy {
                setLifecycle(.idle)
                updateIdleStatus()
            }
            return
        }

        if blockReason != nil {
            setLifecycle(.blocked)
            return
        }

        permissionGranted = CGPreflightScreenCaptureAccess()
        guard permissionGranted else {
            blockReason = .permission
            let message =
                "Automatischer Start wartet auf Bildschirmaufnahme-Berechtigung. Bitte Zugriff erlauben."
            if lifecycle == .running || captureSession != nil {
                await stopCommittedOutput(
                    message: message,
                    isError: true
                )
            } else {
                setLifecycle(.blocked)
                setStatus(message, isError: true)
            }
            return
        }

        guard let resolved = resolvedDisplays() else {
            if case .starting = lifecycle {
                operationEpoch &+= 1
                setStatus(waitingStatusText, isError: false)
                return
            }
            if lifecycle == .running || captureSession != nil {
                await stopCommittedOutput(
                    message: waitingStatusText,
                    isError: false
                )
            } else if lifecycle != .stopping {
                setLifecycle(.waiting)
                setStatus(waitingStatusText, isError: false)
            }
            return
        }

        if lifecycle == .running {
            guard let activeSource, let activeTarget,
                  activeSource.id == resolved.source.id,
                  activeTarget.id == resolved.target.id,
                  activeSource.pixelWidth == resolved.source.pixelWidth,
                  activeSource.pixelHeight == resolved.source.pixelHeight,
                  activeTarget.pixelWidth == resolved.target.pixelWidth,
                  activeTarget.pixelHeight == resolved.target.pixelHeight else {
                await stopCommittedOutput(
                    message: "Monitorkonfiguration geändert; Ausgabe wird neu gestartet.",
                    isError: false
                )
                return
            }
            outputController?.updateTargetScreen(resolved.screen)
            outputController?.updateTransform(transform)
            return
        }

        switch lifecycle {
        case .starting, .stopping:
            return
        case .idle, .waiting, .blocked:
            await startResolvedOutput(
                source: resolved.source,
                target: resolved.target,
                targetScreen: resolved.screen
            )
        case .running:
            break
        }
    }

    private func startResolvedOutput(
        source: DisplayDescriptor,
        target: DisplayDescriptor,
        targetScreen: NSScreen
    ) async {
        operationEpoch &+= 1
        let epoch = operationEpoch
        pendingCaptureStop = nil
        pendingRenderingFailure = nil
        setLifecycle(.starting(epoch))
        setStatus("Aufnahme wird vorbereitet …", isError: false)

        var localOutput: OutputWindowController?
        var localSession: CaptureSession?

        do {
            let output = try OutputWindowController(
                screen: targetScreen,
                transform: transform,
                onEscape: { [weak self] in
                    self?.requestStop(
                        message: "Übertragung mit Escape beendet."
                    )
                },
                onFirstFrame: { [weak self] path in
                    self?.firstFrameWasRendered(
                        epoch: epoch,
                        path: path
                    )
                },
                onFailure: { [weak self] message in
                    self?.renderingFailed(
                        epoch: epoch,
                        message: message
                    )
                }
            )
            localOutput = output

            let session = try await CaptureSession(
                sourceDisplayID: source.id,
                targetMaximumDimension: max(
                    target.pixelWidth,
                    target.pixelHeight
                ),
                frameReceiver: output.frameReceiver,
                onUnexpectedStop: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.captureStoppedUnexpectedly(
                            epoch: epoch,
                            message: message
                        )
                    }
                }
            )
            localSession = session
            try await session.start()

            if let pendingCaptureStop,
               pendingCaptureStop.epoch == epoch {
                throw AppModelError.captureStoppedDuringStart(
                    pendingCaptureStop.message
                )
            }
            if let pendingRenderingFailure,
               pendingRenderingFailure.epoch == epoch {
                throw AppModelError.renderingFailedDuringStart(
                    pendingRenderingFailure.message
                )
            }

            guard epoch == operationEpoch,
                  desiredOutput,
                  !manualStopSuppressed else {
                try? await session.stop()
                output.close()
                if lifecycle == .starting(epoch) {
                    setLifecycle(.idle)
                }
                await reconcileOutput()
                return
            }

            refreshDisplaySnapshot()
            guard let current = resolvedDisplays(),
                  current.source.id == source.id,
                  current.target.id == target.id,
                  current.source.pixelWidth == source.pixelWidth,
                  current.source.pixelHeight == source.pixelHeight,
                  current.target.pixelWidth == target.pixelWidth,
                  current.target.pixelHeight == target.pixelHeight else {
                throw AppModelError.displayConfigurationChangedDuringStart
            }

            output.updateTargetScreen(current.screen)
            output.updateTransform(transform)
            captureSession = session
            outputController = output
            localSession = nil
            localOutput = nil
            activeSource = source
            activeTarget = target
            pendingCaptureStop = nil
            pendingRenderingFailure = nil
            setLifecycle(.running)
            output.show()
            setStatus(
                "Übertragung läuft. Mit „Stoppen“ oder Escape beenden.",
                isError: false
            )
        } catch {
            let startError = error
            if let localSession {
                try? await localSession.stop()
            }
            localOutput?.close()
            pendingCaptureStop = nil
            pendingRenderingFailure = nil

            guard epoch == operationEpoch else {
                if lifecycle == .starting(epoch) {
                    setLifecycle(.idle)
                }
                await reconcileOutput()
                return
            }

            refreshDisplaySnapshot()
            if let _ = resolvedDisplays() {
                blockReason = .capture
                setLifecycle(.blocked)
                setStatus(
                    "Start fehlgeschlagen: \(startError.localizedDescription) Erneut mit „Übertragung starten“ versuchen.",
                    isError: true
                )
            } else {
                blockReason = nil
                setLifecycle(.waiting)
                setStatus(waitingStatusText, isError: false)
            }
        }
    }

    private func stopCommittedOutput(
        message: String,
        isError: Bool
    ) async {
        guard lifecycle != .stopping else {
            return
        }

        operationEpoch &+= 1
        let session = captureSession
        let output = outputController
        captureSession = nil
        outputController = nil
        activeSource = nil
        activeTarget = nil
        pendingCaptureStop = nil
        pendingRenderingFailure = nil
        setLifecycle(.stopping)
        output?.close()

        var stopError: (any Error)?
        if let session {
            do {
                try await session.stop()
            } catch {
                stopError = error
            }
        }

        if blockReason != nil {
            setLifecycle(.blocked)
            setStatus(message, isError: isError)
        } else if desiredOutput, !manualStopSuppressed {
            setLifecycle(.idle)
            if let stopError {
                setStatus(
                    "\(message) Freigabe meldete: \(stopError.localizedDescription)",
                    isError: true
                )
            } else {
                setStatus(message, isError: isError)
            }
            await reconcileOutput()
        } else {
            setLifecycle(.idle)
            if let stopError, !isError {
                setStatus(
                    "\(message) Freigabe meldete: \(stopError.localizedDescription)",
                    isError: true
                )
            } else {
                setStatus(message, isError: isError)
            }
        }
    }

    private func captureStoppedUnexpectedly(
        epoch: UInt64,
        message: String
    ) {
        guard epoch == operationEpoch else {
            return
        }
        if lifecycle == .starting(epoch) {
            pendingCaptureStop = (epoch, message)
            return
        }
        guard lifecycle == .running else {
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, epoch == operationEpoch else {
                return
            }
            refreshDisplaySnapshot()
            if let _ = resolvedDisplays() {
                blockReason = .capture
                await stopCommittedOutput(
                    message: "Die Bildschirmaufnahme wurde beendet: \(message) Erneut mit „Übertragung starten“ versuchen.",
                    isError: true
                )
            } else {
                blockReason = nil
                await stopCommittedOutput(
                    message: waitingStatusText,
                    isError: false
                )
            }
        }
    }

    private func renderingFailed(
        epoch: UInt64,
        message: String
    ) {
        guard epoch == operationEpoch else {
            return
        }
        if lifecycle == .starting(epoch) {
            pendingRenderingFailure = (epoch, message)
            return
        }
        guard lifecycle == .running else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self, epoch == operationEpoch else {
                return
            }
            blockReason = .capture
            await stopCommittedOutput(
                message: "Die Bildausgabe ist fehlgeschlagen: \(message) Erneut mit „Übertragung starten“ versuchen.",
                isError: true
            )
        }
    }

    private func firstFrameWasRendered(
        epoch: UInt64,
        path: RenderingPath
    ) {
        guard epoch == operationEpoch else {
            return
        }
        guard isSelfTest else {
            if lifecycle == .running {
                setStatus(
                    "Übertragung läuft (\(path.rawValue)). Mit „Stoppen“ oder Escape beenden.",
                    isError: false
                )
            }
            return
        }
        selfTestRenderedFrame = true
        selfTestTimeoutTask?.cancel()
        setStatus(
            "SELF_TEST_PASS: \(path.rawValue) stellt Frames dar.",
            isError: false
        )
        lifecycleLogger.notice(
            "SELF_TEST_PASS: \(path.rawValue, privacy: .public), Ziel ID \(self.activeTarget?.id ?? 0, privacy: .public)"
        )
    }

    private var waitingStatusText: String {
        let sourceMissing =
            workingSourceIdentity != nil && selectedSourceID == nil
        let targetMissing =
            workingTargetIdentity != nil && selectedTargetID == nil

        if workingSourceIdentity == nil || workingTargetIdentity == nil {
            return "Aktives Preset ist noch nicht vollständig konfiguriert."
        }
        if sourceMissing && targetMissing {
            return "Warte ruhig auf Quell- und Zielmonitor …"
        }
        if sourceMissing {
            return "Warte ruhig auf den gespeicherten Quellmonitor …"
        }
        if targetMissing {
            return "Warte ruhig auf den gespeicherten Zielmonitor …"
        }
        return "Warte auf eine eindeutige, unterschiedliche Monitorzuordnung …"
    }

    private func invalidateStartIfNeeded() {
        if case .starting = lifecycle {
            operationEpoch &+= 1
        }
    }

    private func setLifecycle(_ newValue: Lifecycle) {
        lifecycle = newValue
        isRunning = newValue == .running
        switch newValue {
        case .starting, .stopping:
            isBusy = true
        case .idle, .waiting, .running, .blocked:
            isBusy = false
        }
    }

    private func updateIdleStatus() {
        guard lifecycle == .idle || lifecycle == .waiting else {
            return
        }
        if displays.count < 2 {
            setStatus(
                "Mindestens zwei angeschlossene Monitore werden benötigt.",
                isError: false
            )
        } else if !permissionGranted {
            setStatus(
                "Bildschirmaufnahme ist noch nicht erlaubt.",
                isError: true
            )
        } else if selectionsAreIdentical {
            setStatus(
                "Quelle und Ziel müssen unterschiedlich sein.",
                isError: true
            )
        } else {
            setStatus(
                "\(displays.count) Monitore erkannt. Änderungen mit „Preset speichern“ sichern.",
                isError: false
            )
        }
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusText = text
        statusIsError = isError
    }

    @objc
    private func screenParametersDidChange(_ notification: Notification) {
        displayChangeTask?.cancel()
        displayChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else {
                return
            }
            refreshDisplaySnapshot()
            await reconcileOutput()
        }
    }

    @objc
    private func applicationDidBecomeActive(_ notification: Notification) {
        updatePermissionStatus()
        refreshLoginItemStatus()
    }
}
