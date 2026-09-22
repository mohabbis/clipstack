import Foundation

/// Decides which items have expired.
public enum RetentionPolicy {
    /// Splits `items` (newest first) into those to keep and those that expired, either by
    /// age (older than the retention period) or by count (beyond `maxItems`, oldest first).
    public static func apply(
        to items: [ClipItem],
        retention: RetentionPeriod,
        maxItems: Int,
        now: Date
    ) -> (kept: [ClipItem], expired: [ClipItem]) {
        var kept: [ClipItem] = []
        var expired: [ClipItem] = []
        let cutoff = retention.maxAge.map { now.addingTimeInterval(-$0) }
        let newestFirst = items.sorted { $0.createdAt > $1.createdAt }
        for item in newestFirst {
            if let cutoff, item.createdAt < cutoff {
                expired.append(item)
            } else if kept.count >= max(1, maxItems) {
                expired.append(item)
            } else {
                kept.append(item)
            }
        }
        return (kept, expired)
    }
}
