import Foundation
import SwiftUI

// MARK: - OpenAI API Response Models

struct OpenAIUsageResponse: Codable, Sendable {
    let object: String
    let data: [OpenAIUsageBucket]
    let hasMore: Bool
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case object, data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

struct OpenAIUsageBucket: Codable, Sendable {
    let object: String
    let startTime: Int
    let endTime: Int
    let results: [OpenAIUsageResult]

    enum CodingKeys: String, CodingKey {
        case object
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

struct OpenAIUsageResult: Codable, Sendable {
    let object: String
    let inputTokens: Int
    let outputTokens: Int
    let inputCachedTokens: Int?
    let inputAudioTokens: Int?
    let outputAudioTokens: Int?
    let numModelRequests: Int
    let model: String?
    let batch: Bool?

    enum CodingKeys: String, CodingKey {
        case object
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case inputAudioTokens = "input_audio_tokens"
        case outputAudioTokens = "output_audio_tokens"
        case numModelRequests = "num_model_requests"
        case model, batch
    }
}

struct OpenAICostResponse: Codable, Sendable {
    let object: String
    let data: [OpenAICostBucket]
    let hasMore: Bool
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case object, data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

struct OpenAICostBucket: Codable, Sendable {
    let object: String
    let startTime: Int
    let endTime: Int
    let results: [OpenAICostResult]

    enum CodingKeys: String, CodingKey {
        case object
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

struct OpenAICostResult: Codable, Sendable {
    let object: String
    let amount: OpenAICostAmount
    let lineItem: String?
    let projectId: String?

    enum CodingKeys: String, CodingKey {
        case object, amount
        case lineItem = "line_item"
        case projectId = "project_id"
    }
}

struct OpenAICostAmount: Codable, Sendable {
    let value: Double
    let currency: String
}

// MARK: - OpenAI Provider

final class OpenAIProvider: UsageProvider, Sendable {
    let providerType = ProviderType.openAI
    private let baseURL = "https://api.openai.com/v1/organization"

    var isConfigured: Bool {
        let key = KeychainService.load(key: providerType.keychainKey)
        return key != nil && !(key?.isEmpty ?? true)
    }

    func fetchUsage(period: TimePeriod) async throws -> ProviderUsage {
        let (rawStart, rawEnd) = period.dateRange
        let (start, end) = validRange(rawStart, rawEnd)

        async let usageData = fetchCompletionsUsage(start: start, end: end, period: period)
        async let costData = fetchCosts(start: start, end: end)

        let (usage, cost) = try await (usageData, costData)
        return aggregate(usage: usage, cost: cost, period: period)
    }

    func fetchPreviousPeriodTotals(period: TimePeriod) async throws -> (tokens: Int, cost: Double) {
        let (rawStart, rawEnd) = period.previousDateRange
        let (start, end) = validRange(rawStart, rawEnd)

        async let usageData = fetchCompletionsUsage(start: start, end: end, period: period)
        async let costData = fetchCosts(start: start, end: end)

        let (usage, cost) = try await (usageData, costData)

        let totalTokens = usage.flatMap(\.results).reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
        let totalCost = cost.flatMap(\.results).reduce(0.0) { $0 + $1.amount.value }

        return (totalTokens, totalCost)
    }

    private func validRange(_ rawStart: Date, _ rawEnd: Date) -> (Date, Date) {
        let minEnd = rawStart.addingTimeInterval(86400)
        let end = max(rawEnd, minEnd)
        return (rawStart, end)
    }

    // MARK: - API Calls

    private func fetchCompletionsUsage(start: Date, end: Date, period: TimePeriod) async throws -> [OpenAIUsageBucket] {
        let bucketWidth = "1d"

        var allBuckets: [OpenAIUsageBucket] = []
        var page: String? = nil

        repeat {
            var components = URLComponents(string: "\(baseURL)/usage/completions")!
            var queryItems = [
                URLQueryItem(name: "start_time", value: "\(Int(start.timeIntervalSince1970))"),
                URLQueryItem(name: "end_time", value: "\(Int(end.timeIntervalSince1970))"),
                URLQueryItem(name: "bucket_width", value: bucketWidth),
                URLQueryItem(name: "group_by", value: "model"),
            ]
            if let page {
                queryItems.append(URLQueryItem(name: "page", value: page))
            }
            components.queryItems = queryItems

            let data = try await request(url: components.url!)
            let response = try JSONDecoder().decode(OpenAIUsageResponse.self, from: data)
            allBuckets.append(contentsOf: response.data)
            page = response.nextPage
        } while page != nil

        return allBuckets
    }

    private func fetchCosts(start: Date, end: Date) async throws -> [OpenAICostBucket] {
        var allBuckets: [OpenAICostBucket] = []
        var page: String? = nil

        repeat {
            var components = URLComponents(string: "\(baseURL)/costs")!
            var queryItems = [
                URLQueryItem(name: "start_time", value: "\(Int(start.timeIntervalSince1970))"),
                URLQueryItem(name: "end_time", value: "\(Int(end.timeIntervalSince1970))"),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "group_by", value: "line_item"),
                URLQueryItem(name: "limit", value: "180"),
            ]
            if let page {
                queryItems.append(URLQueryItem(name: "page", value: page))
            }
            components.queryItems = queryItems

            let data = try await request(url: components.url!)
            let response = try JSONDecoder().decode(OpenAICostResponse.self, from: data)
            allBuckets.append(contentsOf: response.data)
            page = response.nextPage
        } while page != nil

        return allBuckets
    }

    // MARK: - Aggregation

    private func aggregate(usage: [OpenAIUsageBucket], cost: [OpenAICostBucket], period: TimePeriod) -> ProviderUsage {
        var totalInput = 0
        var totalOutput = 0
        var totalCached = 0
        var modelMap: [String: (input: Int, output: Int)] = [:]
        var bucketTokens: [String: (date: Date, input: Int, output: Int)] = [:]

        for bucket in usage {
            let date = Date(timeIntervalSince1970: Double(bucket.startTime))
            let label = bucketLabel(date: date, period: period)

            for result in bucket.results {
                let input = result.inputTokens
                let output = result.outputTokens
                let cached = result.inputCachedTokens ?? 0

                totalInput += input
                totalOutput += output
                totalCached += cached

                let existing = bucketTokens[label, default: (date, 0, 0)]
                bucketTokens[label] = (existing.date, existing.input + input, existing.output + output)

                if let model = result.model {
                    let m = modelMap[model, default: (0, 0)]
                    modelMap[model] = (m.input + input, m.output + output)
                }
            }
        }

        let buckets = bucketTokens.map { label, value in
            BucketSummary(label: label, date: value.date, inputTokens: value.input, outputTokens: value.output, totalTokens: value.input + value.output)
        }.sorted { $0.date < $1.date }

        // Cost aggregation
        var totalCost = 0.0
        var costByLineItem: [String: Double] = [:]
        var costByModel: [String: Double] = [:]

        for bucket in cost {
            for result in bucket.results {
                let amount = result.amount.value
                totalCost += amount
                if let lineItem = result.lineItem {
                    costByLineItem[lineItem, default: 0] += amount
                    costByModel[lineItem, default: 0] += amount
                }
            }
        }

        let costBreakdown = costByLineItem.map { item, amount in
            CostBreakdownItem(
                category: Self.formatModelName(item),
                amount: amount,
                color: .green
            )
        }.sorted { $0.amount > $1.amount }

        let modelBreakdown = modelMap.map { key, value in
            ModelUsage(
                model: Self.formatModelName(key),
                provider: .openAI,
                inputTokens: value.input,
                outputTokens: value.output,
                totalTokens: value.input + value.output,
                cost: costByModel[key]
            )
        }.sorted { $0.totalTokens > $1.totalTokens }

        // OpenAI has cached tokens but no cache creation concept
        let uncached = totalInput - totalCached
        let cacheBreakdown = CacheBreakdown(
            uncachedInputTokens: max(uncached, 0),
            cacheReadTokens: totalCached,
            cacheCreationTokens: 0
        )

        return ProviderUsage(
            provider: .openAI,
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            totalCost: totalCost,
            buckets: buckets,
            modelBreakdown: modelBreakdown,
            cacheBreakdown: cacheBreakdown,
            costBreakdown: costBreakdown,
            serviceTierBreakdown: [],
            contextWindowBreakdown: []
        )
    }

    // MARK: - Helpers

    private func request(url: URL, retries: Int = 3) async throws -> Data {
        guard let apiKey = KeychainService.load(key: providerType.keychainKey) else {
            throw ProviderError.noAPIKey(providerType)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse(providerType)
        }

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

    private func bucketLabel(date: Date, period: TimePeriod) -> String {
        let formatter = DateFormatter()
        switch period {
        case .weekly: formatter.dateFormat = "EEE"
        case .monthly, .yearly: formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }

    private static func formatModelName(_ name: String) -> String {
        // e.g. "gpt-4o-2024-08-06" -> "GPT-4o 2024-08-06"
        if name.lowercased().hasPrefix("gpt-") {
            let withoutPrefix = name.dropFirst(4)
            return "GPT-\(withoutPrefix)"
        }
        if name.lowercased().hasPrefix("o1") || name.lowercased().hasPrefix("o3") || name.lowercased().hasPrefix("o4") {
            return name
        }
        return name
    }
}
