import Foundation
import MCP

/// HTTP adapter. Tool handling lives in `ToolExecutor`.
@Observable
@MainActor
final class MCPService {

    static let port: UInt16 = 19789

    private static let enabledKey = "io.palmier.slate.mcp.enabled"

    static var isEnabledPreference: Bool {
        get { isEnabled(in: .standard) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? false
    }

    private(set) var isRunning: Bool = false

    @ObservationIgnored
    private let toolExecutor: ToolExecutor
    @ObservationIgnored
    private var httpServer: MCPHTTPServer?

    init(editorProvider: @escaping () -> EditorViewModel?) {
        self.toolExecutor = ToolExecutor(editorProvider: editorProvider)
    }

    func start() {
        let httpServer = MCPHTTPServer(port: Self.port) { [weak self] in
            let server = Server(
                name: "palmier-pro",
                version: "1.0.0",
                instructions: AgentInstructions.serverInstructions,
                capabilities: .init(
                    tools: .init(listChanged: false)
                )
            )
            await self?.registerTools(on: server)
            return server
        }
        self.httpServer = httpServer
        Task { @MainActor [weak self] in
            do {
                try await httpServer.start()
                Log.mcp.notice("http server started port=\(Self.port)")
                self?.isRunning = true
            } catch {
                Log.mcp.error("http server failed to start: \(error.localizedDescription)")
                self?.isRunning = false
            }
        }
    }

    func stop() {
        if let server = httpServer {
            Task { await server.stop() }
        }
        httpServer = nil
        isRunning = false
        Log.mcp.notice("http server stopped")
    }

    private func registerTools(on server: Server) async {
        let tools: [Tool] = ToolDefinitions.all.map { def in
            Tool(name: def.name.rawValue, description: def.description, inputSchema: def.mcpSchemaValue)
        }

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                return ToolResult.error("Editor not available").toMCPResult()
            }
            return await self.dispatchCall(params)
        }
    }

    // Convert args inside the actor so the non-Sendable dict never crosses the hop.
    private func dispatchCall(_ params: CallTool.Parameters) async -> CallTool.Result {
        let args = ToolArgsBridge.argsFromMCP(params.arguments ?? [:])
        let result = await toolExecutor.execute(name: params.name, args: args)
        return result.toMCPResult()
    }

}
