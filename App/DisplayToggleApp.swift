import SwiftUI
import AppKit
import CoreGraphics
import IOKit
import IOKit.usb

// ⚠️ API privada de CoreGraphics/SkyLight (no documentada, no apta para App Store).
@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(_ config: CGDisplayConfigRef,
                                _ display: CGDirectDisplayID,
                                _ enabled: Bool) -> CGError

// MARK: - Idioma (español / inglés, cambio en vivo)

enum AppLanguage: String, CaseIterable {
    case es, en
    var displayName: String { self == .es ? "Español" : "English" }
}

/// Idioma de la UI. Se guarda en UserDefaults ("appLanguage"); sin preferencia guardada sigue
/// al sistema (`Locale.preferredLanguages.first` empieza con "es" → español; si no, inglés).
/// Es ObservableObject: las vistas que lo observan se redibujan al instante al cambiarlo.
@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()
    private static let defaultsKey = "appLanguage"

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey) }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let saved = AppLanguage(rawValue: raw) {
            language = saved
        } else {
            let system = Locale.preferredLanguages.first?.lowercased() ?? ""
            language = system.hasPrefix("es") ? .es : .en
        }
    }
}

/// Helper de traducción: elige el texto según el idioma activo en el momento de dibujar.
enum L10n {
    @MainActor static func t(_ es: String, _ en: String) -> String {
        LanguageManager.shared.language == .es ? es : en
    }
}

/// Texto en ambos idiomas que se resuelve al mostrarse. Se usa para mensajes guardados
/// (como `lastError`), para que también cambien de idioma si ya están en pantalla.
struct LText: Equatable {
    let es: String
    let en: String
    @MainActor var text: String { L10n.t(es, en) }
    /// Texto que ya viene localizado por macOS (p. ej. `NSError.localizedDescription`).
    static func raw(_ s: String) -> LText { LText(es: s, en: s) }

    static func joined(_ list: [LText]) -> LText {
        LText(es: list.map(\.es).joined(separator: "\n"), en: list.map(\.en).joined(separator: "\n"))
    }
}

// MARK: - Modelo

struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    var name: String
    var isEnabled: Bool
    var isMain: Bool
    let isBuiltin: Bool
    /// Sidecar / AirPlay / virtual: no se conserva en caché al desaparecer.
    let isVirtual: Bool
}

// MARK: - Sidecar (framework privado SidecarCore, cargado en tiempo de ejecución)

/// Pantalla física que la app apagó. Se persiste en UserDefaults ANTES de completar el
/// apagado: es la fuente de verdad para (1) mostrarla siempre como "Apagada" aunque macOS
/// ya no la reporte y (2) volver a encenderla al salir o al arrancar tras un cierre forzado.
struct DisabledDisplayRecord: Codable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
}

enum DisabledDisplayStore {
    private static let key = "disabledDisplays"

    static func load() -> [DisabledDisplayRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([DisabledDisplayRecord].self, from: data)
        else { return [] }
        return records
    }

    private static func save(_ records: [DisabledDisplayRecord]) {
        if records.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func add(_ record: DisabledDisplayRecord) {
        save(load().filter { $0.id != record.id } + [record])
    }

    static func remove(_ id: CGDirectDisplayID) {
        let records = load()
        if records.contains(where: { $0.id == id }) { save(records.filter { $0.id != id }) }
    }

    static func clear() { save([]) }
}

/// Un iPad apto para Sidecar. Se identifica por el UUID de SidecarCore, no por
/// CGDirectDisplayID, porque existe aunque no haya pantalla (iPad desconectado).
struct SidecarDeviceInfo: Identifiable, Codable, Equatable {
    let id: String          // SidecarDevice.identifier
    var name: String        // Nombre del iPad tal como aparece en Duplicar pantalla
}

/// Conecta y desconecta sesiones de Sidecar de forma limpia (como Centro de control),
/// en vez de congelar el framebuffer con CGSConfigureDisplayEnabled.
enum SidecarBridge {
    private static let path = "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore"
    private static let loaded: Bool = dlopen(path, RTLD_NOW) != nil

    private static var manager: NSObject? {
        guard loaded,
              let cls = NSClassFromString("SidecarDisplayManager") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("sharedManager"))
        else { return nil }
        return cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject
    }

    static var isAvailable: Bool { manager != nil }

    private static func objects(_ key: String) -> [NSObject] {
        guard let mgr = manager, mgr.responds(to: NSSelectorFromString(key)) else { return [] }
        return mgr.value(forKey: key) as? [NSObject] ?? []
    }

    private static func info(_ device: NSObject) -> SidecarDeviceInfo? {
        guard let id = (device.value(forKey: "identifier") as? NSObject)?.description else { return nil }
        let name = device.value(forKey: "name") as? String ?? "iPad"
        return SidecarDeviceInfo(id: id, name: name)
    }

    /// iPads disponibles ahora o usados recientemente (`devices` ∪ `recentDevices`).
    static func availableDevices() -> [SidecarDeviceInfo] {
        var seen = Set<String>()
        return (objects("devices") + objects("recentDevices")).compactMap(info).filter { seen.insert($0.id).inserted }
    }

    static func connectedIDs() -> Set<String> {
        Set(objects("connectedDevices").compactMap(info).map(\.id))
    }

    /// El SidecarDevice vivo para un identificador (nil si SidecarCore ya no lo ve).
    private static func device(_ id: String) -> NSObject? {
        (objects("connectedDevices") + objects("devices") + objects("recentDevices"))
            .first { info($0)?.id == id }
    }

    static func connect(_ id: String, completion: @escaping (LText?) -> Void) {
        invoke("connectToDevice:completion:", id, completion)
    }

    static func disconnect(_ id: String, completion: @escaping (LText?) -> Void) {
        invoke("disconnectFromDevice:completion:", id, completion)
    }

    /// Desconecta todos los iPad conectados. Para pantallas virtuales que no se pueden
    /// asociar a un iPad concreto. `completion` corre en el hilo principal.
    static func disconnectAll(completion: @escaping (LText?) -> Void) {
        let ids = connectedIDs()
        guard !ids.isEmpty else {
            return completion(LText(
                es: "No hay iPad conectado por Sidecar. Si es AirPlay, desconéctalo desde Centro de control.",
                en: "No iPad is connected via Sidecar. If it's AirPlay, disconnect it from Control Center."))
        }
        let group = DispatchGroup()
        var errors: [LText] = []
        for id in ids {
            group.enter()
            disconnect(id) { error in
                if let error { errors.append(error) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(errors.isEmpty ? nil : LText.joined(errors)) }
    }

    /// Ambos métodos tienen la firma `v@:@@?` (device, completion ^(NSError *)).
    /// `completion` corre siempre en el hilo principal, una sola vez.
    private static func invoke(_ selector: String, _ id: String, _ completion: @escaping (LText?) -> Void) {
        typealias Done = @convention(block) (NSError?) -> Void
        typealias Call = @convention(c) (NSObject, Selector, NSObject, Done) -> Void

        let sel = NSSelectorFromString(selector)
        guard let mgr = manager, let method = class_getInstanceMethod(type(of: mgr), sel) else {
            return completion(LText(es: "SidecarCore no está disponible en esta versión de macOS.",
                                    en: "SidecarCore isn't available on this macOS version."))
        }
        guard let device = device(id) else {
            return completion(LText(es: "SidecarCore no encuentra el iPad (¿apagado o fuera de alcance?).",
                                    en: "SidecarCore can't find the iPad (turned off or out of range?)."))
        }
        let call = unsafeBitCast(method_getImplementation(method), to: Call.self)
        let done: Done = { error in
            DispatchQueue.main.async { completion(error.map { LText.raw($0.localizedDescription) }) }
        }
        call(mgr, sel, device, done)
    }
}

/// Respaldo si SidecarCore falla: UI scripting sobre "Duplicar pantalla" en Centro de control.
/// Requiere que DisplayToggle tenga permiso de Accesibilidad y de Automatización (System Events).
enum ControlCenterFallback {
    private static let script = #"""
    on run argv
        set deviceName to item 1 of argv
        tell application "System Events"
            tell process "ControlCenter"
                set mirrorItem to missing value
                repeat with mi in menu bar items of menu bar 1
                    set d to ""
                    try
                        set d to (description of mi) as text
                    end try
                    if d contains "Mirror" or d contains "Duplica" then
                        set mirrorItem to mi
                        exit repeat
                    end if
                end repeat
                if mirrorItem is missing value then error "No encontré «Duplicar pantalla» en la barra de menú. Actívalo en Configuración del Sistema › Centro de control › Duplicar pantalla › Mostrar siempre."
                click mirrorItem
                delay 1
                set found to false
                repeat with el in (entire contents of window 1)
                    set t to ""
                    try
                        set t to (name of el) as text
                    end try
                    if t is "" or t is "missing value" then
                        try
                            set t to (description of el) as text
                        end try
                    end if
                    if t contains deviceName then
                        click el
                        set found to true
                        exit repeat
                    end if
                end repeat
                if not found then
                    key code 53
                    error "«" & deviceName & "» no aparece en Duplicar pantalla."
                end if
            end tell
        end tell
    end run
    """#

    /// Corre `osascript` fuera del hilo principal; `completion` vuelve al principal.
    static func connect(deviceName: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script, deviceName]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            var message: String?
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let raw = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    message = raw.contains("-1743") || raw.contains("-25211") || raw.contains("assistive")
                        ? "Da permiso de Accesibilidad y Automatización a DisplayToggle en Configuración del Sistema › Privacidad y seguridad."
                        : raw.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async { completion(message) }
        }
    }
}

// MARK: - USB (IOKit)

/// Observa en tiempo real si hay un iPad enchufado por cable: dispositivos USB de Apple
/// (idVendor 0x05ac) cuyo nombre contiene "iPad". Escucha altas y bajas con
/// IOServiceAddMatchingNotification en el run loop principal.
@MainActor
final class USBiPadMonitor {
    private(set) var isPluggedIn = false
    var onChange: (() -> Void)?

    private static let appleVendorID = 0x05AC
    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    init() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .defaultMode)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let monitor = Unmanaged<USBiPadMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated {
                USBiPadMonitor.drain(iterator)   // Vaciar el iterador rearma la notificación.
                monitor.rescan(notify: true)
            }
        }
        // Cada llamada consume su diccionario de matching, por eso se crea uno nuevo.
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, Self.matching(),
                                         callback, refcon, &addedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, Self.matching(),
                                         callback, refcon, &removedIterator)
        Self.drain(addedIterator)
        Self.drain(removedIterator)
        rescan(notify: false)
    }

    deinit {
        if addedIterator != 0 { IOObjectRelease(addedIterator) }
        if removedIterator != 0 { IOObjectRelease(removedIterator) }
        if let port { IONotificationPortDestroy(port) }
    }

    /// Ojo: `idVendor` va dentro de IOPropertyMatch. Puesto directo en el diccionario,
    /// IOUSBHostDevice no lo evalúa y el matching devuelve 0 dispositivos (el bug anterior).
    private static func matching() -> CFMutableDictionary {
        let dict = IOServiceMatching(kIOUSBHostDeviceClassName) as NSMutableDictionary
        dict[kIOPropertyMatchKey] = ["idVendor": appleVendorID]
        return dict as CFMutableDictionary
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    /// Recorre los dispositivos USB de Apple conectados ahora y busca un iPad.
    /// `notify: false` cuando quien llama ya va a refrescar (evita un refresh doble).
    func rescan(notify: Bool) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, Self.matching(), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            if Self.productName(service).localizedCaseInsensitiveContains("iPad") { found = true }
            IOObjectRelease(service)
        }
        if found != isPluggedIn {
            isPluggedIn = found
            if notify { onChange?() }
        }
    }

    private static func productName(_ service: io_service_t) -> String {
        for key in ["USB Product Name", "kUSBProductString"] {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String {
                return value
            }
        }
        var name = [CChar](repeating: 0, count: 128)
        return IORegistryEntryGetName(service, &name) == KERN_SUCCESS ? String(cString: name) : ""
    }
}

/// Por qué un switch está bloqueado: `message` para el tooltip, `badge` para el subtítulo.
enum LockReason {
    case loading, connecting, disconnecting, lastActive, builtinNeedsExternal, lastPhysical

    var messageText: LText {
        switch self {
        case .loading:              LText(es: "Cargando...", en: "Loading...")
        case .connecting:           LText(es: "Conectando…", en: "Connecting…")
        case .disconnecting:        LText(es: "Desconectando…", en: "Disconnecting…")
        case .lastActive:           LText(es: "Es la última pantalla activa", en: "It's the last active display")
        case .builtinNeedsExternal: LText(es: "La pantalla interna solo se apaga con otro monitor físico externo activo",
                                          en: "The built-in display can only be turned off with another external physical monitor active")
        case .lastPhysical:         LText(es: "Es la última pantalla física activa", en: "It's the last active physical display")
        }
    }

    var badgeText: LText {
        switch self {
        case .loading, .connecting, .disconnecting: messageText
        case .lastActive:           LText(es: "Protegida · Última pantalla", en: "Protected · Last display")
        case .builtinNeedsExternal: LText(es: "Protegida · Requiere monitor externo", en: "Protected · Needs external monitor")
        case .lastPhysical:         LText(es: "Protegida · Última pantalla física", en: "Protected · Last physical display")
        }
    }

    @MainActor var message: String { messageText.text }
    @MainActor var badge: String { badgeText.text }
}

enum DisplayKind {
    /// Las pantallas AirPlay/Sidecar reportan vendor "aapl" (0x6161706C) en vez del ID EDID de Apple (0x610).
    static let airPlayVendor: UInt32 = 0x6161_706C
    static let virtualKeywords = ["sidecar", "airplay", "virtual", "dummy"]

    static func isVirtual(_ id: CGDirectDisplayID, name: String) -> Bool {
        if CGDisplayIsBuiltin(id) != 0 { return false }
        if CGDisplayVendorNumber(id) == airPlayVendor { return true }
        let lower = name.lowercased()
        return virtualKeywords.contains { lower.contains($0) }
    }
}

@MainActor
final class DisplayManager: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []
    @Published var lastError: LText?
    /// Pantallas con una desconexión de Sidecar en curso (switch bloqueado mientras tanto).
    @Published private(set) var pending: Set<CGDirectDisplayID> = []

    /// Pantallas vistas desde que abrió la app. Una pantalla física apagada
    /// desaparece de CGGetOnlineDisplayList, pero aquí se conserva con isEnabled = false.
    /// Las virtuales (Sidecar/AirPlay) se eliminan en cuanto dejan de estar activas.
    private var knownDisplays: [CGDirectDisplayID: DisplayInfo] = [:]
    /// Pantallas que esta app apagó a propósito: nunca se ocultan como duplicado.
    private var disabledByApp: Set<CGDirectDisplayID> = []
    /// Orden de detección, para que la lista no salte al apagar/prender.
    private var order: [CGDirectDisplayID] = []
    private var observers: [NSObjectProtocol] = []

    /// iPads de Sidecar: los que ve SidecarCore más los guardados en UserDefaults,
    /// para que sigan en la lista como "Desconectada" y se puedan volver a conectar.
    @Published private(set) var sidecarDevices: [SidecarDeviceInfo] = []
    @Published private(set) var sidecarConnected: Set<String> = []
    @Published private(set) var sidecarPending: Set<String> = []
    private static let sidecarDefaultsKey = "knownSidecarDevices"
    private var sidecarOps: [String: UUID] = [:]
    static let connectFailedMessage = LText(
        es: "No se pudo conectar. Si usas AirPlay, despierta el iPad primero.",
        en: "Could not connect. If using AirPlay, wake the iPad first.")

    /// true si hay un iPad enchufado por cable USB (se actualiza con notificaciones de IOKit).
    @Published private(set) var iPadOnUSB = false
    private let usbMonitor = USBiPadMonitor()

    /// Ventana de 3 s tras tocar el switch del iPad o tras quitar el cable con la sesión
    /// activa: el estado de Sidecar todavía no es fiable (p. ej. sigue "activa" pero ya sin
    /// USB, y aún no es AirPlay real). Mientras dura: "Cargando..." y switch bloqueado.
    @Published private(set) var sidecarTransitioning = false
    private var transitionToken = UUID()
    private static let transitionDuration: TimeInterval = 3
    private var refreshScheduled = false

    private func beginTransition() {
        let token = UUID()
        transitionToken = token          // Un evento nuevo reinicia los 3 s.
        sidecarTransitioning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.transitionDuration) { [weak self] in
            guard let self, self.transitionToken == token else { return }
            self.sidecarTransitioning = false
            self.refresh()               // Mostrar el estado ya estabilizado.
        }
    }

    /// Actualiza el estado del cable y abre la ventana de transición si se desenchufó
    /// mientras había una sesión de Sidecar activa (consulta en vivo, no la caché).
    private func updateUSB(_ plugged: Bool) {
        guard plugged != iPadOnUSB else { return }
        let unplugged = iPadOnUSB && !plugged
        iPadOnUSB = plugged
        if unplugged && !SidecarBridge.connectedIDs().isEmpty { beginTransition() }
    }

    /// Agrupa ráfagas de avisos de reconfiguración en un solo refresh.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.sidecarDefaultsKey),
           let saved = try? JSONDecoder().decode([SidecarDeviceInfo].self, from: data) {
            sidecarDevices = saved
        }
        iPadOnUSB = usbMonitor.isPluggedIn
        usbMonitor.onChange = { [weak self] in
            guard let self else { return }
            self.updateUSB(self.usbMonitor.isPluggedIn)
            self.refresh()
        }
        refresh()

        // Aviso de CoreGraphics al terminar cada reconfiguración (p. ej. cuando macOS acaba
        // de destruir el display virtual de Sidecar). Complementa didChangeScreenParameters.
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
            let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { manager.scheduleRefresh() } }
        }, Unmanaged.passUnretained(self).toOpaque())
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        // La restauración al salir vive en AppDelegate (quitAppSafely / applicationWillTerminate).
    }

    func refresh() {
        var screenNames: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                screenNames[num.uint32Value] = screen.localizedName
            }
        }
        let active = Set(Self.list(CGGetActiveDisplayList))
        let online = Self.list(CGGetOnlineDisplayList)

        // Pantallas que el sistema reporta ahora: alta o actualización.
        for id in Set(online).union(active) {
            if var known = knownDisplays[id] {
                if let name = screenNames[id] { known.name = name }
                known.isEnabled = active.contains(id)
                known.isMain = CGDisplayIsMain(id) != 0
                knownDisplays[id] = known
            } else {
                let builtin = CGDisplayIsBuiltin(id) != 0
                // "" = sin nombre de NSScreen; la vista pone uno genérico en el idioma activo.
                let name = screenNames[id] ?? ""
                knownDisplays[id] = DisplayInfo(
                    id: id,
                    name: name,
                    isEnabled: active.contains(id),
                    isMain: CGDisplayIsMain(id) != 0,
                    isBuiltin: builtin,
                    isVirtual: DisplayKind.isVirtual(id, name: name)
                )
                order.append(id)
            }
        }

        // Aquí solo entran las que no están activas: desconectadas (fuera de
        // CGGetOnlineDisplayList) o con CGDisplayIsActive == false.
        for (id, info) in knownDisplays where !active.contains(id) {
            if info.isVirtual {
                // Sidecar/AirPlay: al reconectar llega con otro ID, así que se borra ya.
                knownDisplays[id] = nil
                disabledByApp.remove(id)
            } else {
                // Física: se queda marcada como apagada para poder volver a encenderla.
                knownDisplays[id]?.isEnabled = false
                knownDisplays[id]?.isMain = false
            }
        }
        order.removeAll { knownDisplays[$0] == nil }

        // Fusión con UserDefaults: una pantalla que la app apagó NUNCA sale de la lista,
        // aunque macOS ya no la reporte o la caché en memoria se haya perdido (reinicio).
        for record in DisabledDisplayStore.load() {
            if active.contains(record.id) {
                // Se volvió a encender por otra vía (Configuración, reconexión): registro obsoleto.
                DisabledDisplayStore.remove(record.id)
                disabledByApp.remove(record.id)
                continue
            }
            if knownDisplays[record.id] == nil {
                knownDisplays[record.id] = DisplayInfo(
                    id: record.id, name: record.name, isEnabled: false, isMain: false,
                    isBuiltin: record.isBuiltin, isVirtual: false)
                order.append(record.id)
            } else {
                knownDisplays[record.id]?.isEnabled = false
            }
            disabledByApp.insert(record.id)   // También la protege del filtro de duplicados.
        }

        refreshSidecar()
        checkSidecarConsistency(activeVirtual: Set(active.filter {
            DisplayKind.isVirtual($0, name: screenNames[$0] ?? knownDisplays[$0]?.name ?? "")
        }))
        // Si hay iPads en la sección de Sidecar, su pantalla virtual ya está representada
        // allí: no se repite en la lista de pantallas.
        let hideSidecarDisplays = !sidecarDevices.isEmpty
        displays = Self.dedupe(order.compactMap { knownDisplays[$0] }, keep: disabledByApp)
            .filter { !(hideSidecarDisplays && $0.isVirtual && $0.name.lowercased().contains("sidecar")) }
    }

    /// Displays virtuales activos en el refresh anterior, para detectar cuándo macOS destruye uno.
    private var lastActiveVirtual: Set<CGDirectDisplayID> = []
    private var mismatchHandled = false
    private var followUpToken = UUID()

    /// Las notificaciones de pantalla llegan cuando CoreGraphics destruye el display virtual,
    /// pero SidecarCore puede actualizar `connectedDevices` un momento después (p. ej. el iPad
    /// se suspende y macOS cierra la sesión AirPlay en segundo plano). Un solo refresh en ese
    /// instante leería "sigue conectado". Por eso se reconsulta unos segundos más tarde cuando:
    ///  - desaparece un display virtual que estaba activo, o
    ///  - SidecarCore dice "conectado" pero no hay ningún display virtual activo (incoherente).
    private func checkSidecarConsistency(activeVirtual: Set<CGDirectDisplayID>) {
        let lostVirtual = !lastActiveVirtual.subtracting(activeVirtual).isEmpty
        lastActiveVirtual = activeVirtual

        let mismatch = !sidecarConnected.isEmpty && activeVirtual.isEmpty && sidecarPending.isEmpty
        if lostVirtual || (mismatch && !mismatchHandled) { scheduleSidecarFollowUps() }
        mismatchHandled = mismatch     // Un solo ciclo de reintentos por episodio incoherente.
    }

    private func scheduleSidecarFollowUps() {
        let token = UUID()
        followUpToken = token          // Un evento nuevo reemplaza los reintentos pendientes.
        for delay in [1.0, 2.5, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.followUpToken == token else { return }
                self.refresh()
            }
        }
    }

    private func refreshSidecar() {
        // Se reevalúa el cable en cada refresh (abrir el menú, cambio de pantallas,
        // fin de conexión Sidecar), además de las notificaciones USB de IOKit.
        usbMonitor.rescan(notify: false)
        updateUSB(usbMonitor.isPluggedIn)

        var merged = sidecarDevices
        for d in SidecarBridge.availableDevices() {
            if let i = merged.firstIndex(where: { $0.id == d.id }) {
                merged[i].name = d.name
            } else {
                merged.append(d)
            }
        }
        if merged != sidecarDevices {
            sidecarDevices = merged
            if let data = try? JSONEncoder().encode(merged) {
                UserDefaults.standard.set(data, forKey: Self.sidecarDefaultsKey)
            }
        }
        sidecarConnected = SidecarBridge.connectedIDs()
    }

    /// Conectar nunca se bloquea. Desconectar solo si queda al menos una pantalla física
    /// activa: Sidecar por sí solo no cuenta como respaldo (ni para la pantalla interna).
    func sidecarLockReason(_ d: SidecarDeviceInfo) -> LockReason? {
        let connected = sidecarConnected.contains(d.id)
        if sidecarTransitioning { return .loading }
        if sidecarPending.contains(d.id) { return connected ? .disconnecting : .connecting }
        guard connected else { return nil }
        if !Self.list(CGGetActiveDisplayList).contains(where: { !isVirtual($0) }) { return .lastActive }
        return nil
    }

    func setSidecar(_ d: SidecarDeviceInfo, connected: Bool) {
        lastError = nil
        // Doble seguro: ignorar clics mientras el estado se estabiliza (también al conectar).
        guard !sidecarTransitioning, !sidecarPending.contains(d.id) else { return }
        if !connected, let reason = sidecarLockReason(d) {
            lastError = LText(es: "No se puede desconectar: \(reason.messageText.es.lowercased()).",
                              en: "Can't disconnect: \(reason.messageText.en.lowercased()).")
            return
        }
        beginTransition()
        sidecarPending.insert(d.id)
        let token = UUID()
        sidecarOps[d.id] = token

        // Termina una sola vez (respuesta real o timeout, lo que llegue primero) y solo
        // si sigue siendo la operación vigente para ese iPad.
        let finish: (LText?) -> Void = { [weak self] error in
            guard let self, self.sidecarOps[d.id] == token else { return }
            self.sidecarOps[d.id] = nil
            self.sidecarPending.remove(d.id)
            self.lastError = error
            self.refresh()
        }

        if connected {
            // 1º SidecarCore; 2º, si falla, UI scripting en Centro de control.
            SidecarBridge.connect(d.id) { coreError in
                guard let coreError else { return finish(nil) }
                ControlCenterFallback.connect(deviceName: d.name) { fallbackError in
                    guard let fallbackError else { return finish(nil) }
                    // El detalle técnico va al log (Consola.app); la UI muestra un mensaje corto.
                    NSLog("DisplayToggle: no se pudo conectar %@. SidecarCore: %@ · Centro de control: %@",
                          d.name, coreError.es, fallbackError)
                    finish(Self.connectFailedMessage)
                }
            }
        } else {
            SidecarBridge.disconnect(d.id, completion: finish)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            finish(connected ? Self.connectFailedMessage
                             : LText(es: "Sidecar no respondió a tiempo. Revisa que el iPad esté desbloqueado y cerca.",
                                     en: "Sidecar didn't respond in time. Make sure the iPad is unlocked and nearby."))
        }
    }

    /// Si hay una entrada apagada con el mismo nombre que otra encendida, oculta la apagada
    /// (restos de una reconexión con ID nuevo). Las que apagó esta app se respetan, para no
    /// esconder un monitor idéntico a otro que tú apagaste a propósito.
    private static func dedupe(_ list: [DisplayInfo], keep: Set<CGDirectDisplayID>) -> [DisplayInfo] {
        let enabledNames = Set(list.filter(\.isEnabled).map(\.name))
        return list.filter { d in
            d.isEnabled || keep.contains(d.id) || d.name.isEmpty || !enabledNames.contains(d.name)
        }
    }

    /// Motivo por el que el switch está bloqueado, o nil si se puede usar.
    func lockReason(_ d: DisplayInfo) -> LockReason? {
        if pending.contains(d.id) { return .disconnecting }
        guard d.isEnabled else { return nil }   // Encender siempre está permitido.
        return turnOffBlockReason(d.id)
    }

    /// Reglas de seguridad para apagar una pantalla, evaluadas con el estado real de
    /// CoreGraphics en este momento (no con la caché). Devuelve el motivo del bloqueo o nil.
    func turnOffBlockReason(_ id: CGDirectDisplayID) -> LockReason? {
        let active = Self.list(CGGetActiveDisplayList)
        guard active.contains(id) else { return nil }   // Ya está apagada.

        // 1. Regla general: nunca quedar con 0 pantallas activas.
        if active.count <= 1 { return .lastActive }

        // Sidecar/AirPlay pueden desconectarse solas, así que no cuentan como respaldo.
        let otherPhysical = active.filter { $0 != id && !isVirtual($0) }

        // 2. Pantalla interna: solo con otro monitor físico externo activo.
        if CGDisplayIsBuiltin(id) != 0 && otherPhysical.isEmpty { return .builtinNeedsExternal }
        // Mismo criterio para cualquier monitor físico: no dejar solo pantallas inalámbricas.
        if !isVirtual(id) && otherPhysical.isEmpty { return .lastPhysical }
        return nil
    }

    private func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        knownDisplays[id]?.isVirtual ?? DisplayKind.isVirtual(id, name: "")
    }

    func isLocked(_ d: DisplayInfo) -> Bool { lockReason(d) != nil }

    /// Enciende, en una sola transacción, toda pantalla conocida que esté apagada.
    /// ÚNICO punto del código que llama a CGSConfigureDisplayEnabled. Rechaza cualquier
    /// display virtual (Sidecar/AirPlay), comprobado en vivo por vendor "aapl" y por nombre:
    /// sobre ellos congela el framebuffer y deja la sesión huérfana en SidecarRelay.
    /// El iPad solo se conecta/desconecta abriendo o cerrando su sesión de Sidecar.
    private func configurePhysical(_ config: CGDisplayConfigRef, _ id: CGDirectDisplayID,
                                   _ enabled: Bool) -> CGError {
        if isVirtual(id) || DisplayKind.isVirtual(id, name: knownDisplays[id]?.name ?? "") {
            return .illegalArgument
        }
        return CGSConfigureDisplayEnabled(config, id, enabled)
    }

    /// Vuelve a encender, de forma síncrona y en una sola transacción, toda pantalla que la
    /// app haya apagado: las de UserDefaults (sobreviven a cierres forzados, incluida la
    /// integrada ID 1 si quedó registrada) + las de memoria. Luego limpia los registros.
    /// Se llama al salir (todos los caminos) y al arrancar (por si hubo un cierre forzado).
    func restoreDisabledDisplays() {
        let active = Set(Self.list(CGGetActiveDisplayList))
        var ids = Set(DisabledDisplayStore.load().map(\.id))
        ids.formUnion(disabledByApp)
        ids.formUnion(knownDisplays.values.filter { !$0.isEnabled && !$0.isVirtual }.map(\.id))
        // Solo físicas apagadas: una virtual de Sidecar nunca pasa por CGSConfigureDisplayEnabled.
        let off = ids.filter { !active.contains($0) && !isVirtual($0) }

        if !off.isEmpty {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let config {
                for id in off { _ = configurePhysical(config, id, true) }
                if CGCompleteDisplayConfiguration(config, .permanently) != .success {
                    NSLog("DisplayToggle: no se pudieron reactivar las pantallas %@", off.map(String.init).joined(separator: ", "))
                }
            }
        }
        DisabledDisplayStore.clear()
        disabledByApp.removeAll()
    }

    func set(_ id: CGDirectDisplayID, enabled: Bool) {
        lastError = nil
        // Doble seguro: misma validación que la UI, justo antes de tocar CoreGraphics/Sidecar.
        if !enabled, let reason = turnOffBlockReason(id) {
            lastError = LText(es: "No se puede apagar: \(reason.messageText.es.lowercased()).",
                              en: "Can't turn off: \(reason.messageText.en.lowercased()).")
            return
        }
        if knownDisplays[id]?.isVirtual == true {
            // Nunca CGSConfigureDisplayEnabled aquí: congela el framebuffer y traba SidecarRelay.
            // Solo se muestran mientras están conectadas, así que "encender" no aplica.
            guard !enabled else { return }
            pending.insert(id)
            SidecarBridge.disconnectAll { [weak self] error in
                guard let self else { return }
                self.pending.remove(id)
                self.lastError = error
                // La pantalla sale de la lista al quedar inactiva (ver refresh()).
                self.refresh()
            }
            return
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            lastError = LText(es: "No se pudo iniciar la configuración.", en: "Couldn't start the display configuration.")
            return
        }
        guard configurePhysical(config, id, enabled) == .success else {
            CGCancelDisplayConfiguration(config)
            lastError = LText(es: "Error al cambiar la pantalla \(id).", en: "Error changing display \(id).")
            return
        }
        // Al apagar, el registro se guarda ANTES de completar: si la app muere justo después,
        // el próximo arranque igual sabe que tiene que volver a encenderla.
        if !enabled {
            let info = knownDisplays[id]
            DisabledDisplayStore.add(DisabledDisplayRecord(
                id: id,
                name: info?.name ?? "",
                isBuiltin: info?.isBuiltin ?? (CGDisplayIsBuiltin(id) != 0)))
        }
        // .forSession: el apagado se deshace al reiniciar el Mac (más seguro).
        if CGCompleteDisplayConfiguration(config, .forSession) != .success {
            lastError = LText(es: "Error al aplicar el cambio.", en: "Error applying the change.")
            if !enabled { DisabledDisplayStore.remove(id) }   // No llegó a apagarse.
        } else if enabled {
            disabledByApp.remove(id)
            DisabledDisplayStore.remove(id)
        } else {
            disabledByApp.insert(id)
        }
        refresh()
    }

    private typealias ListFn = (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

    private static func list(_ fn: ListFn) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        _ = fn(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        _ = fn(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }
}

// MARK: - UI

struct DisplayRow: View {
    let display: DisplayInfo
    @ObservedObject var manager: DisplayManager
    @ObservedObject private var lang = LanguageManager.shared   // Redibuja al cambiar idioma.

    var body: some View {
        let d = display
        let lock = manager.lockReason(d)
        let canToggle = lock == nil

        HStack(spacing: 8) {
            Image(systemName: d.isBuiltin ? "laptopcomputer" : d.isVirtual ? "ipad.landscape" : "display")
                .foregroundStyle(d.isEnabled ? .primary : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName).lineLimit(1)
                Text(subtitle(lock))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(canToggle ? 1.0 : 0.6)

            Spacer(minLength: 12)

            // En un panel de MenuBarExtra el switch deshabilitado conserva el azul de acento,
            // así que se fuerza gris + transparencia para que el bloqueo se note.
            Toggle("", isOn: Binding(
                get: { d.isEnabled },
                set: { manager.set(d.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(canToggle ? .accentColor : .gray)
            .saturation(canToggle ? 1.0 : 0.0)
            .opacity(canToggle ? 1.0 : 0.45)
            .disabled(!canToggle)
        }
        // .help en el contenedor: en un control deshabilitado el tooltip no aparece.
        .contentShape(Rectangle())
        .help(lock?.message ?? "")
    }

    /// Nombre de NSScreen (lo da macOS) o uno genérico en el idioma activo.
    private var displayName: String {
        let d = display
        if !d.name.isEmpty { return d.name }
        return d.isBuiltin ? L10n.t("Pantalla integrada", "Built-in display")
                           : L10n.t("Pantalla \(d.id)", "Display \(d.id)")
    }

    private func subtitle(_ lock: LockReason?) -> String {
        let d = display
        if let lock { return lock.badge }
        if d.isVirtual { return "Sidecar/AirPlay · ID \(d.id)" }
        if !d.isEnabled { return L10n.t("Apagada · ID \(d.id)", "Off · ID \(d.id)") }
        return d.isMain ? L10n.t("Principal · ID \(d.id)", "Primary · ID \(d.id)") : "ID \(d.id)"
    }
}

struct SidecarRow: View {
    let device: SidecarDeviceInfo
    @ObservedObject var manager: DisplayManager
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        let connected = manager.sidecarConnected.contains(device.id)
        let lock = manager.sidecarLockReason(device)
        let canToggle = lock == nil

        HStack(spacing: 8) {
            Image(systemName: "ipad.landscape")
                .foregroundStyle(connected ? .primary : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                Text(lock?.badge ?? subtitle(connected: connected, usb: manager.iPadOnUSB))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(canToggle ? 1.0 : 0.6)

            Spacer(minLength: 12)

            Toggle("", isOn: Binding(
                get: { connected },
                set: { manager.setSidecar(device, connected: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(canToggle ? .accentColor : .gray)
            .saturation(canToggle ? 1.0 : 0.0)
            .opacity(canToggle ? 1.0 : 0.45)
            .disabled(!canToggle)
        }
        .contentShape(Rectangle())
        .help(lock?.message ?? (connected
            ? L10n.t("Desconectar Sidecar", "Disconnect Sidecar")
            : L10n.t("Por AirPlay el iPad debe estar despierto para conectar; por USB despierta automáticamente.",
                     "Over AirPlay, the iPad must be awake to connect; over USB, it wakes automatically.")))
    }

    /// Activo + cable → USB; activo sin cable → AirPlay (inalámbrico).
    private func subtitle(connected: Bool, usb: Bool) -> String {
        switch (connected, usb) {
        case (true, true):   L10n.t("Conectada · USB", "Connected · USB")
        case (true, false):  L10n.t("Conectada · AirPlay", "Connected · AirPlay")
        case (false, true):  L10n.t("Desconectada · USB", "Disconnected · USB")
        case (false, false): L10n.t("Desconectada", "Disconnected")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var manager: DisplayManager
    /// Salida segura (reactiva pantallas antes de terminar); la inyecta AppDelegate.
    let onQuit: () -> Void
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("Pantallas", "Displays"))
                .font(.headline)

            ForEach(manager.displays) { d in
                DisplayRow(display: d, manager: manager)
            }

            if !manager.sidecarDevices.isEmpty {
                Text("iPad (Sidecar)")
                    .font(.headline)
                    .padding(.top, 4)
                ForEach(manager.sidecarDevices) { device in
                    SidecarRow(device: device, manager: manager)
                }
            }

            if let error = manager.lastError {
                Text(error.text)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)   // Multilínea, sin truncar.
            }

            Divider()

            HStack {
                Button {
                    // Abre Configuración del Sistema › Pantallas (organizar, resolución, principal).
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(L10n.t("Organizar…", "Arrange…"), systemImage: "slider.horizontal.3")
                }
                .help(L10n.t("Abrir la configuración de Pantallas de macOS", "Open macOS Displays settings"))
                Spacer()
                Button(L10n.t("Salir", "Quit")) { onQuit() }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { manager.refresh() }
    }
}

// MARK: - Barra de menú (NSStatusItem + NSPopover)

/// MenuBarExtra no deja distinguir clic izquierdo de clic derecho, así que el ícono es un
/// NSStatusItem propio: clic izquierdo abre/cierra el popover con la misma vista SwiftUI;
/// clic derecho o Control+clic muestra un NSMenu contextual nativo con "Salir".
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = DisplayManager()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    /// Se arma en cada clic derecho para que títulos y checkmark reflejen el idioma actual:
    ///   Idioma ▸ (✓ Español / English)
    ///   ─────────
    ///   Salir
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        let languageMenu = NSMenu()
        for language in AppLanguage.allCases {
            let item = NSMenuItem(title: language.displayName,
                                  action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = LanguageManager.shared.language == language ? .on : .off
            languageMenu.addItem(item)
        }
        let languageItem = NSMenuItem(title: L10n.t("Idioma", "Language"), action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.t("Salir", "Quit"),
                              action: #selector(quitAppSafely), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// Guarda en UserDefaults (vía LanguageManager) y SwiftUI se redibuja al instante.
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        LanguageManager.shared.language = language
    }

    /// Único camino de salida desde la UI ("Salir" del popover y del menú contextual):
    /// primero reactiva de forma síncrona toda pantalla apagada (UserDefaults + memoria,
    /// `.permanently`), limpia los registros y solo entonces termina el proceso.
    @objc func quitAppSafely() {
        manager.restoreDisabledDisplays()
        NSApp.terminate(nil)
    }

    /// Red de seguridad para salidas que no pasan por quitAppSafely (⌘Q del sistema,
    /// cerrar sesión, apagar el Mac). Si ya se restauró, aquí no queda nada que hacer.
    func applicationWillTerminate(_ notification: Notification) {
        manager.restoreDisabledDisplays()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Si la sesión anterior terminó por la fuerza (kill -9, crash, Forzar salida) con
        // pantallas apagadas, UserDefaults aún las tiene: se encienden al arrancar.
        manager.restoreDisabledDisplays()
        manager.refresh()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "DisplayToggle")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // Sin esto el botón solo envía la acción con el clic izquierdo.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let hosting = NSHostingController(rootView: MenuContent(manager: manager) { [weak self] in
            self?.quitAppSafely()
        })
        hosting.sizingOptions = .preferredContentSize   // El popover se ajusta al contenido.
        popover.contentViewController = hosting
        popover.behavior = .transient                   // Se cierra al hacer clic fuera.
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let isSecondary = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if isSecondary {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        manager.refresh()   // Estado fresco cada vez que se abre.
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        // App LSUIElement: hay que activarla para que el popover reciba foco y .transient funcione.
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu() {
        if popover.isShown { popover.performClose(nil) }
        // Asignar el menú solo durante este clic: performClick lo muestra (bloquea hasta que
        // se cierra) y luego se quita para que el clic izquierdo vuelva a abrir el popover.
        statusItem.menu = makeContextMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}

@main
struct DisplayToggleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Toda la UI vive en el NSStatusItem; SwiftUI exige al menos una escena.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
