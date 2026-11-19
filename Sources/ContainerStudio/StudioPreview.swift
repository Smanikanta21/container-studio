import AppKit
import StudioCore
import SwiftUI
import SwiftTerm

// Canvas fixtures are explicitly isolated from the CLI, network and engine setup.
@MainActor
enum StudioPreview {
    static func store(page: String = "Containers") -> StudioStore {
        let store = StudioStore(isPreview: true)
        let containers = #"""
        [{"configuration":{"id":"web-api","image":{"reference":"docker.io/library/node:22-alpine"},"resources":{"cpus":2,"memoryInBytes":536870912},"publishedPorts":[{"hostPort":3000,"containerPort":3000,"proto":"tcp"}]},"status":"running","networks":[{"ipv4Address":"192.168.64.2"}]},
        {"configuration":{"id":"postgres","image":{"reference":"docker.io/library/postgres:17-alpine"},"resources":{"cpus":2,"memoryInBytes":1073741824}},"status":"stopped"}]
        """#
        let images = #"""
        [{"configuration":{"name":"docker.io/library/node:22-alpine"},"variants":[{"size":152043520,"platform":{"architecture":"arm64"}}]}]
        """#
        store.containers = (try? SnapshotDecoder.containers(Data(containers.utf8))) ?? []
        store.images = (try? SnapshotDecoder.images(Data(images.utf8))) ?? []
        store.selection = "web-api"; store.page = page; store.setupState = .ready
        store.hasOpenedWorkspace = true; store.lastUpdated = Date()
        store.logs = logs(id: "web-api").logs
        store.record("Workspace refreshed", detail: "2 containers · 1 image")
        store.record("Container started", detail: "web-api")
        return store
    }

    static func container() -> StudioContainer { store().containers[0] }

    static func files(id: String = "web-api") -> ContainerFilesSession {
        let session = ContainerFilesSession(id: id, isPreview: true)
        session.path = "/app"
        session.entries = (try? ContainerFilesystem.decodeEntries(Data("d\0src\0d\0config\0f\0package.json\0f\0server.js\0f\0.env.example\0".utf8))) ?? []
        session.filePath = "/app/server.js"
        session.text = "import http from 'node:http';\n\nconst port = process.env.PORT ?? 3000;\n\nhttp.createServer((request, response) => {\n  response.writeHead(200);\n  response.end('Container Studio\\n');\n}).listen(port);\n"
        session.originalText = session.text
        return session
    }

    static func logs(id: String = "web-api") -> ContainerSession {
        let session = ContainerSession(id: id, isPreview: true)
        session.logs = "2026-11-19T10:30:00Z Server listening on :3000\n2026-11-19T10:30:12Z GET /health 200 2ms\n2026-11-19T10:31:01Z GET /api/workspaces 200 8ms\n"
        session.logsUpdated = Date()
        session.script = "pwd\nls -la /app\n"
        session.stdout = "/app\nserver.js  package.json  src  config\n"
        session.exitCode = 0
        return session
    }

    static func terminal() -> ContainerTerminalSession {
        let session = ContainerTerminalSession()
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 650, height: 260))
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)
        terminal.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        terminal.feed(text: "/app # pwd\r\n/app\r\n/app # ls\r\nconfig  package.json  server.js  src\r\n/app # ")
        session.terminal = terminal; session.status = "Canvas preview · Sample CLI output"
        return session
    }
}
