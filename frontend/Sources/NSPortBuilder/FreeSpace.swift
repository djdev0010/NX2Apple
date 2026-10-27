import AppKit
import SwiftUI

/// The parts of a game's build folder (<output folder>/<title ID>_build) that the next build makes again
/// (LNPANDY/NX2Apple#67, after seedds/nxnative#264). The layout is scripts/build_ipa_from_nsp.py's: extract/ (the extracted
/// game files), shader/ and pso/ (the shader package, caches and libraries), xcode/, xcode-derived-data/ and ipa/ (the app
/// build), and the smaller caches beside them. What the script keeps for its own sake stays: logs/, profile/ (a provisional
/// or derived profile, which someone may have edited), run/ (the Mac development build's save) and nsp/ (NSZ files
/// converted to NSP, which are game files).
enum BuildFolderPart: String, CaseIterable, Identifiable {
    case extracted, shaders, xcode, caches
    var id: String { rawValue }

    /// The part a top-level entry of the build folder belongs to; nil for what is never offered. A stage's reuse key
    /// (<name>.key) and an interrupted stage's output (<name>.partial) go with the folder they belong to.
    static func of(_ name: String) -> BuildFolderPart? {
        var base = name
        for suffix in [".key", ".partial"] where base.hasSuffix(suffix) { base = String(base.dropLast(suffix.count)) }
        switch base {
        case "extract", "exefs": return .extracted
        case "shader", "pso": return .shaders
        case "xcode", "xcode-derived-data", "ipa": return .xcode
        case "tools", "tmp", "aoc", "font": return .caches
        default:   // the rewritten modules and the NROs collected for them, one folder per packed version
            return base.hasPrefix("patched_") || base.hasPrefix("nro_") ? .caches : nil
        }
    }
}

/// What a build folder holds, part by part, in bytes on disk.
struct BuildFolderSurvey: Equatable {
    var folder: String
    var sizes: [BuildFolderPart: Int64] = [:]
    /// Everything that stays: logs, the profile, converted NSPs, saves, and anything the game still needs that lies inside.
    var kept: Int64 = 0
    var parts: [BuildFolderPart] { BuildFolderPart.allCases.filter { (sizes[$0] ?? 0) > 0 } }
}

enum FreeSpaceError: LocalizedError, Equatable {
    case buildRunning, notABuildFolder(String), failed(String)
    var errorDescription: String? {
        switch self {
        case .buildRunning: return "A build is running."
        case .notABuildFolder(let path): return "Not a build folder: \(path)"
        case .failed(let why): return why
        }
    }
}

enum BuildFolder {
    /// Where the game's build folder can be: in its output folder (--work-dir), else beside its NSPs (the script's default,
    /// and where a checkout without --work-dir puts it).
    nonisolated static func candidates(for game: LibraryGame) -> [String] {
        let base = game.inputs["base", default: []].first.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        let dirs = [game.outputDirectory, base].filter { !$0.isEmpty }
        var seen = Set<String>()
        return dirs.map { $0 + "/" + game.titleID + "_build" }.filter { seen.insert($0).inserted }
    }

    nonisolated static func location(for game: LibraryGame) -> String? {
        candidates(for: game).first { path in
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
        }
    }

    /// What this sheet never removes, wherever it lies: the finished Mac app, the IPA, the app installed on a device (its
    /// build is in xcode-derived-data), the game data archive (games/<title ID>/ with romfs.img), and the NSPs and keys.
    nonisolated static func protectedPaths(for game: LibraryGame) -> [String] {
        let out = game.outputDirectory.isEmpty
            ? game.inputs["base", default: []].first.map { ($0 as NSString).deletingLastPathComponent } ?? "" : game.outputDirectory
        var paths = [game.appPath, game.ipaPath, game.iosAppPath, game.archivePath]
        if !game.archivePath.isEmpty { paths.append(game.archivePath + "/romfs.img") }
        if !out.isEmpty { paths.append(out + "/games/" + game.titleID) }
        paths += game.inputs.values.flatMap { $0 }
        return paths.filter { !$0.isEmpty }.map(resolved)
    }

    nonisolated static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The sizes of the parts and of what stays. Reads the whole folder (tens of GB for some games): off the main thread.
    nonisolated static func survey(_ folder: String, protecting: [String]) -> BuildFolderSurvey {
        let root = resolved(folder)
        var result = BuildFolderSurvey(folder: root)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let path = root + "/" + name
            guard let part = BuildFolderPart.of(name) else { result.kept += size(path); continue }
            let kept = protectedSize(path, protecting: protecting)
            result.sizes[part, default: 0] += size(path) - kept
            result.kept += kept
        }
        return result
    }

    /// Delete the chosen parts. Refused while a build runs (it may be writing into this folder) and for a folder that is
    /// not a build folder. A protected path inside a part stays, with the folders that lead to it. Deleted, not moved to the
    /// Trash: the Trash keeps the bytes on the same drive. Returns the bytes freed.
    @discardableResult
    nonisolated static func remove(_ parts: Set<BuildFolderPart>, in folder: String, protecting: [String], buildRunning: Bool) throws -> Int64 {
        guard !buildRunning else { throw FreeSpaceError.buildRunning }
        let root = resolved(folder)
        guard root.hasSuffix("_build"), root.split(separator: "/").count > 1 else { throw FreeSpaceError.notABuildFolder(folder) }
        var freed: Int64 = 0
        var failures: [String] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            guard let part = BuildFolderPart.of(name), parts.contains(part) else { continue }
            removeTree(root + "/" + name, protecting: protecting, freed: &freed, failures: &failures)
        }
        if let first = failures.first { throw FreeSpaceError.failed(first) }
        return freed
    }

    private nonisolated static func removeTree(_ path: String, protecting: [String], freed: inout Int64, failures: inout [String]) {
        if protecting.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return }
        if protecting.contains(where: { $0.hasPrefix(path + "/") }) {   // something to keep lies inside: go in, around it
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                removeTree(path + "/" + name, protecting: protecting, freed: &freed, failures: &failures)
            }
            return
        }
        let bytes = size(path)
        do { try FileManager.default.removeItem(atPath: path); freed += bytes }
        catch { failures.append(error.localizedDescription) }
    }

    /// The bytes of the protected paths inside path, each counted once (the archive folder holds romfs.img).
    private nonisolated static func protectedSize(_ path: String, protecting: [String]) -> Int64 {
        let inside = Set(protecting.filter { $0 == path || $0.hasPrefix(path + "/") })
        return inside.filter { p in !inside.contains { p.hasPrefix($0 + "/") } }.reduce(0) { $0 + size($1) }
    }

    /// Allocated bytes of a file or folder, symbolic links not followed.
    nonisolated static func size(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey, .isDirectoryKey]
        func bytes(_ u: URL) -> Int64 {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return 0 }
            return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        guard let top = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return 0 }
        if top.isSymbolicLink == true || top.isDirectory != true { return bytes(url) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let u = e?.nextObject() as? URL { total += bytes(u) }
        return total
    }
}

/// The game's Free space sheet: the parts of its build folder with their sizes and what removing each costs; the player
/// picks parts and confirms.
struct FreeSpaceView: View {
    @ObservedObject var m: BuildModel
    let game: LibraryGame
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var focus: PadFocus
    @State private var survey: BuildFolderSurvey?
    @State private var chosen: Set<BuildFolderPart> = []
    @State private var confirming = false
    @State private var working = false
    @State private var outcome: String?

    init(m: BuildModel, game: LibraryGame, survey: BuildFolderSurvey? = nil, chosen: Set<BuildFolderPart> = []) {
        self.m = m
        self.game = game
        _survey = State(initialValue: survey)   // visual QA: a measured folder without one on disk
        _chosen = State(initialValue: chosen)
    }

    private var chosenBytes: Int64 { chosen.reduce(0) { $0 + (survey?.sizes[$1] ?? 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.t("free.title")).font(.manrope(26, .heavy)).tracking(-0.6)
                Text(game.name).font(.manrope(14)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 14)
            Text(m.t("free.note")).font(.manrope(13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let survey {
                        if survey.parts.isEmpty {
                            Text(m.t("free.empty")).font(.manrope(14)).foregroundStyle(.secondary)
                        } else {
                            card {
                                ForEach(survey.parts) { part in
                                    row(part, bytes: survey.sizes[part] ?? 0)
                                    Divider().opacity(0.25).padding(.leading, 18)
                                }
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(m.t("free.kept")).font(.manrope(14, .medium)).foregroundStyle(.secondary)
                                        Text(m.t("free.keptNote")).font(.manrope(12)).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 12)
                                    sizeText(survey.kept).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 18).padding(.vertical, 13)
                            }
                        }
                        if game.isReady {   // pack_app.py clones the game files and shaders into the app on the same APFS volume
                            Text(m.t("free.clones")).font(.manrope(12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
                        }
                        Text(survey.folder).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).padding(.horizontal, 2)
                    } else {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text(m.t("free.measuring")).foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal, 30).padding(.bottom, 20)
            }
            Divider().opacity(0.3)
            HStack(spacing: 14) {
                Text(outcome ?? (m.running ? m.t("free.running") : String(format: m.t("free.selected"), Self.bytes(chosenBytes))))
                    .font(.manrope(12)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                Button(m.t("free.remove")) { confirming = true }
                    .buttonStyle(LauncherSecondaryButtonStyle(accent: LauncherPalette.building))
                    .disabled(chosen.isEmpty || m.running || working)
                    .padTarget("free.remove", scope: "free") { if !chosen.isEmpty && !m.running && !working { confirming = true } }
                Button { dismiss() } label: {
                    Text(m.t("free.done")).font(.manrope(13.5, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(LauncherPalette.cream, in: Capsule())
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                .padTarget("free.done", scope: "free", radius: 20) { dismiss() }
            }
            .padding(.horizontal, 30).padding(.vertical, 16)
        }
        .padScope("free", focus)
        .frame(width: 560, height: 690)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
        .onAppear { if survey == nil { measure() } }
        .confirmationDialog(String(format: m.t("free.confirm"), Self.bytes(chosenBytes)), isPresented: $confirming, titleVisibility: .visible) {
            Button(m.t("free.confirmButton"), role: .destructive) { removeChosen() }
        } message: {
            Text(([m.t("free.confirmNote")] + BuildFolderPart.allCases.filter(chosen.contains).map { m.t("free.cost." + $0.rawValue) }).joined(separator: "\n"))
        }
    }

    private func row(_ part: BuildFolderPart, bytes: Int64) -> some View {
        let on = Binding(get: { chosen.contains(part) }, set: { if $0 { chosen.insert(part) } else { chosen.remove(part) } })
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(m.t("free.part." + part.rawValue)).font(.manrope(14, .medium))
                Text(m.t("free.cost." + part.rawValue)).font(.manrope(12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            sizeText(bytes)
            Toggle("", isOn: on).labelsHidden().toggleStyle(LauncherSwitchStyle()).disabled(working)
        }
        .padding(.horizontal, 18).padding(.vertical, 13).frame(minHeight: 52)
        .padTarget("free." + part.rawValue, scope: "free", radius: 10,
                   activate: { on.wrappedValue.toggle() }, adjust: { _ in on.wrappedValue.toggle() })
    }

    private func sizeText(_ bytes: Int64) -> some View {
        Text(Self.bytes(bytes)).font(.manrope(13, .semibold)).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
    }

    nonisolated static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private func measure() {
        let protected = BuildFolder.protectedPaths(for: game)
        guard let folder = BuildFolder.location(for: game) else { survey = BuildFolderSurvey(folder: ""); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = BuildFolder.survey(folder, protecting: protected)
            DispatchQueue.main.async { survey = result; chosen = chosen.filter { (result.sizes[$0] ?? 0) > 0 } }
        }
    }

    private func removeChosen() {
        guard let folder = survey?.folder, !folder.isEmpty else { return }
        let parts = chosen, protected = BuildFolder.protectedPaths(for: game), running = m.running
        working = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try BuildFolder.remove(parts, in: folder, protecting: protected, buildRunning: running) }
            let after = BuildFolder.survey(folder, protecting: protected)
            DispatchQueue.main.async {
                working = false
                survey = after
                chosen = []
                switch result {
                case .success(let freed): outcome = String(format: m.t("free.freed"), Self.bytes(freed))
                case .failure(FreeSpaceError.buildRunning): outcome = m.t("free.running")
                case .failure(let error): outcome = String(format: m.t("free.failed"), error.localizedDescription)
                }
            }
        }
    }
}
