import LinkPresentation
import SwiftUI
import UIKit

// The app's one UIKit view (AGENTS.md, Development Defaults). Only
// UIActivityViewController lets an app hand Messages a finished link preview
// (LPLinkMetadata); with SwiftUI's ShareLink, Messages shows a bare
// "actualist.app" link with no card.

extension View {
    /// Presents the share sheet while `content` is non-nil. Opening it asks
    /// the sender's own waiting changes to upload, so the recipient's sync can
    /// find the transaction; sharing never waits for that upload.
    func transactionShareSheet(_ content: Binding<TransactionShareContent?>) -> some View {
        modifier(TransactionShareSheetModifier(content: content))
    }
}

/// Owns one row's share presentation, so a context-menu item can open the
/// sheet after the menu closes.
struct TransactionShareHost<Content: View>: View {
    let share: TransactionShareContent
    @ViewBuilder let content: (_ present: @escaping () -> Void) -> Content
    @State private var presented: TransactionShareContent?

    var body: some View {
        content { presented = share }
            .transactionShareSheet($presented)
    }
}

private struct TransactionShareSheetModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Binding var content: TransactionShareContent?

    func body(content view: Content) -> some View {
        view.sheet(item: $content) { share in
            TransactionActivitySheet(content: share)
                .presentationDetents([.medium, .large])
                .task { await appState.localFirstStore.retryPendingLocalMessageFlush() }
        }
    }
}

private struct TransactionActivitySheet: UIViewControllerRepresentable {
    let content: TransactionShareContent

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [TransactionLinkItemSource.make(content: content)],
            applicationActivities: nil
        )
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Hands the share sheet the link with its preview already built, so Messages
/// shows the card without fetching the page. Holds only finished values; the
/// metadata is built on the main actor before this object exists.
final class TransactionLinkItemSource: NSObject, UIActivityItemSource {
    let url: URL
    let metadata: LPLinkMetadata

    private init(url: URL, metadata: LPLinkMetadata) {
        self.url = url
        self.metadata = metadata
    }

    @MainActor
    static func make(content: TransactionShareContent) -> TransactionLinkItemSource {
        let url = content.url()
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = TransactionShareContent.previewTitle
        let renderer = ImageRenderer(content: TransactionShareCard(content: content))
        renderer.scale = 3
        if let image = renderer.uiImage {
            metadata.imageProvider = NSItemProvider(object: image)
            metadata.iconProvider = NSItemProvider(object: image)
        }
        return TransactionLinkItemSource(url: url, metadata: metadata)
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        metadata
    }
}
