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
    /// Kennung der PDFKit-Zeile, aus der dieses Stück stammt (-1 = keine). Stücke einer
    /// Zeile, die durch große Lücken (Spalten, Tabellenzellen) getrennt wurden, teilen sie.
    public var row: Int
    /// Anzahl der Stücke dieser Zeile (≥ 3 deutet auf eine Tabellenzeile).
    public var cells: Int
    /// Absatz-Kennung der Texterkennung (`RecognizeDocumentsRequest`), -1 = unbekannt.
    /// Zeilen mit gleicher Kennung gehören zu einem Absatz.
    public var paragraph: Int = -1

    public init(_ text: String, rect: CGRect, fontSize: CGFloat = 11, isBold: Bool = false, page: Int = 0, row: Int = -1, cells: Int = 1) {
        self.row = row
        self.cells = cells
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
