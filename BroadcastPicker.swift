import SwiftUI
import ReplayKit
import AVFoundation

/// Кнопка запуска трансляции экрана.
///
/// Важный нюанс: на iOS 17+ системная кнопка внутри `RPSystemBroadcastPickerView` реагирует
/// только на НАСТОЯЩЕЕ касание пальцем — синтетический `sendActions(.touchUpInside)` игнорируется,
/// поэтому окно «Начать трансляцию» не появлялось и расширение не запускалось.
///
/// Решение: кладём настоящий `RPSystemBroadcastPickerView` поверх нашей кнопки (почти прозрачным),
/// чтобы палец пользователя попадал прямо в системную кнопку. Параллельно распознаватель касаний
/// (не отменяющий касание) готовит трансляцию — поднимает локальный сокет и шлёт op 18.
struct BroadcastStartButton: UIViewRepresentable {
    let voice: VoiceSpike
    let quality: BroadcastShared.Quality
    let streamAudio: Bool
    let blur: Bool
    let record: Bool
    let onTapped: () -> Void

    func makeUIView(context: Context) -> UIView {
        let container = TappableContainer()
        container.onPrepare = {
            voice.prepareBroadcast(quality: quality, streamAudio: streamAudio, blur: blur, record: record)
            voice.add("[видео/демо] Открываю системное окно трансляции (нажми «Начать трансляцию»)")
            onTapped()
        }

        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = "com.example.discclient.broadcast"
        picker.showsMicrophoneButton = false
        picker.translatesAutoresizingMaskIntoConstraints = false
        // Почти прозрачный, но живой и ПОВЕРХ всего — палец попадает в системную кнопку.
        picker.alpha = 0.02
        container.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: container.topAnchor),
            picker.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            picker.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        container.picker = picker
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class TappableContainer: UIView {
        weak var picker: RPSystemBroadcastPickerView?
        var onPrepare: (() -> Void)?
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
            // Распознаватель готовит трансляцию, но НЕ отменяет касание — оно доходит до
            // системной кнопки, и та показывает окно «Начать трансляцию».
            let tap = UITapGestureRecognizer(target: self, action: #selector(prepareTapped))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            addGestureRecognizer(tap)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func prepareTapped() { onPrepare?() }
    }
}
