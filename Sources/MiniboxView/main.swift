// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

//
// Sources/MiniboxView/main.swift
// MiniboxSwift
//
// Version: 0.1.0
// Date: 2026-04-27
//

import AppKit
import Foundation
import Virtualization
import Vision
import os

private let kVersion = "0.1.0"

private let kUsage = """
    minibox-view: Starts a new VM with a image bundle to view its contents.
    Usage: minibox view --bundle-path=PATH
      --bundle-path=PATH  Path to the image bundle. Mandatory.
      --cpu-count=3       vCPU count. Optional.
      --memory-mb=7168    Memory size in megabytes. Optional.
      --width=1024        Width pixels of the vm. Optional.
      --height=768        Height pixels of the vm. Optional.
      --dpi=72            DPI value of the vm. Optional.
    """

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

let (opts, _) = parseArgs(CommandLine.arguments.dropFirst())

if opts["--help"] == "true" {
    logStderr(level: .default, kUsage)
    exit(64)
} else if opts["--version"] == "true" {
    print("miniboxViewVersion=\(kVersion)")
    exit(64)
}

logStderr(level: .info, "minibox-view v\(kVersion)")
print(
    "event:startUp",
    "version:\(kVersion)",
    separator: "\t"
)

guard let bundlePath = opts["--bundle-path"] else {
    logStderr(level: .default, kUsage)
    exit(64)
}

if !FileManager.default.fileExists(atPath: bundlePath) {
    logStderr(level: .default, "--bundle-path does not exist: \(bundlePath)")
    logStderr(level: .default, kUsage)
    print("error:BundlePathNotExistError")
    exit(1)
}

let bundleURL = URL(fileURLWithPath: bundlePath)

guard let cpuCount = Int(opts["--cpu-count", default: "3"]), cpuCount > 0 else {
    logStderr(level: .error, "Invalid --cpu-count.")
    logStderr(level: .default, kUsage)
    exit(64)
}

guard let memoryMb = Int(opts["--memory-mb", default: "7168"]), memoryMb > 0 else {
    logStderr(level: .error, "Invalid --memory-mb.")
    logStderr(level: .default, kUsage)
    exit(64)
}

let memorySize = memoryMb * 1024 * 1024

guard let width = Int(opts["--width", default: "1024"]), width > 0 else {
    logStderr(level: .error, "Invalid --width.")
    logStderr(level: .default, kUsage)
    exit(64)
}

guard let height = Int(opts["--height", default: "768"]), height > 0 else {
    logStderr(level: .error, "Invalid --height.")
    logStderr(level: .default, kUsage)
    exit(64)
}

guard let dpi = Int(opts["--dpi", default: "72"]), dpi > 0 else {
    logStderr(level: .error, "Invalid --dpi.")
    logStderr(level: .default, kUsage)
    exit(64)
}

print(
    "event:argumentsParsed",
    "bundleURL:\(bundleURL.absoluteString)",
    "cpuCount:\(cpuCount)",
    "memorySize:\(memorySize)",
    "width:\(width)",
    "height:\(height)",
    "dpi:\(dpi)",
    separator: "\t",
)

struct MiniboxBundle {
    let hardwareModelURL: URL
    let machineIdentifierURL: URL
    let auxiliaryStorageURL: URL
    let storageURLs: [URL]
}

enum LoadVMConfigError: Error {
    case hardwareModelLoadError
    case machineIdentifierLoadError
}

func loadVMConfig(
    miniboxBundle: MiniboxBundle,
    macAddress: VZMACAddress,
    cpuCount: Int,
    memorySize: Int,
    width: Int,
    height: Int,
    dpi: Int,
)
    throws -> VZVirtualMachineConfiguration
{
    let hardwareModelURL = miniboxBundle.hardwareModelURL
    let machineIdentifierURL = miniboxBundle.machineIdentifierURL
    let auxiliaryStorageURL = miniboxBundle.auxiliaryStorageURL
    let storageURLs = miniboxBundle.storageURLs

    let platform = VZMacPlatformConfiguration()

    guard
        let hardwareModel = VZMacHardwareModel(
            dataRepresentation: try Data(contentsOf: hardwareModelURL))
    else {
        throw LoadVMConfigError.hardwareModelLoadError
    }
    platform.hardwareModel = hardwareModel

    guard
        let machineIdentifier = VZMacMachineIdentifier(
            dataRepresentation: try Data(contentsOf: machineIdentifierURL))
    else {
        throw LoadVMConfigError.machineIdentifierLoadError
    }
    platform.machineIdentifier = machineIdentifier

    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxiliaryStorageURL)

    let config = VZVirtualMachineConfiguration()
    config.bootLoader = VZMacOSBootLoader()
    config.cpuCount = cpuCount
    config.memorySize = UInt64(memorySize)
    config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    config.platform = platform

    let consoleConfig = VZVirtioConsoleDeviceConfiguration()
    let consolePort = VZVirtioConsolePortConfiguration()
    consolePort.isConsole = true
    consolePort.name = "virtio"
    consoleConfig.ports[0] = consolePort
    config.consoleDevices = [consoleConfig]

    let networkConfig = VZVirtioNetworkDeviceConfiguration()
    networkConfig.attachment = VZNATNetworkDeviceAttachment()
    networkConfig.macAddress = macAddress
    config.networkDevices = [networkConfig]

    config.storageDevices = try storageURLs.map {
        VZVirtioBlockDeviceConfiguration(
            attachment: try VZDiskImageStorageDeviceAttachment(url: $0, readOnly: false)
        )
    }

    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    let audioConfig = VZVirtioSoundDeviceConfiguration()
    let audioOutputConfig = VZVirtioSoundDeviceOutputStreamConfiguration()
    audioConfig.streams = [audioOutputConfig]
    config.audioDevices = [audioConfig]

    let graphicsConfig = VZMacGraphicsDeviceConfiguration()
    graphicsConfig.displays = [
        VZMacGraphicsDisplayConfiguration(
            widthInPixels: width,
            heightInPixels: height,
            pixelsPerInch: dpi,
        )
    ]
    config.graphicsDevices = [graphicsConfig]

    config.keyboards = [VZMacKeyboardConfiguration()]

    config.pointingDevices = [VZMacTrackpadConfiguration()]

    try config.validate()

    return config
}

class MiniboxViewVMDelegate: NSObject, VZVirtualMachineDelegate {
    var app: NSApplication?

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        if let app {
            DispatchQueue.main.async {
                app.terminate(nil)
            }
        }
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        didStopWithError error: any Error
    ) {
        if let app {
            DispatchQueue.main.async {
                app.presentError(error)
                app.terminate(nil)
            }
        }
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: any Error
    ) {

        if let app {
            DispatchQueue.main.async {
                app.presentError(error)
                app.terminate(nil)
            }
        }
    }
}

let miniboxBundle = MiniboxBundle(
    hardwareModelURL: bundleURL.appending(path: "HardwareModel"),
    machineIdentifierURL: bundleURL.appending(path: "MachineIdentifier"),
    auxiliaryStorageURL: bundleURL.appending(path: "AuxiliaryStorage"),
    storageURLs: [bundleURL.appending(path: "Disk.asif")],
)

let macAddress = VZMACAddress.randomLocallyAdministered()

let config: VZVirtualMachineConfiguration
do {
    config = try loadVMConfig(
        miniboxBundle: miniboxBundle,
        macAddress: macAddress,
        cpuCount: cpuCount,
        memorySize: memorySize,
        width: width,
        height: height,
        dpi: dpi,
    )
} catch {
    logStderr(level: .error, error.localizedDescription)
    exit(1)
}

let vm = VZVirtualMachine(configuration: config)
let vmDelegate = MiniboxViewVMDelegate()
vm.delegate = vmDelegate
vm.start { result in
    if case .failure(let error) = result {
        logStderr(level: .error, error.localizedDescription)
        DispatchQueue.main.async {
            NSApplication.shared.presentError(error)
            NSApplication.shared.terminate(nil)
        }
    }
}

class MinboxViewWindow: NSWindow, NSWindowDelegate {
    private let app: NSApplication
    private let vmView: VZVirtualMachineView

    init(app: NSApplication, vm: VZVirtualMachine, contentRect: NSRect) {
        self.app = app

        let vmView = VZVirtualMachineView()
        vmView.virtualMachine = vm
        self.vmView = vmView

        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        contentView = vmView
        delegate = self
        title = "MiniboxView"

        makeFirstResponder(vmView)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    func windowWillClose(_ notification: Notification) {
        if vm.canStop {
            vm.stop { error in
                DispatchQueue.main.async {
                    if let error {
                        logStderr(level: .error, error.localizedDescription)
                        self.app.presentError(error)
                    }
                    print("event:vmStop")
                    self.app.terminate(nil)
                }
            }
        } else {
            print("event:forceExit")
            app.terminate(nil)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let app: NSApplication
    let vm: VZVirtualMachine
    let width: Int
    let height: Int

    var window: NSWindow?

    init(app: NSApplication, vm: VZVirtualMachine, width: Int, height: Int) {
        self.app = app
        self.vm = vm
        self.width = width
        self.height = height
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = MinboxViewWindow(
            app: app,
            vm: vm,
            contentRect: NSRect(x: 0, y: 0, width: width, height: height)
        )
        window.makeKeyAndOrderFront(nil)
        window.center()
        app.activate(ignoringOtherApps: true)
        self.window = window
    }
}

if let consoleDevice = vm.consoleDevices[0] as? VZVirtioConsoleDevice,
    let consolePort = consoleDevice.ports[0]
{
    consolePort.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: FileHandle.standardInput,
        fileHandleForWriting: FileHandle.standardOutput,
    )
}

let app = NSApplication.shared
let appDelegate = AppDelegate(app: app, vm: vm, width: width, height: height)
app.setActivationPolicy(.regular)
app.delegate = appDelegate
vmDelegate.app = app
app.run()
