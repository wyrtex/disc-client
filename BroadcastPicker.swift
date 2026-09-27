import SwiftUI
import ReplayKit
import AVFoundation

/// Кнопка, которая вызывает системное окно «Общий экран» (как в официальном клиенте).
/// Тап по нашей кнопке программно нажимает скрытую системную кнопку трансляции.
struct BroadcastStartButton: UIViewRepresentable {
    let voice: VoiceSpike
    let quality: BroadcastShared.Quality
    let streamAudio: Bool
    let blur: Bool
    let record: Bool
    let onTapped: () -> Void

    func makeUIView(context: Context) -> UIView {
        let container = TappableContainer()
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        // ESign при переподписи может менять bundle id расширения, поэтому находим его сами.
        let extID = Self.broadcastExtensionBundleID()
        picker.preferredExtension = extID ?? "com.example.discclient.broadcast"
        picker.showsMicrophoneButton = false
        picker.alpha = 0.02
        picker.translatesAutoresizingMaskIntoConstraints = false
        container.insertSubview(picker, at: 0)
        NSLayoutConstraint.activate([
            picker.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            picker.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            picker.widthAnchor.constraint(equalTo: container.widthAnchor),
            picker.heightAnchor.constraint(equalTo: container.heightAnchor)
        ])
        container.picker = picker
        container.onTap = {
            voice.add("[видео/демо] Расширение для трансляции: \(extID ?? "не найдено, дефолт com.example.discclient.broadcast")")
            voice.prepareBroadcast(quality: quality, streamAudio: streamAudio, blur: blur, record: record)
            onTapped()
            if !container.triggerPicker() {
                voice.add("[видео/демо] Не нашёл системную кнопку трансляции — окно «Начать трансляцию» не открылось")
            }
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    /// Находим bundle id встроенного broadcast-upload расширения.
    static func broadcastExtensionBundleID() -> String? {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(
                at: plugins, includingPropertiesForKeys: nil) else { return nil }
        for url in items where url.pathExtension == "appex" {
            guard let b = Bundle(url: url),
                  let ext = b.infoDictionary?["NSExtension"] as? [String: Any],
                  let point = ext["NSExtensionPointIdentifier"] as? String,
                  point == "com.apple.broadcast-services-upload" else { continue }
            return b.bundleIdentifier
        }
        return nil
    }

    final class TappableContainer: UIView {
        weak var picker: RPSystemBroadcastPickerView?
        var onTap: (() -> Void)?
        private let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = UIColor(red: 0.35, green: 0.40, blue: 0.95, alpha: 1)
            layer.cornerRadius = 12
            label.text = "Начать стрим"
            label.textColor = .white
            label.font = .systemFont(ofSize: 16, weight: .semibold)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                heightAnchor.constraint(equalToConstant: 52)
            ])
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func tap() { onTap?() }

        /// Ищем системную кнопку трансляции рекурсивно и жмём её.
        @discardableResult
        func triggerPicker() -> Bool {
            guard let picker = picker, let button = Self.findButton(in: picker) else { return false }
            button.sendActions(for: .touchUpInside)
            return true
        }

        private static func findButton(in view: UIView) -> UIButton? {
            if let b = view as? UIButton { return b }
            for sub in view.subviews {
                if let b = findButton(in: sub) { return b }
            }
            return nil
        }
    }
}
