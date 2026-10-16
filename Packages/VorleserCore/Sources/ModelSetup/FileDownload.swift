import Foundation

/// Ereignisse eines einzelnen HTTP-Abrufs.
enum DownloadEvent: Sendable {
    case response(status: Int)
    case data(Data)
}

/// Streamt eine HTTP-Antwort in Stücken (kein `AsyncBytes`, das ist pro Byte zu langsam für GB-Dateien).
final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation

    init(_ continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        continuation.yield(.response(status: status))
        completionHandler((200..<300).contains(status) ? .allow : .cancel)
        if !(200..<300).contains(status) { continuation.finish() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as? URLError)?.code != .cancelled {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

enum FileDownload {
    /// Startet einen GET (mit `Range`, wenn `offset > 0`) und liefert Antwortstatus und Datenstücke.
    /// Wird die Konsumenten-Task abgebrochen, bricht auch die Verbindung ab.
    static func stream(url: URL, offset: Int64, configuration: URLSessionConfiguration)
        -> AsyncThrowingStream<DownloadEvent, Error>
    {
        let (stream, continuation) = AsyncThrowingStream<DownloadEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        let delegate = DownloadDelegate(continuation)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        // Wir hashen selbst; eine komprimierte Übertragung würde Größen verfälschen.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        continuation.onTermination = { @Sendable _ in
            task.cancel()
            session.invalidateAndCancel()
        }
        task.resume()
        return stream
    }
}
