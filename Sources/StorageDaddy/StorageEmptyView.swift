import SwiftUI

struct StorageEmptyView: View {
    let title: String
    let systemImage: String
    var description: Text?
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.title = title; self.systemImage = systemImage; self.description = description
    }
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage).font(.system(size: 42, weight: .light)).foregroundStyle(Tints.mint)
            Text(title).font(.title2.weight(.semibold)).foregroundStyle(AppColors.ink)
            if let description { description.foregroundStyle(Tints.secondaryText).multilineTextAlignment(.center).frame(maxWidth: 420) }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(AppColors.canvas)
    }
}
