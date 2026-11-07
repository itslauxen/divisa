import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// De que lado da tela fica o outro computador.
enum Lado: String, CaseIterable, Identifiable {
    case esquerda, direita, acima, abaixo
    var id: String { rawValue }
    var nome: String {
        switch self {
        case .esquerda: "À esquerda"
        case .direita: "À direita"
        case .acima: "Em cima"
        case .abaixo: "Embaixo"
        }
    }
    /// Lados que andam em y (esquerda/direita) mandam "y"; os outros mandam "x".
    var vertical: Bool { self == .esquerda || self == .direita }
}

enum Estado: Equatable {
    case local, mandando, obedecendo
}

/// Liga a rede, o mouse e o teclado. Estados e mensagens seguem PROTOCOLO.md.
@MainActor
final class Coordenador: ObservableObject {
    @Published private(set) var estado = Estado.local {
        didSet {
            guard estado != oldValue else { return }
            diario("estado: %@", "\(estado)")
            if estado == .local { voltouEm = Date() }
        }
    }
    /// Logo depois de voltar para cá, a borda não passa o cursor de novo (o cursor costuma estar colado nela).
    private var voltouEm = Date.distantPast
    @Published private(set) var parceiro: String?
    @Published private(set) var acessibilidade = AXIsProcessTrusted()
    @Published var ativo: Bool { didSet { UserDefaults.standard.set(ativo, forKey: "ativo") } }
    @Published var lado: Lado { didSet { UserDefaults.standard.set(lado.rawValue, forKey: "lado") } }

    let id: String
    let nome = Host.current().localizedName ?? "Mac"

    /// Marca dos eventos que este app injeta, para não confundir com o mouse físico.
    nonisolated static let marca: Int64 = 0x0D1_715A

    private var descoberta: Descoberta?
    private let servidor = Servidor()
    private var conexao: Conexao?
    /// Desde quando ouvimos o parceiro sem estar conectados (só para quem tem o id maior).
    private var anunciosSemConexao: Date?
    private var ultimoRecebido = Date()
    private var relogio: Timer?
    private var toque: CFMachPort?

    // Mandando
    private var pino = CGPoint.zero
    private var ultimaAreaEnviada = -1

    // Obedecendo
    private var cursor = CGPoint.zero
    private var botoesApertados: Set<String> = []
    private var teclasApertadas: Set<CGKeyCode> = []
    private var flags: CGEventFlags = []
    private var ultimoClique: (botao: String, hora: Date, contagem: Int64) = ("", .distantPast, 0)

    init() {
        let ud = UserDefaults.standard
        if let salvo = ud.string(forKey: "id") { id = salvo } else {
            id = UUID().uuidString.lowercased()
            ud.set(id, forKey: "id")
        }
        ativo = ud.object(forKey: "ativo") as? Bool ?? true
        lado = Lado(rawValue: ud.string(forKey: "lado") ?? "") ?? .esquerda
    }

    func iniciar() {
        diario("iniciando %@ (id %@), acessibilidade %@", nome, id, acessibilidade ? "liberada" : "negada")
        servidor.aoConectar = { [weak self] nova in
            guard let self else { return }
            guard self.conexao == nil else { nova.cancel(); return }
            self.usar(Conexao(nova))
        }
        servidor.iniciar()

        let d = Descoberta(anuncio: ["t": "anuncio", "v": 1, "id": id, "nome": nome, "so": "mac", "porta": Int(Portas.tcp)])
        d.aoOuvir = { [weak self] msg, ip in self?.ouvir(msg, ip: ip) }
        d.iniciar()
        descoberta = d

        relogio = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.batimento() }
        }
        if acessibilidade { ligarToque() } else { pedirAcessibilidade() }
    }

    /// Conecta direto num IP, para redes que bloqueiam broadcast.
    func conectar(ip: String) {
        guard conexao == nil, !ip.isEmpty else { return }
        usar(Conexao.para(ip: ip, porta: Portas.tcp))
    }

    func pedirAcessibilidade() {
        let op = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(op)
    }

    // MARK: Rede

    private func ouvir(_ msg: Mensagem, ip: String) {
        guard msg["t"] as? String == "anuncio", let outro = msg["id"] as? String, outro != id else { return }
        guard conexao == nil else { anunciosSemConexao = nil; return }
        // Quem tem o id menor conecta na hora. O outro espera 6 s: se o firewall de lá bloquear a entrada, conecta ele.
        if id > outro {
            let desde = anunciosSemConexao ?? Date()
            anunciosSemConexao = desde
            guard Date().timeIntervalSince(desde) > 6 else { return }
            anunciosSemConexao = nil
        }
        let porta = (msg["porta"] as? Int).flatMap { UInt16(exactly: $0) } ?? Portas.tcp
        diario("achei %@ em %@", msg["nome"] as? String ?? "?", ip)
        usar(Conexao.para(ip: ip, porta: porta))
    }

    private func usar(_ c: Conexao) {
        conexao = c
        ultimoRecebido = Date()
        c.aoReceber = { [weak self] msg in self?.receber(msg) }
        c.aoFechar = { [weak self, weak c] in
            guard let self, self.conexao === c else { return }
            diario("conexão fechada")
            self.conexao = nil
            self.parceiro = nil
            self.voltarParaLocal(avisar: false)
        }
        c.iniciar { [weak self] in
            guard let self else { return }
            c.enviar(["t": "ola", "v": 1, "id": self.id, "nome": self.nome, "so": "mac"])
        }
    }

    private func enviar(_ msg: Mensagem) { conexao?.enviar(msg) }

    private func batimento() {
        let liberada = AXIsProcessTrusted()
        if liberada != acessibilidade { diario("acessibilidade: %@", liberada ? "liberada" : "negada") }
        acessibilidade = liberada
        if toque == nil && acessibilidade { ligarToque() }
        guard let conexao else { return }
        if Date().timeIntervalSince(ultimoRecebido) > 6 {
            diario("parceiro sumiu")
            conexao.fechar()
            return
        }
        enviar(["t": "ping"])
    }

    private func receber(_ msg: Mensagem) {
        ultimoRecebido = Date()
        switch msg["t"] as? String {
        case "ola":
            parceiro = msg["nome"] as? String ?? "Outro computador"
            diario("conectado a %@ (%@)", parceiro ?? "?", msg["so"] as? String ?? "?")
        case "entrar":
            guard ativo else { return enviar(["t": "liberar"]) }
            if estado == .mandando { soltarCursor(em: nil) }
            entrar(fracao: (msg["y"] ?? msg["x"]).flatMap(numero) ?? 0.5)
        case "mov":
            guard estado == .obedecendo else { return }
            mover(dx: numero(msg["dx"]) ?? 0, dy: numero(msg["dy"]) ?? 0)
        case "botao":
            guard estado == .obedecendo, let b = msg["b"] as? String else { return }
            botao(b, apertado: msg["d"] as? Bool ?? false)
        case "rolar":
            guard estado == .obedecendo else { return }
            rolar(dx: numero(msg["dx"]) ?? 0, dy: numero(msg["dy"]) ?? 0)
        case "tecla":
            guard estado == .obedecendo, let hid = msg["hid"] as? Int, let tecla = Teclas.doHID[hid] else { return }
            teclar(tecla, apertada: msg["d"] as? Bool ?? false)
        case "sair":
            guard estado == .mandando else { return }
            soltarCursor(em: (msg["y"] ?? msg["x"]).flatMap(numero))
        case "liberar":
            guard estado == .mandando else { return }
            soltarCursor(em: nil)
        case "area":
            if let texto = msg["texto"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(texto, forType: .string)
                ultimaAreaEnviada = NSPasteboard.general.changeCount // não devolver o mesmo texto
            }
        default: break
        }
    }

    private nonisolated func numero(_ valor: Any?) -> Double? { (valor as? NSNumber)?.doubleValue }

    // MARK: Telas

    /// Área de todas as telas, em coordenadas globais (origem no canto de cima à esquerda).
    private var area: CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    /// Ponto na borda do lado do parceiro, `dentro` px para dentro, na fração dada.
    private func pontoNaBorda(_ fracao: Double, dentro: CGFloat) -> CGPoint {
        let a = area
        let f = CGFloat(min(max(fracao, 0), 1))
        switch lado {
        case .esquerda: return CGPoint(x: a.minX + dentro, y: a.minY + f * (a.height - 1))
        case .direita: return CGPoint(x: a.maxX - 1 - dentro, y: a.minY + f * (a.height - 1))
        case .acima: return CGPoint(x: a.minX + f * (a.width - 1), y: a.minY + dentro)
        case .abaixo: return CGPoint(x: a.minX + f * (a.width - 1), y: a.maxY - 1 - dentro)
        }
    }

    private func fracao(de p: CGPoint) -> Double {
        let a = area
        return lado.vertical ? Double((p.y - a.minY) / max(a.height - 1, 1)) : Double((p.x - a.minX) / max(a.width - 1, 1))
    }

    /// O ponto está na borda do parceiro e o movimento empurra para fora dela.
    private func empurrandoBorda(_ p: CGPoint, dx: Double, dy: Double) -> Bool {
        let a = area
        switch lado {
        case .esquerda: return p.x <= a.minX && dx < 0
        case .direita: return p.x >= a.maxX - 1 && dx > 0
        case .acima: return p.y <= a.minY && dy < 0
        case .abaixo: return p.y >= a.maxY - 1 && dy > 0
        }
    }

    // MARK: Mandando

    private func comecarAMandar(de p: CGPoint) {
        let pb = NSPasteboard.general
        if pb.changeCount != ultimaAreaEnviada, let texto = pb.string(forType: .string) {
            enviar(["t": "area", "texto": texto])
        }
        ultimaAreaEnviada = pb.changeCount
        enviar(lado.vertical ? ["t": "entrar", "y": fracao(de: p)] : ["t": "entrar", "x": fracao(de: p)])
        estado = .mandando
        pino = p
        CGAssociateMouseAndMouseCursorPosition(0)
        Cursor.esconder()
    }

    /// Volta de Mandando para Local. Sem fração, o cursor reaparece onde estava parado.
    private func soltarCursor(em fracao: Double?) {
        estado = .local
        CGAssociateMouseAndMouseCursorPosition(1)
        CGWarpMouseCursorPosition(fracao.map { pontoNaBorda($0, dentro: 2) } ?? pino)
        Cursor.mostrar()
    }

    /// Trata um evento físico enquanto este Mac manda no outro. Sempre engole o evento.
    private func mandar(_ tipo: CGEventType, _ ev: CGEvent) {
        switch tipo {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = ev.getIntegerValueField(.mouseEventDeltaX), dy = ev.getIntegerValueField(.mouseEventDeltaY)
            if dx != 0 || dy != 0 { enviar(["t": "mov", "dx": dx, "dy": dy]) }
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let b = tipo == .leftMouseDown || tipo == .leftMouseUp ? "esq" : tipo == .rightMouseDown || tipo == .rightMouseUp ? "dir" : "meio"
            enviar(["t": "botao", "b": b, "d": tipo == .leftMouseDown || tipo == .rightMouseDown || tipo == .otherMouseDown])
        case .scrollWheel:
            let dy = ev.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            let dx = -ev.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            if dx != 0 || dy != 0 { enviar(["t": "rolar", "dx": dx, "dy": dy]) }
        case .keyDown, .keyUp:
            let k = CGKeyCode(ev.getIntegerValueField(.keyboardEventKeycode))
            if let hid = Teclas.paraHID[k] { enviar(["t": "tecla", "hid": hid, "d": tipo == .keyDown]) }
        case .flagsChanged:
            let k = CGKeyCode(ev.getIntegerValueField(.keyboardEventKeycode))
            guard let hid = Teclas.paraHID[k] else { return }
            if let mascara = Teclas.mascaraDoModificador[k] {
                enviar(["t": "tecla", "hid": hid, "d": ev.flags.rawValue & mascara != 0])
            } else {
                // Caps Lock e afins: cada mudança vale um toque.
                enviar(["t": "tecla", "hid": hid, "d": true])
                enviar(["t": "tecla", "hid": hid, "d": false])
            }
        default: break
        }
    }

    // MARK: Obedecendo

    private func entrar(fracao: Double) {
        estado = .obedecendo
        cursor = pontoNaBorda(fracao, dentro: 1)
        CGWarpMouseCursorPosition(cursor)
        Cursor.mostrar()
        postar(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cursor, mouseButton: .left))
    }

    private func mover(dx: Double, dy: Double) {
        if empurrandoBorda(cursor, dx: dx, dy: dy) && botoesApertados.isEmpty {
            let f = fracao(de: cursor)
            soltarTudo()
            estado = .local
            enviar(lado.vertical ? ["t": "sair", "y": f] : ["t": "sair", "x": f])
            return
        }
        let a = area
        cursor = CGPoint(x: min(max(cursor.x + dx, a.minX), a.maxX - 1), y: min(max(cursor.y + dy, a.minY), a.maxY - 1))
        let tipo: CGEventType, botao: CGMouseButton
        if botoesApertados.contains("esq") { (tipo, botao) = (.leftMouseDragged, .left) }
        else if botoesApertados.contains("dir") { (tipo, botao) = (.rightMouseDragged, .right) }
        else if botoesApertados.contains("meio") { (tipo, botao) = (.otherMouseDragged, .center) }
        else { (tipo, botao) = (.mouseMoved, .left) }
        let ev = CGEvent(mouseEventSource: nil, mouseType: tipo, mouseCursorPosition: cursor, mouseButton: botao)
        ev?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        ev?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        postar(ev)
    }

    private func botao(_ b: String, apertado: Bool) {
        let (desce, sobe, botao): (CGEventType, CGEventType, CGMouseButton) = switch b {
        case "dir": (.rightMouseDown, .rightMouseUp, .right)
        case "meio": (.otherMouseDown, .otherMouseUp, .center)
        default: (.leftMouseDown, .leftMouseUp, .left)
        }
        if apertado {
            botoesApertados.insert(b)
            let agora = Date()
            let seguido = ultimoClique.botao == b && agora.timeIntervalSince(ultimoClique.hora) < 0.4
            ultimoClique = (b, agora, seguido ? ultimoClique.contagem + 1 : 1)
        } else {
            botoesApertados.remove(b)
        }
        let ev = CGEvent(mouseEventSource: nil, mouseType: apertado ? desce : sobe, mouseCursorPosition: cursor, mouseButton: botao)
        ev?.setIntegerValueField(.mouseEventClickState, value: ultimoClique.contagem)
        ev?.flags = flags
        postar(ev)
    }

    private func rolar(dx: Double, dy: Double) {
        // Um dente da roda ≈ 40 px, perto do que o macOS rola com a roda de um mouse comum.
        let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                         wheel1: Int32((dy * 40).rounded()), wheel2: Int32((dx * 40).rounded()), wheel3: 0)
        postar(ev)
    }

    private func teclar(_ tecla: CGKeyCode, apertada: Bool) {
        if let f = Teclas.flagDoModificador[tecla] {
            if apertada { flags.insert(f) } else { flags.remove(f) }
        }
        if apertada { teclasApertadas.insert(tecla) } else { teclasApertadas.remove(tecla) }
        let ev = CGEvent(keyboardEventSource: nil, virtualKey: tecla, keyDown: apertada)
        ev?.flags = flags
        postar(ev)
    }

    /// Solta tudo o que ficou apertado do lado de cá.
    private func soltarTudo() {
        for b in botoesApertados { botao(b, apertado: false) }
        for t in teclasApertadas { teclar(t, apertada: false) }
        flags = []
    }

    private func postar(_ ev: CGEvent?) {
        ev?.setIntegerValueField(.eventSourceUserData, value: Self.marca)
        ev?.post(tap: .cghidEventTap)
    }

    /// Sai de qualquer estado de volta para Local.
    private func voltarParaLocal(avisar: Bool) {
        switch estado {
        case .mandando: soltarCursor(em: nil)
        case .obedecendo: soltarTudo(); estado = .local
        case .local: break
        }
        if avisar { enviar(["t": "liberar"]) }
    }

    // MARK: Toque nos eventos

    private func ligarToque() {
        guard toque == nil else { return }
        let tipos: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
                                    .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mascara = tipos.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let eu = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mascara, callback: { _, tipo, ev, eu in
            // Roda numa linha própria. Os eventos que nós mesmos injetamos passam direto, sem esperar
            // a fila principal (que está ocupada com a rede): senão o cursor controlado de longe engasga.
            if ev.getIntegerValueField(.eventSourceUserData) == Coordenador.marca { return Unmanaged.passUnretained(ev) }
            let c = Unmanaged<Coordenador>.fromOpaque(eu!).takeUnretainedValue()
            var segue = true
            DispatchQueue.main.sync { segue = MainActor.assumeIsolated { c.tratar(tipo, ev) } }
            return segue ? Unmanaged.passUnretained(ev) : nil
        }, userInfo: eu) else {
            diario("sem permissão de Acessibilidade para ler o mouse")
            return
        }
        let fonte = CFMachPortCreateRunLoopSource(nil, t, 0)
        let linha = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), fonte, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        linha.name = "divisa.toque"
        linha.qualityOfService = .userInteractive
        linha.start()
        toque = t
        diario("lendo mouse e teclado")
    }

    /// Devolve false para engolir o evento.
    private func tratar(_ tipo: CGEventType, _ ev: CGEvent) -> Bool {
        if tipo == .tapDisabledByTimeout || tipo == .tapDisabledByUserInput {
            if let toque { CGEvent.tapEnable(tap: toque, enable: true) }
            return true
        }
        if ev.getIntegerValueField(.eventSourceUserData) == Self.marca { return true } // nosso

        // Ctrl+Option+Shift+Esc: volta para cá na hora.
        if tipo == .keyDown, CGKeyCode(ev.getIntegerValueField(.keyboardEventKeycode)) == Teclas.esc,
           ev.flags.isSuperset(of: [.maskControl, .maskAlternate, .maskShift]), estado != .local {
            voltarParaLocal(avisar: true)
            return false
        }

        switch estado {
        case .mandando:
            mandar(tipo, ev)
            return false
        case .obedecendo:
            // Mouse ou teclado físico daqui: toma o controle de volta.
            diario("mexeram aqui; tomando o controle de volta")
            voltarParaLocal(avisar: true)
            return true
        case .local:
            guard tipo == .mouseMoved, ativo, conexao != nil, parceiro != nil,
                  Date().timeIntervalSince(voltouEm) > 0.5 else { return true }
            let dx = Double(ev.getIntegerValueField(.mouseEventDeltaX)), dy = Double(ev.getIntegerValueField(.mouseEventDeltaY))
            let p = ev.location
            if empurrandoBorda(p, dx: dx, dy: dy) {
                comecarAMandar(de: p)
                return false
            }
            return true
        }
    }
}

/// Esconde o cursor mesmo com o app em segundo plano (propriedade privada do WindowServer, a mesma que
/// apps como o Synergy usam). Sem ela, o cursor fica visível parado na borda, o que não quebra nada.
enum Cursor {
    private typealias Padrao = @convention(c) () -> Int32
    private typealias Propriedade = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private static var escondido = false

    private static let liberarNoFundo: Void = {
        guard let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
              let p = dlsym(h, "_CGSDefaultConnection"), let s = dlsym(h, "CGSSetConnectionProperty") else { return }
        let conexao = unsafeBitCast(p, to: Padrao.self)()
        _ = unsafeBitCast(s, to: Propriedade.self)(conexao, conexao, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }()

    static func esconder() {
        guard !escondido else { return }
        _ = liberarNoFundo
        CGDisplayHideCursor(CGMainDisplayID())
        escondido = true
    }

    static func mostrar() {
        guard escondido else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        escondido = false
    }
}
