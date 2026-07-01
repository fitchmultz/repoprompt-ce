import CryptoKit
import Foundation
import SwiftTreeSitter

extension LanguageType: CaseIterable {
    static var allCases: [LanguageType] {
        [.swift, .js, .c_sharp, .python, .c, .rust, .cpp, .go, .java, .dart, .ts, .tsx, .php, .ruby]
    }
}

enum CodeMapSyntaxQueryOutcome {
    case captures([NamedRange])
    case oversize(CodeMapSyntaxOversizeReason)
    case parseFailed(CodeMapSyntaxParseFailure)
}

struct CodeMapLanguagePipelineDescriptor: Hashable {
    let stableLanguageID: CodeMapPipelineLanguageID
    let grammarRevision: String
    let treeSitterABIVersion: UInt32
    let queryBytes: Data
}

protocol CodeMapSyntaxQuerying {
    func codeMap(content: String, language: LanguageType) throws -> CodeMapSyntaxQueryOutcome
}

extension SyntaxManager: CodeMapSyntaxQuerying {
    func language(forFileExtension fileExtension: String) -> LanguageType? {
        switch fileExtension.lowercased() {
        case "swift": .swift
        case "js", "jsx", "mjs", "cjs": .js
        case "cs": .c_sharp
        case "py": .python
        case "c", "h": .c
        case "rs": .rust
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx": .cpp
        case "go": .go
        case "java": .java
        case "dart": .dart
        case "ts": .ts
        case "tsx": .tsx
        case "php": .php
        case "rb": .ruby
        default: nil
        }
    }

    func codeMap(content: String, language: LanguageType) throws -> CodeMapSyntaxQueryOutcome {
        try .captures(codeMap(content: content, fileExtension: language.codemapArtifactFileExtension))
    }

    func codeMapPipelineDescriptor(for languageType: LanguageType) throws -> CodeMapLanguagePipelineDescriptor {
        try CodeMapLanguagePipelineDescriptor(
            stableLanguageID: languageType.codemapPipelineLanguageID(),
            grammarRevision: String(Data(SHA256.hash(data: Data("legacy-syntax-manager-\(languageType.rawValue)".utf8))).map { String(format: "%02x", $0) }.joined().prefix(40)),
            treeSitterABIVersion: 1,
            queryBytes: Data(languageType.rawValue.utf8)
        )
    }

    func pipelineIdentity(
        for languageType: LanguageType,
        decoderPolicy: CodeMapSourceDecoderPolicy
    ) throws -> CodeMapPipelineIdentity {
        let descriptor = try codeMapPipelineDescriptor(for: languageType)
        return try CodeMapPipelineIdentity(
            languageID: descriptor.stableLanguageID,
            decoderPolicy: decoderPolicy,
            grammarRevision: descriptor.grammarRevision,
            treeSitterABIVersion: descriptor.treeSitterABIVersion,
            codeMapQuerySHA256: CodeMapSHA256Digest(bytes: Data(SHA256.hash(data: descriptor.queryBytes))),
            extractorVersion: CodeMapSemanticVersion(major: 1, minor: 0, patch: 0),
            generatorVersion: CodeMapSemanticVersion(major: 1, minor: 0, patch: 0),
            artifactSchemaVersion: 1,
            oversizeParsePolicyVersion: 1,
            limits: [
                CodeMapPipelineNamedLimit(name: "jsts-max-appended-continuation-lines", value: 20),
                CodeMapPipelineNamedLimit(name: "parse-line-count", value: 120_000),
                CodeMapPipelineNamedLimit(name: "parse-utf16-code-units", value: 8_000_000),
                CodeMapPipelineNamedLimit(name: "parse-utf8-bytes", value: 8_000_000)
            ],
            flags: [
                CodeMapPipelineNamedFlag(name: "filename-main-class-shaping", enabled: true),
                CodeMapPipelineNamedFlag(name: "jsts-signature-extraction", enabled: languageType == .js || languageType == .ts || languageType == .tsx),
                CodeMapPipelineNamedFlag(name: "lightweight-extraction", enabled: SyntaxManager.isLightweight(language: languageType)),
                CodeMapPipelineNamedFlag(name: "path-free-artifact-finalization", enabled: true),
                CodeMapPipelineNamedFlag(name: "swift-range-strategy", enabled: languageType == .swift),
                CodeMapPipelineNamedFlag(name: "typescript-range-strategy", enabled: languageType == .ts || languageType == .tsx)
            ]
        )
    }
}

extension LanguageType {
    var codemapArtifactFileExtension: String {
        switch self {
        case .swift: "swift"
        case .js: "js"
        case .c_sharp: "cs"
        case .python: "py"
        case .c: "c"
        case .rust: "rs"
        case .cpp: "cpp"
        case .go: "go"
        case .java: "java"
        case .dart: "dart"
        case .ts: "ts"
        case .tsx: "tsx"
        case .php: "php"
        case .ruby: "rb"
        }
    }

    func codemapPipelineLanguageID() throws -> CodeMapPipelineLanguageID {
        switch self {
        case .swift: .swift
        case .js: .javascript
        case .c_sharp: .cSharp
        case .python: .python
        case .c: .c
        case .rust: .rust
        case .cpp: .cpp
        case .go: .go
        case .java: .java
        case .dart: .dart
        case .ts: .typescript
        case .tsx: .tsx
        case .php: .php
        case .ruby: .ruby
        }
    }
}

extension CodeMapGenerator {
    static func generateSyntaxArtifact(
        from namedRanges: [NamedRange],
        content: String,
        language: LanguageType,
        perfOptions: CodeMapPerfOptions = .disabled,
        perfStats: CodeMapPerfStats? = nil
    ) -> CodeMapSyntaxArtifact? {
        guard let api = generateCodeMap(
            from: namedRanges,
            content: content,
            fullPath: "artifact.\(language.codemapArtifactFileExtension)",
            perfOptions: perfOptions,
            perfStats: perfStats
        ) else { return nil }
        return CodeMapSyntaxArtifact(
            imports: api.imports,
            exports: api.exports,
            classes: api.classes,
            interfaces: api.interfaces,
            aliases: api.aliases,
            literalUnions: api.literalUnions,
            functions: api.functions,
            enums: api.enums,
            globalVars: api.globalVars,
            macros: api.macros,
            referencedTypes: api.referencedTypes
        )
    }
}
