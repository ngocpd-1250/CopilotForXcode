import Foundation
import LanguageClient
import LanguageServerProtocol
import Logger
import SuggestionModel
import XcodeInspector

public protocol CodeiumSuggestionServiceType {
    func getCompletions(
        fileURL: URL,
        content: String,
        cursorPosition: CursorPosition,
        tabSize: Int,
        indentSize: Int,
        usesTabsForIndentation: Bool
    ) async throws -> [CodeSuggestion]
    func notifyAccepted(_ suggestion: CodeSuggestion) async
    func notifyOpenTextDocument(fileURL: URL, content: String) async throws
    func notifyChangeTextDocument(fileURL: URL, content: String) async throws
    func notifyCloseTextDocument(fileURL: URL) async throws
    func cancelRequest() async
    func terminate()
}

enum CodeiumError: Error, LocalizedError {
    case languageServerNotInstalled
    case languageServerOutdated
    case languageServiceIsInstalling

    var errorDescription: String? {
        switch self {
        case .languageServerNotInstalled:
            return "Language server is not installed. Please install it in the host app."
        case .languageServerOutdated:
            return "Language server is outdated. Please update it in the host app or update the extension."
        case .languageServiceIsInstalling:
            return "Language service is installing, please try again later."
        }
    }
}

public class CodeiumService {
    static let sessionId = UUID().uuidString
    let projectRootURL: URL
    var server: CodeiumLSP?
    var heartbeatTask: Task<Void, Error>?
    var requestCounter: UInt64 = 0
    var cancellationCounter: UInt64 = 0
    let openedDocumentPool = OpenedDocumentPool()
    let onServiceLaunched: () -> Void

    let languageServerURL: URL
    let supportURL: URL

    let authService = CodeiumAuthService()

    var fallbackXcodeVersion = "14.0.0"
    var languageServerVersion = CodeiumInstallationManager.latestSupportedVersion

    private var ongoingTasks = Set<Task<[CodeSuggestion], Error>>()

    init(designatedServer: CodeiumLSP) {
        projectRootURL = URL(fileURLWithPath: "/")
        server = designatedServer
        onServiceLaunched = {}
        languageServerURL = URL(fileURLWithPath: "/")
        supportURL = URL(fileURLWithPath: "/")
    }

    public init(projectRootURL: URL, onServiceLaunched: @escaping () -> Void) throws {
        self.projectRootURL = projectRootURL
        self.onServiceLaunched = onServiceLaunched
        let urls = try CodeiumService.createFoldersIfNeeded()
        languageServerURL = urls.executableURL.appendingPathComponent("language_server")
        supportURL = urls.supportURL
        Task {
            try await setupServerIfNeeded()
        }
    }

    @discardableResult
    func setupServerIfNeeded() async throws -> CodeiumLSP {
        if let server { return server }

        let binaryManager = CodeiumInstallationManager()
        let installationStatus = binaryManager.checkInstallation()
        switch installationStatus {
        case let .installed(version), let .unsupported(version, _):
            languageServerVersion = version
        case .notInstalled:
            throw CodeiumError.languageServerNotInstalled
        case let .outdated(version, _):
            languageServerVersion = version
            throw CodeiumError.languageServerOutdated
        }

        let metadata = try await getMetadata()
        let tempFolderURL = FileManager.default.temporaryDirectory
        let managerDirectoryURL = tempFolderURL
            .appendingPathComponent("com.intii.CopilotForXcode")
            .appendingPathComponent(UUID().uuidString)
        if !FileManager.default.fileExists(atPath: managerDirectoryURL.path) {
            try FileManager.default.createDirectory(
                at: managerDirectoryURL,
                withIntermediateDirectories: true
            )
        }

        let server = CodeiumLanguageServer(
            languageServerExecutableURL: languageServerURL,
            managerDirectoryURL: managerDirectoryURL,
            supportURL: supportURL
        )

        server.terminationHandler = { [weak self] in
            self?.server = nil
            self?.heartbeatTask?.cancel()
            self?.requestCounter = 0
            self?.cancellationCounter = 0
            Logger.codeium.info("Language server is terminated, will be restarted when needed.")
        }

        server.launchHandler = { [weak self] in
            guard let self else { return }
            self.onServiceLaunched()
            self.heartbeatTask = Task { [weak self, metadata] in
                while true {
                    try Task.checkCancellation()
                    _ = try? await self?.server?.sendRequest(
                        CodeiumRequest.Heartbeat(requestBody: .init(metadata: metadata))
                    )
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }

        self.server = server
        server.start()
        return server
    }

    public static func createFoldersIfNeeded() throws -> (
        applicationSupportURL: URL,
        gitHubCopilotURL: URL,
        executableURL: URL,
        supportURL: URL
    ) {
        let supportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent(
            Bundle.main
                .object(forInfoDictionaryKey: "APPLICATION_SUPPORT_FOLDER") as! String
        )

        if !FileManager.default.fileExists(atPath: supportURL.path) {
            try? FileManager.default
                .createDirectory(at: supportURL, withIntermediateDirectories: false)
        }
        let gitHubCopilotFolderURL = supportURL.appendingPathComponent("Codeium")
        if !FileManager.default.fileExists(atPath: gitHubCopilotFolderURL.path) {
            try? FileManager.default
                .createDirectory(at: gitHubCopilotFolderURL, withIntermediateDirectories: false)
        }
        let supportFolderURL = gitHubCopilotFolderURL.appendingPathComponent("support")
        if !FileManager.default.fileExists(atPath: supportFolderURL.path) {
            try? FileManager.default
                .createDirectory(at: supportFolderURL, withIntermediateDirectories: false)
        }
        let executableFolderURL = gitHubCopilotFolderURL.appendingPathComponent("executable")
        if !FileManager.default.fileExists(atPath: executableFolderURL.path) {
            try? FileManager.default
                .createDirectory(at: executableFolderURL, withIntermediateDirectories: false)
        }

        return (supportURL, gitHubCopilotFolderURL, executableFolderURL, supportFolderURL)
    }
}

extension CodeiumService {
    func getMetadata() async throws -> Metadata {
        guard let key = authService.key else {
            struct E: Error, LocalizedError {
                var errorDescription: String? { "Codeium not signed in." }
            }
            throw E()
        }
        var ideVersion = await XcodeInspector.shared.safe.latestActiveXcode?.version
        ?? fallbackXcodeVersion
        let versionNumberSegmentCount = ideVersion.split(separator: ".").count
        if versionNumberSegmentCount == 2 {
            ideVersion += ".0"
        } else if versionNumberSegmentCount == 1 {
            ideVersion += ".0.0"
        }
        return Metadata(
            ide_name: "xcode",
            ide_version: ideVersion,
            extension_version: languageServerVersion,
            api_key: key,
            session_id: CodeiumService.sessionId,
            request_id: requestCounter
        )
    }

    func getRelativePath(of fileURL: URL) -> String {
        let filePath = fileURL.path
        let rootPath = projectRootURL.path
        if let range = filePath.range(of: rootPath),
           range.lowerBound == filePath.startIndex
        {
            let relativePath = filePath.replacingCharacters(
                in: filePath.startIndex..<range.upperBound,
                with: ""
            )
            return relativePath
        }
        return filePath
    }
}

extension CodeiumService: CodeiumSuggestionServiceType {
    public func getCompletions(
        fileURL: URL,
        content: String,
        cursorPosition: CursorPosition,
        tabSize: Int,
        indentSize: Int,
        usesTabsForIndentation: Bool
    ) async throws -> [CodeSuggestion] {
        ongoingTasks.forEach { $0.cancel() }
        ongoingTasks.removeAll()
        await cancelRequest()

        requestCounter += 1
        let languageId = languageIdentifierFromFileURL(fileURL)
        let relativePath = getRelativePath(of: fileURL)

        let task = Task {
            let request = await CodeiumRequest.GetCompletion(requestBody: .init(
                metadata: try getMetadata(),
                document: .init(
                    absolute_path: fileURL.path,
                    relative_path: relativePath,
                    text: content,
                    editor_language: languageId.rawValue,
                    language: .init(codeLanguage: languageId),
                    cursor_position: .init(
                        row: cursorPosition.line,
                        col: cursorPosition.character
                    )
                ),
                editor_options: .init(tab_size: indentSize, insert_spaces: !usesTabsForIndentation),
                other_documents: openedDocumentPool.getOtherDocuments(exceptURL: fileURL)
                    .map { openedDocument in
                        let languageId = languageIdentifierFromFileURL(openedDocument.url)
                        return .init(
                            absolute_path: openedDocument.url.path,
                            relative_path: openedDocument.relativePath,
                            text: openedDocument.content,
                            editor_language: languageId.rawValue,
                            language: .init(codeLanguage: languageId)
                        )
                    }
            ))

            try Task.checkCancellation()

            let result = try await (try await setupServerIfNeeded()).sendRequest(request)

            try Task.checkCancellation()

            return result.completionItems?.map { item in
                CodeSuggestion(
                    id: item.completion.completionId,
                    text: item.completion.text,
                    position: cursorPosition,
                    range: CursorRange(
                        start: .init(
                            line: item.range.startPosition?.row.flatMap(Int.init) ?? 0,
                            character: item.range.startPosition?.col.flatMap(Int.init) ?? 0
                        ),
                        end: .init(
                            line: item.range.endPosition?.row.flatMap(Int.init) ?? 0,
                            character: item.range.endPosition?.col.flatMap(Int.init) ?? 0
                        )
                    )
                )
            } ?? []
        }

        ongoingTasks.insert(task)

        return try await task.value
    }

    public func cancelRequest() async {
        _ = try? await server?.sendRequest(
            CodeiumRequest.CancelRequest(requestBody: .init(
                request_id: requestCounter,
                session_id: CodeiumService.sessionId
            ))
        )
    }

    public func notifyAccepted(_ suggestion: CodeSuggestion) async {
        _ = try? await (try setupServerIfNeeded())
            .sendRequest(CodeiumRequest.AcceptCompletion(requestBody: .init(
                metadata: getMetadata(),
                completion_id: suggestion.id
            )))
    }

    public func notifyOpenTextDocument(fileURL: URL, content: String) async throws {
        let relativePath = getRelativePath(of: fileURL)
        await openedDocumentPool.openDocument(
            url: fileURL,
            relativePath: relativePath,
            content: content
        )
    }

    public func notifyChangeTextDocument(fileURL: URL, content: String) async throws {
        let relativePath = getRelativePath(of: fileURL)
        await openedDocumentPool.updateDocument(
            url: fileURL,
            relativePath: relativePath,
            content: content
        )
    }

    public func notifyCloseTextDocument(fileURL: URL) async throws {
        await openedDocumentPool.closeDocument(url: fileURL)
    }

    public func terminate() {
        server?.terminate()
        server = nil
    }
}

func getXcodeVersion() async throws -> String {
    let task = Process()
    task.launchPath = "/usr/bin/xcodebuild"
    task.arguments = ["-version"]
    let outpipe = Pipe()
    task.standardOutput = outpipe
    task.standardError = Pipe()
    return try await withUnsafeThrowingContinuation { continuation in
        do {
            task.terminationHandler = { _ in
                do {
                    if let data = try outpipe.fileHandleForReading.readToEnd(),
                       let content = String(data: data, encoding: .utf8)
                    {
                        let firstLine = content.split(whereSeparator: \.isNewline).first ?? ""
                        var version = firstLine.replacingOccurrences(of: "Xcode ", with: "")
                        if version.isEmpty {
                            version = "14.0"
                        }
                        continuation.resume(returning: version)
                        return
                    }
                    continuation.resume(returning: "")
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            try task.run()
        } catch {
            continuation.resume(throwing: error)
        }
    }
}

