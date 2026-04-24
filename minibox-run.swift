// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

// minibox-run: Minimum macOS runner based on Virtualization.framework

import Foundation
import Virtualization

struct FileHandleTextOutputStream: TextOutputStream {
  let handle: FileHandle
  func write(_ string: String) {
    guard let data = string.data(using: .utf8) else { return }
    try? handle.write(contentsOf: data)
  }
}

var stderr = FileHandleTextOutputStream(handle: .standardError)

func printUsage() {
  var stderr = FileHandleTextOutputStream(handle: .standardError)
  print(
    "Usage: minibox-run --bundle-path=PATH --cpu-count=COUNT --memory-size=BYTES d--runner-name=NAME",
    "  --bundle-path: Path to template vm bundle. Mandatory.",
    "  --cpu-count: Number of CPU assigned to the runner. Mandatory.",
    "  --memory-size: Memory size in bytes assigned to the runner. Mandatory.",
    "  --runner-name: Unique name for the runner to manage its instance. mandatory.",
    "  --help: Print this help.",
    "  --version: Print version.",
    separator: "\n",
    to: &stderr
  )
}

class ExitToken {
  var exitCode: Int32 = 0
  var isExiting: Bool = false

  func exit(_ code: Int32) {
    exitCode = code
    isExiting = true
  }
}

struct TemplateBundle {
  let url: URL
  var hardwareModelURL: URL { url.appending(components: "HardwareModel") }
  var machineIdentifierURL: URL { url.appending(components: "MachineIdentifier") }
  var auxiliaryStorageURL: URL { url.appending(components: "AuxiliaryStorage") }
  var diskURL: URL { url.appending(components: "Disk.asif") }
}

class RunnerDirectory {
  static var fileManager = FileManager.default

  let url: URL

  let fileManager = RunnerDirectory.fileManager
  var isDirty: Bool = false

  var hardwareModelURL: URL { url.appending(components: "HardwareModel") }
  var machineIdentifierURL: URL { url.appending(components: "MachineIdentifier") }
  var auxiliaryStorageURL: URL { url.appending(components: "AuxiliaryStorage") }
  var diskURL: URL { url.appending(components: "Disk.asif") }

  init(templateBundle: TemplateBundle, toURL: URL) throws {
    self.exitToken = exitToken

    let bundleHardwareModelURL = bundleURL.appending(components: "HardwareModel")
    let bundleMachineIdentifierURL = bundleURL.appending(components: "MachineIdentifier")
    let bundleAuxiliaryStorageURL = bundleURL.appending(components: "AuxiliaryStorage")
    let bundleDiskURL = bundleURL.appending(components: "Disk.asif")

    url = toURL

    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    try fileManager.copyItem(at: templateBundle.hardwareModelURL, to: hardwareModelURL)
    try fileManager.copyItem(at: templateBundle.machineIdentifierURL, to: machineIdentifierURL)
    try fileManager.copyItem(at: templateBundle.auxiliaryStorageURL, to: auxiliaryStorageURL)
    try fileManager.copyItem(at: templateBundle.diskURL, to: diskURL)
  }

  func loadConfig(macAddress: VZMACAddress) -> VZVirtualMachineConfiguration {
    var stderr = FileHandleTextOutputStream(handle: .standardError)

    let platform = VZMacPlatformConfiguration()

    guard
      let hardwareModelData = try? Data(contentsOf: hardwareModelURL),
      let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData)
    else {
      print("error(HardwareModelLoadError)=\(hardwareModelURL.path(percentEncoded: false))")
      print("ERROR: HardwareModel cannot be loaded!", to: &stderr)
      exitToken.exit(1)
      return
    }
    platform.hardwareModel = hardwareModel

    guard
      let machinesIdentifierData = try? Data(contentsOf: machineIdentifierURL),
      let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machinesIdentifierData)
    else {
      print(
        "error(MachineIdentifierLoadError)=\(machineIdentifierURL.path(percentEncoded: false))")
      print("ERROR: MachineIdentifier cannot be loaded!", to: &stderr)
      exitToken.exit(1)
      return
    }
    platform.machineIdentifier = machineIdentifier

    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxiliaryStorageURL)

    let config = VZVirtualMachineConfiguration()
    config.bootLoader = VZMacOSBootLoader()
    config.cpuCount = cpuCount
    config.memorySize = UInt64(memorySize)
    config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    config.platform = platform

    let networkConfig = VZVirtioNetworkDeviceConfiguration()
    networkConfig.attachment = VZNATNetworkDeviceAttachment()
    networkConfig.macAddress = macAddress
    config.networkDevices = [networkConfig]

    let storageAttachment = try! VZDiskImageStorageDeviceAttachment(
      url: runnerDiskURL, readOnly: false)
    let storageConfig = VZVirtioBlockDeviceConfiguration(attachment: storageAttachment)
    config.storageDevices = [storageConfig]

    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    let audioConfig = VZVirtioSoundDeviceConfiguration()
    let audioOutputConfig = VZVirtioSoundDeviceOutputStreamConfiguration()
    audioConfig.streams = [audioOutputConfig]
    config.audioDevices = [audioConfig]

    config.directorySharingDevices = []

    let graphicsConfig = VZMacGraphicsDeviceConfiguration()
    graphicsConfig.displays = [
      VZMacGraphicsDisplayConfiguration(
        widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 72)
    ]
    config.graphicsDevices = [graphicsConfig]

    config.keyboards = [VZMacKeyboardConfiguration()]

    config.pointingDevices = [VZMacTrackpadConfiguration()]

    do {
      try config.validate()
    } catch {
      print(error.localizedDescription)
      exitCode = 1
    }
  }

  func markDirty() {
    isDirty = true
  }

  deinit {
    var stderr = FileHandleTextOutputStream(handle: .standardError)

    if isDirty {
      let formatter = ISO8602DateFormatter()
      let backupRunnerPath = "\(runnerPath)_\(formatter.string(from: Date()))"

      print("backup=\(backupRunnerPath)")
      print("Backing up the runner directory due to failure...", to: &stderr)
      fileManager.moveItem(atPath: runnerPath, toPath: bakRunnerPath)
    } else {
      print("cleanup=\(runnerURL.path(percentEncoded: false))")
      print("Cleaning up the runner directory...", to: &stderr)
      try? fileManager.removeItem(at: runnerURL)
    }
  }
}

class RunnerDelegate: NSObject, VZVirtualMachineDelegate {
  let runnerDirectory: RunnerDirectory
  var exitToken: ExitToken

  static let fileManager: FileManager = FileManager.default

  init(runnerDirectory: RunnerDirectory, exitToken: ExitToken) {
    self.runnerDirectory = runnerDirectory
    self.exitToken = exitToken
  }

  func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    print("gracefulStop=true")
    exitToken.exit(0)
  }

  func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
    var stderr = FileHandleTextOutputStream(handle: .standardError)
    print("gracefulStop=false")
    print(error.localizedDescription, to: &stderr)
    exitToken.exit(1)
  }

  func virtualMachine(
    _ virtualMachine: VZVirtualMachine,
    networkDevice: VZNetworkDevice,
    attachmentWasDisconnectedWithError error: any Error
  ) {
    var stderr = FileHandleTextOutputStream(handle: .standardError)

    print("gracefulStop=false")
    print(error.localizedDescription, to: &stderr)
    exitToken.exit(1)
  }
}

var options: [String: String] = [:]

for arg in CommandLine.arguments.dropFirst() {
  let parts = arg.split(separator: "=", maxSplits: 1)
  let key = String(parts[0])
  options[key] = parts.count == 2 ? String(parts[1]) : "true"
}

if options["--help"] != nil {
  printUsage()
  exit(64)
}

guard
  let runnerName = options["--runner-name"],
  let bundlePath = options["--bundle-path"]
else {
  print("ERROR: --runner-name or --bundle-path is missing.", to: &stderr)
  printUsage()
  exit(64)
}

guard let cpuCountString = options["--cpu-count"], let cpuCount = Int(cpuCountString) else {
  print("ERROR: Malformed value for --cpu-count.", to: &stderr)
  printUsage()
  exit(64)
}

guard let memorySizeString = options["--memory-size"], let memorySize = Int(memorySizeString) else {
  print("ERROR: Malformed value for --memory-size.", to: &stderr)
  printUsage()
  exit(64)
}

let macAddress: VZMACAddress
if let macAddressString = options["--mac-address"], macAddressString != "" {
  guard let macAddressValue = VZMACAddress(string: macAddressString) else {
    print("ERROR: Malformed value for --mac-address.", to: &stderr)
    printUsage()
    exit(64)
  }
  macAddress = macAddressValue
} else {
  macAddress = .randomLocallyAdministered()
}

print("runnerName=\(runnerName)")
print("bundlePath=\(bundlePath)")
print("cpuCount=\(cpuCount)")
print("memorySize=\(memorySize)")
print("macAddress=\(macAddress)")

let runnerDirectoryPath = "runners/\(runnerName)"

if FileManager.default.fileExists(atPath: runnerDirectoryPath) {
  print("error(RunnerDirectoryAlreadyExistsError)=\(runnerDirectoryPath)")
  print("ERROR: Old runner directory remains. Exiting...", to: &stderr)
  exit(1)
}

let bundleURL = URL(filePath: bundlePath, directoryHint: .isDirectory)
let runnerDirectoryURL = URL(filePath: runnerDirectoryPath, directoryHint: .isDirectory)

var exitToken = ExitToken()

func main() {
  let runnerDirectory: RunnerDirectory
  do {
    runnerDirectory = try RunnerDirectory(bundleURL: bundleURL, toURL: runnerDirectoryURL)
  } catch {
    print(error.localizedDescription, to: &stderr)
    exit(1)
  }

  let runner = VZVirtualMachine(configuration: runnerDirectory.loadConfig(macAddress: macAddress))
  let runnerDelegate = RunnerDelegate(runnerDirectory: runnerDirectory, exitToken: exitToken)
  runner.delegate = runnerDelegate

  let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
  sigintSource.setEventHandler {
    print("info=SIGINT received. Stopping the runner...")
    runner.stop { error in
      if let error {
        print("gracefulStop=false")
        print(error.localizedDescription, to: &stderr)
        exitToken.exit(1)
      } else {
        print("gracefulStop=true")
        exitToken.exit(0)
      }
    }
  }

  runner.start { result in
    switch result {
    case .success:
      signal(SIGINT, SIG_IGN)
      sigintSource.activate()
      print("info=Runner started. Ctrl-C to stop the runner.")
      print("info=To get ip address, run the following command.")
      print(
        "runnerip=$(awk -vRS='}' -vmac='\(macAddress.string)' '$0~mac' /var/db/dhcpd_leases | awk -F'=' '$1~\"ip_address\"{print $2}') printenv runnerip"
      )
    case .failure(let error):
      print(error.localizedDescription)
      exitToken.exit(1)
    }
  }

  while !exitToken.isExiting && RunLoop.main.run(mode: .default, before: .distantFuture) {}
  exit(exitToken.exitCode)
}

await withThrowing
do {
  main()
  exit(0)
} catch {
  print(error.localizedDescription)
  exit(1)
}
