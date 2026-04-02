# miclog

Real-time microphone transcription tool for macOS using whisper.cpp. Never worry about whether you have authorization to record a meeting or enable AI summaries in your meeting app again!

## Prerequisites

### 1. Install Xcode Command Line Tools
```bash
xcode-select --install
```

### 2. Install whisper.cpp
```bash
brew install whisper-cpp
# This installs the whisper-cli executable
```

### 3. Download Whisper Large Model

```bash
# Create models directory
mkdir -p .whisper-models

# Download large model (~3GB)
curl -L https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin -o .whisper-models/ggml-large-v3.bin
```

The tool will search for the model at:
- `.whisper-models/ggml-large-v3.bin` (recommended - in project directory)
- `~/.whisper/models/ggml-large-v3.bin`
- `/opt/homebrew/share/whisper-cpp/models/ggml-large-v3.bin`
- `/usr/local/share/whisper-cpp/models/ggml-large-v3.bin`

## Build

```bash
make
```

## First-Time Setup

On first launch, miclog will run an interactive setup wizard that walks you through:

1. **Your name** — used to identify you in meeting transcripts
2. **Output directory** — where transcript files are saved (e.g., `~/recordings`)
3. **Meeting types** — categories like "1-1", "Team Meeting", "Standup" (add/remove as needed)
4. **Attendees** — people you frequently meet with (add/remove as needed)

You can re-run the wizard or change settings any time:
```bash
# Re-run the full setup wizard
./miclog config setup

# Or change individual settings
./miclog config set name "John"
./miclog config set output-dir ~/recordings
./miclog config add meeting-type "Sprint Retro"
./miclog config add attendee "Alice"
./miclog config remove attendee "Bob"
./miclog config show
```

The "1-1" meeting type is always available — it's automatically added if not already in your config.

## Usage

### Basic Usage
```bash
# Transcribe to stdout until Ctrl+C
./miclog

# Transcribe for 30 seconds
./miclog --test 30

# Save to file (shell redirection)
./miclog > transcript.txt
```

### Audio Device Selection

By default, miclog records from your system's default microphone. If you're using a Bluetooth headset or other audio interface, you can select a specific input device:

```bash
# List available audio input devices
./miclog --list-devices
#   1. MacBook Pro Microphone (default)
#   2. AirPods Pro
#   3. ZoomAudioDevice

# Record from a specific device (by name or number)
./miclog --device "AirPods Pro"
./miclog --device 2

# Partial, case-insensitive matching works too
./miclog --device airpods

# Combine with other flags
./miclog --device 2 --test 30
```

The original default device is automatically restored when miclog exits.

### Post-Recording Prompts

When you stop recording (Ctrl+C or test mode ends), miclog prompts you to categorize the meeting:

**1. Meeting type** (required) — choose from your configured list or add a new type:
```
What type of meeting was this?
  1. 1-1
  2. Team Meeting
  3. Standup
  4. + Add new type
> 2
```
New types are automatically saved to your config for future use.

**2. Attendees** (optional) — select from your configured list, add others, or skip:
```
Who attended? (comma-separated numbers, or Enter to skip)
  1. Alice
  2. Bob
  3. Charlie
  4. Others
> 1,3,4
Other attendees (comma-separated names):
> Dave, Eve
```
Pressing Enter without selecting anyone records attendees as "Unspecified". Your own name (from config) is always included automatically.

**3. Meeting title** (optional) — give the recording a descriptive name:
```
Meeting title (or Enter to skip):
> Q2 Planning Review
```

These prompts are skipped automatically when stdin is not a terminal (e.g., piped usage).

### Output Files

Transcripts are saved as structured text files with a header and organized into directories by meeting type.

**File header:**
```
==============================
Meeting: Q2 Planning Review
Date: 2026-04-01 2:03 PM
Type: Team Meeting
Attendees: John (me), Alice, Charlie, Dave, Eve
==============================

[2026-04-01 14:03:22] So as I was saying about the quarterly...
[2026-04-01 14:03:27] I think we need to revisit the timeline...
```

**Directory structure:**
```
~/recordings/
  Team Meeting/
    20260401_14:03_Team Meeting_Q2 Planning Review.txt
  Standup/
    20260401_09:00_Standup.txt
  1-1/
    Alice/
      20260401_10:00_1-1_Alice.txt
    others/
      20260402_15:30_1-1.txt
```

**Filename format:** `YYYYMMDD_HH:MM_<type>[_<suffix>].txt`

**Special 1-1 behavior:**
- If the meeting type is "1-1" and exactly one attendee is selected, the transcript is saved in a subdirectory named after that person (e.g., `1-1/Alice/`), and the filename uses their name instead of the title.
- If the meeting is a 1-1 with zero, two or more attendees, or attendees are unspecified, it goes into `1-1/others/`.
- The meeting title is **never** included in the filename for 1-1 meetings (it's still recorded in the file header).

### More Examples

```bash
# Basic transcription to terminal
./miclog

# Save to file
./miclog >> daily_log.txt

# Test mode (exit after 5 seconds)
./miclog --test 5

# Output to both console AND file (live viewing while saving)
./miclog 2>&1 | tee -a ~/miclog.txt

# Record from Bluetooth headset for 30 seconds
./miclog --device airpods --test 30
```

### Example Output

```
[2026-03-09 15:05:03] Okay, I am now testing audio transcription.
[2026-03-09 15:05:08] I'm waiting for it to print something to the screen.
[2026-03-09 15:05:13] I cannot believe this is working.
```

Each line shows a timestamp followed by the transcribed text from that 5-second audio chunk.

## How It Works

1. Records audio in 5-second chunks (WAV format, 16kHz) from the selected input device
2. Transcribes each chunk with whisper.cpp (large model)
3. Streams transcription to stdout as chunks complete
4. ~5-10 second latency per chunk (recording + transcription time)
5. Temporary chunk files are automatically cleaned up
6. On exit, prompts for meeting metadata and saves a structured transcript file

## Performance

- **Latency**: ~5-10 seconds per chunk (depends on CPU)
- **Accuracy**: High (large model)
- **Disk space**: Minimal (chunks deleted after transcription)
- **Memory**: ~1-2GB (model loaded in memory)

Large model transcription is CPU-intensive (~1x realtime on modern Macs). For faster results, consider using a smaller model by editing the `modelPath` search in `main.swift`.

## Troubleshooting

### "whisper-cli not found"
Install with: `brew install whisper-cpp` (this installs the `whisper-cli` executable)

Verify installation: `which whisper-cli` should show `/opt/homebrew/bin/whisper-cli`

### "Model not found"
Download the large model (see Prerequisites above). The tool searches multiple locations automatically.

### "Permission denied"
It should prompt for for this automatically on first run. Allow microphone access in **System Settings → Privacy & Security → Microphone**

### Slow transcription
The large model is slow but accurate. For faster results:
1. Download a smaller model (medium, small, or base)
2. Update the search paths in `main.swift` to use the smaller model
3. Or edit `findModelPath()` to return your preferred model path

### No output appearing
- Status messages go to stderr, transcription to stdout
- Redirect stderr to see status: `./miclog 2> status.log`
- Or combine: `./miclog > transcript.txt 2> status.log`

## Technical Details

- **Audio format**: 16kHz WAV, mono, 16-bit PCM
- **Chunk size**: 5 seconds (~800KB per chunk)
- **Chunk location**: `/tmp/miclog_chunk_*.wav`
- **Model**: Whisper large (~3GB)
- **Output**: Stdout (status messages to stderr)

## Development

See [CLAUDE.md](CLAUDE.md) for development commands and architecture details.
