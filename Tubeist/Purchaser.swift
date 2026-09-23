//
//  IAPManager.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2025-01-19.
//

import StoreKit
import Observation

/// Reconcile the launch snapshot without undoing newer transaction updates.
@Observable @MainActor
final class PurchaseEntitlements {
    private(set) var productIDs: Set<String>
    private var verificationID: UUID?
    private var updates: [String: Bool] = [:]

    init(productIDs: Set<String> = []) {
        self.productIDs = productIDs
    }

    func beginVerification() -> UUID {
        let id = UUID()
        verificationID = id
        updates = [:]
        return id
    }

    func setPurchased(_ purchased: Bool, productID: String) {
        if purchased { productIDs.insert(productID) }
        else { productIDs.remove(productID) }
        if verificationID != nil { updates[productID] = purchased }
    }

    @discardableResult
    func finishVerification(_ verified: Set<String>, id: UUID) -> Bool {
        guard verificationID == id else { return false }
        var result = verified
        for (productID, purchased) in updates {
            if purchased { result.insert(productID) }
            else { result.remove(productID) }
        }
        productIDs = result
        verificationID = nil
        updates = [:]
        return true
    }
}

actor Purchaser {
    static let shared = Purchaser()
    
    private init() {
        Task {
            await listenForTransactions()
        }
    }
    
    private let productIdentifiers: Set<String> = ["tubeist_lifetime_styling"]
    private(set) var availableProducts: [Product] = []
    
    // Keep track of purchased product IDs
    @MainActor private static let entitlements = PurchaseEntitlements(
        productIDs: Set(UserDefaults.standard.stringArray(forKey: "purchased_products") ?? [])
    )
    
    @MainActor
    func isProductPurchased(_ productID: String) -> Bool {
        YOU_HAVE_IT_ALL || Self.entitlements.productIDs.contains(productID)
    }
    
    // Verify past purchases on app launch
    @MainActor
    func verifyPurchases() async {
        let verificationID = Self.entitlements.beginVerification()
        var validProductIDs = Set<String>()
        
        // Get all valid transactions
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                LOG("Verified entitlement for \(transaction.productID)", level: .info)
                validProductIDs.insert(transaction.productID)
            }
        }
        
        // Update the stored purchases to match exactly what's valid
        if Self.entitlements.finishVerification(validProductIDs, id: verificationID) {
            persistEntitlements()
            resetStylingIfUnentitled()
        }
    }
    
    private func listenForTransactions() async {
        for await result in Transaction.updates {
            LOG("Transaction handled by App Store in progress", level: .debug)
            if case .verified(let transaction) = result {
                // Handle the transaction based on its state
                switch transaction.revocationDate {
                case .some(_):  // Purchase was revoked
                    await removePurchase(productID: transaction.productID)
                case .none:     // Purchase is valid
                    await savePurchase(productID: transaction.productID)
                }
                await transaction.finish()
            }
        }
    }
    
    @MainActor
    private func savePurchase(productID: String) {
        LOG("Entitled for \(productID)", level: .debug)
        Self.entitlements.setPurchased(true, productID: productID)
        persistEntitlements()
    }
    
    @MainActor
    private func removePurchase(productID: String) {
        Self.entitlements.setPurchased(false, productID: productID)
        persistEntitlements()
        resetStylingIfUnentitled()
    }

    /// After a refund or revocation the styling button is locked, so a saved
    /// paid style or effect could otherwise never be turned off again.
    @MainActor
    private func resetStylingIfUnentitled() {
        guard !isProductPurchased("tubeist_lifetime_styling"),
              Settings.style != nil || Settings.effect != nil else { return }
        LOG("Styling is no longer purchased; turning off the selected style and effect", level: .info)
        Settings.style = NO_STYLE
        Settings.effect = NO_EFFECT
        Task {
            await FrameGrabber.shared.refreshStyle()
            await FrameGrabber.shared.refreshEffect()
        }
    }

    @MainActor
    private func persistEntitlements() {
        UserDefaults.standard.set(Array(Self.entitlements.productIDs), forKey: "purchased_products")
    }
    
    func fetchProducts() async -> [Product] {
        do {
            availableProducts = try await Product.products(for: productIdentifiers)
            for product in availableProducts {
                LOG("Product: \(product.displayName), Price: \(product.displayPrice)", level: .debug)
            }
        } catch {
            LOG("Failed to fetch products: \(error)", level: .error)
        }
        return availableProducts
    }
        
    func purchase(product: Product) async {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await savePurchase(productID: transaction.productID)
                    await transaction.finish()
                case .unverified(_, let error):
                    LOG("Unverified transaction: \(error)", level: .error)
                }
            case .userCancelled:
                LOG("User cancelled the transaction", level: .warning)
            case .pending:
                LOG("Transaction is pending", level: .debug)
            @unknown default:
                LOG("Unhandled type of purchase result", level: .error)
            }
        } catch {
            LOG("Purchase failed: \(error)", level: .error)
        }
    }
}
