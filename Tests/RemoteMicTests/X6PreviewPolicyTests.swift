import XCTest
@testable import RemoteMic

final class X6PreviewPolicyTests: XCTestCase {
    func testSleepAndWakeResumeOnlyPreviouslyEnabledMappings() {
        var router = X6MappingRouter()
        router.enabled = true
        router.suspendForSleep()
        XCTAssertFalse(router.enabled)
        router.suspendForSleep()
        router.resumeAfterSleep()
        XCTAssertTrue(router.enabled)
        router.suspendForSleep()
        router.reset()
        router.resumeAfterSleep()
        XCTAssertFalse(router.enabled)
    }

    func testInterfaceRemovalPreservesEnabledMappingsAndOtherInterfaces() {
        let key = X6HIDObservationDecoder.Key(page: 7, usage: 80)
        let binding = X6MappingRouter.Binding(key: key, name: "left", action: "left",
            shortcutCode: nil, shortcutFlags: 0, shortcutLabel: "")
        var router = X6MappingRouter()
        router.bindings = [binding]; router.enabled = true
        XCTAssertEqual(router.consume(.init(device: 1, key: key, pressed: true)).binding, binding)
        XCTAssertNil(router.consume(.init(device: 2, key: key, pressed: true)).binding)
        router.removeDevice(1)
        XCTAssertTrue(router.enabled)
        XCTAssertNil(router.consume(.init(device: 2, key: key, pressed: true)).binding)
        XCTAssertEqual(router.consume(.init(device: 2, key: key, pressed: false)).released, binding)
        XCTAssertEqual(router.consume(.init(device: 2, key: key, pressed: true)).binding, binding)
        XCTAssertEqual(router.bindings, [binding])
    }


    func testLearningAnotherPhysicalKeyCannotReplaceAnOccupiedSlot() {
        let old = X6MappingRouter.Binding(key: .init(page: 12, usage: 406), name: "power",
            action: "power", shortcutCode: nil, shortcutFlags: 0, shortcutLabel: "")
        let differentKey = X6MappingRouter.Binding(key: .init(page: 12, usage: 207), name: "power",
            action: "power", shortcutCode: nil, shortcutFlags: 0, shortcutLabel: "")
        XCTAssertNil(X6MappingRouter.adding(differentKey, to: [old]))
        let freeSlot = X6MappingRouter.Binding(key: differentKey.key, name: "home", action: "home",
            shortcutCode: nil, shortcutFlags: 0, shortcutLabel: "")
        XCTAssertEqual(X6MappingRouter.adding(freeSlot, to: [old]), [old, freeSlot])
    }

    func testMappingMirroredInterfacesProduceOnePressAndOneFinalRelease() {
        let key = X6HIDObservationDecoder.Key(page: 12, usage: 207)
        let binding = X6MappingRouter.Binding(key: key, name: "home", action: "home",
            shortcutCode: nil, shortcutFlags: 0, shortcutLabel: "")
        var router = X6MappingRouter()
        router.bindings = [binding]
        router.enabled = true
        XCTAssertEqual(router.consume(.init(device: 1, key: key, pressed: true)).binding, binding)
        XCTAssertNil(router.consume(.init(device: 2, key: key, pressed: true)).binding)
        XCTAssertNil(router.consume(.init(device: 1, key: key, pressed: false)).released)
        XCTAssertEqual(router.consume(.init(device: 2, key: key, pressed: false)).released, binding)
    }

    func testLearningDisarmsActionsAndIgnoresConsumerCollectionMarker() {
        var router = X6MappingRouter()
        router.enabled = true
        router.armLearning()
        XCTAssertFalse(router.enabled)
        XCTAssertNil(router.consume(.init(device: 1, key: .init(page: 12, usage: 1), pressed: true)).learned)
        let key = X6HIDObservationDecoder.Key(page: 12, usage: 207)
        let result = router.consume(.init(device: 1, key: key, pressed: true))
        XCTAssertEqual(result.learned, key)
        XCTAssertNil(result.binding)
        XCTAssertFalse(router.enabled)
    }

    func testMatchesOnlyExactReceiver() {
        XCTAssertTrue(X6PreviewPolicy.matches(vendorID: 0x1915, productID: 0x1025))
        XCTAssertFalse(X6PreviewPolicy.matches(vendorID: 0x1915, productID: 0x1026))
        XCTAssertFalse(X6PreviewPolicy.matches(vendorID: 0x1916, productID: 0x1025))
    }

    func testSelectsOnlyExplicitUniqueUID() {
        XCTAssertNil(X6PreviewPolicy.selectedInputIndex(uids: [], selectedUID: "a"))
        XCTAssertNil(X6PreviewPolicy.selectedInputIndex(uids: ["a"], selectedUID: nil))
        XCTAssertNil(X6PreviewPolicy.selectedInputIndex(uids: ["a", "a"], selectedUID: "a"))
        XCTAssertNil(X6PreviewPolicy.selectedInputIndex(uids: ["a"], selectedUID: "b"))
        XCTAssertEqual(X6PreviewPolicy.selectedInputIndex(uids: ["a", "b"], selectedUID: "b"), 1)
    }

    func testNeverRoutesToSpeakers() {
        XCTAssertTrue(X6PreviewPolicy.isVirtualOutput(uid: "MiRemoteV2ch_UID"))
        XCTAssertTrue(X6PreviewPolicy.isVirtualOutput(uid: "BlackHole2ch_UID"))
        XCTAssertFalse(X6PreviewPolicy.isVirtualOutput(uid: "BuiltInSpeakerDevice"))
        XCTAssertFalse(X6PreviewPolicy.isVirtualOutput(uid: ""))
    }

    func testPCMConversionClipsAndRejectsNonFiniteValues() {
        XCTAssertEqual(X6PreviewPolicy.pcm16(-2), -32767)
        XCTAssertEqual(X6PreviewPolicy.pcm16(2), 32767)
        XCTAssertEqual(X6PreviewPolicy.pcm16(0), 0)
        XCTAssertEqual(X6PreviewPolicy.pcm16(.nan), 0)
        XCTAssertEqual(X6PreviewPolicy.pcm16(.infinity), 0)
    }
}
