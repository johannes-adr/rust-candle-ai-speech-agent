import Foundation

/// Fortschritt und Restzeit aus der gemessenen Geschwindigkeit der fertigen Abschnitte.
public struct ProgressEstimate: Sendable, Equatable {
    /// 0…1, nach Zeichen gewichtet.
    public var progress: Double
    /// Geschätzte Restzeit; nil, solange noch nichts gemessen wurde.
    public var remainingSeconds: Double?
    /// Seite des nächsten offenen Abschnitts, 1-basiert („Seite x von y“).
    public var currentPage: Int?
    public var totalPages: Int?
}

public struct ETAEstimator: Sendable {
    /// Anzahl der zuletzt fertigen Abschnitte, über die gemittelt wird.
    public var window: Int

    public init(window: Int = 8) { self.window = max(1, window) }

    public func estimate(for chunks: [ProjectChunk]) -> ProgressEstimate {
        func weight(_ c: ProjectChunk) -> Int { max(1, c.chunk.spokenText.count) }
        let total = chunks.reduce(0) { $0 + weight($1) }
        let finished = chunks.filter { $0.status == .done || $0.status == .suspicious }
        let doneWeight = finished.reduce(0) { $0 + weight($1) }
        let remaining = chunks.filter { $0.status == .pending || $0.status == .failed }

        let measured = finished.filter { ($0.computeSeconds ?? 0) > 0 }.suffix(window)
        var eta: Double?
        if !measured.isEmpty {
            let chars = measured.reduce(0) { $0 + weight($1) }
            let secs = measured.reduce(0.0) { $0 + ($1.computeSeconds ?? 0) }
            eta = secs / Double(chars) * Double(remaining.reduce(0) { $0 + weight($1) })
        } else if remaining.isEmpty {
            eta = 0
        }

        let pages = chunks.compactMap(\.pageIndex)
        let nextPage = remaining.first?.pageIndex ?? pages.max()
        return ProgressEstimate(
            progress: total == 0 ? 1 : Double(doneWeight) / Double(total),
            remainingSeconds: eta,
            currentPage: nextPage.map { $0 + 1 },
            totalPages: pages.max().map { $0 + 1 })
    }
}
