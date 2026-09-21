import SwiftUI

/// Просмотр картинки: тянешь вниз, фон темнеет/светлеет вместе с движением, отпускаешь, и она закрывается.
struct ImageViewer: View {
    let url: URL
    let onClose: () -> Void
    @State private var offset: CGSize = .zero

    private var progress: Double {
        min(1, Double(abs(offset.height)) / 320)
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
            .scaleEffect(1 - progress * 0.25)
            .offset(offset)
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
        .gesture(
            DragGesture()
                .onChanged { v in
                    offset = v.translation
                }
                .onEnded { v in
                    if abs(v.translation.height) > 120 || abs(v.predictedEndTranslation.height) > 320 {
                        onClose()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            offset = .zero
                        }
                    }
                }
        )
    }
}
