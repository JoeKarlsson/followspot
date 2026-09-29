import CryptoKit
import Foundation

struct ModelChoice: Identifiable, Hashable {
  let name: String
  let size: String
  let note: String
  var id: String { name }
}

// Model discovery and downloads. Mirrors the ./followspot launcher: same
// preference order, same Hugging Face URLs, same VAD model.
enum Models {
  static let choices = [
    ModelChoice(name: "base.en", size: "142 MB", note: "Fine for clear speech."),
    ModelChoice(name: "small.en", size: "466 MB", note: "Good default for most laptops."),
    ModelChoice(name: "medium.en", size: "1.5 GB", note: "More forgiving with names and mumbling."),
    ModelChoice(name: "large-v3-turbo", size: "1.6 GB", note: "Best accuracy if your machine keeps up."),
  ]
  static let defaultChoice = "small.en"
  static let vadName = "silero-v6.2.0"

  static func url(for name: String) -> URL {
    if name == vadName {
      return URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-\(name).bin")!
    }
    return URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(name).bin")!
  }

  private static var dirs: [URL] {
    [Paths.models, Paths.repo?.appendingPathComponent("models")].compactMap { $0 }
  }

  // Largest first, like the launcher. Screen Studio's medium ranks above
  // small/base so a quick base.en download doesn't silently downgrade.
  private static var ranked: [URL] {
    let screenStudio = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Screen Studio/models/ggml-medium.bin")
    var out: [URL] = []
    for name in ["large-v3-turbo", "medium.en", "medium"] {
      out += dirs.map { $0.appendingPathComponent("ggml-\(name).bin") }
    }
    out.append(screenStudio)
    for name in ["small.en", "base.en"] {
      out += dirs.map { $0.appendingPathComponent("ggml-\(name).bin") }
    }
    return out
  }

  // Every model on disk, for the Model menu: the ranked ones plus anything
  // else dropped into a models folder (tiny.en, a custom fine-tune, ...).
  static var installed: [URL] {
    var seen = Set<String>()
    var out: [URL] = []
    let extras = dirs.flatMap { dir in
      ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }
        .filter { !$0.lastPathComponent.hasPrefix("ggml-silero-") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    for url in ranked + extras where FileManager.default.fileExists(atPath: url.path) {
      if seen.insert(url.standardizedFileURL.path).inserted { out.append(url) }
    }
    return out
  }

  // The chosen model if it still exists, else the best one found.
  static var current: URL? {
    if let path = UserDefaults.standard.string(forKey: "model"), FileManager.default.fileExists(atPath: path) {
      return URL(fileURLWithPath: path)
    }
    return installed.first
  }

  // Newest Silero model in any models folder (names sort by version).
  static var vad: URL? {
    dirs.flatMap { dir in
      ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix("ggml-silero-") && $0.pathExtension == "bin" }
    }
    .max { $0.lastPathComponent < $1.lastPathComponent }
  }

  static func label(for url: URL) -> String {
    var name = url.deletingPathExtension().lastPathComponent
    if name.hasPrefix("ggml-") { name.removeFirst(5) }
    return url.path.contains("Screen Studio") ? "\(name) (Screen Studio)" : name
  }
}

// One download at a time into Paths.models, with progress for the UI. Also
// holds the picker's choices: @State is a macro, and its plugin only ships
// with Xcode, so this builds with just the Command Line Tools.
//
// Each file is checked against the SHA-256 and size Hugging Face publishes
// (x-linked-etag / x-linked-size on the un-followed redirect), so a truncated
// or corrupted download never reaches whisper-server. Dropped connections
// resume where they stopped, up to three times.
final class ModelDownload: NSObject, ObservableObject, URLSessionTaskDelegate {
  @Published var choice = Models.defaultChoice
  @Published var vad = true
  @Published var fraction: Double = 0
  @Published var status = ""
  @Published var busy = false
  @Published var error: String?
  private var task: URLSessionDownloadTask?
  private var observation: NSKeyValueObservation?
  private var cancelled = false

  // Downloads each name in order, then calls done. Failures land in error.
  func start(_ names: [String], done: @escaping () -> Void) {
    busy = true
    error = nil
    cancelled = false
    guard let name = names.first else {
      busy = false
      return done()
    }
    status = "Checking \(name)…"
    fraction = 0
    Task {
      do {
        let expected = try await self.expected(for: name)
        let file = try await self.download(name, expected: expected)
        await MainActor.run { self.status = "Verifying \(name)…" }
        try await Task.detached { try Self.verify(file, expected) }.value
        let dest = Paths.models.appendingPathComponent("ggml-\(name).bin")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: file, to: dest)
        await MainActor.run { self.start(Array(names.dropFirst()), done: done) }
      } catch {
        await MainActor.run {
          self.busy = false
          if !self.cancelled { self.error = error.localizedDescription }
        }
      }
    }
  }

  func cancel() {
    cancelled = true
    task?.cancel()
  }

  struct Expected {
    let sha256: String
    let size: Int64
  }

  // HEAD without following the redirect: the Hub's own response carries the
  // checksum; the CDN it redirects to doesn't.
  private func expected(for name: String) async throws -> Expected {
    var request = URLRequest(url: Models.url(for: name))
    request.httpMethod = "HEAD"
    let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (_, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse,
      let tag = http.value(forHTTPHeaderField: "x-linked-etag"),
      let size = Int64(http.value(forHTTPHeaderField: "x-linked-size") ?? "")
    else { throw Self.failure("Couldn't get the checksum for \(name) from Hugging Face.") }
    return Expected(sha256: tag.trimmingCharacters(in: CharacterSet(charactersIn: "\"W/")).lowercased(), size: size)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  // Downloads to a .part file next to the models, resuming on failure.
  private func download(_ name: String, expected: Expected) async throws -> URL {
    let part = Paths.models.appendingPathComponent("ggml-\(name).bin.part")
    var resumeData: Data?
    for attempt in 1...4 {
      do {
        return try await withCheckedThrowingContinuation { cont in
          let handler: (URL?, URLResponse?, Error?) -> Void = { tmp, response, error in
            if let error { return cont.resume(throwing: error) }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
              return cont.resume(throwing: Self.failure("Download of \(name) failed (HTTP \(http.statusCode))."))
            }
            // The temp file is deleted when this handler returns, so move it now.
            do {
              try? FileManager.default.removeItem(at: part)
              try FileManager.default.moveItem(at: tmp!, to: part)
              cont.resume(returning: part)
            } catch {
              cont.resume(throwing: error)
            }
          }
          let task =
            resumeData.map { URLSession.shared.downloadTask(withResumeData: $0, completionHandler: handler) }
            ?? URLSession.shared.downloadTask(with: Models.url(for: name), completionHandler: handler)
          DispatchQueue.main.async {
            self.status = attempt == 1 ? "Downloading \(name)…" : "Resuming \(name)…"
            self.observation = task.progress.observe(\.fractionCompleted) { progress, _ in
              DispatchQueue.main.async { self.fraction = progress.fractionCompleted }
            }
            self.task = task
          }
          task.resume()
        }
      } catch {
        let nsError = error as NSError
        resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if cancelled || nsError.code == NSURLErrorCancelled || resumeData == nil || attempt == 4 { throw error }
      }
    }
    throw Self.failure("Download of \(name) failed.")
  }

  private static func verify(_ file: URL, _ expected: Expected) throws {
    let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? -1
    guard size == expected.size else {
      try? FileManager.default.removeItem(at: file)
      throw failure("The download was incomplete (\(size) of \(expected.size) bytes). Try again.")
    }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == expected.sha256 else {
      try? FileManager.default.removeItem(at: file)
      throw failure("The download didn't match Hugging Face's checksum, so it was discarded. Try again.")
    }
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "Followspot", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
