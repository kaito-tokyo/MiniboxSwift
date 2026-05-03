// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

//
// Sources/MiniboxToolsLinuxExec/main.swift
// MiniboxSwift
//
// Version: 0.1.0
// Date: 2026-05-01
//

import Foundation
import Virtualization
import os

private let kVersion = "0.1.0"
private let kUsage = """
    minibox-tools-linux-exec: Execute a command on a Linux VM in Minibox tools.
    Usage: minibox-tools-linux-exec --tool-name=NAME [options] -- [entrypoint args...]
      --tool-name=NAME         Name of Minibox tool to run. Mandatory.
      --shared=HOST_PATH       Host path of `shared` mount. Optional.
      --srv.NAME=HOST_PATH     Host path of subdirectory in `srv` mount. Optional.
      --entrypoint=GUEST_PATH  Guest executable path to run in the VM. Optional.
      --cpu-count=1            vCPU count. Optional.
      --memory-mb=256          Memory size in megabytes. Optional.
      --no-ip                  Disables guest network setup.
      [entrypoint args...]     Kernel parameter literals for entrypoint. Optional.
    Environment variables:
      MINIBOX_DATA_DIR  Path to the Minibox Data directory. Optional.
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

func parseArgsWithPassthrough(_ args: ArraySlice<String>) -> (
    opts: [String: String], flags: Set<String>, posArgs: [String], passthroughArgs: [String]
) {
    var opts: [String: String] = [:]
    var flags = Set<String>()
    var posArgs: [String] = []
    var tail = args

    while let arg = tail.popFirst() {
        if arg == "--" {
            return (opts, flags, posArgs, Array(tail))
        } else if let match = arg.wholeMatch(of: /(--[^=]+)=(.*)/) {
            opts[String(match.output.1)] = String(match.output.2)
        } else if arg.hasPrefix("--") {
            if tail.first?.hasPrefix("--") == false {
                opts[arg] = tail.popFirst()
            } else {
                flags.insert(arg)
            }
        } else {
            posArgs.append(arg)
        }
    }

    return (opts, flags, posArgs, [])
}

let miniboxDataURL: URL
if let miniboxDataPath = ProcessInfo.processInfo.environment["MINIBOX_DATA_DIR"] {
    miniboxDataURL = URL(filePath: miniboxDataPath, directoryHint: .isDirectory)
} else {
    miniboxDataURL = kDefaultMiniboxDataDir
}

var (opts, flags, posArgs, passthroughArgs) = parseArgsWithPassthrough(
    CommandLine.arguments.dropFirst())

if flags.remove("--version") != nil {
    print("minibox-tools-linux-exec \(kVersion)")
    exit(0)
} else if flags.remove("--help") != nil {
    print(kUsage)
    exit(0)
}

guard let toolName = opts.removeValue(forKey: "--tool-name") else {
    logStderr(level: .error, "--tool-name=NAME missing.")
    logStderr(level: .default, kUsage)
    exit(64)
}

guard toolName.wholeMatch(of: /[-a-zA-Z0-9_.]+/) != nil else {
    logStderr(level: .error, "Invalid --tool-name.")
    logStderr(level: .default, kUsage)
    exit(64)
}

let bundleURL: URL
let exactToolURL: URL = miniboxDataURL.appending(path: "Tools/\(toolName).miniboxvm")
let versionedToolURL: URL = miniboxDataURL.appending(
    path: "Tools/\(toolName)_\(kVersion).miniboxvm")
if FileManager.default.fileExists(atPath: exactToolURL.path(percentEncoded: false)) {
    bundleURL = exactToolURL
} else if FileManager.default.fileExists(atPath: versionedToolURL.path(percentEncoded: false)) {
    bundleURL = versionedToolURL
} else {
    logStderr(level: .error, "\(toolName) not found.")
    logStderr(level: .default, kUsage)
    exit(64)
}

let sharedURL: URL?
if let sharedPath = opts.removeValue(forKey: "--shared") {
    sharedURL = URL(filePath: sharedPath, directoryHint: .isDirectory)
} else {
    sharedURL = nil
}

let srvURLs: [String: URL]
do {
    var newSrvURLs: [String: URL] = [:]

    var removingKeys = Set<String>()

    for (opt, optarg) in opts {
        if let match = opt.wholeMatch(of: /--srv\.([a-zA-Z][a-zA-Z0-9_-]+)/) {
            let tag = String(match.output.1)
            newSrvURLs[tag] = URL(filePath: optarg, directoryHint: .isDirectory)
            removingKeys.insert(opt)
        }
    }

    for key in removingKeys {
        opts.removeValue(forKey: key)
    }

    srvURLs = newSrvURLs
}

let cpuCount: Int
if let cpuCountString = opts.removeValue(forKey: "--cpu-count") {
    guard let cpuCountValue = Int(cpuCountString), cpuCountValue > 0 else {
        logStderr(level: .error, "Invalid --cpu-count.")
        logStderr(level: .default, kUsage)
        exit(64)
    }
    cpuCount = cpuCountValue
} else {
    cpuCount = 1
}

let memoryMb: UInt64
if let memoryMbString = opts.removeValue(forKey: "--memory-mb") {
    guard let memoryMbValue = UInt64(memoryMbString), memoryMbValue > 0 else {
        logStderr(level: .error, "Invalid --memory-mb.")
        logStderr(level: .default, kUsage)
        exit(64)
    }
    memoryMb = memoryMbValue
} else {
    memoryMb = 256
}

let noIP = flags.remove("--no-ip") != nil

if !opts.isEmpty {
    logStderr(level: .error, "Unrecognized options found.")
    logStderr(level: .default, kUsage)
    exit(64)
} else if !posArgs.isEmpty {
    logStderr(level: .error, "No positional argument is permitted.")
    logStderr(level: .default, kUsage)
    exit(64)
}

struct MiniboxLinuxBundle {
    let machineIdentifierURL: URL
    let imageURL: URL
    let initramfsURL: URL
    let macAddressURL: URL
}

enum LoadAndSaveVMConfigError: Error, LocalizedError {
    case machineIdentifierDataLoadError(any Error)
    case machineIdentifierLoadError
    case machineIdentifierSaveError(any Error)
    case imageNotFoundError(URL)
    case initramfsNotFoundError(URL)
    case macAddressLoadError(any Error)
    case macAddressInitError
    case macAddressSaveError(any Error)

    var errorDescription: String? {
        switch self {
        case .machineIdentifierDataLoadError(let error):
            "Failed to load machine identifier data: \(error.localizedDescription)"
        case .machineIdentifierLoadError: "Failed to load machine identifier."
        case .machineIdentifierSaveError(let error):
            "Failed to save machine identifier: \(error.localizedDescription)"
        case .imageNotFoundError(let url):
            "Failed to find Image: \(url.absoluteString)"
        case .initramfsNotFoundError(let url):
            "Failed to find initramfs: \(url.absoluteString)"
        case .macAddressLoadError(let error):
            "Failed to load MAC address: \(error.localizedDescription)"
        case .macAddressInitError: "Failed to initialize MAC address"
        case .macAddressSaveError(let error):
            "Failed to save MAC address: \(error.localizedDescription)"
        }
    }
}

func loadAndSaveVMConfig(
    miniboxBundle: MiniboxLinuxBundle,
    commandLine: String,
    cpuCount: Int,
    memorySize: UInt64
)
    throws(LoadAndSaveVMConfigError) -> VZVirtualMachineConfiguration
{
    let machineIdentifierURL = miniboxBundle.machineIdentifierURL
    let imageURL = miniboxBundle.imageURL
    let initramfsURL = miniboxBundle.initramfsURL
    let macAddressURL = miniboxBundle.macAddressURL

    let platform = VZGenericPlatformConfiguration()

    let machineIdentifier: VZGenericMachineIdentifier
    if FileManager.default.fileExists(atPath: machineIdentifierURL.path(percentEncoded: false)) {
        let machineIdentifierData: Data
        do {
            machineIdentifierData = try Data(contentsOf: machineIdentifierURL)
        } catch {
            throw LoadAndSaveVMConfigError.machineIdentifierDataLoadError(error)
        }

        guard
            let machineIdentifierValue = VZGenericMachineIdentifier(
                dataRepresentation: machineIdentifierData)
        else {
            throw LoadAndSaveVMConfigError.machineIdentifierLoadError
        }
        machineIdentifier = machineIdentifierValue
    } else {
        machineIdentifier = VZGenericMachineIdentifier()
        do {
            try machineIdentifier.dataRepresentation.write(to: machineIdentifierURL)
        } catch {
            throw LoadAndSaveVMConfigError.machineIdentifierSaveError(error)
        }
    }
    platform.machineIdentifier = machineIdentifier

    guard FileManager.default.fileExists(atPath: imageURL.path(percentEncoded: false)) else {
        throw LoadAndSaveVMConfigError.imageNotFoundError(imageURL)
    }

    guard FileManager.default.fileExists(atPath: initramfsURL.path(percentEncoded: false)) else {
        throw LoadAndSaveVMConfigError.initramfsNotFoundError(initramfsURL)
    }

    let bootLoader = VZLinuxBootLoader(kernelURL: imageURL)
    bootLoader.initialRamdiskURL = initramfsURL
    bootLoader.commandLine = commandLine

    let config = VZVirtualMachineConfiguration()
    config.bootLoader = bootLoader
    config.cpuCount = cpuCount
    config.memorySize = memorySize
    config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    config.platform = platform

    let macAddress: VZMACAddress
    if FileManager.default.fileExists(atPath: macAddressURL.path(percentEncoded: false)) {
        let macAddressString: String
        do {
            macAddressString = try String(contentsOf: macAddressURL, encoding: .utf8)
        } catch {
            throw LoadAndSaveVMConfigError.macAddressLoadError(error)
        }

        guard let macAddressValue = VZMACAddress(string: macAddressString) else {
            throw LoadAndSaveVMConfigError.macAddressInitError
        }

        macAddress = macAddressValue
    } else {
        macAddress = .randomLocallyAdministered()

        do {
            try Data(macAddress.string.utf8).write(to: macAddressURL)
        } catch {
            throw LoadAndSaveVMConfigError.macAddressSaveError(error)
        }
    }

    let networkConfig = VZVirtioNetworkDeviceConfiguration()
    networkConfig.attachment = VZNATNetworkDeviceAttachment()
    networkConfig.macAddress = macAddress
    config.networkDevices = [networkConfig]

    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    return config
}

class MiniboxToolsLinuxExecMain: NSObject, VZVirtualMachineDelegate {
    enum MainError: Error, LocalizedError {
        case configValidationError(any Error)
        case consoleDeviceGetError
        case sharingDeviceGetError

        var errorDescription: String? {
            switch self {
            case .configValidationError(let error):
                "Failed to validate config: \(error)"
            case .consoleDeviceGetError:
                "Failed to get a console device."
            case .sharingDeviceGetError:
                "Failed to get a sharing device."
            }
        }
    }

    let consolePort: VZVirtioConsolePort
    let stderrPort: VZVirtioConsolePort
    let sharedDirectoryDevice: VZVirtioFileSystemDevice
    let srvDirectoryDevice: VZVirtioFileSystemDevice
    let exitLock = OSAllocatedUnfairLock<Int32>(initialState: -1)

    private let config: VZVirtualMachineConfiguration
    private let vm: VZVirtualMachine

    private let signalPipe = Pipe()
    private let didResume = OSAllocatedUnfairLock(initialState: false)

    init(config: VZVirtualMachineConfiguration) throws(MainError) {
        let consoleConfig = VZVirtioConsoleDeviceConfiguration()

        do {
            let consolePort = VZVirtioConsolePortConfiguration()
            consolePort.isConsole = true
            consoleConfig.ports[0] = consolePort
        }

        do {
            let stderrConsolePort = VZVirtioConsolePortConfiguration()
            stderrConsolePort.isConsole = false
            stderrConsolePort.name = "stderr"
            consoleConfig.ports[1] = stderrConsolePort
        }

        do {
            let signalConsolePort = VZVirtioConsolePortConfiguration()
            signalConsolePort.isConsole = false
            signalConsolePort.name = "signal"
            signalConsolePort.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: nil,
                fileHandleForWriting: signalPipe.fileHandleForWriting,
            )
            consoleConfig.ports[2] = signalConsolePort
        }

        config.consoleDevices = [consoleConfig]

        config.directorySharingDevices = [
            VZVirtioFileSystemDeviceConfiguration(tag: "shared"),
            VZVirtioFileSystemDeviceConfiguration(tag: "srv"),
        ]

        do {
            try config.validate()
        } catch {
            throw MainError.configValidationError(error)
        }

        self.config = config
        self.vm = VZVirtualMachine(configuration: config)

        guard
            let consoleDevice = vm.consoleDevices[0] as? VZVirtioConsoleDevice,
            let consolePort = consoleDevice.ports[0],
            let stderrPort = consoleDevice.ports[1]
        else {
            throw MainError.consoleDeviceGetError
        }

        self.consolePort = consolePort
        self.stderrPort = stderrPort

        guard
            let sharedDirectoryDevice = vm.directorySharingDevices[0] as? VZVirtioFileSystemDevice,
            sharedDirectoryDevice.tag == "shared",
            let srvDirectoryDevice = vm.directorySharingDevices[1] as? VZVirtioFileSystemDevice,
            srvDirectoryDevice.tag == "srv"
        else {
            throw MainError.sharingDeviceGetError
        }
        self.sharedDirectoryDevice = sharedDirectoryDevice
        self.srvDirectoryDevice = srvDirectoryDevice

        super.init()

        vm.delegate = self
    }

    func attachConsole(
        standardInput: FileHandle,
        standardOutput: FileHandle,
        standardError: FileHandle,
    ) {
        consolePort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: standardInput,
            fileHandleForWriting: standardOutput,
        )

        stderrPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: standardError,
        )
    }

    func start() {
        vm.start { result in
            if case .failure(let error) = result {
                logStderr(level: .error, error.localizedDescription)
                self.resume(returning: 1)
            }
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        let data = signalPipe.fileHandleForReading.availableData
        let string = String(data: data, encoding: .ascii)
        if let match = string?.firstMatch(of: /exit:([0-9]+)\n/) {
            self.resume(returning: Int32(match.output.1) ?? 1)
        } else {
            logStderr(level: .error, "Guest did not report a valid exit code.")
            self.resume(returning: 1)
        }
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        didStopWithError error: any Error
    ) {
        logStderr(level: .error, error.localizedDescription)
        self.resume(returning: 1)
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: any Error
    ) {
        logStderr(level: .error, error.localizedDescription)
        self.resume(returning: 1)
    }

    private func resume(returning value: Int32) {
        exitLock.withLock { $0 = value }
    }
}

let commandLineParameters: [String]
do {
    var newCommndLineParameters = [
        "console=hvc0",
        "quiet",
        "--",
        "--stderr=virtio=stderr",
        "--signal=virtio=signal",
    ]

    if sharedURL != nil {
        newCommndLineParameters.append("--shared")
    }

    if !srvURLs.isEmpty {
        newCommndLineParameters.append("--srv")
    }

    if noIP {
        newCommndLineParameters.append("--no-ip")
    }

    newCommndLineParameters += passthroughArgs

    commandLineParameters = newCommndLineParameters
}

let miniboxBundle = MiniboxLinuxBundle(
    machineIdentifierURL: bundleURL.appending(path: "MachineIdentifier"),
    imageURL: bundleURL.appending(path: "Image"),
    initramfsURL: bundleURL.appending(path: "initramfs.img"),
    macAddressURL: bundleURL.appending(path: "MACAddress")
)

let config: VZVirtualMachineConfiguration
do {
    config = try loadAndSaveVMConfig(
        miniboxBundle: miniboxBundle,
        commandLine: commandLineParameters.joined(separator: " "),
        cpuCount: cpuCount,
        memorySize: memoryMb * 1024 * 1024,
    )
} catch {
    logStderr(level: .error, error.localizedDescription)
    exit(1)
}

let main: MiniboxToolsLinuxExecMain
do {
    main = try MiniboxToolsLinuxExecMain(config: config)
} catch {
    logStderr(level: .error, error.localizedDescription)
    exit(1)
}

let inputPipe = Pipe()
var ctrlCCount = 0
var firstCtrlCAt = Date.distantPast

let ctrlcLock = OSAllocatedUnfairLock(initialState: 0)
let forceExitCount = 10

FileHandle.standardInput.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }

    try? inputPipe.fileHandleForWriting.write(contentsOf: data)

    let (count, containsCtrlc) = ctrlcLock.withLock {
        var count = $0
        var containsCtrlc = false
        for byte in data {
            if byte == 0x03 {
                count += 1
                containsCtrlc = true
            } else if byte == 0x1b {
                break
            } else if byte >= 0x20 && byte != 0x7f {
                count = 0
            }
        }
        $0 = count
        return (count, containsCtrlc)
    }

    if count >= forceExitCount {
        logStderr(level: .info, "Force-exiting VM...")
        DispatchQueue.main.async {
            main.exitLock.withLock { $0 = 130 }
        }
    } else if containsCtrlc && count >= 3 {
        logStderr(level: .info, "Ctrl-C \(forceExitCount - count) times to force-exit VM...")
    }
}

main.attachConsole(
    standardInput: inputPipe.fileHandleForReading,
    standardOutput: FileHandle.standardOutput,
    standardError: FileHandle.standardError,
)

if let sharedURL {
    main.sharedDirectoryDevice.share = VZSingleDirectoryShare(
        directory: VZSharedDirectory(url: sharedURL, readOnly: false)
    )
}

if !srvURLs.isEmpty {
    main.srvDirectoryDevice.share = VZMultipleDirectoryShare(
        directories: srvURLs.mapValues { VZSharedDirectory(url: $0, readOnly: false) }
    )
}

main.start()

let sigtermSource: DispatchSourceSignal?
var attributes = termios()
var origAttributes: termios?
if tcgetattr(FileHandle.standardInput.fileDescriptor, &attributes) == 0 {
    origAttributes = attributes

    attributes.c_iflag &= ~tcflag_t(ICRNL)
    attributes.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
    if tcsetattr(FileHandle.standardInput.fileDescriptor, TCSANOW, &attributes) == 0 {
        let newSigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        newSigtermSource.setEventHandler {
            newSigtermSource.cancel()
            main.exitLock.withLock({ $0 = 1 })
        }
        newSigtermSource.activate()
        signal(SIGTERM, SIG_IGN)
        sigtermSource = newSigtermSource
    } else {
        sigtermSource = nil
        origAttributes = nil
    }
} else {
    origAttributes = nil
}

while RunLoop.main.run(mode: .default, before: .distantFuture) {
    let exitCode = main.exitLock.withLock({ $0 })
    if exitCode >= 0 {
        if var origAttributes {
            tcsetattr(FileHandle.standardInput.fileDescriptor, TCSANOW, &origAttributes)
        }
        exit(exitCode)
    }
}
