import SwiftUI

extension Binding {
    /// A Boolean binding that is true while the optional has a value; setting false clears it.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(
            get: { wrappedValue != nil },
            set: { if !$0 { wrappedValue = nil } }
        )
    }
}
