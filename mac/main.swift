// Mac app: index.html in a web view, Bluetooth through CoreBluetooth (see app/bridge.js).
import Cocoa
import CoreBluetooth
import UniformTypeIdentifiers
import WebKit

final class Ble: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var send: (([String: Any]) -> Void) = { _ in }
    private var central: CBCentralManager!
    private var seen: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var pending: [String: Int] = [:]
    private var whenOn: [(id: Int, run: () -> Void)] = []
    private var scanning = false
    private var awake: NSObjectProtocol?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func reply(_ id: Int, _ value: Any? = nil) {
        send(["id": id, "ok": true, "value": value ?? NSNull()])
    }

    private func fail(_ id: Int, _ error: String, _ name: String = "NetworkError") {
        send(["id": id, "ok": false, "error": error, "name": name])
    }

    private func finish(_ key: String, error: String? = nil, name: String = "NetworkError") {
        guard let id = pending.removeValue(forKey: key) else { return }
        if let error { fail(id, error, name) } else { reply(id) }
    }

    private var stateError: String? {
        switch central.state {
        case .unauthorized: return "Нет доступа к Bluetooth. Разрешите его: Системные настройки → Конфиденциальность и безопасность → Bluetooth"
        case .poweredOff: return "Bluetooth выключен"
        case .unsupported: return "На этом Mac нет Bluetooth LE"
        default: return nil
        }
    }

    // Commands wait while macOS is still asking the user for Bluetooth access
    private func ready(_ id: Int, _ run: @escaping () -> Void) {
        if central.state == .poweredOn { run() }
        else if let error = stateError { fail(id, error) }
        else { whenOn.append((id, run)) }
    }

    private func char(_ uuid: String) -> CBCharacteristic? {
        let want = CBUUID(string: uuid)
        return peripheral?.services?.lazy.compactMap { $0.characteristics }.joined().first { $0.uuid == want }
    }

    func handle(_ m: [String: Any]) {
        let id = m["id"] as? Int ?? 0
        switch m["cmd"] as? String {
        case "scanStart":
            scanning = true
            ready(id) { [self] in
                guard scanning else { return }
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                reply(id)
            }
        case "scanStop":
            scanning = false
            if central.state == .poweredOn { central.stopScan() }
        case "lastDevice":
            if let dev = UserDefaults.standard.string(forKey: "device") {
                reply(id, ["device": dev, "name": UserDefaults.standard.string(forKey: "name") ?? ""])
            } else {
                reply(id)
            }
        case "connect":
            ready(id) { [self] in
                guard let uuid = UUID(uuidString: m["device"] as? String ?? ""),
                      let p = seen[uuid] ?? central.retrievePeripherals(withIdentifiers: [uuid]).first else {
                    return fail(id, "Устройство не найдено", "NotFoundError")
                }
                if let old = peripheral, old != p { central.cancelPeripheralConnection(old) }
                peripheral = p
                p.delegate = self
                if p.state == .connected { return reply(id) }
                pending["connect"] = id
                central.connect(p)
            }
        case "disconnect":
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            for (_, pid) in pending { fail(pid, "Отключено") }
            pending.removeAll()
        case "service":
            guard let p = peripheral, p.state == .connected else { return fail(id, "Не подключено") }
            let uuid = m["service"] as? String ?? ""
            if p.services?.contains(where: { $0.uuid == CBUUID(string: uuid) }) == true { return reply(id) }
            pending["service"] = id
            p.discoverServices([CBUUID(string: uuid)])
        case "characteristic":
            let want = CBUUID(string: m["service"] as? String ?? "")
            guard let p = peripheral, let svc = p.services?.first(where: { $0.uuid == want }) else {
                return fail(id, "Нет сервиса", "NotFoundError")
            }
            let uuid = m["char"] as? String ?? ""
            if char(uuid) != nil { return reply(id) }
            pending["char:" + uuid.lowercased()] = id
            p.discoverCharacteristics([CBUUID(string: uuid)], for: svc)
        case "write":
            guard let p = peripheral, let c = char(m["char"] as? String ?? "") else { return fail(id, "Не подключено") }
            let data = Data((m["data"] as? [Int] ?? []).map { UInt8(truncatingIfNeeded: $0) })
            if c.properties.contains(.writeWithoutResponse) && m["response"] as? Bool != true {
                p.writeValue(data, for: c, type: .withoutResponse)
                reply(id)
            } else {
                pending["write"] = id
                p.writeValue(data, for: c, type: .withResponse)
            }
        case "notify":
            guard let p = peripheral, let c = char(m["char"] as? String ?? "") else { return fail(id, "Не подключено") }
            if c.isNotifying { return reply(id) }
            pending["notify"] = id
            p.setNotifyValue(true, for: c)
        case "awake":
            // keep reading while the Mac is idle; the display may still sleep
            if m["on"] as? Bool == true, awake == nil {
                awake = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .userInitiated], reason: "Запись показаний батареи")
            } else if m["on"] as? Bool == false, let a = awake {
                ProcessInfo.processInfo.endActivity(a)
                awake = nil
            }
        case "save":
            save(name: m["name"] as? String ?? "battery.csv", text: m["text"] as? String ?? "")
        default:
            break
        }
    }

    private func save(name: String, text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let queued = whenOn
        if central.state == .poweredOn {
            whenOn.removeAll()
            queued.forEach { $0.run() }
        } else if let error = stateError {
            whenOn.removeAll()
            queued.forEach { fail($0.id, error) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData adv: [String: Any], rssi: NSNumber) {
        guard scanning else { return }
        seen[p.identifier] = p
        let services = (adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map { $0.uuidString.lowercased() }
        let name = adv[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? ""
        send(["event": "scan", "device": p.identifier.uuidString, "name": name,
              "services": services, "rssi": rssi.intValue == 127 ? NSNull() : rssi])
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        UserDefaults.standard.set(p.identifier.uuidString, forKey: "device")
        UserDefaults.standard.set(p.name ?? "", forKey: "name")
        finish("connect")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        finish("connect", error: error?.localizedDescription ?? "Не удалось подключиться")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p == peripheral else { return }
        finish("connect", error: "Не удалось подключиться")
        for (_, pid) in pending { fail(pid, "Связь потеряна") }
        pending.removeAll()
        send(["event": "disconnected", "device": p.identifier.uuidString])
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { return finish("service", error: error.localizedDescription) }
        // the page asks for one service at a time
        if p.services?.isEmpty ?? true {
            finish("service", error: "Нет нужного сервиса", name: "NotFoundError")
        } else {
            finish("service")
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        for key in pending.keys where key.hasPrefix("char:") {
            let uuid = String(key.dropFirst(5))
            if svc.characteristics?.contains(where: { $0.uuid == CBUUID(string: uuid) }) == true {
                finish(key)
            } else {
                finish(key, error: error?.localizedDescription ?? "Нет характеристики", name: "NotFoundError")
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        finish("write", error: error?.localizedDescription)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        finish("notify", error: error?.localizedDescription)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let value = c.value else { return }
        send(["event": "notify", "char": c.uuid.uuidString.lowercased(), "data": value.map { Int($0) }])
    }
}

final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKUIDelegate {
    private var window: NSWindow!
    private var web: WKWebView!
    private let ble = Ble()

    func applicationDidFinishLaunching(_ note: Notification) {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "ble")
        // keep polling the battery while the window is hidden or minimized
        if #available(macOS 14.0, *) { config.preferences.inactiveSchedulingPolicy = .none }
        web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = self
        ble.send = { [weak self] msg in
            guard let data = try? JSONSerialization.data(withJSONObject: msg),
                  let json = String(data: data, encoding: .utf8) else { return }
            self?.web.evaluateJavaScript("window.__ble && __ble.receive(\(json))")
        }

        let res = Bundle.main.resourceURL!
        let html = (try? String(contentsOf: res.appendingPathComponent("index.html"), encoding: .utf8)) ?? ""
        let bridge = (try? String(contentsOf: res.appendingPathComponent("bridge.js"), encoding: .utf8)) ?? ""
        // bridge.js must run before the page's own script; a fixed https origin keeps the
        // recorded history (IndexedDB) between launches. Nothing is loaded from the network.
        let page = html.replacingOccurrences(of: "<head>", with: "<head>\n<script>\(bridge)</script>",
                                             range: html.range(of: "<head>"))
        web.loadHTMLString(page, baseURL: URL(string: "https://battery.local/"))

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Монитор батареи"
        window.contentView = web
        window.setFrameAutosaveName("main")
        if !window.setFrameUsingName("main") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String,
              let m = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        ble.handle(m)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Да")
        alert.addButton(withTitle: "Отмена")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)

let menu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu()
appItem.submenu!.addItem(withTitle: "Скрыть", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appItem.submenu!.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(appItem)
let editItem = NSMenuItem()
editItem.submenu = NSMenu(title: "Правка")
editItem.submenu!.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editItem.submenu!.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
menu.addItem(editItem)
let windowItem = NSMenuItem()
windowItem.submenu = NSMenu(title: "Окно")
windowItem.submenu!.addItem(withTitle: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
windowItem.submenu!.addItem(withTitle: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
menu.addItem(windowItem)
app.mainMenu = menu

app.run()
