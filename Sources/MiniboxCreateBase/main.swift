// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

// minibox-create-base: Creates a base image from ipsw.

import ArgumentParser
import Foundation
import Virtualization
import os

let kMiniboxSwiftBaseImageDirectoryPrefix = URL
  .applicationSupportDirectory
  .appending(
    path: "tokyo.kaito.MiniboxSwift/BaseImages",
    directoryHint: .isDirectory
  )

enum MiniboxInstallError: Error {
  case requirementsNotAvailableError
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

  config.storageDevices = try storageURLs.map {
    VZVirtioBlockDeviceConfiguration(
      attachment: try VZDiskImageStorageDeviceAttachment(
        url: $0,
        readOnly: false
      )
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

private func createBlankASIF(url: URL) throws {
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

  try process.run()
  process.waitUntilExit()
}

struct MiniboxCreateBase: ParsableCommand {
  @Option(help: "Path to ipsw.")
  var ipswPath: String

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

          let osVersion = restoreImage.operatingSystemVersion
          let versionString =
            "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"

          let baseImageName =
            "macOS_\(versionString)_\(restoreImage.buildVersion)"
          let baseImageURL =
            kMiniboxSwiftBaseImageDirectoryPrefix.appending(
              path: baseImageName,
              directoryHint: .isDirectory
            )

          print("==> Installing a new template...")
          print("ipswPath=\(ipswURL.path(percentEncoded: false))")
          print("baseImageName=\(baseImageName)")
          print(
            "baseImagePath=\(baseImageURL.path(percentEncoded: false))"
          )

          if !yes {
            print(
              "==> Are you sure to install? [Y/n] ",
              terminator: ""
            )
            let answer = readLine(strippingNewline: true)
            if let answer, answer != "",
              !answer.starts(with: /[yY]/)
            {
              logStderr(.error, "Aborting...")
              exitLock.withLock { $0 = ExitCode.failure }
              return
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
              do {
                try fileManager.removeItem(at: baseImageURL)
              } catch {
                logStderr(.error, error.localizedDescription)
                exitLock.withLock { $0 = ExitCode.failure }
                return
              }
            } else {
              logStderr(
                .error,
                "There is already a base image named \(baseImageName)! Exiting..."
              )
              exitLock.withLock { $0 = ExitCode.failure }
              return
            }
          }

          do {
            try fileManager.createDirectory(
              at: baseImageURL,
              withIntermediateDirectories: true
            )
          } catch {
            logStderr(.error, error.localizedDescription)
            exitLock.withLock { $0 = ExitCode.failure }
            return
          }

          let diskURL = baseImageURL.appendingPathComponent(
            "Disk.asif"
          )
          do {
            try createBlankASIF(url: diskURL)
          } catch {
            logStderr(.error, error.localizedDescription)
            exitLock.withLock { $0 = ExitCode.failure }
            return
          }

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
              storageURLs: [diskURL],
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

MiniboxCreateBase.main()
