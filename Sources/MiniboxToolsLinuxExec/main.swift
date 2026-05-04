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

import Darwin
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
    exit(EX_OK)
} else if flags.remove("--help") != nil {
    print(kUsage)
    exit(EX_OK)
}

guard let toolName = opts.removeValue(forKey: "--tool-name") else {
    logStderr(level: .error, "--tool-name=NAME missing.")
    logStderr(level: .default, kUsage)
    exit(EX_NOINPUT)
}

guard toolName.wholeMatch(of: /[-a-zA-Z0-9_.]+/) != nil else {
    logStderr(level: .error, "Invalid --tool-name.")
    logStderr(level: .default, kUsage)
    exit(EX_USAGE)
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
    exit(EX_USAGE)
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
        exit(EX_USAGE)
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
        exit(EX_USAGE)
    }
    memoryMb = memoryMbValue
} else {
    memoryMb = 256
}

let noIP = flags.remove("--no-ip") != nil

if !opts.isEmpty {
    logStderr(level: .error, "Unrecognized options found.")
    logStderr(level: .default, kUsage)
    exit(EX_USAGE)
} else if !posArgs.isEmpty {
    logStderr(level: .error, "No positional argument is permitted.")
    logStderr(level: .default, kUsage)
    exit(EX_USAGE)
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

enum MiniboxToolsLinuxExecMainError: Error {
    case configValidationError(any Error)
    case consoleDeviceGetError
    case sharingDeviceGetError
    case vmStartFailureError(any Error)
    case vmStoppedWithError(any Error)

    var errorDescription: String? {
        switch self {
        case .configValidationError(let error):
            "Failed to validate config: \(error.localizedDescription)"
        case .consoleDeviceGetError: "Failed to get a console device."
        case .sharingDeviceGetError: "Failed to get a sharing device."
        case .vmStartFailureError(let error): "Failed to start a VM: \(error.localizedDescription)"
        case .vmStoppedWithError(let error): "VM stopeed with error: \(error.localizedDescription)"
        }
    }
}

enum MiniboxToolsLinuxExecExitEvent: Error {
    case guestDidStop
    case forceExit
    case sigterm
}

class MiniboxToolsLinuxExecMain: NSObject, VZVirtualMachineDelegate {
    let consolePort: VZVirtioConsolePort
    let stderrPort: VZVirtioConsolePort
    let sharedDirectoryDevice: VZVirtioFileSystemDevice
    let srvDirectoryDevice: VZVirtioFileSystemDevice

    private let exitToken: OSAllocatedUnfairLock<(any Error)?>
    private let config: VZVirtualMachineConfiguration
    private let vm: VZVirtualMachine

    private let signalPipe = Pipe()
    private let signalBuffer = OSAllocatedUnfairLock(initialState: Data())
    private let signalQueue = DispatchQueue(
        label: "tokyo.kaito.MiniboxSwift.MiniboxToolsLinuxExec.signal")

    init(
        exitToken: OSAllocatedUnfairLock<(any Error)?>,
        config: VZVirtualMachineConfiguration
    ) throws(MiniboxToolsLinuxExecMainError) {
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
            throw MiniboxToolsLinuxExecMainError.configValidationError(error)
        }

        self.exitToken = exitToken
        self.config = config
        self.vm = VZVirtualMachine(configuration: config)

        guard
            let consoleDevice = vm.consoleDevices[0] as? VZVirtioConsoleDevice,
            let consolePort = consoleDevice.ports[0],
            let stderrPort = consoleDevice.ports[1]
        else {
            throw MiniboxToolsLinuxExecMainError.consoleDeviceGetError
        }

        self.consolePort = consolePort
        self.stderrPort = stderrPort

        guard
            let sharedDirectoryDevice = vm.directorySharingDevices[0] as? VZVirtioFileSystemDevice,
            sharedDirectoryDevice.tag == "shared",
            let srvDirectoryDevice = vm.directorySharingDevices[1] as? VZVirtioFileSystemDevice,
            srvDirectoryDevice.tag == "srv"
        else {
            throw MiniboxToolsLinuxExecMainError.sharingDeviceGetError
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

    func start(signalHandler: @escaping @Sendable (String) -> Void) {
        let signalQueue = DispatchQueue(
            label: "tokyo.kaito.MiniboxSwift.MiniboxToolsLinuxExec.signal")
        let signalBuffer = self.signalBuffer

        signalPipe.fileHandleForReading.readabilityHandler = { handle in
            let receivedData = handle.availableData

            guard !receivedData.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            signalBuffer.withLock { data in
                data.append(receivedData)

                while let newlineIndex = data.firstIndex(of: 0x0a) {
                    let lineData = data[..<newlineIndex]
                    data.removeSubrange(...newlineIndex)

                    guard let line = String(data: lineData, encoding: .utf8) else {
                        logStderr(level: .error, "Invalid signal line received. Discarding...")
                        continue
                    }

                    signalQueue.async {
                        signalHandler(line)
                    }
                }

            }
        }

        let exitToken = self.exitToken
        vm.start { result in
            if case .failure(let error) = result {
                logStderr(level: .error, error.localizedDescription)
                exitToken.withLock {
                    $0 = MiniboxToolsLinuxExecMainError.vmStartFailureError(error)
                }
                CFRunLoopWakeUp(RunLoop.main.getCFRunLoop())
            }
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        exitToken.withLock { $0 = MiniboxToolsLinuxExecExitEvent.guestDidStop }
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        didStopWithError error: any Error
    ) {
        logStderr(level: .error, error.localizedDescription)
        exitToken.withLock { $0 = MiniboxToolsLinuxExecMainError.vmStoppedWithError(error) }
        CFRunLoopWakeUp(RunLoop.main.getCFRunLoop())
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: any Error
    ) {
        logStderr(level: .error, error.localizedDescription)
    }
}

extension LoadAndSaveVMConfigError {
    var exitCode: Int32 {
        switch self {
        case .machineIdentifierDataLoadError: EX_NOINPUT
        case .machineIdentifierLoadError: EX_CONFIG
        case .machineIdentifierSaveError: EX_CANTCREAT
        case .imageNotFoundError: EX_NOINPUT
        case .initramfsNotFoundError: EX_NOINPUT
        case .macAddressLoadError: EX_NOINPUT
        case .macAddressInitError: EX_CONFIG
        case .macAddressSaveError: EX_CANTCREAT
        }
    }
}

extension MiniboxToolsLinuxExecMainError {
    var exitCode: Int32 {
        switch self {
        case .configValidationError: EX_CONFIG
        case .consoleDeviceGetError: EX_OSERR
        case .sharingDeviceGetError: EX_OSERR
        case .vmStartFailureError: EX_SOFTWARE
        case .vmStoppedWithError: EX_SOFTWARE
        }
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
    exit(error.exitCode)
}

let exitToken = OSAllocatedUnfairLock<(any Error)?>(initialState: nil)

let main: MiniboxToolsLinuxExecMain
do {
    main = try MiniboxToolsLinuxExecMain(exitToken: exitToken, config: config)
} catch {
    logStderr(level: .error, error.localizedDescription)
    exit(error.exitCode)
}

let inputPipe = Pipe()
var ctrlCCount = 0
var firstCtrlCAt = Date.distantPast

let ctrlcLock = OSAllocatedUnfairLock(initialState: 0)
let forceExitCount = 10

FileHandle.standardInput.readabilityHandler = { handle in
    let data = handle.availableData

    guard !data.isEmpty else {
        handle.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        return
    }

    try? inputPipe.fileHandleForWriting.write(contentsOf: data)

    let (count, containsCtrlc) = ctrlcLock.withLock { count in
        var newCount = count
        var containsCtrlc = false
        for byte in data {
            if byte == 0x03 {
                newCount += 1
                containsCtrlc = true
            } else if byte == 0x1b {
                break
            } else if byte >= 0x20 && byte != 0x7f {
                newCount = 0
            }
        }
        count = newCount
        return (newCount, containsCtrlc)
    }

    if count >= forceExitCount {
        exitToken.withLock { $0 = MiniboxToolsLinuxExecExitEvent.forceExit }
        CFRunLoopWakeUp(RunLoop.main.getCFRunLoop())
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

let guestExitCodeLock = OSAllocatedUnfairLock<Int32?>(initialState: nil)

main.start { signalLine in
    if let match = signalLine.wholeMatch(of: /exit:([0-9]+)/),
        let exitCode = Int32(match.output.1)
    {
        guestExitCodeLock.withLock { $0 = exitCode }
        CFRunLoopWakeUp(RunLoop.main.getCFRunLoop())
    }
}

let sigtermSource: DispatchSourceSignal?
var attributes = termios()
let origAttributes: termios?
if tcgetattr(FileHandle.standardInput.fileDescriptor, &attributes) == 0 {
    let newOrigAttributes = attributes

    attributes.c_iflag &= ~tcflag_t(ICRNL)
    attributes.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
    if tcsetattr(FileHandle.standardInput.fileDescriptor, TCSANOW, &attributes) == 0 {
        let newSigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        newSigtermSource.setEventHandler {
            newSigtermSource.cancel()
            exitToken.withLock { $0 = MiniboxToolsLinuxExecExitEvent.sigterm }
            CFRunLoopWakeUp(RunLoop.main.getCFRunLoop())
        }
        newSigtermSource.activate()
        signal(SIGTERM, SIG_IGN)
        sigtermSource = newSigtermSource
        origAttributes = newOrigAttributes
    } else {
        sigtermSource = nil
        origAttributes = nil
    }
} else {
    origAttributes = nil
}

while RunLoop.main.run(mode: .default, before: .distantFuture) {
    let guestDidStop = exitToken.withLock { (token: inout (any Error)?) in
        guard let error = token else { return false }

        let exitCode: Int32
        switch error {
        case MiniboxToolsLinuxExecExitEvent.guestDidStop:
            return true
        case MiniboxToolsLinuxExecExitEvent.forceExit:
            logStderr(level: .info, "Force-exiting VM...")
            exitCode = 128 + SIGINT
        case MiniboxToolsLinuxExecExitEvent.sigterm:
            logStderr(level: .info, "Receiving SIGTERM. Exiting VM...")
            exitCode = 128 + SIGTERM
        case let error as LoadAndSaveVMConfigError:
            logStderr(level: .error, error.localizedDescription)
            exitCode = error.exitCode
        case let error as MiniboxToolsLinuxExecMainError:
            logStderr(level: .error, error.localizedDescription)
            exitCode = error.exitCode
        default:
            logStderr(level: .error, "Unhandled error: \(error.localizedDescription)")
            exitCode = EX_SOFTWARE
        }

        if var origAttributes {
            tcsetattr(FileHandle.standardInput.fileDescriptor, TCSANOW, &origAttributes)
        }
        exit(exitCode)
    }

    if guestDidStop {
        for _ in 0..<1000 {
            guestExitCodeLock.withLockIfAvailableUnchecked {
                if let exitCode = $0 {
                    if var origAttributes {
                        tcsetattr(FileHandle.standardInput.fileDescriptor, TCSANOW, &origAttributes)
                    }
                    exit(exitCode)
                }
            }
            sched_yield()
        }

        logStderr(level: .error, "Guest did not report exit code. Exiting with failure...")
        if var origAttributes {
            tcsetattr(FileHandle.standardInput.fileDescriptor, TCSANOW, &origAttributes)
        }
        exit(EX_SOFTWARE)
    }
}

if var origAttributes {
    tcsetattr(FileHandle.standardInput.fileDescriptor, TCSANOW, &origAttributes)
}
fatalError("Unexpected RunLoop exit.")
