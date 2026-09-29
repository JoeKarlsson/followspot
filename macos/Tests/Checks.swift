import CryptoKit
import Foundation

// Checks for the app's non-UI logic, run by macos/test.sh (compiled together
// with those source files; no test framework, since Swift Testing and XCTest
// need Xcode). The download checks run a real local server, so resume and
// checksum handling are exercised end to end.

var failures = 0
var passed = 0

func expect(_ condition: @autoclosure () throws -> Bool, _ what: String, line: Int = #line) {
  do {
    if try condition() {
      passed += 1
      return
    }
    print("  FAIL line \(line): \(what)")
  } catch {
    print("  FAIL line \(line): \(what) threw \(error)")
  }
  failures += 1
}

func expectThrows(_ what: String, line: Int = #line, _ body: () throws -> Void) {
  do {
    try body()
    print("  FAIL line \(line): \(what) didn't throw")
    failures += 1
  } catch {
    passed += 1
  }
}

struct Missing: Error {}
func require<T>(_ value: T?) throws -> T {
  guard let value else { throw Missing() }
  return value
}

func tempDir() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("fs-test-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// Keep in step with scriptFileName() in public/native.js (test/native.test.mjs).
func scriptNames() {
  expect(Scripts.fileName("  Launch video ") == "Launch video.md", "adds .md and trims")
  expect(Scripts.fileName("notes.txt") == "notes.txt", "keeps .txt")
  expect(Scripts.fileName("Intro.MD") == "Intro.MD", "keeps .MD")
  expect(Scripts.fileName("v1.2 take") == "v1.2 take.md", "a dot isn't an extension")
  for bad in ["", "   ", ".secret", "../up", "a/b", "a:b", "a\\b"] {
    expect(Scripts.fileName(bad) == nil, "refuses \(bad.debugDescription)")
  }
}

func versions() {
  expect(Updates.isNewer("v0.2.0", than: "0.1.0"), "v0.2.0 > 0.1.0")
  expect(Updates.isNewer("0.10.0", than: "0.9.9"), "numeric, not string, compare")
  expect(Updates.isNewer("v1", than: "0.9"), "missing parts count as 0")
  expect(!Updates.isNewer("v0.1.0", than: "0.1.0"), "same version")
  expect(!Updates.isNewer("0.1", than: "0.1.0"), "0.1 == 0.1.0")
  expect(!Updates.isNewer("v0.1.0", than: "0.2.0"), "older")
  expect(!Updates.isNewer("v0.2.0-beta.1", than: "0.2.0"), "pre-release suffix ignored")

  let ok = Data(#"{"tag_name":"v0.3.0","html_url":"https://example.com/r","draft":false}"#.utf8)
  expect(Updates.release(from: ok)?.version == "v0.3.0", "reads the tag")
  expect(Updates.release(from: ok)?.page.absoluteString == "https://example.com/r", "reads the page")
  expect(Updates.release(from: Data(#"{"tag_name":"v9","draft":true}"#.utf8)) == nil, "skips drafts")
  expect(Updates.release(from: Data(#"{"tag_name":"v9","prerelease":true}"#.utf8)) == nil, "skips pre-releases")
  expect(Updates.release(from: Data("not json".utf8)) == nil, "bad JSON")
}

func serverFlags() throws {
  let dir = try tempDir()
  let small = dir.appendingPathComponent("ggml-base.en.bin")
  let large = dir.appendingPathComponent("ggml-large-v3-turbo.bin")
  FileManager.default.createFile(atPath: small.path, contents: Data(count: 1024))
  // Sparse: reports 1.6 GB without using the disk space.
  FileManager.default.createFile(atPath: large.path, contents: nil)
  let handle = try FileHandle(forWritingTo: large)
  try handle.truncate(atOffset: 1_600_000_000)
  try handle.close()
  let vad = URL(fileURLWithPath: "/m/ggml-silero-v6.2.0.bin")

  expect(
    Server.optionArgs(model: large, vadModel: vad, vad: true, fastMode: true, extra: [])
      == ["--vad", "-vm", vad.path, "-ac", "512"], "fast mode on a large model")
  expect(
    Server.optionArgs(model: small, vadModel: vad, vad: true, fastMode: true, extra: [])
      == ["--vad", "-vm", vad.path], "no fast mode on a small model")
  expect(
    Server.optionArgs(model: large, vadModel: nil, vad: true, fastMode: false, extra: []).isEmpty,
    "VAD needs its model; fast mode off")
  expect(
    Server.optionArgs(model: large, vadModel: nil, vad: true, fastMode: true, extra: ["-ac", "768"])
      == ["-ac", "768"], "an explicit -ac wins over fast mode")
  expect(
    Server.optionArgs(model: large, vadModel: nil, vad: false, fastMode: true, extra: ["--no-gpu"])
      == ["-ac", "512", "--no-gpu"], "extra flags go last")

  // Add Model File… links models in; a link's own size is a few bytes.
  let link = dir.appendingPathComponent("ggml-linked.bin")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: large)
  expect(Server.isLarge(link), "a link to a large model counts as large")
  expect(!Server.isLarge(small), "small model")
}

func modelRanking() throws {
  let dir = try tempDir()
  let studioDir = try tempDir().appendingPathComponent("Screen Studio/models")
  try FileManager.default.createDirectory(at: studioDir, withIntermediateDirectories: true)
  let studio = studioDir.appendingPathComponent("ggml-medium.bin")
  for name in [
    "ggml-base.en.bin", "ggml-small.en.bin", "ggml-large-v3-turbo.bin", "ggml-tiny.en.bin",
    "ggml-silero-v6.2.0.bin", "ggml-small.en.bin.part",
  ] {
    FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
  }
  FileManager.default.createFile(atPath: studio.path, contents: Data())
  let names = Models.installed(in: [dir], screenStudio: studio).map(Models.label(for:))
  expect(
    names == ["large-v3-turbo", "medium (Screen Studio)", "small.en", "base.en", "tiny.en"],
    "largest first, Screen Studio above small, no VAD or partial files: \(names)")
}

func downloadChecks() throws {
  let sha = String(repeating: "ab", count: 32)
  let ok = HTTPURLResponse(
    url: URL(string: "https://h")!, statusCode: 302, httpVersion: nil,
    headerFields: ["x-linked-etag": "\"\(sha.uppercased())\"", "x-linked-size": "1234"])!
  let expected = ModelDownload.expected(from: ok)
  expect(expected?.sha256 == sha && expected?.size == 1234, "reads Hugging Face's checksum headers")
  let bad = HTTPURLResponse(
    url: URL(string: "https://h")!, statusCode: 302, httpVersion: nil,
    headerFields: ["x-linked-etag": "\"not-a-sha\"", "x-linked-size": "1234"])!
  expect(ModelDownload.expected(from: bad) == nil, "refuses an etag that isn't a SHA-256")

  let dir = try tempDir()
  let data = Data("model bytes".utf8)
  let right = ModelDownload.Expected(sha256: sha256(data), size: Int64(data.count))

  let good = dir.appendingPathComponent("ok.bin")
  try data.write(to: good)
  expect((try? ModelDownload.verify(good, right)) != nil, "accepts a matching file")

  let short = dir.appendingPathComponent("short.bin")
  try data.prefix(5).write(to: short)
  expectThrows("a truncated file") { try ModelDownload.verify(short, right) }
  expect(!FileManager.default.fileExists(atPath: short.path), "a truncated file is deleted")

  let corrupt = dir.appendingPathComponent("bad.bin")
  try Data("model bytez".utf8).write(to: corrupt)
  expectThrows("a corrupted file") { try ModelDownload.verify(corrupt, right) }
  expect(!FileManager.default.fileExists(atPath: corrupt.path), "a corrupted file is deleted")
}

// A server that drops the connection halfway through the first response and
// honors Range after that, as the Hugging Face CDN does.
func resumeAfterDrop() async throws {
  let dir = try tempDir()
  var payload = Data(count: 8 << 20)
  for i in stride(from: 0, to: payload.count, by: 4096) { payload[i] = UInt8(truncatingIfNeeded: i >> 12) }
  try payload.write(to: dir.appendingPathComponent("model.bin"))
  let log = dir.appendingPathComponent("requests.log")
  let script = dir.appendingPathComponent("server.py")
  try dropServer.write(to: script, atomically: true, encoding: .utf8)

  let python = Process()
  python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  python.arguments = ["python3", script.path, dir.path, log.path]
  let out = Pipe()
  python.standardOutput = out
  try python.run()
  defer { python.terminate() }
  let portLine = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
  let port = try require(Int(portLine.trimmingCharacters(in: .whitespacesAndNewlines)))

  let part = dir.appendingPathComponent("model.bin.part")
  let file = try await ModelDownload().download(
    from: URL(string: "http://127.0.0.1:\(port)/model.bin")!, to: part, label: "test")
  expect(try Data(contentsOf: file) == payload, "the resumed file is complete and intact")
  let requests = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
  expect(requests.count == 2, "one dropped request, one resume: \(requests)")
  expect(requests.first == "full", "first request was the full file")
  expect(requests.last?.hasPrefix("range bytes=") == true, "second request resumed with Range")
}

let dropServer = #"""
  import http.server, os, socketserver, sys
  root, log = sys.argv[1], sys.argv[2]
  data = open(os.path.join(root, "model.bin"), "rb").read()
  class H(http.server.BaseHTTPRequestHandler):
      def log_message(self, *a): pass
      def do_GET(self):
          rng = self.headers.get("Range")
          with open(log, "a") as f: f.write(("range " + rng if rng else "full") + "\n")
          start = int(rng.split("=")[1].split("-")[0]) if rng else 0
          self.send_response(206 if rng else 200)
          self.send_header("Accept-Ranges", "bytes")
          self.send_header("ETag", '"fixed"')
          self.send_header("Last-Modified", "Mon, 01 Jan 2024 00:00:00 GMT")
          self.send_header("Content-Length", str(len(data) - start))
          if rng: self.send_header("Content-Range", "bytes %d-%d/%d" % (start, len(data) - 1, len(data)))
          self.end_headers()
          if rng:
              self.wfile.write(data[start:])
          else:
              self.wfile.write(data[: len(data) // 2])
              self.wfile.flush()
              self.connection.shutdown(2)  # drop mid-transfer
  s = socketserver.ThreadingTCPServer(("127.0.0.1", 0), H)
  print(s.server_address[1], flush=True)
  s.serve_forever()
  """#

@main struct Checks {
  static func main() async {
    let suites: [(String, () async throws -> Void)] = [
      ("script names", { scriptNames() }),
      ("versions", { versions() }),
      ("server flags", { try serverFlags() }),
      ("model ranking", { try modelRanking() }),
      ("download checks", { try downloadChecks() }),
      ("resume after a dropped connection", { try await resumeAfterDrop() }),
    ]
    for (name, run) in suites {
      let before = failures
      do {
        try await run()
      } catch {
        print("  FAIL: threw \(error)")
        failures += 1
      }
      print("\(failures == before ? "ok  " : "FAIL") \(name)")
    }
    print("\n\(passed) passed, \(failures) failed")
    exit(failures == 0 ? 0 : 1)
  }
}
