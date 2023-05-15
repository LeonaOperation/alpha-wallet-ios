//
//  BlockscoutApiNetworking.swift
//  AlphaWalletFoundation
//
//  Created by Vladyslav Shepitko on 09.05.2023.
//

import Foundation
import SwiftyJSON
import Combine
import AlphaWalletCore
import BigInt
import AlphaWalletLogger
import Alamofire

class BlockscoutApiNetworking: ApiNetworking {
    private let server: RPCServer
    private let transporter: ApiTransporter
    private let transactionBuilder: TransactionBuilder
    private let apiKey: String?
    private let baseUrl: URL

    init(server: RPCServer,
         transporter: ApiTransporter,
         transactionBuilder: TransactionBuilder,
         apiKey: String?,
         baseUrl: URL) {

        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.transactionBuilder = transactionBuilder
        self.transporter = transporter
        self.server = server
    }

    func erc20TokenInteractions(walletAddress: AlphaWallet.Address,
                                startBlock: Int?) -> AnyPublisher<UniqueNonEmptyContracts, PromiseError> {

        let request = Request(
            baseUrl: baseUrl,
            startBlock: startBlock,
            apiKey: apiKey,
            walletAddress: walletAddress,
            action: .tokentx)

        return transporter
            .dataTaskPublisher(request)
            .handleEvents(receiveOutput: { [server] in EtherscanCompatibleApiNetworking.log(response: $0, server: server) })
            .tryMap { UniqueNonEmptyContracts(json: try JSON(data: $0.data), tokenType: .erc20) }
            .mapError { PromiseError.some(error: $0) }
            .eraseToAnyPublisher()
    }

    func erc721TokenInteractions(walletAddress: AlphaWallet.Address,
                                 startBlock: Int?) -> AnyPublisher<UniqueNonEmptyContracts, PromiseError> {

        switch server {
        case .main, .classic, .goerli, .xDai, .polygon, .binance_smart_chain, .binance_smart_chain_testnet, .callisto, .optimistic, .cronosMainnet, .cronosTestnet, .custom, .arbitrum, .palm, .palmTestnet, .optimismGoerli, .arbitrumGoerli, .avalanche, .avalanche_testnet, .sepolia:
            break
        case .heco, .heco_testnet, .fantom, .fantom_testnet, .mumbai_testnet, .klaytnCypress, .klaytnBaobabTestnet, .ioTeX, .ioTeXTestnet, .okx:
            return .fail(PromiseError(error: ApiNetworkingError.methodNotSupported))
        }

        let request = Request(
            baseUrl: baseUrl,
            startBlock: startBlock,
            apiKey: apiKey,
            walletAddress: walletAddress,
            action: .txlist)

        return transporter
            .dataTaskPublisher(request)
            .handleEvents(receiveOutput: { [server] in EtherscanCompatibleApiNetworking.log(response: $0, server: server) })
            .tryMap { UniqueNonEmptyContracts(json: try JSON(data: $0.data), tokenType: .erc721) }
            .mapError { PromiseError.some(error: $0) }
            .eraseToAnyPublisher()
    }

    func erc1155TokenInteractions(walletAddress: AlphaWallet.Address,
                                  startBlock: Int?) -> AnyPublisher<UniqueNonEmptyContracts, PromiseError> {

        switch server {
        case .main, .classic, .goerli, .xDai, .polygon, .binance_smart_chain, .binance_smart_chain_testnet, .callisto, .optimistic, .cronosMainnet, .cronosTestnet, .custom, .arbitrum, .palm, .palmTestnet, .optimismGoerli, .arbitrumGoerli, .avalanche, .avalanche_testnet, .sepolia:
            break
        case .heco, .heco_testnet, .fantom, .fantom_testnet, .mumbai_testnet, .klaytnCypress, .klaytnBaobabTestnet, .ioTeX, .ioTeXTestnet, .okx:
            return .fail(PromiseError(error: ApiNetworkingError.methodNotSupported))
        }

        let request = Request(
            baseUrl: baseUrl,
            startBlock: startBlock,
            apiKey: apiKey,
            walletAddress: walletAddress,
            action: .txlist)

        return transporter
            .dataTaskPublisher(request)
            .handleEvents(receiveOutput: { [server] in EtherscanCompatibleApiNetworking.log(response: $0, server: server) })
            .tryMap { UniqueNonEmptyContracts(json: try JSON(data: $0.data), tokenType: .erc1155) }
            .mapError { PromiseError.some(error: $0) }
            .eraseToAnyPublisher()
    }

    func erc20TokenTransferTransactions(walletAddress: AlphaWallet.Address, startBlock: Int? = nil) -> AnyPublisher<([Transaction], Int), PromiseError> {
        return erc20TokenTransferTransactions(walletAddress: walletAddress, server: server, startBlock: startBlock)
            .flatMap { transactions -> AnyPublisher<([Transaction], Int), PromiseError> in
                let (result, minBlockNumber, maxBlockNumber) = EtherscanCompatibleApiNetworking.functional.extractBoundingBlockNumbers(fromTransactions: transactions)
                return self.backFillTransactionGroup(walletAddress: walletAddress, result, startBlock: minBlockNumber, endBlock: maxBlockNumber)
                    .map { ($0, maxBlockNumber) }
                    .eraseToAnyPublisher()
            }.eraseToAnyPublisher()
    }

    func erc721TokenTransferTransactions(walletAddress: AlphaWallet.Address, startBlock: Int? = nil) -> AnyPublisher<([Transaction], Int), PromiseError> {
        return getErc721Transactions(walletAddress: walletAddress, server: server, startBlock: startBlock)
            .flatMap { transactions -> AnyPublisher<([Transaction], Int), PromiseError> in
                let (result, minBlockNumber, maxBlockNumber) = EtherscanCompatibleApiNetworking.functional.extractBoundingBlockNumbers(fromTransactions: transactions)
                return self.backFillTransactionGroup(walletAddress: walletAddress, result, startBlock: minBlockNumber, endBlock: maxBlockNumber)
                    .map { ($0, maxBlockNumber) }
                    .eraseToAnyPublisher()
            }.eraseToAnyPublisher()
    }

    func normalTransactions(walletAddress: AlphaWallet.Address, startBlock: Int, endBlock: Int = 999_999_999, sortOrder: GetTransactions.SortOrder) -> AnyPublisher<[Transaction], PromiseError> {

        let request = Request(
            baseUrl: baseUrl,
            startBlock: startBlock,
            endBlock: endBlock,
            sortOrder: sortOrder,
            apiKey: apiKey,
            walletAddress: walletAddress,
            action: .txlist)

        return transporter
            .dataTaskPublisher(request)
            .handleEvents(receiveOutput: { [server] in EtherscanCompatibleApiNetworking.log(response: $0, server: server) })
            .mapError { PromiseError(error: $0) }
            .flatMap { [transactionBuilder] result -> AnyPublisher<[Transaction], PromiseError> in
                if result.response.statusCode == 404 {
                    return .fail(.some(error: URLError(URLError.Code(rawValue: 404)))) // Clearer than a JSON deserialization error when it's a 404
                }

                do {
                    let promises = try JSONDecoder().decode(ArrayResponse<NormalTransaction>.self, from: result.data)
                        .result.map { transactionBuilder.buildTransaction(from: $0) }

                    return Publishers.MergeMany(promises)
                        .collect()
                        .map { $0.compactMap { $0 } }
                        .setFailureType(to: PromiseError.self)
                        .eraseToAnyPublisher()
                } catch {
                    return .fail(.some(error: error))
                }
            }.eraseToAnyPublisher()
    }

    func erc1155TokenTransferTransactions(walletAddress: AlphaWallet.Address, startBlock: Int?) -> AnyPublisher<([Transaction], Int), AlphaWalletCore.PromiseError> {
        return .empty()
    }

    func normalTransactions(walletAddress: AlphaWallet.Address,
                            pagination: TransactionsPagination) -> AnyPublisher<TransactionsResponse, PromiseError> {
        return .empty()
    }

    func erc20TokenTransferTransactions(walletAddress: AlphaWallet.Address,
                                        pagination: TransactionsPagination) -> AnyPublisher<TransactionsResponse, PromiseError> {
        return .empty()
    }

    func erc721TokenTransferTransactions(walletAddress: AlphaWallet.Address,
                                         pagination: TransactionsPagination) -> AnyPublisher<TransactionsResponse, PromiseError> {
        return .empty()
    }

    func erc1155TokenTransferTransaction(walletAddress: AlphaWallet.Address,
                                         pagination: TransactionsPagination) -> AnyPublisher<TransactionsResponse, PromiseError> {
        return .empty()
    }

    private func erc20TokenTransferTransactions(walletAddress: AlphaWallet.Address, server: RPCServer, startBlock: Int? = nil) -> AnyPublisher<[Transaction], PromiseError> {

        let request = Request(
            baseUrl: baseUrl,
            startBlock: startBlock,
            apiKey: apiKey,
            walletAddress: walletAddress,
            action: .tokentx)

        return transporter
            .dataTaskPublisher(request)
            .handleEvents(receiveOutput: { EtherscanCompatibleApiNetworking.log(response: $0, server: server) })
            .tryMap { EtherscanCompatibleApiNetworking.functional.decodeTokenTransferTransactions(json: JSON($0.data), server: server, tokenType: .erc20) }
            .mapError { PromiseError.some(error: $0) }
            .eraseToAnyPublisher()
    }

    private func getErc721Transactions(walletAddress: AlphaWallet.Address, server: RPCServer, startBlock: Int? = nil) -> AnyPublisher<[Transaction], PromiseError> {

        let request = Request(
            baseUrl: baseUrl,
            startBlock: startBlock,
            apiKey: apiKey,
            walletAddress: walletAddress,
            action: .tokentx)

        return transporter
            .dataTaskPublisher(request)
            .handleEvents(receiveOutput: { EtherscanCompatibleApiNetworking.log(response: $0, server: server) })
            .tryMap { EtherscanCompatibleApiNetworking.functional.decodeTokenTransferTransactions(json: JSON($0.data), server: server, tokenType: .erc721) }
            .mapError { PromiseError.some(error: $0) }
            .eraseToAnyPublisher()
    }

    func gasPriceEstimates() -> AnyPublisher<LegacyGasEstimates, PromiseError> {
        return .fail(PromiseError(error: ApiNetworkingError.methodNotSupported))
    }

    private func backFillTransactionGroup(walletAddress: AlphaWallet.Address, _ transactions: [Transaction], startBlock: Int, endBlock: Int) -> AnyPublisher<[Transaction], PromiseError> {
        guard !transactions.isEmpty else { return .just([]) }

        return normalTransactions(walletAddress: walletAddress, startBlock: startBlock, endBlock: endBlock, sortOrder: .asc)
            .map {
                EtherscanCompatibleApiNetworking.functional.mergeTransactionOperationsForNormalTransactions(
                    transactions: transactions,
                    normalTransactions: $0)
            }.eraseToAnyPublisher()
    }

    static func log(response: URLRequest.Response, server: RPCServer, caller: String = #function) {
        switch URLRequest.validate(statusCode: 200..<300, response: response.response) {
        case .failure:
            let json = try? JSON(response.data)
            infoLog("[API] request failure with status code: \(response.response.statusCode), json: \(json), server: \(server)", callerFunctionName: caller)
        case .success:
            break
        }
    }
}

extension BlockscoutApiNetworking {

    private enum Action: String {
        case txlist
        case tokentx
    }

    private struct Request: URLRequestConvertible {
        let baseUrl: URL
        let startBlock: Int?
        let endBlock: Int?
        let apiKey: String?
        let walletAddress: AlphaWallet.Address
        let sortOrder: GetTransactions.SortOrder?
        let action: Action

        init(baseUrl: URL,
             startBlock: Int? = nil,
             endBlock: Int? = nil,
             sortOrder: GetTransactions.SortOrder? = nil,
             apiKey: String? = nil,
             walletAddress: AlphaWallet.Address,
             action: Action) {

            self.action = action
            self.baseUrl = baseUrl
            self.startBlock = startBlock
            self.endBlock = endBlock
            self.apiKey = apiKey
            self.walletAddress = walletAddress
            self.sortOrder = sortOrder
        }

        func asURLRequest() throws -> URLRequest {
            guard var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
            let request = try URLRequest(url: baseUrl, method: .get)
            var params: Parameters = [
                "module": "account",
                "action": action.rawValue,
                "address": walletAddress.eip55String
            ]
            if let startBlock = startBlock {
                params["start_block"] = String(startBlock)
            }

            if let endBlock = endBlock {
                params["end_block"] = String(endBlock)
            }

            if let apiKey = apiKey {
                params["apikey"] = apiKey
            }

            if let sortOrder = sortOrder {
                params["sort"] = sortOrder.rawValue
            }

            return try URLEncoding().encode(request, with: params)
        }
    }
}
