import Foundation
import AVFoundation
import CoreAudio

// MARK: - Audio Device Selection

struct AudioInputDevice {
    let id: AudioDeviceID
    let name: String
}

func listAudioInputDevices() -> [AudioInputDevice] {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0, nil,
        &dataSize
    )
    guard status == noErr else { return [] }

    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0, nil,
        &dataSize,
        &deviceIDs
    )
    guard status == noErr else { return [] }

    var inputDevices: [AudioInputDevice] = []

    for deviceID in deviceIDs {
        // Check if device has input channels
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var bufferListSize: UInt32 = 0
        status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &bufferListSize)
        guard status == noErr, bufferListSize > 0 else { continue }

        let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferListPtr.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &bufferListSize, bufferListPtr)
        guard status == noErr else { continue }

        let bufferList = bufferListPtr.pointee
        var totalChannels: UInt32 = 0
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferListPtr))
        for buffer in buffers {
            totalChannels += buffer.mNumberChannels
        }
        guard totalChannels > 0 else { continue }

        // Get device name
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef)
        guard status == noErr else { continue }

        let name = nameRef as String
        inputDevices.append(AudioInputDevice(id: deviceID, name: name))
    }

    return inputDevices
}

func getDefaultInputDevice() -> AudioDeviceID {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioDeviceID = 0
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0, nil,
        &dataSize,
        &deviceID
    )
    return deviceID
}

func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var mutableDeviceID = deviceID
    let status = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size),
        &mutableDeviceID
    )
    return status == noErr
}

func resolveDevice(_ deviceArg: String) -> AudioInputDevice? {
    let devices = listAudioInputDevices()

    // Try as a number first (index from --list-devices)
    if let index = Int(deviceArg), index >= 1, index <= devices.count {
        return devices[index - 1]
    }

    // Try case-insensitive exact match
    if let device = devices.first(where: { $0.name.lowercased() == deviceArg.lowercased() }) {
        return device
    }

    // Try case-insensitive partial match
    let matches = devices.filter { $0.name.lowercased().contains(deviceArg.lowercased()) }
    if matches.count == 1 {
        return matches[0]
    }

    return nil
}

// MARK: - Recording

class ChunkedRecorder: NSObject, AVAudioRecorderDelegate {
    private var currentRecorder: AVAudioRecorder?
    private var chunkIndex = 0
    private var chunkTimer: Timer?
    private var testTimer: Timer?
    private var meteringTimer: Timer?
    private let transcriptionQueue = DispatchQueue(label: "com.miclog.transcription")
    private var pendingChunks: [String] = []
    private var silentChunks: Set<Int> = []
    private var isRecording = false
    private var isTranscribing = false
    private let dateFormatter: DateFormatter
    private var startTime: Date?
    private let chunkDuration: TimeInterval = 5.0
    private let whisperPath: String?
    private let modelPath: String?
    private var recentOutputs: [String] = []
    private let maxRecentOutputs = 5
    private var currentChunkHasAudio = false
    private let silenceThreshold: Float = -45.0  // dB threshold for silence

    override init() {
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        // Find whisper-cpp executable
        self.whisperPath = ChunkedRecorder.findWhisperPath()

        // Find large model
        self.modelPath = ChunkedRecorder.findModelPath()

        super.init()
    }

    static func findWhisperPath() -> String? {
        let possiblePaths = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
            "/opt/homebrew/bin/main", // whisper.cpp compiled binary name
            "/usr/local/bin/main"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try using 'which' for whisper-cli first
        for binary in ["whisper-cli", "whisper-cpp"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [binary]

            let pipe = Pipe()
            process.standardOutput = pipe

            try? process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    return path
                }
            }
        }

        return nil
    }

    static func findModelPath() -> String? {
        let currentDir = FileManager.default.currentDirectoryPath
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let possiblePaths = [
            "\(currentDir)/.whisper-models/ggml-large-v3.bin",
            "\(homeDir)/.whisper/models/ggml-large-v3.bin",
            "/opt/homebrew/share/whisper-cpp/models/ggml-large-v3.bin",
            "/usr/local/share/whisper-cpp/models/ggml-large-v3.bin"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    func checkPrerequisites() -> Bool {
        guard let _ = whisperPath else {
            print("Error: whisper-cli not found")
            print("")
            print("Install with: brew install whisper-cpp")
            print("(This installs the whisper-cli executable)")
            print("")
            print("Or build from source: https://github.com/ggerganov/whisper.cpp")
            return false
        }

        guard let _ = modelPath else {
            print("Error: Whisper large model not found")
            print("")
            print("Download with:")
            print("  mkdir -p .whisper-models")
            print("  curl -L https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin -o .whisper-models/ggml-large-v3.bin")
            print("")
            print("Or use whisper.cpp model downloader:")
            print("  bash /opt/homebrew/Cellar/whisper-cpp/*/models/download-ggml-model.sh large")
            return false
        }

        return true
    }

    func startRecording(duration: TimeInterval? = nil) -> Bool {
        guard checkPrerequisites() else {
            return false
        }

        isRecording = true
        isTranscribing = true
        startTime = Date()

        // Start first chunk
        if !startNewChunk() {
            return false
        }

        // Setup chunk rotation timer
        chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: true) { [weak self] _ in
            self?.rotateChunk()
        }

        // Setup metering timer to check audio levels periodically
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkAudioLevels()
        }

        // Set terminal tab title
        print("\u{1B}]1;🎤 miclog\u{07}", to: &standardError)

        // Setup test mode timer if specified
        if let duration = duration {
            print("Recording for \(Int(duration)) seconds...", to: &standardError)
            testTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                self?.stopRecording()
            }
        } else {
            print("Recording... (Press Ctrl+C to stop)", to: &standardError)
        }

        return true
    }

    private func startNewChunk() -> Bool {
        let chunkPath = "/tmp/miclog_chunk_\(chunkIndex).wav"
        let audioURL = URL(fileURLWithPath: chunkPath)

        // WAV format settings
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0, // 16kHz optimal for whisper
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            currentRecorder = try AVAudioRecorder(url: audioURL, settings: settings)
            currentRecorder?.delegate = self
            currentRecorder?.isMeteringEnabled = true
            currentRecorder?.prepareToRecord()

            // Reset audio detection for new chunk
            currentChunkHasAudio = false

            let success = currentRecorder?.record() ?? false
            if !success {
                print("Error: Failed to start recording chunk", to: &standardError)
                return false
            }

            return true
        } catch {
            print("Error starting chunk: \(error.localizedDescription)", to: &standardError)
            return false
        }
    }

    private func checkAudioLevels() {
        guard let recorder = currentRecorder, recorder.isRecording else { return }

        recorder.updateMeters()
        let averagePower = recorder.averagePower(forChannel: 0)

        // If audio level exceeds silence threshold, mark chunk as having audio
        if averagePower > silenceThreshold {
            currentChunkHasAudio = true
        }
    }

    private func rotateChunk() {
        guard isRecording else { return }

        // Stop current recorder
        currentRecorder?.stop()

        // Mark chunk as silent if no audio was detected
        if !currentChunkHasAudio {
            silentChunks.insert(chunkIndex)
        }

        // Add completed chunk to transcription queue
        let chunkPath = "/tmp/miclog_chunk_\(chunkIndex).wav"
        pendingChunks.append(chunkPath)

        // Process transcription in background
        transcriptionQueue.async { [weak self] in
            self?.processNextChunk()
        }

        // Start next chunk
        chunkIndex += 1
        _ = startNewChunk()
    }

    private func processNextChunk() {
        guard let chunkPath = pendingChunks.first else { return }
        pendingChunks.removeFirst()

        // Extract chunk index from path (e.g., "/tmp/miclog_chunk_5.wav" -> 5)
        let filename = (chunkPath as NSString).lastPathComponent
        let chunkIndexStr = filename.replacingOccurrences(of: "miclog_chunk_", with: "").replacingOccurrences(of: ".wav", with: "")
        let currentChunkIndex = Int(chunkIndexStr) ?? -1

        // Skip transcription for silent chunks
        if silentChunks.contains(currentChunkIndex) {
            try? FileManager.default.removeItem(atPath: chunkPath)
            silentChunks.remove(currentChunkIndex)
        } else {
            transcribeChunk(chunkPath)
        }

        // Process next chunk if available
        if !pendingChunks.isEmpty {
            processNextChunk()
        } else if !isRecording {
            // All chunks processed and recording stopped
            DispatchQueue.main.async { [weak self] in
                self?.isTranscribing = false
                self?.printStats()
                // Restore original audio device
                if let originalID = originalDeviceID {
                    _ = setDefaultInputDevice(originalID)
                }
                exit(0)
            }
        }
    }

    private func transcribeChunk(_ path: String) {
        guard let whisperPath = whisperPath, let modelPath = modelPath else { return }

        // Ensure cleanup happens even on early returns
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = [
            "-m", modelPath,
            "-np",              // No prints (only output transcription)
            "-nt",              // No timestamps in output
            "-nth", "0.90",     // No-speech threshold (default: 0.60)
            "-et", "3.5",       // Entropy threshold (default: 2.40)
            "-sns",             // Suppress non-speech tokens
            "-nf",              // Disable temperature fallback
            path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

                    // Skip empty output
                    if trimmed.isEmpty {
                        return
                    }

                    // Filter 1: Minimum word count (skip very short outputs)
                    let wordCount = trimmed.components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }.count
                    if wordCount < 3 {
                        return  // Skip outputs with fewer than 3 words
                    }

                    // Filter 2: Exact repetition detection
                    if recentOutputs.contains(trimmed) {
                        return  // Skip exact duplicate of recent output
                    }

                    // Output the transcription
                    let timestamp = dateFormatter.string(from: Date())
                    print("[\(timestamp)] \(trimmed)")
                    fflush(stdout)

                    // Update recent outputs cache
                    recentOutputs.append(trimmed)
                    if recentOutputs.count > maxRecentOutputs {
                        recentOutputs.removeFirst()
                    }
                }
            }
        } catch {
            print("Error transcribing chunk: \(error.localizedDescription)", to: &standardError)
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        isRecording = false
        chunkTimer?.invalidate()
        testTimer?.invalidate()
        meteringTimer?.invalidate()

        // Stop current recorder and mark final chunk as silent if needed
        currentRecorder?.stop()
        if !currentChunkHasAudio {
            silentChunks.insert(chunkIndex)
        }

        let finalChunkPath = "/tmp/miclog_chunk_\(chunkIndex).wav"
        pendingChunks.append(finalChunkPath)

        print("", to: &standardError)
        print("Recording stopped. Processing remaining chunks...", to: &standardError)

        // Process remaining chunks
        transcriptionQueue.async { [weak self] in
            self?.processNextChunk()
        }
    }

    private func printStats() {
        if let startTime = startTime {
            let duration = Date().timeIntervalSince(startTime)
            print("Duration: \(String(format: "%.1f", duration))s", to: &standardError)
        }
    }
}

// Utility to write to stderr
var standardError = FileHandle.standardError

extension FileHandle: @retroactive TextOutputStream {
    public func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            self.write(data)
        }
    }
}

func printUsage() {
    print("Usage: miclog [--test SECONDS] [--device NAME|NUMBER]", to: &standardError)
    print("", to: &standardError)
    print("Options:", to: &standardError)
    print("  --test SECONDS       Record for specified seconds and exit", to: &standardError)
    print("  --device NAME|NUM    Use a specific audio input device", to: &standardError)
    print("  --list-devices       List available audio input devices", to: &standardError)
    print("", to: &standardError)
    print("Output is written to stdout. Use shell redirection to save:", to: &standardError)
    print("  ./miclog > transcript.txt", to: &standardError)
    print("", to: &standardError)
    print("Examples:", to: &standardError)
    print("  ./miclog                             # Transcribe to stdout until Ctrl+C", to: &standardError)
    print("  ./miclog --test 30                   # Transcribe for 30 seconds", to: &standardError)
    print("  ./miclog --list-devices              # Show available microphones", to: &standardError)
    print("  ./miclog --device \"AirPods Pro\"       # Record from specific device", to: &standardError)
    print("  ./miclog --device 2                  # Record from device #2", to: &standardError)
    print("  ./miclog > output.txt                # Save transcript to file", to: &standardError)
}

// Parse command line arguments
var testDuration: TimeInterval? = nil
var deviceArg: String? = nil
var args = Array(CommandLine.arguments.dropFirst())

if args.contains("--help") || args.contains("-h") {
    printUsage()
    exit(0)
}

if args.contains("--list-devices") {
    let devices = listAudioInputDevices()
    let defaultID = getDefaultInputDevice()
    if devices.isEmpty {
        print("No audio input devices found.", to: &standardError)
        exit(1)
    }
    print("Available audio input devices:", to: &standardError)
    for (i, device) in devices.enumerated() {
        let marker = device.id == defaultID ? " (default)" : ""
        print("  \(i + 1). \(device.name)\(marker)", to: &standardError)
    }
    exit(0)
}

if let deviceIndex = args.firstIndex(of: "--device") {
    let nextIndex = args.index(after: deviceIndex)
    guard nextIndex < args.endIndex else {
        print("Error: --device requires a device name or number", to: &standardError)
        printUsage()
        exit(1)
    }
    deviceArg = args[nextIndex]
}

if let testIndex = args.firstIndex(of: "--test") {
    let nextIndex = args.index(after: testIndex)
    guard nextIndex < args.endIndex else {
        print("Error: --test requires a duration in seconds", to: &standardError)
        printUsage()
        exit(1)
    }

    guard let seconds = TimeInterval(args[nextIndex]) else {
        print("Error: Invalid duration '\(args[nextIndex])'", to: &standardError)
        printUsage()
        exit(1)
    }

    testDuration = seconds
}

// Handle device selection
var originalDeviceID: AudioDeviceID? = nil

if let deviceArg = deviceArg {
    guard let device = resolveDevice(deviceArg) else {
        print("Error: Could not find audio device '\(deviceArg)'", to: &standardError)
        print("", to: &standardError)
        let devices = listAudioInputDevices()
        if !devices.isEmpty {
            print("Available devices:", to: &standardError)
            for (i, d) in devices.enumerated() {
                print("  \(i + 1). \(d.name)", to: &standardError)
            }
        }
        exit(1)
    }

    // Save current default so we can restore it later
    originalDeviceID = getDefaultInputDevice()

    if setDefaultInputDevice(device.id) {
        print("Using audio device: \(device.name)", to: &standardError)
    } else {
        print("Error: Could not set audio device to '\(device.name)'", to: &standardError)
        exit(1)
    }
}

let recorder = ChunkedRecorder()

// Setup signal handler for Ctrl+C
let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signalSource.setEventHandler {
    recorder.stopRecording()
    // Restore original audio device
    if let originalID = originalDeviceID {
        _ = setDefaultInputDevice(originalID)
    }
}
signal(SIGINT, SIG_IGN)
signalSource.resume()

// Start recording
if recorder.startRecording(duration: testDuration) {
    RunLoop.main.run()
} else {
    // Restore original audio device on failure
    if let originalID = originalDeviceID {
        _ = setDefaultInputDevice(originalID)
    }
    exit(1)
}
