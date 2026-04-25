// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

// minibox-run: Minimum macOS runner based on Virtualization.framework.

import Foundation
import Virtualization
import os

enum MiniboxRunError: Error {
  case hardwareModelLoadError
  case machineIndentifierLoadError
  case invalidMACAddressError
  case runnerDirectoryAlreadyExistsError
  case runnerAlreadyStartedError
  case getIPAddressError
}

struct TemplateBundle {
  let url: URL
  var hardwareModelURL: URL { url.appending(components: "HardwareModel") }
  var machineIdentifierURL: URL {
    url.appending(components: "MachineIdentifier")
  }
  var auxiliaryStorageURL: URL {
    url.appending(components: "AuxiliaryStorage")
  }
  var diskURL: URL { url.appending(components: "Disk.asif") }
}

class RunnerDirectory {
  let url: URL
  let fileManager: FileManager

  var isDirty: Bool = false

  var hardwareModelURL: URL { url.appending(components: "HardwareModel") }
  var machineIdentifierURL: URL {
    url.appending(components: "MachineIdentifier")
  }
  var auxiliaryStorageURL: URL {
    url.appending(components: "AuxiliaryStorage")
  }
  var diskURL: URL { url.appending(components: "Disk.asif") }

  init(
    templateBundle: TemplateBundle,
    to url: URL,
    fileManager: FileManager = FileManager.default
  )
    throws
  {
    self.url = url
    self.fileManager = fileManager

    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    try fileManager.copyItem(
      at: templateBundle.hardwareModelURL,
      to: hardwareModelURL
    )
    try fileManager.copyItem(
      at: templateBundle.machineIdentifierURL,
      to: machineIdentifierURL
    )
    try fileManager.copyItem(
      at: templateBundle.auxiliaryStorageURL,
      to: auxiliaryStorageURL
    )
    try fileManager.copyItem(at: templateBundle.diskURL, to: diskURL)
  }

  func createVMConfig(
    cpuCount: Int,
    memorySize: Int,
    macAddress: VZMACAddress
  )
    throws -> VZVirtualMachineConfiguration
  {
    let platform = VZMacPlatformConfiguration()

    guard
      let hardwareModelData = try? Data(contentsOf: hardwareModelURL),
      let hardwareModel = VZMacHardwareModel(
        dataRepresentation: hardwareModelData
      )
    else {
      throw MiniboxRunError.hardwareModelLoadError
    }
    platform.hardwareModel = hardwareModel

    guard
      let machinesIdentifierData = try? Data(
        contentsOf: machineIdentifierURL
      ),
      let machineIdentifier = VZMacMachineIdentifier(
        dataRepresentation: machinesIdentifierData
      )
    else {
      throw MiniboxRunError.machineIndentifierLoadError
    }
    platform.machineIdentifier = machineIdentifier

    platform.auxiliaryStorage = VZMacAuxiliaryStorage(
      url: auxiliaryStorageURL
    )

    let config = VZVirtualMachineConfiguration()
    config.bootLoader = VZMacOSBootLoader()
    config.cpuCount = cpuCount
    config.memorySize = UInt64(memorySize)
    config.memoryBalloonDevices = [
      VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
    ]
    config.platform = platform

    let networkConfig = VZVirtioNetworkDeviceConfiguration()
    networkConfig.attachment = VZNATNetworkDeviceAttachment()
    networkConfig.macAddress = macAddress
    config.networkDevices = [networkConfig]

    let storageAttachment = try! VZDiskImageStorageDeviceAttachment(
      url: diskURL,
      readOnly: false
    )
    let storageConfig = VZVirtioBlockDeviceConfiguration(
      attachment: storageAttachment
    )
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

  func markDirty() {
    isDirty = true
  }

  func cleanup(logHandler: (OSLogType, String) -> Void) {
    if isDirty {
      let formatter = ISO8601DateFormatter()
      let backupURL = url.appendingPathExtension(
        formatter.string(from: Date())
      )

      logHandler(
        .error,
        "Backing up the runner directory due to failure..."
      )
      print("backup=\(backupURL.path(percentEncoded: false))")
      try? fileManager.moveItem(at: url, to: backupURL)
    } else {
      logHandler(.error, "Cleaning up the runner directory...")
      print("cleanup=\(url.path(percentEncoded: false))")
      try? fileManager.removeItem(at: url)
    }
  }
}

@MainActor
class MiniboxRun: NSObject, VZVirtualMachineDelegate {
  let runnerDirectory: RunnerDirectory
  let macAddress: VZMACAddress
  let logHandler: (OSLogType, String) -> Void

  var runner: VZVirtualMachine?
  var sigintSource: DispatchSourceSignal?
  let exitLock = OSAllocatedUnfairLock<Int32?>(initialState: nil)

  var assignedMACAddressString: String {
    macAddress.string
  }

  nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    exitLock.withLock { state in state = 0 }
  }

  nonisolated func virtualMachine(
    _ virtualMachine: VZVirtualMachine,
    didStopWithError error: any Error
  ) {
    exitLock.withLock { state in state = 1 }
  }

  nonisolated func virtualMachine(
    _ virtualMachine: VZVirtualMachine,
    networkDevice: VZNetworkDevice,
    attachmentWasDisconnectedWithError error: any Error
  ) {
    exitLock.withLock { state in state = 1 }
  }

  init(
    runnerDirectory: RunnerDirectory,
    macAddressString: String?,
    logHandler: @escaping (OSLogType, String) -> Void
  ) throws {
    self.runnerDirectory = runnerDirectory
    if let macAddressString {
      guard let macAddress = VZMACAddress(string: macAddressString) else {
        throw MiniboxRunError.invalidMACAddressError
      }
      self.macAddress = macAddress
    } else {
      self.macAddress = .randomLocallyAdministered()
    }
    self.logHandler = logHandler
  }

  func start(
    cpuCount: Int,
    memorySize: Int,
    completionHandler: @escaping (Result<Void, any Error>) -> Void
  ) throws {
    guard runner == nil else {
      throw MiniboxRunError.runnerAlreadyStartedError
    }

    let config = try runnerDirectory.createVMConfig(
      cpuCount: cpuCount,
      memorySize: memorySize,
      macAddress: macAddress
    )

    runner = VZVirtualMachine(configuration: config)
    runner?.delegate = self

    sigintSource = DispatchSource.makeSignalSource(
      signal: SIGINT,
      queue: .main
    )

    sigintSource?.setEventHandler { [weak self] in
      guard let self = self else {
        fatalError("MiniboxRun should never be deallocated!")
      }

      logHandler(.info, "SIGINT received. Stopping the runner...")
      stop()
    }

    runner?.start { result in
      switch result {
      case .success:
        signal(SIGINT, SIG_IGN)
        self.sigintSource?.activate()
        completionHandler(result)
      case .failure:
        completionHandler(result)
      }
    }
  }

  func stop() {
    if let runner {
      self.logHandler(.info, "Stopping the runner...")
      runner.stop { error in
        if let error {
          self.logHandler(.error, error.localizedDescription)
          print("stopWithError=true")
          self.exitLock.withLock { state in state = 1 }
        } else {
          self.logHandler(.info, "The runner stopped without error")
          print("stopWithError=false")
          self.exitLock.withLock { state in state = 0 }
        }
      }
    } else {
      self.logHandler(.info, "No runner has started.")
      print("stopWithoutAction=true")
      exitLock.withLock { state in state = 0 }
    }
  }

  func getIPAddresses() throws -> [String] {
    let process = Process()
    let pipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
    process.arguments = [
      "-vRS={", "-vmac=\(macAddress.string)", "$0~mac{print}",
      "/var/db/dhcpd_leases",
    ]
    process.standardInput = nil
    process.standardOutput = pipe
    process.standardError = nil

    let data: Data
    do {
      try process.run()
      data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
    } catch {
      throw MiniboxRunError.getIPAddressError
    }

    guard let records = String(data: data, encoding: .utf8) else {
      throw MiniboxRunError.getIPAddressError
    }

    let matches = records.matches(
      of: /ip_address=((?:[0-9]{1,3}\.){3}[0-9]{1,3})/
    )
    return matches.map { String($0.output.1) }
  }
}

func logStderr(_ level: OSLogType, _ message: String) {
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

func printUsage() {
  logStderr(
    .default,
    "Usage: minibox-run --bundle-path=PATH --cpu-count=COUNT --memory-size=BYTES --runner-name=NAME"
  )
  logStderr(
    .default,
    "  --bundle-path: Path to the template bundle. Mandatory."
  )
  logStderr(
    .default,
    "  --cpu-count: Number of CPU assigned to the runner. Mandatory."
  )
  logStderr(
    .default,
    "  --memory-size: Memory size in bytes assigned to the runner. Mandatory."
  )
  logStderr(
    .default,
    "  --runner-name: Unique name for the runner to manage its instance. Mandatory."
  )
  logStderr(
    .default,
    "  --mac-address: MAC address to be assigned to the runner. Optional."
  )
  logStderr(.default, "  --force-clean: Remove existing runner directory.")
  logStderr(.default, "  --version: Print version.")
  logStderr(.default, "  --help: Print this help.")
}

let options = {
  var options: [String: String] = [:]

  for arg in CommandLine.arguments.dropFirst() {
    let parts = arg.split(separator: "=", maxSplits: 1)
    let key = String(parts[0])
    options[key] = parts.count == 2 ? String(parts[1]) : "true"
  }

  return options
}()

if options["--help"] != nil {
  printUsage()
  exit(64)
}

guard
  let runnerName = options["--runner-name"],
  let bundlePath = options["--bundle-path"]
else {
  logStderr(.error, "--runner-name or --bundle-path is missing.")
  printUsage()
  exit(64)
}

guard let cpuCountString = options["--cpu-count"],
  let cpuCount = Int(cpuCountString)
else {
  logStderr(.error, "Malformed value for --cpu-count.")
  printUsage()
  exit(64)
}

guard let memorySizeString = options["--memory-size"],
  let memorySize = Int(memorySizeString)
else {
  logStderr(.error, "Malformed value for --memory-size.")
  printUsage()
  exit(64)
}

let macAddressString: String?
if let macAddressValue = options["--mac-address"], macAddressValue != "" {
  macAddressString = macAddressValue
} else {
  macAddressString = nil
}

let forceClean = options["--force-clean"] == "true"

print("bundlePath=\(bundlePath)")
print("cpuCount=\(cpuCount)")
print("memorySize=\(memorySize)")
print("runnerName=\(runnerName)")
print("macAddress=\(macAddressString ?? "(auto)")")
print("forceClean=\(forceClean)")

let runnerDirectoryURL = URL.applicationSupportDirectory.appending(
  path: "tokyo.kaito.Minibox/runners/\(runnerName)",
  directoryHint: .isDirectory
)
let templateBundleURL = URL(fileURLWithPath: bundlePath)

do {
  let fileManager = FileManager.default

  let templateBundle = TemplateBundle(url: templateBundleURL)

  if forceClean {
    logStderr(
      .info,
      "Force-cleaning runner directory: \(runnerDirectoryURL.path(percentEncoded: false))..."
    )
    try? fileManager.removeItem(at: runnerDirectoryURL)
  } else if fileManager.fileExists(
    atPath: runnerDirectoryURL.path(percentEncoded: false)
  ) {
    logStderr(.error, "Old runner directory remains. Exiting...")
    throw MiniboxRunError.runnerDirectoryAlreadyExistsError
  }

  let runnerDirectory = try RunnerDirectory(
    templateBundle: templateBundle,
    to: runnerDirectoryURL
  )
  defer {
    runnerDirectory.cleanup(logHandler: logStderr(_:_:))
  }

  let miniboxRun = try MiniboxRun(
    runnerDirectory: runnerDirectory,
    macAddressString: macAddressString,
    logHandler: logStderr(_:_:)
  )

  try miniboxRun.start(
    cpuCount: cpuCount,
    memorySize: memorySize
  ) { result in
    switch result {
    case .success:
      logStderr(
        .info,
        "Runner started. Ctrl-C to stop the runner."
      )
      logStderr(
        .info,
        "To get ip address, type ip and press enter here."
      )
    case .failure(let error):
      logStderr(.error, error.localizedDescription)
    }
  }

  Thread.detachNewThread {
    while true {
      guard let line = readLine(strippingNewline: true) else { return }
      let cmdline = line.split(separator: /\s+/)
      if cmdline.count >= 1 {
        let cmd = cmdline[0]
        if cmd.wholeMatch(of: /exit|stop|quit/) != nil {
          print("commandReceived=exit")
          DispatchQueue.main.sync {
            miniboxRun.stop()
          }
        } else if cmd.wholeMatch(of: /ip/) != nil {
          print("commandReceived=ip")
          DispatchQueue.main.sync {
            do {
              let ipAddresses = try miniboxRun.getIPAddresses()
              print("ipAddressCount=\(ipAddresses.count)")
              for ipAddress in ipAddresses {
                print("ipAddress=\(ipAddress)")
              }
            } catch {
              logStderr(.error, error.localizedDescription)
              print("ipAddressCount=-1")
            }
          }
        } else {
          print("commandReceived=help")
          print("availableCommand=exit(stop,quit)")
          print("availableCommand=ip")
        }
      }
    }
  }

  while RunLoop.main.run(mode: .default, before: .distantFuture) {
    if let exitCode = miniboxRun.exitLock.withLock({ $0 }) {
      exit(exitCode)
    }
  }
} catch {
  logStderr(.error, error.localizedDescription)
}

exit(1)
