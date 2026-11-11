//  ContentView.swift — main window.

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmErase = false
    @State private var infoText: String? = nil
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBar()
            Divider()
            HStack(spacing: 0) {
                PicturePanel()
                    .frame(width: 300)
                Divider()
                PreviewPanel(infoText: $infoText)
                    .frame(minWidth: 380, maxWidth: .infinity)
                Divider()
                SettingsPanel(confirmErase: $confirmErase)
                    .frame(width: 240)
            }
            Divider()
            LogPanel()
                .frame(height: 130)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: 3)
                .opacity(dropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            let lock = NSLock()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { model.convert(urls) }
            return true
        }
        .alert("Chinon ES-3000", isPresented: Binding(
            get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
        .alert("Erase ALL pictures from the camera?", isPresented: $confirmErase) {
            Button("Erase All", role: .destructive) { model.eraseAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases the PC card if one is inserted, otherwise the internal memory. It cannot be undone. Download the pictures first if you want to keep them.")
        }
        .alert("Picture Info", isPresented: Binding(
            get: { infoText != nil }, set: { if !$0 { infoText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoText ?? "")
        }
    }
}

// MARK: - Top bar

struct ConnectionBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text("Port:")
            Picker("Port", selection: $model.selectedPort) {
                Text("Auto").tag(AppModel.autoPort)
                ForEach(model.ports, id: \.self) { p in
                    Text((p as NSString).lastPathComponent).tag(p)
                }
            }
            .labelsHidden()
            .frame(width: 220)
            .disabled(model.connected)
            Button {
                model.refreshPorts()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Look for serial adapters again")
            .disabled(model.connected)
            Button(model.connected ? "Disconnect" : "Connect") { model.toggleConnection() }
                .disabled(model.busy)
            Circle()
                .fill(model.statusOK ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 9, height: 9)
            Text(model.statusText)
                .foregroundColor(model.statusOK ? .primary : .secondary)
                .lineLimit(1)
            if model.busy {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Convert .DCT Files…") { model.chooseAndConvert() }
                .help("Turn .DCT files saved by the original software into pictures. You can also drop them on this window.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Picture list

struct PicturePanel: View {
    @EnvironmentObject var model: AppModel
    private var canUseCamera: Bool { model.connected && !model.busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pictures in camera").font(.headline)
            List(selection: $model.selection) {
                ForEach(model.pictures, id: \.number) { p in
                    PictureRow(picture: p).tag(p.number)
                }
            }
            .contextMenu(forSelectionType: Int.self) { items in
                Button("Download") {
                    model.selection = items
                    model.download(.selected)
                }
                .disabled(items.isEmpty || !model.connected)
            } primaryAction: { items in
                model.selection = items
                model.download(.selected)
            }
            .onChange(of: model.selection) { _ in model.selectionChanged() }
            .overlay {
                if model.pictures.isEmpty {
                    Text(model.connected ? "No pictures in the camera." : "Connect to see the pictures.")
                        .foregroundColor(.secondary)
                }
            }
            Text("Double-click a picture to download it.")
                .font(.caption).foregroundColor(.secondary)

            Button {
                model.download(.new)
            } label: {
                Label("Download New", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!canUseCamera)
            HStack {
                Button("Download All") { model.download(.all) }.frame(maxWidth: .infinity)
                Button("Selected") { model.download(.selected) }.frame(maxWidth: .infinity)
                    .disabled(model.selection.isEmpty)
            }
            .disabled(!canUseCamera)
            Button("Refresh List") { model.refreshList() }.frame(maxWidth: .infinity)
                .disabled(!canUseCamera)

            Divider().padding(.vertical, 2)

            Text("Save photos to:").font(.subheadline)
            Text(model.photoDir.path)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(2).truncationMode(.middle)
                .help(model.photoDir.path)
            HStack {
                Button("Change…") { model.choosePhotoFolder() }
                Button("Open Folder") { model.openPhotoFolder() }
            }
            Picker("Save as:", selection: $model.format) {
                ForEach(ImageFormat.allCases) { f in Text(f.rawValue).tag(f) }
            }
            Toggle("Keep original .DCT files", isOn: $model.keepDCT)
                .help("The .DCT is the camera's raw data. Rotating re-decodes from it, so there is no quality loss.")
            Picker("Speed:", selection: $model.fastBaud) {
                ForEach(AppModel.speeds) { s in Text(s.label).tag(s.baud) }
            }
        }
        .padding(12)
    }
}

struct PictureRow: View {
    @EnvironmentObject var model: AppModel
    let picture: PictureInfo

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                if let t = model.listThumbnail(picture.number) {
                    Image(decorative: t, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 64, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(String(format: "#%02d", picture.number)).monospacedDigit().bold()
                    Text(picture.resolution.name)
                    if model.saved[picture.number] != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            .help("Already downloaded")
                    }
                }
                Text(picture.taken.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "no date")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview

struct PreviewPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var infoText: String?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .underPageBackgroundColor))
                if let img = model.preview {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(img.width < 200 ? .medium : .high)
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else {
                    Text(model.previewPlaceholder)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
            }
            if model.progress != nil {
                ProgressView(value: model.progress ?? 0)
            }
            HStack {
                Text(model.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { model.rotate(90) } label: { Image(systemName: "rotate.left") }
                    .help("Rotate left")
                Button { model.rotate(-90) } label: { Image(systemName: "rotate.right") }
                    .help("Rotate right")
                Button("Info") { infoText = model.pictureInfoText() }
            }
        }
        .padding(12)
    }
}

// MARK: - Camera settings

struct SettingsPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var confirmErase: Bool
    @State private var zoomDraft: Double = 0

    var body: some View {
        let enabled = model.connected && !model.busy
        VStack(alignment: .leading, spacing: 10) {
            Text("Camera settings").font(.headline)

            labeledPicker("Resolution", AppModel.resolutionNames,
                          Binding(get: { model.resolution }, set: { model.setResolution($0) }))
            labeledPicker("Flash", AppModel.flashNames,
                          Binding(get: { model.flash }, set: { model.setFlash($0) }))
            labeledPicker("Focus", AppModel.focusNames,
                          Binding(get: { model.focus }, set: { model.setFocus($0) }))

            VStack(alignment: .leading, spacing: 2) {
                Text("Zoom: \(Int(zoomDraft))" + (zoomDraft == 0 ? " (wide)" : zoomDraft == 6 ? " (tele)" : ""))
                    .foregroundColor(model.zoomLocked ? .secondary : .primary)
                Slider(value: $zoomDraft, in: 0...6, step: 1, onEditingChanged: { editing in
                    if !editing && Int(zoomDraft) != model.zoom { model.setZoom(Int(zoomDraft)) }
                })
                .disabled(model.zoomLocked)
                .help(model.zoomLocked ? "Zoom is unavailable in Macro focus." : "")
            }
            .onAppear { zoomDraft = Double(model.zoom) }
            .onChange(of: model.zoom) { z in zoomDraft = Double(z) }

            Toggle("Self-timer", isOn: Binding(get: { model.timer }, set: { model.setTimer($0) }))

            Button {
                model.takePicture()
            } label: {
                Label("Take Picture", systemImage: "camera").frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Button("Sync Camera Clock to Mac") { model.syncClock() }.frame(maxWidth: .infinity)

            Text(model.cameraInfo)
                .font(.callout).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
            Button(role: .destructive) {
                confirmErase = true
            } label: {
                Text("Erase ALL Pictures…").frame(maxWidth: .infinity)
            }
        }
        .disabled(!enabled)
        .padding(12)
    }

    private func labeledPicker(_ title: String, _ names: [String], _ binding: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Picker(title, selection: binding) {
                ForEach(names.indices, id: \.self) { i in Text(names[i]).tag(i) }
            }
            .labelsHidden()
        }
    }
}

// MARK: - Log

struct LogPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Log").font(.caption).foregroundColor(.secondary)
                Spacer()
                Toggle("Show technical details", isOn: $model.verbose)
                    .toggleStyle(.checkbox).font(.caption)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.log) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onChange(of: model.log.count) { _ in
                    if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
