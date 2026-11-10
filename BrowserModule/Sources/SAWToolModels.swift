import Foundation

public struct SAWRegisteredCommand: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(id: UUID = UUID(), name: String, executable: String, arguments: [String] = [], environment: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    private enum CodingKeys: String, CodingKey { case id, name, executable, arguments, environment }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    }
}

public struct SAWMCPTool: Codable, Equatable, Identifiable {
    public var name: String
    public var toolDescription: String
    public var inputSchemaJSON: String
    public var id: String { name }

    public init(name: String, toolDescription: String = "", inputSchemaJSON: String = "{}") {
        self.name = name
        self.toolDescription = toolDescription
        self.inputSchemaJSON = inputSchemaJSON
    }

    private enum CodingKeys: String, CodingKey { case name, toolDescription, inputSchemaJSON }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        toolDescription = try c.decodeIfPresent(String.self, forKey: .toolDescription) ?? ""
        inputSchemaJSON = try c.decodeIfPresent(String.self, forKey: .inputSchemaJSON) ?? "{}"
    }
}

public struct SAWMCPServer: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var tools: [SAWMCPTool]
    public var allowedToolNames: [String]

    public init(id: UUID = UUID(), name: String, executable: String, arguments: [String] = [], environment: [String: String] = [:], tools: [SAWMCPTool] = [], allowedToolNames: [String] = []) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.tools = tools
        self.allowedToolNames = allowedToolNames
    }

    private enum CodingKeys: String, CodingKey { case id, name, executable, arguments, environment, tools, allowedToolNames }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        tools = try c.decodeIfPresent([SAWMCPTool].self, forKey: .tools) ?? []
        allowedToolNames = try c.decodeIfPresent([String].self, forKey: .allowedToolNames) ?? []
    }
}

public struct SAWToolConfiguration: Codable, Equatable {
    public var workspaceDirectory: String
    public var skillFiles: [String]
    public var commands: [SAWRegisteredCommand]
    public var mcpServers: [SAWMCPServer]

    public init(workspaceDirectory: String = "", skillFiles: [String] = [], commands: [SAWRegisteredCommand] = [], mcpServers: [SAWMCPServer] = []) {
        self.workspaceDirectory = workspaceDirectory
        self.skillFiles = skillFiles
        self.commands = commands
        self.mcpServers = mcpServers
    }

    private enum CodingKeys: String, CodingKey { case workspaceDirectory, skillFiles, commands, mcpServers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceDirectory = try c.decodeIfPresent(String.self, forKey: .workspaceDirectory) ?? ""
        skillFiles = try c.decodeIfPresent([String].self, forKey: .skillFiles) ?? []
        commands = try c.decodeIfPresent([SAWRegisteredCommand].self, forKey: .commands) ?? []
        mcpServers = try c.decodeIfPresent([SAWMCPServer].self, forKey: .mcpServers) ?? []
    }
}

/// `toolID` is `command:<UUID>` or `mcp:<UUID>:<toolname>`; never an arbitrary executable.
public struct SAWToolRequest: Codable, Equatable {
    public var toolID: String
    public var argumentsJSON: String

    public init(toolID: String, argumentsJSON: String = "{}") {
        self.toolID = toolID
        self.argumentsJSON = argumentsJSON
    }
}

public struct SAWToolExecutionResult: Equatable {
    public var success: Bool
    public var output: String
    public var error: String?
    public var exitCode: Int32?
    public var cancelled: Bool
    public var uncertain: Bool
    public var outputDirectory: String?

    public init(success: Bool, output: String = "", error: String? = nil, exitCode: Int32? = nil, cancelled: Bool = false, uncertain: Bool = false, outputDirectory: String? = nil) {
        self.success = success
        self.output = output
        self.error = error
        self.exitCode = exitCode
        self.cancelled = cancelled
        self.uncertain = uncertain
        self.outputDirectory = outputDirectory
    }
}
