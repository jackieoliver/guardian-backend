import Foundation

extension URLSession {
    static let guardianShared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: configuration)
    }()
}

struct GuardianBackendReadiness: Decodable, Equatable {
    let status: String
}

struct GuardianBackendUser: Decodable, Equatable {
    let userID: String
    let email: String?
    let emailVerified: Bool
    let name: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case email
        case emailVerified = "email_verified"
        case name
    }
}

struct GuardianAppUserProfile: Decodable, Equatable {
    let userID: String
    let email: String?
    let name: String?
    let vmID: String?
    let terminalSSHPublicKey: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case email
        case name
        case vmID = "vm_id"
        case terminalSSHPublicKey = "terminal_ssh_public_key"
    }
}

struct GuardianVMAccess: Decodable, Equatable {
    let vmID: String?
    let host: String?
    let port: Int?
    let linuxUsername: String?
    let runtimeWorkspacePath: String?
    let runtimeWorkspaceState: String?
    let accessState: String?
    let canConnect: Bool
    let terminalSSHPublicKeyPresent: Bool
    let bootstrapError: String?

    var linuxUser: String? { linuxUsername }
    var vmDisplayName: String? { vmID }
    var syncRoot: String? { runtimeWorkspacePath }
    var sshHost: String? { host }
    var sshPort: Int? { port }

    enum CodingKeys: String, CodingKey {
        case vmID = "vm_id"
        case host
        case port
        case linuxUsername = "linux_username"
        case runtimeWorkspacePath = "runtime_workspace_path"
        case runtimeWorkspaceState = "runtime_workspace_state"
        case accessState = "access_state"
        case canConnect = "can_connect"
        case terminalSSHPublicKeyPresent = "terminal_ssh_public_key_present"
        case bootstrapError = "bootstrap_error"
    }
}

private struct TerminalSSHKeyPayload: Encodable {
    let publicKey: String

    enum CodingKeys: String, CodingKey {
        case publicKey = "public_key"
    }
}

struct GuardianSourceType: Decodable, Equatable, Identifiable {
    let sourceID: String
    let sourceName: String

    var id: String {
        sourceID
    }

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case sourceName = "source_name"
    }
}

struct GuardianOwnedSource: Decodable, Equatable, Identifiable {
    let ownedSourceID: String
    let userID: String
    let sourceID: String
    let sourceName: String?
    let displayName: String
    let lastImportCompletedAt: String?
    let currentImportRunID: String?

    var id: String {
        ownedSourceID
    }

    enum CodingKeys: String, CodingKey {
        case ownedSourceID = "owned_source_id"
        case userID = "user_id"
        case sourceID = "source_id"
        case sourceName = "source_name"
        case displayName = "display_name"
        case lastImportCompletedAt = "last_import_completed_at"
        case currentImportRunID = "current_import_run_id"
    }
}

struct GuardianImportQueueItem: Decodable, Equatable, Identifiable {
    let importRunID: String
    let ownedSourceID: String
    let sourceID: String
    let sourceDisplayName: String
    let status: String
    let totalCandidateFileCount: Int
    let transportShardCount: Int
    let uploadedTransportShardCount: Int
    let processedTransportShardCount: Int
    let canonicalFileCount: Int
    let error: String?

    var id: String {
        importRunID
    }

    enum CodingKeys: String, CodingKey {
        case importRunID = "import_run_id"
        case ownedSourceID = "owned_source_id"
        case sourceID = "source_id"
        case sourceDisplayName = "source_display_name"
        case status
        case totalCandidateFileCount = "total_candidate_file_count"
        case transportShardCount = "transport_shard_count"
        case uploadedTransportShardCount = "uploaded_transport_shard_count"
        case processedTransportShardCount = "processed_transport_shard_count"
        case canonicalFileCount = "canonical_file_count"
        case error
    }
}

struct GuardianImportRun: Decodable, Equatable, Identifiable {
    let importRunID: String
    let ownedSourceID: String
    let sourceID: String
    let status: String
    let clientID: String?
    let sourceSnapshotLabel: String?
    let totalCandidateFileCount: Int
    let totalCandidateSizeBytes: Int
    let transportShardCount: Int
    let uploadedTransportShardCount: Int
    let processedTransportShardCount: Int
    let failedTransportShardCount: Int
    let canonicalFileCount: Int
    let createdAt: String
    let updatedAt: String
    let completedAt: String?
    let error: String?

    var id: String {
        importRunID
    }

    enum CodingKeys: String, CodingKey {
        case importRunID = "import_run_id"
        case ownedSourceID = "owned_source_id"
        case sourceID = "source_id"
        case status
        case clientID = "client_id"
        case sourceSnapshotLabel = "source_snapshot_label"
        case totalCandidateFileCount = "total_candidate_file_count"
        case totalCandidateSizeBytes = "total_candidate_size_bytes"
        case transportShardCount = "transport_shard_count"
        case uploadedTransportShardCount = "uploaded_transport_shard_count"
        case processedTransportShardCount = "processed_transport_shard_count"
        case failedTransportShardCount = "failed_transport_shard_count"
        case canonicalFileCount = "canonical_file_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
        case error
    }
}

struct GuardianImportPlanCandidatePayload: Encodable, Equatable {
    let contentHash: String
    let originalRelativePath: String
    let sizeBytes: Int
    let sourceModifiedAt: String

    enum CodingKeys: String, CodingKey {
        case contentHash = "content_hash"
        case originalRelativePath = "original_relative_path"
        case sizeBytes = "size_bytes"
        case sourceModifiedAt = "source_modified_at"
    }
}

struct GuardianImportPlanMatch: Decodable, Equatable {
    let contentHash: String
    let originalRelativePath: String
    let sizeBytes: Int
    let sourceModifiedAt: String
    let known: Bool
    let sourceFileID: String?
    let objectPath: String?

    enum CodingKeys: String, CodingKey {
        case contentHash = "content_hash"
        case originalRelativePath = "original_relative_path"
        case sizeBytes = "size_bytes"
        case sourceModifiedAt = "source_modified_at"
        case known
        case sourceFileID = "source_file_id"
        case objectPath = "object_path"
    }
}

struct GuardianImportPlanResponse: Decodable, Equatable {
    let known: [GuardianImportPlanMatch]
    let missing: [GuardianImportPlanMatch]
    let knownCount: Int
    let missingCount: Int

    enum CodingKeys: String, CodingKey {
        case known
        case missing
        case knownCount = "known_count"
        case missingCount = "missing_count"
    }
}

struct GuardianImportShard: Decodable, Equatable, Identifiable {
    let importShardID: String
    let importRunID: String
    let ownedSourceID: String
    let status: String
    let shardIndex: Int
    let filename: String
    let objectPath: String
    let contentHash: String
    let fileCount: Int
    let totalSizeBytes: Int

    var id: String {
        importShardID
    }

    enum CodingKeys: String, CodingKey {
        case importShardID = "import_shard_id"
        case importRunID = "import_run_id"
        case ownedSourceID = "owned_source_id"
        case status
        case shardIndex = "shard_index"
        case filename
        case objectPath = "object_path"
        case contentHash = "content_hash"
        case fileCount = "file_count"
        case totalSizeBytes = "total_size_bytes"
    }
}

private struct ImportRunCreatePayload: Encodable {
    let clientID: String?
    let sourceSnapshotLabel: String?
    let totalCandidateFileCount: Int
    let totalCandidateSizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case sourceSnapshotLabel = "source_snapshot_label"
        case totalCandidateFileCount = "total_candidate_file_count"
        case totalCandidateSizeBytes = "total_candidate_size_bytes"
    }
}

private struct ImportRunStatusUpdatePayload: Encodable {
    let error: String?
}

private struct ImportPlanPayload: Encodable {
    let candidates: [GuardianImportPlanCandidatePayload]
}

struct GuardianImportShardCreateInputPayload: Encodable, Equatable {
    let shardIndex: Int
    let filename: String
    let objectPath: String?
    let contentHash: String
    let fileCount: Int
    let totalSizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case shardIndex = "shard_index"
        case filename
        case objectPath = "object_path"
        case contentHash = "content_hash"
        case fileCount = "file_count"
        case totalSizeBytes = "total_size_bytes"
    }
}

private struct ImportShardCreatePayload: Encodable {
    let shards: [GuardianImportShardCreateInputPayload]
}

extension GuardianImportQueueItem {
    var progressFraction: Double {
        let shardCount = max(transportShardCount, 1)
        let uploadFraction = Double(uploadedTransportShardCount) / Double(shardCount)
        let processingFraction = Double(processedTransportShardCount) / Double(shardCount)

        switch status {
        case "created":
            return 0
        case "uploading":
            return min(max(uploadFraction * 0.5, 0), 0.5)
        case "processing":
            return min(max(0.5 + (processingFraction * 0.5), 0.5), 1)
        case "completed":
            return 1
        case "failed", "canceled":
            return min(max(0.5 + (processingFraction * 0.5), 0), 1)
        default:
            return min(max(uploadFraction * 0.5, 0), 1)
        }
    }

    var statusTitle: String {
        switch status {
        case "created":
            return "Queued"
        case "uploading":
            return "Uploading"
        case "processing":
            return "Processing"
        case "completed":
            return "Done"
        case "failed":
            return "Failed"
        case "canceled":
            return "Canceled"
        default:
            return status.capitalized
        }
    }
}

extension GuardianImportRun {
    var progressFraction: Double {
        let shardCount = max(transportShardCount, 1)
        let uploadFraction = Double(uploadedTransportShardCount) / Double(shardCount)
        let processingFraction = Double(processedTransportShardCount) / Double(shardCount)

        switch status {
        case "created":
            return 0
        case "uploading":
            return min(max(uploadFraction * 0.5, 0), 0.5)
        case "processing":
            return min(max(0.5 + (processingFraction * 0.5), 0.5), 1)
        case "completed":
            return 1
        case "failed", "canceled":
            return min(max(0.5 + (processingFraction * 0.5), 0), 1)
        default:
            return min(max(uploadFraction * 0.5, 0), 1)
        }
    }

    var statusTitle: String {
        switch status {
        case "created":
            return "Queued"
        case "uploading":
            return "Uploading"
        case "processing":
            return "Processing"
        case "completed":
            return "Completed"
        case "failed":
            return "Failed"
        case "canceled":
            return "Canceled"
        default:
            return status.capitalized
        }
    }
}

private struct OwnedSourceCreatePayload: Encodable {
    let sourceID: String
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case displayName = "display_name"
    }
}

struct GuardianBackendClient {
    private let baseURLOverride: String?

    init(baseURLOverride: String? = nil) {
        let trimmed = baseURLOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURLOverride = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private struct ErrorPayload: Decodable {
        let detail: String
    }

    enum ClientError: LocalizedError {
        case missingBaseURL
        case invalidBaseURL(String)
        case missingIDToken
        case invalidResponse
        case server(statusCode: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .missingBaseURL:
                return "Guardian backend base URL is missing from Info.plist."
            case let .invalidBaseURL(value):
                return "Guardian backend base URL is invalid: \(value)"
            case .missingIDToken:
                return "Guardian sign-in did not provide an auth token."
            case .invalidResponse:
                return "Guardian backend returned an invalid response."
            case let .server(statusCode, detail):
                return "Guardian backend request failed (\(statusCode)): \(detail)"
            }
        }
    }

    func fetchReadiness(
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> GuardianBackendReadiness {
        let endpoint = try baseURL(bundle: bundle).appending(path: "ready")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"

        let (data, response) = try await data(for: request, session: session)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw serverError(from: data, statusCode: httpResponse.statusCode)
        }
        return try JSONDecoder().decode(GuardianBackendReadiness.self, from: data)
    }

    func fetchCurrentUser(
        idToken: String,
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> GuardianBackendUser {
        try await sendJSONRequest(
            path: "me",
            method: "GET",
            idToken: idToken,
            requestBody: String?.none,
            bundle: bundle,
            session: session,
            responseType: GuardianBackendUser.self
        )
    }

    func fetchProfile(
        idToken: String,
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> GuardianAppUserProfile {
        try await sendJSONRequest(
            path: "me/profile",
            method: "GET",
            idToken: idToken,
            requestBody: String?.none,
            bundle: bundle,
            session: session,
            responseType: GuardianAppUserProfile.self
        )
    }

    func fetchVMAccess(
        idToken: String,
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> GuardianVMAccess {
        try await sendJSONRequest(
            path: "me/vm-access",
            method: "GET",
            idToken: idToken,
            requestBody: String?.none,
            bundle: bundle,
            session: session,
            responseType: GuardianVMAccess.self
        )
    }

    func registerTerminalSSHKey(
        idToken: String,
        publicKey: String,
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> GuardianAppUserProfile {
        try await sendJSONRequest(
            path: "me/terminal-ssh-key",
            method: "PUT",
            idToken: idToken,
            requestBody: TerminalSSHKeyPayload(publicKey: publicKey),
            bundle: bundle,
            session: session,
            responseType: GuardianAppUserProfile.self
        )
    }

    func listSourceTypes(
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> [GuardianSourceType] {
        let endpoint = try baseURL(bundle: bundle).appending(path: "source-types")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"

        let (data, response) = try await data(for: request, session: session)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw serverError(from: data, statusCode: httpResponse.statusCode)
        }
        return try JSONDecoder().decode([GuardianSourceType].self, from: data)
    }

    func listOwnedSources(
        idToken: String,
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> [GuardianOwnedSource] {
        try await sendJSONRequest(
            path: "me/sources",
            method: "GET",
            idToken: idToken,
            requestBody: String?.none,
            bundle: bundle,
            session: session,
            responseType: [GuardianOwnedSource].self
        )
    }

    func createOwnedSource(
        idToken: String,
        sourceID: String,
        displayName: String,
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> GuardianOwnedSource {
        try await sendJSONRequest(
            path: "me/sources",
            method: "POST",
            idToken: idToken,
            requestBody: OwnedSourceCreatePayload(sourceID: sourceID, displayName: displayName),
            bundle: bundle,
            session: session,
            responseType: GuardianOwnedSource.self
        )
    }

    func listImportQueue(
        idToken: String,
        includeCompleted: Bool = false,
        limit: Int = 20,
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> [GuardianImportQueueItem] {
        return try await sendJSONRequest(
            path: "me/imports/queue",
            method: "GET",
            idToken: idToken,
            requestBody: String?.none,
            queryItems: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "include_completed", value: includeCompleted ? "true" : "false"),
            ],
            bundle: bundle,
            session: session,
            responseType: [GuardianImportQueueItem].self
        )
    }

    func listImportRuns(
        idToken: String,
        ownedSourceID: String,
        limit: Int = 50,
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> [GuardianImportRun] {
        try await sendJSONRequest(
            path: "me/sources/\(ownedSourceID)/imports",
            method: "GET",
            idToken: idToken,
            requestBody: String?.none,
            queryItems: [URLQueryItem(name: "limit", value: String(limit))],
            bundle: bundle,
            session: session,
            responseType: [GuardianImportRun].self
        )
    }

    func createImportRun(
        idToken: String,
        ownedSourceID: String,
        clientID: String? = "guardian-desktop",
        sourceSnapshotLabel: String? = nil,
        totalCandidateFileCount: Int = 0,
        totalCandidateSizeBytes: Int = 0,
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> GuardianImportRun {
        try await sendJSONRequest(
            path: "me/sources/\(ownedSourceID)/imports",
            method: "POST",
            idToken: idToken,
            requestBody: ImportRunCreatePayload(
                clientID: clientID,
                sourceSnapshotLabel: sourceSnapshotLabel,
                totalCandidateFileCount: totalCandidateFileCount,
                totalCandidateSizeBytes: totalCandidateSizeBytes
            ),
            bundle: bundle,
            session: session,
            responseType: GuardianImportRun.self
        )
    }

    func fetchImportRun(
        idToken: String,
        ownedSourceID: String,
        importRunID: String,
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> GuardianImportRun {
        try await sendJSONRequest(
            path: "me/sources/\(ownedSourceID)/imports/\(importRunID)",
            method: "GET",
            idToken: idToken,
            requestBody: String?.none,
            bundle: bundle,
            session: session,
            responseType: GuardianImportRun.self
        )
    }

    func planImportRun(
        idToken: String,
        ownedSourceID: String,
        importRunID: String,
        candidates: [GuardianImportPlanCandidatePayload],
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> GuardianImportPlanResponse {
        try await sendJSONRequest(
            path: "me/sources/\(ownedSourceID)/imports/\(importRunID)/plan",
            method: "POST",
            idToken: idToken,
            requestBody: ImportPlanPayload(candidates: candidates),
            bundle: bundle,
            session: session,
            responseType: GuardianImportPlanResponse.self
        )
    }

    func createImportShards(
        idToken: String,
        ownedSourceID: String,
        importRunID: String,
        shards: [GuardianImportShardCreateInputPayload],
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> [GuardianImportShard] {
        try await sendJSONRequest(
            path: "me/sources/\(ownedSourceID)/imports/\(importRunID)/shards",
            method: "POST",
            idToken: idToken,
            requestBody: ImportShardCreatePayload(shards: shards),
            bundle: bundle,
            session: session,
            responseType: [GuardianImportShard].self
        )
    }

    func uploadImportShardContent(
        idToken: String,
        ownedSourceID: String,
        importRunID: String,
        importShardID: String,
        payload: Data,
        contentType: String = "application/x-tar",
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> GuardianImportShard {
        let endpoint = try baseURL(bundle: bundle).appending(
            path: "me/sources/\(ownedSourceID)/imports/\(importRunID)/shards/\(importShardID)/content"
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        let (responseData, response) = try await data(for: request, session: session)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw serverError(from: responseData, statusCode: httpResponse.statusCode)
        }
        return try JSONDecoder().decode(GuardianImportShard.self, from: responseData)
    }

    func completeImportRun(
        idToken: String,
        ownedSourceID: String,
        importRunID: String,
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> GuardianImportRun {
        try await sendJSONRequest(
            path: "me/sources/\(ownedSourceID)/imports/\(importRunID)/complete",
            method: "POST",
            idToken: idToken,
            requestBody: String?.none,
            bundle: bundle,
            session: session,
            responseType: GuardianImportRun.self
        )
    }

    func cancelImportRun(
        idToken: String,
        ownedSourceID: String,
        importRunID: String,
        error: String? = nil,
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws -> GuardianImportRun {
        try await sendJSONRequest(
            path: "me/sources/\(ownedSourceID)/imports/\(importRunID)/cancel",
            method: "POST",
            idToken: idToken,
            requestBody: ImportRunStatusUpdatePayload(error: error),
            bundle: bundle,
            session: session,
            responseType: GuardianImportRun.self
        )
    }

    func deleteOwnedSource(
        idToken: String,
        ownedSourceID: String,
        bundle: Bundle = .main,
        session: URLSession = .guardianShared
    ) async throws {
        try await sendEmptyRequest(
            path: "me/sources/\(ownedSourceID)",
            method: "DELETE",
            idToken: idToken,
            bundle: bundle,
            session: session,
            expectedStatusCode: 204
        )
    }

    private func sendJSONRequest<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        method: String,
        idToken: String,
        requestBody: RequestBody?,
        queryItems: [URLQueryItem] = [],
        bundle: Bundle,
        session: URLSession,
        responseType: ResponseBody.Type
    ) async throws -> ResponseBody {
        let endpoint = try endpointURL(path: path, queryItems: queryItems, bundle: bundle)
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        if let requestBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(requestBody)
        }

        let (data, response) = try await data(for: request, session: session)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw serverError(from: data, statusCode: httpResponse.statusCode)
        }
        return try JSONDecoder().decode(responseType, from: data)
    }

    private func sendEmptyRequest(
        path: String,
        method: String,
        idToken: String,
        bundle: Bundle,
        session: URLSession,
        expectedStatusCode: Int
    ) async throws {
        let endpoint = try endpointURL(path: path, bundle: bundle)
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await data(for: request, session: session)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard httpResponse.statusCode == expectedStatusCode else {
            throw serverError(from: data, statusCode: httpResponse.statusCode)
        }
    }

    private func baseURL(bundle: Bundle) throws -> URL {
        guard
            let baseURLString = baseURLOverride
            ?? (bundle.object(forInfoDictionaryKey: "GuardianAPIBaseURL") as? String)
        else {
            throw ClientError.missingBaseURL
        }
        guard let baseURL = URL(string: baseURLString) else {
            throw ClientError.invalidBaseURL(baseURLString)
        }
        return baseURL
    }

    private func endpointURL(
        path: String,
        queryItems: [URLQueryItem] = [],
        bundle: Bundle
    ) throws -> URL {
        let base = try baseURL(bundle: bundle).appending(path: path)
        guard !queryItems.isEmpty else {
            return base
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidBaseURL(base.absoluteString)
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ClientError.invalidBaseURL(base.absoluteString)
        }
        return url
    }

    private func data(
        for request: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        try await withRetryingNetworkOperation {
            try await session.data(for: request)
        }
    }

    private func withRetryingNetworkOperation<T>(
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let delays: [Double] = [0.5, 1.0, 2.0]
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard shouldRetryNetworkError(error), attempt < delays.count else {
                    throw error
                }
                let delay = delays[attempt]
                attempt += 1
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func shouldRetryNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return false
        }
        switch nsError.code {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorCallIsActive,
             NSURLErrorDataNotAllowed,
             NSURLErrorSecureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private func serverError(from data: Data, statusCode: Int) -> ClientError {
        let detail = (try? JSONDecoder().decode(ErrorPayload.self, from: data).detail)
            ?? String(data: data, encoding: .utf8)
            ?? "Unknown error"
        return .server(statusCode: statusCode, detail: detail)
    }
}
