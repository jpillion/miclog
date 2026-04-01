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
```

### Configure
```bash
# Show current configuration
./miclog config show

# Set your name (used in meeting transcripts)
./miclog config set name "John"

# Set output directory for recordings
./miclog config set output-dir ~/recordings

# Manage meeting types
./miclog config add meeting-type "Team Meeting"
./miclog config add meeting-type "Standup"
./miclog config list meeting-types
./miclog config remove meeting-type "Standup"

# Manage attendees
./miclog config add attendee "Alice"
./miclog config list attendees

# Interactive configuration wizard
./miclog config setup
```

## Architecture

Single-file Swift CLI tool using whisper.cpp for transcription:

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
- **Post-recording prompts**: After Ctrl+C, prompts user (via stderr/stdin) for meeting type, attendees, and title. Skipped if stdin is not a terminal.
- **File output**: Writes structured transcript file with header (meeting title, date, type, attendees) to organized directory tree
- **Configuration**: JSON config file (`config.json`) next to binary, managed via CLI subcommands or interactive wizard

## File Output Structure

After recording, transcripts are saved to the configured output directory:
```
<output_dir>/<meeting type>/<filename>.txt           # General meetings
<output_dir>/1-1/<attendee name>/<filename>.txt      # 1-1 with single attendee
<output_dir>/1-1/others/<filename>.txt               # 1-1 with 0 or 2+ attendees
```

Filename format: `YYYYMMDD_HH:MM_<type>[_<title or attendee>].txt`
- Title is included for non-1-1 meetings (if provided)
- For 1-1s, attendee name is used instead of title (title always omitted from filename)

## Key Conventions

- Output: Stdout (use shell redirection to save: `./miclog > file.txt`)
- Timestamp format: `[YYYY-MM-DD HH:MM:SS]` at the start of each transcribed line
- Chunk size: 5 seconds (~800KB WAV per chunk)
- Chunks are deleted after transcription (no disk space accumulation)
- Background transcription queue processes chunks asynchronously
- Latency: ~5-10 seconds per chunk (depends on CPU speed)
- Status messages go to stderr, transcription to stdout
