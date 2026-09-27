import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system folder picker (Files). Returns a security-scoped folder URL;
/// `FolderSyncController.useFolder(_:)` keeps a bookmark to it.
///
/// There is no way to open the picker at the iCloud Drive root without an
/// iCloud entitlement, so the surrounding UI tells people to pick iCloud
/// Drive first (`FolderPicker.tip`).
struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onCancel: () -> Void = {}

    static let tip = "Pick iCloud Drive, then create or choose a folder such as “Forumind”. Choose the same folder on each device."

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: FolderPicker

        init(parent: FolderPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { parent.onPick(url) } else { parent.onCancel() }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

extension View {
    /// Presents the folder picker and hands the folder to the sync engine.
    /// Errors from `useFolder` are shown in an alert.
    func syncFolderPicker(
        isPresented: Binding<Bool>,
        app: AppModel,
        onChosen: @escaping () -> Void = {}
    ) -> some View {
        modifier(SyncFolderPickerModifier(isPresented: isPresented, app: app, onChosen: onChosen))
    }
}

private struct SyncFolderPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let app: AppModel
    let onChosen: () -> Void
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                FolderPicker { url in
                    isPresented = false
                    do {
                        try app.folderSync.useFolder(url)
                        SyncPrompt.markHandled()
                        DCHaptics.success()
                        onChosen()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } onCancel: {
                    isPresented = false
                }
                .ignoresSafeArea()
            }
            .alert(
                "Couldn’t use this folder",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }
}
