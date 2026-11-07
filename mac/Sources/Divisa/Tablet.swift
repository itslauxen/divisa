import AppKit
import CGVirtual
import CoreImage
import Network
import ScreenCaptureKit

/// Monitor virtual no tablet: cria uma tela no Mac do tamanho da do tablet, manda a imagem dela para uma
/// página no navegador (JPEG por WebSocket) e transforma os toques em mouse.
/// A página fica em http://<ip do Mac>:24802 e o vídeo/toques em ws://<ip>:24803.
@MainActor
final class Tablet: NSObject, ObservableObject {
    static let portaPagina: UInt16 = 24802
    static let portaVideo: UInt16 = 24803

    @Published var ligado: Bool { didSet { UserDefaults.standard.set(ligado, forKey: "tablet"); ligado ? iniciar() : parar() } }
    @Published private(set) var conectado = false
    @Published private(set) var semPermissaoDeTela = false
    @Published private(set) var endereco = ""

    private var pagina: NWListener?
    private var video: NWListener?
    private var cliente: NWConnection?
    private var tela: CGVirtualDisplay?
    private var tamanhoDaTela = (largura: 0, altura: 0)
    private var captura: Captura?
    private var desligarTela: Task<Void, Never>?
    private var botaoApertado = false

    override init() {
        ligado = UserDefaults.standard.bool(forKey: "tablet")
        super.init()
    }

    func comecar() {
        endereco = "http://\(Self.ipLocal() ?? "seu-mac.local"):\(Self.portaPagina)"
        if ligado {
            // Pede a Gravação de Tela já na abertura, e não só quando o tablet conecta.
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            iniciar()
        }
    }

    private func iniciar() {
        guard pagina == nil else { return }
        endereco = "http://\(Self.ipLocal() ?? "seu-mac.local"):\(Self.portaPagina)"
        pagina = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.portaPagina)!)
        pagina?.newConnectionHandler = { [weak self] c in MainActor.assumeIsolated { self?.servirPagina(c) } }
        pagina?.start(queue: .main)

        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        video = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.portaVideo)!)
        video?.newConnectionHandler = { [weak self] c in MainActor.assumeIsolated { self?.aceitar(c) } }
        video?.start(queue: .main)
        diario("tablet: esperando em %@", endereco)
    }

    private func parar() {
        pagina?.cancel(); pagina = nil
        video?.cancel(); video = nil
        cliente?.cancel(); cliente = nil
        conectado = false
        fecharTela()
    }

    // MARK: Página

    private func servirPagina(_ c: NWConnection) {
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, _ in
            let html = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")
                .flatMap { try? Data(contentsOf: $0) } ?? Data("<h1>Página do tablet não encontrada no app</h1>".utf8)
            var resposta = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
            resposta.append(html)
            c.send(content: resposta, completion: .contentProcessed { _ in c.cancel() })
        }
    }

    // MARK: Conexão do tablet

    private func aceitar(_ c: NWConnection) {
        // Um tablet por vez: o novo substitui o anterior.
        cliente?.cancel()
        cliente = c
        c.stateUpdateHandler = { [weak self, weak c] estado in
            MainActor.assumeIsolated { self?.mudou(c, estado) }
        }
        c.start(queue: .main)
        ler(c)
    }

    private func mudou(_ c: NWConnection?, _ estado: NWConnection.State) {
            guard let c else { return }
            switch estado {
            case .ready:
                self.conectado = true
                diario("tablet: conectou")
            case .failed, .cancelled:
                guard self.cliente === c else { return }
                self.cliente = nil
                self.conectado = false
                diario("tablet: desconectou")
                self.captura?.parar()
                self.captura = nil
                // Espera um pouco antes de tirar a tela: recarregar a página não deve bagunçar as janelas.
                self.desligarTela?.cancel()
                self.desligarTela = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    self?.fecharTela()
                }
            default: break
            }
    }

    private func ler(_ c: NWConnection) {
        c.receiveMessage { [weak self, weak c] dados, _, _, erro in
            guard let self, let c else { return }
            MainActor.assumeIsolated {
                if let dados, let msg = try? JSONSerialization.jsonObject(with: dados) as? [String: Any] { self.receber(msg) }
                if erro == nil { self.ler(c) }
            }
        }
    }

    private func receber(_ msg: [String: Any]) {
        let n = { (k: String) in (msg[k] as? NSNumber)?.doubleValue ?? 0 }
        switch msg["t"] as? String {
        case "tela":
            abrirTela(largura: Int(n("w")), altura: Int(n("h")))
        case "toque":
            toque(fase: msg["fase"] as? String ?? "", x: n("x"), y: n("y"))
        case "direito":
            clique(.right, x: n("x"), y: n("y"))
        case "rolar":
            let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                             wheel1: Int32(n("dy").rounded()), wheel2: Int32(n("dx").rounded()), wheel3: 0)
            postar(ev)
        default: break
        }
    }

    // MARK: Tela virtual

    /// Cria (ou reaproveita) a tela virtual com o tamanho em pixels do tablet, em HiDPI (pontos = pixels / 2).
    private func abrirTela(largura: Int, altura: Int) {
        desligarTela?.cancel()
        guard largura >= 400, altura >= 300 else { return }
        // Pixels pares e no máximo 4K, para o modo HiDPI fechar certinho.
        let w = min(largura, 3840) & ~1, h = min(altura, 2400) & ~1
        if tela == nil || tamanhoDaTela != (w, h) {
            fecharTela()
            let d = CGVirtualDisplayDescriptor()
            d.queue = .main
            d.name = "Tablet (Divisa)"
            d.maxPixelsWide = UInt32(w)
            d.maxPixelsHigh = UInt32(h)
            // ~10" na diagonal, para o macOS escolher um tamanho de interface razoável.
            let diagonalPx = (Double(w * w + h * h)).squareRoot()
            d.sizeInMillimeters = CGSize(width: 254 * Double(w) / diagonalPx, height: 254 * Double(h) / diagonalPx)
            d.productID = 0xD1F1
            d.vendorID = 0x1A2B
            d.serialNum = 1
            let nova = CGVirtualDisplay(descriptor: d)
            let ajustes = CGVirtualDisplaySettings()
            ajustes.hiDPI = 1
            ajustes.modes = [CGVirtualDisplayMode(width: UInt32(w / 2), height: UInt32(h / 2), refreshRate: 60)]
            guard nova.apply(ajustes) else {
                diario("tablet: não deu para criar a tela virtual")
                return
            }
            tela = nova
            tamanhoDaTela = (w, h)
            diario("tablet: tela virtual %d×%d px (id %d)", w, h, nova.displayID)
        }
        comecarCaptura()
    }

    private func fecharTela() {
        captura?.parar()
        captura = nil
        if tela != nil { diario("tablet: tela virtual removida") }
        tela = nil
        tamanhoDaTela = (0, 0)
    }

    private func comecarCaptura() {
        guard let tela, cliente != nil else { return }
        captura?.parar()
        let id = tela.displayID, (w, h) = tamanhoDaTela
        let nova = Captura(displayID: id, largura: w, altura: h) { [weak self] jpeg in
            MainActor.assumeIsolated { self?.enviarQuadro(jpeg) }
        }
        captura = nova
        Task {
            // A tela recém-criada demora um instante para aparecer na lista do ScreenCaptureKit.
            for _ in 0..<10 {
                switch await nova.iniciar() {
                case .ok: semPermissaoDeTela = false; return
                case .semPermissao: semPermissaoDeTela = true; return
                case .telaNaoEncontrada: try? await Task.sleep(for: .milliseconds(300))
                }
            }
            diario("tablet: a tela virtual não apareceu para a captura")
        }
    }

    private var quadrosNoCaminho = 0

    private func enviarQuadro(_ jpeg: Data) {
        // Se a rede não está dando conta, pula quadros em vez de acumular atraso.
        guard let cliente, quadrosNoCaminho < 2 else { return }
        quadrosNoCaminho += 1
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "quadro", metadata: [meta])
        cliente.send(content: jpeg, contentContext: ctx, isComplete: true, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.quadrosNoCaminho -= 1 }
        })
    }

    // MARK: Toque → mouse

    private func ponto(_ x: Double, _ y: Double) -> CGPoint? {
        guard let tela else { return nil }
        let b = CGDisplayBounds(tela.displayID)
        return CGPoint(x: b.minX + min(max(x, 0), 1) * (b.width - 1), y: b.minY + min(max(y, 0), 1) * (b.height - 1))
    }

    private func toque(fase: String, x: Double, y: Double) {
        guard let p = ponto(x, y) else { return }
        switch fase {
        case "inicio":
            botaoApertado = true
            postar(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
            postar(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
        case "move":
            postar(CGEvent(mouseEventSource: nil, mouseType: botaoApertado ? .leftMouseDragged : .mouseMoved,
                           mouseCursorPosition: p, mouseButton: .left))
        default:
            botaoApertado = false
            postar(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
        }
    }

    private func clique(_ botao: CGMouseButton, x: Double, y: Double) {
        guard let p = ponto(x, y) else { return }
        postar(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: p, mouseButton: botao))
        postar(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: p, mouseButton: botao))
    }

    private func postar(_ ev: CGEvent?) {
        // Mesma marca do compartilhamento de mouse: toque no tablet não é "mouse físico do Mac".
        ev?.setIntegerValueField(.eventSourceUserData, value: Coordenador.marca)
        ev?.post(tap: .cghidEventTap)
    }

    // MARK: Rede local

    /// IPv4 da rede local (Wi-Fi ou cabo), para mostrar o endereço da página.
    static func ipLocal() -> String? {
        var lista: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&lista) == 0, let primeiro = lista else { return nil }
        defer { freeifaddrs(lista) }
        var achado: String?
        for p in sequence(first: primeiro, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let end = i.ifa_addr, end.pointee.sa_family == UInt8(AF_INET),
                  i.ifa_flags & UInt32(IFF_LOOPBACK) == 0, i.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let nome = String(cString: i.ifa_name)
            guard nome.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(end, socklen_t(end.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            achado = String(cString: host)
            if nome == "en0" { break }
        }
        return achado
    }
}

/// Captura uma tela com o ScreenCaptureKit e entrega cada quadro novo em JPEG.
final class Captura: NSObject, SCStreamOutput, @unchecked Sendable {
    enum Resultado { case ok, semPermissao, telaNaoEncontrada }

    private let displayID: CGDirectDisplayID
    private let largura: Int, altura: Int
    private let aoQuadro: (Data) -> Void
    private var stream: SCStream?
    private let fila = DispatchQueue(label: "divisa.captura")
    private let ci = CIContext(options: [.useSoftwareRenderer: false])

    init(displayID: CGDirectDisplayID, largura: Int, altura: Int, aoQuadro: @escaping (Data) -> Void) {
        self.displayID = displayID
        self.largura = largura
        self.altura = altura
        self.aoQuadro = aoQuadro
    }

    func iniciar() async -> Resultado {
        let conteudo: SCShareableContent
        do { conteudo = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) } catch {
            diario("tablet: sem permissão de Gravação de Tela (%@)", error.localizedDescription)
            return .semPermissao
        }
        guard let display = conteudo.displays.first(where: { $0.displayID == displayID }) else { return .telaNaoEncontrada }
        let filtro = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = largura
        config.height = altura
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 3
        let s = SCStream(filter: filtro, configuration: config, delegate: nil)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: fila)
            try await s.startCapture()
        } catch {
            diario("tablet: captura falhou (%@)", error.localizedDescription)
            return .semPermissao
        }
        stream = s
        diario("tablet: capturando %d×%d", largura, altura)
        return .ok
    }

    func parar() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer amostra: CMSampleBuffer, of tipo: SCStreamOutputType) {
        // Só quadros com imagem nova; os "parados" não mudam nada na tela do tablet.
        guard tipo == .screen,
              let anexos = CMSampleBufferGetSampleAttachmentsArray(amostra, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let bruto = anexos.first?[.status] as? Int, SCFrameStatus(rawValue: bruto) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(amostra) else { return }
        let imagem = CIImage(cvPixelBuffer: pixels)
        guard let jpeg = ci.jpegRepresentation(of: imagem, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                               options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]) else { return }
        DispatchQueue.main.async { self.aoQuadro(jpeg) }
    }
}
