#if X6_ADAPTER_PREVIEW
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// A bounded, explicitly started USB capture path into SayAll's existing output.
final class X6PreviewAudio {
    private let queue = DispatchQueue(label: "SayAll.X6Preview.audio")
    private let slots = DispatchSemaphore(value: 4)
    private let output = VirtualAudioOutput()
    private var input: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var generation = 0
    private var receivedSamples = 0
    private var stopping = false
    private var preparing = false
    var onStatus: ((String, Bool) -> Void)?

    static func isUSB(_ device: AudioDeviceInfo) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &transport) == noErr &&
            transport == kAudioDeviceTransportTypeUSB
    }

    static func isEligibleInput(_ device: AudioDeviceInfo) -> Bool {
        X6PreviewPolicy.isEligibleInput(uid: device.uid, isUSB: isUSB(device))
    }

    func start(inputDevice: AudioDeviceInfo, outputDevice: AudioDeviceInfo) {
        queue.async { [self] in
            guard input == nil, !stopping, !preparing else { return }
            generation += 1
            let current = generation
            receivedSamples = 0
            AppLogger.shared.write("X6 AUDIO operation_id=\(current) phase=requested")
            let currentInputs = CoreAudioDeviceCatalog.inputDevices().filter(Self.isEligibleInput)
            guard let inputIndex = X6PreviewPolicy.selectedInputIndex(uids: currentInputs.map(\.uid), selectedUID: inputDevice.uid),
                  currentInputs[inputIndex].uid == inputDevice.uid,
                  currentInputs[inputIndex].id == inputDevice.id,
                  CoreAudioDeviceCatalog.outputDevices().contains(where: { $0.uid == outputDevice.uid && $0.id == outputDevice.id }),
                  Self.isEligibleInput(inputDevice),
                  X6PreviewPolicy.isVirtualOutput(uid: outputDevice.uid) else {
                fail("device_rejected", operation: current); return
            }
            preparing = true
            output.configureAsync(deviceUID: outputDevice.uid) { [weak self] configured in
                guard let self else { return }
                self.queue.async {
                    guard self.generation == current, self.preparing else { return }
                    self.preparing = false
                    guard configured else {
                        self.fail("output_configuration_failed", operation: current)
                        return
                    }
                    self.startCaptureOnQueue(inputDevice: inputDevice, current: current)
                }
            }
        }
    }

    private func startCaptureOnQueue(inputDevice: AudioDeviceInfo, current: Int) {
        let engine = AVAudioEngine()
        let node = engine.inputNode
        guard let unit = node.audioUnit else {
            fail("input_unit_unavailable", operation: current); return
        }
        var deviceID = inputDevice.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { fail("input_binding_failed", operation: current); return }
        var actualID = AudioDeviceID(kAudioObjectUnknown)
        var actualSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &actualID, &actualSize) == noErr,
            actualID == inputDevice.id else { fail("input_binding_mismatch", operation: current); return }
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            fail("input_format_unavailable", operation: current); return
        }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Copy before leaving the tap callback: AVAudioEngine owns its buffer.
            guard self.slots.wait(timeout: .now()) == .success else {
                self.queue.async { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.stopOnQueue(reason: "capture_backpressure", drain: false)
                }
                return
            }
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                self.slots.signal(); return
            }
            copy.frameLength = buffer.frameLength
            let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in 0..<src.count {
                if let from = src[index].mData, let to = dst[index].mData {
                    memcpy(to, from, Int(src[index].mDataByteSize))
                }
            }
            self.queue.async { [weak self] in
                defer { self?.slots.signal() }
                guard let self, self.generation == current, self.input != nil, !self.stopping else { return }
                let capacity = AVAudioFrameCount(ceil(Double(copy.frameLength) * 16_000 / format.sampleRate)) + 64
                guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                    self.stopOnQueue(reason: "conversion_buffer_failed", drain: false); return
                }
                var supplied = false
                var error: NSError?
                let result = converter.convert(to: converted, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return copy
                }
                guard result != .error, error == nil, let samples = converted.floatChannelData?[0] else {
                    self.stopOnQueue(reason: "conversion_failed", drain: false); return
                }
                guard converted.frameLength > 0 else { return }
                let pcm = (0..<Int(converted.frameLength)).map { X6PreviewPolicy.pcm16(samples[$0]) }
                self.receivedSamples += pcm.count
                guard self.output.enqueue(samples: pcm, deliveryGeneration: current) else {
                    self.stopOnQueue(reason: "output_rejected", drain: false); return
                }
            }
        }
        input = engine
        do {
            engine.prepare()
            try engine.start()
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self, weak engine] _ in
                guard let self, let engine else { return }
                self.queue.async {
                    guard self.generation == current, self.input === engine, !self.stopping else { return }
                    var observedID = AudioDeviceID(kAudioObjectUnknown)
                    var observedSize = UInt32(MemoryLayout<AudioDeviceID>.size)
                    let readStatus = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global, 0, &observedID, &observedSize)
                    let actualID = readStatus == noErr && observedID != kAudioObjectUnknown ? observedID : nil
                    let observedFormat = engine.inputNode.outputFormat(forBus: 0)
                    let unchanged = X6PreviewPolicy.keepCaptureAfterNotification(
                        selectedID: inputDevice.id, actualID: actualID, running: engine.isRunning,
                        expectedRate: format.sampleRate, actualRate: observedFormat.sampleRate,
                        expectedChannels: format.channelCount, actualChannels: observedFormat.channelCount)
                    AppLogger.shared.write("X6 ROUTE operation_id=\(current) phase=observed " +
                        "binding_known=\(actualID != nil) binding_matches=\(actualID == inputDevice.id) " +
                        "engine_running=\(engine.isRunning) format_matches=\(format.sampleRate == observedFormat.sampleRate && format.channelCount == observedFormat.channelCount) " +
                        "result=\(unchanged ? "unchanged" : "changed_or_unknown")")
                    if !unchanged { self.stopOnQueue(reason: "input_route_changed", drain: false) }
                }
            }
            output.onConfigurationChange = { [weak self] in self?.stop(reason: "output_route_changed", drain: false) }
            AppLogger.shared.write("X6 AUDIO operation_id=\(current) phase=started input_bound=true transcription=unknown")
            report("音频桥已启动。请按住 X6 语音键，并在目标 App 选择同一虚拟麦克风。", active: true)
        } catch {
            stopOnQueue(reason: "capture_start_failed", drain: false)
        }
    }

    func stop(reason: String = "user_stop", drain: Bool = true) {
        queue.async { [weak self] in self?.stopOnQueue(reason: reason, drain: drain) }
    }

    /// Called on app exit/sleep. Does not depend on a main-run-loop drain callback.
    func shutdown(reason: String = "app_exit") {
        queue.sync {
            let hadSession = input != nil || stopping || preparing
            let current = stopping ? generation - 1 : generation
            input?.stop()
            input?.inputNode.removeTap(onBus: 0)
            input = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            output.onConfigurationChange = nil
            output.cancelPendingDrain()
            output.stop()
            generation += 1
            stopping = false
            preparing = false
            if hadSession {
                AppLogger.shared.write("X6 AUDIO operation_id=\(current) phase=cancelled reason=\(reason) received_samples=\(receivedSamples) transcription=unknown")
                report("音频桥已停止：\(reason)。", active: false)
            }
        }
    }

    private func stopOnQueue(reason: String, drain: Bool) {
        if preparing {
            let current = generation
            generation += 1
            preparing = false
            output.stop()
            AppLogger.shared.write("X6 AUDIO operation_id=\(current) phase=cancelled reason=\(reason)")
            report("音频桥已停止。", active: false)
            return
        }
        guard let input, !stopping else { return }
        stopping = true
        input.stop()
        input.inputNode.removeTap(onBus: 0)
        self.input = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        output.onConfigurationChange = nil
        let current = generation
        generation += 1 // Reject every late tap callback from the old session.
        let finish = { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.stopping, self.generation == current + 1 else { return }
                let snapshot = self.output.diagnosticSnapshot(deliveryGeneration: current)
                AppLogger.shared.write("X6 AUDIO operation_id=\(current) phase=completed reason=\(reason) " +
                    "received_samples=\(self.receivedSamples) played_samples=\(snapshot.counters.playedSamples) " +
                    "interrupted_samples=\(snapshot.counters.interruptedSamples) pending_samples=\(snapshot.pendingSamples) transcription=unknown")
                self.output.stop()
                self.stopping = false
                self.report("已停止：\(reason)。收到 \(self.receivedSamples) 样本，播放 \(snapshot.counters.playedSamples) 样本；文字上屏未验证。", active: false)
            }
        }
        if drain {
            output.endSessionAfterDraining(maximumDelay: nil, completion: finish)
        } else {
            output.endSession()
            finish()
        }
    }

    private func fail(_ reason: String, operation: Int) {
        output.stop()
        AppLogger.shared.write("X6 AUDIO operation_id=\(operation) phase=failed reason=\(reason)")
        report("无法启动：\(reason)", active: false)
    }

    private func report(_ text: String, active: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(text, active) }
    }
}
#endif
