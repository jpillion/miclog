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

// Utility to write to stderr (declared early so config functions can use it)
var standardError = FileHandle.standardError

extension FileHandle: @retroactive TextOutputStream {
    public func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            self.write(data)
        }
    }
}

// MARK: - Configuration

struct MiclogConfig: Codable {
    var name: String
    var outputDir: String
    var meetingTypes: [String]
    var attendees: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case outputDir = "output_dir"
        case meetingTypes = "meeting_types"
        case attendees
    }

    init(name: String = "", outputDir: String, meetingTypes: [String] = [], attendees: [String] = []) {
        self.name = name
        self.outputDir = outputDir
        self.meetingTypes = meetingTypes
        self.attendees = attendees
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaultDir = MiclogConfig.binaryDirectory()
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.outputDir = try container.decodeIfPresent(String.self, forKey: .outputDir) ?? defaultDir
        self.meetingTypes = try container.decodeIfPresent([String].self, forKey: .meetingTypes) ?? []
        self.attendees = try container.decodeIfPresent([String].self, forKey: .attendees) ?? []
    }

    static func binaryDirectory() -> String {
        var binaryPath = CommandLine.arguments[0]
        if !binaryPath.hasPrefix("/") {
            if binaryPath.contains("/") {
                binaryPath = FileManager.default.currentDirectoryPath + "/" + binaryPath
            } else {
                // Invoked via $PATH — fall back to cwd
                return FileManager.default.currentDirectoryPath
            }
        }
        let resolved = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath()
        return resolved.deletingLastPathComponent().path
    }
}

func configFilePath() -> String {
    return MiclogConfig.binaryDirectory() + "/config.json"
}

func defaultConfig() -> MiclogConfig {
    return MiclogConfig(outputDir: MiclogConfig.binaryDirectory())
}

func loadConfig() -> MiclogConfig {
    let path = configFilePath()
    var config: MiclogConfig
    if FileManager.default.fileExists(atPath: path) {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            config = try JSONDecoder().decode(MiclogConfig.self, from: data)
        } catch {
            print("Warning: Could not read config.json (\(error.localizedDescription)), using defaults", to: &standardError)
            config = defaultConfig()
        }
    } else {
        config = defaultConfig()
    }

    // Ensure "1-1" always exists in meeting types
    if !config.meetingTypes.contains("1-1") {
        config.meetingTypes.insert("1-1", at: 0)
        saveConfig(config)
    }

    return config
}

func saveConfig(_ config: MiclogConfig) {
    let path = configFilePath()
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        print("Error: Could not save config.json: \(error.localizedDescription)", to: &standardError)
        exit(1)
    }
}

// MARK: - Config CLI Commands

func handleConfigCommand(_ args: [String]) {
    if args.isEmpty || args.first == "show" {
        let config = loadConfig()
        let path = configFilePath()
        print("Configuration (\(path)):")
        print("  name: \(config.name.isEmpty ? "(not set)" : config.name)")
        print("  output_dir: \(config.outputDir)")
        if config.meetingTypes.isEmpty {
            print("  meeting_types: (none)")
        } else {
            print("  meeting_types: \(config.meetingTypes.joined(separator: ", "))")
        }
        if config.attendees.isEmpty {
            print("  attendees: (none)")
        } else {
            print("  attendees: \(config.attendees.joined(separator: ", "))")
        }
        return
    }

    let subcmd = args[0]
    let rest = Array(args.dropFirst())

    switch subcmd {
    case "list":
        handleConfigList(rest)
    case "set":
        handleConfigSet(rest)
    case "add":
        handleConfigAdd(rest)
    case "remove":
        handleConfigRemove(rest)
    case "setup":
        runConfigSetup()
    default:
        print("Error: Unknown config subcommand '\(subcmd)'", to: &standardError)
        printConfigUsage()
        exit(1)
    }
}

func handleConfigList(_ args: [String]) {
    let config = loadConfig()
    if args.isEmpty {
        handleConfigCommand([])  // show all
        return
    }
    switch args[0] {
    case "meeting-types":
        if config.meetingTypes.isEmpty {
            print("(none)")
        } else {
            for t in config.meetingTypes { print(t) }
        }
    case "attendees":
        if config.attendees.isEmpty {
            print("(none)")
        } else {
            for a in config.attendees { print(a) }
        }
    default:
        print("Error: Unknown list target '\(args[0])'. Use 'meeting-types' or 'attendees'.", to: &standardError)
        exit(1)
    }
}

func handleConfigSet(_ args: [String]) {
    guard args.count >= 2 else {
        print("Error: 'config set' requires a key and value", to: &standardError)
        printConfigUsage()
        exit(1)
    }
    let key = args[0]
    let value = args.dropFirst().joined(separator: " ")

    switch key {
    case "name":
        var config = loadConfig()
        config.name = value
        saveConfig(config)
        print("name set to: \(value)")
    case "output-dir":
        var config = loadConfig()
        let expandedPath = NSString(string: value).expandingTildeInPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: expandedPath) {
            do {
                try fm.createDirectory(atPath: expandedPath, withIntermediateDirectories: true)
                print("Created directory: \(expandedPath)")
            } catch {
                print("Error: Could not create directory: \(error.localizedDescription)", to: &standardError)
                exit(1)
            }
        }
        if !fm.isWritableFile(atPath: expandedPath) {
            print("Warning: Directory is not writable: \(expandedPath)", to: &standardError)
        }
        config.outputDir = expandedPath
        saveConfig(config)
        print("output_dir set to: \(expandedPath)")
    default:
        print("Error: Unknown setting '\(key)'. Use 'name' or 'output-dir'.", to: &standardError)
        exit(1)
    }
}

func handleConfigAdd(_ args: [String]) {
    guard args.count >= 2 else {
        print("Error: 'config add' requires a type and value", to: &standardError)
        printConfigUsage()
        exit(1)
    }
    let target = args[0]
    let value = args.dropFirst().joined(separator: " ")
    var config = loadConfig()

    switch target {
    case "meeting-type":
        if config.meetingTypes.contains(value) {
            print("'\(value)' already exists in meeting types")
            return
        }
        config.meetingTypes.append(value)
        saveConfig(config)
        print("Added meeting type: \(value)")
    case "attendee":
        if config.attendees.contains(value) {
            print("'\(value)' already exists in attendees")
            return
        }
        config.attendees.append(value)
        saveConfig(config)
        print("Added attendee: \(value)")
    default:
        print("Error: Unknown target '\(target)'. Use 'meeting-type' or 'attendee'.", to: &standardError)
        exit(1)
    }
}

func handleConfigRemove(_ args: [String]) {
    guard args.count >= 2 else {
        print("Error: 'config remove' requires a type and value", to: &standardError)
        printConfigUsage()
        exit(1)
    }
    let target = args[0]
    let value = args.dropFirst().joined(separator: " ")
    var config = loadConfig()

    switch target {
    case "meeting-type":
        guard let idx = config.meetingTypes.firstIndex(of: value) else {
            print("Error: '\(value)' not found in meeting types", to: &standardError)
            exit(1)
        }
        config.meetingTypes.remove(at: idx)
        saveConfig(config)
        print("Removed meeting type: \(value)")
    case "attendee":
        guard let idx = config.attendees.firstIndex(of: value) else {
            print("Error: '\(value)' not found in attendees", to: &standardError)
            exit(1)
        }
        config.attendees.remove(at: idx)
        saveConfig(config)
        print("Removed attendee: \(value)")
    default:
        print("Error: Unknown target '\(target)'. Use 'meeting-type' or 'attendee'.", to: &standardError)
        exit(1)
    }
}

// MARK: - Interactive Config Wizard

func runConfigSetup() {
    var config = loadConfig()
    print("miclog Configuration Setup")
    print("==========================")
    print("")

    // Your name
    let currentName = config.name.isEmpty ? "(not set)" : config.name
    print("Your name [\(currentName)]:")
    if let input = readLine()?.trimmingCharacters(in: .whitespaces), !input.isEmpty {
        config.name = input
    }
    print("")

    // Output directory
    print("Output directory [\(config.outputDir)]:")
    if let input = readLine(), !input.isEmpty {
        let expanded = NSString(string: input).expandingTildeInPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: expanded) {
            do {
                try fm.createDirectory(atPath: expanded, withIntermediateDirectories: true)
                print("  Created directory: \(expanded)")
            } catch {
                print("  Warning: Could not create directory: \(error.localizedDescription)")
            }
        }
        config.outputDir = expanded
    }
    print("")

    // Meeting types
    print("Meeting Types:")
    printNumberedList(config.meetingTypes)
    var editingMeetingTypes = true
    while editingMeetingTypes {
        print("  [a]dd, [r]emove, [d]one: ", terminator: "")
        fflush(stdout)
        guard let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(), !input.isEmpty else {
            editingMeetingTypes = false
            break
        }
        switch input {
        case "a":
            print("  New meeting type: ", terminator: "")
            fflush(stdout)
            if let name = readLine()?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                if config.meetingTypes.contains(name) {
                    print("  '\(name)' already exists")
                } else {
                    config.meetingTypes.append(name)
                    printNumberedList(config.meetingTypes)
                }
            }
        case "r":
            if config.meetingTypes.isEmpty {
                print("  No meeting types to remove")
            } else {
                print("  Number to remove: ", terminator: "")
                fflush(stdout)
                if let numStr = readLine(), let num = Int(numStr), num >= 1, num <= config.meetingTypes.count {
                    let removed = config.meetingTypes.remove(at: num - 1)
                    print("  Removed: \(removed)")
                    printNumberedList(config.meetingTypes)
                } else {
                    print("  Invalid number")
                }
            }
        case "d":
            editingMeetingTypes = false
        default:
            print("  Enter 'a', 'r', or 'd'")
        }
    }
    print("")

    // Attendees
    print("Attendees:")
    printNumberedList(config.attendees)
    var editingAttendees = true
    while editingAttendees {
        print("  [a]dd, [r]emove, [d]one: ", terminator: "")
        fflush(stdout)
        guard let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(), !input.isEmpty else {
            editingAttendees = false
            break
        }
        switch input {
        case "a":
            print("  New attendee: ", terminator: "")
            fflush(stdout)
            if let name = readLine()?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                if config.attendees.contains(name) {
                    print("  '\(name)' already exists")
                } else {
                    config.attendees.append(name)
                    printNumberedList(config.attendees)
                }
            }
        case "r":
            if config.attendees.isEmpty {
                print("  No attendees to remove")
            } else {
                print("  Number to remove: ", terminator: "")
                fflush(stdout)
                if let numStr = readLine(), let num = Int(numStr), num >= 1, num <= config.attendees.count {
                    let removed = config.attendees.remove(at: num - 1)
                    print("  Removed: \(removed)")
                    printNumberedList(config.attendees)
                } else {
                    print("  Invalid number")
                }
            }
        case "d":
            editingAttendees = false
        default:
            print("  Enter 'a', 'r', or 'd'")
        }
    }
    print("")

    saveConfig(config)
    print("Config saved to \(configFilePath())")
}

func printNumberedList(_ items: [String]) {
    if items.isEmpty {
        print("  (none)")
    } else {
        for (i, item) in items.enumerated() {
            print("  \(i + 1). \(item)")
        }
    }
}

func printConfigUsage() {
    print("", to: &standardError)
    print("Config subcommands:", to: &standardError)
    print("  config show                          Show all configuration", to: &standardError)
    print("  config list meeting-types            List meeting types", to: &standardError)
    print("  config list attendees                List attendees", to: &standardError)
    print("  config set name <NAME>               Set your name", to: &standardError)
    print("  config set output-dir <PATH>         Set output directory", to: &standardError)
    print("  config add meeting-type <NAME>       Add a meeting type", to: &standardError)
    print("  config remove meeting-type <NAME>    Remove a meeting type", to: &standardError)
    print("  config add attendee <NAME>           Add an attendee", to: &standardError)
    print("  config remove attendee <NAME>        Remove an attendee", to: &standardError)
    print("  config setup                         Interactive configuration wizard", to: &standardError)
}

// MARK: - Meeting Metadata & Post-Recording Prompts

struct MeetingMetadata {
    let meetingType: String
    let attendees: [String]   // empty means "unspecified"
    let title: String?        // nil means skipped
    let date: Date            // recording start time
}

func sanitizeFilename(_ name: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:\\")
    return name.components(separatedBy: invalid).joined(separator: "-")
}

func promptMeetingMetadata(config: MiclogConfig, recordingStartTime: Date) -> MeetingMetadata? {
    // Skip prompts if stdin is not a terminal (piped input)
    guard isatty(STDIN_FILENO) != 0 else { return nil }

    var currentConfig = config
    print("", to: &standardError)

    // Step 1: Meeting type (required, single choice)
    let meetingType: String
    if currentConfig.meetingTypes.isEmpty {
        // Defensive: shouldn't happen since 1-1 is always injected
        print("What type of meeting was this?", to: &standardError)
        while true {
            print("Meeting type: ", terminator: "", to: &standardError)
            fflush(stderr)
            if let input = readLine()?.trimmingCharacters(in: .whitespaces), !input.isEmpty {
                meetingType = input
                currentConfig.meetingTypes.append(input)
                saveConfig(currentConfig)
                break
            }
            print("  Please enter a meeting type.", to: &standardError)
        }
    } else {
        print("What type of meeting was this?", to: &standardError)
        while true {
            for (i, t) in currentConfig.meetingTypes.enumerated() {
                print("  \(i + 1). \(t)", to: &standardError)
            }
            print("  \(currentConfig.meetingTypes.count + 1). + Add new type", to: &standardError)
            print("> ", terminator: "", to: &standardError)
            fflush(stderr)
            guard let input = readLine()?.trimmingCharacters(in: .whitespaces), !input.isEmpty,
                  let choice = Int(input) else {
                print("  Please enter a valid number.", to: &standardError)
                continue
            }
            if choice >= 1 && choice <= currentConfig.meetingTypes.count {
                meetingType = currentConfig.meetingTypes[choice - 1]
                break
            } else if choice == currentConfig.meetingTypes.count + 1 {
                // Add new type
                print("New meeting type: ", terminator: "", to: &standardError)
                fflush(stderr)
                if let newType = readLine()?.trimmingCharacters(in: .whitespaces), !newType.isEmpty {
                    if !currentConfig.meetingTypes.contains(newType) {
                        currentConfig.meetingTypes.append(newType)
                        saveConfig(currentConfig)
                    }
                    meetingType = newType
                    break
                } else {
                    print("  Please enter a meeting type name.", to: &standardError)
                    continue
                }
            } else {
                print("  Please enter a valid number.", to: &standardError)
                continue
            }
        }
    }
    print("", to: &standardError)

    // Step 2: Attendees (optional, multi-select)
    var selectedAttendees: [String] = []
    // Filter out the user's own name from the selectable list
    let selectableAttendees = currentConfig.attendees.filter { $0 != currentConfig.name }

    if selectableAttendees.isEmpty {
        // Only "Others" option available
        print("Who attended? (Enter to skip)", to: &standardError)
        print("  1. Others", to: &standardError)
    } else {
        print("Who attended? (comma-separated numbers, or Enter to skip)", to: &standardError)
        for (i, a) in selectableAttendees.enumerated() {
            print("  \(i + 1). \(a)", to: &standardError)
        }
        print("  \(selectableAttendees.count + 1). Others", to: &standardError)
    }
    print("> ", terminator: "", to: &standardError)
    fflush(stderr)

    let attendeeInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
    if !attendeeInput.isEmpty {
        let choices = attendeeInput.components(separatedBy: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        let othersIndex = selectableAttendees.count + 1
        var selectedOthers = false

        for choice in choices {
            if choice >= 1 && choice <= selectableAttendees.count {
                let name = selectableAttendees[choice - 1]
                if !selectedAttendees.contains(name) {
                    selectedAttendees.append(name)
                }
            } else if choice == othersIndex {
                selectedOthers = true
            }
        }

        if selectedOthers {
            print("Other attendees (comma-separated names):", to: &standardError)
            print("> ", terminator: "", to: &standardError)
            fflush(stderr)
            let othersInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            if !othersInput.isEmpty {
                let otherNames = othersInput.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                for name in otherNames {
                    if !selectedAttendees.contains(name) {
                        selectedAttendees.append(name)
                    }
                }
            }
        }
    }
    // If attendeeInput was empty, selectedAttendees stays empty → "unspecified"
    print("", to: &standardError)

    // Step 3: Title (optional, free text)
    print("Meeting title (or Enter to skip):", to: &standardError)
    print("> ", terminator: "", to: &standardError)
    fflush(stderr)
    let titleInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
    let title: String? = titleInput.isEmpty ? nil : titleInput
    print("", to: &standardError)

    return MeetingMetadata(
        meetingType: meetingType,
        attendees: selectedAttendees,
        title: title,
        date: recordingStartTime
    )
}

func writeOutputFile(metadata: MeetingMetadata, transcript: String, config: MiclogConfig) {
    let fm = FileManager.default
    let baseDir = config.outputDir

    let isOneOnOne = metadata.meetingType.lowercased() == "1-1"
    let singleAttendee = (metadata.attendees.count == 1) ? metadata.attendees[0] : nil

    // Determine output directory
    let outputDir: String
    if isOneOnOne {
        if let attendee = singleAttendee {
            outputDir = "\(baseDir)/1-1/\(sanitizeFilename(attendee))"
        } else {
            outputDir = "\(baseDir)/1-1/others"
        }
    } else {
        outputDir = "\(baseDir)/\(sanitizeFilename(metadata.meetingType))"
    }

    // Create directory if needed
    if !fm.fileExists(atPath: outputDir) {
        do {
            try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        } catch {
            print("Error: Could not create directory \(outputDir): \(error.localizedDescription)", to: &standardError)
            return
        }
    }

    // Build filename
    let dateFmt = DateFormatter()
    dateFmt.dateFormat = "yyyyMMdd_HH:mm"
    let dateStr = dateFmt.string(from: metadata.date)

    let sanitizedType = sanitizeFilename(metadata.meetingType)
    var filename = "\(dateStr)_\(sanitizedType)"

    if isOneOnOne {
        // For 1-1s, always ignore title; use attendee name if single
        if let attendee = singleAttendee {
            filename += "_\(sanitizeFilename(attendee))"
        }
    } else {
        // For non-1-1s, append title if provided
        if let title = metadata.title {
            filename += "_\(sanitizeFilename(title))"
        }
    }
    filename += ".txt"

    let filePath = "\(outputDir)/\(filename)"

    // Build file header
    let headerDateFmt = DateFormatter()
    headerDateFmt.dateFormat = "yyyy-MM-dd h:mm a"
    let headerDateStr = headerDateFmt.string(from: metadata.date)

    let titleStr = metadata.title ?? "Unspecified"
    let typeStr = metadata.meetingType

    let attendeesStr: String
    if metadata.attendees.isEmpty {
        attendeesStr = "Unspecified"
    } else {
        var attendeeList: [String] = []
        if !config.name.isEmpty {
            attendeeList.append("\(config.name) (me)")
        }
        attendeeList.append(contentsOf: metadata.attendees)
        attendeesStr = attendeeList.joined(separator: ", ")
    }

    var content = "==============================\n"
    content += "Meeting: \(titleStr)\n"
    content += "Date: \(headerDateStr)\n"
    content += "Type: \(typeStr)\n"
    content += "Attendees: \(attendeesStr)\n"
    content += "==============================\n"

    if !transcript.isEmpty {
        content += "\n" + transcript + "\n"
    }

    // Write file
    do {
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        print("Transcript saved to: \(filePath)", to: &standardError)
    } catch {
        print("Error: Could not write file \(filePath): \(error.localizedDescription)", to: &standardError)
    }
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
    private var transcriptLines: [String] = []

    var recordingStartTime: Date? { return startTime }

    func getTranscript() -> String {
        return transcriptLines.joined(separator: "\n")
    }

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

                // Post-recording prompts and file output
                let config = loadConfig()
                if let startTime = self?.recordingStartTime,
                   let metadata = promptMeetingMetadata(config: config, recordingStartTime: startTime) {
                    let transcript = self?.getTranscript() ?? ""
                    writeOutputFile(metadata: metadata, transcript: transcript, config: config)
                }

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
                    let line = "[\(timestamp)] \(trimmed)"
                    print(line)
                    fflush(stdout)
                    transcriptLines.append(line)

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

func printUsage() {
    print("Usage: miclog [--test SECONDS] [--device NAME|NUMBER]", to: &standardError)
    print("       miclog config <subcommand>", to: &standardError)
    print("", to: &standardError)
    print("Options:", to: &standardError)
    print("  --test SECONDS       Record for specified seconds and exit", to: &standardError)
    print("  --device NAME|NUM    Use a specific audio input device", to: &standardError)
    print("  --list-devices       List available audio input devices", to: &standardError)
    print("", to: &standardError)
    printConfigUsage()
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

if args.first == "config" {
    handleConfigCommand(Array(args.dropFirst()))
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
