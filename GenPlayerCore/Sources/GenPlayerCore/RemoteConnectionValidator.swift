import Foundation

public enum RemoteConnectionValidator {
    public static func validate(
        server: ServerConfig,
        timeoutNanoseconds: UInt64 = 15_000_000_000
    ) async throws -> ServerConfig {
        try await withThrowingTaskGroup(of: ServerConfig.self) { group in
            group.addTask {
                try await AppNetworkService.shared.testConnection(server)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw NSError(
                    domain: "GenPlayer",
                    code: NSURLErrorTimedOut,
                    userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString(
                            "Connection timed out. Please check server address, port, and network status.",
                            comment: ""
                        )
                    ]
                )
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }

            group.cancelAll()
            return result
        }
    }
}
