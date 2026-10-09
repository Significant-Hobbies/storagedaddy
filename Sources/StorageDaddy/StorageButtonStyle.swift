import SwiftUI

struct StorageButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        DaddyControlStyle(prominent: prominent).makeBody(configuration: configuration)
    }
}
