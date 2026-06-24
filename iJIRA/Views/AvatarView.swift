import SwiftUI

/// Rundes Actor-Avatar mit Fallback-Symbol je nach Notification-Typ.
struct AvatarView: View {
    let url: URL?
    let kind: NotificationKind
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.quaternary, lineWidth: 0.5))
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(.quaternary.opacity(0.4))
            Image(systemName: kind.symbolName)
                .font(.system(size: size * 0.45))
                .foregroundStyle(.secondary)
        }
    }
}

extension NotificationKind {
    var symbolName: String {
        switch self {
        case .comment: return "text.bubble"
        case .statusChange: return "arrow.triangle.swap"
        case .assignment: return "person.crop.circle"
        case .fieldChange: return "pencil"
        case .other: return "bell"
        }
    }
}
