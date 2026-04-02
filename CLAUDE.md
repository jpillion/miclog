# CLAUDE.md

Experimental project to transcribe audio from the macOS microphone into a text file for AI summarization. 

## Milestones

1. ✅ Write a command line tool to listen to the mic audio and record it to a file.
2. ✅ Add text to speech transcription to a text file, and stream the text file output as the command is running.
3. ✅ Instead of taking a file name, write the transcript text to stdout. Add the test text output files to gitignore. 

## Development Commands

### Setup
```bash
# Requires Xcode Command Line Tools
xcode-select --install

# Install whisper.cpp (provides whisper-cli executable)
brew install whisper-cpp

# Download Whisper large model (~3GB)
mkdir -p .whisper-models
curl -L https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin -o .whisper-models/ggml-large-v3.bin

# Note: Microphone permission will be requested on first run
# See README.md for detailed setup instructions
```

### Build
```bash
make
```

### Test
```bash
# Test mode - transcribe for 10 seconds (output to stdout)
./miclog --test 10

# Or save to file with redirection
./miclog --test 10 > test.txt
cat test.txt
```

### Lint/Format
```bash
# [Add linting/formatting commands]
```

### Run
```bash
# Transcribe to stdout until Ctrl+C
./miclog

# Save to file with redirection
./miclog > transcript.txt

# Test mode - transcribe for 30 seconds
./miclog --test 30

# Pipe to other commands
./miclog | grep "important"

# Append to existing file
./miclog >> daily_log.txt

# List available audio input devices
./miclog --list-devices

# Record from a specific device (by name or number)
./miclog --device "AirPods Pro"
./miclog --device 2
```

## Architecture

Single-file Swift CLI tool using whisper.cpp for transcription:

- **CoreAudio**: Enumerates audio input devices and allows selecting a specific device via `--device`
- **AVFoundation**: AVAudioRecorder captures microphone input in 5-second chunks
- **Chunked Recording**: Records to temporary WAV files in `/tmp/`
- **whisper.cpp Integration**: Shells out to whisper.cpp to transcribe each chunk
- **Real-time streaming**: Transcription results stream to stdout as chunks complete
- **Signal handling**: DispatchSource handles Ctrl+C for graceful shutdown
- **Transcription modes**:
  - Interactive mode: Transcribe until Ctrl+C
  - Test mode: Auto-stop after specified duration
- **Audio format**: 16kHz WAV, mono, 16-bit PCM (optimal for Whisper)
- **Model**: Whisper large (~3GB, high accuracy)
- **Output**: Stdout with timestamps (stderr for status messages)

## Key Conventions

- Output: Stdout (use shell redirection to save: `./miclog > file.txt`)
- Timestamp format: `[YYYY-MM-DD HH:MM:SS]` at the start of each transcribed line
- Chunk size: 5 seconds (~800KB WAV per chunk)
- Chunks are deleted after transcription (no disk space accumulation)
- Background transcription queue processes chunks asynchronously
- Latency: ~5-10 seconds per chunk (depends on CPU speed)
- Status messages go to stderr, transcription to stdout
