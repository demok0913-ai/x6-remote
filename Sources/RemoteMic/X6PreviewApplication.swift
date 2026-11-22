#if X6_ADAPTER_PREVIEW
import AppKit
import AVFoundation
import IOKit.hid
import SwiftUI
import UniformTypeIdentifiers

/// A narrow test entrance in the original SayAll executable, not a replacement app.
/// The regular model, updater, settings and Bluetooth path are never instantiated.
enum X6PreviewApplication {
    @MainActor
    static func run() {
        // Fail closed if a preview-compiled executable is accidentally packaged as stable.
        guard Bundle.main.bundleIdentifier == X6PreviewPolicy.bundleIdentifier else {
            fputs("X6 preview requires its isolated app bundle.\n", stderr)
            return
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(X6PreviewPolicy.storageDirectory, isDirectory: true)
        guard case let .acquired(lock) = ApplicationInstanceLock.acquire(
            at: base.appendingPathComponent(".app-instance.lock")) else { return }
        let app = NSApplication.shared
        let delegate = X6PreviewDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .aqua)
        withExtendedLifetime(lock) {
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

@MainActor
private final class X6PreviewDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    // run() verifies the preview bundle ID before constructing this delegate.
    // The standard domain is already isolated by that ID; using our own ID as
    // a suite name returns nil on macOS and must never be force-unwrapped.
    private let mappingDefaults = UserDefaults.standard
    private lazy var settings = AppSettings(defaults: mappingDefaults)
    private lazy var localization = LocalizationStore(settings: settings)
    private let interactions = RemoteButtonInteractionController()
    private var router = X6MappingRouter()
    private var learnedKey: X6HIDObservationDecoder.Key?
    private let slots = NSPopUpButton()
    private let triggers = NSPopUpButton()
    private var triggerSegments: NSSegmentedControl?
    private let actions = NSPopUpButton()
    private let categoryButtons = NSSegmentedControl()
    private let editorSummary = NSTextField(wrappingLabelWithString: "")
    private let bindingSummary = NSTextField(wrappingLabelWithString: "")
    private let shortcutEditor = NSButton()
    private let applicationEditor = NSButton()
    private let saveEditor = NSButton()
    private var actionGroup = 0
    private var visibleActions: [ButtonAction] = []
    private func group(for action: ButtonAction) -> Int {
        if action == .customShortcut { return 1 }
        if action.category == .applications { return 2 }
        if action.category == .systemAndMedia { return 3 }
        return 0
    }
    private func rebuildActions() {
        visibleActions = supportedActions.filter { group(for: $0) == actionGroup }
        actions.removeAllItems()
        actions.addItems(withTitles: visibleActions.map { $0.displayName(using: localization) })
        if let index = visibleActions.firstIndex(of: configured.action) { actions.selectItem(at: index) }
        categoryButtons.selectedSegment = actionGroup
    }
    @objc private func selectCategory(_ sender: NSSegmentedControl) {
        actionGroup = sender.selectedSegment
        rebuildActions()
        pauseMappings(reason: "选择此分类下的功能；保存后生效。")
        if !visibleActions.contains(configured.action), let first = visibleActions.first {
            configured.action = first
        }
        updateConfiguredLabel()
    }
    private let sourceLabel = NSTextField(wrappingLabelWithString: "尚未录入实体按键")
    private let mappingStatus = NSTextField(wrappingLabelWithString: "映射已暂停。先选配置位置，再录入对应的 X6 实体键。")
    private let shortcutLabel = NSTextField(wrappingLabelWithString: "")
    private var shortcutPanel: NSPanel?
    private var configured = ConfiguredButtonAction.disabled
    private var supportedActions: [ButtonAction] {
        ButtonAction.allCases.filter { !$0.isAppInternal && $0 != .combinationAction && $0 != .appSwitcher && $0 != .openRemoteMic }
    }
    private var selectedSlot: RemoteButton { RemoteButton.xiaomiCases[max(0, slots.indexOfSelectedItem)] }
    private var selectedTrigger: ButtonTrigger { ButtonTrigger.allCases[max(0, triggers.indexOfSelectedItem)] }
    private let hid = X6PreviewHID()
    private let audio = X6PreviewAudio()
    private let status = NSTextField(wrappingLabelWithString: "尚未启动，未采集声音。")
    private let hidStatus = NSTextField(wrappingLabelWithString: "按键检测未开启。")
    private let inputChoices = NSStackView()
    private let inputStatus = NSTextField(wrappingLabelWithString: "请选择要接入虚拟麦的 USB 输入。")
    private var availableInputs: [AudioDeviceInfo] = []
    private var chosenInputUID: String?
    private var window: NSWindow?
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var applicationLaunchObserver: NSObjectProtocol?
    private var requestGeneration = 0
    private var busy = false
    private var selectedInputUID: String?
    private var selectedOutputUID: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: min(820, (NSScreen.main?.visibleFrame.height ?? 860) - 50)),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "X6遥控"
        window.delegate = self
        window.contentView = makeCardInterface()
        audio.onStatus = { [weak self] message, active in
            self?.status.stringValue = message
            self?.busy = active
            if !active { self?.selectedInputUID = nil; self?.selectedOutputUID = nil }
            self?.updateInputButtons()
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.router.suspendForSleep()
                self.interactions.cancelAll(reason: "system_sleep")
                self.hid.stop()
                self.requestGeneration += 1
                self.mappingStatus.stringValue = "电脑睡眠中，唤醒后恢复原来的映射状态。"
                AppLogger.shared.write("X6 MAPPING phase=suspended reason=system_sleep")
                self.audio.shutdown(reason: "system_sleep")
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.router.resumeAfterSleep()
                if self.mappingDefaults.bool(forKey: "x6MappingsEnabled") {
                    self.activateMappings(requestPermission: false)
                }
            }
        }
        applicationLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self,
                      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == "com.hd838a.RemoteMic" else { return }
                self.requestGeneration += 1
                self.audio.shutdown(reason: "stable_app_launched")
                self.busy = false
                self.selectedInputUID = nil
                self.selectedOutputUID = nil
                self.status.stringValue = "其他语音程序已启动，音频路由已停止。"
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.window = window
        hid.onEdge = { [weak self] edge in
            MainActor.assumeIsolated { self?.route(edge) }
        }
        hid.onDeviceRemoved = { [weak self] device in
            MainActor.assumeIsolated {
                guard let self else { return }
                let cancelled = self.router.removeDevice(device)
                for binding in cancelled {
                    if let button = RemoteButton(rawValue: binding.action) {
                        self.interactions.cancel(button, reason: "x6_interface_removed")
                    }
                }
                if self.hid.connectedCount == 0 {
                    self.interactions.cancelAll(reason: "x6_receiver_removed")
                }
                if self.router.enabled {
                    self.mappingStatus.stringValue = "接收器接口变化，映射保持开启，等待可用接口。"
                }
                AppLogger.shared.write("X6 MAPPING phase=waiting reason=interface_removed enabled=\(self.router.enabled)")
            }
        }
        let resumeOnLaunch = mappingDefaults.bool(forKey: "x6MappingsEnabled")
        loadAssignments()
        if resumeOnLaunch {
            activateMappings(requestPermission: false)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }


    private let selectedHeading = NSTextField(labelWithString: "选择一个按键")
    private let connectionHeading = NSTextField(labelWithString: "正在连接…")
    private var remoteCanvas: NSHostingView<X6RemoteCanvas>?

    private func column(_ views: [NSView], spacing: CGFloat = 16) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }

    private func card(_ views: [NSView], width: CGFloat) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.white.cgColor
        box.layer?.cornerRadius = 20
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor(white: 0.88, alpha: 1).cgColor
        let stack = column(views, spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -24)
        ])
        return box
    }

    private func heading(_ text: String, size: CGFloat = 20) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: .semibold)
        return label
    }

    private func makeCardInterface() -> NSView {
        slots.addItems(withTitles: RemoteButton.xiaomiCases.map { $0.displayName(using: localization) })
        slots.target = self; slots.action = #selector(selectMapping)
        triggers.addItems(withTitles: ButtonTrigger.allCases.map { $0.displayName(using: localization) })
        triggers.target = self; triggers.action = #selector(selectMapping)
        rebuildActions()
        actions.target = self; actions.action = #selector(selectAction)
        actions.widthAnchor.constraint(equalToConstant: 298).isActive = true
        slots.widthAnchor.constraint(equalToConstant: 298).isActive = true
        selectedHeading.font = .systemFont(ofSize: 26, weight: .bold)
        connectionHeading.font = .systemFont(ofSize: 13, weight: .medium)
        let title = heading("X6遥控", size: 25)
        let enable = NSButton(title: "开启映射", target: self, action: #selector(enableMappings))
        let pause = NSButton(title: "暂停", target: self, action: #selector(pauseMappingButton))
        let header = NSStackView(views: [title, connectionHeading, NSView(), enable, pause])
        header.spacing = 18
        let canvas = NSHostingView(rootView: X6RemoteCanvas(selected: selectedSlot.rawValue) { [weak self] raw in
            guard let self, let index = RemoteButton.xiaomiCases.firstIndex(where: { $0.rawValue == raw }) else { return }
            self.slots.selectItem(at: index)
            self.selectMapping()
        })
        remoteCanvas = canvas
        canvas.widthAnchor.constraint(equalToConstant: 318).isActive = true
        canvas.heightAnchor.constraint(equalToConstant: 610).isActive = true
        let middle = card([heading("点击按键，设置功能", size: 18), canvas], width: 362)
        var common: [NSView] = [heading("常用映射")]
        for (name, raw) in [("←  左键", "left"), ("→  右键", "right"), ("↩  返回键", "back"), ("＋  音量加", "volume_up"), ("－  音量减", "volume_down")] {
            let button = NSButton(title: name, target: self, action: #selector(selectCardButton(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(raw)
            button.bezelStyle = .rounded
            common.append(button)
        }
        let hint = NSTextField(wrappingLabelWithString: "点击中间的遥控器按键，右侧即可设置功能。\n\n编辑时会暂停映射，点击“保存并启用映射”后立即生效。")
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .secondaryLabelColor
        let add = NSButton(title: "新增实体按键", target: self, action: #selector(addSource))
        let left = column([card(common, width: 244), card([heading("使用提示", size: 17), hint, add], width: 244)])
        let shortcut = shortcutEditor
        shortcut.title = "设置快捷键…"; shortcut.target = self; shortcut.action = #selector(editShortcut)
        let application = applicationEditor
        application.title = "选择应用…"; application.target = self; application.action = #selector(chooseApplication)
        let save = saveEditor
        save.title = "保存并启用映射"; save.target = self; save.action = #selector(saveMapping)
        save.bezelStyle = .rounded; save.bezelColor = .controlAccentColor
        save.widthAnchor.constraint(equalToConstant: 298).isActive = true
        let learn = NSButton(title: "录入实体按键", target: self, action: #selector(learnSource))
        let remove = NSButton(title: "解除对应", target: self, action: #selector(removeSource))
        let segments = NSSegmentedControl(labels: ButtonTrigger.allCases.map { $0.displayName(using: localization) }, trackingMode: .selectOne, target: self, action: #selector(selectTriggerSegment(_:)))
        segments.selectedSegment = 0
        segments.widthAnchor.constraint(equalToConstant: 298).isActive = true
        triggerSegments = segments
        categoryButtons.segmentCount = 4
        for (index, title) in ["基础按键", "快捷键", "应用", "系统媒体"].enumerated() {
            categoryButtons.setLabel(title, forSegment: index)
        }
        categoryButtons.trackingMode = .selectOne
        categoryButtons.target = self; categoryButtons.action = #selector(selectCategory(_:))
        categoryButtons.widthAnchor.constraint(equalToConstant: 298).isActive = true
        bindingSummary.font = .systemFont(ofSize: 13)
        bindingSummary.textColor = .secondaryLabelColor
        editorSummary.font = .systemFont(ofSize: 14, weight: .medium)
        shortcut.title = "快捷键配置…"
        application.title = "应用配置…"
        let right = card([selectedHeading, bindingSummary, slots, segments,
            categoryButtons, actions, shortcutLabel,
            NSStackView(views: [shortcut, application]), editorSummary, save,
            NSStackView(views: [learn, remove]), mappingStatus], width: 342)
        let body = NSStackView(views: [left, middle, right])
        body.alignment = .top; body.spacing = 18
        mappingStatus.font = .systemFont(ofSize: 13)
        mappingStatus.textColor = .secondaryLabelColor
        let diagnostics = column([sourceLabel, hidStatus,
            NSButton(title: "停止全部检测", target: self, action: #selector(stopAll))])
        diagnostics.isHidden = true
        let disclose = NSButton(title: "诊断信息", target: self, action: #selector(toggleDiagnostics(_:)))
        disclose.setButtonType(.switch)
        diagnosticContent = diagnostics
        let footer = NSStackView(views: [disclose, NSView(), NSButton(title: "退出 X6遥控", target: NSApp, action: #selector(NSApplication.terminate(_:)))])
        let root = column([header, body, footer, diagnostics], spacing: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        let document = X6MappingDocumentView()
        document.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
        let scroll = NSScrollView()
        scroll.documentView = document; scroll.hasVerticalScroller = true
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.windowBackgroundColor
        return scroll
    }

    @objc private func selectTriggerSegment(_ sender: NSSegmentedControl) {
        triggers.selectItem(at: sender.selectedSegment)
        selectMapping()
    }
    private var diagnosticContent: NSView?
    @objc private func toggleDiagnostics(_ sender: NSButton) {
        diagnosticContent?.isHidden = sender.state != .on
    }
    @objc private func selectCardButton(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let index = RemoteButton.xiaomiCases.firstIndex(where: { $0.rawValue == raw }) else { return }
        slots.selectItem(at: index)
        selectMapping()
    }

    private func loadAssignments() {
        if let data = mappingDefaults.data(forKey: "x6SourceAssignments") {
            do {
                let bindings = try JSONDecoder().decode([X6MappingRouter.Binding].self, from: data)
                guard Set(bindings.map(\.key)).count == bindings.count,
                      Set(bindings.map(\.action)).count == bindings.count,
                      bindings.allSatisfy({ binding in RemoteButton.xiaomiCases.contains { $0.rawValue == binding.action } }) else {
                    throw CocoaError(.coderReadCorrupt)
                }
                router.bindings = bindings
            } catch { mappingStatus.stringValue = "实体键对应记录无法读取，请重新录入；映射保持暂停。" }
        }
        selectMapping()
    }

    private func persistAssignments(_ bindings: [X6MappingRouter.Binding]) throws {
        let data = try JSONEncoder().encode(bindings)
        mappingDefaults.set(data, forKey: "x6SourceAssignments")
        router.bindings = bindings
    }

    @objc private func selectMapping() {
        pauseMappings(reason: "编辑中，映射已暂停。")
        selectedHeading.stringValue = selectedSlot.displayName(using: localization)
        remoteCanvas?.rootView.selected = selectedSlot.rawValue
        refreshSlotTitles()
        learnedKey = router.bindings.first { $0.action == selectedSlot.rawValue }?.key
        sourceLabel.stringValue = learnedKey.map { String(format: "实体键：Page 0x%04X / Usage 0x%04X", $0.page, $0.usage) } ?? "此配置位置尚未对应 X6 实体键"
        configured = settings.configuredAction(for: selectedSlot, trigger: selectedTrigger)
        if !supportedActions.contains(configured.action) { configured = .disabled }
        actionGroup = group(for: configured.action)
        rebuildActions()
        updateConfiguredLabel()
    }

    private func refreshSlotTitles() {
        for (index, button) in RemoteButton.xiaomiCases.enumerated() {
            let occupied = router.bindings.contains { $0.action == button.rawValue }
            slots.item(at: index)?.title = button.displayName(using: localization) + (occupied ? " · 已绑定" : " · 空位")
        }
    }

    @objc private func selectAction() {
        pauseMappings(reason: "功能已修改，点击保存。")
        guard visibleActions.indices.contains(actions.indexOfSelectedItem) else { return }
        configured.action = visibleActions[actions.indexOfSelectedItem]
        updateConfiguredLabel()
    }

    private func updateConfiguredLabel() {
        bindingSummary.stringValue = learnedKey == nil ? "未录入：请先录入对应的实体键" : "实体按键已绑定"
        saveEditor.isEnabled = learnedKey != nil
        editorSummary.stringValue = "\(selectedSlot.displayName(using: localization)) · \(selectedTrigger.displayName(using: localization)) → \(configured.action.displayName(using: localization))"
        shortcutLabel.stringValue = configured.action == .customShortcut
            ? (configured.shortcut?.detailedDisplayName(using: localization) ?? "尚未设置快捷键")
            : (configured.action == .openCustomApplication ? (settings.customApplicationProfile(id: configured.applicationProfileID)?.displayName ?? "尚未选择应用") : "")
    }

    @objc private func learnSource() {
        guard !router.bindings.contains(where: { $0.action == selectedSlot.rawValue }) else {
            pauseMappings(reason: "此位置已有绑定。新增请点“新增按键”；换绑请先点“解除实体键对应”。")
            return
        }
        pauseMappings(reason: "请按下并松开要录入当前配置位置的 X6 实体键。")
        startHID()
        guard hid.isRunning else { return }
        router.armLearning()
    }

    @objc private func addSource() {
        guard let index = RemoteButton.xiaomiCases.firstIndex(where: { button in
            !router.bindings.contains { $0.action == button.rawValue }
        }) else {
            pauseMappings(reason: "当前按键位置已全部使用，请先解除不需要的对应。")
            return
        }
        slots.selectItem(at: index)
        selectMapping()
        learnSource()
    }

    private func route(_ edge: X6HIDObservationDecoder.Edge) {
        let result = router.consume(edge)
        if let key = result.learned {
            let assignment = X6MappingRouter.Binding(key: key, name: selectedSlot.rawValue,
                action: selectedSlot.rawValue, shortcutCode: nil, shortcutFlags: 0, shortcutLabel: "")
            guard let bindings = X6MappingRouter.adding(assignment, to: router.bindings) else {
                mappingStatus.stringValue = "该实体键或配置位置已有对应，原绑定未改动。请换一个实体键，或先明确解除原对应。"
                return
            }
            do {
                try persistAssignments(bindings)
                learnedKey = key
                refreshSlotTitles()
                sourceLabel.stringValue = String(format: "已对应：Page 0x%04X / Usage 0x%04X", key.page, key.usage)
                mappingStatus.stringValue = "新按键已录入，已有按键绑定保留。选择功能后保存，再开启映射。"
            } catch { mappingStatus.stringValue = "实体键对应保存失败，映射保持暂停。" }
            return
        }
        if let binding = result.binding, let button = RemoteButton(rawValue: binding.action) {
            handleMapped(.press, button: button)
        }
        if let binding = result.released, let button = RemoteButton(rawValue: binding.action) {
            handleMapped(.release, button: button)
        }
    }

    private func handleMapped(_ phase: RemoteButtonPhase, button: RemoteButton) {
        interactions.handle(phase, button: button,
            snapshot: settings.interactionSnapshot(for: button).withMode(.once),
            valid: { [weak self] in self?.router.enabled == true },
            perform: { [weak self] trigger, configured in
                guard let self, self.router.enabled else { return false }
                let action = configured.normalizedForExecution
                guard self.supportedActions.contains(action.action) else { return false }
                if action.action.presetApplication == nil && action.action != .openCustomApplication &&
                    action.action != .disabled && !KeyboardInjector.isAccessibilityTrusted {
                    self.mappingStatus.stringValue = "此功能需要 X6遥控的辅助功能权限，其他映射保持开启。"
                    return false
                }
                let submitted = KeyboardInjector.send(action.action, shortcut: action.shortcut,
                    applicationProfile: self.settings.customApplicationProfile(id: action.applicationProfileID))
                self.mappingStatus.stringValue = submitted ? "已执行：\(button.displayName(using: self.localization)) · \(trigger.displayName(using: self.localization))" : "功能未能执行，请检查辅助功能权限或目标应用。"
                return submitted
            })
    }

    @objc private func saveMapping() {
        pauseMappings(reason: "映射已暂停。")
        guard learnedKey != nil else { mappingStatus.stringValue = "请先录入当前配置位置对应的 X6 实体键。"; return }
        guard supportedActions.contains(configured.action) else { return }
        guard configured.action != .customShortcut || configured.shortcut != nil else { mappingStatus.stringValue = "请先设置快捷键。"; return }
        guard configured.action != .openCustomApplication || settings.customApplicationProfile(id: configured.applicationProfileID) != nil else { mappingStatus.stringValue = "请先选择应用。"; return }
        settings.setBaseBinding(configured, for: selectedSlot, trigger: selectedTrigger, profileID: settings.selectedRemoteProfileID)
        activateMappings(requestPermission: true)
        if router.enabled { mappingStatus.stringValue = "已保存并启用：\(editorSummary.stringValue)" }
        else { mappingStatus.stringValue = "已保存；按键检测尚未启动，请检查权限。" }
    }

    @objc private func removeSource() {
        pauseMappings(reason: "映射已暂停。")
        do { try persistAssignments(router.bindings.filter { $0.action != selectedSlot.rawValue }); selectMapping() }
        catch { mappingStatus.stringValue = "解除对应失败。" }
    }

    @objc private func enableMappings() {
        activateMappings(requestPermission: true)
    }

    private func activateMappings(requestPermission: Bool) {
        guard !router.bindings.isEmpty else { mappingStatus.stringValue = "请先录入至少一个实体键。"; return }
        pauseMappings(reason: "正在开启映射。", remember: false)
        mappingDefaults.set(true, forKey: "x6MappingsEnabled")
        startHID(requestPermission: requestPermission)
        guard hid.isRunning else {
            AppLogger.shared.write("X6 MAPPING phase=unavailable reason=hid_or_permission")
            return
        }
        router.enabled = true
        mappingDefaults.set(true, forKey: "x6MappingsEnabled")
        mappingStatus.stringValue = "映射已开启；重启、唤醒或接收器重连后自动恢复。"
        AppLogger.shared.write("X6 MAPPING phase=enabled bindings=\(router.bindings.count)")
    }

    @objc private func pauseMappingButton() {
        mappingDefaults.set(false, forKey: "x6MappingsEnabled")
        pauseMappings(reason: "映射已暂停；重启和唤醒后也保持暂停。")
    }
    private func pauseMappings(reason: String, remember: Bool = true) {
        if remember { mappingDefaults.set(false, forKey: "x6MappingsEnabled") }
        router.reset()
        interactions.cancelAll(reason: "x6_mapping_paused")
        mappingStatus.stringValue = reason
    }

    @objc private func editShortcut() {
        pauseMappings(reason: "设置快捷键中，映射已暂停。")
        guard let window else { return }
        if let old = shortcutPanel { window.endSheet(old); old.close() }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 960, height: 590), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "X6遥控 · 快捷键配置"
        let close: () -> Void = { [weak self, weak panel] in
            guard let panel else { return }
            self?.window?.endSheet(panel); panel.orderOut(nil)
            self?.shortcutPanel = nil
        }
        panel.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 14) {
            Text("选择快捷键").font(.title2.bold())
            Text("可选常用组合，或切换到标准键盘：先选修饰键，再点目标按键。选择后回到主界面，点击保存并启用。").font(.system(size: 13))
            ScrollView([.horizontal, .vertical]) {
                KeyboardShortcutPicker(shortcut: self.configured.shortcut) { [weak self] shortcut in
                    guard let self else { return }
                    self.configured.shortcut = shortcut
                    self.configured.action = .customShortcut
                    self.actionGroup = 1
                    self.rebuildActions()
                    self.updateConfiguredLabel()
                    close()
                }.frame(width: 900, alignment: .topLeading).padding(4)
            }
            HStack { Spacer(); Button("取消", action: close).keyboardShortcut(.cancelAction) }
        }.padding(20).environmentObject(localization))
        shortcutPanel = panel
        window.beginSheet(panel)
    }

    @objc private func chooseApplication() {
        pauseMappings(reason: "选择应用中，映射已暂停。")
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return }
        let profile = CustomApplicationProfile(displayName: url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: identifier, applicationPath: url.path)
        configured.applicationProfileID = settings.addCustomApplicationProfile(profile)
        configured.action = .openCustomApplication
        actionGroup = 2
        rebuildActions()
        updateConfiguredLabel()
    }

    private func startHID(requestPermission: Bool = true) {
        // Automatic recovery uses existing permission only; it never opens a permission prompt.
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted ||
                (requestPermission && IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)) else {
            hidStatus.stringValue = "按键检测权限未授予。可在系统设置中为 X6遥控授权后再试。"
            return
        }
        let result = hid.start()
        hidStatus.stringValue = result == kIOReturnSuccess ? "按键检测已开启。" : "HID 打开失败：\(result)"
    }

    @objc private func reloadInputs() {
        let inputs = CoreAudioDeviceCatalog.inputDevices().filter(X6PreviewAudio.isEligibleInput)
            .sorted { $0.uid < $1.uid }
        let changed = inputs != availableInputs
        availableInputs = inputs
        if X6PreviewPolicy.selectedInputIndex(uids: inputs.map(\.uid), selectedUID: chosenInputUID) == nil {
            chosenInputUID = nil
        }
        if changed || inputChoices.arrangedSubviews.isEmpty {
            for view in inputChoices.arrangedSubviews {
                inputChoices.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for (index, device) in inputs.enumerated() {
                let button = NSButton(radioButtonWithTitle: "\(device.name) · USB 输入 \(index + 1)",
                    target: self, action: #selector(chooseInput(_:)))
                button.font = .systemFont(ofSize: 13)
                button.tag = index
                inputChoices.addArrangedSubview(button)
            }
        }
        inputStatus.stringValue = inputs.isEmpty
            ? "当前未列出 USB 音频输入，可点击刷新。"
            : "选择正在使用的 USB 麦克风；按系统显示的实际名称选择。"
        updateInputButtons()
    }

    @objc private func chooseInput(_ sender: NSButton) {
        guard !busy, availableInputs.indices.contains(sender.tag) else { return }
        chosenInputUID = availableInputs[sender.tag].uid
        updateInputButtons()
        status.stringValue = "已选择输入。点击虚拟麦按钮后才会请求权限并采音。"
    }

    private func updateInputButtons() {
        for case let button as NSButton in inputChoices.arrangedSubviews {
            guard availableInputs.indices.contains(button.tag) else { continue }
            button.state = availableInputs[button.tag].uid == chosenInputUID ? .on : .off
            button.isEnabled = !busy
        }
    }

    @objc private func startMiRemote() { beginAudio(outputUID: "MiRemoteV2ch_UID") }
    @objc private func startBlackHole() { beginAudio(outputUID: "BlackHole2ch_UID") }

    private func beginAudio(outputUID: String) {
        guard !busy else { return }
        guard ApplicationInstanceGuard.existingApplication(bundleIdentifier: "com.hd838a.RemoteMic") == nil else {
            status.stringValue = "请先退出其他语音程序，避免同时使用虚拟麦。"; return
        }
        let inputs = CoreAudioDeviceCatalog.inputDevices().filter(X6PreviewAudio.isEligibleInput)
        guard let index = X6PreviewPolicy.selectedInputIndex(uids: inputs.map(\.uid), selectedUID: chosenInputUID) else {
            status.stringValue = "请先选择一个当前可用的 USB 音频输入。"; return
        }
        guard let output = CoreAudioDeviceCatalog.outputDevices().first(where: { $0.uid == outputUID }) else {
            status.stringValue = "所选虚拟音频设备不可用，请检查设备列表。"; return
        }
        let input = inputs[index]
        busy = true
        updateInputButtons()
        requestGeneration += 1
        let request = requestGeneration
        status.stringValue = "等待麦克风权限。取消或停止后不会自动开始。"
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.requestGeneration == request else { return }
                guard granted else {
                    self.busy = false
                    self.updateInputButtons()
                    self.status.stringValue = "麦克风权限未授予，未采集声音。"
                    AppLogger.shared.write("X6 PERMISSION phase=failed reason=microphone_denied")
                    return
                }
                let currentInputs = CoreAudioDeviceCatalog.inputDevices().filter(X6PreviewAudio.isEligibleInput)
                guard let currentIndex = X6PreviewPolicy.selectedInputIndex(uids: currentInputs.map(\.uid), selectedUID: input.uid),
                      currentInputs[currentIndex].uid == input.uid,
                      let currentOutput = CoreAudioDeviceCatalog.outputDevices().first(where: { $0.uid == output.uid }),
                      ApplicationInstanceGuard.existingApplication(bundleIdentifier: "com.hd838a.RemoteMic") == nil else {
                    self.busy = false
                    self.updateInputButtons()
                    self.status.stringValue = "设备或正式版运行状态已变化，请重新选择并开始。"
                    return
                }
                self.selectedInputUID = input.uid
                self.selectedOutputUID = output.uid
                self.audio.start(inputDevice: currentInputs[currentIndex], outputDevice: currentOutput)
            }
        }
    }

    @objc private func stopAll() {
        mappingDefaults.set(false, forKey: "x6MappingsEnabled")
        pauseMappings(reason: "映射已暂停。")
        requestGeneration += 1
        hid.stop()
        audio.stop()
        if selectedInputUID == nil { busy = false; status.stringValue = "已停止，未采集声音。" }
        updateInputButtons()
        hidStatus.stringValue = "按键检测已停止。"
    }

    private func refresh() {
        connectionHeading.stringValue = hid.connectedCount > 0
            ? (router.enabled ? "● 已连接 · 映射已开启" : "● 已连接 · 映射暂停")
            : "○ 等待遥控器连接"
        if hid.isRunning {
            hidStatus.stringValue = "匹配 HID 接口：\(hid.connectedCount) · 事件：\(hid.eventCount)\n\(hid.latestEvent)"
        }
        guard let inputUID = selectedInputUID, let outputUID = selectedOutputUID else { return }
        let inputs = CoreAudioDeviceCatalog.inputDevices().filter(X6PreviewAudio.isEligibleInput)
        let inputPresent = X6PreviewPolicy.selectedInputIndex(uids: inputs.map(\.uid), selectedUID: inputUID) != nil
        let outputPresent = CoreAudioDeviceCatalog.outputDevices().contains { $0.uid == outputUID }
        if !inputPresent || !outputPresent ||
                ApplicationInstanceGuard.existingApplication(bundleIdentifier: "com.hd838a.RemoteMic") != nil {
            audio.stop(reason: "device_or_isolation_changed", drain: false)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        requestGeneration += 1
        timer?.invalidate()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let applicationLaunchObserver { NSWorkspace.shared.notificationCenter.removeObserver(applicationLaunchObserver) }
        pauseMappings(reason: "应用退出", remember: false)
        hid.stop()
        audio.shutdown()
        AppLogger.shared.flush()
    }
}
@MainActor
private final class X6MappingDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private struct X6RemoteCanvas: View {
    var selected: String
    let onSelect: (String) -> Void
    // Normalized to the full transparent asset; never used as HID identifiers.
    private let keys: [(String, String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        ("power", "电源键", 0.50, 0.092, 0.20, 0.067),
        ("back", "返回键", 0.285, 0.238, 0.20, 0.045),
        ("menu", "菜单键", 0.50, 0.238, 0.20, 0.045),
        ("tv", "应用键", 0.725, 0.238, 0.20, 0.045),
        ("up", "上键", 0.50, 0.31, 0.20, 0.045),
        ("left", "左键", 0.285, 0.382, 0.18, 0.07),
        ("ok", "确认键", 0.50, 0.382, 0.24, 0.09),
        ("right", "右键", 0.715, 0.382, 0.18, 0.07),
        ("down", "下键", 0.50, 0.458, 0.20, 0.045),
        ("volume_up", "音量加", 0.735, 0.51, 0.20, 0.064),
        ("volume_down", "音量减", 0.735, 0.602, 0.20, 0.064)
    ]
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let url = Bundle.main.url(forResource: "X6RemoteFront", withExtension: "png"),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().frame(width: 194, height: 582)
                }
                ForEach(keys.indices, id: \.self) { index in
                    let key = keys[index]
                    Button { onSelect(key.0) } label: {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selected == key.0 ? Color.accentColor.opacity(0.35) : .clear)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected == key.0 ? Color.accentColor : .clear, lineWidth: 2))
                            .frame(width: key.4 * 194, height: key.5 * 582)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(key.1).accessibilityLabel(key.1)
                        .position(x: key.2 * 194, y: key.3 * 582)
                }
            }.frame(width: 194, height: 582)
            Text("选中按键后，在右侧编辑映射").font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

#endif
