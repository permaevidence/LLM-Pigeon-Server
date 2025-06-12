# LLM Pigeon Server

A macOS companion app for [Pigeon Chat](https://github.com/permaevidence/LLM-Pigeon) that provides AI assistant functionality. This server app monitors CloudKit for new messages and processes them using your choice of local LLM providers.

## Overview

LLM Pigeon Server acts as the backend for the Pigeon Chat iOS app, enabling:
- 🤖 Local AI processing using multiple LLM providers
- ☁️ CloudKit synchronization with iOS devices
- 🔄 Automatic message processing via push notifications
- 💻 Support for LM Studio, Ollama, and built-in models

## Architecture

```
┌─────────────────┐         ┌──────────────────┐
│  iOS App        │ CloudKit│  macOS Server    │
│  (Pigeon Chat)  │◄────────►  (LLM Pigeon)    │
│                 │         │                  │
│  User sends     │         │  Processes with  │
│  message        │         │  Local LLM       │
└─────────────────┘         └──────────────────┘
```

## Requirements

- macOS 13.0+
- Xcode 14.0+
- Active Apple Developer account (for CloudKit)
- iCloud account (same as iOS device)
- One of the following LLM providers:
  - [LM Studio](https://lmstudio.ai)
  - [Ollama](https://ollama.ai)
  - Built-in model (downloads ~800MB)

## Installation

### 1. Clone the Repository
```bash
git clone https://github.com/permaevidence/LLM-Pigeon-Server.git
cd llm-pigeon-server
```

### 2. Configure CloudKit

**Important**: Use the SAME CloudKit container as your iOS app!

1. Open the project in Xcode
2. Select your development team
3. The bundle identifier can be different from iOS (e.g., `com.yourcompany.pigeonserver`)
4. But the CloudKit container MUST be the same: `iCloud.com.pigeonchat.pigeonchat`

### 3. Enable Capabilities in Xcode

1. Select your project → Target → "Signing & Capabilities"
2. Ensure these capabilities are enabled:
   - **CloudKit** (using the same container as iOS)
   - **Push Notifications**
   - **App Sandbox** with:
     - Network: Client & Server
     - File Access: User Selected Files (Read Only)

### 4. Choose Your LLM Provider

#### Option A: LM Studio (Recommended)
1. Download [LM Studio](https://lmstudio.ai)
2. Download a model (e.g., Llama 3, Mistral, or any GGUF model)
3. Start the local server in LM Studio (default port: 1234)
4. Note your model name from the server tab

#### Option B: Ollama
1. Install Ollama: `curl -fsSL https://ollama.ai/install.sh | sh`
2. Pull a model: `ollama pull llama3`
3. Start Ollama (it runs automatically on port 11434)

#### Option C: Built-in Model
1. Select "Built-in" in the app
2. Click "Download Model" (downloads Qwen 0.6B, ~800MB)
3. Click "Load Model" when download completes

## Setup Instructions

### First-Time Setup

1. **Ensure both apps use the same iCloud account**
2. **Start the macOS server app first**
3. **Verify CloudKit status shows "Connected"**
4. **Select and configure your LLM provider**
5. **Verify LLM status shows "Connected"**
6. **Keep the macOS app running in the background**

### Testing the Connection

1. Open Pigeon Chat on your iOS device
2. Start a new conversation
3. Send a message
4. Within seconds, you should see:
   - The conversation ID appear in "Active conversations" on macOS
   - Activity in the macOS app's log
   - An AI response appear in your iOS app

## Features

### Supported LLM Providers

| Provider | Port | Notes |
|----------|------|-------|
| LM Studio | 1234 (configurable) | Supports any GGUF model |
| Ollama | 11434 (fixed) | Supports Ollama's model library |
| Built-in | N/A | Qwen 0.6B, runs entirely offline |

### CloudKit Sync

- Automatic sync via push notifications
- Fallback polling every 15 seconds
- Processes only conversations marked as "needsResponse"

### Security & Privacy

- All processing happens locally on your Mac
- No data is sent to external servers
- CloudKit data is encrypted and private to your iCloud account

## Troubleshooting

### "LLM Provider: Not connected"
- **LM Studio**: Ensure server is running (look for "Server started" in LM Studio)
- **Ollama**: Check if Ollama is running: `ollama list`
- **Built-in**: Make sure model is downloaded AND loaded

### "No conversations appearing"
1. Verify both apps use the same iCloud account
2. Check CloudKit Dashboard for your container
3. Ensure push notifications are enabled
4. Try sending a new message from iOS

### "Processing gets stuck"
- Check the activity log for errors
- Restart the macOS app
- Verify your LLM provider is responding

## Development

### CloudKit Schema

The app shares the same CloudKit schema as the iOS app:

**Record Type:** `Conversation`
- `conversationData` (Bytes) - JSON encoded conversation
- `lastUpdated` (Date/Time)
- `needsResponse` (Int64) - 1 = needs processing, 0 = processed

### How It Works

1. iOS app creates/updates a conversation with `needsResponse = 1`
2. CloudKit sends push notification to macOS app
3. macOS app fetches the conversation
4. Processes the last message with selected LLM
5. Appends AI response and sets `needsResponse = 0`
6. iOS app receives update via CloudKit

## Building for Distribution

1. Archive the app in Xcode
2. Choose "Developer ID" for distribution outside the App Store
3. Notarize the app for Gatekeeper approval
4. Create a DMG for easy distribution

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Related Projects

- [Pigeon Chat (iOS)](https://github.com/permaevidence/LLM-Pigeon) - The iOS client app
- [LLM.swift](https://github.com/eastriverlee/LLM.swift) - Built-in model support

## License

This project is available under the MIT License. See the LICENSE file for more info.

## Acknowledgments

- Built with SwiftUI and CloudKit
- LLM.swift for built-in model support
- Compatible with LM Studio and Ollama

## Contact

Your Name - [@your_twitter](https://twitter.com/your_twitter)

Project Link: [https://github.com/permaevidence/LLM-Pigeon-Server](https://github.com/permaevidence/LLM-Pigeon-Server)