import SwiftUI

struct StorageEmptyView: View {
    let title: String
    let systemImage: String
    var description: Text?
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.title = title; self.systemImage = systemImage; self.description = description
    }
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .regular)).foregroundStyle(Tints.mint)
                .frame(width: 64, height: 64)
                .background(DaddyTheme.palette.brandSoft, in: RoundedRectangle(cornerRadius: 18))
            Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(AppColors.ink)
            if let description { description.font(.callout).foregroundStyle(Tints.secondaryText).multilineTextAlignment(.center).frame(maxWidth: 420) }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(AppColors.canvas)
    }
}
