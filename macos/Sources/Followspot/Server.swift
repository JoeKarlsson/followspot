import Darwin
import Foundation

// Runs whisper-server as a child process, with the flags ./followspot uses.
// It serves the page from Paths.www and transcribes at /inference, so the
// page and the model share one origin, exactly as with the launcher.
final class Server {
  // Fixed so the page's origin (and so its localStorage settings) stays the
  // same between launches. 8177, not the launcher's 8178, so both can run.
  static var port: Int {
    let saved = UserDefaults.standard.integer(forKey: "port")
    return saved > 0 ? saved : 8177
  }

  var url: URL { URL(string: "http://127.0.0.1:\(Server.port)/")! }
  var onExit: ((String) -> Void)?
  private var process: Process?

  var isRunning: Bool { process?.isRunning ?? false }

  func start(model: URL) throws {
    guard let binary = Paths.whisperServer else {
      throw Server.error("whisper-server is missing from the app. Rebuild it with macos/build-whisper.sh.")
    }
    if Server.portInUse(Server.port) {
      throw Server.error(
        "Port \(Server.port) is already in use. Quit whatever is using it, or pick another port with:\n\n"
          + "defaults write \(Bundle.main.bundleIdentifier ?? "com.joekarlsson.followspot") port -int 8179")
    }

    var args = [
      "-m", model.path,
      "--host", "127.0.0.1",
      "--port", String(Server.port),
      "--public", Paths.www.path,
      "-l", "en",
      "-nt",
      "-t", String(Server.threads),
    ]
    // VAD stops Whisper inventing words during pauses; see the README.
    if UserDefaults.standard.object(forKey: "vad") as? Bool ?? true, let vad = Models.vad {
      args += ["--vad", "-vm", vad.path]
    }
    // The launcher's `-- flags`: `defaults write <id> extraArgs -array -ac 512`.
    // defaults stores 512 as a number, so take any value, not just strings.
    args += (UserDefaults.standard.array(forKey: "extraArgs") ?? []).map { "\($0)" }

    FileManager.default.createFile(atPath: Paths.log.path, contents: nil)
    let log = try FileHandle(forWritingTo: Paths.log)
    log.write("whisper-server \(args.joined(separator: " "))\n\n".data(using: .utf8)!)

    let process = Process()
    process.executableURL = binary
    process.arguments = args
    process.standardOutput = log
    process.standardError = log
    process.terminationHandler = { [weak self] proc in
      try? FileManager.default.removeItem(at: Paths.pidFile)
      DispatchQueue.main.async {
        guard let self, self.process === proc else { return }
        self.process = nil
        self.onExit?(Server.logTail())
      }
    }
    try process.run()
    self.process = process
    try? String(process.processIdentifier).write(to: Paths.pidFile, atomically: true, encoding: .utf8)
  }

  // Polls the page until the model has loaded and the server answers.
  func waitUntilReady(timeout: TimeInterval = 180) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      guard isRunning else { return false }
      var request = URLRequest(url: url)
      request.timeoutInterval = 1
      if let (_, response) = try? await URLSession.shared.data(for: request),
        (response as? HTTPURLResponse)?.statusCode == 200
      {
        return true
      }
      try? await Task.sleep(nanoseconds: 500_000_000)
    }
    return false
  }

  func stop() {
    guard let process else { return }
    self.process = nil  // an intended stop isn't reported through onExit
    process.terminate()
    process.waitUntilExit()
    try? FileManager.default.removeItem(at: Paths.pidFile)
  }

  // A crashed or force-quit app leaves its server running and holding the
  // port. Kill it, but only if the saved PID really is a whisper-server.
  static func killOrphan() {
    guard let text = try? String(contentsOf: Paths.pidFile, encoding: .utf8),
      let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return }
    try? FileManager.default.removeItem(at: Paths.pidFile)
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
      String(cString: buffer).hasSuffix("/whisper-server")
    else { return }
    kill(pid, SIGTERM)
    for _ in 0..<50 where kill(pid, 0) == 0 { usleep(100_000) }
  }

  // Performance cores only, like the launcher: efficiency cores slow it down.
  static var threads: Int {
    for name in ["hw.perflevel0.physicalcpu", "hw.physicalcpu"] {
      var value: Int32 = 0
      var size = MemoryLayout<Int32>.size
      if sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 { return Int(value) }
    }
    return 4
  }

  static func logTail(lines: Int = 15) -> String {
    let text = (try? String(contentsOf: Paths.log, encoding: .utf8)) ?? ""
    return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
  }

  private static func portInUse(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    // Like the server itself, so a just-stopped server's TIME_WAIT doesn't
    // count as in use; a live listener still does.
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return result != 0
  }

  private static func error(_ message: String) -> NSError {
    NSError(domain: "Followspot", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
