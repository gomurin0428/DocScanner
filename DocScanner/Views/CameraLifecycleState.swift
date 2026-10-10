import UIKit

/// セッション開始要求の世代をスレッドセーフに管理する。
final class CameraLifecycleState: @unchecked Sendable {

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?

    /// 新しい開始世代を有効にする。
    func activate() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        activeGeneration = generation
        return generation
    }

    /// 進行中の開始世代を無効化する。
    func deactivate() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        activeGeneration = nil
    }

    /// 指定世代が現在も有効かを返す。
    func isActive(_ candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == candidate
    }

    /// 非同期権限応答後に開始処理を続けてよいかを返す。
    func canStart(_ candidate: UInt64, taskIsCancelled: Bool) -> Bool {
        !taskIsCancelled && isActive(candidate)
    }

    /// 現在有効な世代を返す。
    var currentGeneration: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration
    }
}

/// 手動撮影の UI 状態を保持する。
struct CameraPhotoState {
    private(set) var sources: [PageSource]
    var captures: [UIImage] { sources.map(\.image) }
    private(set) var isCapturing = false

    /// 初期撮影済み画像を設定する。
    init(captures: [UIImage] = []) {
        self.sources = captures.map { .camera($0, boundary: nil) }
    }

    /// Done を実行できる状態かを返す。
    var canFinish: Bool {
        !captures.isEmpty && !isCapturing
    }

    /// 1 件の撮影トランザクションを開始する。
    @discardableResult
    mutating func beginCapture() -> Bool {
        guard !isCapturing else { return false }
        isCapturing = true
        return true
    }

    /// 撮影トランザクションを完了し、必要なら画像を追加する。
    mutating func finishCapture(image: UIImage?, shouldAppend: Bool, boundary: DocumentBoundary? = nil,
                               camera: DocumentCamera? = nil) {
        guard isCapturing else { return }
        if shouldAppend, let image {
            sources.append(.camera(image, boundary: boundary, camera: camera))
        }
        isCapturing = false
    }
}
