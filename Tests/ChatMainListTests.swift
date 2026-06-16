import XCTest
import TDLibKit
@testable import Pidgy

/// Guards the "reply queue shows a group I don't even have" bug. The reply
/// queue draws from `visibleChats` = chats flagged `isInMainList`. A chat the
/// user LEFT has no chat-list positions, and an ARCHIVED chat sits in
/// `chatListArchive` — neither is in the main list, so neither should be
/// surfaced. (The old logic defaulted empty positions to `true`, which kept
/// left/archived chats generating reply tasks even though they're gone from
/// the user's chat list.)
///
/// This is exactly how you catch this class of bug: feed the position shapes a
/// left / archived / active chat actually has, and assert main-list membership.
final class ChatMainListTests: XCTestCase {
    private func pos(_ list: ChatList, order: Int64) -> ChatPosition {
        ChatPosition(isPinned: false, list: list, order: TdInt64(order), source: nil)
    }

    func testLeftChatWithNoPositionsIsNotMainList() {
        // A chat the user left / that was removed from every list.
        XCTAssertFalse(TelegramService.isInMainList(positions: []))
    }

    func testArchivedChatIsNotMainList() {
        XCTAssertFalse(TelegramService.isInMainList(positions: [pos(.chatListArchive, order: 100)]))
    }

    func testMainListOrderZeroIsNotMainList() {
        // order 0 in main list == removed from the main list.
        XCTAssertFalse(TelegramService.isInMainList(positions: [pos(.chatListMain, order: 0)]))
    }

    func testActiveMainListChatIsMainList() {
        XCTAssertTrue(TelegramService.isInMainList(positions: [pos(.chatListMain, order: 100)]))
    }

    func testArchiveAndMainCountsAsMain() {
        XCTAssertTrue(TelegramService.isInMainList(positions: [
            pos(.chatListArchive, order: 50),
            pos(.chatListMain, order: 100)
        ]))
    }
}
