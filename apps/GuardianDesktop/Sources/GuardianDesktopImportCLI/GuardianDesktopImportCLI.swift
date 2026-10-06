import Foundation

struct CLIConfig {
    let apiBaseURL: String
    let bearerToken: String
    let sourceID: String
    let displayName: String
    let ownedSourceID: String?
    let selectedURLs: [URL]
    let pollTimeoutSeconds: TimeInterval
}

enum CLIError: LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case let .usage(message):
            return message
        }
    }
}

@main
struct GuardianDesktopImportCLI {
    static func main() async {
        do {
            let config = try parseConfig(arguments: CommandLine.arguments)
            let result = try await run(config: config)
            try printJSON(
                [
                    "api_base_url": config.apiBaseURL,
                    "display_name": config.displayName,
                    "owned_source_id": result.ownedSourceID,
                    "import_run_id": result.importRunID,
                    "user_id": result.userID,
                    "total_candidate_file_count": result.totalCandidateFileCount,
                    "total_candidate_size_bytes": result.totalCandidateSizeBytes,
                    "missing_candidate_file_count": result.missingCandidateFileCount,
                    "shard_count": result.shardCount,
                    "uploaded_shard_count": result.uploadedShardCount,
                    "settled_status": result.settledStatus,
                    "canonical_file_count": result.canonicalFileCount,
                    "processed_transport_shard_count": result.processedTransportShardCount,
                    "success": result.settledStatus == "completed",
                ]
            )
        } catch {
            let message = error.localizedDescription
            try? printJSON(["success": false, "error": message])
            fputs(message + "\n", stderr)
            exit(1)
        }
    }

    private static func run(config: CLIConfig) async throws -> DesktopImportResult {
        let backendClient = GuardianBackendClient(baseURLOverride: config.apiBaseURL)
        let ownedSourceID: String
        if let existing = config.ownedSourceID {
            ownedSourceID = existing
        } else {
            let source = try await backendClient.createOwnedSource(
                idToken: config.bearerToken,
                sourceID: config.sourceID,
                displayName: config.displayName
            )
            ownedSourceID = source.ownedSourceID
        }

        return try await DesktopImportRunner.runImport(
            backendClient: backendClient,
            idToken: config.bearerToken,
            ownedSourceID: ownedSourceID,
            selectedURLs: config.selectedURLs,
            pollTimeoutSeconds: config.pollTimeoutSeconds
        )
    }

    private static func parseConfig(arguments: [String]) throws -> CLIConfig {
        var apiBaseURL: String?
        var bearerToken: String?
        var sourceID = "screenpipe"
        var displayName: String?
        var ownedSourceID: String?
        var selectedPaths: [String] = []
        var pollTimeoutSeconds: TimeInterval = 300

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--api-base-url":
                index += 1
                apiBaseURL = try requireValue(arguments: arguments, index: index, flag: argument)
            case "--bearer-token":
                index += 1
                bearerToken = try requireValue(arguments: arguments, index: index, flag: argument)
            case "--source-id":
                index += 1
                sourceID = try requireValue(arguments: arguments, index: index, flag: argument)
            case "--display-name":
                index += 1
                displayName = try requireValue(arguments: arguments, index: index, flag: argument)
            case "--owned-source-id":
                index += 1
                ownedSourceID = try requireValue(arguments: arguments, index: index, flag: argument)
            case "--input-path":
                index += 1
                selectedPaths.append(try requireValue(arguments: arguments, index: index, flag: argument))
            case "--poll-timeout-seconds":
                index += 1
                let raw = try requireValue(arguments: arguments, index: index, flag: argument)
                guard let parsed = TimeInterval(raw), parsed > 0 else {
                    throw CLIError.usage("Invalid value for --poll-timeout-seconds: \(raw)")
                }
                pollTimeoutSeconds = parsed
            case "--help", "-h":
                throw CLIError.usage(usage)
            default:
                throw CLIError.usage("Unknown argument: \(argument)\n\n\(usage)")
            }
            index += 1
        }

        guard let resolvedAPIBaseURL = nonEmpty(apiBaseURL) else {
            throw CLIError.usage("Missing --api-base-url\n\n\(usage)")
        }
        guard let resolvedBearerToken = nonEmpty(bearerToken) else {
            throw CLIError.usage("Missing --bearer-token\n\n\(usage)")
        }
        guard !selectedPaths.isEmpty else {
            throw CLIError.usage("At least one --input-path is required\n\n\(usage)")
        }

        let resolvedDisplayName = nonEmpty(displayName) ?? "Desktop CLI Import \(UUID().uuidString.prefix(8))"
        let selectedURLs = selectedPaths.map { URL(fileURLWithPath: $0) }

        return CLIConfig(
            apiBaseURL: resolvedAPIBaseURL,
            bearerToken: resolvedBearerToken,
            sourceID: sourceID,
            displayName: resolvedDisplayName,
            ownedSourceID: nonEmpty(ownedSourceID),
            selectedURLs: selectedURLs,
            pollTimeoutSeconds: pollTimeoutSeconds
        )
    }

    private static func requireValue(arguments: [String], index: Int, flag: String) throws -> String {
        guard index < arguments.count else {
            throw CLIError.usage("Missing value for \(flag)\n\n\(usage)")
        }
        return arguments[index]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func printJSON(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError.usage("Could not render JSON output.")
        }
        print(text)
    }

    private static let usage = """
    Usage:
      GuardianDesktopImportCLI --api-base-url URL --bearer-token TOKEN --input-path PATH [--input-path PATH ...]
        [--source-id SOURCE_ID]
        [--display-name NAME]
        [--owned-source-id OWNED_SOURCE_ID]
        [--poll-timeout-seconds SECONDS]
    """
}
