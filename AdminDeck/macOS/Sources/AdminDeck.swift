// AdminDeck for macOS: a SwiftUI frontend for the AdminDroid Microsoft 365 PowerShell scripts.
//
// Scripts and their parameters are read through PowerShell 7 (pwsh) using the same
// AdminDeck.Catalog.psm1 as the Windows app (bundled in Resources by build.sh), so both
// frontends understand scripts identically. Runs happen in Terminal via a .command file.
//
// Single file, no Xcode project: see build.sh.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Catalog model (decoded from Export-AdCatalog.ps1)

struct ParamInfo: Decodable, Hashable, Identifiable {
    var Name: String
    var TypeName: String?
    var Kind: String
    var Choices: [String]?
    var Default: String?
    var Hint: String?
    var AlwaysRequired: Bool?
    var MandatorySets: [String]?
    var ParameterSets: [String]?

    var id: String { Name }
    var choices: [String] { Choices ?? [] }
    var required: Bool { AlwaysRequired ?? false }
    var isAuth: Bool { AuthNames.matches(Name) }
}

struct ScriptInfo: Decodable, Identifiable, Hashable {
    var Id: String
    var Name: String
    var Title: String?
    var Path: String
    var Folder: String
    var FolderName: String
    var Area: String?
    var Category: String?
    var Description: String?
    var Highlights: [String]?
    var DocsUrl: String?
    var Version: String?
    var Services: [String]?
    var Modules: [String]?
    var Modifies: Bool?
    var WritesToScriptRoot: Bool?
    var WindowsOnly: Bool?
    var WindowsOnlyReasons: [String]?
    var SearchText: String?
    var Parameters: [ParamInfo]?
    var ParameterSets: [String]?
    var ParseErrors: [String]?

    var id: String { Id }
    var params: [ParamInfo] { Parameters ?? [] }
    var modifies: Bool { Modifies ?? false }
    var windowsOnly: Bool { WindowsOnly ?? false }
    var area: String { Area ?? "Other" }
    var category: String { Category ?? "Other" }
    var services: [String] { Services ?? [] }

    static func == (a: ScriptInfo, b: ScriptInfo) -> Bool { a.Id == b.Id }
    func hash(into h: inout Hasher) { h.combine(Id) }
}

struct CatalogFile: Decodable {
    var repoRoot: String
    var psVersion: String?
    var knownModules: [String]?
    var scripts: [ScriptInfo]
}

enum AuthNames {
    static let regex = try! NSRegularExpression(
        pattern: "^(TenantId|TenantName|ClientId|AppId|CertificateThumbprint|Thumbprint|Organization|UserName|Password|AdminName|AdminPass\\w*|ClientSecret|CreateSession|Credential|MFA)$",
        options: [.caseInsensitive])
    static func matches(_ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    static let profileKeys = ["TenantId", "TenantName", "Organization", "ClientId", "AppId", "CertificateThumbprint", "UserName", "AdminName"]
}

// MARK: - Settings

struct AppSettings: Codable {
    var repoRoot = ""
    var outputRoot = NSHomeDirectory() + "/Documents/AdminDeck Reports"
    var pwshPath = ""
    var terminal = "Terminal"
    var keepOpen = true
    var transcript = false
    var favorites: [String] = []
    var lastValues: [String: [String: String]] = [:]
    var profile: [String: String] = [:]

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = AppSettings()
        repoRoot = try c.decodeIfPresent(String.self, forKey: .repoRoot) ?? def.repoRoot
        outputRoot = try c.decodeIfPresent(String.self, forKey: .outputRoot) ?? def.outputRoot
        pwshPath = try c.decodeIfPresent(String.self, forKey: .pwshPath) ?? def.pwshPath
        terminal = try c.decodeIfPresent(String.self, forKey: .terminal) ?? def.terminal
        keepOpen = try c.decodeIfPresent(Bool.self, forKey: .keepOpen) ?? def.keepOpen
        transcript = try c.decodeIfPresent(Bool.self, forKey: .transcript) ?? def.transcript
        favorites = try c.decodeIfPresent([String].self, forKey: .favorites) ?? []
        lastValues = try c.decodeIfPresent([String: [String: String]].self, forKey: .lastValues) ?? [:]
        profile = try c.decodeIfPresent([String: String].self, forKey: .profile) ?? [:]
    }
}

enum Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AdminDeck")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var settings: URL { support.appendingPathComponent("settings.json") }
    static var cache: URL { support.appendingPathComponent("catalog-cache.json") }
    static var history: URL { support.appendingPathComponent("history.log") }
    static var runs: URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AdminDeck/runs")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return u
    }
    static func resource(_ name: String) -> String? { Bundle.main.path(forResource: name, ofType: nil) }
}

// MARK: - PowerShell command building (mirrors ConvertTo-AdInvocation in the psm1)

enum PS {
    /// Single-quoted PowerShell literal. PowerShell also treats curly single quotes as quotes, so double those too.
    static func quote(_ s: String) -> String {
        var out = "'"
        for ch in s {
            out.append(ch)
            if ch == "'" || ch == "\u{2018}" || ch == "\u{2019}" || ch == "\u{201A}" || ch == "\u{201B}" { out.append(ch) }
        }
        return out + "'"
    }
    /// POSIX shell single-quoting for the .command file.
    static func sh(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static let timeKeySuffix = "\u{1}time"

    static func dateValue(_ values: [String: String], _ name: String) -> String {
        let d = (values[name] ?? "").trimmingCharacters(in: .whitespaces)
        let t = (values[name + timeKeySuffix] ?? "").trimmingCharacters(in: .whitespaces)
        if d.isEmpty { return "" }
        return t.isEmpty ? d : d + " " + t
    }

    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "yyyy-MM-dd H:mm", "yyyy-MM-dd HH:mm:ss", "MM/dd/yyyy", "MM/dd/yyyy HH:mm"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    struct Invocation {
        var command = ""
        var display = ""
        var secrets: [String: String] = [:]   // local variable name -> value
        var errors: [String] = []
    }

    static func build(scriptPath: String, params: [ParamInfo], values: [String: String], secrets: [String: String], extra: String) -> Invocation {
        var inv = Invocation()
        var cmd = ["& " + quote(scriptPath)]
        var disp = cmd
        var n = 0
        for p in params {
            let raw: String = p.Kind == "Date" ? dateValue(values, p.Name) : (p.Kind == "Secret" ? (secrets[p.Name] ?? "") : (values[p.Name] ?? ""))
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let flag = "-" + p.Name
            if p.required && (v.isEmpty || (p.Kind == "Switch" && v != "true")) {
                inv.errors.append("\(p.Name) is required.")
                continue
            }
            if v.isEmpty { continue }
            switch p.Kind {
            case "Switch":
                if v == "true" { cmd.append(flag); disp.append(flag) }
            case "Bool":
                let b = ["true", "1", "yes"].contains(v.lowercased()) ? "$true" : "$false"
                cmd.append("\(flag):\(b)"); disp.append("\(flag):\(b)")
            case "Number":
                if v.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) == nil {
                    inv.errors.append("\(p.Name) must be a number."); continue
                }
                cmd.append("\(flag) \(v)"); disp.append("\(flag) \(v)")
            case "Date":
                if parseDate(v) == nil { inv.errors.append("\(p.Name) is not a valid date (YYYY-MM-DD, optional HH:mm)."); continue }
                cmd.append("\(flag) \(quote(v))"); disp.append("\(flag) \(quote(v))")
            case "Choice":
                if !p.choices.contains(v) { inv.errors.append("\(p.Name) must be one of: \(p.choices.joined(separator: ", "))."); continue }
                cmd.append("\(flag) \(quote(v))"); disp.append("\(flag) \(quote(v))")
            case "List":
                let items = v.components(separatedBy: CharacterSet(charactersIn: ",;\r\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if items.isEmpty { continue }
                let a = items.map(quote).joined(separator: ",")
                cmd.append("\(flag) \(a)"); disp.append("\(flag) \(a)")
            case "Raw":
                cmd.append("\(flag) \(v)"); disp.append("\(flag) \(v)")
            case "Secret":
                n += 1
                let varName = "__adeck_s\(n)"
                inv.secrets[varName] = raw
                let ref = (p.TypeName ?? "").lowercased().contains("securestring")
                    ? "(ConvertTo-SecureString $\(varName) -AsPlainText -Force)" : "$\(varName)"
                cmd.append("\(flag) \(ref)"); disp.append("\(flag) '********'")
            default:
                cmd.append("\(flag) \(quote(v))"); disp.append("\(flag) \(quote(v))")
            }
        }
        let x = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !x.isEmpty { cmd.append(x); disp.append(x) }
        inv.command = cmd.joined(separator: " ")
        inv.display = disp.joined(separator: " ")
        return inv
    }

    /// The script run in Terminal. Secrets arrive in a 0600 JSON file in a 0700 run folder,
    /// which the script reads and deletes (with the whole run folder) before anything else runs.
    static func launchScript(inv: Invocation, title: String, runDir: String, outDir: String, transcript: Bool) -> String {
        var s: [String] = []
        s.append("$Host.UI.RawUI.WindowTitle = \(quote("AdminDeck - " + title))")
        s.append("$__adeck_run = \(quote(runDir))")
        s.append("$__adeck_secretFile = Join-Path $__adeck_run 'secrets.json'")
        s.append("$__adeck_secrets = $null")
        s.append("if (Test-Path -LiteralPath $__adeck_secretFile) { $__adeck_secrets = Get-Content -Raw -Encoding UTF8 -LiteralPath $__adeck_secretFile | ConvertFrom-Json }")
        s.append("Remove-Item -LiteralPath $__adeck_run -Recurse -Force -ErrorAction SilentlyContinue")
        for k in inv.secrets.keys.sorted() {
            s.append("$\(k) = [string]$__adeck_secrets.\(k)")
        }
        s.append("Remove-Variable __adeck_secrets")
        s.append("Set-Location -LiteralPath \(quote(outDir))")
        s.append("Write-Host \(quote("> " + inv.display)) -ForegroundColor DarkCyan")
        if transcript {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let log = (outDir as NSString).appendingPathComponent("transcript_\(f.string(from: Date())).txt")
            s.append("Start-Transcript -LiteralPath \(quote(log)) | Out-Null")
        }
        s.append("try {")
        s.append("    " + inv.command)
        s.append("} catch { Write-Host $_ -ForegroundColor Red } finally {")
        if transcript { s.append("    try { Stop-Transcript | Out-Null } catch {}") }
        s.append("    Write-Host ''; Write-Host (\(quote("AdminDeck: finished. Output folder: " + outDir))) -ForegroundColor Green")
        s.append("}")
        return s.joined(separator: "\n") + "\n"
    }

    static func writeRun(inv: Invocation, title: String, runDir: URL, outDir: String, pwsh: String, keepOpen: Bool, transcript: Bool) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: runDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !inv.secrets.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: inv.secrets)
            guard fm.createFile(atPath: runDir.appendingPathComponent("secrets.json").path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw NSError(domain: "AdminDeck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not write the secrets file."])
            }
        }
        let ps1 = runDir.appendingPathComponent("launch.ps1")
        let script = launchScript(inv: inv, title: title, runDir: runDir.path, outDir: outDir, transcript: transcript)
        // BOM so Windows PowerShell would also read it as UTF-8 (pwsh does either way).
        var data = Data([0xEF, 0xBB, 0xBF]); data.append(script.data(using: .utf8)!)
        guard fm.createFile(atPath: ps1.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "AdminDeck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not write the launch script."])
        }
        let command = runDir.appendingPathComponent("run.command")
        var sh = "#!/bin/zsh\n"
        sh += "cd \(PS.sh(outDir)) || exit 1\n"
        sh += "exec \(PS.sh(pwsh)) -NoLogo -NoProfile\(keepOpen ? " -NoExit" : "") -File \(PS.sh(ps1.path))\n"
        guard fm.createFile(atPath: command.path, contents: sh.data(using: .utf8), attributes: [.posixPermissions: 0o700]) else {
            throw NSError(domain: "AdminDeck", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not write the .command file."])
        }
        return command
    }
}

// MARK: - Processes

enum Shell {
    struct Result { var status: Int32; var out: String; var err: String }

    /// Runs a process off the main thread, capturing output via temp files (no pipe deadlocks).
    static func run(_ exe: String, _ args: [String], cwd: String? = nil) async -> Result {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let tmp = FileManager.default.temporaryDirectory
            let o = tmp.appendingPathComponent("adeck-\(UUID().uuidString).out")
            let e = tmp.appendingPathComponent("adeck-\(UUID().uuidString).err")
            FileManager.default.createFile(atPath: o.path, contents: nil)
            FileManager.default.createFile(atPath: e.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: o); try? FileManager.default.removeItem(at: e) }
            do {
                p.standardOutput = try FileHandle(forWritingTo: o)
                p.standardError = try FileHandle(forWritingTo: e)
                p.standardInput = FileHandle.nullDevice
                try p.run()
                p.waitUntilExit()
            } catch {
                return Result(status: -1, out: "", err: error.localizedDescription)
            }
            let out = (try? String(contentsOf: o, encoding: .utf8)) ?? ""
            let err = (try? String(contentsOf: e, encoding: .utf8)) ?? ""
            return Result(status: p.terminationStatus, out: out, err: err)
        }.value
    }

    static func findPwsh(_ configured: String) -> String? {
        var c: [String] = []
        if let env = ProcessInfo.processInfo.environment["ADMINDECK_PWSH"] { c.append(env) }
        c += [configured, "/opt/homebrew/bin/pwsh", "/usr/local/bin/pwsh",
              "/usr/local/microsoft/powershell/7/pwsh", "/opt/homebrew/microsoft/powershell/7/pwsh",
              NSHomeDirectory() + "/.dotnet/tools/pwsh"]
        return c.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func terminalURL(_ name: String) -> URL? {
        let ids = name == "iTerm" ? ["com.googlecode.iterm2"] : ["com.apple.Terminal"]
        for id in ids { if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u } }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
    }

    /// Opens a shell snippet in Terminal (for installs) via a throwaway .command file.
    static func openInTerminal(_ body: String, terminal: String) {
        let dir = Paths.runs.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let f = dir.appendingPathComponent("task.command")
        let text = "#!/bin/zsh -l\nrm -rf \(PS.sh(dir.path))\n" + body + "\n"
        FileManager.default.createFile(atPath: f.path, contents: text.data(using: .utf8), attributes: [.posixPermissions: 0o700])
        if let t = terminalURL(terminal) {
            NSWorkspace.shared.open([f], withApplicationAt: t, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

// MARK: - App model

enum DetailTab: String, CaseIterable, Identifiable { case run = "Run", output = "Output files", source = "Source"; var id: String { rawValue } }

struct OutputFile: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var name: String
    var modified: Date
    var size: Int64
    var location: String
}

struct RenderConfig {
    var renderTo: String?
    var select: String?
    var tab: DetailTab = .run
    var search: String?
    var catalogJSON: String?
    var sheet: String?

    static let current: RenderConfig = {
        var r = RenderConfig()
        let a = CommandLine.arguments
        func val(_ k: String) -> String? { if let i = a.firstIndex(of: k), i + 1 < a.count { return a[i + 1] }; return nil }
        r.renderTo = val("--render-to")
        r.select = val("--select")
        r.search = val("--search")
        r.catalogJSON = val("--catalog-json") ?? ProcessInfo.processInfo.environment["ADMINDECK_CATALOG_JSON"]
        r.sheet = val("--sheet")
        if let t = val("--tab") { r.tab = DetailTab.allCases.first { $0.rawValue.lowercased().hasPrefix(t.lowercased()) } ?? .run }
        return r
    }()
}

enum LoadState: Equatable { case idle, loading, ready, failed(String) }

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = AppSettings()
    @Published var catalog: [ScriptInfo] = []
    @Published var knownModules: [String] = []
    @Published var psVersion = ""
    @Published var loadState: LoadState = .idle
    @Published var pwsh: String?
    @Published var moduleStatus: [String: String]?   // module -> version, "" when missing
    @Published var search = ""
    @Published var area = "All areas"
    @Published var category = "All types"
    @Published var favoritesOnly = false
    @Published var readOnlyOnly = false
    @Published var hideWindowsOnly = false
    @Published var selection: String? { didSet { if oldValue != selection { loadForm() } } }
    @Published var tab: DetailTab = .run
    @Published var values: [String: String] = [:]
    @Published var secrets: [String: String] = [:]
    @Published var extra = ""
    @Published var status = ""
    @Published var showProfile = false
    @Published var showModules = false

    let render = RenderConfig.current

    init() {
        if let d = try? Data(contentsOf: Paths.settings), let s = try? JSONDecoder().decode(AppSettings.self, from: d) { settings = s }
    }

    func saveSettings() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(settings) { try? d.write(to: Paths.settings, options: .atomic) }
    }

    var current: ScriptInfo? { catalog.first { $0.Id == selection } }
    var areas: [String] { ["All areas"] + Array(Set(catalog.map(\.area))).sorted() }
    var categories: [String] { ["All types"] + Array(Set(catalog.map(\.category))).sorted() }

    var filtered: [ScriptInfo] {
        let terms = search.lowercased().split(separator: " ").map(String.init)
        return catalog.filter { s in
            if area != "All areas" && s.area != area { return false }
            if category != "All types" && s.category != category { return false }
            if favoritesOnly && !settings.favorites.contains(s.Id) { return false }
            if readOnlyOnly && s.modifies { return false }
            if hideWindowsOnly && s.windowsOnly { return false }
            let hay = s.SearchText ?? s.Name.lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    // MARK: startup / catalog

    func resolveRepoRoot() -> String? {
        let fm = FileManager.default
        func ok(_ p: String) -> Bool { !p.isEmpty && fm.fileExists(atPath: (p as NSString).appendingPathComponent("ScriptMetadata.csv")) }
        if ok(settings.repoRoot) { return settings.repoRoot }
        if let f = Paths.resource("repo-root.txt"), let p = try? String(contentsOfFile: f, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), ok(p) { return p }
        let cloned = Paths.support.appendingPathComponent("powershell-scripts").path
        if ok(cloned) { return cloned }
        return nil
    }

    func startup() async {
        pwsh = Shell.findPwsh(settings.pwshPath)
        if let fixture = render.catalogJSON {
            loadCatalogJSON(path: fixture)
            moduleStatus = [:]
            return
        }
        if let root = resolveRepoRoot() {
            settings.repoRoot = root
            if let d = try? Data(contentsOf: Paths.cache), let c = try? JSONDecoder().decode(CatalogFile.self, from: d), c.repoRoot == root {
                apply(c)
            }
            await reloadCatalog()
            await checkModules()
        }
    }

    func loadCatalogJSON(path: String) {
        do {
            let c = try JSONDecoder().decode(CatalogFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            apply(c)
        } catch { loadState = .failed("Could not read \(path): \(error)") }
    }

    private func apply(_ c: CatalogFile) {
        catalog = c.scripts.sorted { $0.Name.localizedStandardCompare($1.Name) == .orderedAscending }
        knownModules = c.knownModules ?? []
        psVersion = c.psVersion ?? ""
        loadState = .ready
        if let sel = selection, !catalog.contains(where: { $0.Id == sel }) { selection = nil }
    }

    func reloadCatalog() async {
        guard let pwsh else { loadState = .failed("PowerShell 7 (pwsh) was not found."); return }
        guard let root = resolveRepoRoot() else { loadState = .failed("Choose the scripts folder first."); return }
        guard let exporter = Paths.resource("Export-AdCatalog.ps1"), let module = Paths.resource("AdminDeck.Catalog.psm1") else {
            loadState = .failed("The app bundle is missing Export-AdCatalog.ps1 / AdminDeck.Catalog.psm1. Rebuild with build.sh."); return
        }
        if catalog.isEmpty { loadState = .loading }
        status = "Reading scripts with pwsh..."
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("adeck-catalog-\(UUID().uuidString).json")
        let r = await Shell.run(pwsh, ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", exporter, "-RepoRoot", root, "-ModulePath", module, "-OutFile", tmp.path])
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard r.status == 0, let d = try? Data(contentsOf: tmp) else {
            if catalog.isEmpty { loadState = .failed("pwsh could not read the scripts:\n\(r.err.isEmpty ? r.out : r.err)") }
            status = "Catalog refresh failed."
            return
        }
        do {
            let c = try JSONDecoder().decode(CatalogFile.self, from: d)
            apply(c)
            try? d.write(to: Paths.cache, options: .atomic)
            status = "\(c.scripts.count) scripts loaded from \(root)"
        } catch {
            loadState = .failed("Could not decode the catalog: \(error)")
        }
    }

    func checkModules() async {
        guard let pwsh else { return }
        moduleStatus = nil
        let names = knownModules.isEmpty ? ["Microsoft.Graph", "ExchangeOnlineManagement"] : knownModules
        let list = names.map { PS.quote($0) }.joined(separator: ",")
        let script = "$h = [ordered]@{}; foreach ($n in @(\(list))) { $m = Get-Module -ListAvailable -Name $n -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1; $h[$n] = if ($m) { [string]$m.Version } else { '' } }; $h | ConvertTo-Json -Compress"
        let r = await Shell.run(pwsh, ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script])
        if let d = r.out.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            moduleStatus = obj.mapValues { ($0 as? String) ?? "" }
        } else {
            moduleStatus = [:]
        }
    }

    // MARK: form

    func loadForm() {
        values = [:]; secrets = [:]; extra = ""
        guard let s = current else { return }
        let last = settings.lastValues[s.Id] ?? [:]
        for p in s.params {
            if p.isAuth {
                if let v = settings.profile.first(where: { $0.key.caseInsensitiveCompare(p.Name) == .orderedSame })?.value { values[p.Name] = v }
            } else {
                if let v = last[p.Name] { values[p.Name] = v }
                if let t = last[p.Name + PS.timeKeySuffix] { values[p.Name + PS.timeKeySuffix] = t }
            }
        }
    }

    func resetForm() {
        guard let s = current else { return }
        settings.lastValues[s.Id] = nil
        loadForm()
    }

    var invocation: PS.Invocation {
        guard let s = current else { return PS.Invocation() }
        return PS.build(scriptPath: s.Path, params: s.params, values: values, secrets: secrets, extra: extra)
    }

    func toggleFavorite() {
        guard let id = selection else { return }
        if let i = settings.favorites.firstIndex(of: id) { settings.favorites.remove(at: i) } else { settings.favorites.append(id) }
        saveSettings()
    }

    func outputDir(for s: ScriptInfo) -> String {
        let root = settings.outputRoot.isEmpty ? AppSettings().outputRoot : (settings.outputRoot as NSString).expandingTildeInPath
        let leaf = s.FolderName.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "_")
        return (root as NSString).appendingPathComponent(leaf)
    }

    func run() throws {
        guard let s = current else { return }
        guard let pwsh else { throw NSError(domain: "AdminDeck", code: 10, userInfo: [NSLocalizedDescriptionKey: "PowerShell 7 (pwsh) is not installed."]) }
        let inv = invocation
        let out = outputDir(for: s)
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let runDir = Paths.runs.appendingPathComponent(UUID().uuidString)
        let command = try PS.writeRun(inv: inv, title: s.Name, runDir: runDir, outDir: out, pwsh: pwsh, keepOpen: settings.keepOpen, transcript: settings.transcript)
        guard let term = Shell.terminalURL(settings.terminal) else { throw NSError(domain: "AdminDeck", code: 11, userInfo: [NSLocalizedDescriptionKey: "Terminal not found."]) }
        NSWorkspace.shared.open([command], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())

        // Remember non-secret, non-sign-in values for next time.
        var keep: [String: String] = [:]
        for p in s.params where !p.isAuth && p.Kind != "Secret" {
            if let v = values[p.Name], !v.isEmpty, !(p.Kind == "Switch" && v != "true") { keep[p.Name] = v }
            if let t = values[p.Name + PS.timeKeySuffix], !t.isEmpty { keep[p.Name + PS.timeKeySuffix] = t }
        }
        settings.lastValues[s.Id] = keep
        saveSettings()
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(out)\t\(inv.display)\n"
        if let h = try? FileHandle(forWritingTo: Paths.history) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.data(using: .utf8)!.write(to: Paths.history) }
        status = "Started \(s.Name) in \(settings.terminal). Output: \(out)"
    }

    func outputFiles(for s: ScriptInfo) -> [OutputFile] {
        let fm = FileManager.default
        var res: [OutputFile] = []
        func scan(_ dir: String, _ loc: String, filter: Bool) {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for n in items where !n.hasPrefix(".") {
                let p = (dir as NSString).appendingPathComponent(n)
                guard let a = try? fm.attributesOfItem(atPath: p), (a[.type] as? FileAttributeType) == .typeRegular else { continue }
                if filter {
                    let ext = (n as NSString).pathExtension.lowercased()
                    if !["csv", "html", "htm", "xlsx", "txt", "log", "json"].contains(ext) || n.hasPrefix("LicenseFriendlyName") { continue }
                }
                res.append(OutputFile(path: p, name: n, modified: (a[.modificationDate] as? Date) ?? .distantPast, size: (a[.size] as? Int64) ?? 0, location: loc))
            }
        }
        scan(outputDir(for: s), "output folder", filter: false)
        scan(s.Folder, "script folder", filter: true)
        return res.sorted { $0.modified > $1.modified }
    }

    func installPwsh() {
        Shell.openInTerminal("echo 'Installing PowerShell 7 with Homebrew...'\nbrew install powershell && echo && echo 'Done. Return to AdminDeck and click Retry.'", terminal: settings.terminal)
    }

    func installModule(_ name: String) {
        guard let pwsh else { return }
        let cmd = "Install-Module -Name \(PS.quote(name)) -Scope CurrentUser -Repository PSGallery -AllowClobber -Force; Write-Host 'Done. Return to AdminDeck and click Recheck.' -ForegroundColor Green"
        Shell.openInTerminal("exec \(PS.sh(pwsh)) -NoLogo -NoProfile -NoExit -Command \(PS.sh(cmd))", terminal: settings.terminal)
    }

    func cloneScripts() async {
        let dest = Paths.support.appendingPathComponent("powershell-scripts").path
        status = "Cloning scripts..."
        let r = await Shell.run("/usr/bin/git", ["clone", "--depth", "1", "https://github.com/jcacc/powershell-scripts.git", dest])
        if r.status == 0 {
            settings.repoRoot = dest; saveSettings()
            await reloadCatalog(); await checkModules()
        } else {
            loadState = .failed("git clone failed:\n\(r.err)")
        }
    }

    func chooseRepo() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "Choose the powershell-scripts folder (it contains ScriptMetadata.csv)"
        if p.runModal() == .OK, let u = p.url {
            settings.repoRoot = u.path; saveSettings()
            Task { await reloadCatalog(); await checkModules() }
        }
    }
}

// MARK: - Small views

struct Badge: View {
    let text: String
    let color: Color
    var help: String? = nil
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
            .help(help ?? text)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

struct CodeView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        let tv = sv.documentView as! NSTextView
        if tv.string != text { tv.string = text; tv.scrollToBeginningOfDocument(nil) }
    }
}

func choosePath(directory: Bool, start: String?) -> String? {
    let p = NSOpenPanel()
    p.canChooseDirectories = directory
    p.canChooseFiles = !directory
    p.canCreateDirectories = true
    if let start, !start.isEmpty { p.directoryURL = URL(fileURLWithPath: (start as NSString).expandingTildeInPath) }
    return p.runModal() == .OK ? p.url?.path : nil
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.catalog.isEmpty {
                SetupView()
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
                } detail: {
                    if let s = model.current { DetailView(script: s).id(s.Id) }
                    else {
                        ContentUnavailableView("Select a script", systemImage: "terminal",
                                               description: Text("\(model.catalog.count) Microsoft 365 scripts. Search or filter on the left."))
                    }
                }
                .searchable(text: $model.search, placement: .sidebar, prompt: "Search scripts")
            }
        }
        .toolbar {
            if !model.catalog.isEmpty { ToolbarItemGroup(placement: .primaryAction) {
                Button { model.showProfile = true } label: { Label("Connection profile", systemImage: "person.badge.key") }
                    .help("Saved TenantId / ClientId / CertificateThumbprint that pre-fill sign-in fields")
                Button { model.showModules = true } label: { Label("Modules", systemImage: "shippingbox") }
                    .help("PowerShell modules the scripts need")
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: (model.settings.outputRoot as NSString).expandingTildeInPath)) } label: {
                    Label("Reports folder", systemImage: "folder")
                }.help("Open the reports folder")
                Button { Task { await model.reloadCatalog() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Re-read the scripts (after git pull)")
            } }
        }
        .sheet(isPresented: $model.showProfile) { ProfileSheet() }
        .sheet(isPresented: $model.showModules) { ModulesSheet() }
        .task {
            await model.startup()
            await RenderMode.runIfRequested(model)
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "terminal").font(.system(size: 46)).foregroundStyle(.tint)
            Text("AdminDeck").font(.largeTitle.bold())
            Text("A Mac frontend for the AdminDroid Microsoft 365 PowerShell scripts.").foregroundStyle(.secondary)

            if model.pwsh == nil {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("PowerShell 7 is required", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                        Text("The scripts run in pwsh. Install it with Homebrew:")
                        Text("brew install powershell").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        HStack {
                            Button("Install in Terminal") { model.installPwsh() }.buttonStyle(.borderedProminent)
                            Button("Locate pwsh...") {
                                if let p = choosePath(directory: false, start: "/usr/local") { model.settings.pwshPath = p; model.saveSettings(); Task { await model.startup() } }
                            }
                            Button("Retry") { Task { await model.startup() } }
                        }
                    }.padding(6)
                }.frame(maxWidth: 520)
            } else if model.resolveRepoRoot() == nil {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Where are the scripts?", systemImage: "folder.badge.questionmark").font(.headline)
                        Text("Choose your clone of powershell-scripts, or download a copy into Application Support.")
                        HStack {
                            Button("Choose folder...") { model.chooseRepo() }.buttonStyle(.borderedProminent)
                            Button("Download (git clone)") { Task { await model.cloneScripts() } }
                        }
                    }.padding(6)
                }.frame(maxWidth: 520)
            } else {
                switch model.loadState {
                case .failed(let msg):
                    Text(msg).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: 620)
                    Button("Retry") { Task { await model.reloadCatalog() } }
                default:
                    ProgressView("Reading scripts with pwsh...")
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let items = model.filtered
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Area", selection: $model.area) { ForEach(model.areas, id: \.self) { Text($0).tag($0) } }
                        .labelsHidden()
                    Picker("Type", selection: $model.category) { ForEach(model.categories, id: \.self) { Text($0).tag($0) } }
                        .labelsHidden()
                }
                HStack(spacing: 12) {
                    Toggle("Favorites", isOn: $model.favoritesOnly)
                    Toggle("Read-only", isOn: $model.readOnlyOnly).help("Hide scripts that may change the tenant")
                    Toggle("Mac-friendly", isOn: $model.hideWindowsOnly).help("Hide scripts that need Windows-only features")
                }
                .toggleStyle(.checkbox).font(.callout)
                Text("Showing \(items.count) of \(model.catalog.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            List(items, selection: $model.selection) { s in
                ScriptRow(script: s, favorite: model.settings.favorites.contains(s.Id)).tag(s.Id)
            }
            .listStyle(.sidebar)
        }
    }
}

struct ScriptRow: View {
    let script: ScriptInfo
    let favorite: Bool
    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(script.Name).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                Text(([script.area, script.category] + script.services).joined(separator: " \u{00B7} "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if script.windowsOnly { Badge(text: "Windows", color: .gray, help: "Uses " + (script.WindowsOnlyReasons ?? []).joined(separator: ", ")) }
            if script.modifies { Badge(text: "changes", color: .orange, help: "May change tenant settings or data") }
            if favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
        }
        .padding(.vertical, 2)
        .help(script.Name)
    }
}

// MARK: - Detail

struct DetailView: View {
    @EnvironmentObject var model: AppModel
    let script: ScriptInfo

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(script: script)
            Divider()
            Picker("", selection: $model.tab) { ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380).padding(.vertical, 8)
            Divider()
            switch model.tab {
            case .run: RunView(script: script)
            case .output: OutputView(script: script)
            case .source: CodeView(text: (try? String(contentsOfFile: script.Path, encoding: .utf8)) ?? (try? String(contentsOfFile: script.Path, encoding: .isoLatin1)) ?? "Could not read \(script.Path)")
            }
            Divider()
            HStack {
                Text(model.status).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(model.pwsh.map { "pwsh \(model.psVersion) \u{00B7} \($0)" } ?? "PowerShell 7 not found: brew install powershell")
                    .lineLimit(1).truncationMode(.head)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 5)
        }
        .navigationTitle(script.Name)
    }
}

struct HeaderView: View {
    @EnvironmentObject var model: AppModel
    let script: ScriptInfo
    @State private var showHighlights = false

    var body: some View {
        let fav = model.settings.favorites.contains(script.Id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(script.Title ?? script.Name).font(.title2.weight(.semibold)).textSelection(.enabled)
                Spacer()
                Button { model.toggleFavorite() } label: { Label(fav ? "Favorite" : "Favorite", systemImage: fav ? "star.fill" : "star") }
                    .help(fav ? "Remove from favorites" : "Add to favorites")
            }
            if let d = script.Description { Text(d).foregroundStyle(.secondary).lineLimit(3) }
            FlowLayout {
                Badge(text: script.area, color: .indigo)
                Badge(text: script.category, color: .secondary)
                if script.modifies { Badge(text: "May change tenant", color: .orange, help: "You will be asked to confirm before it runs") }
                else { Badge(text: "Read-only", color: .green) }
                if script.windowsOnly { Badge(text: "Windows only: " + (script.WindowsOnlyReasons ?? []).joined(separator: ", "), color: .red) }
                ForEach(script.Modules ?? [], id: \.self) { m in
                    if let st = model.moduleStatus {
                        if let v = st[m], !v.isEmpty { Badge(text: "\(m) \(v)", color: .green, help: "Installed") }
                        else { Badge(text: "\(m) missing", color: .red, help: "Not installed for pwsh. Most scripts offer to install it; or use Modules.") }
                    } else { Badge(text: m, color: .secondary) }
                }
                if let v = script.Version { Badge(text: "v\(v)", color: .secondary) }
            }
            HStack(spacing: 8) {
                if let u = script.DocsUrl, let url = URL(string: u) { Button("Documentation") { NSWorkspace.shared.open(url) } }
                let readme = (script.Folder as NSString).appendingPathComponent("README.md")
                if FileManager.default.fileExists(atPath: readme) { Button("README") { NSWorkspace.shared.open(URL(fileURLWithPath: readme)) } }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: script.Path)]) }
                Button("Open in Editor") { openInEditor(script.Path) }
                if !(script.Highlights ?? []).isEmpty {
                    Toggle(isOn: $showHighlights) { Label("Highlights", systemImage: "list.bullet") }.toggleStyle(.button)
                }
            }
            .controlSize(.small)
            if showHighlights {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array((script.Highlights ?? []).enumerated()), id: \.offset) { _, h in
                        Text("\u{2022} " + h).font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(.top, 2)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func openInEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        for id in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.TextEdit"] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()); return
            }
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Run tab

struct RunView: View {
    @EnvironmentObject var model: AppModel
    let script: ScriptInfo
    @State private var confirm = false
    @State private var errorText: String?

    var body: some View {
        let main = script.params.filter { !$0.isAuth }
        let auth = script.params.filter { $0.isAuth }
        let inv = model.invocation
        VStack(spacing: 0) {
            Form {
                if script.windowsOnly {
                    Section {
                        Label("This script uses Windows-only features (\((script.WindowsOnlyReasons ?? []).joined(separator: ", "))). It will probably fail on macOS; run it on Windows with the Windows AdminDeck.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if !(script.ParseErrors ?? []).isEmpty {
                    Section { Text("PowerShell could not fully parse this script, so the form may be incomplete:\n" + (script.ParseErrors ?? []).prefix(3).joined(separator: "\n")).foregroundStyle(.red) }
                }
                if !(script.ParameterSets ?? []).isEmpty {
                    Section {
                        Text("This script has alternative parameter sets (\((script.ParameterSets ?? []).joined(separator: ", "))). Fill only the fields for the one you want; see the note under each field.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if script.params.isEmpty {
                    Section { Text("This script takes no parameters. Settings, if any, are edited inside the script (Open in Editor).").foregroundStyle(.secondary) }
                }
                if !main.isEmpty {
                    Section {
                        ForEach(main) { p in FieldRow(param: p) }
                    } header: { Text("Parameters") } footer: {
                        Text("Leave anything blank to use the script default; many scripts prompt for what they need.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !auth.isEmpty {
                    Section {
                        ForEach(auth) { p in FieldRow(param: p) }
                    } header: { Text("Sign-in") } footer: {
                        Text("Leave blank for interactive (MFA-capable) sign-in in your browser. Fill TenantId / ClientId / CertificateThumbprint for unattended certificate auth. Saved values come from Connection profile.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Advanced") {
                    TextField("Extra arguments", text: $model.extra, prompt: Text("e.g. -Verbose"))
                        .font(.system(.body, design: .monospaced))
                }
            }
            .formStyle(.grouped)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Command").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(inv.display, forType: .string)
                        model.status = "Command copied (secrets masked)."
                    }.controlSize(.small)
                }
                ScrollView {
                    Text(inv.display).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(7)
                }
                .frame(height: 50)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                if !inv.errors.isEmpty {
                    Text(inv.errors.joined(separator: "  ")).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text("Output to").foregroundStyle(.secondary)
                    TextField("", text: $model.settings.outputRoot).textFieldStyle(.roundedBorder)
                        .help("Each script gets its own subfolder here, and runs with it as the current folder")
                    Button("Choose...") { if let p = choosePath(directory: true, start: model.settings.outputRoot) { model.settings.outputRoot = p } }
                }
                HStack(spacing: 14) {
                    Toggle("Keep window open", isOn: $model.settings.keepOpen)
                    Toggle("Save transcript", isOn: $model.settings.transcript)
                    Picker("", selection: $model.settings.terminal) {
                        Text("Terminal").tag("Terminal")
                        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil { Text("iTerm").tag("iTerm") }
                    }.labelsHidden().fixedSize()
                    Spacer()
                    Button("Reset") { model.resetForm() }
                    Button { startRun(inv) } label: { Label("Run script", systemImage: "play.fill").padding(.horizontal, 6) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.pwsh == nil)
                        .help(model.pwsh == nil ? "Install PowerShell 7 first" : "Run in \(model.settings.terminal) (Cmd-Return)")
                }
                .toggleStyle(.checkbox)
            }
            .padding(12)
            .background(.bar)
        }
        .confirmationDialog(confirmTitle, isPresented: $confirm) {
            Button(script.modifies ? "Run (may change tenant)" : "Run anyway", role: script.modifies ? .destructive : nil) { doRun() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage(inv))
        }
        .alert("AdminDeck", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    var confirmTitle: String { script.modifies ? "Run a script that may change your tenant?" : "Run a Windows-only script?" }

    func confirmMessage(_ inv: PS.Invocation) -> String {
        var m = ""
        if script.windowsOnly { m += "It uses Windows-only features (\((script.WindowsOnlyReasons ?? []).joined(separator: ", "))) and will probably fail on macOS.\n\n" }
        if script.modifies { m += "'\(script.Name)' may change data or settings in your tenant.\n\n" }
        return m + inv.display
    }

    func startRun(_ inv: PS.Invocation) {
        if !inv.errors.isEmpty { errorText = "Fix these first:\n" + inv.errors.joined(separator: "\n"); return }
        if script.modifies || script.windowsOnly { confirm = true } else { doRun() }
    }

    func doRun() {
        do { try model.run() } catch { errorText = error.localizedDescription }
    }
}

struct FieldRow: View {
    @EnvironmentObject var model: AppModel
    let param: ParamInfo
    @State private var showCalendar = false

    var kindLabel: String {
        switch param.Kind {
        case "Switch": return "switch"
        case "Date": return "date"
        case "Number": return "number"
        case "List": return "list"
        case "Secret": return "secret, never saved"
        case "Choice": return "choice"
        case "File": return "file path"
        case "Folder": return "folder"
        case "Bool": return "true / false"
        default: return "text"
        }
    }

    var notes: String {
        var n: [String] = []
        if let h = param.Hint, !h.isEmpty { n.append(h) }
        if let d = param.Default, !d.isEmpty, param.Kind != "Switch" { n.append("Default: \(d)") }
        if param.Kind == "List" { n.append("Separate values with commas or new lines.") }
        if let s = param.ParameterSets, !s.isEmpty { n.append("Parameter set: " + s.joined(separator: ", ")) }
        if let m = param.MandatorySets, !m.isEmpty, !param.required { n.append("Required for: " + m.map { $0 == "*" ? "all sets" : $0 }.joined(separator: ", ")) }
        return n.joined(separator: "  \u{2022}  ")
    }

    func binding(_ key: String) -> Binding<String> {
        Binding(get: { model.values[key] ?? "" }, set: { model.values[key] = $0 })
    }

    var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Text(param.Name)
                if param.required { Text("*").foregroundStyle(.red) }
            }
            Text(kindLabel).font(.caption).foregroundStyle(.tertiary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if param.Kind == "Switch" {
                Toggle(isOn: Binding(get: { model.values[param.Name] == "true" }, set: { model.values[param.Name] = $0 ? "true" : "" })) { label }
            } else {
                LabeledContent { control } label: { label }
            }
            if !notes.isEmpty {
                Text(notes).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder var control: some View {
        switch param.Kind {
        case "Choice", "Bool":
            Picker("", selection: binding(param.Name)) {
                Text("\u{2014}").tag("")
                ForEach(param.Kind == "Bool" ? ["True", "False"] : param.choices, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().fixedSize()
        case "Secret":
            SecureField("", text: Binding(get: { model.secrets[param.Name] ?? "" }, set: { model.secrets[param.Name] = $0 }))
                .labelsHidden().frame(maxWidth: 320)
        case "Date":
            HStack(spacing: 6) {
                TextField("", text: binding(param.Name), prompt: Text("YYYY-MM-DD")).labelsHidden().frame(width: 110)
                Button { showCalendar.toggle() } label: { Image(systemName: "calendar") }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showCalendar) {
                        DatePicker("", selection: Binding(
                            get: { PS.parseDate(model.values[param.Name] ?? "") ?? Date() },
                            set: { d in
                                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
                                model.values[param.Name] = f.string(from: d)
                            }), displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden().padding()
                    }
                TextField("", text: binding(param.Name + PS.timeKeySuffix), prompt: Text("HH:mm")).labelsHidden().frame(width: 60)
            }
        case "List":
            TextField("", text: binding(param.Name), prompt: Text("a@contoso.com, b@contoso.com"), axis: .vertical)
                .labelsHidden().lineLimit(1...4)
        case "File", "Folder":
            HStack(spacing: 6) {
                TextField("", text: binding(param.Name)).labelsHidden()
                Button("Choose...") {
                    if let p = choosePath(directory: param.Kind == "Folder", start: (model.values[param.Name] ?? "").isEmpty ? nil : ((model.values[param.Name] ?? "") as NSString).deletingLastPathComponent) {
                        model.values[param.Name] = p
                    }
                }.controlSize(.small)
            }
        case "Number":
            TextField("", text: binding(param.Name)).labelsHidden().frame(width: 110)
        default:
            TextField("", text: binding(param.Name)).labelsHidden()
        }
    }
}

// MARK: - Output tab

struct OutputView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let script: ScriptInfo
    @State private var files: [OutputFile] = []
    @State private var selection = Set<String>()
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("View in grid") { if let f = target { open(f) } }.disabled(target == nil || !(target!.name.lowercased().hasSuffix(".csv")))
                Button("Open") { if let f = target { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) } }.disabled(target == nil)
                Button("Show in Finder") { if let f = target { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) } }.disabled(target == nil)
                Button("Open output folder") {
                    let d = model.outputDir(for: script)
                    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(URL(fileURLWithPath: d))
                }
                Text(model.outputDir(for: script)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            .controlSize(.small)
            if files.isEmpty {
                Text("Nothing yet. Files the script writes show up here (refreshes automatically).").foregroundStyle(.secondary)
                Spacer()
            } else {
                Table(files, selection: $selection) {
                    TableColumn("File", value: \.name)
                    TableColumn("Modified") { f in Text(f.modified.formatted(date: .abbreviated, time: .standard)) }.width(170)
                    TableColumn("Size") { f in Text(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)) }.width(80)
                    TableColumn("Location", value: \.location).width(100)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let f = files.first(where: { ids.contains($0.id) }) {
                        if f.name.lowercased().hasSuffix(".csv") { Button("View in grid") { open(f) } }
                        Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }
                    }
                } primaryAction: { ids in
                    if let f = files.first(where: { ids.contains($0.id) }) { open(f) }
                }
            }
        }
        .padding(12)
        .onAppear { refresh() }
        .onReceive(timer) { _ in refresh() }
    }

    var target: OutputFile? { files.first { selection.contains($0.id) } ?? files.first }

    func refresh() {
        let new = model.outputFiles(for: script)
        if new != files { files = new }
    }

    func open(_ f: OutputFile) {
        if f.name.lowercased().hasSuffix(".csv") { openWindow(value: URL(fileURLWithPath: f.path)) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) }
    }
}

// MARK: - CSV viewer

enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var it = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? { if let p = pending { pending = nil; return p }; return it.next() }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(String(field)); field = String.UnicodeScalarView()
                case "\r": break
                case "\n": row.append(String(field)); field = String.UnicodeScalarView(); rows.append(row); row = []
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(String(field)); rows.append(row) }
        return rows
    }

    static func load(_ url: URL) throws -> (headers: [String], rows: [[String]]) {
        var enc = String.Encoding.utf8
        let text = try (try? String(contentsOf: url, usedEncoding: &enc)) ?? String(contentsOf: url, encoding: .isoLatin1)
        var all = parse(text).filter { !($0.count == 1 && $0[0].isEmpty) }
        if let f = all.first, f.first?.hasPrefix("#TYPE") == true { all.removeFirst() }
        guard let headers = all.first else { return ([], []) }
        return (headers, Array(all.dropFirst()))
    }
}

struct CSVRow: Identifiable { let id: Int; let cells: [String]; func cell(_ i: Int) -> String { i < cells.count ? cells[i] : "" } }
struct CSVColumn: Identifiable { let id: Int; let name: String }

struct CellComparator: SortComparator, Hashable {
    var column: Int
    var order: SortOrder = .forward
    func compare(_ a: CSVRow, _ b: CSVRow) -> ComparisonResult {
        let r = a.cell(column).localizedStandardCompare(b.cell(column))
        if order == .forward { return r }
        return r == .orderedAscending ? .orderedDescending : (r == .orderedDescending ? .orderedAscending : .orderedSame)
    }
}

struct CSVViewer: View {
    let url: URL
    @State private var columns: [CSVColumn] = []
    @State private var rows: [CSVRow] = []
    @State private var filter = ""
    @State private var sortOrder: [CellComparator] = []
    @State private var error: String?

    var shown: [CSVRow] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var r = q.isEmpty ? rows : rows.filter { $0.cells.contains { $0.lowercased().contains(q) } }
        if !sortOrder.isEmpty { r.sort(using: sortOrder) }
        return r
    }

    var body: some View {
        let visible = shown
        VStack(spacing: 8) {
            HStack {
                TextField("Filter", text: $filter, prompt: Text("Filter rows")).textFieldStyle(.roundedBorder)
                Text(filter.isEmpty ? "\(rows.count) rows" : "\(visible.count) of \(rows.count) rows").foregroundStyle(.secondary).monospacedDigit()
                Button("Open in default app") { NSWorkspace.shared.open(url) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            Table(visible, sortOrder: $sortOrder) {
                TableColumnForEach(columns) { col in
                    TableColumn(col.name, sortUsing: CellComparator(column: col.id)) { row in
                        Text(row.cell(col.id)).lineLimit(1).help(row.cell(col.id))
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 700, minHeight: 400)
        .navigationTitle(url.lastPathComponent)
        .task {
            do {
                let (h, r) = try CSV.load(url)
                var seen: [String: Int] = [:]
                columns = h.enumerated().map { i, name in
                    let base = name.isEmpty ? "Column \(i + 1)" : name
                    seen[base, default: 0] += 1
                    return CSVColumn(id: i, name: seen[base]! > 1 ? "\(base) (\(seen[base]!))" : base)
                }
                rows = r.enumerated().map { CSVRow(id: $0.offset, cells: $0.element) }
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Sheets

struct ProfileSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection profile").font(.title3.bold())
            Text("Values here pre-fill the matching sign-in fields of every script. Use it for certificate-based (unattended) auth with an Entra app registration; the certificate must be in your login keychain. Passwords and secrets are never stored.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                ForEach(AuthNames.profileKeys, id: \.self) { k in
                    TextField(k, text: Binding(get: { draft[k] ?? "" }, set: { draft[k] = $0 }))
                }
            }
            HStack {
                Button("Clear all") { draft = [:] }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.settings.profile = draft.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                        .mapValues { $0.trimmingCharacters(in: .whitespaces) }
                    model.saveSettings()
                    model.loadForm()
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { draft = model.settings.profile }
    }
}

struct ModuleRow: Identifiable { var id: String { name }; let name: String; let installed: String; let users: Int; let note: String }

struct ModulesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    var rows: [ModuleRow] {
        (model.knownModules.isEmpty ? ["Microsoft.Graph", "ExchangeOnlineManagement"] : model.knownModules).map { m in
            let users = model.catalog.filter { ($0.Modules ?? []).contains(m) }.count
            let inst: String
            if let st = model.moduleStatus { inst = (st[m] ?? "").isEmpty ? "not installed" : st[m]! } else { inst = "checking..." }
            let note: String
            switch m {
            case "MSOnline", "AzureAD": note = "Retired by Microsoft; Windows PowerShell only"
            case "Microsoft.Online.SharePoint.PowerShell": note = "Windows only"
            case "PnP.PowerShell": note = "Needs your own Entra app (v2+)"
            default: note = ""
            }
            return ModuleRow(name: m, installed: inst, users: users, note: note)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PowerShell modules").font(.title3.bold())
            Text("Modules the scripts use, as seen by pwsh. Install / Update opens Terminal running Install-Module -Scope CurrentUser.")
                .font(.callout).foregroundStyle(.secondary)
            Table(rows, selection: $selection) {
                TableColumn("Module", value: \.name).width(min: 200, ideal: 250)
                TableColumn("Installed", value: \.installed).width(100)
                TableColumn("Scripts") { r in Text("\(r.users)").monospacedDigit() }.width(55)
                TableColumn("Note", value: \.note)
            }
            .frame(minHeight: 240)
            HStack {
                Button("Recheck") { Task { await model.checkModules() } }
                Spacer()
                Button("Install / Update selected") { if let s = selection { model.installModule(s) } }.disabled(selection == nil || model.pwsh == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 420)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section("Scripts") {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.settings.repoRoot.isEmpty ? "not set" : model.settings.repoRoot).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        Button("Choose...") { model.chooseRepo() }
                    }
                }
            }
            Section("PowerShell") {
                LabeledContent("pwsh") {
                    HStack {
                        Text(model.pwsh ?? "not found").lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        Button("Choose...") {
                            if let p = choosePath(directory: false, start: "/usr/local") { model.settings.pwshPath = p; model.saveSettings(); Task { await model.startup() } }
                        }
                    }
                }
            }
            Section("Runs") {
                TextField("Reports folder", text: $model.settings.outputRoot)
                Picker("Terminal app", selection: $model.settings.terminal) { Text("Terminal").tag("Terminal"); Text("iTerm").tag("iTerm") }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 320)
        .onDisappear { model.saveSettings() }
    }
}

// MARK: - Testing hooks

enum RenderMode {
    /// --render-to x.png [--select 'Name*'] [--tab run|output|source] [--search text] [--sheet modules|profile]
    /// Captures the main window to a PNG (no screen-recording permission needed) and quits.
    @MainActor static func runIfRequested(_ model: AppModel) async {
        let r = model.render
        guard let path = r.renderTo else { return }
        if let win = NSApp.windows.first(where: { $0.isVisible }) {
            win.setFrame(NSRect(x: 60, y: 60, width: 1320, height: 860), display: true)
        }
        if let s = r.search { model.search = s }
        if let sel = r.select {
            let pred = NSPredicate(format: "SELF LIKE[c] %@", sel)
            model.selection = model.filtered.first { pred.evaluate(with: $0.Name) }?.Id
        }
        model.tab = r.tab
        if r.sheet == "modules" { model.showModules = true }
        if r.sheet == "profile" { model.showProfile = true }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if ProcessInfo.processInfo.environment["ADMINDECK_DUMP"] != nil, let win = NSApp.windows.first(where: { $0.isVisible }), let root = win.contentView {
            func walk(_ v: NSView, _ depth: Int) {
                let r = v.convert(v.bounds, to: nil)
                var label = ""
                if let b = v as? NSButton { label = "button '\(b.title)'" }
                else if let s = v as? NSSegmentedControl { label = "segmented [\((0..<s.segmentCount).compactMap { s.label(forSegment: $0) }.joined(separator: "|"))]" }
                else if let t = v as? NSTextField { label = "field '\(t.stringValue.prefix(40))' ph='\(t.placeholderString ?? "")'" }
                else if v is NSScrollView { label = "scrollview" }
                else if v is NSPopUpButton { label = "popup" }
                if !label.isEmpty, !v.isHiddenOrHasHiddenAncestor {
                    print(String(format: "%@ x=%.0f y=%.0f w=%.0f h=%.0f  %@", String(repeating: " ", count: min(depth, 12)), r.minX, win.frame.height - r.maxY, r.width, r.height, label))
                }
                for s in v.subviews { walk(s, depth + 1) }
            }
            print("window \(win.frame.size) content \(root.frame.size) minSize \(win.contentMinSize) maxSize \(win.contentMaxSize) fitting \(root.fittingSize)")
            walk(root.superview ?? root, 0)
        }
        for (i, win) in NSApp.windows.filter({ $0.isVisible }).enumerated() {
            let out = i == 0 ? path : path.replacingOccurrences(of: ".png", with: "-\(i).png")
            if ProcessInfo.processInfo.environment["ADMINDECK_SCREENCAPTURE"] != nil {
                // Real window-server capture (needs Screen Recording permission for the caller).
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", String(win.windowNumber), out]
                try? p.run(); p.waitUntilExit()
            } else if let data = capture(win) {
                try? data.write(to: URL(fileURLWithPath: out))
            }
        }
        NSApp.terminate(nil)
    }

    /// Renders the window's layer tree (cacheDisplay mis-draws SwiftUI's layer-backed scroll views).
    @MainActor static func capture(_ win: NSWindow) -> Data? {
        guard let view = win.contentView?.superview ?? win.contentView else { return nil }
        view.wantsLayer = true
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let layer = view.layer else { return nil }
        let scale = win.backingScaleFactor
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped == false && view.isFlipped {
            ctx.translateBy(x: 0, y: view.bounds.height); ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}

enum SelfTest {
    /// --write-launch <runDir> --script <path> --outdir <path> --pwsh <exe>
    /// Writes launch.ps1 / secrets.json / run.command for a dummy script with awkward values,
    /// so the generated PowerShell can be run and checked on any machine.
    static func runIfRequested() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--write-launch"), i + 1 < a.count else { return }
        func val(_ k: String) -> String? { if let j = a.firstIndex(of: k), j + 1 < a.count { return a[j + 1] }; return nil }
        let params = [
            ParamInfo(Name: "Name", TypeName: "string", Kind: "Text"),
            ParamInfo(Name: "Password", TypeName: "string", Kind: "Secret"),
            ParamInfo(Name: "Flag", TypeName: "switch", Kind: "Switch"),
            ParamInfo(Name: "StartDate", TypeName: "nullable[datetime]", Kind: "Date"),
            ParamInfo(Name: "Users", TypeName: "string[]", Kind: "List"),
            ParamInfo(Name: "Days", TypeName: "int", Kind: "Number"),
        ]
        let values = ["Name": "O'Brien \"quoted\" $notavar \u{2019}curly\u{2019} `tick", "Flag": "true",
                      "StartDate": "2026-11-01", "StartDate" + PS.timeKeySuffix: "13:45", "Users": "a@x.com\nb@x.com", "Days": "7"]
        let inv = PS.build(scriptPath: val("--script") ?? "/tmp/Dummy.ps1", params: params, values: values,
                           secrets: ["Password": "p@ss'w$rd \u{2019}x"], extra: "")
        do {
            let cmd = try PS.writeRun(inv: inv, title: "Dummy", runDir: URL(fileURLWithPath: a[i + 1]), outDir: val("--outdir") ?? "/tmp",
                                      pwsh: val("--pwsh") ?? "pwsh", keepOpen: false, transcript: true)
            print("errors: \(inv.errors)")
            print("display: \(inv.display)")
            print("wrote \(cmd.path)")
            exit(inv.errors.isEmpty ? 0 : 1)
        } catch { print("failed: \(error)"); exit(2) }
    }
}

// MARK: - App

@main
struct AdminDeckApp: App {
    @StateObject private var model = AppModel()

    init() { SelfTest.runIfRequested() }

    var body: some Scene {
        WindowGroup("AdminDeck", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reload Scripts") { Task { await model.reloadCatalog() } }.keyboardShortcut("r")
                Button("Connection Profile...") { model.showProfile = true }
                Button("Modules...") { model.showModules = true }
            }
        }

        WindowGroup("CSV", for: URL.self) { $url in
            if let url { CSVViewer(url: url) }
        }
        .defaultSize(width: 1100, height: 700)

        Settings { SettingsView().environmentObject(model) }
    }
}
