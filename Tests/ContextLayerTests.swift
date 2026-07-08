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
            action: "",
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
        // Leading article is stripped by the canonical object normalizer.
        XCTAssertEqual(draft(subject: "Piyush").fingerprint, "n:piyush|i_owe|deck")
    }

    func test_fingerprint_keysOnPersonId_whenResolved() {
        XCTAssertEqual(draft(subject: "Piyush", personId: 100).fingerprint, "p:100|i_owe|deck")
    }

    func test_fingerprint_articleVariantsCollapse() {
        // "the deck" and "deck" are the same loop — article-only rewording must
        // not mint a second identity (parser drop-set and upsert share this).
        XCTAssertEqual(draft(subject: "X", object: "the deck").fingerprint,
                       draft(subject: "X", object: "deck").fingerprint)
    }

    func test_fingerprint_interiorWhitespaceClassesCollapse() {
        // Newline/tab variants must not dodge identity (they once slipped the
        // parser's drop-set and re-anchored the stored fact via ON CONFLICT).
        XCTAssertEqual(draft(subject: "X", object: "pitch\ndeck").fingerprint,
                       draft(subject: "X", object: "pitch deck").fingerprint)
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

    private func snippet(id: Int64, sender: String = "Rahul", text: String, at seconds: TimeInterval = 100) -> MessageSnippet {
        MessageSnippet(messageId: id, senderFirstName: sender, text: text,
                       relativeTimestamp: "now", chatId: 7, chatName: "Chat",
                       date: Date(timeIntervalSince1970: seconds))
    }

    private func openLoop(fingerprint: String, subject: String = "X", object: String = "o",
                          predicate: FactPredicate = .iOwe) -> Fact {
        var f = fact(fingerprint: fingerprint, predicate: predicate)
        f.subjectEntity = subject
        f.objectText = object
        return f
    }

    /// Review finding #3: an unparseable reply must THROW (so the caller doesn't
    /// advance the cursor), not silently look like a valid empty result.
    func test_parse_throwsOnUnparseableResponse() {
        XCTAssertThrowsError(
            try FactExtractionParser.parse("complete garbage, no json here !@#$",
                                           chatId: 1, openLoops: [],
                                           validFrom: Date(timeIntervalSince1970: 0))
        ) { error in
            XCTAssertEqual(error as? FactExtractionError, .unparseableResponse)
        }
    }

    func test_parse_validButEmpty_returnsEmptyWithoutThrowing() throws {
        let result = try FactExtractionParser.parse(#"{"facts":[],"resolvedLoops":[]}"#,
                                                    chatId: 1, openLoops: [],
                                                    validFrom: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(result.drafts.isEmpty)
        XCTAssertTrue(result.resolvedFingerprints.isEmpty)
    }

    func test_parse_resolvedLoops_mapOneBasedIndexToStoredFingerprint() throws {
        let loops = [fact(fingerprint: "fp-A"), fact(fingerprint: "fp-B")]
        let result = try FactExtractionParser.parse(#"{"facts":[],"resolvedLoops":[2]}"#,
                                                    chatId: 1, openLoops: loops,
                                                    validFrom: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(result.resolvedFingerprints, ["fp-B"])
    }

    func test_parse_resolvedLoops_outOfRange_areIgnored() throws {
        let loops = [fact(fingerprint: "fp-A")]
        let result = try FactExtractionParser.parse(#"{"facts":[],"resolvedLoops":[5,0]}"#,
                                                    chatId: 1, openLoops: loops,
                                                    validFrom: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(result.resolvedFingerprints.isEmpty)
    }

    func test_parse_buildsDraftFromFact_withPerFactProvenance() throws {
        let json = #"{"facts":[{"subject":"Rahul","predicate":"owes_me","object":"the invoice","sourceMsg":1,"confidence":0.8,"evidence":"send the invoice"}],"resolvedLoops":[]}"#
        let messages = [snippet(id: 42, text: "send the invoice", at: 50)]
        let result = try FactExtractionParser.parse(json, chatId: 7, openLoops: [],
                                                    validFrom: Date(timeIntervalSince1970: 100),
                                                    messages: messages)
        XCTAssertEqual(result.drafts.count, 1)
        let d = try XCTUnwrap(result.drafts.first)
        XCTAssertEqual(d.subjectEntity, "Rahul")
        XCTAssertEqual(d.predicate, .owesMe)
        XCTAssertEqual(d.objectText, "the invoice")
        XCTAssertEqual(d.sourceChatId, 7)
        XCTAssertEqual(d.sourceMessageId, 42)
        // validFrom = the CITED message's date (age of the ask), not batch-newest.
        XCTAssertEqual(d.validFrom, Date(timeIntervalSince1970: 50))
    }

    /// A fact with no valid [N] and no evidence matching a real message must be
    /// DROPPED — every surfaced loop has verifiable provenance.
    func test_parse_dropsFact_withUnverifiableProvenance() throws {
        let json = #"{"facts":[{"subject":"Rahul","predicate":"owes_me","object":"the invoice","evidence":"Previous context"}],"resolvedLoops":[]}"#
        let messages = [snippet(id: 42, text: "totally unrelated message here")]
        let result = try FactExtractionParser.parse(json, chatId: 7, openLoops: [],
                                                    validFrom: Date(timeIntervalSince1970: 0),
                                                    messages: messages)
        XCTAssertTrue(result.drafts.isEmpty)
    }

    /// Review round 2, finding 1: a loop already open in the chat is a
    /// re-emission → dropped (keeps the original anchor)…
    func test_parse_dropsReEmissionOfOpenLoop() throws {
        let loops = [openLoop(fingerprint: "fp-A", subject: "Rahul", object: "the invoice")]
        let json = #"{"facts":[{"subject":"Rahul","predicate":"i_owe","object":"the invoice","sourceMsg":1,"evidence":"otp 123456"}],"resolvedLoops":[]}"#
        let messages = [snippet(id: 9, text: "otp 123456")]
        let result = try FactExtractionParser.parse(json, chatId: 7, openLoops: loops,
                                                    validFrom: Date(timeIntervalSince1970: 0),
                                                    messages: messages)
        XCTAssertTrue(result.drafts.isEmpty, "re-emitting an open loop must not re-anchor it")
    }

    /// …but a loop the SAME response closes is a legitimate re-ask and survives.
    func test_parse_keepsReAsk_whenSameResponseClosesTheLoop() throws {
        let loops = [openLoop(fingerprint: "fp-A", subject: "Rahul", object: "the invoice")]
        let json = #"{"facts":[{"subject":"Rahul","predicate":"i_owe","object":"the invoice","sourceMsg":2,"evidence":"now the April invoice please"}],"resolvedLoops":[1]}"#
        let messages = [snippet(id: 1, sender: "[ME]", text: "paid the March invoice"),
                        snippet(id: 2, text: "now the April invoice please")]
        let result = try FactExtractionParser.parse(json, chatId: 7, openLoops: loops,
                                                    validFrom: Date(timeIntervalSince1970: 0),
                                                    messages: messages)
        XCTAssertEqual(result.resolvedFingerprints, ["fp-A"])
        XCTAssertEqual(result.drafts.count, 1, "close + re-ask in one window must keep the new ask")
        XCTAssertEqual(result.drafts.first?.sourceMessageId, 2)
    }

    /// A DIFFERENT named person owing the same object is a distinct loop, kept.
    func test_parse_keepsSameObjectLoop_fromDifferentPerson() throws {
        let loops = [openLoop(fingerprint: "fp-A", subject: "Alice", object: "the pitch deck")]
        let json = #"{"facts":[{"subject":"Bob","predicate":"i_owe","object":"the pitch deck","sourceMsg":1,"evidence":"can you send me the pitch deck too?"}],"resolvedLoops":[]}"#
        let messages = [snippet(id: 5, sender: "Bob", text: "can you send me the pitch deck too?")]
        let result = try FactExtractionParser.parse(json, chatId: 7, openLoops: loops,
                                                    validFrom: Date(timeIntervalSince1970: 0),
                                                    messages: messages)
        XCTAssertEqual(result.drafts.count, 1, "Bob's ask is not a re-emission of Alice's loop")
    }

    /// Subject drift me↔counterparty on the same loop IS a re-emission, dropped.
    func test_parse_dropsReEmission_withSubjectDriftedToMe() throws {
        let loops = [openLoop(fingerprint: "fp-A", subject: "Rahul", object: "the invoice")]
        let json = #"{"facts":[{"subject":"me","predicate":"i_owe","object":"the invoice","sourceMsg":1,"evidence":"anything"}],"resolvedLoops":[]}"#
        let messages = [snippet(id: 9, text: "anything")]
        let result = try FactExtractionParser.parse(json, chatId: 7, openLoops: loops,
                                                    validFrom: Date(timeIntervalSince1970: 0),
                                                    messages: messages)
        XCTAssertTrue(result.drafts.isEmpty)
    }

    /// Review round 2, finding 5a: a cited [N] whose message is clearly unrelated
    /// to the quoted evidence is a mis-cite → re-resolved from the evidence text.
    func test_parse_reanchorsMiscitedSourceMsg_toEvidenceMatch() throws {
        let json = #"{"facts":[{"subject":"Rahul","predicate":"owes_me","object":"the deck","sourceMsg":1,"evidence":"can you send the deck tomorrow?"}],"resolvedLoops":[]}"#
        let messages = [snippet(id: 10, text: "520370", at: 10),
                        snippet(id: 20, text: "can you send the deck tomorrow?", at: 20)]
        let result = try FactExtractionParser.parse(json, chatId: 7, openLoops: [],
                                                    validFrom: Date(timeIntervalSince1970: 0),
                                                    messages: messages)
        let d = try XCTUnwrap(result.drafts.first)
        XCTAssertEqual(d.sourceMessageId, 20, "mis-cited [N] (an OTP) must yield to the evidence match")
        XCTAssertEqual(d.validFrom, Date(timeIntervalSince1970: 20))
    }

    /// A follow-up ping on an open loop reports as chasedLoops: mapped to the
    /// loop's fingerprint + anchored on the CHASE message (id + text + date).
    func test_parse_chasedLoop_mapsToFingerprintAndChaseMessage() throws {
        let loops = [openLoop(fingerprint: "fp-A", subject: "Akhil", object: "the logic help")]
        let json = #"{"facts":[],"resolvedLoops":[],"chasedLoops":[{"loop":1,"sourceMsg":1}]}"#
        let messages = [snippet(id: 99, sender: "Akhil", text: "wen free tonight", at: 500)]
        let result = try FactExtractionParser.parse(json, chatId: 7, openLoops: loops,
                                                    validFrom: Date(timeIntervalSince1970: 0),
                                                    messages: messages)
        XCTAssertEqual(result.chasedLoops, [ChasedLoopUpdate(
            fingerprint: "fp-A", sourceMessageId: 99, sourceText: "wen free tonight",
            date: Date(timeIntervalSince1970: 500)
        )])
    }

    /// [ME]'s own message can't chase-bump a loop, and a loop the same response
    /// CLOSED wins as closed (no bump for a loop that just ended).
    func test_parse_chasedLoop_rejectsMeSender_andClosedWins() throws {
        let loops = [openLoop(fingerprint: "fp-A"), openLoop(fingerprint: "fp-B", object: "p")]
        let json = #"{"facts":[],"resolvedLoops":[2],"chasedLoops":[{"loop":1,"sourceMsg":1},{"loop":2,"sourceMsg":2}]}"#
        let messages = [snippet(id: 1, sender: "[ME]", text: "chasing my own thing"),
                        snippet(id: 2, sender: "Akhil", text: "any update on p?")]
        let result = try FactExtractionParser.parse(json, chatId: 7, openLoops: loops,
                                                    validFrom: Date(timeIntervalSince1970: 0),
                                                    messages: messages)
        XCTAssertTrue(result.chasedLoops.isEmpty)
        XCTAssertEqual(result.resolvedFingerprints, ["fp-B"])
    }

    /// Review round 2, finding 5b: a short filler message must never win the
    /// substring fallback ("ok" is inside "book the hotel").
    func test_parse_fillerMessage_neverAnchorsViaSubstring() throws {
        let json = #"{"facts":[{"subject":"Rahul","predicate":"owes_me","object":"the hotel","evidence":"Can you book the hotel"}],"resolvedLoops":[]}"#
        let messages = [snippet(id: 10, text: "ok", at: 10),
                        snippet(id: 20, text: "Can you book the hotel?", at: 20)]
        let result = try FactExtractionParser.parse(json, chatId: 7, openLoops: [],
                                                    validFrom: Date(timeIntervalSince1970: 0),
                                                    messages: messages)
        let d = try XCTUnwrap(result.drafts.first)
        XCTAssertEqual(d.sourceMessageId, 20, "the filler 'ok' must not become the anchor")
    }
}
