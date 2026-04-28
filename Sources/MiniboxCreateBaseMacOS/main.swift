// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

//
// Sources/MiniboxCreateBaseMacOS/main.swift
// MiniboxSwift
//
// Version: 0.1.0
// Date: 2026-04-27
//

import Foundation
import Virtualization
import os

private let kVersion = "0.1.0"

private let kUsage = """
    minibox-create-base-macos: Creates a macOS base image from IPSW.
    Usage: minibox-create-base-macos --bundle-path=PATH
      --ipsw-path  Path to ipsw. Mandatory.
      --force             Force to overwrite existing files.
    """

private let kDefaultMiniboxDataDir = URL.applicationSupportDirectory.appending(
    path: "tokyo.kaito.MiniboxSwift.minibox", directoryHint: .isDirectory)

private func logStderr(
    level: OSLogType, _ message: String, fileHandle: FileHandle = FileHandle.standardError
) {
    let logMessage =
        switch level {
        case .debug: "DEBUG: \(message)\n"
        case .default: "\(message)\n"
        case .error: "ERROR: \(message)\n"
        case .fault: "FAULT: \(message)\n"
        case .info: "INFO: \(message)\n"
        default: "UNKNOWN: \(message)\n"
        }
    try? fileHandle.write(contentsOf: Data(logMessage.utf8))
}

private func parseArgs(_ args: ArraySlice<String>) -> ([String: String], [String]) {
    var opts: [String: String] = [:]
    var posArgs: [String] = []
    var tail = args

    while let arg = tail.popFirst() {
        if arg == "--" {
            posArgs.append(contentsOf: tail)
            break
        } else if let match = arg.wholeMatch(of: /(--[^=]+)=(.*)/) {
            opts[String(match.output.1)] = String(match.output.2)
        } else if arg.hasPrefix("--") {
            if let optarg = tail.first, !optarg.hasPrefix("--") {
                opts[arg] = optarg
                _ = tail.popFirst()
            } else {
                opts[arg] = "true"
            }
        } else {
            posArgs.append(arg)
        }
    }

    return (opts, posArgs)
}

let miniboxDataURL: URL
if let miniboxDataPath = ProcessInfo.processInfo.environment["MINIBOX_DATA_DIR"] {
    miniboxDataURL = URL(fileURLWithPath: miniboxDataPath, isDirectory: true)
} else {
    miniboxDataURL = kDefaultMiniboxDataDir
}

var (opts, posArgs) = parseArgs(CommandLine.arguments.dropFirst())

if opts.removeValue(forKey: "--help") == "true" {
    logStderr(level: .default, kUsage)
    exit(0)
} else if opts.removeValue(forKey: "--version") == "true" {
    print("miniboxCreateBaseMacOSVersion=\(kVersion)")
    exit(0)
}

logStderr(level: .info, "minibox-create-base-macos v\(kVersion)")
print(
    "event:startUp",
    "version:\(kVersion)",
    separator: "\t"
)

guard let ipswPath = opts.removeValue(forKey: "--ipsw-path") else {
    logStderr(level: .default, kUsage)
    exit(64)
}

if !FileManager.default.fileExists(atPath: ipswPath) {
    logStderr(level: .default, "--bundle-path does not exist: \(ipswPath)")
    logStderr(level: .default, kUsage)
    print("error:IPSWPathNotExistError")
    exit(1)
}

let ipswURL = URL(fileURLWithPath: ipswPath)

let force = opts.removeValue(forKey: "--force") != nil

if !opts.isEmpty {
    logStderr(level: .error, "Unrecognized options found.")
    logStderr(level: .default, kUsage)
    exit(64)
} else if !posArgs.isEmpty {
    logStderr(level: .error, "No positional argument is permitted.")
    logStderr(level: .default, kUsage)
    exit(64)
}

print(
    "event:argumentsParsed",
    "ipswURL:\(ipswURL.absoluteString)",
    "force:\(force)",
    separator: "\t",
)

enum MiniboxCreateBaseError: Error {
    case requirementsNotAvailableError
    case asifCreationError
}

struct MiniboxBundle {
    let hardwareModelURL: URL
    let machineIdentifierURL: URL
    let auxiliaryStorageURL: URL
    let storageURLs: [URL]
}

enum CreateVMConfigError: Error {
    case configurationRequirementsNotAvailableError
    case hardwareModelSaveError(any Error)
    case auxiliaryStorageCreateError(any Error)
    case machineIdentifierSaveError(any Error)
    case storageDeviceInitError(any Error)
    case validateError(any Error)
}

extension CreateVMConfigError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .configurationRequirementsNotAvailableError:
            "Failed to get configuration requirements."
        case .hardwareModelSaveError(let error):
            "Failed to save hardware model: \(error.localizedDescription)"
        case .auxiliaryStorageCreateError(let error):
            "Failed to create auxiliary storage: \(error.localizedDescription)"
        case .machineIdentifierSaveError(let error):
            "Failed to save machine identifier: \(error.localizedDescription)"
        case .storageDeviceInitError(let error):
            "Failed to initialize storage device: \(error.localizedDescription)"
        case .validateError(let error):
            "Failed to validate VM configuration: \(error.localizedDescription)"
        }
    }
}

private func createVMConfig(miniboxBundle: MiniboxBundle, restoreImage: VZMacOSRestoreImage)
    throws(CreateVMConfigError)
    -> VZVirtualMachineConfiguration
{
    let hardwareModelURL = miniboxBundle.hardwareModelURL
    let machineIdentifierURL = miniboxBundle.machineIdentifierURL
    let auxiliaryStorageURL = miniboxBundle.auxiliaryStorageURL
    let storageURLs = miniboxBundle.storageURLs

    guard let configRequrements = restoreImage.mostFeaturefulSupportedConfiguration else {
        throw CreateVMConfigError.configurationRequirementsNotAvailableError
    }

    let platform = VZMacPlatformConfiguration()

    let hardwareModel = configRequrements.hardwareModel
    do {
        try hardwareModel.dataRepresentation.write(to: hardwareModelURL, options: .atomic)
    } catch {
        throw CreateVMConfigError.hardwareModelSaveError(error)
    }
    platform.hardwareModel = hardwareModel

    do {
        platform.auxiliaryStorage = try VZMacAuxiliaryStorage(
            creatingStorageAt: auxiliaryStorageURL,
            hardwareModel: hardwareModel,
            options: []
        )
    } catch {
        throw CreateVMConfigError.auxiliaryStorageCreateError(error)
    }

    let machineIdentifier = VZMacMachineIdentifier()
    do {
        try machineIdentifier.dataRepresentation.write(
            to: machineIdentifierURL,
            options: .atomic
        )
    } catch {
        throw CreateVMConfigError.machineIdentifierSaveError(error)
    }
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

    do {
        config.storageDevices = try storageURLs.map {
            VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(
                    url: $0,
                    readOnly: false
                )
            )
        }
    } catch {
        throw CreateVMConfigError.storageDeviceInitError(error)
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

    do {
        try config.validate()
    } catch {
        throw CreateVMConfigError.validateError(error)
    }

    return config
}

enum CreateBlankASIFError: Error {
    case diskutilProcessRunError(any Error)
    case diskutilExitWithFailureError(Int32)
}

private func createBlankASIF(url: URL) throws(CreateBlankASIFError) {
    let process = Process()

    process.executableURL = URL(filePath: "/usr/sbin/diskutil")
    process.arguments = [
        "image",
        "create",
        "blank",
        "--format",
        "ASIF",
        "--size",
        "64GB",
        "--fs",
        "None",
        url.path(percentEncoded: false),
    ]

    do {
        try process.run()
    } catch {
        throw CreateBlankASIFError.diskutilProcessRunError(error)
    }

    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw CreateBlankASIFError.diskutilExitWithFailureError(process.terminationStatus)
    }
}

enum MiniboxExit: Error {
    case success
    case failure
    case failureWithError(any Error)
}

@MainActor
class InstallMacOS {
    private var vm: VZVirtualMachine?
    private var installer: VZMacOSInstaller?
    private var observation: NSKeyValueObservation?

    private let sigintSource = DispatchSource.makeSignalSource(
        signal: SIGINT,
        queue: .main
    )

    func run(restoreImage: VZMacOSRestoreImage) async -> Int32 {
        return await withCheckedContinuation { continuation in
            let majorVersion = restoreImage.operatingSystemVersion.majorVersion
            let minorVersion = restoreImage.operatingSystemVersion.majorVersion
            let patchVersion = restoreImage.operatingSystemVersion.majorVersion
            let buildVersion = restoreImage.buildVersion
            let baseImageName =
                "macOS_\(majorVersion).\(minorVersion).\(patchVersion)_\(buildVersion)"

            let baseImageURL = miniboxDataURL.appending(
                path: "BaseImages/\(baseImageName).miniboxvm", directoryHint: .isDirectory)

            if FileManager.default.fileExists(atPath: baseImageURL.path(percentEncoded: false)) {
                if force {
                    logStderr(
                        level: .info, "Removing a template named \(baseImageName) and keep going..."
                    )
                    do {
                        try FileManager.default.removeItem(at: baseImageURL)
                    } catch {
                        logStderr(level: .error, error.localizedDescription)
                        continuation.resume(returning: 1)
                        return
                    }
                } else {
                    logStderr(
                        level: .error,
                        "Base image named \(baseImageName) already exists! Try with --force to overwrite. Exiting..."
                    )
                    continuation.resume(returning: 1)
                    return
                }
            }

            do {
                try FileManager.default.createDirectory(
                    at: baseImageURL, withIntermediateDirectories: true)
            } catch {
                logStderr(level: .error, error.localizedDescription)
                continuation.resume(returning: 1)
            }

            let diskURL = baseImageURL.appendingPathComponent("Disk.asif")
            do {
                try createBlankASIF(url: diskURL)
            } catch {
                logStderr(level: .error, error.localizedDescription)
                continuation.resume(returning: 1)
            }

            let miniboxBundle = MiniboxBundle(
                hardwareModelURL: baseImageURL.appending(path: "HardwareModel"),
                machineIdentifierURL: baseImageURL.appending(path: "MachineIdentifier"),
                auxiliaryStorageURL: baseImageURL.appending(path: "AuxiliaryStorage"),
                storageURLs: [diskURL],
            )

            let config: VZVirtualMachineConfiguration
            do {
                config = try createVMConfig(
                    miniboxBundle: miniboxBundle, restoreImage: restoreImage)
            } catch {
                logStderr(level: .error, error.localizedDescription)
                continuation.resume(returning: 1)
                return
            }

            let vm = VZVirtualMachine(configuration: config)

            let installer = VZMacOSInstaller(
                virtualMachine: vm,
                restoringFromImageAt: ipswURL
            )

            let observation = installer.progress.observe(
                \.fractionCompleted
            ) { p, _ in
                print("progress=\(p.fractionCompleted)")
            }

            self.vm = vm
            self.installer = installer
            self.observation = observation

            sigintSource.setEventHandler {
                logStderr(level: .info, "Stopping the installation...")
                observation.invalidate()
                installer.progress.cancel()
                continuation.resume(returning: 1)
            }

            sigintSource.activate()
            signal(SIGINT, SIG_IGN)

            print("install=started")
            installer.install { result in
                switch result {
                case .success:
                    print("install=success")
                    continuation.resume(returning: 0)
                case .failure:
                    print("install=failed")
                    continuation.resume(returning: 1)
                }
            }
        }
    }
}

print(
    "event:RestoreImageLoading",
    "ipswURL:\(ipswURL.absoluteString)",
    separator: "\t",
)

let installMacOS = InstallMacOS()

let restoreImage: VZMacOSRestoreImage
do {
    restoreImage = try await VZMacOSRestoreImage.image(from: ipswURL)
} catch {
    logStderr(level: .error, error.localizedDescription)
    exit(1)
}

let exitCode = await installMacOS.run(restoreImage: restoreImage)
exit(exitCode)
