//
//  Pigeon_ServerApp.swift
//  Pigeon Server
//
//  Created by matteo ianni on 06/06/25.
//

//  PigeonServer_macOS.swift
//  Pigeon Server – macOS companion (server)
//  Updated June 2025 – Fixed shared instance, improved concurrency safety

import SwiftUI
import CloudKit
import Combine // For @AppStorage and Timers
import LLM // New import for built-in model support

// MARK: - Shared Models (Ensure these are identical to iOS app's models)
struct Message: Identifiable, Codable {
    let id: UUID // Changed from 'let id = UUID()' to ensure it's decoded if present
    let role: String // "user" | "assistant"
    let content: String
    let timestamp: Date

    // Custom initializer for programmatic creation, ensuring an ID is always set
    init(id: UUID = UUID(), role: String, content: String, timestamp: Date) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        // Optional: print("[Message Programmatic Init] ID: \(self.id.uuidString.prefix(8))")
    }

    // Explicit Codable conformance to be certain about id handling
    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp
    }

    // Decoder: If 'id' is missing in JSON, generate a new one.
    // This was likely the behavior with 'let id = UUID()', making IDs unstable if not in JSON.
    // By making 'id' non-optional and decoding it, we force it to be in the JSON.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Try to decode 'id'. If it's not in the JSON, this will fail, which is good
        // because it means our JSONEncoder isn't saving it.
        // If it IS in the JSON, it will be used.
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(String.self, forKey: .role)
        self.content = try container.decode(String.self, forKey: .content)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        // Optional: print("[Message Decoded] ID: \(self.id.uuidString.prefix(8)) from JSON")
    }

    // Encoder: Ensure 'id' is always encoded.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.role, forKey: .role)
        try container.encode(self.content, forKey: .content)
        try container.encode(self.timestamp, forKey: .timestamp)
    }
}

struct Conversation: Codable, Identifiable {
    var id: String
    var messages: [Message]
    var lastUpdated: Date
}

// MARK: - LLM Provider Types
enum LLMProvider: String, CaseIterable {
    case builtIn = "Built-in"
    case lmstudio = "LM Studio"
    case ollama = "Ollama"
}

// MARK: - Unified LLM Client Protocol
protocol LLMClient {
    func ping() async -> Bool
    func sendChat(messages: [Message]) async throws -> String
    var statusDescription: String { get }
}

// MARK: - Built-in (GGUF) Client
// MARK: - Built-in (GGUF) Client
final class LocalModelClient: LLMClient {
    private var bot: LLM?
    private let modelFileName = "Qwen3-0.6B-Q4_K_M.gguf"
    private let modelURL = "https://huggingface.co/Qwen/Qwen2-0.5B-Instruct-GGUF/resolve/main/qwen2-0_5b-instruct-q4_k_m.gguf"

    private var localModelURL: URL {
        let documentsPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = documentsPath.appendingPathComponent("PigeonServer", isDirectory: true)
        return appFolder.appendingPathComponent(modelFileName)
    }
    
    var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: localModelURL.path)
    }
    
    // +++ NEW +++
    var isModelLoaded: Bool {
        bot != nil
    }

    // --- MODIFIED ---
    // The initializer no longer tries to load the model automatically.
    init() throws {
        // Create app folder if needed
        let appFolder = localModelURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        
        // We no longer load the model on init. We just check for its existence.
    }
    
    enum ModelError: LocalizedError {
        case notDownloaded
        case notLoaded // +++ NEW +++
        case downloadFailed(String)
        case loadFailed(String) // +++ NEW +++
        
        var errorDescription: String? {
            switch self {
            case .notDownloaded:
                return "Model not downloaded yet"
            case .notLoaded: // +++ NEW +++
                return "Model is downloaded but not loaded into memory."
            case .downloadFailed(let reason):
                return "Download failed: \(reason)"
            case .loadFailed(let reason): // +++ NEW +++
                return "Failed to load model: \(reason)"
            }
        }
    }
    
    // --- MODIFIED ---
    // Made public so CloudKitManager can call it.
    func loadModel() async throws {
        guard isModelDownloaded else { throw ModelError.notDownloaded }
        do {
            self.bot = try await LLM(
                from: localModelURL,
                template: .chatML("You are a helpful Mac assistant.")
            )
        } catch {
            // Pass the underlying error for better debugging.
            throw ModelError.loadFailed(error.localizedDescription)
        }
    }

    // +++ NEW +++
    // New function to unload the model and free up memory.
    func unloadModel() {
        self.bot = nil
        // LLM.swift should handle memory deallocation automatically when bot is nil.
    }
    
    // --- MODIFIED ---
    // Removed the automatic call to loadModel() at the end.
    func downloadModel(progress: @escaping (Double) -> Void) async throws {
        guard let url = URL(string: modelURL) else {
            throw ModelError.downloadFailed("Invalid URL")
        }
        
        let session = URLSession(configuration: .default)
        let (asyncBytes, response) = try await session.bytes(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ModelError.downloadFailed("Server error")
        }
        
        let contentLength = httpResponse.expectedContentLength
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        
        let fileHandle = try FileHandle(forWritingTo: tempURL)
        defer { try? fileHandle.close() }
        
        var bytesReceived: Int64 = 0
        var buffer = Data()
        let bufferSize = 1024 * 1024
        
        for try await byte in asyncBytes {
            buffer.append(byte)
            bytesReceived += 1
            
            if buffer.count >= bufferSize {
                fileHandle.write(buffer)
                buffer.removeAll(keepingCapacity: true)
                
                if contentLength > 0 {
                    let percentage = Double(bytesReceived) / Double(contentLength)
                    await MainActor.run {
                        progress(percentage)
                    }
                }
            }
        }
        
        if !buffer.isEmpty {
            fileHandle.write(buffer)
        }
        
        try? FileManager.default.removeItem(at: localModelURL)
        try FileManager.default.moveItem(at: tempURL, to: localModelURL)
        
        // --- REMOVED ---
        // We no longer automatically load the model after download.
        // try await loadModel()
    }
    
    // LLMClient
    var statusDescription: String { "Built-in (Qwen 0.6B)" }
    
    // --- MODIFIED ---
    // ping() now correctly reflects if the model is loaded, not just downloaded.
    func ping() async -> Bool { isModelLoaded }
    
    func sendChat(messages: [Message]) async throws -> String {
        // --- MODIFIED ---
        // The error is now more specific if the model is downloaded but not loaded.
        guard let bot = bot else {
            if isModelDownloaded {
                throw ModelError.notLoaded
            } else {
                throw ModelError.notDownloaded
            }
        }

        let history: [Chat] = messages.dropLast().map { msg in
            (msg.role == "user" ? .user : .bot, msg.content)
        }

        guard let last = messages.last, last.role == "user" else {
            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey:
                                               "Conversation must end with a user message"])
        }

        let prompt = bot.preprocess(last.content, history)
        let raw = await bot.getCompletion(from: prompt)

        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - LM Studio Client
final class LMStudioClient: LLMClient {
    @AppStorage("lmstudioPort") private var port: Int = 1234
    @AppStorage("lmstudioModel") private var modelName: String = "local-model"
    private var baseURL: URL { URL(string: "http://localhost:\(port)/v1")! }
    
    var statusDescription: String {
        "LM Studio (port \(port))"
    }

    func ping() async -> Bool {
        let url = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (_, rsp) = try await URLSession.shared.data(for: request)
            return (rsp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    func sendChat(messages: [Message]) async throws -> String {
        struct OAIMsg: Codable { let role, content: String }
        struct Req: Codable { let model: String; let messages: [OAIMsg]; let temperature: Double = 0.7; let max_tokens: Int = 2000 }
        struct Resp: Codable { struct Choice: Codable { struct Msg: Codable { let role, content: String }; let message: Msg }; let choices: [Choice] }
        
        let url = baseURL.appendingPathComponent("chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let oaiMessages = messages.map { OAIMsg(role: $0.role, content: $0.content) }
        let body = Req(model: modelName, messages: oaiMessages)
        req.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: req)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "No response body"
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "LM Studio server error. Status: \((response as? HTTPURLResponse)?.statusCode ?? 0). Body: \(responseBody)"])
        }

        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            logToManager("[LM Studio] No content in response choices. Full response: \(String(data: data, encoding: .utf8) ?? "")")
            throw URLError(.cannotParseResponse)
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func logToManager(_ msg: String) {
        Task { @MainActor in CloudKitManager.shared.log(msg) }
    }
}

// MARK: - Ollama Client
final class OllamaClient: LLMClient {
    @AppStorage("ollamaModel") private var modelName: String = "llama3"
    private let baseURL = URL(string: "http://localhost:11434/v1")!
    
    var statusDescription: String {
        "Ollama (port 11434)"
    }

    func ping() async -> Bool {
        let url = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("ollama", forHTTPHeaderField: "Authorization") // Dummy API key
        do {
            let (_, rsp) = try await URLSession.shared.data(for: request)
            return (rsp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    func sendChat(messages: [Message]) async throws -> String {
        struct OAIMsg: Codable { let role, content: String }
        struct Req: Codable { let model: String; let messages: [OAIMsg]; let temperature: Double = 0.7; let max_tokens: Int = 2000 }
        struct Resp: Codable { struct Choice: Codable { struct Msg: Codable { let role, content: String }; let message: Msg }; let choices: [Choice] }
        
        let url = baseURL.appendingPathComponent("chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer ollama", forHTTPHeaderField: "Authorization") // Dummy API key required by SDK format
        
        let oaiMessages = messages.map { OAIMsg(role: $0.role, content: $0.content) }
        let body = Req(model: modelName, messages: oaiMessages)
        req.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: req)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "No response body"
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Ollama server error. Status: \((response as? HTTPURLResponse)?.statusCode ?? 0). Body: \(responseBody)"])
        }

        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            logToManager("[Ollama] No content in response choices. Full response: \(String(data: data, encoding: .utf8) ?? "")")
            throw URLError(.cannotParseResponse)
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func logToManager(_ msg: String) {
        Task { @MainActor in CloudKitManager.shared.log(msg) }
    }
}

// MARK: - CloudKit manager (shared singleton)
@MainActor
final class CloudKitManager: NSObject, ObservableObject {
    static let shared = CloudKitManager()
    
    private static let containerID = "iCloud.com.pigeonchat.pigeonchat"
    private let macOSConversationSubscriptionID = "macOSConversationNeedsResponse_v2"

    private let container: CKContainer
    let db: CKDatabase
    
    // LLM Clients
    private let lmStudioClient = LMStudioClient()
    private let ollamaClient = OllamaClient()
    private var localClient: LocalModelClient?
    
    @AppStorage("selectedProvider") var selectedProvider: String = LLMProvider.lmstudio.rawValue
    @AppStorage("lmstudioModel") var lmStudioModelName: String = "local-model"
    @AppStorage("ollamaModel") var ollamaModelName: String = "llama3"
    
    var currentClient: LLMClient {
        switch selectedProvider {
        case LLMProvider.ollama.rawValue:
            return ollamaClient
        case LLMProvider.builtIn.rawValue:
            return localClient ?? lmStudioClient // Fallback to LM Studio if built-in fails
        default:
            return lmStudioClient
        }
    }
    
    var currentModelName: String {
        switch selectedProvider {
        case LLMProvider.ollama.rawValue:
            return ollamaModelName
        case LLMProvider.builtIn.rawValue:
            return "Qwen 0.6B"
        default:
            return lmStudioModelName
        }
    }

    @Published var llmStatus = "Checking…"
    @Published var cloudKitAccountStatus = "Checking..."
    @Published var processingIDs: Set<String> = []
    @Published var log: [String] = []
    @Published var builtInModelStatus = "Checking..."
    @Published var downloadProgress: Double = 0.0
    @Published var isDownloading = false
    @Published var isLoadingModel = false

    private var cancellables = Set<AnyCancellable>()

    private override init() {
        container = CKContainer(identifier: CloudKitManager.containerID)
        db = container.privateCloudDatabase
        super.init()
        Task {
            await initializeBuiltInModel()
            await refreshCloudKitStatus()
            await ensureSubscription()
            await updateLLMStatus()
            await checkForPending(reason: "Initial Check")
        }
        startTimers()
    }
    
    private func initializeBuiltInModel() async {
        do {
            localClient = try LocalModelClient()
            if localClient?.isModelDownloaded == true {
                builtInModelStatus = "Downloaded (Unloaded)" // New state
                log("[Built-in] Model is downloaded and ready to be loaded.")
            } else {
                builtInModelStatus = "Not downloaded"
                log("[Built-in] Model needs to be downloaded")
            }
        } catch {
            builtInModelStatus = "Failed to initialize"
            log("[Built-in] Failed to initialize: \(error.localizedDescription)")
        }
    }
    
    func downloadBuiltInModel() async {
        guard !isDownloading else { return }
        guard let client = localClient else {
            log("[Built-in] No client available for download")
            return
        }
        
        isDownloading = true
        downloadProgress = 0.0
        builtInModelStatus = "Downloading..."
        log("[Built-in] Starting model download...")
        
        do {
            try await client.downloadModel { progress in
                Task { @MainActor in
                    self.downloadProgress = progress
                    self.builtInModelStatus = "Downloading... \(Int(progress * 100))%"
                }
            }
            
            builtInModelStatus = "Downloaded (Unloaded)" // New state
            isDownloading = false
            log("[Built-in] Model downloaded successfully.")
            
            await updateLLMStatus()
        } catch {
            builtInModelStatus = "Download failed"
            isDownloading = false
            log("[Built-in] Download failed: \(error.localizedDescription)")
        }
    }
    
    func loadBuiltInModel() async {
        guard let client = localClient else { return }
        
        isLoadingModel = true
        builtInModelStatus = "Loading..."
        log("[Built-in] Loading model into memory...")
        
        do {
            try await client.loadModel()
            builtInModelStatus = "Ready (Loaded)"
            log("[Built-in] Model loaded successfully.")
        } catch {
            builtInModelStatus = "Failed to load"
            log("[Built-in] Failed to load model: \(error.localizedDescription)")
        }
        
        isLoadingModel = false
        await updateLLMStatus()
    }

    // +++ NEW +++
    func unloadBuiltInModel() async {
        guard let client = localClient else { return }
        
        client.unloadModel()
        builtInModelStatus = "Downloaded (Unloaded)"
        log("[Built-in] Model unloaded from memory.")
        await updateLLMStatus()
    }

    private func startTimers() {
        Timer.publish(every: 15, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { await self?.checkForPending(reason: "Timer Poll") }
        }.store(in: &cancellables)
        
        Timer.publish(every: 10, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { await self?.updateLLMStatus() }
        }.store(in: &cancellables)
    }

    func log(_ msg: String) {
        let ts = DateFormatter.localizedString(from: .now, dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(ts)] \(msg)"
        print(logEntry)
        if log.count >= 200 { log.removeFirst(log.count - 199) }
        log.append(logEntry)
    }
    
    private func refreshCloudKitStatus() async {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available: cloudKitAccountStatus = "Connected"
            case .noAccount: cloudKitAccountStatus = "No iCloud Account"
            case .restricted: cloudKitAccountStatus = "iCloud Account Restricted"
            case .couldNotDetermine: cloudKitAccountStatus = "Could Not Determine iCloud Status"
            @unknown default: cloudKitAccountStatus = "Unknown iCloud Status"
            }
            log("[macOS] CloudKit Account Status: \(cloudKitAccountStatus)")
        } catch {
            cloudKitAccountStatus = "Error Checking Status"
            log("[macOS] Error refreshing CloudKit account status: \(error.localizedDescription)")
        }
    }

    private func ensureSubscription() async {
        do {
            let existingSubscription = try await db.subscription(for: macOSConversationSubscriptionID)
            log("[macOS] Subscription '\(macOSConversationSubscriptionID)' already exists. Type: \(type(of: existingSubscription))")
            return
        } catch let error as CKError where error.code == .unknownItem {
            log("[macOS] Subscription '\(macOSConversationSubscriptionID)' not found (CKError.unknownItem). Will attempt to create.")
            // Fall through to creation logic
        } catch let error as CKError {
            let errorCode = error.errorCode
            let errorDescription = error.localizedDescription
            log("[macOS] CKError checking for subscription '\(macOSConversationSubscriptionID)': \(errorDescription) (Code: \(errorCode)). Full Details: \(error). Will NOT attempt to create.")
            // Optionally update some UI state if this is critical
            return // Do not proceed
        } catch {
            log("[macOS] An unexpected error occurred while checking for subscription '\(macOSConversationSubscriptionID)': \(error.localizedDescription). Full Details: \(error). Will NOT attempt to create.")
            return // Do not proceed
        }

        log("[macOS] Attempting to create subscription '\(macOSConversationSubscriptionID)' because it was not found.")
        let predicate = NSPredicate(format: "needsResponse == 1") // macOS listens for records needing a response
        
        let subscription = CKQuerySubscription(recordType: "Conversation",
                                               predicate: predicate,
                                               subscriptionID: macOSConversationSubscriptionID,
                                               options: [.firesOnRecordCreation, .firesOnRecordUpdate])

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        // notificationInfo.alertBody = "macOS: Conversation needs processing!" // For debug
        subscription.notificationInfo = notificationInfo

        do {
            let savedSubscription = try await db.save(subscription)
            log("[macOS] Successfully saved new subscription '\(savedSubscription.subscriptionID)'. Type: \(type(of: savedSubscription))")
        } catch let error as CKError {
            let errorCode = error.errorCode
            let errorDescription = error.localizedDescription
            log("[macOS] Failed to save subscription '\(macOSConversationSubscriptionID)': \(errorDescription) (Code: \(errorCode)). Full Details: \(error)")
            // Update UI or state to reflect this failure
        } catch {
            log("[macOS] An unexpected error occurred while saving subscription '\(macOSConversationSubscriptionID)': \(error.localizedDescription). Full Details: \(error)")
            // Update UI or state
        }
    }
    
    func updateLLMStatus() async {
        let wasConnected = llmStatus == "Connected"
        let providerName = currentClient.statusDescription
        var isConnected = false
        
        if selectedProvider == LLMProvider.builtIn.rawValue {
            // For built-in, "Connected" means the model is loaded in memory.
            isConnected = localClient?.isModelLoaded ?? false
            llmStatus = isConnected ? "Connected" : "Not Connected"
        } else {
            isConnected = await currentClient.ping()
            llmStatus = isConnected ? "Connected" : "Not connected – start \(selectedProvider) server"
        }
        
        if wasConnected != isConnected {
             log("[\(providerName)] Status changed to: \(llmStatus)")
        }
    }

    private func checkForPending(reason: String) async {
        log("[macOS] Checking for pending conversations (Reason: \(reason))...")
        let predicate = NSPredicate(format: "needsResponse == 1")
        let query = CKQuery(recordType: "Conversation", predicate: predicate)
        
        do {
            let (matchResults, _) = try await db.records(matching: query) // CKDatabase.records(matching: CKQuery)
            if matchResults.isEmpty {
                return
            }
            
            log("[macOS] Found \(matchResults.count) potential records to process.")
            for (recordID, result) in matchResults {
                switch result {
                case .success(let record):
                    if !processingIDs.contains(recordID.recordName) {
                        log("[macOS] Adding \(recordID.recordName.prefix(8)) to processing queue.")
                        Task.detached {
                            await self.handle(record: record)
                        }
                    } else {
                        log("[macOS] Record \(recordID.recordName.prefix(8)) is already being processed.")
                    }
                case .failure(let error):
                    log("[macOS] Error fetching a specific record \(recordID.recordName.prefix(8)) during pending check: \(error.localizedDescription)")
                }
            }
        } catch {
            log("[macOS] Query error during checkForPending: \(error.localizedDescription)")
        }
    }

    private func handle(record: CKRecord) async {
        let recordIDString = record.recordID.recordName
        
        await MainActor.run {
            guard !processingIDs.contains(recordIDString) else {
                log("[macOS] Handle called for \(recordIDString.prefix(8)), but already in processingIDs. Skipping.")
                return
            }
            processingIDs.insert(recordIDString)
        }
        
        defer {
            Task { @MainActor in
                self.processingIDs.remove(recordIDString)
                self.log("[macOS] Finished processing \(recordIDString.prefix(8)). Removed from queue.")
            }
        }
        
        log("[macOS] Handling record: \(recordIDString.prefix(8))")
        guard let blob = record["conversationData"] as? Data,
              let needsResponseFlag = record["needsResponse"] as? NSNumber, needsResponseFlag.boolValue == true else {
            log("[macOS] Record \(recordIDString.prefix(8)) data is invalid or needsResponse is not 1. Skipping.")
            return
        }
        
        do {
            var conv = try JSONDecoder().decode(Conversation.self, from: blob)
            let providerName = currentClient.statusDescription
            log("[macOS] Processing \(conv.id.prefix(8)) with \(conv.messages.count) messages for \(providerName)...")
            
            let assistantReplyContent = try await currentClient.sendChat(messages: conv.messages)
            let assistantMessage = Message(role: "assistant", content: assistantReplyContent, timestamp: .now)
            
            conv.messages.append(assistantMessage)
            conv.lastUpdated = .now
            
            log("[macOS] \(providerName) replied for \(conv.id.prefix(8)). Saving to CloudKit...")
            try await saveUpdatedConversation(conv, originalRecord: record) // Pass the original record
            log("[macOS] Successfully replied and saved for \(conv.id.prefix(8))")
            
        } catch {
            log("[macOS] Error during handle for \(recordIDString.prefix(8)): \(error.localizedDescription). Full error: \(error)")
        }
    }

    private func saveUpdatedConversation(_ conv: Conversation, originalRecord: CKRecord) async throws {
        log("[macOS] Attempting to save updated conversation \(conv.id.prefix(8))")
        
        let recordToSave: CKRecord
        var recordFetchedForUpdate = false

        do {
            let latestRecordFromServer = try await db.record(for: originalRecord.recordID) // CKDatabase.record(for: CKRecord.ID)
            recordToSave = latestRecordFromServer
            recordFetchedForUpdate = true
            log("[macOS] Fetched latest version of record \(conv.id.prefix(8)) for save. Server ChangeTag: \(latestRecordFromServer.recordChangeTag ?? "nil")")
        } catch let error as CKError where error.code == .unknownItem {
            log("[macOS] Original record \(conv.id.prefix(8)) not found when fetching latest for update. Proceeding with initially provided record.")
            recordToSave = originalRecord // Fallback: use the record that was passed in
        }
        // Other CKError or general errors during fetch will propagate up

        let jsonData = try JSONEncoder().encode(conv)
        recordToSave["conversationData"] = jsonData as CKRecordValue
        recordToSave["lastUpdated"] = conv.lastUpdated as CKRecordValue
        recordToSave["needsResponse"] = NSNumber(value: Int64(0)) as CKRecordValue

        do {
            // db.save(CKRecord) implicitly uses recordToSave.recordChangeTag for optimistic locking
            _ = try await db.save(recordToSave) // CKDatabase.save(CKRecord)
            log("[macOS] Successfully saved updated record \(conv.id.prefix(8)) to CloudKit. RecordChangeTag after save: \(recordToSave.recordChangeTag ?? "nil")")
        } catch let error as CKError where error.code == .serverRecordChanged {
            log("[macOS] Save failed for \(conv.id.prefix(8)): Server record changed during processing. Record fetched for update was \(recordFetchedForUpdate). CKError: \(error.localizedDescription)")
            throw error
        } catch {
            log("[macOS] Error saving updated conversation \(conv.id.prefix(8)) to CloudKit: \(error.localizedDescription)")
            throw error
        }
    }

    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) {
        log("[macOS] Received remote notification.")
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            log("[macOS] Failed to parse CKNotification from userInfo.")
            return
        }

        guard notification.subscriptionID == macOSConversationSubscriptionID,
              let queryNotification = notification as? CKQueryNotification,
              let recordID = queryNotification.recordID else {
            log("[macOS] Notification is not for our subscription or not a query notification with recordID. SubID: \(notification.subscriptionID ?? "N/A")")
            return
        }
        
        log("[macOS] Handling remote notification for record: \(recordID.recordName.prefix(8)), Reason: \(queryNotification.queryNotificationReason.rawValue). Triggering check for pending.")
        Task {
            await checkForPending(reason: "Push Notification for \(recordID.recordName.prefix(8))")
        }
    }
}

// MARK: - UI
struct ContentView: View {
    @ObservedObject private var cloud = CloudKitManager.shared
    @AppStorage("lmstudioPort") private var port: Int = 1234
    @AppStorage("selectedProvider") private var selectedProvider: String = LLMProvider.lmstudio.rawValue

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pigeon Server").font(.largeTitle).bold()
                StatusRow(title: "CloudKit", status: "Connected", color: .green)
                StatusRow(title: "LLM Provider", status: cloud.llmStatus, color: cloud.llmStatus == "Connected" ? .green : .red)
                StatusRow(title: "Processing", status: cloud.processingIDs.isEmpty ? "Idle" : "Active", color: cloud.processingIDs.isEmpty ? .gray : .orange)
                Divider()
                
                // Provider Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("LLM Provider:").font(.headline)
                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(LLMProvider.allCases, id: \.rawValue) { provider in
                            Text(provider.rawValue).tag(provider.rawValue)
                        }
                    }
                    .pickerStyle(RadioGroupPickerStyle())
                    .onChange(of: selectedProvider) { _ in
                        Task { await cloud.updateLLMStatus() }
                    }
                }
                
                Divider()
                
                // Provider-specific settings
                if selectedProvider == LLMProvider.lmstudio.rawValue {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("LM Studio port:")
                            TextField("Port", value: $port, formatter: NumberFormatter()).frame(width: 60)
                        }
                        HStack {
                            Text("Model name:")
                            TextField("Model", text: $cloud.lmStudioModelName).frame(width: 200)
                        }
                        Text("Check your model name in LM Studio's server tab").font(.caption).foregroundColor(.secondary)
                    }
                } else if selectedProvider == LLMProvider.ollama.rawValue {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Model name:")
                            TextField("Model", text: $cloud.ollamaModelName).frame(width: 200)
                        }
                        Text("Ollama uses fixed port 11434").font(.caption).foregroundColor(.secondary)
                        Text("Pull models with: ollama pull <model-name>").font(.caption).foregroundColor(.secondary)
                    }
                } else if selectedProvider == LLMProvider.builtIn.rawValue {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Built-in Model: Qwen 0.6B").font(.body)
                        
                        // State: Ready (Loaded)
                        if cloud.builtInModelStatus == "Ready (Loaded)" {
                            Text("Model loaded and ready.").font(.caption).foregroundColor(.green)
                            Button("Unload Model") {
                                Task { await cloud.unloadBuiltInModel() }
                            }
                            .disabled(cloud.isLoadingModel)
                        
                        // State: Downloaded but not loaded
                        } else if cloud.builtInModelStatus == "Downloaded (Unloaded)" {
                            Text("Model downloaded. Load to activate.").font(.caption).foregroundColor(.blue)
                            Button("Load Model") {
                                Task { await cloud.loadBuiltInModel() }
                            }
                            .disabled(cloud.isLoadingModel)

                        // State: Not downloaded
                        } else if cloud.builtInModelStatus == "Not downloaded" {
                            Text("Model needs to be downloaded (~800 MB).").font(.caption).foregroundColor(.secondary)
                            Button("Download Model") {
                                Task { await cloud.downloadBuiltInModel() }
                            }
                            .disabled(cloud.isDownloading)

                        // State: Actively downloading
                        } else if cloud.isDownloading {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(cloud.builtInModelStatus).font(.caption).foregroundColor(.blue)
                                ProgressView(value: cloud.downloadProgress)
                                    .progressViewStyle(.linear)
                                    .frame(width: 200)
                            }
                        
                        // State: Actively loading
                        } else if cloud.isLoadingModel {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Loading model...").font(.caption).foregroundColor(.blue)
                            }

                        // State: Failure states
                        } else {
                            Text("Status: \(cloud.builtInModelStatus)").font(.caption).foregroundColor(.red)
                            if cloud.builtInModelStatus == "Download failed" {
                                Button("Retry Download") {
                                    Task { await cloud.downloadBuiltInModel() }
                                }
                            } else if cloud.builtInModelStatus == "Failed to load" {
                                Button("Retry Load") {
                                    Task { await cloud.loadBuiltInModel() }
                                }
                            }
                        }
                    }
                }
                
                Divider()
                Text("Active conversations").font(.headline)
                if cloud.processingIDs.isEmpty {
                    Text("None").foregroundColor(.secondary)
                } else {
                    List(Array(cloud.processingIDs), id: \.self) { id in
                        HStack {
                            Image(systemName: "message.fill").foregroundColor(.accentColor)
                            Text(String(id.prefix(8)) + "…").font(.system(.body, design: .monospaced))
                        }
                    }.frame(height: 100)
                }
                Spacer()
            }.padding().frame(minWidth: 350)
            
            VStack(alignment: .leading) {
                Text("Activity log").font(.headline)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(cloud.log.enumerated()), id: \.offset) { idx, msg in
                                Text(msg).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary).id(idx)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.onChange(of: cloud.log.count) { _ in
                        proxy.scrollTo(cloud.log.count - 1, anchor: .bottom)
                    }
                }.background(Color.gray.opacity(0.1)).cornerRadius(8)
            }.padding().frame(minWidth: 400)
        }
        .frame(minWidth: 850, minHeight: 650)
    }
}

struct StatusRow: View {
    let title, status: String
    let color: Color
    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).frame(width: 90, alignment: .leading)
            Text(status).foregroundColor(.secondary)
            Spacer()
        }
    }
}

// MARK: – Push delegate plumbing
class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, didFinishLaunching notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications() // sandboxed app – allowed
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String : Any]) {
        CloudKitManager.shared.handleRemoteNotification(userInfo) // Now using shared instance
    }
}

@main
struct PigeonServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup { ContentView() }
#if compiler(>=5.10)
        .windowStyle(.hiddenTitleBar) // macOS 15+
        .windowResizability(.contentSize)
#endif
    }
}
