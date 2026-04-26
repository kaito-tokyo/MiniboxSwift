// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

// minibox-view: Starts a new VM with a image bundle to view its contents.

import AppKit
import ArgumentParser
import Foundation
import Virtualization
import Vision
import os

private func logStderr(level: OSLogType, _ message: String) {
    let logMessage =
        switch level {
        case .debug: "DEBUG: \(message)\n"
        case .default: "\(message)\n"
        case .error: "ERROR: \(message)\n"
        case .fault: "FAULT: \(message)\n"
        case .info: "INFO: \(message)\n"
        default: "UNKNOWN: \(message)\n"
        }
    try? FileHandle.standardError.write(contentsOf: Data(logMessage.utf8))
}

enum MiniboxViewError: Error {
    case hardwareModelLoadError
    case machineIndentifierLoadError
    case ocrFailedError
    case ollamaResponseNotOKError
}

func loadVMConfig(
    hardwareModelURL: URL,
    machineIdentifierURL: URL,
    auxiliaryStorageURL: URL,
    storageURLs: [URL],
    macAddress: VZMACAddress,
    cpuCount: Int,
    memorySize: Int,
    width: Int,
    height: Int,
)
    throws -> VZVirtualMachineConfiguration
{
    let platform = VZMacPlatformConfiguration()

    guard
        let hardwareModelData = try? Data(contentsOf: hardwareModelURL),
        let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData)
    else {
        throw MiniboxViewError.hardwareModelLoadError
    }
    platform.hardwareModel = hardwareModel

    guard
        let machinesIdentifierData = try? Data(contentsOf: machineIdentifierURL),
        let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machinesIdentifierData)
    else {
        throw MiniboxViewError.machineIndentifierLoadError
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

    config.directorySharingDevices = []

    let graphicsConfig = VZMacGraphicsDeviceConfiguration()
    graphicsConfig.displays = [
        VZMacGraphicsDisplayConfiguration(
            widthInPixels: width,
            heightInPixels: height,
            pixelsPerInch: 72
        )
    ]
    config.graphicsDevices = [graphicsConfig]

    config.keyboards = [VZMacKeyboardConfiguration()]

    config.pointingDevices = [VZMacTrackpadConfiguration()]

    try config.validate()

    return config
}

struct MiniboxView: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "minibox view",
        abstract: "Starts a new VM with a image bundle to view its contents."
    )

    @Option(help: "Path to the image bundle.")
    var bundlePath: String

    @Option(help: "CPU count.")
    var cpuCount = 3

    @Option(help: "Memory size in bytes.")
    var memorySize = 7 * 1024 * 1024 * 1024

    @Option(help: "Number of width pixels.")
    var width = 1024

    @Option(help: "Number of height pixels.")
    var height = 768

    @Flag(help: "Enable agentic advice using Ollama.")
    var agenticAdvice = false

    var fileManager: FileManager { .default }

    func validate() throws {
        if !fileManager.fileExists(atPath: bundlePath) {
            throw ValidationError("Bundle path does not exist: \(bundlePath)!")
        }
    }
}

let options: MiniboxView
do {
    options = try MiniboxView.parse()
} catch {
    logStderr(level: .error, error.localizedDescription)
    logStderr(level: .default, MiniboxView.helpMessage())
    exit(64)
}

let bundleURL = URL(filePath: options.bundlePath)

let macAddress = VZMACAddress.randomLocallyAdministered()

let config = try loadVMConfig(
    hardwareModelURL: bundleURL.appending(path: "HardwareModel"),
    machineIdentifierURL: bundleURL.appending(path: "MachineIdentifier"),
    auxiliaryStorageURL: bundleURL.appending(path: "AuxiliaryStorage"),
    storageURLs: [bundleURL.appending(path: "Disk.asif")],
    macAddress: macAddress,
    cpuCount: options.cpuCount,
    memorySize: options.memorySize,
    width: options.width,
    height: options.height
)

let vm = VZVirtualMachine(configuration: config)

class VMDelegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        didStopWithError error: any Error
    ) {
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: any Error
    ) {
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }
}

let vmDelegate = VMDelegate()

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

func performOCR(on cgImage: CGImage) async throws -> [String] {
    return try await withCheckedThrowingContinuation { continuation in
        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                continuation.resume(throwing: error ?? MiniboxViewError.ocrFailedError)
                return
            }

            var recognizedTexts: [String] = []

            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let bb = observation.boundingBox
                let centerX = (bb.origin.x + bb.size.width / 2.0)
                let centerY = 1.0 - (bb.origin.y + bb.size.height / 2.0)
                recognizedTexts.append(
                    "[\(Int(centerX * 100.0)) \(Int(centerY * 100.0))] \(candidate.string)")
            }

            continuation.resume(returning: recognizedTexts)
        }

        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false
        request.usesLanguageCorrection = true
        request.customWords = []
        request.minimumTextHeight = 0.02

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            continuation.resume(throwing: error)
        }
    }
}

struct OllamaRequest: Codable {
    let model: String
    let messages: [Message]
    let stream: Bool

    struct Message: Codable {
        let role: String
        let content: String
        let images: [String]?
    }
}

struct OllamaResponse: Codable {
    let message: Message
    struct Message: Codable {
        let content: String
    }
}

func agenticChat(with ollamaRequest: OllamaRequest, ollamaBaseURL: URL) async throws
    -> OllamaResponse
{
    let url = ollamaBaseURL.appendingPathComponent("api/chat")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(ollamaRequest)

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        throw MiniboxViewError.ollamaResponseNotOKError
    }

    return try JSONDecoder().decode(OllamaResponse.self, from: data)
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let vm: VZVirtualMachine
    let width: Int
    let height: Int
    let ollamaBaseURL: URL?

    var systemPrompt: String?

    var recognizeTimer: Timer?
    var window: NSWindow?
    var vmView: VZVirtualMachineView?

    var spinner: NSProgressIndicator?
    var instructionLabel: NSTextField?
    var askButton: NSButton?

    init(vm: VZVirtualMachine, width: Int, height: Int, ollamaBaseURL: URL?) {
        self.vm = vm
        self.width = width
        self.height = height
        self.ollamaBaseURL = ollamaBaseURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.center()
        window.title = "MiniboxView"

        let vmView = VZVirtualMachineView()
        vmView.virtualMachine = vm

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false

        let instructionLabel = NSTextField(labelWithString: "")
        instructionLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        instructionLabel.textColor = .secondaryLabelColor
        instructionLabel.lineBreakMode = .byWordWrapping
        instructionLabel.isSelectable = true

        let adviceStackViewSpacer = NSView()
        adviceStackViewSpacer.translatesAutoresizingMaskIntoConstraints = false

        let askButton = NSButton(
            title: "Ask LLM for Advice", target: self, action: #selector(navigateTask))

        let adviceStackView = NSStackView(views: [
            spinner, instructionLabel, adviceStackViewSpacer, askButton,
        ])
        adviceStackView.orientation = .horizontal
        adviceStackView.distribution = .fill

        let stackView = NSStackView(views: [vmView, adviceStackView])
        stackView.orientation = .vertical
        stackView.spacing = 10
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        stackView.alignment = .leading

        window.contentView = stackView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(vmView)

        vmView.setContentHuggingPriority(.defaultLow, for: .vertical)
        instructionLabel.setContentHuggingPriority(.required, for: .vertical)

        NSApplication.shared.activate(ignoringOtherApps: true)

        self.window = window
        self.vmView = vmView
        self.spinner = spinner
        self.instructionLabel = instructionLabel
        self.askButton = askButton
    }

    @objc func navigateTask() {
        Task { @MainActor in
            guard let vmView else { return }

            let bounds = vmView.bounds
            guard let bitmapRep = vmView.bitmapImageRepForCachingDisplay(in: bounds) else {
                return
            }

            vmView.cacheDisplay(in: bounds, to: bitmapRep)

            if let cgImage = bitmapRep.cgImage, let ollamaBaseURL, let systemPrompt {
                let recognizedTexts = try await performOCR(on: cgImage)

                var message = "Can you advice me on how to proceed the setup of macOS?\n\n"
                message += """
                    ## OCR Data (Format: [x y] Text, Coordinate: Top Left [0, 0], Bottom Right [100, 100])
                    """
                message += "\n\n"
                if recognizedTexts.count == 0 {
                    message += "EMPTY: No text detected.\n"
                } else {
                    for recognizedText in recognizedTexts {
                        message += "- \(recognizedText)\n"
                    }
                }
                message += """
                    ## Instruction
                    Determine the current phase and provide the next step.
                    Use the format: [TAG] Action description.
                    """

                let imageDataURLs: [String]?
                if let data = bitmapRep.representation(using: .jpeg, properties: [:]) {
                    imageDataURLs = [data.base64EncodedString()]
                } else {
                    imageDataURLs = nil
                }

                let ollamaRequest = OllamaRequest(
                    model: "gemma3:4b-it-q8_0",
                    messages: [
                        .init(role: "system", content: systemPrompt, images: nil),
                        .init(role: "user", content: message, images: imageDataURLs),
                    ],
                    stream: false
                )
                do {
                    spinner?.startAnimation(nil)
                    let advice = try await agenticChat(
                        with: ollamaRequest, ollamaBaseURL: ollamaBaseURL)
                    instructionLabel?.stringValue = advice.message.content
                    spinner?.stopAnimation(nil)
                } catch {
                    logStderr(level: .error, error.localizedDescription)
                }
            }
        }
    }
}

let ollamaBaseURL: URL?
if options.agenticAdvice {
    if let string = ProcessInfo.processInfo.environment["OLLAMA_BASE_URL"] {
        ollamaBaseURL = URL(string: string)
    } else {
        ollamaBaseURL = URL(string: "http://localhost:11434")
    }
} else {
    ollamaBaseURL = nil
}

NSApplication.shared.setActivationPolicy(.regular)
let delegate = AppDelegate(
    vm: vm, width: options.width, height: options.height, ollamaBaseURL: ollamaBaseURL)
if options.agenticAdvice {
    delegate.systemPrompt = """
        The goal of user is to complete macOS installation process.
        Please provide a short text to instruct what user should do next.

        ## Installation sequence
        1. Blank screen
        2. Welcome screen
        3. Select your region
        4. Transfer Your Data to This Mac
        5. Written and Spoken Languages
        6. Accessibility

        ## Rules
        - Language MUST be English.
        - Let user to select region.
        """
}
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
