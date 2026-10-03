import Foundation
import StoreKit
import SwiftUI

public enum DonationProductID {
    public static let coffee = "com.fugary.genplayer.tip.coffee"
    public static let tea = "com.fugary.genplayer.tip.tea"
    public static let lifetime = "com.fugary.genplayer.supporter.lifetime"

    public static let all: [String] = [coffee, tea, lifetime]
}

public final class DonationService: NSObject, ObservableObject {
    public static let shared = DonationService()

    private let userDefaults = UserDefaults.standard
    private let iCloudStore = NSUbiquitousKeyValueStore.default

    private let keyPurchasedCoffee = "donation_purchased_coffee"
    private let keyPurchasedTea = "donation_purchased_tea"
    private let keyPurchasedLifetime = "donation_purchased_lifetime"

    @Published public private(set) var products: [SKProduct] = []
    @Published public private(set) var isLoadingProducts = false
    @Published public private(set) var isPurchasing = false
    @Published public private(set) var isRestoring = false
    @Published public var purchaseErrorMessage: String?
    @Published public var shouldShowThankYou = false

    @Published public private(set) var hasPurchasedCoffee: Bool = false
    @Published public private(set) var hasPurchasedTea: Bool = false
    @Published public private(set) var hasPurchasedLifetime: Bool = false

    private var productsRequest: SKProductsRequest?

    override private init() {
        super.init()
        loadPersistedState()
        SKPaymentQueue.default().add(self)
        registerICloudNotification()
        if isChinaStorefront {
            fetchProducts()
        }
    }

    deinit {
        SKPaymentQueue.default().remove(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Storefront & Regional Logic

    /// Returns true if the user's active App Store account is registered in China (Mainland China / "CHN").
    /// In Release mode, only returns true if the StoreKit storefront country code is explicitly "CHN".
    /// If storefront is unavailable or overseas, returns false (defaulting to overseas paid app behavior).
    public var isChinaStorefront: Bool {
        #if DEBUG
        if let forced = UserDefaults.standard.object(forKey: "debug_force_china_storefront") as? Bool {
            return forced
        }
        return true
        #else
        if #available(iOS 13.0, macOS 10.15, tvOS 13.0, *) {
            if let countryCode = SKPaymentQueue.default().storefront?.countryCode {
                return countryCode.uppercased() == "CHN"
            }
        }
        return false
        #endif
    }

    /// Determines if the user is a Lifetime Supporter.
    /// - For China storefront: unlocked if lifetime was purchased OR (coffee AND tea) were purchased.
    /// - For overseas storefronts: users paid upfront when downloading the paid app, so they automatically get lifetime supporter perks.
    public var isLifetimeSupporter: Bool {
        guard isChinaStorefront else {
            return true
        }
        return hasPurchasedLifetime || (hasPurchasedCoffee && hasPurchasedTea)
    }

    /// Progress toward synthesizing lifetime supporter status (0, 1, or 2).
    public var supporterProgressCount: Int {
        if isLifetimeSupporter { return 2 }
        var count = 0
        if hasPurchasedCoffee { count += 1 }
        if hasPurchasedTea { count += 1 }
        return count
    }

    // MARK: - Products & Pricing

    public func fetchProducts() {
        guard isChinaStorefront else { return }
        guard !isLoadingProducts else { return }
        isLoadingProducts = true

        let request = SKProductsRequest(productIdentifiers: Set(DonationProductID.all))
        request.delegate = self
        self.productsRequest = request
        request.start()
    }

    public func product(for productID: String) -> SKProduct? {
        products.first(where: { $0.productIdentifier == productID })
    }

    public func formattedPrice(for productID: String) -> String {
        if let product = product(for: productID) {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.locale = product.priceLocale
            return formatter.string(from: product.price) ?? "¥\(product.price)"
        }

        // Fallback default pricing (CNY only)
        switch productID {
        case DonationProductID.coffee:
            return "¥6.00"
        case DonationProductID.tea:
            return "¥6.00"
        case DonationProductID.lifetime:
            return "¥12.00"
        default:
            return "¥6.00"
        }
    }

    // MARK: - Purchase Actions

    public func purchase(productID: String) {
        guard isChinaStorefront else {
            purchaseErrorMessage = NSLocalizedString("In-App Purchases are disabled on this device.", comment: "")
            return
        }

        guard SKPaymentQueue.canMakePayments() else {
            purchaseErrorMessage = NSLocalizedString("In-App Purchases are disabled on this device.", comment: "")
            return
        }

        guard !isPurchasing else { return }

        if let product = product(for: productID) {
            isPurchasing = true
            purchaseErrorMessage = nil
            let payment = SKPayment(product: product)
            SKPaymentQueue.default().add(payment)
        } else {
            // If product is not yet loaded, retry fetching
            fetchProducts()
            #if DEBUG
            purchaseErrorMessage = NSLocalizedString("Product not loaded yet. If testing on device/simulator, make sure Xcode -> Edit Scheme -> Run -> Options -> StoreKit Configuration is set to 'Donation.storekit'.", comment: "")
            #else
            purchaseErrorMessage = NSLocalizedString("Connecting to App Store, please try again shortly.", comment: "")
            #endif
        }
    }

    public func restorePurchases() {
        guard isChinaStorefront else { return }
        guard !isRestoring else { return }
        isRestoring = true
        purchaseErrorMessage = nil
        SKPaymentQueue.default().restoreCompletedTransactions()
    }

    // MARK: - Persistence & iCloud Sync

    private func loadPersistedState() {
        iCloudStore.synchronize()

        let localCoffee = userDefaults.bool(forKey: keyPurchasedCoffee)
        let iCloudCoffee = iCloudStore.bool(forKey: keyPurchasedCoffee)
        hasPurchasedCoffee = localCoffee || iCloudCoffee

        let localTea = userDefaults.bool(forKey: keyPurchasedTea)
        let iCloudTea = iCloudStore.bool(forKey: keyPurchasedTea)
        hasPurchasedTea = localTea || iCloudTea

        let localLifetime = userDefaults.bool(forKey: keyPurchasedLifetime)
        let iCloudLifetime = iCloudStore.bool(forKey: keyPurchasedLifetime)
        hasPurchasedLifetime = localLifetime || iCloudLifetime
    }

    private func recordPurchase(productID: String) {
        switch productID {
        case DonationProductID.coffee:
            hasPurchasedCoffee = true
            userDefaults.set(true, forKey: keyPurchasedCoffee)
            iCloudStore.set(true, forKey: keyPurchasedCoffee)
        case DonationProductID.tea:
            hasPurchasedTea = true
            userDefaults.set(true, forKey: keyPurchasedTea)
            iCloudStore.set(true, forKey: keyPurchasedTea)
        case DonationProductID.lifetime:
            hasPurchasedLifetime = true
            userDefaults.set(true, forKey: keyPurchasedLifetime)
            iCloudStore.set(true, forKey: keyPurchasedLifetime)
        default:
            break
        }

        iCloudStore.synchronize()
        shouldShowThankYou = true
    }

    private func registerICloudNotification() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iCloudStoreDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: iCloudStore
        )
    }

    @objc private func iCloudStoreDidChange(notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.loadPersistedState()
        }
    }
}

// MARK: - SKProductsRequestDelegate

extension DonationService: SKProductsRequestDelegate {
    public func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isLoadingProducts = false
            self.products = response.products
            if !response.invalidProductIdentifiers.isEmpty {
                print("DonationService: Invalid product IDs: \(response.invalidProductIdentifiers)")
            }
        }
    }

    public func request(_ request: SKRequest, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isLoadingProducts = false
            print("DonationService: Product request failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - SKPaymentTransactionObserver

extension DonationService: SKPaymentTransactionObserver {
    public func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            switch transaction.transactionState {
            case .purchased:
                handlePurchased(transaction)
            case .restored:
                handleRestored(transaction)
            case .failed:
                handleFailed(transaction)
            case .deferred, .purchasing:
                break
            @unknown default:
                break
            }
        }
    }

    private func handlePurchased(_ transaction: SKPaymentTransaction) {
        let productID = transaction.payment.productIdentifier
        recordPurchase(productID: productID)
        SKPaymentQueue.default().finishTransaction(transaction)

        DispatchQueue.main.async { [weak self] in
            self?.isPurchasing = false
            self?.purchaseErrorMessage = nil
        }
    }

    private func handleRestored(_ transaction: SKPaymentTransaction) {
        let productID = transaction.payment.productIdentifier
        recordPurchase(productID: productID)
        SKPaymentQueue.default().finishTransaction(transaction)

        DispatchQueue.main.async { [weak self] in
            self?.isPurchasing = false
            self?.purchaseErrorMessage = nil
        }
    }

    private func handleFailed(_ transaction: SKPaymentTransaction) {
        let error = transaction.error as? SKError
        SKPaymentQueue.default().finishTransaction(transaction)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPurchasing = false
            if error?.code != .paymentCancelled {
                self.purchaseErrorMessage = error?.localizedDescription ?? NSLocalizedString("Payment could not be completed. Please try again.", comment: "")
            }
        }
    }

    public func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRestoring = false
            self.loadPersistedState()
        }
    }

    public func paymentQueue(_ queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRestoring = false
            let skError = error as? SKError
            if skError?.code != .paymentCancelled {
                self.purchaseErrorMessage = error.localizedDescription
            }
        }
    }
}
