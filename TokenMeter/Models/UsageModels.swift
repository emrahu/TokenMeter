import Foundation
import SwiftUI

// MARK: - Provider Identity

enum ProviderType: String, CaseIterable, Identifiable, Codable, Hashable {
    case anthropic = "Anthropic"
    case openAI = "OpenAI"

    var id: String { rawValue }

    var logoName: String {
        switch self {
        case .anthropic: return "logo_anthropic"
        case .openAI: return "logo_openai"
        }
    }

    var color: Color {
        switch self {
        case .anthropic: return .orange
        case .openAI: return .green
        }
    }

    var keychainKey: String {
        switch self {
        case .anthropic: return "anthropic_admin_key"
        case .openAI: return "openai_admin_key"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-admin-..."
        case .openAI: return "sk-admin-..."
        }
    }

    var keyHelp: String {
        switch self {
        case .anthropic: return "Requires an admin key from your Anthropic organization."
        case .openAI: return "Requires an admin key from your OpenAI organization."
        }
    }
}

// MARK: - Time Period Selection

enum TimePeriod: String, CaseIterable, Identifiable {
    case weekly = "Week"
    case monthly = "Month"
    case yearly = "Year"

    var id: String { rawValue }

    var dateRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        let now = Date()

        switch self {
        case .weekly:
            let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            return (weekStart, now)
        case .monthly:
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            return (monthStart, now)
        case .yearly:
            let yearStart = calendar.date(from: calendar.dateComponents([.year], from: now))!
            return (yearStart, now)
        }
    }

    /// Previous period of the same length, for trend comparison
    var previousDateRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        let (start, _) = dateRange

        switch self {
        case .weekly:
            let prevStart = calendar.date(byAdding: .weekOfYear, value: -1, to: start)!
            return (prevStart, start)
        case .monthly:
            let prevStart = calendar.date(byAdding: .month, value: -1, to: start)!
            return (prevStart, start)
        case .yearly:
            let prevStart = calendar.date(byAdding: .year, value: -1, to: start)!
            return (prevStart, start)
        }
    }

    var daysInPeriod: Int {
        let (start, end) = dateRange
        return max(Calendar.current.dateComponents([.day], from: start, to: end).day ?? 1, 1)
    }
}

// MARK: - Provider Protocol

protocol UsageProvider: Sendable {
    var providerType: ProviderType { get }
    var isConfigured: Bool { get }
    func fetchUsage(period: TimePeriod) async throws -> ProviderUsage
}

// MARK: - Provider-Agnostic Display Models

struct ProviderUsage: Sendable {
    let provider: ProviderType
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCost: Double?
    let buckets: [BucketSummary]
    let modelBreakdown: [ModelUsage]
    let cacheBreakdown: CacheBreakdown
    let costBreakdown: [CostBreakdownItem]
    let serviceTierBreakdown: [ServiceTierUsage]
    let contextWindowBreakdown: [ContextWindowUsage]

    var totalTokens: Int { totalInputTokens + totalOutputTokens }
}

struct UsageSummary {
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalTokens: Int
    let totalCost: Double
    let dailyAvgTokens: Int
    let dailyAvgCost: Double
    let trend: TrendData?
    let buckets: [BucketSummary]
    let modelBreakdown: [ModelUsage]
    let cacheBreakdown: CacheBreakdown
    let costBreakdown: [CostBreakdownItem]
    let serviceTierBreakdown: [ServiceTierUsage]
    let contextWindowBreakdown: [ContextWindowUsage]
    let providerBreakdown: [ProviderUsage]
}

struct TrendData: Sendable {
    let previousTotalTokens: Int
    let previousTotalCost: Double
    let currentTotalTokens: Int
    let currentTotalCost: Double

    var tokenChangePercent: Double? {
        guard previousTotalTokens > 0 else { return nil }
        return Double(currentTotalTokens - previousTotalTokens) / Double(previousTotalTokens) * 100
    }

    var costChangePercent: Double? {
        guard previousTotalCost > 0 else { return nil }
        return (currentTotalCost - previousTotalCost) / previousTotalCost * 100
    }
}

struct BucketSummary: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let date: Date
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
}

struct ModelUsage: Identifiable, Sendable {
    let id = UUID()
    let model: String
    let provider: ProviderType
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let cost: Double?
}

struct CacheBreakdown: Sendable {
    let uncachedInputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int

    var totalTokens: Int { uncachedInputTokens + cacheReadTokens + cacheCreationTokens }

    var cacheHitRate: Double {
        let total = uncachedInputTokens + cacheReadTokens
        guard total > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(total) * 100
    }

    static let zero = CacheBreakdown(uncachedInputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
}

struct CostBreakdownItem: Identifiable, Sendable {
    let id = UUID()
    let category: String
    let amount: Double
    let color: Color
}

struct ServiceTierUsage: Identifiable, Sendable {
    let id = UUID()
    let tier: String
    let tokens: Int
}

struct ContextWindowUsage: Identifiable, Sendable {
    let id = UUID()
    let window: String
    let tokens: Int
}
