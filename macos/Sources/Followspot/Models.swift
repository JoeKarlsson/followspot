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
final class ModelDownload: NSObject, ObservableObject {
  @Published var choice = Models.defaultChoice
  @Published var vad = true
  @Published var fraction: Double = 0
  @Published var status = ""
  @Published var busy = false
  @Published var error: String?
  private var task: URLSessionDownloadTask?
  private var observation: NSKeyValueObservation?

  // Downloads each name in order, then calls done. Failures land in error.
  func start(_ names: [String], done: @escaping () -> Void) {
    busy = true
    error = nil
    guard let name = names.first else {
      busy = false
      return done()
    }
    status = "Downloading \(name)…"
    fraction = 0
    let dest = Paths.models.appendingPathComponent("ggml-\(name).bin")
    let task = URLSession.shared.downloadTask(with: Models.url(for: name)) { tmp, response, error in
      var failure = error
      if failure == nil, let http = response as? HTTPURLResponse, http.statusCode != 200 {
        failure = NSError(
          domain: "Followspot", code: http.statusCode,
          userInfo: [NSLocalizedDescriptionKey: "Download of \(name) failed (HTTP \(http.statusCode))."])
      }
      if failure == nil, let tmp {
        // The temp file is deleted when this handler returns, so move it now.
        do {
          try? FileManager.default.removeItem(at: dest)
          try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
          failure = error
        }
      }
      DispatchQueue.main.async {
        if let failure {
          self.busy = false
          if (failure as NSError).code != NSURLErrorCancelled { self.error = failure.localizedDescription }
          return
        }
        self.start(Array(names.dropFirst()), done: done)
      }
    }
    observation = task.progress.observe(\.fractionCompleted) { progress, _ in
      DispatchQueue.main.async { self.fraction = progress.fractionCompleted }
    }
    self.task = task
    task.resume()
  }

  func cancel() {
    task?.cancel()
  }
}
