import Foundation

/// iOS suspends the app soon after it leaves the screen, which cuts the streamed search. So each
/// search also asks iOS for its final result through a background session: iOS finishes that
/// download while Doorlist is suspended (or even closed) and wakes the app with it.
final class SearchFollowUp: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = SearchFollowUp()
    static let identifier = "com.doorlist.app.search-results"

    /// iOS's completion handler when it relaunched the app for this session; called once delivered.
    @MainActor var finishEvents: (() -> Void)?
    /// The Find screen, when it's alive, takes each finished search by request id.
    @MainActor var deliver: ((String, SearchOutcome) -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.timeoutIntervalForResource = 15 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Asks the server for this search's outcome; the request waits there until it's ready.
    func start(requestId: String, query: String) {
        var req = DoorlistAPI.request("v1/search/result", method: "GET", timeout: 300)
        var components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "requestId", value: requestId)]
        req.url = components.url
        let task = session.downloadTask(with: req)
        task.taskDescription = "\(requestId)\n\(query)"
        task.resume()
    }

    /// The live stream got there first.
    func cancel(requestId: String) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription?.hasPrefix(requestId + "\n") == true { task.cancel() }
        }
    }

    /// Touching the session after a relaunch is what lets iOS hand over finished downloads.
    func reconnect() { _ = session }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is gone once this returns, so read it now.
        guard let parts = downloadTask.taskDescription?.split(separator: "\n", maxSplits: 1).map(String.init),
              let id = parts.first,
              (downloadTask.response as? HTTPURLResponse)?.statusCode == 200,
              let data = try? Data(contentsOf: location) else { return }
        let query = parts.count > 1 ? parts[1] : ""
        Task { @MainActor in
            guard let outcome = try? EventSearch.finished(data) else { return }
            if let deliver {
                deliver(id, outcome)
            } else if case .events(let found) = outcome, !found.isEmpty {
                // Relaunched without the Find screen: say it's ready.
                Notifier.searchReady(found.count, query: query)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Cancelled, or the network gave out: the live stream and the rejoin on return cover it.
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            finishEvents?()
            finishEvents = nil
        }
    }
}
