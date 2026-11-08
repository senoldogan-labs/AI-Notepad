import CryptoKit
import Foundation
import Testing
@testable import AINotepadCore

/// A note payload for the tests.
func sampleSharedFolderPayload(marker: String) -> SharedFolderItemPayload {
    SharedFolderItemPayload(
        startedAt: Date(timeIntervalSince1970: 1_793_000_000),
        note: SharedNotePayload(
            v: 1, lang: "en", rtl: false, title: "Weekly \(marker)", subtitle: "November 8, 2026", headings: SharedNoteHeadings(
                summary: "Summary", outline: "Topics", decisions: "Decisions", openQuestions: "Open questions", tasks: "Tasks", glossary: "Glossary",
                transcript: "Transcript"
            ),
            summary: "We agreed. \(marker)", outline: [], decisions: ["Ship it."], openQuestions: [],
            tasks: [SharedTask(owner: "Aino", description: "Send the deck", due: nil)], glossary: [], transcript: nil
        )
    )
}

@Suite struct SharedFolderCryptoTests {
    let owner: SharingIdentity
    let member: SharingIdentity
    let folderID: String = UUID().uuidString.lowercased()

    init() throws {
        owner = try newSharingIdentity()
        member = try newSharingIdentity()
    }

    @Test func identityIsDeterministicFromTheSeedAndTheSealedSeedNeedsTheRegisteredKeys() throws {
        #expect(try sharingIdentity(seed: owner.seedData).publicKeys == owner.publicKeys)
        #expect(owner.publicKeys != member.publicKeys)
        #expect(throws: SharedFolderCryptoError.invalidKeyLength(byteCount: 31)) { try sharingIdentity(seed: Data(count: 31)) }
        let syncKey: SyncAccountKey = newSyncAccountKey()
        let sealed: Data = try sealSharingSeed(identity: owner, accountKey: syncKey, userID: "u1")
        #expect(try openSharingSeed(sealed: sealed, accountKey: syncKey, userID: "u1", expected: owner.publicKeys).publicKeys == owner.publicKeys)
        // Another account, another sync key or swapped keys do not open it.
        #expect(throws: SharedFolderCryptoError.authenticationFailed) { try openSharingSeed(sealed: sealed, accountKey: syncKey, userID: "u2", expected: owner.publicKeys) }
        #expect(throws: SharedFolderCryptoError.authenticationFailed) { try openSharingSeed(sealed: sealed, accountKey: newSyncAccountKey(), userID: "u1", expected: owner.publicKeys) }
        #expect(throws: SharedFolderCryptoError.authenticationFailed) { try openSharingSeed(sealed: sealed, accountKey: syncKey, userID: "u1", expected: member.publicKeys) }
    }

    @Test func itemsOpenOnlyWithTheOwnersSignatureTheRightFolderItemAndEpoch() throws {
        let keyring: FolderKeyring = newFolderKeyring(folderID: folderID)
        let plaintext: Data = Data("note".utf8)
        let blob: Data = try sealFolderBlob(plaintext: plaintext, keyring: keyring, itemID: "item-a", owner: owner)
        #expect(try folderBlobEpoch(blob: blob) == 1)
        #expect(try openFolderBlob(blob: blob, keyring: keyring, itemID: "item-a", ownerSigningKey: owner.publicKeys.signingKey) == plaintext)
        // Moved to another item, signed by a member (who holds the keyring), or tampered.
        #expect(throws: SharedFolderCryptoError.badSignature) { try openFolderBlob(blob: blob, keyring: keyring, itemID: "item-b", ownerSigningKey: owner.publicKeys.signingKey) }
        let forged: Data = try sealFolderBlob(plaintext: Data("forged".utf8), keyring: keyring, itemID: "item-a", owner: member)
        #expect(throws: SharedFolderCryptoError.badSignature) { try openFolderBlob(blob: forged, keyring: keyring, itemID: "item-a", ownerSigningKey: owner.publicKeys.signingKey) }
        var tampered: Data = blob
        tampered[20] ^= 0x01
        #expect(throws: SharedFolderCryptoError.badSignature) { try openFolderBlob(blob: tampered, keyring: keyring, itemID: "item-a", ownerSigningKey: owner.publicKeys.signingKey) }
        // Another folder's keyring with the same id cannot open it.
        let other: FolderKeyring = newFolderKeyring(folderID: folderID)
        #expect(throws: SharedFolderCryptoError.authenticationFailed) { try openFolderBlob(blob: blob, keyring: other, itemID: "item-a", ownerSigningKey: owner.publicKeys.signingKey) }
    }

    @Test func rotationKeepsOldNotesReadableAndNewNotesNeedTheNewEpoch() throws {
        let first: FolderKeyring = newFolderKeyring(folderID: folderID)
        let old: Data = try sealFolderBlob(plaintext: Data("old".utf8), keyring: first, itemID: "a", owner: owner)
        let second: FolderKeyring = rotatedFolderKeyring(keyring: first)
        #expect(second.currentEpoch == 2)
        let new: Data = try sealFolderBlob(plaintext: Data("new".utf8), keyring: second, itemID: "b", owner: owner)
        #expect(try openFolderBlob(blob: old, keyring: second, itemID: "a", ownerSigningKey: owner.publicKeys.signingKey) == Data("old".utf8))
        // A removed member keeps only epoch 1: the new note does not open.
        #expect(throws: SharedFolderCryptoError.unknownEpoch(epoch: 2)) { try openFolderBlob(blob: new, keyring: first, itemID: "b", ownerSigningKey: owner.publicKeys.signingKey) }
        // Item ids and tags come from epoch 1 and survive rotation.
        #expect(try sharedFolderItemID(keyring: first, meetingID: "20261108-100000") == sharedFolderItemID(keyring: second, meetingID: "20261108-100000"))
        #expect(try sharedFolderItemID(keyring: first, meetingID: "20261108-100000").count == 36)
    }

    @Test func envelopesOpenOnlyForTheirMemberFolderAndOwner() throws {
        let keyring: FolderKeyring = rotatedFolderKeyring(keyring: newFolderKeyring(folderID: folderID))
        let envelope: Data = try sealKeyringEnvelope(keyring: keyring, recipient: member.publicKeys, memberID: "m1", owner: owner)
        let opened: FolderKeyring = try openKeyringEnvelope(envelope: envelope, recipient: member, folderID: folderID, memberID: "m1", ownerSigningKey: owner.publicKeys.signingKey)
        #expect(opened == keyring)
        #expect(throws: SharedFolderCryptoError.self) { try openKeyringEnvelope(envelope: envelope, recipient: owner, folderID: folderID, memberID: "m1", ownerSigningKey: owner.publicKeys.signingKey) }
        #expect(throws: SharedFolderCryptoError.badSignature) { try openKeyringEnvelope(envelope: envelope, recipient: member, folderID: folderID, memberID: "m2", ownerSigningKey: owner.publicKeys.signingKey) }
        #expect(throws: SharedFolderCryptoError.badSignature) { try openKeyringEnvelope(envelope: envelope, recipient: member, folderID: folderID, memberID: "m1", ownerSigningKey: member.publicKeys.signingKey) }
        // A server that wraps its own keyring and signs it with its own key is caught by the owner signature.
        let server: SharingIdentity = try newSharingIdentity()
        let fake: Data = try sealKeyringEnvelope(keyring: newFolderKeyring(folderID: folderID), recipient: member.publicKeys, memberID: "m1", owner: server)
        #expect(throws: SharedFolderCryptoError.badSignature) { try openKeyringEnvelope(envelope: fake, recipient: member, folderID: folderID, memberID: "m1", ownerSigningKey: owner.publicKeys.signingKey) }
    }

    @Test func rostersAreSignedAndBoundToTheFolder() throws {
        let roster: SharedFolderRoster = SharedFolderRoster(folderId: folderID, version: 2, epoch: 1, members: [SharedFolderRosterMember(memberId: "m1", userId: "u", keys: member.publicKeys)])
        let signed: SignedSharedFolderRoster = try signSharedFolderRoster(roster: roster, owner: owner)
        #expect(try verifySharedFolderRoster(text: signed.text, signature: signed.signature, ownerSigningKey: owner.publicKeys.signingKey, folderID: folderID) == roster)
        let swapped: String = signed.text.replacingOccurrences(of: member.publicKeys.agreementKey.base64EncodedString(), with: owner.publicKeys.agreementKey.base64EncodedString())
        #expect(throws: SharedFolderCryptoError.badSignature) { try verifySharedFolderRoster(text: swapped, signature: signed.signature, ownerSigningKey: owner.publicKeys.signingKey, folderID: folderID) }
        #expect(throws: SharedFolderCryptoError.wrongFolder) { try verifySharedFolderRoster(text: signed.text, signature: signed.signature, ownerSigningKey: owner.publicKeys.signingKey, folderID: "other") }
        // Keys and ids exactly as the server's schema expects them.
        let json: [String: Any] = try #require(try JSONSerialization.jsonObject(with: Data(signed.text.utf8)) as? [String: Any])
        #expect(Set(json.keys) == ["folderId", "version", "epoch", "members"])
    }

    @Test func invitesAuthenticateBothSidesAndKeepLabelsFromMembers() throws {
        let invite: SharedFolderInvite = newSharedFolderInvite()
        let link: URL = sharedFolderInviteLink(siteOrigin: try #require(URL(string: "https://gistsmith.com")), invite: invite)
        #expect(link.absoluteString.hasPrefix("https://gistsmith.com/j#\(invite.inviteID)."))
        #expect(try sharedFolderInvite(text: " \(link.absoluteString)\n") == invite)
        #expect(try sharedFolderInvite(text: "gistsmith://join#\(try #require(link.fragment()))") == invite)
        for bad in ["https://gistsmith.com/s#\(try #require(link.fragment()))", "https://gistsmith.com/j", "https://gistsmith.com/j#abc.def", "hello"] {
            #expect(throws: SharedFolderCryptoError.invalidInviteLink) { try sharedFolderInvite(text: bad) }
        }
        let ownerProof: Data = sharedFolderOwnerProof(invite: invite, folderID: folderID, owner: owner.publicKeys)
        try verifySharedFolderOwnerProof(proof: ownerProof, invite: invite, folderID: folderID, owner: owner.publicKeys)
        // The server swapping in its own owner keys fails the invitee's check.
        #expect(throws: SharedFolderCryptoError.proofMismatch) { try verifySharedFolderOwnerProof(proof: ownerProof, invite: invite, folderID: folderID, owner: member.publicKeys) }
        let memberProof: Data = sharedFolderMemberProof(invite: invite, folderID: folderID, memberUserID: "u-member", member: member.publicKeys)
        try verifySharedFolderMemberProof(proof: memberProof, invite: invite, folderID: folderID, memberUserID: "u-member", member: member.publicKeys)
        // Swapped keys or another account are refused before any keyring is wrapped.
        #expect(throws: SharedFolderCryptoError.proofMismatch) { try verifySharedFolderMemberProof(proof: memberProof, invite: invite, folderID: folderID, memberUserID: "u-member", member: owner.publicKeys) }
        #expect(throws: SharedFolderCryptoError.proofMismatch) { try verifySharedFolderMemberProof(proof: memberProof, invite: invite, folderID: folderID, memberUserID: "u-other", member: member.publicKeys) }
        // Labels and secrets open only with the owner's identity, never with a member's.
        let label: Data = try sealSharedFolderInviteLabel(label: "ayse@example.com", owner: owner, folderID: folderID, inviteID: invite.inviteID)
        #expect(try openSharedFolderInviteLabel(sealed: label, owner: owner, folderID: folderID, inviteID: invite.inviteID) == "ayse@example.com")
        #expect(throws: SharedFolderCryptoError.authenticationFailed) { try openSharedFolderInviteLabel(sealed: label, owner: member, folderID: folderID, inviteID: invite.inviteID) }
        let secret: Data = try sealSharedFolderInviteSecret(invite: invite, owner: owner, folderID: folderID)
        #expect(try openSharedFolderInviteSecret(sealed: secret, owner: owner, folderID: folderID, inviteID: invite.inviteID) == invite)
        let preview: SharedFolderInvitePreview = SharedFolderInvitePreview(folderName: "Sales weekly", ownerName: "Ayşe")
        let sealedPreview: Data = try sealSharedFolderInvitePreview(preview: preview, invite: invite, folderID: folderID)
        #expect(try openSharedFolderInvitePreview(sealed: sealedPreview, invite: invite, folderID: folderID) == preview)
        #expect(throws: SharedFolderCryptoError.authenticationFailed) { try openSharedFolderInvitePreview(sealed: sealedPreview, invite: newSharedFolderInvite(), folderID: folderID) }
        let pin: SharedFolderPin = SharedFolderPin(ownerKeys: owner.publicKeys, folderName: "Sales weekly", ownerName: "Ayşe")
        #expect(try openSharedFolderPin(sealed: try sealSharedFolderPin(pin: pin, member: member, folderID: folderID), member: member, folderID: folderID) == pin)
    }
}

@Suite struct SharedFolderPlanTests {
    private func remote(_ id: String, _ tag: String) -> SharedFolderRemoteItem {
        SharedFolderRemoteItem(itemId: id, keyEpoch: 1, tag: tag, size: 100, rev: 1)
    }

    @Test func publishPlanUploadsChangedAndDeletesOnlyOwnPublishedItems() {
        let plan: SharedFolderPublishPlan = sharedFolderPublishPlan(
            local: [SharedFolderLocalItem(itemID: "a", tag: "1"), SharedFolderLocalItem(itemID: "b", tag: "2"), SharedFolderLocalItem(itemID: "c", tag: "3")],
            remote: [remote("a", "1"), remote("b", "old"), remote("gone", "x"), remote("other-device", "y")],
            ledger: ["a", "gone"]
        )
        #expect(plan == SharedFolderPublishPlan(uploads: ["b", "c"], deletes: ["gone"], ledger: ["a", "b", "c"]))
        // A device that took over publishing adopts its notes already on the server, so it can remove one that later
        // leaves the folder.
        let takeover: SharedFolderPublishPlan = sharedFolderPublishPlan(local: [SharedFolderLocalItem(itemID: "m", tag: "1")], remote: [remote("m", "1")], ledger: [])
        #expect(takeover.uploads.isEmpty && takeover.ledger == ["m"])
        let movedOut: SharedFolderPublishPlan = sharedFolderPublishPlan(local: [], remote: [remote("m", "1")], ledger: takeover.ledger)
        #expect(movedOut.deletes == ["m"] && movedOut.ledger.isEmpty)
    }

    private func rosterMember(_ id: String) throws -> SharedFolderRosterMember {
        SharedFolderRosterMember(memberId: id, userId: "u-\(id)", keys: try newSharingIdentity().publicKeys)
    }

    @Test func rosterActionRotatesWhenSomeoneLeftOrIsRemovedAndActivatesOtherwise() throws {
        let a: SharedFolderRosterMember = try rosterMember("a")
        let b: SharedFolderRosterMember = try rosterMember("b")
        let c: SharedFolderRosterMember = try rosterMember("c")
        let roster: SharedFolderRoster = SharedFolderRoster(folderId: "f", version: 3, epoch: 1, members: [a, b])
        #expect(sharedFolderRosterAction(roster: roster, serverActiveIDs: ["a", "b"], needsRotation: false, removing: [], acceptances: []) == .none)
        #expect(
            sharedFolderRosterAction(roster: roster, serverActiveIDs: ["a", "b"], needsRotation: false, removing: [], acceptances: [SharedFolderAcceptance(member: c)])
                == .activate(members: [a, b, c], added: ["c"])
        )
        // b left (the server no longer has it active): rotate it out and take c in with the new epoch.
        #expect(
            sharedFolderRosterAction(roster: roster, serverActiveIDs: ["a"], needsRotation: true, removing: [], acceptances: [SharedFolderAcceptance(member: c)])
                == .rotate(members: [a, c])
        )
        #expect(sharedFolderRosterAction(roster: roster, serverActiveIDs: ["a", "b"], needsRotation: false, removing: ["a"], acceptances: []) == .rotate(members: [b]))
    }

    @Test func versionPinsRefuseRollbackAndCachesSurviveTheSwitchBeingOff() throws {
        let pin: SharedFolderVersionPin = try advancedSharedFolderPin(stored: nil, epoch: 2, rosterVersion: 5)
        #expect(throws: SharedFolderCryptoError.staleVersion(seen: 2, served: 1)) { try advancedSharedFolderPin(stored: pin, epoch: 1, rosterVersion: 6) }
        #expect(throws: SharedFolderCryptoError.staleVersion(seen: 5, served: 4)) { try advancedSharedFolderPin(stored: pin, epoch: 2, rosterVersion: 4) }
        #expect(sharedFolderCachesToKeep(cached: ["a", "b"], listed: ["a"], available: true) == ["a"])
        #expect(sharedFolderCachesToKeep(cached: ["a", "b"], listed: [], available: false) == ["a", "b"])
    }

    @Test func sampleMeetingAndMeetingsWithoutANoteAreNeverShared() throws {
        let payload: SharedFolderItemPayload = sampleSharedFolderPayload(marker: "x")
        let data: Data = try canonicalJSON(payload)
        #expect(try JSONDecoder().decode(SharedFolderItemPayload.self, from: data) == payload)
    }

    @Test func inviteLinksOpenTheJoinScreenAndBrokenOnesAreIgnored() throws {
        let invite: SharedFolderInvite = newSharedFolderInvite()
        let web: URL = sharedFolderInviteLink(siteOrigin: try #require(URL(string: "https://gistsmith.com")), invite: invite)
        #expect(appLinkRoute(url: web) == .joinSharedFolder(link: web.absoluteString))
        let fragment: String = try #require(web.fragment())
        let app: URL = try #require(URL(string: "gistsmith://join#\(fragment)"))
        #expect(appLinkRoute(url: app) == .joinSharedFolder(link: app.absoluteString))
        for text in ["https://gistsmith.com/j", "https://gistsmith.com/j#short.key", "gistsmith://join", "https://example.com/j#\(fragment)"] {
            #expect(appLinkRoute(url: try #require(URL(string: text))) == nil)
        }
        // Other links still route as before.
        #expect(appLinkRoute(url: try #require(URL(string: "gistsmith://record"))) == .record)
    }

    @Test func limitsAndFormatsMatchTheServer() throws {
        let source: String = try String(contentsOf: serverDirectory().appending(path: "src/sharedFolders.ts"), encoding: .utf8)
        func constant(_ name: String) throws -> String {
            let match = try #require(source.firstMatch(of: try Regex("export const \(name): (?:number|string) = ([^;]+);")))
            return String(try #require(match.output[1].substring)).replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "\"", with: "")
        }
        #expect(try constant("sharedFolderItemMagic") == sharedFolderItemMagic)
        #expect(try constant("sharedFolderItemMaxBytes") == String(sharedFolderItemMaxBytes))
        #expect(try constant("sharedFolderMaxItems") == String(SharedFolderLimits.maxItems))
        #expect(try constant("sharedFolderMaxOwned") == String(SharedFolderLimits.maxOwnedFolders))
        #expect(try constant("sharedFolderMaxMemberships") == String(SharedFolderLimits.maxMemberships))
        #expect(try constant("sharedFolderMaxMembers") == String(SharedFolderLimits.maxMembers))
        #expect(try constant("sharedFolderMaxOpenInvites") == String(SharedFolderLimits.maxOpenInvites))
        #expect(try constant("sharedFolderInviteTtlDays") == String(SharedFolderLimits.inviteTTLDays))
    }
}
