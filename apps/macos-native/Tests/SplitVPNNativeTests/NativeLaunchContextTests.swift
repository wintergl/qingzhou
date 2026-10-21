import Carbon
import XCTest
@testable import SplitVPNNative

final class NativeLaunchContextTests: XCTestCase {
    private func event(_ id: AEEventID = AEEventID(kAEOpenApplication)) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: id, targetDescriptor: nil,
                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }
    func testLoginItemAndServiceLaunchKindsAreSilent() {
        for source in [keyAELaunchedAsLogInItem, keyAELaunchedAsServiceItem] {
            let launch = event()
            launch.setParam(NSAppleEventDescriptor(enumCode: source), forKeyword: AEKeyword(keyAEPropData))
            XCTAssertTrue(NativeLaunchContext.isBackground(launch))
        }
    }
    func testManualLaunchAndReopenDoNotBecomeBackgroundLaunches() {
        XCTAssertFalse(NativeLaunchContext.isBackground(nil))
        XCTAssertFalse(NativeLaunchContext.isBackground(event()))
        let reopen = event(AEEventID(kAEReopenApplication))
        reopen.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: AEKeyword(keyAEPropData))
        XCTAssertFalse(NativeLaunchContext.isBackground(reopen))
    }
    func testBooleanWithLoginKeywordDoesNotReplaceTheSystemLaunchKind() {
        let launch = event()
        launch.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: AEKeyword(keyAELaunchedAsLogInItem))
        XCTAssertFalse(NativeLaunchContext.isBackground(launch))
    }
}
