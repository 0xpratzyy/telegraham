import XCTest
@testable import Pidgy

/// Unit tests for the #48 context layer's pure logic: fingerprint identity,
/// the (deterministic) entity resolver, and the extraction parser. These cover
/// the correctness fixes from the pre-merge review — fingerprint stability,
/// the token-equality DM guard, and parse-failure vs empty-result.
final class ContextLayerTests: XCTestCase {

    // MARK: Fixtures

    private func draft(
        subject: String,
        personId: Int64? = nil,
        predicate: FactPredicate = .iOwe,
        object: String = "the deck"
    ) -> FactDraft {
        FactDraft(
            subjectEntity: subject,
            subjectPersonId: personId,
            predicate: predicate,
            objectText: object,
            objectEntity: nil,
            confidence: 0.9,
            validFrom: Date(timeIntervalSince1970: 0),
            sourceChatId: 1,
            sourceMessageId: 1,
            sourceText: "",
            senderName: subject
        )
    }

    private func fact(fingerprint: String, predicate: FactPredicate = .iOwe) -> Fact {
        Fact(
            id: 1,
            subjectEntity: "X",
            subjectPersonId: nil,
            predicate: predicate,
            objectText: "o",
            objectEntity: nil,
            confidence: 0.9,
            validFrom: Date(timeIntervalSince1970: 0),
            invalidAt: nil,
            sourceChatId: 1,
            sourceMessageId: 1,
            sourceText: "",
            senderName: "X",
            fingerprint: fingerprint,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func dmChat(title: String, userId: Int64) -> TGChat {
        TGChat(id: userId, title: title, chatType: .privateChat(userId: userId),
               unreadCount: 0, lastMessage: nil, memberCount: nil, order: 0,
               isInMainList: true, smallPhotoFileId: nil)
    }

    private func groupChat(title: String = "Some Group") -> TGChat {
        TGChat(id: 999, title: title, chatType: .basicGroup(groupId: 999),
               unreadCount: 0, lastMessage: nil, memberCount: 10, order: 0,
               isInMainList: true, smallPhotoFileId: nil)
    }

    // MARK: - Fingerprint identity

    func test_fingerprint_keysOnName_whenUnresolved() {
        XCTAssertEqual(draft(subject: "Piyush").fingerprint, "n:piyush|i_owe|the deck")
    }

    func test_fingerprint_keysOnPersonId_whenResolved() {
        XCTAssertEqual(draft(subject: "Piyush", personId: 100).fingerprint, "p:100|i_owe|the deck")
    }

    func test_fingerprint_nameVariantsCollapse_underSamePersonId() {
        // "Piyush" and "Piyush Avantis" must produce the SAME identity once both
        // resolve to the same person — the whole point of entity resolution.
        let a = draft(subject: "Piyush", personId: 100)
        let b = draft(subject: "Piyush Avantis", personId: 100)
        XCTAssertEqual(a.fingerprint, b.fingerprint)
    }

    func test_fingerprint_normalizesObjectWhitespaceAndCase() {
        XCTAssertEqual(draft(subject: "X", object: "  The   Deck ").fingerprint,
                       draft(subject: "X", object: "the deck").fingerprint)
    }

    func test_fingerprint_distinctPredicates_areDistinct() {
        XCTAssertNotEqual(draft(subject: "X", predicate: .iOwe).fingerprint,
                          draft(subject: "X", predicate: .owesMe).fingerprint)
    }

    // MARK: - Entity resolver

    func test_resolve_selfToken_returnsNil() {
        let r = FactEntityResolver.resolve(subject: "me", predicate: .iOwe,
                                           chat: groupChat(), myUserId: 1, directory: .empty)
        XCTAssertNil(r.personId)
    }

    func test_resolve_dmCounterparty_tokenMatch_resolves() {
        let r = FactEntityResolver.resolve(subject: "Piyush", predicate: .iOwe,
                                           chat: dmChat(title: "Piyush Avantis", userId: 100),
                                           myUserId: 1, directory: .empty)
        XCTAssertEqual(r.personId, 100)
        XCTAssertEqual(r.displayName, "Piyush Avantis")
    }

    /// Review finding #4: a 3rd party mentioned in a DM must NOT be misattributed
    /// to the counterparty via loose substring matching ("sam" ⊂ "samuel").
    func test_resolve_dmCounterparty_rejectsSubstringThirdParty() {
        let r = FactEntityResolver.resolve(subject: "Samuel", predicate: .iOwe,
                                           chat: dmChat(title: "Sam", userId: 100),
                                           myUserId: 1, directory: .empty)
        XCTAssertNil(r.personId, "Samuel (a 3rd party) must not resolve to DM counterparty 'Sam'")
    }

    func test_resolve_globalDirectory_resolvesMentionedPersonInGroup() {
        let dir = FactContactDirectory.build(
            rows: [(id: 200, name: "Deeksha Rungta", count: 12)],
            dmContacts: []
        )
        // A group (no DM counterparty) where Deeksha is only mentioned.
        let r = FactEntityResolver.resolve(subject: "Deeksha", predicate: .owesMe,
                                           chat: groupChat(), myUserId: 1, directory: dir)
        XCTAssertEqual(r.personId, 200)
        XCTAssertEqual(r.displayName, "Deeksha Rungta")
    }

    func test_resolve_ambiguousFirstName_staysNameOnly() {
        // Two Rahuls globally → first name is ambiguous → must NOT guess.
        let dir = FactContactDirectory.build(
            rows: [(id: 1, name: "Rahul Raj", count: 5), (id: 2, name: "Rahul Singh", count: 5)],
            dmContacts: []
        )
        let r = FactEntityResolver.resolve(subject: "Rahul", predicate: .iOwe,
                                           chat: groupChat(), myUserId: 1, directory: dir)
        XCTAssertNil(r.personId)
    }

    func test_resolve_unknownName_returnsNameOnly() {
        let r = FactEntityResolver.resolve(subject: "Nobody", predicate: .iOwe,
                                           chat: groupChat(), myUserId: 1, directory: .empty)
        XCTAssertNil(r.personId)
        XCTAssertEqual(r.displayName, "Nobody")
    }

    // MARK: - Extraction parser

    /// Review finding #3: an unparseable reply must THROW (so the caller doesn't
    /// advance the cursor), not silently look like a valid empty result.
    func test_parse_throwsOnUnparseableResponse() {
        XCTAssertThrowsError(
            try FactExtractionParser.parse("complete garbage, no json here !@#$",
                                           chatId: 1, openLoops: [], sourceMessageId: 1,
                                           validFrom: Date(timeIntervalSince1970: 0))
        ) { error in
            XCTAssertEqual(error as? FactExtractionError, .unparseableResponse)
        }
    }

    func test_parse_validButEmpty_returnsEmptyWithoutThrowing() throws {
        let result = try FactExtractionParser.parse(#"{"facts":[],"resolvedLoops":[]}"#,
                                                    chatId: 1, openLoops: [], sourceMessageId: 1,
                                                    validFrom: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(result.drafts.isEmpty)
        XCTAssertTrue(result.resolvedFingerprints.isEmpty)
    }

    func test_parse_resolvedLoops_mapOneBasedIndexToStoredFingerprint() throws {
        let loops = [fact(fingerprint: "fp-A"), fact(fingerprint: "fp-B")]
        let result = try FactExtractionParser.parse(#"{"facts":[],"resolvedLoops":[2]}"#,
                                                    chatId: 1, openLoops: loops, sourceMessageId: 1,
                                                    validFrom: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(result.resolvedFingerprints, ["fp-B"])
    }

    func test_parse_resolvedLoops_outOfRange_areIgnored() throws {
        let loops = [fact(fingerprint: "fp-A")]
        let result = try FactExtractionParser.parse(#"{"facts":[],"resolvedLoops":[5,0]}"#,
                                                    chatId: 1, openLoops: loops, sourceMessageId: 1,
                                                    validFrom: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(result.resolvedFingerprints.isEmpty)
    }

    func test_parse_buildsDraftFromFact() throws {
        let json = #"{"facts":[{"subject":"Rahul","predicate":"owes_me","object":"the invoice","confidence":0.8,"evidence":"send the invoice"}],"resolvedLoops":[]}"#
        let result = try FactExtractionParser.parse(json, chatId: 7, openLoops: [],
                                                    sourceMessageId: 42,
                                                    validFrom: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(result.drafts.count, 1)
        let d = try XCTUnwrap(result.drafts.first)
        XCTAssertEqual(d.subjectEntity, "Rahul")
        XCTAssertEqual(d.predicate, .owesMe)
        XCTAssertEqual(d.objectText, "the invoice")
        XCTAssertEqual(d.sourceChatId, 7)
        XCTAssertEqual(d.sourceMessageId, 42)
    }
}
