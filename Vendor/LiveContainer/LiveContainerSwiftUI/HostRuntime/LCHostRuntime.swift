//
//  LCHostRuntime.swift
//  LiveContainerSwiftUI
//
//  Public entry points for a host app (Hermex) that embeds LiveContainer's
//  frameworks but keeps its own main() and UI. Guests always run in the
//  LiveProcess extension, so the host process never loads guest code.
//

import UIKit

public struct LCHostApp: Identifiable, Hashable, Sendable {
    public var id: String { relativeBundlePath }
    public let bundleIdentifier: String
    public let displayName: String
    public let version: String
    public let relativeBundlePath: String

    public init(bundleIdentifier: String, displayName: String, version: String, relativeBundlePath: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.version = version
        self.relativeBundlePath = relativeBundlePath
    }
}

public struct LCHostError: LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

@MainActor
public enum LCHostRuntime {
    /// Call once at launch, before any other LCHostRuntime call.
    public static func bootstrap() {
        LCHostInitialize()
        let fm = FileManager.default
        for url in [LCPath.bundlePath, LCPath.dataPath, LCPath.tweakPath] {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    public static func installedApps() -> [LCHostApp] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: LCPath.bundlePath.path)) ?? []
        return names.filter { $0.hasSuffix(".app") }.sorted().compactMap { name in
            guard let info = LCAppInfo(bundlePath: LCPath.bundlePath.appendingPathComponent(name).path) else {
                return nil
            }
            info.relativeBundlePath = name
            return hostApp(info)
        }
    }

    /// Installs an .ipa into the container. Installing a bundle ID that is
    /// already present replaces the app and keeps its data container.
    public static func installIPA(at ipaURL: URL) async throws -> LCHostApp {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("LCHostInstall-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let ipaPath = ipaURL.path
        let workPath = workDir.path
        let status = await Task.detached {
            extract(ipaPath, workPath, Progress.discreteProgress(totalUnitCount: 100))
        }.value
        guard status == 0 else {
            throw LCHostError(message: "The file is not a valid IPA.")
        }

        let payload = workDir.appendingPathComponent("Payload")
        guard let bundleName = try fm.contentsOfDirectory(atPath: payload.path).first(where: { $0.hasSuffix(".app") }),
              let newInfo = LCAppInfo(bundlePath: payload.appendingPathComponent(bundleName).path),
              let bundleIdentifier = newInfo.bundleIdentifier() else {
            throw LCHostError(message: "The IPA has no readable app bundle.")
        }

        let relativePath = "\(bundleIdentifier.sanitizeNonACSII()).app"
        let destination = LCPath.bundlePath.appendingPathComponent(relativePath)
        var previous: LCAppInfo?
        if fm.fileExists(atPath: destination.path) {
            previous = LCAppInfo(bundlePath: destination.path)
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: payload.appendingPathComponent(bundleName), to: destination)

        guard let info = LCAppInfo(bundlePath: destination.path) else {
            throw LCHostError(message: "The installed app could not be read.")
        }
        info.relativeBundlePath = relativePath
        if let previous {
            info.dataUUID = previous.dataUUID
            info.containerInfo = previous.containerInfo
        }

        let signError: String? = await withCheckedContinuation { continuation in
            info.patchExecAndSignIfNeed(completionHandler: { success, error in
                continuation.resume(returning: success ? nil : (error ?? "Signing failed."))
            }, progressHandler: { _ in }, forceSign: false)
        }
        if let signError {
            throw LCHostError(message: signError)
        }
        return hostApp(info)
    }

    public static func removeApp(_ app: LCHostApp) throws {
        let fm = FileManager.default
        let bundleURL = LCPath.bundlePath.appendingPathComponent(app.relativeBundlePath)
        if let info = LCAppInfo(bundlePath: bundleURL.path) {
            for container in info.containers {
                try? fm.removeItem(at: LCPath.dataPath.appendingPathComponent(container.folderName))
            }
        }
        try fm.removeItem(at: bundleURL)
    }

    /// A view controller that launches the app in LiveProcess and renders it
    /// edge to edge. Dismissing it terminates the app.
    public static func makeAppViewController(
        for app: LCHostApp,
        onExit: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) throws -> UIViewController {
        let bundleURL = LCPath.bundlePath.appendingPathComponent(app.relativeBundlePath)
        guard let info = LCAppInfo(bundlePath: bundleURL.path) else {
            throw LCHostError(message: "\(app.displayName) is not installed.")
        }
        info.relativeBundlePath = app.relativeBundlePath
        guard #available(iOS 16.0, *) else {
            throw LCHostError(message: "Running apps needs iOS 16 or later.")
        }
        let dataUUID = ensureContainer(info)
        return LCHostAppViewController(
            relativeBundlePath: app.relativeBundlePath,
            dataUUID: dataUUID,
            onExit: onExit,
            onError: onError
        )
    }

    private static func ensureContainer(_ info: LCAppInfo) -> String {
        if let existing = info.containers.first {
            return existing.folderName
        }
        let folderName = UUID().uuidString
        let container = LCContainer(folderName: folderName, name: folderName, isShared: false)
        container.makeLCContainerInfoPlist(
            appIdentifier: info.bundleIdentifier() ?? folderName,
            keychainGroupId: Int.random(in: 0..<SharedModel.keychainAccessGroupCount)
        )
        info.containers = [container]
        info.dataUUID = folderName
        return folderName
    }

    private static func hostApp(_ info: LCAppInfo) -> LCHostApp {
        LCHostApp(
            bundleIdentifier: info.bundleIdentifier() ?? "",
            displayName: info.displayName() ?? info.relativeBundlePath,
            version: info.version() ?? "",
            relativeBundlePath: info.relativeBundlePath
        )
    }
}

@available(iOS 16.0, *)
private final class LCHostAppViewController: UIViewController, AppSceneViewControllerDelegate {
    private let relativeBundlePath: String
    private let dataUUID: String
    private let onExit: @MainActor () -> Void
    private let onError: @MainActor (Error) -> Void
    private var sceneController: AppSceneViewController?

    init(relativeBundlePath: String, dataUUID: String, onExit: @escaping @MainActor () -> Void, onError: @escaping @MainActor (Error) -> Void) {
        self.relativeBundlePath = relativeBundlePath
        self.dataUUID = dataUUID
        self.onExit = onExit
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let scene = AppSceneViewController(bundleId: relativeBundlePath, dataUUID: dataUUID, delegate: self) else {
            return
        }
        sceneController = scene
        addChild(scene)
        scene.view.frame = view.bounds
        scene.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scene.view)
        scene.didMove(toParent: self)
    }

    // The host usually dismisses a container above this one (a SwiftUI
    // cover, a navigation pop), so check every ancestor before terminating.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        var controller: UIViewController? = self
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent {
                sceneController?.terminate()
                return
            }
            controller = current.parent
        }
    }

    func appSceneVCAppDidExit(_ vc: AppSceneViewController!) {
        DispatchQueue.main.async { self.onExit() }
    }

    func appSceneVC(_ vc: AppSceneViewController!, didInitializeWithError error: (any Error)!) {
        guard let error else { return }
        DispatchQueue.main.async { self.onError(error) }
    }
}
