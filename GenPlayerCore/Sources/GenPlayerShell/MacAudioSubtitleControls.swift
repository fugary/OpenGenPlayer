#if os(macOS) || os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct MacGeneratedSubtitleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "srt") ?? .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Shared form fields; recognition progress never changes the destination picker identity.
@available(iOS 16.0, *)
struct AudioSubtitleOutputControls: View {
    @ObservedObject var model: MacAudioSubtitleJob
    @ObservedObject var translation: MacSubtitleTranslation
    @AppStorage("enableSecondarySubtitlesBeta") private var secondaryEnabled = false

    var body: some View {
        Group {
            Picker(platformShellString("AS.OriginalDestination"), selection: Binding(get: { model.originalDestination }, set: model.setOriginalDestination)) {
                Text(platformShellString("Primary Subtitle")).tag(MacAudioSubtitleJob.Destination.primary)
                Text(platformShellString("Secondary Subtitle")).tag(MacAudioSubtitleJob.Destination.secondary)
                Text(platformShellString("AS.Hidden")).tag(MacAudioSubtitleJob.Destination.none)
            }
            Toggle(platformShellString("AS.AutoTranslate"), isOn: Binding(get: { model.automaticallyTranslate }, set: model.setAutomaticallyTranslate))
            if model.automaticallyTranslate {
                Picker(platformShellString("Translation.Target"), selection: Binding(get: { translation.targetLanguage }, set: translation.setTarget)) {
                    ForEach(Array(Set(translation.languages + [translation.targetLanguage])).sorted { translation.languageName($0) < translation.languageName($1) }, id: \.self) { code in
                        Text(translation.languageName(code)).tag(code)
                    }
                }
                Picker(platformShellString("AS.TranslationDestination"), selection: Binding(get: { model.translationDestination }, set: model.setTranslationDestination)) {
                    Text(platformShellString("Primary Subtitle")).tag(MacAudioSubtitleJob.Destination.primary)
                    Text(platformShellString("Secondary Subtitle")).tag(MacAudioSubtitleJob.Destination.secondary)
                }
                if model.originalDestination == model.translationDestination {
                    Picker(platformShellString("SI.BilingualOrder"), selection: Binding(get: { translation.originalFirst }, set: translation.setOriginalFirst)) {
                        Text(platformShellString("SI.OriginalFirst")).tag(true)
                        Text(platformShellString("SI.TranslationFirst")).tag(false)
                    }
                    Text(platformShellString("AS.MergeHint")).font(.caption).foregroundColor(.secondary)
                }
                if translation.enabled {
                    Text(translation.statusMessage(for: translation.statusKey)).font(.caption).foregroundColor(.secondary)
                    if translation.canRetry { Button(platformShellString("Retry")) { translation.retry() } }
                }
            }
            if model.needsSecondary && !secondaryEnabled {
                Text(platformShellString("AS.SecondaryRequired")).font(.caption)
                Button(platformShellString("AS.EnableSecondary")) {
                    secondaryEnabled = true
                    model.applyOutputConfiguration()
                }
            }
            Text(platformShellString(model.originalDestination == .none && !model.automaticallyTranslate ? "AS.CacheOnlyHint" : "AS.ReplaceHint"))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        #if os(iOS)
        .pickerStyle(.navigationLink)
        #endif
        .disabled(model.inspecting || (model.running && model.cache == nil))
        .onAppear {
            if #available(macOS 15.0, iOS 18.0, *) { Task { @MainActor in await translation.loadLanguages() } }
        }
    }
}

#if os(macOS)
struct MacAudioSubtitleControls: View {
    @ObservedObject var model: MacAudioSubtitleJob
    @ObservedObject var translation: MacSubtitleTranslation
    @Environment(\.presentationMode) private var presentationMode
    @AppStorage("enableSecondarySubtitlesBeta") private var secondaryEnabled = false
    @State private var confirmDelete = false
    @State private var exporting = false
    @State private var exportText = ""
    @State private var exportFailed = false

    private func languageName(_ id: String) -> String {
        let app = platformResolvedLanguage(for: UserDefaults.standard.string(forKey: "appLanguage") ?? "system")
        return Locale(identifier: app).localizedString(forIdentifier: id) ?? id
    }
    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text(platformShellString("AS.Title")).font(.headline)
            Text(platformShellString(model.source?.fileAudio != nil ? (model.source?.fileAudio?.access.kind == "smb" ? "AS.SMBPrivacy" : "AS.FilePrivacy") :
                (model.source?.remote == nil ? "AS.Privacy" : "AS.RemotePrivacy"))).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.source?.remote?.usesVideoRoute == true {
                Text(platformShellString("AS.MultiTrackNetwork")).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let source = model.source {
                Picker(platformShellString("AS.AudioTrack"), selection: $model.selectedTrack) {
                    Text(platformShellString("AS.ChooseTrack")).tag(Int32(-1))
                    ForEach(source.tracks) { track in
                        Text(track.name ?? String(format: platformShellString("AS.TrackFormat"), track.ordinal,
                                    track.language.map(languageName) ?? platformShellString("AS.UnknownLanguage")))
                            .tag(track.id)
                    }
                }
                .disabled(model.running || model.inspecting)
                Picker(platformShellString("AS.Language"), selection: $model.language) {
                    Text(platformShellString("AS.ChooseLanguage")).tag("")
                    ForEach(Array(Set(model.languages + (model.language.isEmpty ? [] : [model.language]))).sorted(), id: \.self) {
                        Text(languageName($0)).tag($0)
                    }
                }
                .disabled(model.running || model.inspecting)
            }
            AudioSubtitleOutputControls(model: model, translation: translation)
            Text(platformShellString(model.status)).font(.callout).fixedSize(horizontal: false, vertical: true)
            if model.running || model.inspecting {
                if model.status == "AS.Generating" { ProgressView(value: model.progress) }
                else { ProgressView().controlSize(.small) }
            }
            if let cache = model.cache {
                Text(String(format: platformShellString("AS.ProgressFormat"), cache.completedDuration / 60, cache.duration / 60))
                    .font(.caption).foregroundColor(.secondary)
                if let track = model.activeTrack.flatMap({ id in model.source?.tracks.first { $0.id == id } }),
                   let language = model.activeLanguage {
                    Text(String(format: platformShellString("AS.TrackFormat"), track.ordinal, languageName(language)))
                        .font(.caption).foregroundColor(.secondary)
                }
                if !model.cues.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(model.cues.filter { $0.end > model.playbackTime }.prefix(3)), id: \.id) { cue in
                                Text(cue.text).font(.callout).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 90)
                }
                Text(platformShellString("AS.CacheHint")).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(platformShellString(cache.isComplete ? "AS.Export" : "AS.ExportPartial")) {
                        exportText = MacAudioSubtitlePlan.srt(model.cues)
                        exporting = true
                    }.disabled(model.cues.isEmpty)
                    Button(platformShellString("AS.Delete"), role: .destructive) { confirmDelete = true }
                        .disabled(model.inspecting)
                }
            }
            if exportFailed { Text(platformShellString("AS.StorageFailed")).foregroundColor(.red) }
        }
        .padding(24)
        }
            Divider()
            HStack {
                if model.running {
                    Button(platformShellString("AS.Cancel")) { model.cancel() }
                } else if !model.completedSelection || model.display == .off {
                    Button(platformShellString(model.completedSelection ? "AS.UseCached" : (model.automaticallyTranslate ? "SI.GenerateTranslate" : "AS.Start"))) { model.useOrGenerate() }
                        .disabled(!model.canStart || !model.outputAvailable)
                }
                Spacer()
                Button(platformShellString("Done")) { presentationMode.wrappedValue.dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(24)
        }
        .frame(width: 460)
        .frame(maxHeight: 650)
        .onAppear { model.retryInspectionIfNeeded(); model.refreshDefaultAudioTrack() }
        .alert(platformShellString("AS.Delete"), isPresented: $confirmDelete) {
            Button(platformShellString("AS.Delete"), role: .destructive) { model.deleteCache() }
            Button(platformShellString("Cancel"), role: .cancel) {}
        } message: { Text(platformShellString("AS.DeleteConfirm")) }
        .fileExporter(isPresented: $exporting, document: MacGeneratedSubtitleDocument(text: exportText),
                      contentType: MacGeneratedSubtitleDocument.readableContentTypes[0], defaultFilename: "subtitle.\(model.activeLanguage ?? "und").generated.srt") { result in
            if case .failure = result { exportFailed = true }
        }
    }
}
#endif
#endif
