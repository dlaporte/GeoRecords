import SwiftUI
import CoreLocation

/// Reusable UI components for the setup wizard

// MARK: - Density

/// Sizes for the setup wizard steps: roomy on phones in portrait, compact where
/// the page is too short for the roomy layout (folded iPhone Duo, iPhone SE).
/// Roomy is today's literals; compact fits the Duo's 382×644 window.
enum WizardDensity: Equatable {
    case roomy, compact

    var horizontalPadding: CGFloat { self == .roomy ? 40 : 24 }
    var stackSpacing: CGFloat { self == .roomy ? 30 : 20 }
    var titleSpacing: CGFloat { self == .roomy ? 12 : 8 }
    var listSpacing: CGFloat { self == .roomy ? 16 : 12 }
    var listTopPadding: CGFloat { self == .roomy ? 20 : 12 }
    /// The Welcome image
    var heroIconSize: CGFloat { self == .roomy ? 120 : 88 }
    /// The SF Symbol above the other steps' titles
    var symbolSize: CGFloat { self == .roomy ? 60 : 48 }
    var welcomeTitleSize: CGFloat { self == .roomy ? 32 : 28 }
    var welcomeSubtitle: Font { self == .roomy ? .title3 : .body }
    var cardPadding: CGFloat { self == .roomy ? 20 : 16 }
    var cardIconWidth: CGFloat { self == .roomy ? 50 : 36 }
    var cardIconFont: Font { self == .roomy ? .title : .title2 }
    var homeMapHeight: CGFloat { self == .roomy ? 200 : 160 }
}

extension EnvironmentValues {
    @Entry var wizardDensity: WizardDensity = .roomy
}

/// Shows `content` roomy when its wrapped text fits the page height, compact
/// otherwise. No scroll view: on the folded Duo every step fits compact.
struct FitToHeight<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.environment(\.wizardDensity, .roomy)
            content.environment(\.wizardDensity, .compact)
        }
    }
}

// MARK: - Feature Row
struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 30)

            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Unit System Card
struct UnitSystemCard: View {
    @Environment(\.wizardDensity) private var density
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(density.cardIconFont)
                    .foregroundColor(isSelected ? .white : .blue)
                    .frame(width: density.cardIconWidth)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundColor(isSelected ? .white : .primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                }
            }
            .padding(density.cardPadding)
            .background(isSelected ? Color.blue : Color(UIColor.secondarySystemBackground))
            .cornerRadius(16)
        }
    }
}

// MARK: - Notification Toggle Card
struct NotificationToggleCard: View {
    @Environment(\.wizardDensity) private var density
    let title: String
    let subtitle: String
    let icon: String
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(.blue)
                .frame(width: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.secondary)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
        }
        .padding(density.cardPadding)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(16)
    }
}

// MARK: - Import Option Card
struct ImportOptionCard: View {
    @Environment(\.wizardDensity) private var density
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(density.cardIconFont)
                    .foregroundColor(isSelected ? .white : .blue)
                    .frame(width: density.cardIconWidth)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundColor(isSelected ? .white : .primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                }
            }
            .padding(density.cardPadding)
            .background(isSelected ? Color.blue : Color(UIColor.secondarySystemBackground))
            .cornerRadius(16)
        }
    }
}
