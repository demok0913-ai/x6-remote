#if X6_ADAPTER_PREVIEW
import Foundation
import IOKit
import IOKit.hid

/// Diagnostic observation only: does not seize, remap, suppress or inject keys.
final class X6PreviewHID {
    private var manager: IOHIDManager?
    private var decoder = X6HIDObservationDecoder()
    private var recentEdges: [String] = []
    private(set) var eventCount = 0
    private(set) var latestEvent = "尚未检测到按键"
    var onDeviceRemoved: ((UInt64) -> Void)?
    var onEdge: ((X6HIDObservationDecoder.Edge) -> Void)?

    var isRunning: Bool { manager != nil }

    var connectedCount: Int {
        guard let manager, let devices = IOHIDManagerCopyDevices(manager) else { return 0 }
        return CFSetGetCount(devices)
    }

    func start() -> IOReturn {
        stop()
        eventCount = 0
        latestEvent = "尚未检测到按键"
        decoder = X6HIDObservationDecoder()
        recentEdges = []
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: X6PreviewPolicy.vendorID,
            kIOHIDProductIDKey: X6PreviewPolicy.productID,
        ] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let owner = Unmanaged<X6PreviewHID>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            // Ignore pointer axes and other continuous, non-button elements.
            guard IOHIDElementGetType(element) == kIOHIDElementTypeInput_Button ||
                    IOHIDElementGetType(element) == kIOHIDElementTypeInput_ScanCodes else { return }
            owner.eventCount += 1
            let device = IOHIDElementGetDevice(element)
            var deviceToken: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &deviceToken) == KERN_SUCCESS else { return }
            let source = X6HIDObservationDecoder.Source(device: deviceToken,
                cookie: UInt32(IOHIDElementGetCookie(element)))
            let edges = owner.decoder.update(source: source,
                page: IOHIDElementGetUsagePage(element), usage: IOHIDElementGetUsage(element),
                value: IOHIDValueGetIntegerValue(value), array: IOHIDElementIsArray(element))
            owner.show(edges)

        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let owner = Unmanaged<X6PreviewHID>.fromOpaque(context).takeUnretainedValue()
            var deviceToken: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &deviceToken) == KERN_SUCCESS else { return }
            owner.onDeviceRemoved?(deviceToken)
            owner.show(owner.decoder.remove(device: deviceToken))
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnSuccess {
            self.manager = manager
        } else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        AppLogger.shared.write("X6 HID phase=\(result == kIOReturnSuccess ? "started" : "failed") error_code=\(result)")
        return result
    }

    private func show(_ edges: [X6HIDObservationDecoder.Edge]) {
        for edge in edges {
            onEdge?(edge)
            recentEdges.append(String(format: "%@ · Page 0x%04X · Usage 0x%04X",
                edge.pressed ? "按下" : "释放", edge.key.page, edge.key.usage))
        }
        recentEdges = Array(recentEdges.suffix(4))
        if !recentEdges.isEmpty { latestEvent = recentEdges.joined(separator: "\n") }
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        decoder = X6HIDObservationDecoder()
        AppLogger.shared.write("X6 HID phase=completed observed_events=\(eventCount)")
    }

    deinit { stop() }
}
#endif
