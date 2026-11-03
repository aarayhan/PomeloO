import AppKit
import PomeloOCore
import SwiftUI

/// The window a tool shows before it runs: one form per tool, an error line, and Cancel and the tool's name.
/// Nothing here decides anything: the forms in PomeloOCore (`ToolForms`) turn what is typed into a request or say what is wrong.
@MainActor
final class ToolDialogController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onRun: ((ToolInvocation, [URL]) -> Void)?

    /// Shows the dialog for `toolID`. `files` are the selection (in the order Finder gave them).
    func show(toolID: String, files: [URL], catalog: Catalog, onRun: @escaping (ToolInvocation, [URL]) -> Void) {
        window?.close()
        self.onRun = onRun
        let title = catalog.tools[toolID]?.name ?? toolID
        let view = ToolDialogView(toolID: toolID, title: title, files: files) { [weak self] invocation, ordered in
            self?.window?.close()
            onRun(invocation, ordered)
        } cancel: { [weak self] in
            self?.window?.close()
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onRun = nil
    }
}

struct ToolDialogView: View {
    let toolID: String
    let title: String
    let files: [URL]
    let run: (ToolInvocation, [URL]) -> Void
    let cancel: () -> Void

    @State private var compress = CompressForm()
    @State private var metadata = MetadataForm()
    @State private var crop = CropForm()
    @State private var redact = RedactForm()
    @State private var adjust = AdjustForm()
    @State private var split = SplitForm()
    @State private var organize = OrganizeForm()
    @State private var merge: MergeForm
    @State private var password = PasswordForm()
    @State private var watermark = WatermarkForm()
    @State private var numbers = NumberForm()
    @State private var mediaCompress = MediaCompressForm()
    @State private var mediaMetadata = MediaMetadataForm()
    @State private var normalize = NormalizeForm()
    @State private var visualize = VisualizeForm()
    @State private var trim: TrimForm
    @State private var channels = ChannelsForm()
    @State private var bleep = BleepForm()
    @State private var videoCrop = VideoCropForm()
    @State private var speed = SpeedForm()
    @State private var snapshots = SnapshotForm()
    @State private var splitVideo = SplitVideoForm()
    @State private var videoRedact = VideoRedactForm()
    @State private var join: JoinForm
    @State private var error: String?

    private var isMedia: Bool { files.first.map(ToolForms.isMedia) ?? false }

    init(toolID: String, title: String, files: [URL], run: @escaping (ToolInvocation, [URL]) -> Void, cancel: @escaping () -> Void) {
        self.toolID = toolID
        self.title = title
        self.files = files
        self.run = run
        self.cancel = cancel
        _merge = State(initialValue: MergeForm(files: files))
        _join = State(initialValue: JoinForm(files: files))
        _trim = State(initialValue: TrimForm(isVideo: toolID == "trimVideo"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            form
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(title) { submit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submit() {
        do {
            let invocation = try makeInvocation()
            error = nil
            run(invocation, toolID == "mergePDF" ? merge.files : toolID == "joinVideos" ? join.files : files)
        } catch let problem as ToolFormError {
            error = problem.message
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func makeInvocation() throws -> ToolInvocation {
        switch toolID {
        case "compress": try isMedia ? mediaCompress.invocation() : compress.invocation()
        case "removeMetadata": try isMedia ? mediaMetadata.invocation() : metadata.invocation()
        case "normalizeAudio": try normalize.invocation()
        case "audioToVideo": try visualize.invocation()
        case "trimAudio", "trimVideo": try trim.invocation()
        case "audioChannels": try channels.invocation()
        case "redactAudio": try bleep.invocation()
        case "cropVideo": try videoCrop.invocation()
        case "changeVideoSpeed": try speed.invocation()
        case "videoSnapshots": try snapshots.invocation()
        case "splitVideo": try splitVideo.invocation()
        case "redactVideo": try videoRedact.invocation()
        case "joinVideos": try join.invocation()
        case "cropImage": try crop.invocation()
        case "redactImage": try redact.invocation()
        case "editImage": try adjust.invocation()
        case "splitPDF": try split.invocation()
        case "organizePDF": try organize.invocation()
        case "mergePDF": try merge.invocation()
        case "protectPDF": try password.protectInvocation()
        case "unlockPDF": password.unlockInvocation()
        case "watermarkPDF": try watermark.invocation()
        case "numberPDF": try numbers.invocation()
        default: throw ToolFormError("\(title) has no settings yet.")
        }
    }

    @ViewBuilder private var form: some View {
        switch toolID {
        case "compress": if isMedia { mediaCompressForm } else { compressForm }
        case "removeMetadata": if isMedia { mediaMetadataForm } else { metadataForm }
        case "normalizeAudio": normalizeForm
        case "audioToVideo": visualizeForm
        case "trimAudio", "trimVideo": trimForm
        case "audioChannels": channelsForm
        case "redactAudio": bleepForm
        case "cropVideo": videoCropForm
        case "changeVideoSpeed": speedForm
        case "videoSnapshots": snapshotForm
        case "splitVideo": splitVideoForm
        case "redactVideo": videoRedactForm
        case "joinVideos": joinForm
        case "cropImage": cropForm
        case "redactImage": redactForm
        case "editImage": adjustForm
        case "splitPDF": splitForm
        case "organizePDF": organizeForm
        case "mergePDF": mergeForm
        case "protectPDF": protectForm
        case "unlockPDF": unlockForm
        case "watermarkPDF": watermarkForm
        case "numberPDF": numberForm
        default: Text("\(title) has no settings yet.")
        }
    }

    // MARK: pictures

    private var compressForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Quality", selection: $compress.quality) {
                Text("Custom").tag(CompressForm.Quality.custom)
                Text("High quality").tag(CompressForm.Quality.highQuality)
                Text("Balanced").tag(CompressForm.Quality.balanced)
                Text("Smallest").tag(CompressForm.Quality.smallest)
            }
            if compress.quality == .custom {
                slider("Target size", value: $compress.percent, range: 5...95, unit: "%")
                Stepper("Exact size (KB, 0 = off): \(compress.targetKB)", value: $compress.targetKB, in: 0...10_000_000, step: 50)
            }
            slider("Resize", value: $compress.resizePercent, range: 10...100, unit: "%")
            Text("If the target cannot be reached by lowering the quality, the picture is made smaller and you are told.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var metadataForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Action", selection: $metadata.mode) {
                Text("Remove everything").tag(MetadataForm.Mode.remove)
                Text("Edit fields").tag(MetadataForm.Mode.edit)
            }.pickerStyle(.segmented)
            if metadata.mode == .edit {
                TextField("Title", text: $metadata.title)
                TextField("Artist", text: $metadata.artist)
                TextField("Copyright", text: $metadata.copyright)
                TextField("Camera make", text: $metadata.make)
                TextField("Camera model", text: $metadata.model)
                TextField("Software", text: $metadata.software)
                Text("Empty fields stay as they are.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Camera, location and caption data are removed; the colour profile stays.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var cropForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Aspect", selection: $crop.aspect) {
                ForEach(CropForm.aspects, id: \.self) { Text($0 == "free" ? "Free" : $0).tag($0) }
            }
            HStack {
                Text("Exact size")
                TextField("Width", value: $crop.width, format: .number).frame(width: 70)
                Text("×")
                TextField("Height", value: $crop.height, format: .number).frame(width: 70)
                Text("px")
            }
            Text("Crops from the middle. Choosing the area by hand comes later.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var redactForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Cover", selection: $redact.auto) {
                Text("Faces").tag(RedactOptions.Auto.faces)
                Text("Text").tag(RedactOptions.Auto.text)
                Text("Faces and text").tag(RedactOptions.Auto.both)
            }
            Picker("Style", selection: $redact.style) {
                Text("Pixelate").tag(RedactOptions.Style.pixelate)
                Text("Blur").tag(RedactOptions.Style.blur)
                Text("Solid colour").tag(RedactOptions.Style.color)
            }
            if redact.style == .color {
                ColorPicker("Colour", selection: hexBinding($redact.color), supportsOpacity: false)
            }
            Text("Found on this Mac with Vision; nothing is uploaded. Drawing areas by hand comes later.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var adjustForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                doubleSlider("Exposure", $adjust.options.exposure, -3...3)
                intSlider("Contrast", $adjust.options.contrast)
                intSlider("Highlights", $adjust.options.highlights)
                intSlider("Shadows", $adjust.options.shadows)
                intSlider("Saturation", $adjust.options.saturation)
                intSlider("Temperature", $adjust.options.temperature)
                intSlider("Tint", $adjust.options.tint)
                intSlider("Clarity", $adjust.options.clarity, 0...100)
                intSlider("Dehaze", $adjust.options.dehaze, 0...100)
                intSlider("Sharpness", $adjust.options.sharpness, 0...100)
                intSlider("Noise reduction", $adjust.options.noiseReduction, 0...100)
                intSlider("Grain", $adjust.options.grain, 0...100)
                intSlider("Vignette", $adjust.options.vignette, 0...100)
                Picker("Rotate", selection: $adjust.options.rotate) {
                    ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                }
                Picker("Flip", selection: $adjust.options.flip) {
                    Text("None").tag(AdjustOptions.Flip.none)
                    Text("Horizontal").tag(AdjustOptions.Flip.horizontal)
                    Text("Vertical").tag(AdjustOptions.Flip.vertical)
                }
                Toggle("Black and white", isOn: $adjust.options.grayscale)
                HStack {
                    Button("Reset") { adjust.options = AdjustOptions() }
                    Text("The result is a new copy. A live preview comes later.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 430)
    }

    // MARK: PDF

    private var splitForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Page ranges, e.g. 1-3, 5", text: $split.ranges)
            Text("Leave empty for one file per page. The files go in a new folder.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var organizeForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Page order, e.g. 3, 1, 2-4", text: $organize.order)
            Text("Pages you leave out are removed; a page named twice is copied. Empty keeps every page.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Turn pages, e.g. 2:90, 4:180", text: $organize.rotations)
            Text("Page numbers here are the numbers in the result. Seeing the pages comes later.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var mergeForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Order of the documents").font(.callout)
            ForEach(Array(merge.files.enumerated()), id: \.offset) { index, file in
                HStack {
                    Text("\(index + 1).").foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                    Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { merge.move(from: index, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                    Button { merge.move(from: index, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == merge.files.count - 1)
                }
            }
        }
    }

    private var protectForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Password", text: $password.password)
            SecureField("Password again", text: $password.confirmation)
            Text(PasswordForm.strengthNote).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var unlockForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Current password", text: $password.password)
            Text("Saves a copy that opens without a password.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var watermarkForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Text", text: $watermark.options.text)
            slider("Width", value: $watermark.options.sizePercent, range: 10...100, unit: "%")
            slider("Opacity", value: $watermark.options.opacityPercent, range: 5...100, unit: "%")
            Picker("Angle", selection: $watermark.options.angle) {
                ForEach([0, 45, 90], id: \.self) { Text("\($0)°").tag($0) }
            }.pickerStyle(.segmented)
            ColorPicker("Colour", selection: hexBinding($watermark.options.color), supportsOpacity: false)
        }
    }

    private var numberForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Style", selection: $numbers.options.style) {
                ForEach(NumberingOptions.Style.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Position", selection: $numbers.options.position) {
                ForEach(NumberForm.positions, id: \.self) { Text($0.capitalized).tag($0) }
            }
            Stepper("Start at \(numbers.options.start)", value: $numbers.options.start, in: 0...99_999)
            Stepper("Size \(numbers.options.size) pt", value: $numbers.options.size, in: 6...36)
        }
    }

    // MARK: audio and video

    private var mediaCompressForm: some View {
        let isVideo = files.first.map(ToolForms.isVideo) ?? false
        return VStack(alignment: .leading, spacing: 10) {
            Picker("Quality", selection: $mediaCompress.quality) {
                Text("Custom").tag(CompressForm.Quality.custom)
                Text("High quality").tag(CompressForm.Quality.highQuality)
                Text("Balanced").tag(CompressForm.Quality.balanced)
                Text("Smallest").tag(CompressForm.Quality.smallest)
            }
            if mediaCompress.quality == .custom {
                slider("Target size", value: $mediaCompress.percent, range: 5...95, unit: "%")
                Stepper("Exact size (KB, 0 = off): \(mediaCompress.targetKB)", value: $mediaCompress.targetKB, in: 0...100_000_000, step: 500)
            }
            if isVideo { slider("Resize", value: $mediaCompress.resizePercent, range: 10...100, unit: "%") }
            Text(isVideo ? "Sets the bitrate from the size you ask for, so the result lands near it, not exactly on it."
                         : "WAV and AIFF become FLAC, which loses nothing. Other formats lose quality as the size drops.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var mediaMetadataForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Action", selection: $mediaMetadata.mode) {
                Text("Remove everything").tag(MediaMetadataForm.Mode.remove)
                Text("Edit fields").tag(MediaMetadataForm.Mode.edit)
            }.pickerStyle(.segmented)
            if mediaMetadata.mode == .edit {
                TextField("Title", text: $mediaMetadata.title)
                TextField("Artist", text: $mediaMetadata.artist)
                TextField("Album", text: $mediaMetadata.album)
                TextField("Genre", text: $mediaMetadata.genre)
                TextField("Date or year", text: $mediaMetadata.date)
                TextField("Comment", text: $mediaMetadata.comment)
                Text("Empty fields stay as they are. The sound and picture are copied, not re-encoded.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Tags, cover art info and chapters are removed. The sound and picture are copied, not re-encoded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var normalizeForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Target", selection: $normalize.options.loudness) {
                ForEach(NormalizeForm.presets, id: \.loudness) { Text($0.name).tag($0.loudness) }
            }
            HStack {
                Text("Loudness range")
                TextField("LU", value: $normalize.options.range, format: .number).frame(width: 60)
                Text("LU")
                Spacer().frame(width: 12)
                Text("True peak")
                TextField("dBTP", value: $normalize.options.truePeak, format: .number).frame(width: 60)
                Text("dBTP")
            }
            Text("Measures the whole file first, then adjusts it once (EBU R128), so it takes two passes.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var visualizeForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Style", selection: $visualize.options.style) {
                Text("Waves").tag(VisualizeOptions.Style.waves)
                Text("Spectrum").tag(VisualizeOptions.Style.spectrum)
                Text("Picture").tag(VisualizeOptions.Style.image)
            }.pickerStyle(.segmented)
            if visualize.options.style == .waves {
                ColorPicker("Colour", selection: hexBinding($visualize.options.color), supportsOpacity: false)
            }
            if visualize.options.style == .image {
                HStack {
                    Button("Choose Picture…") { chooseImage() }
                    Text(visualize.options.image?.lastPathComponent ?? "None chosen").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Picker("Shape", selection: $visualize.options.shape) {
                Text("Landscape 1280×720").tag(VisualizeOptions.Shape.landscape)
                Text("Portrait 720×1280").tag(VisualizeOptions.Shape.portrait)
                Text("Square 1080×1080").tag(VisualizeOptions.Shape.square)
            }
            Text("Makes an MP4 with the sound under an animation or a still picture.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { visualize.options.image = panel.url }
    }

    private var trimForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("From").frame(width: 40, alignment: .leading)
                TextField("0", text: $trim.start).frame(width: 90)
                Text("to").frame(width: 20)
                TextField("end of file", text: $trim.end).frame(width: 90)
            }
            if !trim.isVideo { Toggle("Also cut silence at the start and end", isOn: $trim.trimSilence) }
            Text("Times in seconds (83.5) or minutes and seconds (1:23.5). Cuts land exactly, so the file is re-encoded. A player to pick the moments comes later.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var channelsForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Channels", selection: $channels.channels) {
                Text("Mono").tag(1)
                Text("Stereo").tag(2)
            }.pickerStyle(.segmented)
            slider("Left volume", value: $channels.left, range: 0...200, unit: "%")
            slider("Right volume", value: $channels.right, range: 0...200, unit: "%")
            Text("For mono, the two sides are mixed after their volumes are applied.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var bleepForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Stretches, e.g. 1:02-1:05, 2:00-2:03", text: $bleep.ranges)
            Picker("Cover with", selection: $bleep.mode) {
                Text("A beep").tag(BleepOptions.Mode.beep)
                Text("Silence").tag(BleepOptions.Mode.mute)
            }.pickerStyle(.segmented)
            if bleep.mode == .beep { Stepper("Beep pitch \(bleep.frequency) Hz", value: $bleep.frequency, in: 200...4000, step: 100) }
            Text("Times in seconds or minutes and seconds. The rest of the sound is left as it is.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var videoCropForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Aspect", selection: $videoCrop.aspect) {
                ForEach(CropForm.aspects, id: \.self) { Text($0 == "free" ? "Free" : $0).tag($0) }
            }
            HStack {
                Text("Exact size")
                TextField("Width", value: $videoCrop.width, format: .number).frame(width: 70)
                Text("×")
                TextField("Height", value: $videoCrop.height, format: .number).frame(width: 70)
                Text("px")
            }
            Text("Crops from the middle; the sound is kept. Choosing the area on the picture comes later.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var speedForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Speed")
                TextField("×", value: $speed.factor, format: .number).frame(width: 70)
                Text("×")
            }
            HStack {
                ForEach(SpeedForm.presets, id: \.self) { preset in
                    Button(preset == preset.rounded() ? "\(Int(preset))×" : "\(preset)×") { speed.factor = preset }
                }
            }
            Text("The pitch of the sound stays the same. From 0.25× to 8×.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var snapshotForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Pictures", selection: $snapshots.mode) {
                Text("Evenly spaced").tag(SnapshotForm.Mode.count)
                Text("At moments").tag(SnapshotForm.Mode.moments)
            }.pickerStyle(.segmented)
            if snapshots.mode == .count {
                Stepper("\(snapshots.count) picture\(snapshots.count == 1 ? "" : "s")", value: $snapshots.count, in: 1...200)
            } else {
                TextField("Moments, e.g. 1.5, 10, 1:05", text: $snapshots.moments)
            }
            Text("Full-size PNG. One picture is a file; several go in a new folder.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var splitVideoForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Split", selection: $splitVideo.mode) {
                Text("Equal parts").tag(SplitVideoForm.Mode.parts)
                Text("Fixed length").tag(SplitVideoForm.Mode.length)
                Text("At moments").tag(SplitVideoForm.Mode.points)
            }.pickerStyle(.segmented)
            switch splitVideo.mode {
            case .parts: Stepper("\(splitVideo.parts) parts", value: $splitVideo.parts, in: 2...100)
            case .length: TextField("Length of each clip, e.g. 60 or 1:30", text: $splitVideo.seconds)
            case .points: TextField("Cut at, e.g. 30, 1:15", text: $splitVideo.points)
            }
            Toggle("Exact cuts (re-encodes; off is fast but cuts on key frames)", isOn: $splitVideo.precise)
            Text("The clips go in a new folder.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var videoRedactForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($videoRedact.areas) { $area in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Area").font(.callout)
                                intField("x", $area.x); intField("y", $area.y); intField("w", $area.width); intField("h", $area.height)
                                Text("%").foregroundStyle(.secondary)
                                Spacer()
                                Button { videoRedact.areas.removeAll { $0.id == area.id } } label: { Image(systemName: "minus.circle") }
                                    .disabled(videoRedact.areas.count == 1).buttonStyle(.borderless)
                            }
                            HStack {
                                Text("Only from").font(.caption).foregroundStyle(.secondary)
                                TextField("start", text: $area.from).frame(width: 70)
                                Text("to").font(.caption).foregroundStyle(.secondary)
                                TextField("end", text: $area.until).frame(width: 70)
                            }
                        }
                    }
                }
            }.frame(maxHeight: 200)
            Button("Add Area") { videoRedact.areas.append(.init()) }
            Picker("Style", selection: $videoRedact.style) {
                Text("Blur").tag(VideoRedactOptions.Style.blur)
                Text("Black").tag(VideoRedactOptions.Style.black)
                Text("Colour").tag(VideoRedactOptions.Style.color)
            }.pickerStyle(.segmented)
            if videoRedact.style == .color { ColorPicker("Colour", selection: hexBinding($videoRedact.color), supportsOpacity: false) }
            Text("x and y are the top left corner, w and h the size, in percent of the picture. Leave the times empty to cover the whole video. Drawing the areas comes later.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func intField(_ label: String, _ value: Binding<Int>) -> some View {
        HStack(spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number).frame(width: 42)
        }
    }

    private var joinForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Order of the clips").font(.callout)
            ForEach(Array(join.files.enumerated()), id: \.offset) { index, file in
                HStack {
                    Text("\(index + 1).").foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                    Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { join.move(from: index, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                    Button { join.move(from: index, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == join.files.count - 1)
                }
            }
            Text("The result is an MP4 the size of the first clip; the others are fitted into it. A clip with no sound is given silence.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: controls

    private func slider(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
            Text("\(value.wrappedValue)\(unit)").monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }

    private func intSlider(_ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int> = -100...100) -> some View {
        slider(label, value: value, range: range, unit: "")
    }

    private func doubleSlider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: 0.1)
            Text(String(format: "%+.1f", value.wrappedValue)).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }

    /// A SwiftUI colour as `#rrggbb` text, the form the tools take.
    private func hexBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: {
                let digits = hex.wrappedValue.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                let value = UInt32(digits, radix: 16) ?? 0
                return Color(.sRGB, red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255,
                             blue: Double(value & 255) / 255, opacity: 1)
            },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
                hex.wrappedValue = String(format: "#%02x%02x%02x", Int((ns.redComponent * 255).rounded()),
                                          Int((ns.greenComponent * 255).rounded()), Int((ns.blueComponent * 255).rounded()))
            })
    }
}
