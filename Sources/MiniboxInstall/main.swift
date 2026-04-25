// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

// minibox-install: Prepare your VM for minibox-run.

import ArgumentParser
import Foundation
import Virtualization
import os

public let kMiniboxSwiftBaseImageDirectoryPrefix = URL
    .applicationSupportDirectory
    .appending(
        path: "tokyo.kaito.MiniboxSwift/BaseImages",
        directoryHint: .isDirectory
    )

enum MiniboxInstallError: Error {
    case requirementsNotAvailableError
    case hardwareModelLoadError
    case machineIndentifierLoadError
    case invalidMACAddressError
    case runnerDirectoryAlreadyExistsError
    case runnerAlreadyStartedError
    case getIPAddressError
}

private func logStderr(_ level: OSLogType, _ message: String) {
    let prefix =
        switch level {
        case .debug: "DEBUG: "
        case .info: "INFO: "
        case .default: ""
        case .error: "ERROR: "
        case .fault: "FAULT: "
        default: "UNKNOWN: "
        }

    let logMessage = "\(prefix)\(message)\n"

    if let data = logMessage.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private func createAndSaveVMConfig(
    hardwareModelURL: URL,
    machineIdentifierURL: URL,
    auxiliaryStorageURL: URL,
    storageURLs: [URL],
    storageSizes: [Int],
    restoreImage: VZMacOSRestoreImage
)
    throws -> VZVirtualMachineConfiguration
{
    guard
        let configRequrements = restoreImage
            .mostFeaturefulSupportedConfiguration
    else {
        throw MiniboxInstallError.requirementsNotAvailableError
    }

    let platform = VZMacPlatformConfiguration()

    let hardwareModel = configRequrements.hardwareModel
    try hardwareModel.dataRepresentation.write(
        to: hardwareModelURL,
        options: .atomic
    )
    platform.hardwareModel = hardwareModel

    platform.auxiliaryStorage = try VZMacAuxiliaryStorage(
        creatingStorageAt: auxiliaryStorageURL,
        hardwareModel: hardwareModel,
        options: []
    )

    let machineIdentifier = VZMacMachineIdentifier()
    try machineIdentifier.dataRepresentation.write(
        to: machineIdentifierURL,
        options: .atomic
    )
    platform.machineIdentifier = machineIdentifier

    let config = VZVirtualMachineConfiguration()
    config.bootLoader = VZMacOSBootLoader()
    config.cpuCount = configRequrements.minimumSupportedCPUCount
    config.memorySize = configRequrements.minimumSupportedMemorySize
    config.memoryBalloonDevices = [
        VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
    ]
    config.platform = platform

    let networkConfig = VZVirtioNetworkDeviceConfiguration()
    networkConfig.attachment = VZNATNetworkDeviceAttachment()
    config.networkDevices = [networkConfig]

    for (storageURL, storageSize) in zip(storageURLs, storageSizes) {
        if storageURL.pathExtension == "asif" {
            let process = Process()

            process.executableURL = URL(filePath: "/usr/sbin/diskutil")
            process.arguments = [
                "image",
                "create",
                "blank",
                "--format",
                "ASIF",
                "--size",
                "\(storageSize)",
                "--fs",
                "None",
                storageURL.path(percentEncoded: false),
            ]

            try process.run()
            process.waitUntilExit()

            let storageAttachment = try VZDiskImageStorageDeviceAttachment(
                url: storageURL,
                readOnly: false
            )

            config.storageDevices.append(
                VZVirtioBlockDeviceConfiguration(attachment: storageAttachment)
            )
        } else {
            logStderr(
                .info,
                "Unsupported file type: \(storageURL.pathExtension)"
            )
        }
    }

    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    let audioConfig = VZVirtioSoundDeviceConfiguration()
    let audioOutputConfig = VZVirtioSoundDeviceOutputStreamConfiguration()
    audioConfig.streams = [audioOutputConfig]
    config.audioDevices = [audioConfig]

    let graphicsConfig = VZMacGraphicsDeviceConfiguration()
    graphicsConfig.displays = [
        VZMacGraphicsDisplayConfiguration(
            widthInPixels: 1920,
            heightInPixels: 1080,
            pixelsPerInch: 72
        )
    ]
    config.graphicsDevices = [graphicsConfig]

    config.keyboards = [VZMacKeyboardConfiguration()]

    config.pointingDevices = [VZMacTrackpadConfiguration()]

    try config.validate()

    return config
}

struct CreateBaseImage: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Creates base images."
    )

    @Option(help: "Path to ipsw.")
    var ipswPath: String

    @Option(help: "The storage size to be created in bytes.")
    var storageSize: Int = 256 * 1024 * 1024 * 1024

    @Flag
    var force = false

    @Flag
    var yes = false

    var fileManager: FileManager { .default }

    func validate() throws {
        if !fileManager.fileExists(atPath: ipswPath) {
            throw ValidationError("Bundle path does not exist: \(ipswPath)!")
        }
    }

    func run() throws {
        let ipswURL = URL(filePath: ipswPath)
        let baseImageName = ipswURL.deletingPathExtension().lastPathComponent
        let baseImageURL = kMiniboxSwiftBaseImageDirectoryPrefix.appending(
            path: baseImageName,
            directoryHint: .isDirectory
        )

        print("==> Installing a new template...")
        print("ipswPath=\(ipswURL.path(percentEncoded: false))")
        print("baseImageName=\(baseImageName)")
        print("baseImagePath=\(baseImageURL.path(percentEncoded: false))")

        if !yes {
            print("==> Are you sure to install? [Y/n] ", terminator: "")
            let answer = readLine(strippingNewline: true)
            if let answer, answer != "", !answer.starts(with: /[yY]/) {
                print("Aborting...")
                throw ExitCode.failure
            }
        }

        print("==> Installing \(baseImageName)...")

        if fileManager.fileExists(
            atPath: baseImageURL.path(percentEncoded: false)
        ) {
            if force {
                logStderr(
                    .info,
                    "Removing a template named \(baseImageName) and keep going..."
                )
                try fileManager.removeItem(at: baseImageURL)
            } else {
                logStderr(
                    .error,
                    "There is already a base image named \(baseImageName)! Exiting..."
                )
                throw ExitCode.failure
            }
        }

        try fileManager.createDirectory(
            at: baseImageURL,
            withIntermediateDirectories: true
        )

        let exitLock = OSAllocatedUnfairLock<(any Error)?>(initialState: nil)

        let sigintSource = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: .main
        )

        struct SendableWrapper<T>: @unchecked Sendable {
            let value: T
        }

        VZMacOSRestoreImage.load(from: ipswURL) { result in
            switch result {
            case .success(let restoreImage):
                let wrappedRestoreImage = SendableWrapper(value: restoreImage)
                DispatchQueue.main.async {
                    let restoreImage = wrappedRestoreImage.value
                    let config: VZVirtualMachineConfiguration
                    do {
                        config = try createAndSaveVMConfig(
                            hardwareModelURL: baseImageURL.appending(
                                path: "HardwareModel"
                            ),
                            machineIdentifierURL: baseImageURL.appending(
                                path: "MachineIdentifier"
                            ),
                            auxiliaryStorageURL: baseImageURL.appending(
                                path: "AuxiliaryStorage"
                            ),
                            storageURLs: [
                                baseImageURL.appending(path: "Disk.asif")
                            ],
                            storageSizes: [storageSize],
                            restoreImage: restoreImage
                        )
                    } catch {
                        logStderr(.error, error.localizedDescription)
                        exitLock.withLock { $0 = ExitCode.failure }
                        return
                    }

                    let runner = VZVirtualMachine(configuration: config)

                    let installer = VZMacOSInstaller(
                        virtualMachine: runner,
                        restoringFromImageAt: ipswURL
                    )

                    let observation = installer.progress.observe(
                        \.fractionCompleted
                    ) { p, _ in
                        print("progress=\(p.fractionCompleted)")
                    }

                    sigintSource.setEventHandler {
                        logStderr(.info, "Stopping the installation...")
                        observation.invalidate()
                        installer.progress.cancel()
                        exitLock.withLock { $0 = ExitCode.failure }
                    }

                    sigintSource.activate()

                    signal(SIGINT, SIG_IGN)

                    print("install=started")
                    installer.install { result in
                        switch result {
                        case .success:
                            print("install=success")
                            observation.invalidate()
                            exitLock.withLock { $0 = ExitCode.success }
                        case .failure(let error):
                            print("install=failed")
                            logStderr(.error, error.localizedDescription)
                            exitLock.withLock { $0 = ExitCode.failure }
                        }
                    }
                }
            case .failure(let error):
                logStderr(.error, error.localizedDescription)
            }
        }

        while RunLoop.main.run(mode: .default, before: .distantFuture) {
            if let error = exitLock.withLock({ $0 }) {
                throw error
            }
        }
    }
}

struct MiniboxInstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "minibox-install",
        abstract: "Install subsystem for MiniboxSwift",
        subcommands: [CreateBaseImage.self],
    )
}

MiniboxInstall.main()
