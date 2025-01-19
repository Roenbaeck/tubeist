//
//  IAPManager.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2025-01-19.
//

import StoreKit

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
    @MainActor
    private var purchasedProductIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "purchased_products") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "purchased_products") }
    }
    
    @MainActor
    func isProductPurchased(_ productID: String) -> Bool {
        purchasedProductIDs.contains(productID)
    }
    
    // Verify past purchases on app launch
    @MainActor
    func verifyPurchases() async {
        var validProductIDs = Set<String>()
        
        // Get all valid transactions
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                LOG("Verified entitlement for \(transaction.productID)", level: .info)
                validProductIDs.insert(transaction.productID)
            }
        }
        
        // Update the stored purchases to match exactly what's valid
        purchasedProductIDs = validProductIDs
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
        LOG("Entitled for \(productID)", level: .info)
        purchasedProductIDs.insert(productID)
    }
    
    @MainActor
    private func removePurchase(productID: String) {
        purchasedProductIDs.remove(productID)
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
