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
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.preferredExtension = "com.example.discclient.broadcast"
        picker.showsMicrophoneButton = false
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.isHidden = true
        container.addSubview(picker)
        container.picker = picker
        container.onTap = {
            voice.prepareBroadcast(quality: quality, streamAudio: streamAudio, blur: blur, record: record)
            onTapped()
            container.triggerPicker()
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

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

        func triggerPicker() {
            guard let button = picker?.subviews.compactMap({ $0 as? UIButton }).first else { return }
            button.sendActions(for: .touchUpInside)
        }
    }
}
