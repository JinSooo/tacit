public enum AgentTools {
  public struct Tool: Sendable {
    public let id: String
    public let source: String?
    public let label: String
    public let bundle: String?
    public let symbol: String
    let alias: String?
    let substitute: String?
  }

  public static let sessionSources = entries.compactMap(\.source)
  private static let bySource = Dictionary(uniqueKeysWithValues: entries.compactMap { tool in
    tool.source.map { ($0, tool) }
  })
  private static let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
  private static let byDisplayName = Dictionary(entries.flatMap { tool in
    [tool.id, tool.label.lowercased(), tool.alias].compactMap { $0 }.map { ($0, tool) }
  }, uniquingKeysWith: { first, _ in first })

  static let substitutes = Dictionary(uniqueKeysWithValues: entries.compactMap { tool -> (String, String)? in
    guard let bundle = tool.bundle, let substitute = tool.substitute else { return nil }
    return (bundle, substitute)
  })

  public static func session(source: String) -> Tool? { bySource[source] }
  static func named(_ app: String) -> Tool? { byDisplayName[app.lowercased()] }

  private static var otherMCPLabel: String { L10n.text(zh: "其他 AI 工具", en: "Other AI tool") }

  public static func auditTool(id: String) -> Tool {
    byID[id] ?? Tool(id: id, source: nil, label: id == "mcp" ? otherMCPLabel : id, bundle: nil,
                      symbol: "circle-dashed", alias: nil, substitute: nil)
  }
}
