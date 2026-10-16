import Foundation

/// Fassade der Text-Pipeline: Normalisieren und Abschnitte planen.
public enum TextPreparer {
    public static func prepare(
        document: TextDocument,
        language: Language,
        options: NormalizerOptions = .init(),
        planner: ChunkPlanner = .init()
    ) -> [Chunk] {
        let normalizer = Normalizers.make(for: language, options: options)
        return planner.plan(document: document, language: language, normalizer: normalizer)
    }
}
