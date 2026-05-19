import SwiftUI
import Charts

struct DashboardView: View {
    @Bindable var viewModel: DashboardViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                periodPicker

                if viewModel.isLoading {
                    loadingView
                } else if let error = viewModel.error {
                    errorView(error)
                } else if let summary = viewModel.summary {
                    heroCards(summary)
                    trendBadges(summary)
                    usageChart(summary)
                    cacheSection(summary)
                    costSection(summary)
                    modelsSection(summary)
                    tiersAndContextSection(summary)
                    if summary.providerBreakdown.count > 1 {
                        providersSection(summary)
                    }
                } else {
                    emptyState
                }
            }
            .padding(16)
        }
        .frame(width: 380, height: 520)
        .task {
            if viewModel.hasAnyProvider && viewModel.summary == nil {
                await viewModel.refresh()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("TokenMeter")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                    if viewModel.autoRefreshEnabled {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                    }
                }
                if let lastRefreshed = viewModel.lastRefreshed {
                    Text("Updated \(lastRefreshed, style: .relative) ago")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("AI Usage Dashboard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(.quaternary.opacity(0.5), in: Circle())
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isLoading)
        }
    }

    // MARK: - Period Picker

    private var periodPicker: some View {
        Picker("Period", selection: $viewModel.selectedPeriod) {
            ForEach(TimePeriod.allCases) { period in
                Text(period.rawValue).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: viewModel.selectedPeriod) {
            Task { await viewModel.refresh() }
        }
    }

    // MARK: - Hero Cards

    private func heroCards(_ summary: UsageSummary) -> some View {
        HStack(spacing: 8) {
            heroCard(
                title: "Total Tokens",
                value: formatTokens(summary.totalTokens),
                icon: "number.circle.fill",
                gradient: Gradient(colors: [.blue, .cyan])
            )
            heroCard(
                title: "Total Cost",
                value: String(format: "$%.2f", summary.totalCost),
                icon: "dollarsign.circle.fill",
                gradient: Gradient(colors: [.green, .mint])
            )
        }
    }

    private func heroCard(title: String, value: String, icon: String, gradient: Gradient) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.linearGradient(gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
    }

    // MARK: - Trend Badges

    @ViewBuilder
    private func trendBadges(_ summary: UsageSummary) -> some View {
        if let trend = summary.trend {
            HStack(spacing: 8) {
                if let tokenChange = trend.tokenChangePercent {
                    trendBadge(
                        label: "vs prev period",
                        value: String(format: "%+.0f%%", tokenChange),
                        isPositive: tokenChange <= 0
                    )
                }

                miniStat(label: "Daily Avg", value: formatTokens(summary.dailyAvgTokens))
                miniStat(label: "Daily Avg Cost", value: String(format: "$%.2f", summary.dailyAvgCost))

                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.caption2)
                    Text("\(formatTokens(summary.totalInputTokens)) in")
                        .font(.caption2)
                }

                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.purple)
                        .font(.caption2)
                    Text("\(formatTokens(summary.totalOutputTokens)) out")
                        .font(.caption2)
                }
            }
        } else {
            HStack(spacing: 8) {
                miniStat(label: "Input", value: formatTokens(summary.totalInputTokens))
                miniStat(label: "Output", value: formatTokens(summary.totalOutputTokens))
                miniStat(label: "Daily Avg", value: formatTokens(summary.dailyAvgTokens))
                miniStat(label: "Avg Cost", value: String(format: "$%.2f", summary.dailyAvgCost))
            }
        }
    }

    private func trendBadge(label: String, value: String, isPositive: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: isPositive ? "arrow.down.right" : "arrow.up.right")
                .font(.system(size: 9, weight: .bold))
            Text(value)
                .font(.system(.caption2, design: .rounded, weight: .semibold))
        }
        .foregroundStyle(isPositive ? .green : .orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            (isPositive ? Color.green : Color.orange).opacity(0.12),
            in: Capsule()
        )
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(.caption2, design: .rounded, weight: .semibold))
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Usage Chart

    @ViewBuilder
    private func usageChart(_ summary: UsageSummary) -> some View {
        if !summary.buckets.isEmpty {
            sectionCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Usage Over Time")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Chart(summary.buckets) { bucket in
                        BarMark(
                            x: .value("Time", bucket.label),
                            y: .value("Input", bucket.inputTokens)
                        )
                        .foregroundStyle(.blue.gradient)

                        BarMark(
                            x: .value("Time", bucket.label),
                            y: .value("Output", bucket.outputTokens)
                        )
                        .foregroundStyle(.purple.gradient)
                    }
                    .chartForegroundStyleScale([
                        "Input": Color.blue,
                        "Output": Color.purple,
                    ])
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                            AxisValueLabel {
                                if let intValue = value.as(Int.self) {
                                    Text(formatTokensShort(intValue))
                                        .font(.system(size: 9))
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks { _ in
                            AxisValueLabel()
                                .font(.system(size: 9))
                        }
                    }
                    .frame(height: 140)
                }
            }
        }
    }

    // MARK: - Cache Section

    @ViewBuilder
    private func cacheSection(_ summary: UsageSummary) -> some View {
        let cache = summary.cacheBreakdown
        if cache.totalTokens > 0 {
            sectionCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cache Performance")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f%% hit rate", cache.cacheHitRate))
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .foregroundStyle(.green)
                    }

                    // Cache bar
                    GeometryReader { geo in
                        let total = max(Double(cache.totalTokens), 1)
                        let readWidth = Double(cache.cacheReadTokens) / total * geo.size.width
                        let createWidth = Double(cache.cacheCreationTokens) / total * geo.size.width

                        HStack(spacing: 1) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.green.gradient)
                                .frame(width: max(readWidth, 0))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.orange.gradient)
                                .frame(width: max(createWidth, 0))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.gray.gradient.opacity(0.4))
                        }
                    }
                    .frame(height: 8)

                    HStack(spacing: 12) {
                        cacheLabel(color: .green, label: "Cache Read", value: formatTokens(cache.cacheReadTokens))
                        cacheLabel(color: .orange, label: "Cache Write", value: formatTokens(cache.cacheCreationTokens))
                        cacheLabel(color: .gray, label: "Uncached", value: formatTokens(cache.uncachedInputTokens))
                    }
                }
            }
        }
    }

    private func cacheLabel(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                Text(label)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Cost Section

    @ViewBuilder
    private func costSection(_ summary: UsageSummary) -> some View {
        if !summary.costBreakdown.isEmpty {
            sectionCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cost Breakdown")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(summary.costBreakdown) { item in
                        HStack {
                            Circle().fill(item.color).frame(width: 8, height: 8)
                            Text(item.category)
                                .font(.caption)
                            Spacer()
                            Text(String(format: "$%.4f", item.amount))
                                .font(.system(.caption, design: .monospaced, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Models Section

    @ViewBuilder
    private func modelsSection(_ summary: UsageSummary) -> some View {
        if !summary.modelBreakdown.isEmpty {
            sectionCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Models")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(summary.modelBreakdown) { model in
                        VStack(spacing: 4) {
                            HStack {
                                Image(model.provider.logoName)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 12, height: 12)
                                Text(model.model)
                                    .font(.system(.caption, weight: .medium))
                                Spacer()
                                Text(formatTokens(model.totalTokens))
                                    .font(.system(.caption, design: .monospaced, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            // Mini usage bar
                            GeometryReader { geo in
                                let total = max(Double(summary.totalTokens), 1)
                                let width = Double(model.totalTokens) / total * geo.size.width

                                RoundedRectangle(cornerRadius: 2)
                                    .fill(model.provider.color.gradient)
                                    .frame(width: max(width, 4))
                            }
                            .frame(height: 4)

                            HStack {
                                Text("\(formatTokens(model.inputTokens)) in / \(formatTokens(model.outputTokens)) out")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                if let cost = model.cost {
                                    Text(String(format: "$%.4f", cost))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Service Tier & Context Window

    @ViewBuilder
    private func tiersAndContextSection(_ summary: UsageSummary) -> some View {
        let hasTiers = !summary.serviceTierBreakdown.isEmpty
        let hasContext = !summary.contextWindowBreakdown.isEmpty

        if hasTiers || hasContext {
            HStack(alignment: .top, spacing: 8) {
                if hasTiers {
                    sectionCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Service Tier")
                                .font(.system(.caption, weight: .semibold))
                                .foregroundStyle(.secondary)

                            ForEach(summary.serviceTierBreakdown) { tier in
                                HStack {
                                    Text(tier.tier)
                                        .font(.caption2)
                                    Spacer()
                                    Text(formatTokens(tier.tokens))
                                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if hasContext {
                    sectionCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Context Window")
                                .font(.system(.caption, weight: .semibold))
                                .foregroundStyle(.secondary)

                            ForEach(summary.contextWindowBreakdown) { ctx in
                                HStack {
                                    Text(ctx.window)
                                        .font(.caption2)
                                    Spacer()
                                    Text(formatTokens(ctx.tokens))
                                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Providers Section

    @ViewBuilder
    private func providersSection(_ summary: UsageSummary) -> some View {
        sectionCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Providers")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(summary.providerBreakdown, id: \.provider) { usage in
                    HStack {
                        Image(usage.provider.logoName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                        Text(usage.provider.rawValue)
                            .font(.system(.caption, weight: .medium))
                        Spacer()
                        Text(formatTokens(usage.totalTokens))
                            .font(.system(.caption, design: .monospaced, weight: .medium))
                            .foregroundStyle(.secondary)
                        if let cost = usage.totalCost {
                            Text(String(format: "$%.2f", cost))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Shared Components

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading usage data...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var emptyState: some View {
        Text("Press refresh to load usage data.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }

    // MARK: - Formatting

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func formatTokensShort(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.0fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.0fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - Preview

#Preview {
    let vm = DashboardViewModel()
    vm.summary = UsageSummary(
        totalInputTokens: 1_245_000,
        totalOutputTokens: 389_000,
        totalTokens: 1_634_000,
        totalCost: 12.47,
        dailyAvgTokens: 233_428,
        dailyAvgCost: 1.78,
        trend: TrendData(
            previousTotalTokens: 1_100_000,
            previousTotalCost: 9.80,
            currentTotalTokens: 1_634_000,
            currentTotalCost: 12.47
        ),
        buckets: [
            BucketSummary(label: "Mon", date: .now.addingTimeInterval(-518400), inputTokens: 120_000, outputTokens: 35_000, totalTokens: 155_000),
            BucketSummary(label: "Tue", date: .now.addingTimeInterval(-432000), inputTokens: 245_000, outputTokens: 72_000, totalTokens: 317_000),
            BucketSummary(label: "Wed", date: .now.addingTimeInterval(-345600), inputTokens: 310_000, outputTokens: 98_000, totalTokens: 408_000),
            BucketSummary(label: "Thu", date: .now.addingTimeInterval(-259200), inputTokens: 420_000, outputTokens: 130_000, totalTokens: 550_000),
            BucketSummary(label: "Fri", date: .now.addingTimeInterval(-172800), inputTokens: 100_000, outputTokens: 36_000, totalTokens: 136_000),
            BucketSummary(label: "Sat", date: .now.addingTimeInterval(-86400), inputTokens: 50_000, outputTokens: 18_000, totalTokens: 68_000),
        ],
        modelBreakdown: [
            ModelUsage(model: "Claude Sonnet 4", provider: .anthropic, inputTokens: 800_000, outputTokens: 250_000, totalTokens: 1_050_000, cost: 8.20),
            ModelUsage(model: "Claude Haiku 3.5", provider: .anthropic, inputTokens: 445_000, outputTokens: 139_000, totalTokens: 584_000, cost: 4.27),
        ],
        cacheBreakdown: CacheBreakdown(
            uncachedInputTokens: 320_000,
            cacheReadTokens: 850_000,
            cacheCreationTokens: 75_000
        ),
        costBreakdown: [
            CostBreakdownItem(category: "Tokens", amount: 11.92, color: .blue),
            CostBreakdownItem(category: "Web Search", amount: 0.45, color: .purple),
            CostBreakdownItem(category: "Code Execution", amount: 0.10, color: .cyan),
        ],
        serviceTierBreakdown: [
            ServiceTierUsage(tier: "Standard", tokens: 1_400_000),
            ServiceTierUsage(tier: "Batch", tokens: 234_000),
        ],
        contextWindowBreakdown: [
            ContextWindowUsage(window: "0-200k", tokens: 1_534_000),
            ContextWindowUsage(window: "200k-1M", tokens: 100_000),
        ],
        providerBreakdown: []
    )
    vm.lastRefreshed = .now.addingTimeInterval(-120)
    vm.autoRefreshEnabled = true

    return DashboardView(viewModel: vm)
}
