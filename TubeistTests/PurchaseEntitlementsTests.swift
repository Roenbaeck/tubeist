import Testing
@testable import Tubeist

@MainActor
struct PurchaseEntitlementsTests {
    @Test func launchSnapshotCannotUndoANewerPurchaseOrRevocation() {
        let state = PurchaseEntitlements(productIDs: ["revoked", "stale-cache"])
        let verification = state.beginVerification()
        state.setPurchased(true, productID: "new-purchase")
        state.setPurchased(false, productID: "revoked")
        state.finishVerification(["revoked", "still-owned"], id: verification)
        #expect(state.productIDs == ["new-purchase", "still-owned"])
    }

    @Test func olderVerificationCannotReplaceANewerSnapshot() {
        let state = PurchaseEntitlements()
        let old = state.beginVerification()
        let current = state.beginVerification()
        state.setPurchased(true, productID: "new-purchase")
        #expect(!state.finishVerification(["old-purchase"], id: old))
        #expect(state.finishVerification(["current-purchase"], id: current))
        #expect(state.productIDs == ["new-purchase", "current-purchase"])
    }

    @Test func lastUpdateWinsAndAnEmptySnapshotClearsOldCachedPurchases() {
        let state = PurchaseEntitlements(productIDs: ["cached"])
        let verification = state.beginVerification()
        state.setPurchased(true, productID: "changed")
        state.setPurchased(false, productID: "changed")
        state.finishVerification([], id: verification)
        #expect(state.productIDs.isEmpty)
    }
}
