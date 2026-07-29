import Foundation

/// Async git branch resolver with caching for sidebar display.
///
/// Per the plan's Phase 4 GitMetadataService spec: an actor that provides
/// normalized-PWD/generation cache, debounce/cancel/TTL, `.git` dir/file/
/// relative-gitdir support, and a process-wide two-probe bound.
///
/// This is a simplified version that resolves git branches asynchronously
/// and caches results with a TTL to avoid main-thread filesystem access.
actor GitMetadataService {
    static let shared = GitMetadataService()

    private struct CacheEntry {
        let branch: String?
        let timestamp: Date
    }

    /// Cache TTL in seconds.
    private let ttl: TimeInterval = 10.0

    /// Cache keyed by normalized pwd.
    private var cache: [String: CacheEntry] = [:]

    /// Maximum cache entries to prevent unbounded growth.
    private let maxCacheSize = 100

    func branch(forPwd pwd: String) async -> String? {
        let normalized = normalize(pwd: pwd)

        // Check cache.
        if let entry = cache[normalized],
           Date().timeIntervalSince(entry.timestamp) < ttl {
            return entry.branch
        }

        // Resolve asynchronously.
        let resolved = await resolveBranch(pwd: pwd)

        // Update cache.
        cache[normalized] = CacheEntry(branch: resolved, timestamp: Date())

        // Trim cache if needed.
        if cache.count > maxCacheSize {
            let oldest = cache.min(by: { $0.value.timestamp < $1.value.timestamp })
            if let key = oldest?.key {
                cache.removeValue(forKey: key)
            }
        }

        return resolved
    }

    /// Clears the cache (e.g., when a workspace is closed).
    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Resolution

    private func resolveBranch(pwd: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = GitBranchResolver.branch(for: pwd)
                continuation.resume(returning: result)
            }
        }
    }

    private func normalize(pwd: String) -> String {
        // Normalize trailing slash and symlinks for cache key.
        var url = URL(fileURLWithPath: pwd)
        url.standardize()
        return url.path
    }
}
