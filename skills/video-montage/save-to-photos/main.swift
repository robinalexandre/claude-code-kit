import Foundation
import Photos

let files = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
guard !files.isEmpty else {
    fputs("usage: SaveToPhotos <file>...\n", stderr)
    exit(2)
}

guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
    fputs("Photos access (Add Photos Only) was not granted\n", stderr)
    exit(3)
}

do {
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
        PHPhotoLibrary.shared().performChanges({
            for file in files {
                let isVideo = ["mp4", "mov", "m4v"].contains(file.pathExtension.lowercased())
                PHAssetCreationRequest.forAsset().addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
            }
        }) { saved, error in
            if saved {
                done.resume()
            } else {
                done.resume(throwing: error ?? CocoaError(.fileWriteUnknown))
            }
        }
    }
    print("saved \(files.count)")
} catch {
    fputs("Photos import failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
