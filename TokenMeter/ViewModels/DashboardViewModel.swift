import Foundation
import SwiftUI
import UserNotifications

@Observable
@MainActor
class DashboardViewModel {
    var selectedPeriod: TimePeriod = .weekly
    var summary: UsageSummary?
    var isLoading = false
    var error: String?
    var lastRefreshed: Date?

    // Auto-refresh
    var autoRefreshEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "autoRefreshEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoRefreshEnabled")
            if newValue { startAutoRefresh() } else { stopAutoRefresh() }
        }
    }

    var autoRefreshInterval: TimeInterval {
        get {
            let val = UserDefaults.standard.double(forKey: "autoRefreshInterval")
            return val > 0 ? val : 300 // default 5 minutes
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoRefreshInterval")
            if autoRefreshEnabled { startAutoRefresh() }
        }
    }

    // Budget thresholds
    var dailyBudget: Double {
        get { UserDefaults.standard.double(forKey: "dailyBudget") }
        set { UserDefaults.standard.set(newValue, forKey: "dailyBudget") }
    }

    var monthlyBudget: Double {
        get { UserDefaults.standard.double(forKey: "monthlyBudget") }
        set { UserDefaults.standard.set(newValue, forKey: "monthlyBudget") }
    }

    var budgetNotificationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "budgetNotificationsEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "budgetNotificationsEnabled")
            if newValue { requestNotificationPermission() }
        }
    }

    let providers: [any UsageProvider] = [
        AnthropicProvider(),
        OpenAIProvider(),
    ]

    var configuredProviders: [any UsageProvider] {
        providers.filter { $0.isConfigured }
    }

    var hasAnyProvider: Bool {
        !configuredProviders.isEmpty
    }

    private var refreshTimer: Timer?

    init() {
        if autoRefreshEnabled {
            startAutoRefresh()
        }
    }

    // MARK: - Refresh

    func refresh() async {
        isLoading = true
        error = nil

        let active = configuredProviders
        guard !active.isEmpty else {
            error = "No providers configured"
            isLoading = false
            return
        }

        // Fetch from all providers, collecting partial results even if some fail
        let results = await withTaskGroup(of: Result<ProviderUsage, Error>.self) { group in
            for provider in active {
                group.addTask {
                    do {
                        let usage = try await provider.fetchUsage(period: self.selectedPeriod)
                        return .success(usage)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var usages: [ProviderUsage] = []
            var errors: [String] = []
            for await result in group {
                switch result {
                case .success(let usage): usages.append(usage)
                case .failure(let error): errors.append(error.localizedDescription)
                }
            }
            return (usages, errors)
        }

        let (usages, errors) = results

        if usages.isEmpty && !errors.isEmpty {
            self.error = errors.joined(separator: "\n")
        } else {
            if !errors.isEmpty {
                // Partial failure — show data but note errors
                self.error = errors.joined(separator: "\n")
            }
            let trend = await fetchTrend(providers: active, currentUsages: usages)
            summary = aggregate(usages, trend: trend)
            lastRefreshed = Date()
            checkBudgetThresholds()
        }

        isLoading = false
    }

    // MARK: - Auto-Refresh

    func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: autoRefreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Budget Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func checkBudgetThresholds() {
        guard budgetNotificationsEnabled, let summary else { return }

        let cost = summary.totalCost

        if dailyBudget > 0 && selectedPeriod == .weekly && cost >= dailyBudget {
            sendBudgetNotification(
                title: "Daily Budget Exceeded",
                body: String(format: "You've spent $%.2f today (budget: $%.2f)", cost, dailyBudget)
            )
        }

        if monthlyBudget > 0 && selectedPeriod == .monthly && cost >= monthlyBudget {
            sendBudgetNotification(
                title: "Monthly Budget Exceeded",
                body: String(format: "You've spent $%.2f this month (budget: $%.2f)", cost, monthlyBudget)
            )
        }

        // Warn at 80% threshold too
        if dailyBudget > 0 && selectedPeriod == .weekly && cost >= dailyBudget * 0.8 && cost < dailyBudget {
            sendBudgetNotification(
                title: "Approaching Daily Budget",
                body: String(format: "You've spent $%.2f of your $%.2f daily budget (%.0f%%)", cost, dailyBudget, cost / dailyBudget * 100)
            )
        }

        if monthlyBudget > 0 && selectedPeriod == .monthly && cost >= monthlyBudget * 0.8 && cost < monthlyBudget {
            sendBudgetNotification(
                title: "Approaching Monthly Budget",
                body: String(format: "You've spent $%.2f of your $%.2f monthly budget (%.0f%%)", cost, monthlyBudget, cost / monthlyBudget * 100)
            )
        }
    }

    private func sendBudgetNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // Use a unique ID per title so we don't spam the same notification
        let id = title.replacingOccurrences(of: " ", with: "-").lowercased()
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Trend

    private func fetchTrend(providers: [any UsageProvider], currentUsages: [ProviderUsage]) async -> TrendData? {
        do {
            var prevTokens = 0
            var prevCost = 0.0

            try await withThrowingTaskGroup(of: (Int, Double).self) { group in
                for provider in providers {
                    if let anthropic = provider as? AnthropicProvider {
                        group.addTask {
                            try await anthropic.fetchPreviousPeriodTotals(period: self.selectedPeriod)
                        }
                    } else if let openAI = provider as? OpenAIProvider {
                        group.addTask {
                            try await openAI.fetchPreviousPeriodTotals(period: self.selectedPeriod)
                        }
                    }
                }

                for try await (tokens, cost) in group {
                    prevTokens += tokens
                    prevCost += cost
                }
            }

            let currentTokens = currentUsages.reduce(0) { $0 + $1.totalTokens }
            let currentCost = currentUsages.reduce(0.0) { $0 + ($1.totalCost ?? 0) }

            return TrendData(
                previousTotalTokens: prevTokens,
                previousTotalCost: prevCost,
                currentTotalTokens: currentTokens,
                currentTotalCost: currentCost
            )
        } catch {
            return nil
        }
    }

    // MARK: - Aggregation

    private func aggregate(_ providerUsages: [ProviderUsage], trend: TrendData?) -> UsageSummary {
        var totalInput = 0
        var totalOutput = 0
        var totalCost = 0.0
        var allBuckets: [BucketSummary] = []
        var allModels: [ModelUsage] = []
        var totalUncached = 0
        var totalCacheRead = 0
        var totalCacheCreation = 0
        var allCostBreakdown: [CostBreakdownItem] = []
        var allTiers: [ServiceTierUsage] = []
        var allContextWindows: [ContextWindowUsage] = []

        for usage in providerUsages {
            totalInput += usage.totalInputTokens
            totalOutput += usage.totalOutputTokens
            totalCost += usage.totalCost ?? 0
            allBuckets.append(contentsOf: usage.buckets)
            allModels.append(contentsOf: usage.modelBreakdown)
            totalUncached += usage.cacheBreakdown.uncachedInputTokens
            totalCacheRead += usage.cacheBreakdown.cacheReadTokens
            totalCacheCreation += usage.cacheBreakdown.cacheCreationTokens
            allCostBreakdown.append(contentsOf: usage.costBreakdown)
            allTiers.append(contentsOf: usage.serviceTierBreakdown)
            allContextWindows.append(contentsOf: usage.contextWindowBreakdown)
        }

        // Merge buckets by label
        var bucketMap: [String: (date: Date, input: Int, output: Int)] = [:]
        for bucket in allBuckets {
            let existing = bucketMap[bucket.label, default: (bucket.date, 0, 0)]
            bucketMap[bucket.label] = (existing.date, existing.input + bucket.inputTokens, existing.output + bucket.outputTokens)
        }

        let mergedBuckets = bucketMap.map { label, value in
            BucketSummary(label: label, date: value.date, inputTokens: value.input, outputTokens: value.output, totalTokens: value.input + value.output)
        }.sorted { $0.date < $1.date }

        // Merge cost breakdown by category
        var costMap: [String: (amount: Double, color: Color)] = [:]
        for item in allCostBreakdown {
            let existing = costMap[item.category, default: (0, item.color)]
            costMap[item.category] = (existing.amount + item.amount, existing.color)
        }
        let mergedCostBreakdown = costMap.map { CostBreakdownItem(category: $0.key, amount: $0.value.amount, color: $0.value.color) }
            .sorted { $0.amount > $1.amount }

        let days = selectedPeriod.daysInPeriod
        let totalTokens = totalInput + totalOutput

        return UsageSummary(
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            totalTokens: totalTokens,
            totalCost: totalCost,
            dailyAvgTokens: totalTokens / max(days, 1),
            dailyAvgCost: totalCost / Double(max(days, 1)),
            trend: trend,
            buckets: mergedBuckets,
            modelBreakdown: allModels.sorted { $0.totalTokens > $1.totalTokens },
            cacheBreakdown: CacheBreakdown(uncachedInputTokens: totalUncached, cacheReadTokens: totalCacheRead, cacheCreationTokens: totalCacheCreation),
            costBreakdown: mergedCostBreakdown,
            serviceTierBreakdown: allTiers.sorted { $0.tokens > $1.tokens },
            contextWindowBreakdown: allContextWindows.sorted { $0.tokens > $1.tokens },
            providerBreakdown: providerUsages
        )
    }
}
