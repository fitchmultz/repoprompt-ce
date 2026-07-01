import Foundation

// MARK: - Supporting Types

struct InterfaceInfo: Codable, Equatable {
    let name: String
    var properties: [PropertyInfo] = []
    var methods: [FunctionInfo] = []
}

struct TypeAliasInfo: Codable, Equatable {
    let name: String
    let definitionLine: String
}

struct ClassInfo: Codable, Equatable {
    let name: String
    var methods: [FunctionInfo]
    var properties: [PropertyInfo]
}

struct FunctionInfo: Codable, Equatable {
    let name: String
    var parameters: [ParameterInfo]
    var returnType: String?
    let definitionLine: String
    let lineNumber: Int?
}

struct ParameterInfo: Codable, Equatable {
    let externalName: String?
    let localName: String
    var typeName: String?
}

struct PropertyInfo: Codable, Equatable {
    let name: String
    let typeName: String?
}

struct VariableInfo: Codable, Equatable {
    let name: String
    let typeName: String?
    let definitionLine: String
}

struct EnumInfo: Codable, Equatable {
    let name: String
    var cases: [String]
}

/// Represents a structured "API surface" for a file.
struct FileAPI: Codable {
    // MARK: - Codable Stored Properties

    let filePath: String
    var imports: [String]
    var exports: [String]
    var classes: [ClassInfo]
    var interfaces: [InterfaceInfo]
    var aliases: [TypeAliasInfo]
    var literalUnions: [String]
    var functions: [FunctionInfo]
    var enums: [EnumInfo]
    var globalVars: [VariableInfo]
    var macros: [String]
    let referencedTypes: [String]

    // MARK: - Computed-on-Init Properties

    let apiDescription: String
    let definedTypeNames: Set<String>
    let pathAndImportsDescription: String
    let apiTokenCount: Int

    // MARK: - CodingKeys

    enum CodingKeys: String, CodingKey {
        case filePath, imports, exports, classes, interfaces, aliases,
             literalUnions, functions, enums, globalVars, macros, referencedTypes
    }

    // MARK: - Init

    init(
        filePath: String,
        imports: [String],
        exports: [String] = [],
        classes: [ClassInfo],
        interfaces: [InterfaceInfo] = [],
        aliases: [TypeAliasInfo] = [],
        literalUnions: [String] = [],
        functions: [FunctionInfo],
        enums: [EnumInfo],
        globalVars: [VariableInfo],
        macros: [String],
        referencedTypes: [String]
    ) {
        self.filePath = filePath
        self.imports = imports
        self.exports = exports
        self.classes = classes
        self.interfaces = interfaces
        self.aliases = aliases
        self.literalUnions = literalUnions
        self.functions = functions
        self.enums = enums
        self.globalVars = globalVars
        self.macros = macros
        self.referencedTypes = referencedTypes

        // ------------------------------------------------------------
        // Build the human-readable API description string
        // ------------------------------------------------------------
        var lines = ["---"]

        func formatFunctionLine(_ fn: FunctionInfo) -> String {
            if let line = fn.lineNumber {
                return "L\(line): \(fn.definitionLine)"
            }
            return fn.definitionLine
        }

        func formatPropertyLine(_ name: String, typeName: String?) -> String {
            guard let typeName, !typeName.isEmpty else { return name }
            if name.contains(":") { return name }
            return "\(name): \(typeName)"
        }

        if !classes.isEmpty {
            lines.append("Classes:")
            for c in classes {
                lines.append("  - \(c.name)")
                if !c.methods.isEmpty {
                    lines.append("    Methods:")
                    for m in c.methods {
                        lines.append("      - \(formatFunctionLine(m))")
                    }
                }
                if !c.properties.isEmpty {
                    lines.append("    Properties:")
                    for p in c.properties {
                        lines.append("      - \(formatPropertyLine(p.name, typeName: p.typeName))")
                    }
                }
            }
        }
        if !interfaces.isEmpty {
            lines.append("")
            lines.append("Interfaces:")
            for i in interfaces {
                lines.append("  - \(i.name)")
                if !i.methods.isEmpty {
                    lines.append("    Methods:")
                    for m in i.methods {
                        lines.append("      - \(formatFunctionLine(m))")
                    }
                }
                if !i.properties.isEmpty {
                    lines.append("    Properties:")
                    for p in i.properties {
                        lines.append("      - \(formatPropertyLine(p.name, typeName: p.typeName))")
                    }
                }
            }
        }
        if !aliases.isEmpty {
            lines.append("")
            lines.append("Type-aliases:")
            for a in aliases {
                lines.append("  - \(a.name)")
            }
        }
        if !literalUnions.isEmpty {
            lines.append("")
            lines.append("Literal-union aliases:")
            for u in literalUnions {
                lines.append("  - \(u)")
            }
        }
        if !functions.isEmpty {
            lines.append("")
            lines.append("Functions:")
            for f in functions {
                lines.append("  - \(formatFunctionLine(f))")
            }
        }
        if !enums.isEmpty {
            lines.append("")
            lines.append("Enums:")
            for e in enums {
                lines.append("  - \(e.name)")
            }
        }
        if !globalVars.isEmpty {
            lines.append("")
            lines.append("Global vars:")
            for v in globalVars {
                lines.append("  - \(formatPropertyLine(v.name, typeName: v.typeName))")
            }
        }
        if !exports.isEmpty {
            lines.append("")
            lines.append("Exports:")
            for e in exports {
                lines.append("  - \(e)")
            }
        }
        if !macros.isEmpty {
            lines.append("")
            lines.append("Macros:")
            for m in macros {
                lines.append("  - \(m)")
            }
        }
        lines.append("---")

        apiDescription = "\n" + lines.joined(separator: "\n") + "\n"

        // Defined type names (classes + interfaces + enums + aliases)
        definedTypeNames = Set(classes.map(\.name))
            .union(interfaces.map(\.name))
            .union(aliases.map(\.name))
            .union(enums.map(\.name))

        // Path + import lines
        pathAndImportsDescription = Self.pathAndImportsBlock(displayPath: filePath, imports: imports)

        // Cache token count for performance
        apiTokenCount = TokenCalculationService.estimateTokens(for: apiDescription)
    }

    // MARK: - Codable

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(filePath, forKey: .filePath)
        try c.encode(imports, forKey: .imports)
        try c.encode(exports, forKey: .exports)
        try c.encode(classes, forKey: .classes)
        try c.encode(interfaces, forKey: .interfaces)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(literalUnions, forKey: .literalUnions)
        try c.encode(functions, forKey: .functions)
        try c.encode(enums, forKey: .enums)
        try c.encode(globalVars, forKey: .globalVars)
        try c.encode(macros, forKey: .macros)
        try c.encode(referencedTypes, forKey: .referencedTypes)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            filePath: c.decode(String.self, forKey: .filePath),
            imports: c.decode([String].self, forKey: .imports),
            exports: c.decodeIfPresent([String].self, forKey: .exports) ?? [],
            classes: c.decode([ClassInfo].self, forKey: .classes),
            interfaces: c.decodeIfPresent([InterfaceInfo].self, forKey: .interfaces) ?? [],
            aliases: c.decodeIfPresent([TypeAliasInfo].self, forKey: .aliases) ?? [],
            literalUnions: c.decodeIfPresent([String].self, forKey: .literalUnions) ?? [],
            functions: c.decode([FunctionInfo].self, forKey: .functions),
            enums: c.decode([EnumInfo].self, forKey: .enums),
            globalVars: c.decode([VariableInfo].self, forKey: .globalVars),
            macros: c.decode([String].self, forKey: .macros),
            referencedTypes: c.decode([String].self, forKey: .referencedTypes)
        )
    }

    // MARK: - Utilities

    func getFullAPIDescription() -> String {
        getFullAPIDescription(displayPath: filePath)
    }

    /// Returns the complete API description with a caller-specified display path.
    /// This avoids downstream string replacement when switching between Full/Relative paths.
    func getFullAPIDescription(displayPath: String) -> String {
        let pathAndImports = Self.pathAndImportsBlock(displayPath: displayPath, imports: imports)
        return [pathAndImports, apiDescription].joined()
    }

    /// Estimates the token count for the full rendered API description using the
    /// same display-path-aware header as `getFullAPIDescription(displayPath:)`.
    func estimatedFullAPIDescriptionTokens(displayPath: String) -> Int {
        TokenCalculationService.estimateTokens(for: Self.pathAndImportsBlock(displayPath: displayPath, imports: imports)) + apiTokenCount
    }

    /// Prints the captured API description.
    func printAPI() {
        print(apiDescription)
    }

    private static func pathAndImportsBlock(displayPath: String, imports: [String]) -> String {
        (["File: \(displayPath)", "Imports:"] + imports.map { "  - \($0)" }).joined(separator: "\n")
    }
}
