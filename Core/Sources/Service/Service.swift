import BuiltinExtension
import CodeiumService
import Combine
import Dependencies
import Foundation
import GitHubCopilotService
import SuggestionService
import Toast
import Workspace
import WorkspaceSuggestionService
import XcodeInspector
import XPCShared

#if canImport(ProService)
import ProService
#endif

@globalActor public enum ServiceActor {
    public actor TheActor {}
    public static let shared = TheActor()
}

/// The running extension service.
public final class Service {
    public static let shared = Service()

    @WorkspaceActor
    let workspacePool: WorkspacePool
    @MainActor
    public let guiController = GraphicalUserInterfaceController()
    public let realtimeSuggestionController = RealtimeSuggestionController()
    public let scheduledCleaner: ScheduledCleaner
    let globalShortcutManager: GlobalShortcutManager

    #if canImport(ProService)
    let proService: ProService
    #endif

    @Dependency(\.toast) var toast
    var cancellable = Set<AnyCancellable>()

    private init() {
        @Dependency(\.workspacePool) var workspacePool

        BuiltinExtensionManager.shared.setupExtensions([
            GitHubCopilotExtension(workspacePool: workspacePool),
            CodeiumExtension(workspacePool: workspacePool),
        ])
        scheduledCleaner = .init()
        workspacePool.registerPlugin {
            SuggestionServiceWorkspacePlugin(workspace: $0) { SuggestionService.service() }
        }
        workspacePool.registerPlugin {
            GitHubCopilotWorkspacePlugin(workspace: $0)
        }
        workspacePool.registerPlugin {
            CodeiumWorkspacePlugin(workspace: $0)
        }
        workspacePool.registerPlugin {
            BuiltinExtensionWorkspacePlugin(workspace: $0)
        }
        self.workspacePool = workspacePool
        globalShortcutManager = .init(guiController: guiController)

        #if canImport(ProService)
        proService = ProService(
            acceptSuggestion: {
                Task { await PseudoCommandHandler().acceptSuggestion() }
            },
            dismissSuggestion: {
                Task { await PseudoCommandHandler().dismissSuggestion() }
            }
        )
        #endif

        scheduledCleaner.service = self
    }

    @MainActor
    public func start() {
        scheduledCleaner.start()
        realtimeSuggestionController.start()
        guiController.start()
        #if canImport(ProService)
        proService.start()
        #endif
        DependencyUpdater().update()
        globalShortcutManager.start()

        Task {
            await XcodeInspector.shared.safe.$activeDocumentURL
                .removeDuplicates()
                .filter { $0 != .init(fileURLWithPath: "/") }
                .compactMap { $0 }
                .sink { [weak self] fileURL in
                    Task {
                        try await self?.workspacePool
                            .fetchOrCreateWorkspaceAndFilespace(fileURL: fileURL)
                    }
                }.store(in: &cancellable)
        }
    }

    @MainActor
    public func prepareForExit() async {
        #if canImport(ProService)
        proService.prepareForExit()
        #endif
        await scheduledCleaner.closeAllChildProcesses()
    }
}

public extension Service {
    func handleXPCServiceRequests(
        endpoint: String,
        requestBody: Data,
        reply: @escaping (Data?, Error?) -> Void
    ) {
        do {
            #if canImport(ProService)
            try Service.shared.proService.handleXPCServiceRequests(
                endpoint: endpoint,
                requestBody: requestBody,
                reply: reply
            )
            #endif
        } catch is XPCRequestHandlerHitError {
            return
        } catch {
            reply(nil, error)
            return
        }

        reply(nil, XPCRequestNotHandledError())
    }
}

