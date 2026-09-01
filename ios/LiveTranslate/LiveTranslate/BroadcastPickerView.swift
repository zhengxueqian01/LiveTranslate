import ReplayKit
import SwiftUI

struct BroadcastPickerView: UIViewRepresentable {
    static let extensionBundleIdentifier = "com.xueqianzheng.LiveTranslate.BroadcastExtension"

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = Self.extensionBundleIdentifier
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
