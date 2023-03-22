// Copyright SIX DAY LLC. All rights reserved.

import Foundation
import Combine

public class TransactionsService {
    private let transactionDataStore: TransactionDataStore
    private let sessionsProvider: SessionsProvider
    private let tokensService: DetectedContractsProvideble & TokenProvidable & TokenAddable
    private let analytics: AnalyticsLogger
    private var providers: [RPCServer: SingleChainTransactionProvider] = [:]
    private let config: Config
    private let fetchLatestTransactionsQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Fetch Latest Transactions"
            //A limit is important for many reasons. One of which is Etherscan has a rate limit of 5 calls/sec/IP address according to https://etherscan.io/apis
        queue.maxConcurrentOperationCount = 3
        return queue
    }()

    public var transactionsChangeset: AnyPublisher<[TransactionInstance], Never> {
        return sessionsProvider.sessions
            .flatMapLatest { [transactionDataStore] sessions -> AnyPublisher<[TransactionInstance], Never> in
                let servers = sessions.values.map { $0.server }
                return transactionDataStore
                    .transactionsChangeset(filter: .all, servers: servers)
                    .map { change -> [TransactionInstance] in
                        switch change {
                        case .initial(let transactions): return transactions
                        case .update(let transactions, _, _, _): return transactions
                        case .error: return []
                        }
                    }.eraseToAnyPublisher()
            }.eraseToAnyPublisher()
    }
    private var cancelable = Set<AnyCancellable>()
    private let networkService: NetworkService
    private let assetDefinitionStore: AssetDefinitionStore

    public init(sessionsProvider: SessionsProvider,
                transactionDataStore: TransactionDataStore,
                analytics: AnalyticsLogger,
                tokensService: DetectedContractsProvideble & TokenProvidable & TokenAddable,
                networkService: NetworkService,
                config: Config,
                assetDefinitionStore: AssetDefinitionStore) {

        self.config = config
        self.sessionsProvider = sessionsProvider
        self.tokensService = tokensService
        self.transactionDataStore = transactionDataStore
        self.analytics = analytics
        self.networkService = networkService
        self.assetDefinitionStore = assetDefinitionStore

        setupSingleChainTransactionProviders()

        NotificationCenter.default.applicationState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                switch state {
                case .didEnterBackground:
                    self?.stopTimers()
                case .willEnterForeground:
                    self?.restartTimers()
                }
            }.store(in: &cancelable)
    }

    deinit {
        fetchLatestTransactionsQueue.cancelAllOperations()
    }

    private func setupSingleChainTransactionProviders() {
        sessionsProvider.sessions
            .map { [weak self] sessions -> [RPCServer: SingleChainTransactionProvider] in
                guard let strongSelf = self else { return [:] }

                let servers = sessions.map { $0.key }

                var providers: [RPCServer: SingleChainTransactionProvider] = [:]
                for session in sessions {
                    if let provider = strongSelf.providers[session.key] {
                        providers[session.key] = provider
                    } else {
                        providers[session.key] = strongSelf.buildTransactionProvider(for: session.value)
                    }
                }
            }.assign(to: \.providers, on: self)
            .store(in: &cancelable)
    }

    private func buildTransactionProvider(for session: WalletSession) -> SingleChainTransactionProvider {
        let ercTokenDetector = ErcTokenDetector(
            tokensService: tokensService,
            server: session.server,
            ercProvider: session.tokenProvider,
            assetDefinitionStore: assetDefinitionStore)

        switch session.server.transactionsSource {
        case .etherscan:
            let provider = EtherscanSingleChainTransactionProvider(
                session: session,
                analytics: analytics,
                transactionDataStore: transactionDataStore,
                tokensService: tokensService,
                fetchLatestTransactionsQueue: fetchLatestTransactionsQueue,
                ercTokenDetector: ercTokenDetector,
                networkService: networkService)

            provider.start()

            return provider
        case .covalent(let apiKey):
            let transporter = BaseApiTransporter()
            let networking = CovalentApiNetworking(
                server: session.server,
                apiKey: apiKey,
                transporter: transporter)

            let provider = TransactionProvider(
                session: session,
                analytics: analytics,
                transactionDataStore: transactionDataStore,
                ercTokenDetector: ercTokenDetector,
                networking: networking,
                defaultPagination: session.server.defaultTransactionsPagination)

            provider.start()

            return provider
        case .oklink(let apiKey):
            let transporter = BaseApiTransporter()
            let transactionBuilder = TransactionBuilder(
                tokensService: tokensService,
                server: session.server,
                tokenProvider: session.tokenProvider)

            let networking = OklinkApiNetworking(
                server: session.server,
                apiKey: apiKey,
                transporter: transporter,
                ercTokenProvider: session.tokenProvider,
                transactionBuilder: transactionBuilder)

            let provider = TransactionProvider(
                session: session,
                analytics: analytics,
                transactionDataStore: transactionDataStore,
                ercTokenDetector: ercTokenDetector,
                networking: networking,
                defaultPagination: session.server.defaultTransactionsPagination)

            provider.start()

            return provider
        }
    }

    @objc private func stopTimers() {
        for each in providers {
            each.value.stopTimers()
        }
    }

    @objc private func restartTimers() {
        guard !config.development.isAutoFetchingDisabled else { return }

        for each in providers {
            each.value.runScheduledTimers()
        }
    }

    public func fetch() {
        guard !config.development.isAutoFetchingDisabled else { return }

        for each in providers {
            each.value.fetch()
        }
    }

    public func transactionPublisher(for transactionId: String, server: RPCServer) -> AnyPublisher<TransactionInstance?, Never> {
        transactionDataStore.transactionPublisher(for: transactionId, server: server)
            .replaceError(with: nil)
            .eraseToAnyPublisher()
    }

    public func transaction(withTransactionId transactionId: String, forServer server: RPCServer) -> TransactionInstance? {
        transactionDataStore.transaction(withTransactionId: transactionId, forServer: server)
    }

    public func addSentTransaction(_ transaction: SentTransaction) {
        guard let session = sessionsProvider.session(for: transaction.original.server) else { return }

        TransactionDataStore.pendingTransactionsInformation[transaction.id] = (server: transaction.original.server, data: transaction.original.data, transactionType: transaction.original.transactionType, gasPrice: transaction.original.gasPrice)
        let token = transaction.original.to.flatMap { tokensService.token(for: $0, server: transaction.original.server) }
        let transaction = TransactionInstance.from(from: session.account.address, transaction: transaction, token: token)
        
        transactionDataStore.add(transactions: [transaction])
    }

    public func stop() {
        for each in providers {
            each.value.stop()
        }
    }
}

extension RPCServer {
    var defaultTransactionsPagination: TransactionsPagination {
        switch transactionsSource {
        case .etherscan:
            return .init(page: 0, lastFetched: [], limit: 200)
        case .covalent:
            return .init(page: 0, lastFetched: [], limit: 500)
        case .oklink:
            return .init(page: 0, lastFetched: [], limit: 50)
        }
    }
}
