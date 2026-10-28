import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@main
struct TrialShelfApp: App {
    @StateObject private var catalog = FileCatalog()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(catalog)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.titleBar)
    }
}

struct TrackedFile: Identifiable, Codable, Equatable {
    var id: UUID
    var path: String
    var sourcePath: String?
    var packageID: UUID?
    var addedAt: Date
    var expiresAt: Date?
    var modifiedAt: Date?
    var lastAutoRunExpiry: Date?

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var folder: String { url.deletingLastPathComponent().path }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

struct TrackedPackage: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var parentID: UUID?
    var createdAt: Date
}

@MainActor
final class FileCatalog: ObservableObject {
    @Published private(set) var files: [TrackedFile] = []
    @Published private(set) var packages: [TrackedPackage] = []

    private let catalogURL: URL = {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrialShelf", isDirectory: true)
            .appendingPathComponent("catalog.json")
    }()

    private var filesDirectory: URL {
        catalogURL.deletingLastPathComponent().appendingPathComponent("Files", isDirectory: true)
    }

    private var packagesURL: URL {
        catalogURL.deletingLastPathComponent().appendingPathComponent("packages.json")
    }

    init() { load() }

    func createPackage(name: String, parentID: UUID? = nil) -> UUID {
        let id = UUID()
        packages.append(TrackedPackage(id: id, name: name, parentID: parentID, createdAt: Date()))
        try? FileManager.default.createDirectory(at: packageDirectory(id), withIntermediateDirectories: true)
        savePackages()
        return id
    }

    func hasPackage(named name: String, parentID: UUID?) -> Bool {
        let component = packageComponent(name)
        return packages.contains {
            $0.parentID == parentID && packageComponent($0.name).localizedCaseInsensitiveCompare(component) == .orderedSame
        }
    }

    func add(urls: [URL], to packageID: UUID, shellScriptExpiryDays: Int? = nil) -> Int {
        var existingPaths = Set(files.filter { $0.packageID == packageID }.compactMap(\.sourcePath))
        var additions: [TrackedFile] = []

        for url in urls {
            let sourcePath = url.standardizedFileURL.path
            guard !existingPaths.contains(sourcePath),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }

            let id = UUID()
            guard let storedURL = storeCopy(of: url, id: id, packageID: packageID) else { continue }
            existingPaths.insert(sourcePath)
            let expiry = url.pathExtension.lowercased() == "sh"
                ? shellScriptExpiryDays.flatMap { Calendar.current.date(byAdding: .day, value: $0, to: Calendar.current.startOfDay(for: Date())) }
                : nil

            additions.append(TrackedFile(
                id: id,
                path: storedURL.path,
                sourcePath: sourcePath,
                packageID: packageID,
                addedAt: Date(),
                expiresAt: expiry,
                modifiedAt: values.contentModificationDate,
                lastAutoRunExpiry: nil
            ))
        }

        guard !additions.isEmpty else { return 0 }
        files.append(contentsOf: additions)
        save()
        return additions.count
    }

    func addFolder(_ folder: URL, to packageID: UUID, shellScriptExpiryDays: Int?) -> Int {
        guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return 0 }
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true {
                urls.append(url)
            }
        }
        let previousIDs = Set(files.map(\.id))
        _ = add(urls: urls, to: packageID, shellScriptExpiryDays: shellScriptExpiryDays)
        let addedIndices = files.indices.filter { !previousIDs.contains(files[$0].id) }
        return addedIndices.count
    }

    func shellScriptCount(in folder: URL) -> Int {
        guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return 0 }
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension.lowercased() == "sh", values.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    func packageDirectory(_ id: UUID) -> URL {
        guard let package = packages.first(where: { $0.id == id }) else {
            return filesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        }
        let component = packageComponent(package.name)
        if let parentID = package.parentID {
            return packageDirectory(parentID).appendingPathComponent(component, isDirectory: true)
        }
        return filesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
    }

    func files(in packageID: UUID) -> [TrackedFile] {
        files.filter { $0.packageID == packageID }
    }

    func allFiles(in packageID: UUID) -> [TrackedFile] {
        let childIDs = packages.filter { $0.parentID == packageID }.map(\.id)
        return files(in: packageID) + childIDs.flatMap { allFiles(in: $0) }
    }

    func removePackage(_ packageID: UUID) {
        guard packages.contains(where: { $0.id == packageID }) else { return }
        var removedIDs: Set<UUID> = [packageID]
        var pending = [packageID]
        while let current = pending.popLast() {
            let childIDs = packages.filter { $0.parentID == current }.map(\.id)
            for childID in childIDs where removedIDs.insert(childID).inserted {
                pending.append(childID)
            }
        }
        // Remove only copies recorded for this package tree. Folder names are
        // display labels and must never decide which on-disk data gets deleted.
        let removedFiles = files.filter { $0.packageID.map(removedIDs.contains) == true }
        for file in removedFiles where isManaged(file.url) {
            try? FileManager.default.removeItem(at: file.url)
            removeEmptyManagedParents(of: file.url.deletingLastPathComponent())
        }
        for id in removedIDs { removeEmptyManagedParents(of: packageDirectory(id)) }
        files.removeAll { $0.packageID.map(removedIDs.contains) == true }
        packages.removeAll { removedIDs.contains($0.id) }
        save()
        savePackages()
    }

    func markAutoRunAttempted(_ id: UUID, for expiry: Date) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index].lastAutoRunExpiry = expiry
        save()
    }

    func remove(_ id: UUID) {
        guard let file = files.first(where: { $0.id == id }) else { return }
        if isManaged(file.url) {
            try? FileManager.default.removeItem(at: file.url)
        }
        files.removeAll { $0.id == id }
        save()
    }

    func refreshMetadata() {
        for index in files.indices where files[index].exists {
            let url = files[index].url
            files[index].modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: catalogURL),
              let decoded = try? JSONDecoder().decode([TrackedFile].self, from: data) else {
            loadPackages()
            return
        }
        files = decoded
        loadPackages()
        var migrated = false
        let linkedFiles = files.filter {
            (try? $0.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        }
        if !linkedFiles.isEmpty {
            for file in linkedFiles where isManaged(file.url) {
                try? FileManager.default.removeItem(at: file.url)
            }
            let linkedIDs = Set(linkedFiles.map(\.id))
            files.removeAll { linkedIDs.contains($0.id) }
            migrated = true
        }
        if packages.isEmpty && !files.isEmpty {
            let legacyID = createPackage(name: "Gói cũ")
            for index in files.indices { files[index].packageID = legacyID }
            migrated = true
        }
        var migratedManagedFiles: [URL] = []
        for index in files.indices {
            guard let packageID = files[index].packageID,
                  !files[index].url.standardizedFileURL.path.hasPrefix(packageDirectory(packageID).standardizedFileURL.path + "/"),
                  files[index].exists else { continue }
            let originalURL = files[index].url
            guard let storedURL = storeCopy(of: originalURL, id: files[index].id, packageID: packageID) else { continue }
            if isManaged(originalURL) { migratedManagedFiles.append(originalURL) }
            files[index].sourcePath = files[index].sourcePath ?? originalURL.path
            files[index].path = storedURL.path
            migrated = true
        }
        let retainedPaths = Set(files.map { $0.url.standardizedFileURL.path })
        for url in migratedManagedFiles where !retainedPaths.contains(url.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: url)
            removeEmptyManagedParents(of: url.deletingLastPathComponent())
        }
        if migrated { save() }
    }

    private func isManaged(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(filesDirectory.standardizedFileURL.path + "/")
    }

    private func packageComponent(_ name: String) -> String {
        let component = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return component == "." || component == ".." ? "_\(component)" : component
    }

    private func removeEmptyManagedParents(of directory: URL) {
        let managedRoot = filesDirectory.standardizedFileURL
        var current = directory.standardizedFileURL
        while current.path != managedRoot.path && current.path.hasPrefix(managedRoot.path + "/") {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path),
                  contents.isEmpty else { return }
            try? FileManager.default.removeItem(at: current)
            current.deleteLastPathComponent()
        }
    }

    private func storeCopy(of source: URL, id: UUID, packageID: UUID) -> URL? {
        let folder = packageDirectory(packageID)
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        var destination = folder.appendingPathComponent(source.lastPathComponent)
        var suffix = 2
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            while FileManager.default.fileExists(atPath: destination.path) {
                let name = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
                destination = folder.appendingPathComponent(name)
                suffix += 1
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            NSLog("TrialShelf could not store file copy: %@", error.localizedDescription)
            return nil
        }
    }

    private func loadPackages() {
        guard let data = try? Data(contentsOf: packagesURL),
              let decoded = try? JSONDecoder().decode([TrackedPackage].self, from: data) else { return }
        packages = decoded
        var usedNames: [String: Set<String>] = [:]
        var changed = false
        for index in packages.indices {
            let parentKey = packages[index].parentID?.uuidString ?? "root"
            let rawBase = packageComponent(packages[index].name.trimmingCharacters(in: .whitespacesAndNewlines))
            let base = rawBase.isEmpty ? "Folder" : rawBase
            var candidate = base
            var suffix = 2
            while usedNames[parentKey, default: []].contains(candidate.folding(options: [.caseInsensitive], locale: .current)) {
                candidate = "\(base) (\(suffix))"
                suffix += 1
            }
            usedNames[parentKey, default: []].insert(candidate.folding(options: [.caseInsensitive], locale: .current))
            if packages[index].name != candidate {
                packages[index].name = candidate
                changed = true
            }
        }
        if changed { savePackages() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: catalogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(files)
            try data.write(to: catalogURL, options: .atomic)
        } catch {
            NSLog("TrialShelf could not save its catalog: %@", error.localizedDescription)
        }
    }

    private func savePackages() {
        do {
            try FileManager.default.createDirectory(
                at: packagesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(packages).write(to: packagesURL, options: .atomic)
        } catch {
            NSLog("TrialShelf could not save its packages: %@", error.localizedDescription)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var catalog: FileCatalog
    @State private var selectedID: UUID?
    @State private var searchText = ""
    @State private var toast: String?
    @State private var isRunning = false
    @State private var isPackaging = false
    @State private var packagePendingDeletion: TrackedPackage?
    @AppStorage("automaticScriptsEnabled") private var automaticScriptsEnabled = false

    private var visibleFiles: [TrackedFile] {
        let filtered = catalog.files.filter { file in
            searchText.isEmpty || file.name.localizedCaseInsensitiveContains(searchText)
        }
        return filtered.sorted { lhs, rhs in
            switch (lhs.expiresAt, rhs.expiresAt) {
            case let (left?, right?):
                if left != right { return left < right }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private var selectedFile: TrackedFile? {
        guard let selectedID else { return nil }
        return catalog.files.first { $0.id == selectedID }
    }

    private var folderTreeOrder: [TrackedPackage] {
        var result: [TrackedPackage] = []
        func appendChildren(of parentID: UUID?) {
            let children = catalog.packages
                .filter { $0.parentID == parentID }
                .sorted { $0.createdAt < $1.createdAt }
            for child in children {
                result.append(child)
                appendChildren(of: child.id)
            }
        }
        appendChildren(of: nil)
        return result
    }

    private func folderDepth(_ package: TrackedPackage) -> Int {
        var depth = 0
        var parentID = package.parentID
        while let id = parentID, let parent = catalog.packages.first(where: { $0.id == id }) {
            depth += 1
            parentID = parent.parentID
        }
        return depth
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if catalog.packages.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    fileList
                        .frame(minWidth: 450, maxWidth: .infinity)
                    Divider()
                    detailPane
                        .frame(width: 310)
                }
            }

            if let toast {
                Divider()
                HStack {
                    Text(toast).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Ẩn") { self.toast = nil }.buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Xóa folder và nội dung?", isPresented: Binding(
            get: { packagePendingDeletion != nil },
            set: { if !$0 { packagePendingDeletion = nil } }
        )) {
            Button("Hủy", role: .cancel) { packagePendingDeletion = nil }
            Button("Xóa", role: .destructive) {
                guard let package = packagePendingDeletion else { return }
                catalog.removePackage(package.id)
                packagePendingDeletion = nil
                toast = "Đã xóa folder và các mục con. File nguồn vẫn được giữ nguyên."
            }
        } message: {
            Text("‘\(packagePendingDeletion?.name ?? "")’ và các bản sao file bên trong sẽ bị xóa khỏi TrialShelf. File nguồn trên máy không bị xóa.")
        }
        .task {
            setLoginItemEnabled(automaticScriptsEnabled)
            if automaticScriptsEnabled {
                await runExpiredFiles()
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if automaticScriptsEnabled { await runExpiredFiles() }
            }
        }
        .onChange(of: automaticScriptsEnabled) { enabled in
            setLoginItemEnabled(enabled)
            if enabled {
                Task { await runExpiredFiles() }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("TrialShelf").font(.title2.weight(.semibold))
                    Text("Tạo gói file và xuất ZIP để chia sẻ").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Text("\(catalog.packages.filter { $0.parentID == nil }.count) mục lớn · \(catalog.packages.count) folder")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Toggle("Tự chạy script đến hạn", isOn: $automaticScriptsEnabled)
                    Text("Chỉ bật nếu bạn tin cậy các file .sh đã thêm.")
                        .font(.caption)
                } label: {
                    Image(systemName: automaticScriptsEnabled ? "bolt.fill" : "bolt")
                }
                .help("Cài đặt chạy script tự động")
                Button { createPackage(parentID: nil) } label: { Label("Tạo mục lớn", systemImage: "folder.badge.plus") }
                Button { runSelectedFile() } label: {
                    Label(isRunning ? "Đang chạy…" : "Run", systemImage: "play.fill")
                }
                .disabled(selectedFile == nil || selectedFile?.isRunnable != true || isRunning)
                .help("Chạy file script đang chọn")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("Tạo folder đầu tiên").font(.title3.weight(.medium))
            Text("Đặt tên folder, upload file vào đó rồi xuất thành ZIP để chia sẻ.")
                .foregroundStyle(.secondary)
            Button("Tạo folder…") { createPackage(parentID: nil) }
            .padding(.top, 4)
            Text("TrialShelf lưu bản sao riêng; file nguồn của bạn không bị thay đổi.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Tìm tên file", text: $searchText)
                    .textFieldStyle(.plain)
                Button { catalog.refreshMetadata(); toast = "Đã làm mới thông tin file." } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Làm mới ngày sửa và trạng thái file")
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(folderTreeOrder) { package in
                        packageSection(package)
                    }
                    if visibleFiles.isEmpty {
                        Text("Không tìm thấy file khớp với nội dung tìm kiếm.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(32)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private func packageSection(_ package: TrackedPackage) -> some View {
        let depth = folderDepth(package)
        let directFiles = visibleFiles.filter { $0.packageID == package.id }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "folder.fill")
                    .font(.system(size: depth == 0 ? 28 : 22))
                    .foregroundStyle(Color.accentColor)
                Text(package.name)
                    .font(depth == 0 ? .title3.weight(.semibold) : .headline)
                    .lineLimit(1)
                Text("\(catalog.allFiles(in: package.id).count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button { createPackage(parentID: package.id) } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .help("Tạo mục con")
                Button { chooseFiles(to: package.id) } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .help("Upload file vào folder này")
                Button { chooseFolder(to: package.id) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Nhập thư mục vào folder này")
                Button { exportPackageZip(package.id) } label: {
                    Image(systemName: "archivebox")
                }
                .buttonStyle(.plain)
                .disabled(catalog.allFiles(in: package.id).isEmpty || isPackaging)
                .help("Đóng gói folder này thành ZIP")
                Button(role: .destructive) { packagePendingDeletion = package } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Xóa folder và toàn bộ mục con")
            }
            .padding(.leading, CGFloat(depth) * 25)
            .padding(.vertical, 5)

            ForEach(directFiles) { file in
                Button {
                    selectedID = file.id
                } label: {
                    FileRow(file: file)
                        .padding(.horizontal, 9)
                        .background(selectedID == file.id ? Color.accentColor.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.leading, CGFloat(depth + 1) * 25)
                .contextMenu {
                    Button("Hiện bản lưu trong Finder") { reveal(file) }
                    Button("Bỏ khỏi danh mục", role: .destructive) {
                        catalog.remove(file.id)
                        if selectedID == file.id { selectedID = nil }
                    }
                }
            }
            Divider().padding(.leading, CGFloat(depth) * 25)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let file = selectedFile {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(file.name).font(.headline).textSelection(.enabled)
                    Text(file.exists ? "Bản sao đã lưu trong TrialShelf" : "Không tìm thấy bản sao đã lưu")
                        .font(.caption)
                        .foregroundStyle(file.exists ? Color.secondary : Color.orange)
                }

                LabeledContent("Kho lưu trữ", value: "TrialShelf")
                    .font(.caption)

                Divider()

                if let expiry = file.expiresAt {
                    CountdownBadge(date: expiry)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let modifiedAt = file.modifiedAt {
                    LabeledContent("Sửa lần cuối", value: modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                }

                Spacer(minLength: 0)

                Button { reveal(file) } label: {
                    Label("Hiện bản lưu trong Finder", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!file.exists)

                Button { runSelectedFile() } label: {
                    Label("Run file này", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!file.exists || !file.isRunnable || isRunning)

                Button(role: .destructive) {
                    catalog.remove(file.id)
                    selectedID = nil
                    toast = "Đã bỏ file khỏi danh mục. File gốc vẫn được giữ nguyên."
                } label: {
                    Label("Bỏ khỏi danh mục", systemImage: "minus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(18)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Chọn một file để xem chi tiết")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func chooseFiles(to packageID: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Upload file vào folder"
        panel.prompt = "Thêm vào folder"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let hasShellScript = panel.urls.contains { $0.pathExtension.lowercased() == "sh" }
        let expiryDays: Int?
        if hasShellScript {
            guard let value = promptExpiryDays(context: "file .sh") else { return }
            expiryDays = value
        } else {
            expiryDays = nil
        }
        let added = catalog.add(urls: panel.urls, to: packageID, shellScriptExpiryDays: expiryDays)
        toast = hasShellScript
            ? "Đã thêm \(added) file; file .sh sẽ tự chạy sau \(expiryDays ?? 0) ngày."
            : "Đã thêm \(added) file vào folder."
    }

    private func chooseFolder(to packageID: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Chọn thư mục chứa file cần theo dõi"
        panel.prompt = "Quét thư mục"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let shellScriptCount = catalog.shellScriptCount(in: folder)
        let expiryDays: Int?
        if shellScriptCount > 0 {
            guard let value = promptExpiryDays(context: "\(shellScriptCount) file .sh") else { return }
            expiryDays = value
        } else {
            expiryDays = nil
        }
        let added = catalog.addFolder(folder, to: packageID, shellScriptExpiryDays: expiryDays)
        toast = shellScriptCount > 0
            ? "Đã thêm \(added) file; \(shellScriptCount) file .sh được đặt hạn sau \(expiryDays ?? 0) ngày."
            : "Đã thêm \(added) file vào folder."
    }

    private func promptExpiryDays(context: String) -> Int? {
        while true {
            let alert = NSAlert()
            alert.messageText = "Đặt lịch chạy cho \(context)"
            alert.informativeText = "Nhập số ngày còn lại. File .sh sẽ tự chạy khi đến hạn."
            alert.addButton(withTitle: "Upload file")
            alert.addButton(withTitle: "Hủy")

            let input = NSTextField(string: "")
            input.placeholderString = "Số ngày (0 trở lên)"
            input.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
            alert.accessoryView = input

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if let days = Int(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), days >= 0 {
                return days
            }

            let error = NSAlert()
            error.messageText = "Số ngày chưa hợp lệ"
            error.informativeText = "Nhập một số nguyên từ 0 trở lên."
            error.addButton(withTitle: "Nhập lại")
            error.runModal()
        }
    }

    private func createPackage(parentID: UUID?) {
        let alert = NSAlert()
        alert.messageText = parentID == nil ? "Tạo mục lớn" : "Tạo mục con"
        alert.informativeText = parentID == nil
            ? "Đặt tên cho folder chính."
            : "Đặt tên cho folder con bên trong mục lớn này."
        alert.addButton(withTitle: "Tạo folder")
        alert.addButton(withTitle: "Hủy")
        let input = NSTextField(string: "")
        input.placeholderString = "Tên folder"
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else {
            toast = "Tên folder không hợp lệ. Hãy nhập tên khác."
            return
        }
        guard !catalog.hasPackage(named: name, parentID: parentID) else {
            toast = "Folder cùng cấp đã có tên này. Hãy chọn tên khác."
            return
        }
        _ = catalog.createPackage(name: name, parentID: parentID)
        selectedID = nil
        toast = "Đã tạo folder \(name). Dùng nút ⋯ bên cạnh folder để thêm file hoặc mục con."
    }

    private func exportPackageZip(_ packageID: UUID) {
        guard let package = catalog.packages.first(where: { $0.id == packageID }) else { return }
        guard !catalog.allFiles(in: packageID).isEmpty else {
            toast = "Folder chưa có file để đóng gói."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Lưu gói ZIP"
        panel.nameFieldStringValue = "\(package.name.replacingOccurrences(of: "/", with: "-")).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let source = catalog.packageDirectory(packageID)
        isPackaging = true
        toast = "Đang đóng gói \(package.name)…"
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path]
            do {
                try process.run()
                process.waitUntilExit()
                await MainActor.run {
                    isPackaging = false
                    toast = process.terminationStatus == 0
                        ? "Đã tạo ZIP: \(destination.lastPathComponent)"
                        : "Không đóng gói được ZIP (mã \(process.terminationStatus))."
                }
            } catch {
                await MainActor.run {
                    isPackaging = false
                    toast = "Không đóng gói được ZIP: \(error.localizedDescription)"
                }
            }
        }
    }

    private func reveal(_ file: TrackedFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    private func runSelectedFile() {
        guard let file = selectedFile, file.exists, file.isRunnable else { return }
        isRunning = true
        toast = "Đang chạy \(file.name)…"
        Task.detached {
            let result = ScriptRunner.run(file.url)
            await MainActor.run {
                isRunning = false
                let details = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                toast = result.succeeded
                    ? "Chạy thành công: \(file.name)\(details.isEmpty ? "" : " — " + details)"
                    : "Chạy thất bại (mã \(result.status)): \(details.isEmpty ? result.error : details)"
            }
        }
    }

    private func setLoginItemEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            automaticScriptsEnabled = false
            toast = "Không cập nhật được tùy chọn tự chạy: \(error.localizedDescription)"
        }
    }

    private func runExpiredFiles() async {
        guard !isRunning else { return }
        let dueFiles = catalog.files.filter { file in
            guard let expiry = file.expiresAt else { return false }
            return file.isRunnable && file.exists && expiry <= Date() && file.lastAutoRunExpiry != expiry
        }
        guard !dueFiles.isEmpty else { return }

        isRunning = true
        for file in dueFiles {
            guard let expiry = file.expiresAt else { continue }
            catalog.markAutoRunAttempted(file.id, for: expiry)
            let result = await Task.detached { ScriptRunner.run(file.url) }.value
            let details = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            toast = result.succeeded
                ? "Tự chạy thành công: \(file.name)\(details.isEmpty ? "" : " — " + details)"
                : "Tự chạy thất bại (mã \(result.status)): \(details.isEmpty ? result.error : details). Có thể bấm Run để thử lại."
        }
        isRunning = false
    }
}

private enum ScriptRunner {
    private static let timeout: TimeInterval = 120
    private static let maximumCapturedOutput = 64 * 1024

    struct Result {
        var succeeded = false
        var status = -1
        var output = ""
        var error = ""
    }

    static func run(_ url: URL) -> Result {
        let fallback: String
        switch url.pathExtension.lowercased() {
        case "sh", "command": fallback = "/bin/zsh"
        case "py": fallback = "/usr/bin/python3"
        case "swift": fallback = "/usr/bin/swift"
        case "rb": fallback = "/usr/bin/ruby"
        case "pl": fallback = "/usr/bin/perl"
        default: return Result(error: "Định dạng chưa được hỗ trợ.")
        }

        let path = (["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init))
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ":")
        let firstLine = (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: .newlines).first ?? ""
        let shebangParts = firstLine.hasPrefix("#!")
            ? firstLine.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
            : []
        var command = fallback
        var prefixArguments: [String] = []
        if let interpreter = shebangParts.first {
            if interpreter == "/usr/bin/env", shebangParts.count > 1 {
                command = "/usr/bin/env"
                prefixArguments = Array(shebangParts.dropFirst())
            } else {
                command = interpreter
                prefixArguments = Array(shebangParts.dropFirst())
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = prefixArguments + [url.path]
        process.currentDirectoryURL = url.deletingLastPathComponent()
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { _, new in new }
        let outputPipe = Pipe()
        let outputQueue = DispatchQueue(label: "TrialShelf.script-output")
        var capturedOutput = Data()
        var outputWasTruncated = false
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            outputQueue.sync {
                let remaining = max(0, maximumCapturedOutput - capturedOutput.count)
                if remaining > 0 { capturedOutput.append(chunk.prefix(remaining)) }
                if chunk.count > remaining { outputWasTruncated = true }
            }
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            let timedOut = process.isRunning
            if timedOut {
                process.terminate()
                process.waitUntilExit()
            }
            outputPipe.fileHandleForReading.readabilityHandler = nil
            try? outputPipe.fileHandleForReading.close()
            let (outputData, wasTruncated) = outputQueue.sync { (capturedOutput, outputWasTruncated) }
            var output = String(decoding: outputData, as: UTF8.self)
            if wasTruncated { output += "\n[Output truncated at 64 KiB.]" }
            if timedOut { output += "\n[Stopped after 120 seconds.]" }
            return Result(
                succeeded: !timedOut && process.terminationStatus == 0,
                status: Int(process.terminationStatus),
                output: output,
                error: timedOut ? "Stopped after 120 seconds." : ""
            )
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            try? outputPipe.fileHandleForReading.close()
            return Result(error: error.localizedDescription)
        }
    }
}

private extension TrackedFile {
    var isRunnable: Bool {
        ["sh", "command", "py", "swift", "rb", "pl"].contains(url.pathExtension.lowercased())
    }
}

private struct FileRow: View {
    let file: TrackedFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.exists ? "doc" : "doc.questionmark")
                .foregroundStyle(file.exists ? Color.secondary : Color.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name).lineLimit(1)
                Text("Đã lưu trong TrialShelf").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let date = file.expiresAt {
                CountdownBadge(date: date)
            } else {
                Text("Chưa đặt ngày")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct CountdownBadge: View {
    let date: Date

    private func labelAndColor(at now: Date) -> (String, Color) {
        let today = Calendar.current.startOfDay(for: now)
        let expiry = Calendar.current.startOfDay(for: date)
        let days = Calendar.current.dateComponents([.day], from: today, to: expiry).day ?? 0
        if days < 0 { return ("Quá hạn \(-days) ngày", .red) }
        if days == 0 { return ("Hết hạn hôm nay", .orange) }
        return ("Còn \(days) ngày", days <= 3 ? Color.orange : Color.secondary)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let (label, color) = labelAndColor(at: context.date)
            Text(label)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(color.opacity(0.10), in: Capsule())
        }
    }
}
