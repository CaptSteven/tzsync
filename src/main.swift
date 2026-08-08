// TZSync — 讓 Mac 時區跟隨代理出口的選單列小工具。
//
// 兩層作用：
//   1) 終端層（免密）：在 ~/.zshrc / ~/.bashrc 寫一段有標記的 `export TZ=...`，
//      讓終端程式（含 Claude Code，讀 OS 的 TZ）看到與出口一致的時區。
//   2) 系統層（需授權）：用 osascript 彈原生密碼框呼叫 systemsetup 改整個系統時區。
//
// 出口時區偵測走代理（預設 127.0.0.1:10808，xray），多 provider 備援，抄 notme/lib/providers.js。
//
// headless 自測：
//   TZSync --detect         走代理偵測並印出結果
//   TZSync --detect-direct  直連偵測
//   TZSync --status         印出目前系統時區 / 終端同步狀態

import Cocoa

// MARK: - 設定

let PROXY_HOST = "127.0.0.1"
let PROXY_PORT = 10808
let BEGIN_MARK = "# >>> TZSync managed >>>"
let END_MARK   = "# <<< TZSync managed <<<"
let DEFAULTS_FORCED = "forcedTZ"        // 空字串 = 自動跟隨出口
let DEFAULTS_TERM_ON = "terminalSyncOn"
let DEFAULTS_AUTO = "autoFollow"
let DEFAULTS_ORIG_TZ = "defaultSystemTZ"   // 改動前的原始系統時區，供「恢復預設」用

let US_ZONES = [
    ("Pacific（洛杉磯）", "America/Los_Angeles"),
    ("Mountain（丹佛）", "America/Denver"),
    ("Central（芝加哥）", "America/Chicago"),
    ("Eastern（紐約）", "America/New_York"),
]

// MARK: - 偵測引擎

struct DetectResult {
    let tz: String
    let country: String?
    let ip: String?
    let provider: String
    let viaProxy: Bool
}

func makeSession(useProxy: Bool) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 8
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    if useProxy {
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: PROXY_HOST,
            kCFNetworkProxiesHTTPPort as String: PROXY_PORT,
            "HTTPSEnable": 1,
            "HTTPSProxy": PROXY_HOST,
            "HTTPSPort": PROXY_PORT,
        ]
    }
    return URLSession(configuration: config)
}

func httpGetJSON(_ urlStr: String, session: URLSession) -> [String: Any]? {
    guard let url = URL(string: urlStr) else { return nil }
    var req = URLRequest(url: url)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    var out: [String: Any]? = nil
    let sem = DispatchSemaphore(value: 0)
    let task = session.dataTask(with: req) { data, resp, _ in
        defer { sem.signal() }
        guard let data = data else { return }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { return }
        out = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    task.resume()
    _ = sem.wait(timeout: .now() + 10)
    return out
}

func isValidIANA(_ tz: String) -> Bool { TimeZone(identifier: tz) != nil }

// 每個 provider：名稱、URL、從 JSON 取 (timezone, countryCode, ip)。順序 = 可靠度。
let PROVIDERS: [(name: String, url: String, parse: ([String: Any]) -> (String?, String?, String?))] = [
    ("ipwho.is", "https://ipwho.is/", { d in
        let tz = ((d["timezone"] as? [String: Any])?["id"] as? String) ?? (d["timezone"] as? String)
        return (tz, d["country_code"] as? String, d["ip"] as? String)
    }),
    ("ipapi.co", "https://ipapi.co/json/", { d in
        (d["timezone"] as? String, d["country_code"] as? String, d["ip"] as? String)
    }),
    ("ipinfo.io", "https://ipinfo.io/json", { d in
        (d["timezone"] as? String, d["country"] as? String, d["ip"] as? String)
    }),
    ("reallyfreegeoip", "https://reallyfreegeoip.org/json/", { d in
        (d["time_zone"] as? String, d["country_code"] as? String, d["ip"] as? String)
    }),
]

func detect(useProxy: Bool) -> DetectResult? {
    let session = makeSession(useProxy: useProxy)
    for p in PROVIDERS {
        guard let d = httpGetJSON(p.url, session: session) else { continue }
        let (tz, cc, ip) = p.parse(d)
        if let tz = tz, isValidIANA(tz) {
            return DetectResult(tz: tz, country: cc, ip: ip, provider: p.name, viaProxy: useProxy)
        }
    }
    return nil
}

/// 走代理優先，失敗再直連（拿到的是本機真實出口，會標記 viaProxy=false）。
func detectBest() -> DetectResult? {
    detect(useProxy: true) ?? detect(useProxy: false)
}

// MARK: - 系統時區（唯讀，免密）

func currentSystemTZ() -> String {
    if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: "/etc/localtime"),
       let r = dest.range(of: "zoneinfo/") {
        return String(dest[r.upperBound...])
    }
    return TimeZone.current.identifier
}

// MARK: - 終端層（免密）

func profilePaths() -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return ["\(home)/.zshrc", "\(home)/.bashrc"]
}

func stripBlock(_ content: String) -> String {
    var out: [String] = []
    var inside = false
    for line in content.components(separatedBy: "\n") {
        if line.contains(BEGIN_MARK) { inside = true; continue }
        if line.contains(END_MARK) { inside = false; continue }
        if !inside { out.append(line) }
    }
    return out.joined(separator: "\n")
}

/// tz == nil → 移除區塊（關閉同步）。
func writeTerminalTZ(_ tz: String?) {
    let fm = FileManager.default
    for path in profilePaths() {
        // .bashrc 不存在就跳過，避免無中生有；.zshrc 一定寫。
        let exists = fm.fileExists(atPath: path)
        if !exists && !path.hasSuffix(".zshrc") { continue }
        var content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        content = stripBlock(content)
        if let tz = tz {
            if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
            content += "\(BEGIN_MARK)\nexport TZ=\"\(tz)\"\n\(END_MARK)\n"
        }
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

func terminalManagedTZ() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard let content = try? String(contentsOfFile: "\(home)/.zshrc", encoding: .utf8) else { return nil }
    var inside = false
    for line in content.components(separatedBy: "\n") {
        if line.contains(BEGIN_MARK) { inside = true; continue }
        if line.contains(END_MARK) { break }
        if inside, let r = line.range(of: "export TZ=") {
            return line[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
    }
    return nil
}

// MARK: - 系統層（需授權）

/// 用 osascript 彈原生密碼框改系統時區。回傳是否成功。
@discardableResult
func syncSystemTZ(_ tz: String) -> Bool {
    guard isValidIANA(tz) else { return false }
    let script = "do shell script \"/usr/sbin/systemsetup -settimezone \\\"\(tz)\\\"\" with administrator privileges"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

// MARK: - headless CLI（自測用）

func runCLI(_ arg: String) -> Never {
    switch arg {
    case "--detect", "--detect-direct":
        let r = detect(useProxy: arg == "--detect")
        if let r = r {
            print("timezone=\(r.tz) country=\(r.country ?? "?") ip=\(r.ip ?? "?") provider=\(r.provider) viaProxy=\(r.viaProxy)")
            exit(0)
        } else {
            FileHandle.standardError.write("偵測失敗：所有 provider 都沒回傳有效時區\n".data(using: .utf8)!)
            exit(1)
        }
    case "--status":
        print("systemTZ=\(currentSystemTZ())")
        print("terminalManagedTZ=\(terminalManagedTZ() ?? "(未啟用)")")
        exit(0)
    case "--enable-terminal":
        guard let tz = detectBest()?.tz else {
            FileHandle.standardError.write("偵測失敗，無法啟用終端同步\n".data(using: .utf8)!)
            exit(1)
        }
        writeTerminalTZ(tz)
        UserDefaults.standard.set(true, forKey: DEFAULTS_TERM_ON)
        print("terminal sync ON: TZ=\(tz)（開新終端後生效）")
        exit(0)
    case "--disable-terminal":
        writeTerminalTZ(nil)
        UserDefaults.standard.set(false, forKey: DEFAULTS_TERM_ON)
        print("terminal sync OFF（已移除 profile 區塊）")
        exit(0)
    case "--set-default":
        let a = CommandLine.arguments
        guard a.count > 2, isValidIANA(a[2]) else {
            FileHandle.standardError.write("需要有效的 IANA 時區參數，例如 --set-default Asia/Shanghai\n".data(using: .utf8)!)
            exit(1)
        }
        UserDefaults.standard.set(a[2], forKey: DEFAULTS_ORIG_TZ)
        print("defaultSystemTZ=\(a[2])")
        exit(0)
    case "--restore":
        // headless：關終端層；系統層改回需 GUI 密碼授權，故只提示。
        writeTerminalTZ(nil)
        UserDefaults.standard.set(false, forKey: DEFAULTS_TERM_ON)
        let d = UserDefaults.standard.string(forKey: DEFAULTS_ORIG_TZ) ?? ""
        print("terminal sync OFF；系統層請在選單點「恢復預設時區」(預設=\(d.isEmpty ? "未記錄" : d))")
        exit(0)
    default:
        print("用法：TZSync [--detect|--detect-direct|--status|--enable-terminal|--disable-terminal|--set-default <tz>|--restore]")
        exit(2)
    }
}

// MARK: - 選單列 App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var last: DetectResult?
    var lastMessage: String?
    let defaults = UserDefaults.standard
    var timer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem.button?.title = "🕐"
        // 兜底：首次啟動（尚無記錄）時，把當下系統時區記為「預設」，供之後恢復。
        if origTZ == nil { origTZ = currentSystemTZ() }
        rebuildMenu(detecting: true)
        refresh()
        // 自動跟隨：每 6h 重新偵測（僅更新終端層；系統層仍需手動授權）。
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    var forcedTZ: String? {
        get { let v = defaults.string(forKey: DEFAULTS_FORCED) ?? ""; return v.isEmpty ? nil : v }
        set { defaults.set(newValue ?? "", forKey: DEFAULTS_FORCED) }
    }
    var terminalOn: Bool {
        get { defaults.bool(forKey: DEFAULTS_TERM_ON) }
        set { defaults.set(newValue, forKey: DEFAULTS_TERM_ON) }
    }
    /// 改動前的原始系統時區（第一次改系統時區前記錄，供「恢復預設」）。
    var origTZ: String? {
        get { let v = defaults.string(forKey: DEFAULTS_ORIG_TZ) ?? ""; return v.isEmpty ? nil : v }
        set { defaults.set(newValue ?? "", forKey: DEFAULTS_ORIG_TZ) }
    }

    /// 生效時區：強制指定優先，否則用偵測到的出口。
    func effectiveTZ() -> String? { forcedTZ ?? last?.tz }

    func refresh() {
        rebuildMenu(detecting: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = detectBest()
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let r = r { self.last = r }
                // 若終端同步開著，把 profile 更新為目前生效時區。
                if self.terminalOn, let tz = self.effectiveTZ() { writeTerminalTZ(tz) }
                self.rebuildMenu(detecting: false)
            }
        }
    }

    func rebuildMenu(detecting: Bool) {
        let menu = NSMenu()
        let sysTZ = currentSystemTZ()
        let exit = forcedTZ ?? last?.tz
        // 狀態列
        let statusText: String
        if detecting && last == nil {
            statusText = "偵測中…"
        } else if let exit = exit {
            let match = (exit == sysTZ) ? " ✓ 一致" : " ✗ 不一致"
            let src = forcedTZ != nil ? "強制" : (last?.viaProxy == true ? "出口" : "直連")
            statusText = "\(src): \(exit)　｜　系統: \(sysTZ)\(match)"
        } else {
            statusText = "系統: \(sysTZ)　｜　出口偵測失敗"
        }
        let statusMI = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMI.isEnabled = false
        menu.addItem(statusMI)
        if let last = last, forcedTZ == nil {
            let sub = NSMenuItem(title: "  出口 IP: \(last.ip ?? "?")（\(last.country ?? "?")，via \(last.provider)）", action: nil, keyEquivalent: "")
            sub.isEnabled = false
            menu.addItem(sub)
        }
        if let msg = lastMessage {
            let mi = NSMenuItem(title: "· \(msg)", action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
        }
        menu.addItem(.separator())

        // 終端層開關
        let termMI = NSMenuItem(title: "啟用終端時區同步（免密）", action: #selector(toggleTerminal), keyEquivalent: "")
        termMI.target = self
        termMI.state = terminalOn ? .on : .off
        menu.addItem(termMI)

        // 系統層動作
        let sysMI = NSMenuItem(title: "同步系統時區（需授權）", action: #selector(doSyncSystem), keyEquivalent: "")
        sysMI.target = self
        sysMI.isEnabled = (exit != nil)
        menu.addItem(sysMI)

        // 恢復預設時區（關同步 + 系統時區改回原值）
        let restoreTitle = origTZ != nil ? "恢復預設時區（\(origTZ!)）" : "恢復預設時區（尚未記錄）"
        let restoreMI = NSMenuItem(title: restoreTitle, action: #selector(doRestoreDefault), keyEquivalent: "")
        restoreMI.target = self
        restoreMI.isEnabled = (origTZ != nil)
        menu.addItem(restoreMI)

        // 強制指定時區子選單
        let forceMI = NSMenuItem(title: "強制指定時區", action: nil, keyEquivalent: "")
        let forceSub = NSMenu()
        let autoMI = NSMenuItem(title: "自動（跟隨出口）", action: #selector(setForced(_:)), keyEquivalent: "")
        autoMI.target = self
        autoMI.representedObject = ""
        autoMI.state = (forcedTZ == nil) ? .on : .off
        forceSub.addItem(autoMI)
        forceSub.addItem(.separator())
        for (label, tz) in US_ZONES {
            let mi = NSMenuItem(title: label, action: #selector(setForced(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = tz
            mi.state = (forcedTZ == tz) ? .on : .off
            forceSub.addItem(mi)
        }
        menu.setSubmenu(forceSub, for: forceMI)
        menu.addItem(forceMI)

        menu.addItem(.separator())
        let refreshMI = NSMenuItem(title: "立即重新偵測", action: #selector(doRefresh), keyEquivalent: "r")
        refreshMI.target = self
        menu.addItem(refreshMI)
        let quitMI = NSMenuItem(title: "退出 TZSync", action: #selector(doQuit), keyEquivalent: "q")
        quitMI.target = self
        menu.addItem(quitMI)

        statusItem.menu = menu
    }

    @objc func toggleTerminal() {
        terminalOn.toggle()
        if terminalOn, let tz = effectiveTZ() {
            writeTerminalTZ(tz)
            notify("終端時區同步已啟用", "已寫入 TZ=\(tz)，開新終端後生效")
        } else {
            writeTerminalTZ(nil)
            notify("終端時區同步已關閉", "已移除 profile 中的 TZ 設定")
        }
        rebuildMenu(detecting: false)
    }

    @objc func doSyncSystem() {
        guard let tz = effectiveTZ() else { return }
        // 第一次改系統時區前，把改動前的原值記為「預設」，供之後恢復。
        if origTZ == nil { origTZ = currentSystemTZ() }
        DispatchQueue.global().async { [weak self] in
            let ok = syncSystemTZ(tz)
            DispatchQueue.main.async {
                self?.notify(ok ? "系統時區已更新" : "系統時區更新失敗", ok ? "已設為 \(tz)" : "授權取消或時區無效")
                self?.rebuildMenu(detecting: false)
            }
        }
    }

    /// 一鍵恢復原狀：關終端同步、清強制指定、系統時區改回原始預設（需授權）。
    @objc func doRestoreDefault() {
        writeTerminalTZ(nil)
        terminalOn = false
        forcedTZ = nil
        guard let tz = origTZ else {
            notify("尚未記錄預設時區", "先用一次「同步系統時區」或命令列 --set-default 設定")
            return
        }
        DispatchQueue.global().async { [weak self] in
            let ok = syncSystemTZ(tz)
            DispatchQueue.main.async {
                self?.notify(ok ? "已恢復預設" : "恢復失敗",
                             ok ? "系統時區改回 \(tz)，終端同步已關" : "授權取消或時區無效")
                self?.rebuildMenu(detecting: false)
            }
        }
    }

    @objc func setForced(_ sender: NSMenuItem) {
        let tz = sender.representedObject as? String ?? ""
        forcedTZ = tz.isEmpty ? nil : tz
        if terminalOn, let tz = effectiveTZ() { writeTerminalTZ(tz) }
        rebuildMenu(detecting: false)
    }

    @objc func doRefresh() { refresh() }
    @objc func doQuit() { NSApp.terminate(nil) }

    // 用選單內一行狀態回饋，取代已弃用的 NSUserNotification。
    func notify(_ title: String, _ body: String) {
        lastMessage = "\(title)：\(body)"
        rebuildMenu(detecting: false)
    }
}

// MARK: - 進入點

let args = CommandLine.arguments
if args.count > 1, args[1].hasPrefix("--") {
    runCLI(args[1])
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 等同 LSUIElement：純選單列、無 Dock 圖示
app.run()
