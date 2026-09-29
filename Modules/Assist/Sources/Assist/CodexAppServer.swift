import Foundation

/// The account and tool runtime used by Codex on this Mac. Its credentials are
/// managed by Codex, and are shared with other local Codex clients.
public struct CodexAccount: Sendable, Equatable {
    public let email: String?
    public let planType: String?

    public var planName: String? {
        guard let planType, !planType.isEmpty else { return nil }
        if planType == "team" { return "Business" }
        return planType.prefix(1).uppercased() + planType.dropFirst()
    }
}

public struct CodexDeviceCode: Sendable, Equatable {
    public let userCode: String
    public let verificationURL: URL
}

public struct CodexUserQuestion: Sendable, Equatable {
    public let id: String
    public let question: String
    public let options: [String]
}

/// Return one chosen option label per question, or nil when the person cancels.
public typealias CodexInputHandler = @Sendable ([CodexUserQuestion]) async -> [String: String]?

public enum CodexAppServerError: Error, Sendable, LocalizedError {
    case notInstalled
    case notSignedIn
    case needsInteraction(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Install the Codex CLI to use connected tools in Voice Assistant."
        case .notSignedIn:
            "Sign in to ChatGPT through Codex in Voice Assistant settings."
        case .needsInteraction(let detail):
            "Codex needs your input to continue: \(detail) Open Codex to complete this request."
        case .failed(let detail):
            "Codex could not answer: \(detail)"
        }
    }
}

/// A deliberately small JSONL client for the documented Codex App Server
/// protocol. Each operation starts a local server process; a voice turn uses
/// an ephemeral thread so it does not fill the user's Codex chat list.
public struct CodexAppServer: Sendable {
    public let executableURL: URL?

    public init(executableURL: URL? = CodexAppServer.locateExecutable()) {
        self.executableURL = executableURL
    }

    public static func locateExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "\(home)/.cargo/bin/codex", "\(home)/.bun/bin/codex",
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/codex" }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    public func account() async throws -> CodexAccount? {
        try await operate { process in
            try await process.initialize()
            try process.send(id: 2, method: "account/read", params: ["refreshToken": false])
            let response = try await process.response(id: 2)
            return Self.account(from: response["result"] as? [String: Any])
        }
    }

    /// Codex owns the device-code ceremony and persists the resulting sign-in.
    /// The callback is invoked as soon as the code is available, while this
    /// method keeps reading until Codex reports success or failure.
    public func signIn(onCode: @escaping @Sendable (CodexDeviceCode) async -> Void) async throws -> CodexAccount {
        try await operate { process in
            try await process.initialize()
            try process.send(id: 2, method: "account/login/start", params: ["type": "chatgptDeviceCode"])
            let response = try await process.response(id: 2)
            guard let result = response["result"] as? [String: Any],
                  let code = result["userCode"] as? String,
                  let urlString = result["verificationUrl"] as? String,
                  let url = URL(string: urlString) else {
                throw CodexAppServerError.failed("No device sign-in code was returned.")
            }
            await onCode(CodexDeviceCode(userCode: code, verificationURL: url))
            while let message = try await process.next() {
                guard message["method"] as? String == "account/login/completed" else { continue }
                let params = message["params"] as? [String: Any] ?? [:]
                guard params["success"] as? Bool == true else {
                    throw CodexAppServerError.failed(params["error"] as? String ?? "Sign-in was not completed.")
                }
                try process.send(id: 3, method: "account/read", params: ["refreshToken": false])
                let accountResponse = try await process.response(id: 3)
                guard let account = Self.account(from: accountResponse["result"] as? [String: Any]) else {
                    throw CodexAppServerError.notSignedIn
                }
                return account
            }
            throw CodexAppServerError.failed("The sign-in connection closed.")
        }
    }

    public func signOut() async throws {
        try await operate { process in
            try await process.initialize()
            try process.send(id: 2, method: "account/logout", params: [:])
            _ = try await process.response(id: 2)
        }
    }

    public func models() async throws -> [AssistModel] {
        try await operate { process in
            try await process.initialize()
            try process.send(id: 2, method: "model/list", params: ["limit": 100, "includeHidden": false])
            let response = try await process.response(id: 2)
            let entries = (response["result"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
            return entries.compactMap { entry in
                guard let slug = entry["model"] as? String ?? entry["id"] as? String else { return nil }
                return AssistModel(slug: slug, displayName: entry["displayName"] as? String ?? slug)
            }
        }
    }

    public func respond(model: String, instructions: String, input: String, requestInput: CodexInputHandler? = nil) async throws -> AssistResponse {
        try await operate { process in
            try await process.initialize()
            guard try await Self.accountOn(process) != nil else { throw CodexAppServerError.notSignedIn }
            try process.send(id: 3, method: "thread/start", params: [
                "model": model,
                "cwd": FileManager.default.temporaryDirectory.path,
                "approvalPolicy": "on-request",
                "sandbox": "read-only",
                "ephemeral": true,
                "serviceName": "scribe_voice_assistant",
                "developerInstructions": instructions + "\nUse available connected tools when the request needs external information. Do not make changes or perform write actions. Return only the answer to insert.",
            ])
            let started = try await process.response(id: 3)
            guard let threadID = ((started["result"] as? [String: Any])?["thread"] as? [String: Any])?["id"] as? String else {
                throw CodexAppServerError.failed("No agent thread was created.")
            }
            try process.send(id: 4, method: "turn/start", params: [
                "threadId": threadID,
                "input": [["type": "text", "text": input]],
            ])
            var turnID: String?
            var finalText: String?
            var latestText: String?
            while let message = try await process.next() {
                if message["id"] as? Int == 4 {
                    try Self.checkResponse(message)
                    turnID = ((message["result"] as? [String: Any])?["turn"] as? [String: Any])?["id"] as? String
                    continue
                }
                let method = message["method"] as? String
                let params = message["params"] as? [String: Any] ?? [:]
                if let requestID = message["id"], (requestID is Int || requestID is String), let method {
                    if method == "item/tool/requestUserInput", let requestInput {
                        let questions = (params["questions"] as? [[String: Any]] ?? []).compactMap { item -> CodexUserQuestion? in
                            guard let id = item["id"] as? String, let question = item["question"] as? String else { return nil }
                            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                            return CodexUserQuestion(id: id, question: question, options: options)
                        }
                        guard !questions.isEmpty, let answers = await requestInput(questions) else {
                            throw CodexAppServerError.needsInteraction("A connected tool needs approval or more information.")
                        }
                        let payload = Dictionary(uniqueKeysWithValues: answers.map { ($0.key, ["answers": [$0.value]]) })
                        try process.sendResult(id: requestID, result: ["answers": payload])
                        continue
                    }
                    throw CodexAppServerError.needsInteraction(Self.interactionDescription(method: method, params: params))
                }
                guard params["threadId"] as? String == threadID else { continue }
                switch method {
                case "item/completed":
                    if let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
                       let text = item["text"] as? String, !text.isEmpty {
                        latestText = text
                        if item["phase"] as? String == "final_answer" { finalText = text }
                    }
                case "turn/completed":
                    let turn = params["turn"] as? [String: Any] ?? [:]
                    if let turnID, let completedID = turn["id"] as? String, turnID != completedID { continue }
                    guard turn["status"] as? String == "completed" else {
                        let detail = (turn["error"] as? [String: Any])?["message"] as? String ?? "The agent stopped before answering."
                        throw CodexAppServerError.failed(detail)
                    }
                    guard let answer = finalText ?? latestText,
                          !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AssistError.emptyResponse
                    }
                    return AssistResponse(text: answer, model: model)
                default:
                    break
                }
            }
            throw CodexAppServerError.failed("The agent connection closed before an answer arrived.")
        }
    }

    private static func accountOn(_ process: CodexAppServerProcess) async throws -> CodexAccount? {
        try process.send(id: 2, method: "account/read", params: ["refreshToken": false])
        return account(from: try await process.response(id: 2)["result"] as? [String: Any])
    }

    private static func account(from result: [String: Any]?) -> CodexAccount? {
        guard let value = result?["account"] as? [String: Any], value["type"] as? String == "chatgpt" else { return nil }
        return CodexAccount(email: value["email"] as? String, planType: value["planType"] as? String)
    }

    private static func checkResponse(_ message: [String: Any]) throws {
        if let error = message["error"] as? [String: Any] {
            throw CodexAppServerError.failed(error["message"] as? String ?? "The agent rejected a request.")
        }
    }

    private static func interactionDescription(method: String, params: [String: Any]) -> String {
        if let reason = params["reason"] as? String { return reason }
        switch method {
        case "item/tool/requestUserInput": return "A connected tool requested approval or more information."
        case "mcpServer/elicitation/request": return "A connected tool needs you to sign in or provide information."
        case "item/commandExecution/requestApproval": return "A command requested approval."
        case "item/fileChange/requestApproval": return "A file change requested approval."
        default: return "An agent action requested approval."
        }
    }

    private func operate<T>(_ body: (CodexAppServerProcess) async throws -> T) async throws -> T {
        guard let executableURL else { throw CodexAppServerError.notInstalled }
        let process = try CodexAppServerProcess(executableURL: executableURL)
        return try await withTaskCancellationHandler {
            defer { process.stop() }
            return try await body(process)
        } onCancel: {
            process.stop()
        }
    }
}

/// The app's TextAssistant adapter. Codex chooses and invokes installed tools;
/// Scribe receives only the completed agent message for insertion.
public struct CodexAppServerAssistant: TextAssistant {
    public let displayName = "Codex"
    public let model: String
    public let systemPrompt: String?
    public let server: CodexAppServer
    public let requestInput: CodexInputHandler?

    public init(server: CodexAppServer, model: String, systemPrompt: String?, requestInput: CodexInputHandler? = nil) {
        self.server = server
        self.model = model
        self.systemPrompt = systemPrompt
        self.requestInput = requestInput
    }

    public func respond(to request: AssistRequest) async throws -> AssistResponse {
        try await server.respond(
            model: model,
            instructions: AssistPrompt.system(template: systemPrompt, applicationName: request.applicationName),
            input: AssistPrompt.input(for: request),
            requestInput: requestInput
        )
    }
}

private final class CodexAppServerProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator!

    init(executableURL: URL) throws {
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw CodexAppServerError.failed("Could not start the Codex CLI: \(error.localizedDescription)") }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            Task.detached { [self] in
                do {
                    for try await line in output.fileHandleForReading.bytes.lines {
                        continuation.yield(Data(line.utf8))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        iterator = stream.makeAsyncIterator()
    }

    func stop() {
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
    }

    func send(id: Int? = nil, method: String, params: [String: Any]) throws {
        var message: [String: Any] = ["method": method, "params": params]
        if let id { message["id"] = id }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        data.append(0x0a)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func sendResult(id: Any, result: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: ["id": id, "result": result], options: [.withoutEscapingSlashes])
        data.append(0x0a)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func initialize() async throws {
        try send(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "scribe", "title": "Scribe Voice Assistant", "version": "1.0"],
            "capabilities": ["experimentalApi": true, "requestAttestation": false],
        ])
        _ = try await response(id: 1)
        try send(method: "initialized", params: [:])
    }

    func response(id: Int) async throws -> [String: Any] {
        while let message = try await next() {
            guard message["id"] as? Int == id else { continue }
            if let error = message["error"] as? [String: Any] {
                throw CodexAppServerError.failed(error["message"] as? String ?? "The App Server rejected a request.")
            }
            return message
        }
        throw CodexAppServerError.failed("The App Server connection closed.")
    }

    func next() async throws -> [String: Any]? {
        guard let data = try await iterator.next() else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAppServerError.failed("The App Server sent an invalid message.")
        }
        return object
    }
}
