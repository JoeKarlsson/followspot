import SwiftUI

struct StatusButton {
  let label: String
  let action: () -> Void
}

// Shown in the prompter window until the page is up: loading, or an error.
struct StatusView: View {
  let title: String
  let detail: String?
  let busy: Bool
  let buttons: [StatusButton]

  var body: some View {
    VStack(spacing: 16) {
      if busy { ProgressView().controlSize(.large) }
      Text(title).font(.title2)
      if let detail {
        ScrollView {
          Text(detail)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 640, maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
      }
      if !buttons.isEmpty {
        HStack {
          ForEach(buttons.indices, id: \.self) { i in
            Button(buttons[i].label, action: buttons[i].action)
          }
        }
      }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .preferredColorScheme(.dark)
  }
}

// Model picker and downloader: the first-run sheet, and Model > Download.
struct DownloadView: View {
  @ObservedObject var download: ModelDownload
  let onDone: (_ model: String) -> Void
  let onCancel: () -> Void

  private let haveVAD = Models.vad != nil
  private let installed = Set(Models.installed.map(Models.label(for:)))

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Choose a Whisper model").font(.title2)
      Text(
        "Followspot transcribes on this Mac, so it needs a model file. Bigger models are more accurate but slower. "
          + "You can download another one later from the Model menu."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      Picker("", selection: $download.choice) {
        ForEach(Models.choices) { model in
          VStack(alignment: .leading, spacing: 2) {
            Text("\(model.name)  ·  \(model.size)\(installed.contains(model.name) ? "  ·  installed" : "")")
            Text(model.note).font(.caption).foregroundStyle(.secondary)
          }
          .tag(model.name)
          .padding(.vertical, 2)
        }
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
      .disabled(download.busy)

      if !haveVAD {
        Toggle("Also get voice activity detection (under 1 MB, recommended)", isOn: $download.vad)
          .disabled(download.busy)
        Text("Stops Whisper inventing words during pauses and room noise.")
          .font(.caption).foregroundStyle(.secondary)
      }

      if download.busy {
        ProgressView(value: download.fraction) {
          Text(download.status).font(.caption)
        }
      }
      if let error = download.error {
        Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          download.cancel()
          onCancel()
        }
        .keyboardShortcut(.cancelAction)
        Button(installed.contains(download.choice) && (haveVAD || !download.vad) ? "Use" : "Download", action: start)
          .keyboardShortcut(.defaultAction)
          .disabled(download.busy)
      }
    }
    .padding(24)
    .frame(width: 480)
  }

  private func start() {
    let choice = download.choice
    var names = installed.contains(choice) ? [] : [choice]
    if download.vad && !haveVAD { names.append(Models.vadName) }
    download.start(names) { onDone(choice) }
  }
}
