import Testing
@testable import TouchBridgeCore

// Regression tests for advertising surviving Bluetooth power cycles.
//
// macOS powers the Bluetooth controller off and on while the Mac is idle or
// asleep. Before this state machine existed, the daemon re-advertised only on
// the first poweredOn, so the first idle period silently ended advertising and
// the phone could never find the Mac again until the daemon was restarted.

@Test func startBeforeReadyDefersThenStartsOnPowerOn() {
    var s = BLEAdvertisingState()
    #expect(s.requestStart() == .deferUntilReady)
    #expect(!s.isAdvertising)

    #expect(s.stackPoweredOn() == true)
    #expect(s.isReady)
    #expect(s.isAdvertising)
}

@Test func startWhenReadyStartsImmediatelyAndIsIdempotent() {
    var s = BLEAdvertisingState()
    #expect(s.stackPoweredOn() == false) // no intent yet

    #expect(s.requestStart() == .startStack)
    #expect(s.requestStart() == .noop)
    #expect(s.isAdvertising)
}

@Test func advertisingResumesAfterEveryPowerCycle() {
    var s = BLEAdvertisingState()
    _ = s.requestStart()
    #expect(s.stackPoweredOn() == true)

    for _ in 0..<3 {
        s.stackUnavailable()
        #expect(!s.isAdvertising)
        #expect(!s.isReady)
        // The bug: this used to be false on every cycle after the first.
        #expect(s.stackPoweredOn() == true)
        #expect(s.isAdvertising)
    }
}

@Test func startAfterPowerCycleIsNotSwallowedByStaleFlag() {
    // .resetting used to leave isAdvertising == true, making startAdvertising()
    // a permanent no-op. Now any unavailable state clears it.
    var s = BLEAdvertisingState()
    _ = s.requestStart()
    _ = s.stackPoweredOn()

    s.stackUnavailable()
    #expect(s.requestStart() == .deferUntilReady)
    #expect(s.stackPoweredOn() == true)
}

@Test func stopClearsIntentSoPowerCycleDoesNotResume() {
    var s = BLEAdvertisingState()
    _ = s.requestStart()
    _ = s.stackPoweredOn()

    #expect(s.requestStop() == true)
    #expect(!s.isAdvertising)
    #expect(s.requestStop() == false) // already stopped

    s.stackUnavailable()
    #expect(s.stackPoweredOn() == false)
    #expect(!s.isAdvertising)
}

@Test func stopWhileDeferredJustClearsIntent() {
    var s = BLEAdvertisingState()
    _ = s.requestStart()
    #expect(s.requestStop() == false) // stack was never told to start
    #expect(s.stackPoweredOn() == false)
}

@Test func stackRejectedStartAllowsRetry() {
    var s = BLEAdvertisingState()
    _ = s.stackPoweredOn()
    #expect(s.requestStart() == .startStack)
    s.stackRejectedStart()
    #expect(!s.isAdvertising)
    #expect(s.requestStart() == .startStack)
}
