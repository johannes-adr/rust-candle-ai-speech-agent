// VORLÄUFIG: Diese Datei wird beim Zusammenführen mit dem TextPrep-Zweig GELÖSCHT.
// Die Typen gehören nach TextPrep (dort legt der TextPrep-Agent sie an). Hier stehen
// sie nur, damit DocumentImport ohne Abhängigkeit zu TextPrep gebaut und getestet
// werden kann. Beim Merge: diese Datei löschen, in Package.swift
// DocumentImport wieder von TextPrep abhängen lassen und `import TextPrep` ergänzen.

/// Ein importiertes Dokument: Titel (falls erkannt) und Blöcke in Lesereihenfolge.
public struct TextDocument: Sendable, Codable {
    public var title: String?
    public var blocks: [TextBlock]

    public init(title: String? = nil, blocks: [TextBlock]) {
        self.title = title
        self.blocks = blocks
    }
}

/// Ein Block des Dokuments: Überschrift (Ebene 1–3) oder Absatz.
public enum TextBlock: Sendable, Codable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
}
