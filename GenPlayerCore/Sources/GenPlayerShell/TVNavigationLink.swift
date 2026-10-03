import SwiftUI

#if os(tvOS)
/// A wrapper around NavigationLink that uses a Button to trigger the navigation.
/// This prevents the known tvOS 16/17 bug where applying a custom ButtonStyle 
/// to a NavigationLink causes it to swallow Select button clicks.
public struct TVNavigationLink<Destination: View, Label: View>: View {
    public let destination: Destination
    public let label: () -> Label
    @State private var isActive = false

    public init(destination: Destination, @ViewBuilder label: @escaping () -> Label) {
        self.destination = destination
        self.label = label
    }

    public var body: some View {
        Button(action: { isActive = true }) {
            label()
        }
        .background(
            NavigationLink(destination: destination, isActive: $isActive) {
                EmptyView()
            }
            .opacity(0)
            .accessibilityHidden(true)
        )
    }
}
#endif
