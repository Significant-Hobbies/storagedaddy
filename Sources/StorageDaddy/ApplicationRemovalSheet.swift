import SwiftUI
import DiskCore

struct InstalledApplicationRemovalReview: Identifiable {
    let id = UUID()
    let application: InstalledApplication
    let plan: ApplicationRemovalPlan
}

struct ApplicationRemovalSheet: View {
    @EnvironmentObject var m: ExplorerModel
    let review: InstalledApplicationRemovalReview
    @ObservedObject var applications: InstalledApplicationsModel
    let onRemoved: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                if let data = review.application.iconPNG, let icon = NSImage(data: data) {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 56, height: 56)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Remove \(review.application.name)?").font(.title2.weight(.semibold))
                    Text(StorageLabels.location(review.plan.url.path))
                        .font(.caption).foregroundStyle(Tints.secondaryText)
                        .lineLimit(2).truncationMode(.middle)
                }
            }
            Text("\(DiskFormat.bytes(review.plan.allocatedBytes)) app bundle")
                .font(.title3.weight(.medium)).foregroundStyle(Tints.mint)
            VStack(alignment: .leading, spacing: 12) {
                Label("Only this application moves to Trash.", systemImage: "app.badge")
                Label("Documents, preferences and support data stay on your Mac.", systemImage: "folder")
                if Bundle(url: review.application.url)?.bundleIdentifier == "com.google.Chrome" {
                    Text("Your Chrome profile, bookmarks, saved site data and sign-ins are stored outside the app bundle. Moving Chrome to Trash does not erase or reset them. Removing browser data separately can sign you out.")
                        .font(.callout).foregroundStyle(Tints.secondaryText)
                }
                Label("You can restore it from Trash in Finder.", systemImage: "arrow.uturn.backward")
            }.font(.callout)
            Text("Space is not freed until Trash is emptied. storagedaddy will not empty it.")
                .font(.caption).foregroundStyle(Tints.secondaryText)
            if let error = applications.removalError {
                Text(error).font(.callout).foregroundStyle(Tints.yellow)
            }
            HStack {
                if applications.movingApplication {
                    ProgressView().controlSize(.small)
                    Text("Verifying app…").font(.caption)
                }
                Spacer()
                Button("Cancel", action: applications.cancelRemoval)
                    .keyboardShortcut(.cancelAction).disabled(applications.movingApplication)
                Button("Move to Trash") {
                    guard !m.busy, !m.monitoring else { return }
                    applications.confirmRemoval(review, onRemoved: onRemoved)
                }
                    .buttonStyle(StorageButtonStyle(prominent: true))
                    .disabled(applications.movingApplication || applications.removalError != nil || m.busy || m.monitoring)
            }
        }
        .padding(28).frame(width: 520)
        .background(AppColors.canvas)
        .foregroundStyle(AppColors.ink)
        .buttonStyle(StorageButtonStyle())
        .interactiveDismissDisabled(applications.movingApplication)
    }
}
