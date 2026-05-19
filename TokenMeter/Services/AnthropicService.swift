import Foundation
import SwiftUI

// MARK: - Anthropic API Response Models

struct AnthropicUsageResponse: Codable, Sendable {
    let data: [AnthropicUsageBucket]
    let hasMore: Bool
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

struct AnthropicUsageBucket: Codable, Sendable {
    let startingAt: String
    let endingAt: String
    let results: [AnthropicUsageResult]

    enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

struct AnthropicUsageResult: Codable, Sendable {
    let uncachedInputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreation: AnthropicCacheCreation?
    let outputTokens: Int?
    let model: String?
    let serviceTier: String?
    let contextWindow: String?

    enum CodingKeys: String, CodingKey {
        case uncachedInputTokens = "uncached_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreation = "cache_creation"
        case outputTokens = "output_tokens"
        case model
        case serviceTier = "service_tier"
        case contextWindow = "context_window"
    }

    var totalInputTokens: Int {
        (uncachedInputTokens ?? 0) + (cacheReadInputTokens ?? 0) + (cacheCreation?.totalTokens ?? 0)
    }
}

struct AnthropicCacheCreation: Codable, Sendable {
    let ephemeral5mInputTokens: Int?
    let ephemeral1hInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
        case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
    }

    var totalTokens: Int {
        (ephemeral5mInputTokens ?? 0) + (ephemeral1hInputTokens ?? 0)
    }
}

struct AnthropicCostResponse: Codable, Sendable {
    let data: [AnthropicCostBucket]
    let hasMore: Bool
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

struct AnthropicCostBucket: Codable, Sendable {
    let startingAt: String
    let endingAt: String
    let results: [AnthropicCostResult]

    enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

struct AnthropicCostResult: Codable, Sendable {
    let amount: String
    let currency: String
    let costType: String?
    let tokenType: String?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case amount
        case currency
        case costType = "cost_type"
        case tokenType = "token_type"
        case model
    }

    var amountInDollars: Double {
        (Double(amount) ?? 0) / 100.0
    }
}

// MARK: - Anthropic Provider

final class AnthropicProvider: UsageProvider, Sendable {
    let providerType = ProviderType.anthropic
    private let baseURL = "https://api.anthropic.com/v1/organizations"
    private let apiVersion = "2023-06-01"

    var isConfigured: Bool {
        let key = KeychainService.load(key: providerType.keychainKey)
        return key != nil && !(key?.isEmpty ?? true)
    }

    func fetchUsage(period: TimePeriod) async throws -> ProviderUsage {
        let (rawStart, rawEnd) = period.dateRange
        let (start, end) = validRange(rawStart, rawEnd)

        async let usageData = fetchUsageReport(start: start, end: end, period: period, groupBy: ["model", "service_tier", "context_window"])
        async let costData = fetchCostReport(start: start, end: end)

        let (usage, cost) = try await (usageData, costData)
        return aggregate(usage: usage, cost: cost, period: period)
    }

    func fetchPreviousPeriodTotals(period: TimePeriod) async throws -> (tokens: Int, cost: Double) {
        let (rawStart, rawEnd) = period.previousDateRange
        let (start, end) = validRange(rawStart, rawEnd)

        async let usageData = fetchUsageReport(start: start, end: end, period: period, groupBy: [])
        async let costData = fetchCostReport(start: start, end: end)

        let (usage, cost) = try await (usageData, costData)

        let totalTokens = usage.data.flatMap(\.results).reduce(0) { $0 + $1.totalInputTokens + ($1.outputTokens ?? 0) }
        let totalCost = cost.data.flatMap(\.results).reduce(0.0) { $0 + $1.amountInDollars }

        return (totalTokens, totalCost)
    }

    // MARK: - API Calls

    private func fetchUsageReport(start: Date, end: Date, period: TimePeriod, groupBy: [String]) async throws -> AnthropicUsageResponse {
        let bucketWidth = "1d"

        var components = URLComponents(string: "\(baseURL)/usage_report/messages")!
        var queryItems = [
            URLQueryItem(name: "starting_at", value: iso8601(start)),
            URLQueryItem(name: "ending_at", value: iso8601(end)),
            URLQueryItem(name: "bucket_width", value: bucketWidth),
        ]
        for field in groupBy {
            queryItems.append(URLQueryItem(name: "group_by[]", value: field))
        }
        components.queryItems = queryItems

        let data = try await request(url: components.url!)
        return try JSONDecoder().decode(AnthropicUsageResponse.self, from: data)
    }

    private func fetchCostReport(start: Date, end: Date) async throws -> AnthropicCostResponse {
        var components = URLComponents(string: "\(baseURL)/cost_report")!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: iso8601(start)),
            URLQueryItem(name: "ending_at", value: iso8601(end)),
            URLQueryItem(name: "bucket_width", value: "1d"),
        ]

        let data = try await request(url: components.url!)
        return try JSONDecoder().decode(AnthropicCostResponse.self, from: data)
    }

    // MARK: - Aggregation

    private func aggregate(usage: AnthropicUsageResponse, cost: AnthropicCostResponse, period: TimePeriod) -> ProviderUsage {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var totalInput = 0
        var totalOutput = 0
        var totalUncached = 0
        var totalCacheRead = 0
        var totalCacheCreation = 0

        var modelMap: [String: (input: Int, output: Int)] = [:]
        var tierMap: [String: Int] = [:]
        var contextMap: [String: Int] = [:]
        var bucketTokens: [String: (date: Date, input: Int, output: Int)] = [:]

        for bucket in usage.data {
            let date = formatter.date(from: bucket.startingAt) ?? Date()
            let label = bucketLabel(date: date, period: period)

            for result in bucket.results {
                let input = result.totalInputTokens
                let output = result.outputTokens ?? 0
                let uncached = result.uncachedInputTokens ?? 0
                let cacheRead = result.cacheReadInputTokens ?? 0
                let cacheCreation = result.cacheCreation?.totalTokens ?? 0

                totalInput += input
                totalOutput += output
                totalUncached += uncached
                totalCacheRead += cacheRead
                totalCacheCreation += cacheCreation

                // Bucket aggregation
                let existing = bucketTokens[label, default: (date, 0, 0)]
                bucketTokens[label] = (existing.date, existing.input + input, existing.output + output)

                // Model aggregation
                if let model = result.model {
                    let m = modelMap[model, default: (0, 0)]
                    modelMap[model] = (m.input + input, m.output + output)
                }

                // Service tier aggregation
                if let tier = result.serviceTier {
                    tierMap[tier, default: 0] += input + output
                }

                // Context window aggregation
                if let ctx = result.contextWindow {
                    contextMap[ctx, default: 0] += input + output
                }
            }
        }

        let buckets = bucketTokens.map { label, value in
            BucketSummary(label: label, date: value.date, inputTokens: value.input, outputTokens: value.output, totalTokens: value.input + value.output)
        }.sorted { $0.date < $1.date }

        // Cost aggregation by type
        var costByType: [String: Double] = [:]
        var costByModel: [String: Double] = [:]
        var totalCost = 0.0

        for bucket in cost.data {
            for result in bucket.results {
                let dollars = result.amountInDollars
                totalCost += dollars
                let typeName = result.costType ?? "other"
                costByType[typeName, default: 0] += dollars
                if let model = result.model {
                    costByModel[model, default: 0] += dollars
                }
            }
        }

        let costColors: [String: Color] = [
            "tokens": .blue,
            "web_search": .purple,
            "code_execution": .cyan,
        ]

        let costBreakdown = costByType.map { type, amount in
            CostBreakdownItem(
                category: Self.formatCostType(type),
                amount: amount,
                color: costColors[type] ?? .gray
            )
        }.sorted { $0.amount > $1.amount }

        let modelBreakdown = modelMap.map { key, value in
            ModelUsage(
                model: Self.formatModelName(key),
                provider: .anthropic,
                inputTokens: value.input,
                outputTokens: value.output,
                totalTokens: value.input + value.output,
                cost: costByModel[key]
            )
        }.sorted { $0.totalTokens > $1.totalTokens }

        let serviceTierBreakdown = tierMap.map { tier, tokens in
            ServiceTierUsage(tier: Self.formatTierName(tier), tokens: tokens)
        }.sorted { $0.tokens > $1.tokens }

        let contextWindowBreakdown = contextMap.map { ctx, tokens in
            ContextWindowUsage(window: ctx, tokens: tokens)
        }.sorted { $0.tokens > $1.tokens }

        return ProviderUsage(
            provider: .anthropic,
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            totalCost: totalCost,
            buckets: buckets,
            modelBreakdown: modelBreakdown,
            cacheBreakdown: CacheBreakdown(
                uncachedInputTokens: totalUncached,
                cacheReadTokens: totalCacheRead,
                cacheCreationTokens: totalCacheCreation
            ),
            costBreakdown: costBreakdown,
            serviceTierBreakdown: serviceTierBreakdown,
            contextWindowBreakdown: contextWindowBreakdown
        )
    }

    // MARK: - Helpers

    private func request(url: URL, retries: Int = 3) async throws -> Data {
        guard let apiKey = KeychainService.load(key: providerType.keychainKey) else {
            throw ProviderError.noAPIKey(providerType)
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse(providerType)
        }

        // Retry on rate limit
        if httpResponse.statusCode == 429 && retries > 0 {
            let retryAfter = Double(httpResponse.value(forHTTPHeaderField: "retry-after") ?? "2") ?? 2
            try await Task.sleep(for: .seconds(retryAfter))
            return try await self.request(url: url, retries: retries - 1)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No body"
            throw ProviderError.httpError(providerType, statusCode: httpResponse.statusCode, body: body)
        }

        return data
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Ensure end is strictly after start. The API snaps to UTC bucket
    /// boundaries itself — we just need to guarantee end > start.
    private func validRange(_ rawStart: Date, _ rawEnd: Date) -> (start: Date, end: Date) {
        let minEnd = rawStart.addingTimeInterval(86400) // at least 1 day apart
        let end = max(rawEnd, minEnd)
        return (rawStart, end)
    }

    private func bucketLabel(date: Date, period: TimePeriod) -> String {
        let formatter = DateFormatter()
        switch period {
        case .weekly: formatter.dateFormat = "EEE"
        case .monthly, .yearly: formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }

    private static func formatModelName(_ name: String) -> String {
        let parts = name.split(separator: "-")
        guard parts.count >= 3 else { return name }
        return "\(parts[0].capitalized) \(parts[1].capitalized) \(parts[2])"
    }

    private static func formatCostType(_ type: String) -> String {
        switch type {
        case "tokens": return "Tokens"
        case "web_search": return "Web Search"
        case "code_execution": return "Code Execution"
        default: return type.capitalized
        }
    }

    private static func formatTierName(_ tier: String) -> String {
        switch tier {
        case "standard": return "Standard"
        case "batch": return "Batch"
        case "priority": return "Priority"
        case "priority_on_demand": return "Priority (On-Demand)"
        case "flex": return "Flex"
        case "flex_discount": return "Flex (Discount)"
        default: return tier.capitalized
        }
    }
}

// MARK: - Shared Provider Error

enum ProviderError: LocalizedError {
    case noAPIKey(ProviderType)
    case invalidResponse(ProviderType)
    case httpError(ProviderType, statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey(let provider):
            return "No API key configured for \(provider.rawValue)"
        case .invalidResponse(let provider):
            return "Invalid response from \(provider.rawValue)"
        case .httpError(let provider, let code, let body):
            return "\(provider.rawValue) HTTP \(code): \(body)"
        }
    }
}
