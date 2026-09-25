import SwiftUI
import Photos
import UIKit

/// Сохранение фото, гифок и видео из чата в галерею.
enum MediaSaver {
    enum Failure: LocalizedError {
        case denied
        case download

        var errorDescription: String? {
            switch self {
            case .denied: return "Нет доступа к галерее. Разреши добавление фото в Настройки → DiscClient → Фото."
            case .download: return "Не удалось скачать файл."
            }
        }
    }

    /// Если сборка без ключа доступа к фото, вместо прямого сохранения открываем системное меню «Поделиться».
    static var canSaveToPhotos: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil
    }

    private static func authorize() async -> Bool {
        let s = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return s == .authorized || s == .limited
    }

    private static func temporaryFile(ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    @MainActor
    private static func share(_ file: URL) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        vc?.present(sheet, animated: true)
    }

    /// Картинка или гифка (гифка сохраняется анимированной, потому что берём исходные данные).
    static func saveImage(from url: URL) async throws {
        let (data, resp) = try await ImageLoader.shared.session.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.download
        }
        var ext = url.pathExtension.lowercased()
        if ext.isEmpty || ext.count > 5 { ext = "jpg" }
        if canSaveToPhotos {
            guard await authorize() else { throw Failure.denied }
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "discord." + ext
                req.addResource(with: .photo, data: data, options: options)
            }
        } else {
            let file = temporaryFile(ext: ext)
            try data.write(to: file)
            await MainActor.run { share(file) }
        }
    }

    /// Сохранить уже готовый локальный файл (запись стрима) в галерею.
    static func saveLocalVideo(_ file: URL) async throws {
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.download }
        if canSaveToPhotos {
            guard await authorize() else { throw Failure.denied }
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
            }
        } else {
            await MainActor.run { share(file) }
        }
    }

    static func saveVideo(from url: URL) async throws {
        let (tmp, resp) = try await ImageLoader.shared.session.download(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.download
        }
        var ext = url.pathExtension.lowercased()
        if ext.isEmpty || ext.count > 5 { ext = "mp4" }
        let file = temporaryFile(ext: ext)
        try FileManager.default.moveItem(at: tmp, to: file)
        if canSaveToPhotos {
            defer { try? FileManager.default.removeItem(at: file) }
            guard await authorize() else { throw Failure.denied }
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
            }
        } else {
            await MainActor.run { share(file) }
        }
    }
}

/// Кнопка «сохранить» рядом с кнопкой закрытия просмотрщика.
struct SaveMediaButton: View {
    let url: URL
    let isVideo: Bool

    private enum Phase { case idle, saving, done }
    @State private var phase: Phase = .idle
    @State private var errorText: String?

    var body: some View {
        Button {
            save()
        } label: {
            ZStack {
                switch phase {
                case .idle:
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.85))
                case .saving:
                    ProgressView()
                        .tint(.white)
                        .frame(width: 34, height: 34)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.green)
                }
            }
        }
        .disabled(phase == .saving)
        .alert("Не удалось сохранить", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func save() {
        phase = .saving
        Task {
            do {
                if isVideo {
                    try await MediaSaver.saveVideo(from: url)
                } else {
                    try await MediaSaver.saveImage(from: url)
                }
                phase = .done
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                phase = .idle
            } catch {
                phase = .idle
                errorText = error.localizedDescription
            }
        }
    }
}
