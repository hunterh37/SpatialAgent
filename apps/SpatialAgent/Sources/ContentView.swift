import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("SpatialAgent")
                .font(.extraLargeTitle)
        }
        .padding(60)
        .glassBackgroundEffect()
    }
}

#Preview(windowStyle: .plain) {
    ContentView()
}
