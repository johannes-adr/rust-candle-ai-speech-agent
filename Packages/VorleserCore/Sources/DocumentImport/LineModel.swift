import CoreGraphics

/// Eine Textzeile einer Seite mit Position. Koordinaten wie in PDF:
/// Ursprung unten links, y wächst nach oben. Die Bereinigung arbeitet nur auf
/// diesem Modell und ist deshalb ohne PDF testbar.
public struct PageLine: Sendable, Equatable {
    public var text: String
    public var rect: CGRect
    /// Schriftgröße in Punkt (bei OCR aus der Zeilenhöhe geschätzt).
    public var fontSize: CGFloat
    public var isBold: Bool
    /// 0-basierter Seitenindex.
    public var page: Int

    public init(_ text: String, rect: CGRect, fontSize: CGFloat = 11, isBold: Bool = false, page: Int = 0) {
        self.text = text
        self.rect = rect
        self.fontSize = fontSize
        self.isBold = isBold
        self.page = page
    }
}

/// Alle Zeilen einer Seite samt Seitengröße.
public struct PageLayout: Sendable, Equatable {
    public var index: Int
    public var size: CGSize
    public var lines: [PageLine]
    /// true, wenn die Zeilen aus Texterkennung (OCR) stammen.
    public var fromOCR: Bool

    public init(index: Int, size: CGSize, lines: [PageLine], fromOCR: Bool = false) {
        self.index = index
        self.size = size
        self.lines = lines
        self.fromOCR = fromOCR
    }
}

/// Protokoll dessen, was die Bereinigung entfernt oder zusammengezogen hat.
/// Dient dem Spike S4 und den Tests.
public struct CleaningReport: Sendable, Equatable {
    public var language: String?
    public var removedHeaderFooter: [String] = []
    public var removedPageNumbers: Int = 0
    public var removedFootnoteLines: Int = 0
    public var removedCaptions: [String] = []
    public var removedTableLines: Int = 0
    /// Seitenindizes, auf denen zwei Spalten erkannt wurden.
    public var twoColumnPages: [Int] = []
    public var hyphenJoined: [String] = []
    public var hyphenKept: [String] = []
    public var bodyFontSize: Double = 0

    public init() {}
}
