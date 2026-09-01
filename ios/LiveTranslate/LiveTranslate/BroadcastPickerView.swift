import ReplayKit
import SwiftUI

struct BroadcastPickerView: UIViewRepresentable {
    static let extensionBundleIdentifier = "com.xueqianzheng.LiveTranslate.BroadcastExtension"

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 52, height: 52)
        )
        picker.preferredExtension = Self.extensionBundleIdentifier
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
