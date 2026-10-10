import SwiftUI

/// `@State` is a macro in the macOS 27 SDK, and its plugin ships only with Xcode.
/// The property-wrapper type itself is still available, so the app uses it
/// through this alias to build with the Command Line Tools alone.
typealias ViewState<Value> = SwiftUI.State<Value>
