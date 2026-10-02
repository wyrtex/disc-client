import SwiftUI

/// Просмотр картинки/гиф: пинч-зум и перетаскивание. Масштаб и положение ЗАСТЫВАЮТ при отпускании
/// пальцев (не возвращаются в исходное). Когда не приближено — свайп вниз закрывает просмотр.
struct ImageViewer: View {
    let url: URL
    let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var pan: CGSize = .zero          // смещение при зуме (фиксируется)
    @State private var lastPan: CGSize = .zero
    @State private var dragDismiss: CGSize = .zero  // свайп на закрытие (когда не приближено)

    private static let maxScale: CGFloat = 5
    private static let minScale: CGFloat = 1

    private var zoomed: Bool { scale > 1.01 }

    private var progress: Double {
        guard !zoomed else { return 0 }
        return min(1, Double(abs(dragDismiss.height)) / 320)
    }

    private var appliedOffset: CGSize {
        zoomed ? pan : dragDismiss
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - progress * 0.95)
                .ignoresSafeArea()

            Group {
                if url.pathExtension.lowercased() == "gif" {
                    AnimatedGIF(url: url, fit: true)
                } else {
                    RemoteImage(url: url, contentMode: .fit) {
                        ProgressView().tint(.white)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(zoomed ? scale : scale * (1 - progress * 0.25))
            .offset(appliedOffset)
            .gesture(
                // Зум и перетаскивание одновременно. Оба фиксируют своё состояние в onEnded.
                magnify.simultaneously(with: drag)
            )
            .onTapGesture(count: 2) { toggleZoom() }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 14) {
                SaveMediaButton(url: url, isVideo: false)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding()
            .opacity(1 - progress * 3)
        }
    }

    private var magnify: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let next = lastScale * value
                scale = min(Self.maxScale, max(0.6, next))
            }
            .onEnded { _ in
                // Фиксируем масштаб. Если меньше 1 — мягко подтягиваем к 1 и сбрасываем смещение.
                if scale < Self.minScale {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        scale = 1; pan = .zero
                    }
                    lastScale = 1; lastPan = .zero
                } else {
                    lastScale = scale
                    lastPan = pan
                }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { v in
                if zoomed {
                    pan = CGSize(width: lastPan.width + v.translation.width,
                                 height: lastPan.height + v.translation.height)
                } else {
                    dragDismiss = v.translation
                }
            }
            .onEnded { v in
                if zoomed {
                    lastPan = pan   // застываем на месте
                } else if abs(v.translation.height) > 120 || abs(v.predictedEndTranslation.height) > 320 {
                    onClose()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragDismiss = .zero
                    }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if zoomed {
                scale = 1; pan = .zero
                lastScale = 1; lastPan = .zero
            } else {
                scale = 2.5
                lastScale = 2.5
            }
        }
    }
}
