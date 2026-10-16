import Foundation

/// Einfaches, stabiles Dokumentmodell. `DocumentImport` befüllt es,
/// `TextPrep` liest es.
public struct TextDocument: Sendable, Codable, Equatable {
    public var title: String?
    public var blocks: [TextBlock]

    public init(title: String? = nil, blocks: [TextBlock]) {
        self.title = title
        self.blocks = blocks
    }
}

public enum TextBlock: Sendable, Codable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
}

public enum ChunkKind: String, Sendable, Codable, Equatable {
    /// Abschnitt mitten im Absatz.
    case sentence
    /// Letzter Abschnitt eines Absatzes (längere Pause danach).
    case paragraphEnd
    /// Überschrift (Kapitelmarke, längste Pause).
    case heading
}

/// Ein Abschnitt, der in einem Durchgang gesprochen wird.
public struct Chunk: Sendable, Codable, Equatable {
    public var index: Int
    /// Originaltext (für Anzeige und Wiederholen).
    public var text: String
    /// Normalisierte Aussprache (Zahlen, Abkürzungen ausgeschrieben).
    public var spokenText: String
    public var kind: ChunkKind
    /// Laufende Nummer des Kapitels (0 = vor der ersten Überschrift).
    public var chapter: Int

    public init(index: Int, text: String, spokenText: String, kind: ChunkKind, chapter: Int) {
        self.index = index
        self.text = text
        self.spokenText = spokenText
        self.kind = kind
        self.chapter = chapter
    }
}
