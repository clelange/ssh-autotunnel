import SSHAutoTunnelCore
import SwiftUI

struct SectionPanel<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator, lineWidth: 0.5)
        }
    }
}

struct MetricTile: View {
    var title: String
    var value: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct KeyValueRow: Identifiable {
    var id = UUID()
    var key: String
    var value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

struct KeyValueGrid: View {
    var rows: [KeyValueRow]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.key)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 160, alignment: .leading)
                    Text(row.value)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

struct StatusBadge: View {
    var label: String
    var health: TunnelHealth

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor(for: health))
                .frame(width: 8, height: 8)
            if !label.isEmpty {
                Text(label)
                    .font(.caption.weight(.medium))
            }
            Text(health.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct StatusLine: View {
    var label: String
    var health: TunnelHealth
    var message: String
    var pid: Int32?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            StatusBadge(label: "", health: health)
                .frame(width: 84, alignment: .leading)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let pid {
                Text("PID \(pid)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct TagRow: View {
    var tags: [String]

    var body: some View {
        if tags.isEmpty {
            Text("No tags")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Label(tag, systemImage: "tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct InlineNotice: View {
    var title: String
    var message: String
    var systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct PlaceholderView: View {
    var title: String
    var systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FlowLayout<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: spacing) {
            content
        }
    }
}

func statusColor(for health: TunnelHealth) -> Color {
    switch health {
    case .healthy:
        .green
    case .degraded, .connecting, .reconnecting:
        .orange
    case .unhealthy, .failed:
        .red
    case .stopped:
        .secondary
    }
}

extension TunnelHealth {
    var isRunning: Bool {
        switch self {
        case .healthy, .connecting, .degraded, .reconnecting:
            true
        case .stopped, .unhealthy, .failed:
            false
        }
    }

    var needsAttention: Bool {
        switch self {
        case .unhealthy, .failed, .reconnecting:
            true
        case .stopped, .connecting, .healthy, .degraded:
            false
        }
    }

    var systemImage: String {
        switch self {
        case .healthy:
            "checkmark.circle.fill"
        case .degraded:
            "exclamationmark.triangle.fill"
        case .connecting, .reconnecting:
            "arrow.triangle.2.circlepath"
        case .unhealthy, .failed:
            "xmark.octagon.fill"
        case .stopped:
            "circle"
        }
    }
}

extension Optional where Wrapped == TunnelHealth {
    var isRunning: Bool {
        switch self {
        case .some(let health):
            health.isRunning
        case .none:
            false
        }
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var menuTruncated: String {
        guard count > 40 else { return self }
        return String(prefix(37)) + "..."
    }

    var trimmedForSettings: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
