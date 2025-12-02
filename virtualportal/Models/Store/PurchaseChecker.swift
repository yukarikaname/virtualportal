//import Foundation
//import StoreKit
//
///// PurchaseChecker checks whether the app is a legitimate App Store purchase.
//class PurchaseChecker {
//    
//    /// Shared singleton instance
//    static let shared = PurchaseChecker()
//    private init() {}
//    
//    /// Checks app purchase status
//    /// - Returns: `true` if the app is a verified App Store purchase
//    func isAppPurchased() async -> Bool {
//        do {
//            // Get the app transaction (app itself, not IAP)
//            let appTransaction = try await AppTransaction.shared
//            
//            switch appTransaction {
//            case .verified(let transaction):
//                return true
//                
//            case .unverified(let transaction, let verificationError):
//                return false
//            }
//            
//        } catch {
//            print("Failed to fetch app transaction: \(error.localizedDescription)")
//            return false
//        }
//    }
//}
