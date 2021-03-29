//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import MobileCoin

class MobileCoinAPI: Dependencies {

    // MARK: - Passphrases & Entropy

    public static func passphrase(forPaymentsEntropy paymentsEntropy: Data) throws -> PaymentsPassphrase {
        guard paymentsEntropy.count == PaymentsConstants.paymentsEntropyLength else {
            throw PaymentsError.invalidEntropy
        }
        let result = MobileCoin.Mnemonic.mnemonic(fromEntropy: paymentsEntropy)
        switch result {
        case .success(let mnemonic):
            return try PaymentsPassphrase.parse(passphrase: mnemonic,
                                                validateWords: false)
        case .failure(let error):
            owsFailDebug("Error: \(error)")
            let error = Self.convertMCError(error: error)
            throw error
        }
    }

    public static func paymentsEntropy(forPassphrase passphrase: PaymentsPassphrase) throws -> Data {
        let mnemonic = passphrase.asPassphrase
        let result = MobileCoin.Mnemonic.entropy(fromMnemonic: mnemonic)
        switch result {
        case .success(let paymentsEntropy):
            guard paymentsEntropy.count == PaymentsConstants.paymentsEntropyLength else {
                throw PaymentsError.invalidEntropy
            }
            return paymentsEntropy
        case .failure(let error):
            owsFailDebug("Error: \(error)")
            let error = Self.convertMCError(error: error)
            throw error
        }
    }

    public static func mcRootEntropy(forPaymentsEntropy paymentsEntropy: Data) throws -> Data {
        guard paymentsEntropy.count == PaymentsConstants.paymentsEntropyLength else {
            throw PaymentsError.invalidEntropy
        }
        let passphrase = try Self.passphrase(forPaymentsEntropy: paymentsEntropy)
        let mnemonic = passphrase.asPassphrase
        let result = AccountKey.rootEntropy(fromMnemonic: mnemonic, accountIndex: 0)
        switch result {
        case .success(let mcRootEntropy):
            guard mcRootEntropy.count == PaymentsConstants.mcRootEntropyLength else {
                throw PaymentsError.invalidEntropy
            }
            return mcRootEntropy
        case .failure(let error):
            owsFailDebug("Error: \(error)")
            let error = Self.convertMCError(error: error)
            throw error
        }
    }

    public static func isValidPassphraseWord(_ word: String?) -> Bool {
        guard let word = word?.strippedOrNil else {
            return false
        }
        return !MobileCoin.Mnemonic.words(matchingPrefix: word).isEmpty
    }

    // MARK: -

    private let mcRootEntropy: Data

    // PAYMENTS TODO: Finalize this value with the designers.
    private static let timeoutDuration: TimeInterval = 60

    public let localAccount: MobileCoinAccount

    private let client: MobileCoinClient

    private init(mcRootEntropy: Data,
                 localAccount: MobileCoinAccount,
                 client: MobileCoinClient) throws {

        guard mcRootEntropy.count == PaymentsConstants.mcRootEntropyLength else {
            throw PaymentsError.invalidEntropy
        }

        owsAssertDebug(Self.payments.arePaymentsEnabled)

        self.mcRootEntropy = mcRootEntropy
        self.localAccount = localAccount
        self.client = client
    }

    // MARK: -

    public static func configureSDKLogging() {
        if DebugFlags.internalLogging {
            MobileCoinLogging.logSensitiveData = true
        }
    }

    // MARK: -

    public static func buildLocalAccount(mcRootEntropy: Data) throws -> MobileCoinAccount {
        try Self.buildAccount(forMCRootEntropy: mcRootEntropy)
    }

    private static func parseAuthorizationResponse(responseObject: Any?) throws -> OWSAuthorization {
        guard let params = ParamParser(responseObject: responseObject) else {
            throw OWSAssertionError("Invalid responseObject.")
        }
        let username: String = try params.required(key: "username")
        let password: String = try params.required(key: "password")
        return OWSAuthorization(username: username, password: password)
    }

    public static func buildPromise(mcRootEntropy: Data) -> Promise<MobileCoinAPI> {
        firstly(on: .global()) { () -> Promise<TSNetworkManager.Response> in
            let request = OWSRequestFactory.paymentsAuthenticationCredentialRequest()
            return Self.networkManager.makePromise(request: request)
        }.map(on: .global()) { (_: URLSessionDataTask, responseObject: Any?) -> OWSAuthorization in
            try Self.parseAuthorizationResponse(responseObject: responseObject)
        }.map(on: .global()) { (signalAuthorization: OWSAuthorization) -> MobileCoinAPI in
            let localAccount = try Self.buildAccount(forMCRootEntropy: mcRootEntropy)
            let client = try localAccount.buildClient(signalAuthorization: signalAuthorization)
            return try MobileCoinAPI(mcRootEntropy: mcRootEntropy,
                                     localAccount: localAccount,
                                     client: client)
        }
    }

    // MARK: -

    class func isValidMobileCoinPublicAddress(_ publicAddressData: Data) -> Bool {
        MobileCoin.PublicAddress(serializedData: publicAddressData) != nil
    }

    // MARK: -

    func getLocalBalance() -> Promise<TSPaymentAmount> {
        Logger.verbose("")

        let client = self.client

        return firstly(on: .global()) { () throws -> Promise<MobileCoin.Balance> in
            let (promise, resolver) = Promise<MobileCoin.Balance>.pending()
            if DebugFlags.paymentsNoRequestsComplete.get() {
                // Never resolve.
                return promise
            }
            client.updateBalance { (result: Swift.Result<Balance, ConnectionError>) in
                switch result {
                case .success(let balance):
                    resolver.fulfill(balance)
                case .failure(let error):
                    let error = Self.convertMCError(error: error)
                    resolver.reject(error)
                }
            }
            return promise
        }.map(on: .global()) { (balance: MobileCoin.Balance) -> TSPaymentAmount in
            Logger.verbose("Success: \(balance)")
            // We do not need to support amountPicoMobHigh.
            guard let amountPicoMob = balance.amountPicoMob() else {
                throw OWSAssertionError("Invalid balance.")
            }
            return TSPaymentAmount(currency: .mobileCoin, picoMob: amountPicoMob)
        }.recover(on: .global()) { (error: Error) -> Promise<TSPaymentAmount> in
            owsFailDebugUnlessMCNetworkFailure(error)
            throw error
        }.timeout(seconds: Self.timeoutDuration, description: "getLocalBalance") { () -> Error in
            PaymentsError.timeout
        }
    }

    func getEstimatedFee(forPaymentAmount paymentAmount: TSPaymentAmount) throws -> TSPaymentAmount {
        Logger.verbose("")

        guard paymentAmount.isValidAmount(canBeEmpty: false) else {
            throw OWSAssertionError("Invalid amount.")
        }

        // We don't need to support amountPicoMobHigh.
        let result = client.estimateTotalFee(toSendAmount: paymentAmount.picoMob,
                                             feeLevel: Self.feeLevel)
        switch result {
        case .success(let feePicoMob):
            let fee = TSPaymentAmount(currency: .mobileCoin, picoMob: feePicoMob)
            guard fee.isValidAmount(canBeEmpty: false) else {
                throw OWSAssertionError("Invalid amount.")
            }
            Logger.verbose("Success paymentAmount: \(paymentAmount), fee: \(fee), ")
            return fee
        case .failure(let error):
            let error = Self.convertMCError(error: error)
            if case PaymentsError.insufficientFunds = error {
                Logger.warn("Error: \(error)")
            } else {
                owsFailDebugUnlessMCNetworkFailure(error)
            }
            throw error
        }
    }

    func maxTransactionAmount() throws -> TSPaymentAmount {
        // We don't need to support amountPicoMobHigh.
        let result = client.amountTransferable(feeLevel: Self.feeLevel)
        switch result {
        case .success(let feePicoMob):
            let paymentAmount = TSPaymentAmount(currency: .mobileCoin, picoMob: feePicoMob)
            guard paymentAmount.isValidAmount(canBeEmpty: true) else {
                throw OWSAssertionError("Invalid amount.")
            }
            Logger.verbose("Success paymentAmount: \(paymentAmount), ")
            return paymentAmount
        case .failure(let error):
            let error = Self.convertMCError(error: error)
            owsFailDebugUnlessMCNetworkFailure(error)
            throw error
        }
    }

    struct PreparedTransaction {
        let transaction: MobileCoin.Transaction
        let receipt: MobileCoin.Receipt
        let feeAmount: TSPaymentAmount
    }

    func prepareTransaction(paymentAmount: TSPaymentAmount,
                            recipientPublicAddress: MobileCoin.PublicAddress,
                            shouldUpdateBalance: Bool) -> Promise<PreparedTransaction> {
        Logger.verbose("")

        let client = self.client

        return firstly(on: .global()) { () throws -> Promise<Void> in
            guard shouldUpdateBalance else {
                return Promise.value(())
            }
            return firstly(on: .global()) { () throws -> Promise<TSPaymentAmount> in
                // prepareTransaction() will fail if local balance is not yet known.
                self.getLocalBalance()
            }.done(on: .global()) { (balance: TSPaymentAmount) in
                Logger.verbose("balance: \(balance.picoMob)")
            }
        }.map(on: .global()) { () -> TSPaymentAmount in
            try self.getEstimatedFee(forPaymentAmount: paymentAmount)
        }.then(on: .global()) { (estimatedFeeAmount: TSPaymentAmount) -> Promise<PreparedTransaction> in
            guard paymentAmount.isValidAmount(canBeEmpty: false) else {
                throw OWSAssertionError("Invalid amount.")
            }
            guard estimatedFeeAmount.isValidAmount(canBeEmpty: false) else {
                throw OWSAssertionError("Invalid fee.")
            }

            let (promise, resolver) = Promise<PreparedTransaction>.pending()
            if DebugFlags.paymentsNoRequestsComplete.get() {
                // Never resolve.
                return promise
            }
            // We don't need to support amountPicoMobHigh.
            client.prepareTransaction(to: recipientPublicAddress,
                                      amount: paymentAmount.picoMob,
                                      fee: estimatedFeeAmount.picoMob) { (result: Swift.Result<(transaction: MobileCoin.Transaction,
                                                                                                receipt: MobileCoin.Receipt),
                                                                                               TransactionPreparationError>) in
                switch result {
                case .success(let transactionAndReceipt):
                    let (transaction, receipt) = transactionAndReceipt
                    let finalFeeAmount = TSPaymentAmount(currency: .mobileCoin,
                                                         picoMob: transaction.fee)
                    owsAssertDebug(estimatedFeeAmount == finalFeeAmount)
                    let preparedTransaction = PreparedTransaction(transaction: transaction,
                                                                  receipt: receipt,
                                                                  feeAmount: finalFeeAmount)
                    resolver.fulfill(preparedTransaction)
                case .failure(let error):
                    let error = Self.convertMCError(error: error)
                    resolver.reject(error)
                }
            }
            return promise
        }.recover(on: .global()) { (error: Error) -> Promise<PreparedTransaction> in
            owsFailDebugUnlessMCNetworkFailure(error)
            throw error
        }.timeout(seconds: Self.timeoutDuration, description: "prepareTransaction") { () -> Error in
            PaymentsError.timeout
        }
    }

    // TODO: Are we always going to use _minimum_ fee?
    private static let feeLevel: MobileCoin.FeeLevel = .minimum

    func requiresDefragmentation(forPaymentAmount paymentAmount: TSPaymentAmount) -> Promise<Bool> {
        Logger.verbose("")

        let client = self.client

        return firstly(on: .global()) { () throws -> Promise<Bool> in
            let result = client.requiresDefragmentation(toSendAmount: paymentAmount.picoMob, feeLevel: Self.feeLevel)
            switch result {
            case .success(let shouldDefragment):
                return Promise.value(shouldDefragment)
            case .failure(let error):
                let error = Self.convertMCError(error: error)
                throw error
            }
        }.timeout(seconds: Self.timeoutDuration, description: "requiresDefragmentation") { () -> Error in
            PaymentsError.timeout
        }
    }

    func prepareDefragmentationStepTransactions(forPaymentAmount paymentAmount: TSPaymentAmount) -> Promise<[MobileCoin.Transaction]> {
        Logger.verbose("")

        let client = self.client

        return firstly(on: .global()) { () throws -> Promise<[MobileCoin.Transaction]> in
            let (promise, resolver) = Promise<[MobileCoin.Transaction]>.pending()
            if DebugFlags.paymentsNoRequestsComplete.get() {
                // Never resolve.
                return promise
            }
            client.prepareDefragmentationStepTransactions(toSendAmount: paymentAmount.picoMob,
                                                          feeLevel: Self.feeLevel) { (result: Swift.Result<[MobileCoin.Transaction],
                                                                                                           MobileCoin.DefragTransactionPreparationError>) in
                switch result {
                case .success(let transactions):
                    resolver.fulfill(transactions)
                    break
                case .failure(let error):
                    let error = Self.convertMCError(error: error)
                    resolver.reject(error)
                    break
                }
            }
            return promise
        }.timeout(seconds: Self.timeoutDuration, description: "prepareDefragmentationStepTransactions") { () -> Error in
            PaymentsError.timeout
        }
    }

    func submitTransaction(transaction: MobileCoin.Transaction) -> Promise<Void> {
        Logger.verbose("")

        guard !DebugFlags.paymentsFailOutgoingSubmission.get() else {
            return Promise(error: OWSGenericError("Failed."))
        }

        return firstly(on: .global()) { () throws -> Promise<Void> in
            let (promise, resolver) = Promise<Void>.pending()
            if DebugFlags.paymentsNoRequestsComplete.get() {
                // Never resolve.
                return promise
            }
            let client = self.client
            client.submitTransaction(transaction) { (result: Swift.Result<Void, TransactionSubmissionError>) in
                switch result {
                case .success:
                    resolver.fulfill(())
                    break
                case .failure(let error):
                    let error = Self.convertMCError(error: error)
                    resolver.reject(error)
                    break
                }
            }
            return promise
        }.map(on: .global()) { () -> Void in
            Logger.verbose("Success.")
        }.recover(on: .global()) { (error: Error) -> Promise<Void> in
            owsFailDebugUnlessMCNetworkFailure(error)
            throw error
        }.timeout(seconds: Self.timeoutDuration, description: "submitTransaction") { () -> Error in
            PaymentsError.timeout
        }
    }

    func getOutgoingTransactionStatus(transaction: MobileCoin.Transaction) -> Promise<MCOutgoingTransactionStatus> {
        Logger.verbose("")

        guard !DebugFlags.paymentsFailOutgoingVerification.get() else {
            return Promise(error: OWSGenericError("Failed."))
        }

        let client = self.client
        return firstly(on: .global()) { () throws -> Promise<TSPaymentAmount> in
            // .status(of: transaction) requires an updated balance.
            //
            // TODO: We could improve perf when verifying multiple transactions by getting balance just once.
            self.getLocalBalance()
        }.then(on: .global()) { (_: TSPaymentAmount) -> Promise<MCOutgoingTransactionStatus> in
            let (promise, resolver) = Promise<MCOutgoingTransactionStatus>.pending()
            if DebugFlags.paymentsNoRequestsComplete.get() {
                // Never resolve.
                return promise
            }
            client.status(of: transaction) { (result: Swift.Result<MobileCoin.TransactionStatus, ConnectionError>) in
                switch result {
                case .success(let transactionStatus):
                    resolver.fulfill(MCOutgoingTransactionStatus(transactionStatus: transactionStatus))
                    break
                case .failure(let error):
                    let error = Self.convertMCError(error: error)
                    resolver.reject(error)
                    break
                }
            }
            return promise
        }.map(on: .global()) { (value: MCOutgoingTransactionStatus) -> MCOutgoingTransactionStatus in
            Logger.verbose("Success: \(value)")
            return value
        }.recover(on: .global()) { (error: Error) -> Promise<MCOutgoingTransactionStatus> in
            owsFailDebugUnlessMCNetworkFailure(error)
            throw error
        }.timeout(seconds: Self.timeoutDuration, description: "getOutgoingTransactionStatus") { () -> Error in
            PaymentsError.timeout
        }
    }

    func paymentAmount(forReceipt receipt: MobileCoin.Receipt) throws -> TSPaymentAmount {
        try Self.paymentAmount(forReceipt: receipt, localAccount: localAccount)
    }

    static func paymentAmount(forReceipt receipt: MobileCoin.Receipt,
                              localAccount: MobileCoinAccount) throws -> TSPaymentAmount {
        guard let picoMob = receipt.validateAndUnmaskValue(accountKey: localAccount.accountKey) else {
            // This can happen if the receipt was address to a different account.
            owsFailDebug("Receipt missing amount.")
            throw PaymentsError.invalidAmount
        }
        guard picoMob > 0 else {
            owsFailDebug("Receipt has invalid amount.")
            throw PaymentsError.invalidAmount
        }
        return TSPaymentAmount(currency: .mobileCoin, picoMob: picoMob)
    }

    func getIncomingReceiptStatus(receipt: MobileCoin.Receipt) -> Promise<MCIncomingReceiptStatus> {
        Logger.verbose("")

        guard !DebugFlags.paymentsFailIncomingVerification.get() else {
            return Promise(error: OWSGenericError("Failed."))
        }

        let client = self.client
        let localAccount = self.localAccount

        return firstly(on: .global()) { () throws -> Promise<TSPaymentAmount> in
            // .status(of: receipt) requires an updated balance.
            //
            // TODO: We could improve perf when verifying multiple receipts by getting balance just once.
            self.getLocalBalance()
        }.map(on: .global()) { (_: TSPaymentAmount) -> MCIncomingReceiptStatus in
            let paymentAmount: TSPaymentAmount
            do {
                paymentAmount = try Self.paymentAmount(forReceipt: receipt,
                                                       localAccount: localAccount)
            } catch {
                owsFailDebug("Error: \(error)")
                return MCIncomingReceiptStatus(receiptStatus: .failed,
                                               paymentAmount: .zeroMob,
                                               txOutPublicKey: Data())
            }
            let txOutPublicKey: Data = receipt.txOutPublicKey

            let result = client.status(of: receipt)
            switch result {
            case .success(let receiptStatus):
                return MCIncomingReceiptStatus(receiptStatus: receiptStatus,
                                               paymentAmount: paymentAmount,
                                               txOutPublicKey: txOutPublicKey)
            case .failure(let error):
                let error = Self.convertMCError(error: error)
                throw error
            }
        }.map(on: .global()) { (value: MCIncomingReceiptStatus) -> MCIncomingReceiptStatus in
            Logger.verbose("Success: \(value)")
            return value
        }.recover(on: .global()) { (error: Error) -> Promise<MCIncomingReceiptStatus> in
            owsFailDebugUnlessMCNetworkFailure(error)
            throw error
        }.timeout(seconds: Self.timeoutDuration, description: "getIncomingReceiptStatus") { () -> Error in
            PaymentsError.timeout
        }
    }

    func getAccountActivity() -> Promise<MobileCoin.AccountActivity> {
        Logger.verbose("")

        let client = self.client

        return firstly(on: .global()) { () throws -> Promise<MobileCoin.AccountActivity> in
            let (promise, resolver) = Promise<MobileCoin.AccountActivity>.pending()
            if DebugFlags.paymentsNoRequestsComplete.get() {
                // Never resolve.
                return promise
            }
            client.updateBalance { (result: Swift.Result<Balance, ConnectionError>) in
                switch result {
                case .success:
                    resolver.fulfill(client.accountActivity)
                case .failure(let error):
                    let error = Self.convertMCError(error: error)
                    resolver.reject(error)
                }
            }
            return promise
        }.map(on: .global()) { (accountActivity: MobileCoin.AccountActivity) -> MobileCoin.AccountActivity in
            Logger.verbose("Success: \(accountActivity.blockCount)")
            return accountActivity
        }.recover(on: .global()) { (error: Error) -> Promise<MobileCoin.AccountActivity> in
            owsFailDebugUnlessMCNetworkFailure(error)
            throw error
        }.timeout(seconds: Self.timeoutDuration, description: "getAccountActivity") { () -> Error in
            PaymentsError.timeout
        }
    }
}

// MARK: -

extension MobileCoin.PublicAddress {
    var asPaymentAddress: TSPaymentAddress {
        return TSPaymentAddress(currency: .mobileCoin,
                                mobileCoinPublicAddressData: serializedData)
    }
}

// MARK: -

extension TSPaymentAddress {
    func asPublicAddress() throws -> MobileCoin.PublicAddress {
        guard currency == .mobileCoin else {
            throw PaymentsError.invalidCurrency
        }
        guard let address = MobileCoin.PublicAddress(serializedData: mobileCoinPublicAddressData) else {
            throw OWSAssertionError("Invalid mobileCoinPublicAddressData.")
        }
        return address
    }
}

// MARK: -

struct MCIncomingReceiptStatus {
    let receiptStatus: MobileCoin.ReceiptStatus
    let paymentAmount: TSPaymentAmount
    let txOutPublicKey: Data
}

// MARK: -

struct MCOutgoingTransactionStatus {
    let transactionStatus: MobileCoin.TransactionStatus
}

// MARK: - Error Handling

extension MobileCoinAPI {
    public static func convertMCError(error: Error) -> PaymentsError {
        switch error {
        case let error as MobileCoin.InvalidInputError:
            owsFailDebug("Error: \(error)")
            return PaymentsError.invalidInput
        case let error as MobileCoin.ConnectionError:
            switch error {
            case .connectionFailure(let reason):
                Logger.warn("Error: \(error), reason: \(reason)")
                return PaymentsError.connectionFailure
            case .authorizationFailure(let reason):
                owsFailDebug("Error: \(error), reason: \(reason)")

                // Immediately discard the SDK client instance; the auth token may be stale.
                SSKEnvironment.shared.payments.didReceiveMCAuthError()

                return PaymentsError.authorizationFailure
            case .invalidServerResponse(let reason):
                owsFailDebug("Error: \(error), reason: \(reason)")
                return PaymentsError.invalidServerResponse
            case .attestationVerificationFailed(let reason):
                owsFailDebug("Error: \(error), reason: \(reason)")
                return PaymentsError.attestationVerificationFailed
            case .outdatedClient(let reason):
                owsFailDebug("Error: \(error), reason: \(reason)")
                return PaymentsError.outdatedClient
            case .serverRateLimited(let reason):
                owsFailDebug("Error: \(error), reason: \(reason)")
                return PaymentsError.serverRateLimited
            }
        case let error as MobileCoin.TransactionPreparationError:
            switch error {
            case .invalidInput(let reason):
                owsFailDebug("Error: \(error), reason: \(reason)")
                return PaymentsError.invalidInput
            case .insufficientBalance:
                Logger.warn("Error: \(error)")
                return PaymentsError.insufficientFunds
            case .defragmentationRequired:
                Logger.warn("Error: \(error)")
                return PaymentsError.defragmentationRequired
            case .connectionError(let connectionError):
                // Recurse.
                return convertMCError(error: connectionError)
            }
        case let error as MobileCoin.TransactionSubmissionError:
            switch error {
            case .connectionError(let connectionError):
                // Recurse.
                return convertMCError(error: connectionError)
            case .invalidTransaction:
                Logger.warn("Error: \(error)")
                return PaymentsError.invalidTransaction
            case .feeError:
                Logger.warn("Error: \(error)")
                return PaymentsError.invalidFee
            case .tombstoneBlockTooFar:
                Logger.warn("Error: \(error)")
                // Map to .invalidTransaction
                return PaymentsError.invalidTransaction
            case .inputsAlreadySpent:
                Logger.warn("Error: \(error)")
                return PaymentsError.inputsAlreadySpent
            }
        case let error as MobileCoin.TransactionEstimationError:
            switch error {
            case .invalidInput(let reason):
                owsFailDebug("Error: \(error), reason: \(reason)")
                return PaymentsError.invalidInput
            case .insufficientBalance:
                Logger.warn("Error: \(error)")
                return PaymentsError.insufficientFunds
            }
        case let error as MobileCoin.DefragTransactionPreparationError:
            switch error {
            case .invalidInput(let reason):
                owsFailDebug("Error: \(error), reason: \(reason)")
                return PaymentsError.invalidInput
            case .insufficientBalance:
                Logger.warn("Error: \(error)")
                return PaymentsError.insufficientFunds
            case .connectionError(let connectionError):
                // Recurse.
                return convertMCError(error: connectionError)
            }
        case let error as MobileCoin.BalanceTransferEstimationError:
            switch error {
            case .feeExceedsBalance:
                // TODO: Review this mapping.
                Logger.warn("Error: \(error)")
                return PaymentsError.insufficientFunds
            case .balanceOverflow:
                // TODO: Review this mapping.
                Logger.warn("Error: \(error)")
                return PaymentsError.insufficientFunds
            }
        default:
            owsFailDebug("Unexpected error: \(error)")
            return PaymentsError.unknownSDKError
        }
    }
}

// MARK: -

public extension PaymentsError {
    var isPaymentsNetworkFailure: Bool {
        switch self {
        case .notEnabled,
             .userNotRegisteredOrAppNotReady,
             .userHasNoPublicAddress,
             .invalidCurrency,
             .invalidWalletKey,
             .invalidAmount,
             .invalidFee,
             .insufficientFunds,
             .invalidModel,
             .tooOldToSubmit,
             .indeterminateState,
             .unknownSDKError,
             .invalidInput,
             .authorizationFailure,
             .invalidServerResponse,
             .attestationVerificationFailed,
             .outdatedClient,
             .serverRateLimited,
             .serializationError,
             .verificationStatusUnknown,
             .ledgerBlockTimestampUnknown,
             .missingModel,
             .defragmentationRequired,
             .invalidTransaction,
             .inputsAlreadySpent,
             .defragmentationFailed,
             .invalidPassphrase,
             .invalidEntropy,
             .killSwitch:
            return false
        case .connectionFailure,
             .timeout:
            return true
        }
    }
}

// MARK: -

// A variant of owsFailDebugUnlessNetworkFailure() that can handle
// network failures from the MobileCoin SDK.
@inlinable
public func owsFailDebugUnlessMCNetworkFailure(_ error: Error,
                                               file: String = #file,
                                               function: String = #function,
                                               line: Int = #line) {
    if let paymentsError = error as? PaymentsError {
        if paymentsError.isPaymentsNetworkFailure {
            // Log but otherwise ignore network failures.
            Logger.warn("Error: \(error)", file: file, function: function, line: line)
        } else {
            owsFailDebug("Error: \(error)", file: file, function: function, line: line)
        }
    } else if nil != error as? OWSAssertionError {
        owsFailDebug("Unexpected error: \(error)")
    } else {
        owsFailDebugUnlessNetworkFailure(error)
    }
}

// MARK: - URLs

extension MobileCoinAPI {
    static func formatAsBase58(publicAddress: MobileCoin.PublicAddress) -> String {
        return Base58Coder.encode(publicAddress)
    }

    static func formatAsUrl(publicAddress: MobileCoin.PublicAddress) -> String {
        MobUri.encode(publicAddress)
    }

    static func parseAsPublicAddress(url: URL) -> MobileCoin.PublicAddress? {
        let result = MobUri.decode(uri: url.absoluteString)
        switch result {
        case .success(let payload):
            switch payload {
            case .publicAddress(let publicAddress):
                return publicAddress
            case .paymentRequest(let paymentRequest):
                // TODO: We could honor the amount and memo.
                return paymentRequest.publicAddress
            case .transferPayload:
                // TODO: We could handle transferPayload.
                owsFailDebug("Unexpected payload.")
                return nil
            }
        case .failure(let error):
            let error = Self.convertMCError(error: error)
            owsFailDebugUnlessMCNetworkFailure(error)
            return nil
        }
    }

    static func parse(publicAddressBase58 base58: String) -> MobileCoin.PublicAddress? {
        guard let result = Base58Coder.decode(base58) else {
            Logger.verbose("Invalid base58: \(base58)")
            Logger.warn("Invalid base58.")
            return nil
        }
        switch result {
        case .publicAddress(let publicAddress):
            return publicAddress
        default:
            Logger.verbose("Invalid base58: \(base58)")
            Logger.warn("Invalid base58.")
            return nil
        }
    }
}
