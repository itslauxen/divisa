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
    @Published var qualidade = Qualidade.atual {
        didSet {
            UserDefaults.standard.set(qualidade.rawValue, forKey: "tabletQualidade")
            if captura != nil { comecarCaptura() } // vale na hora, sem reconectar o tablet
        }
    }

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
        relogio?.invalidate(); relogio = nil
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
        esperandoDesde = nil
        ultimaPosicao = ""
        ultimaForma = nil
        acompanharCursor()
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
                diario("tablet: conectou (%@)", c.endpoint.debugDescription)
            case .failed, .cancelled:
                guard self.cliente === c else { return }
                self.cliente = nil
                self.conectado = false
                self.relogio?.invalidate()
                self.relogio = nil
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
        case "ok":
            // O tablet desenhou o quadro: libera o próximo.
            if let desde = esperandoDesde { atrasos.append(Date().timeIntervalSince(desde)) }
            esperandoDesde = nil
            captura?.liberar()
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
            // 30 Hz: a captura manda no máximo 30 quadros por segundo, e desenhar a 60 só gastaria o WindowServer do Mac.
            ajustes.modes = [CGVirtualDisplayMode(width: UInt32(w / 2), height: UInt32(h / 2), refreshRate: 30)]
            guard nova.apply(ajustes) else {
                diario("tablet: não deu para criar a tela virtual")
                return
            }
            tela = nova
            tamanhoDaTela = (w, h)
            diario("tablet: tela virtual %d×%d px (id %d)", w, h, nova.displayID)
            comecarCaptura()
        } else if captura == nil {
            // Mesma tela de antes (ex.: o tablet reconectou): só volta a capturar.
            comecarCaptura()
        }
    }

    private func fecharTela() {
        captura?.parar()
        captura = nil
        if tela != nil { diario("tablet: tela virtual removida") }
        tela = nil
        tamanhoDaTela = (0, 0)
    }

    /// Muda a cada captura nova: uma captura que termina de iniciar depois de outra ter sido pedida se desliga sozinha.
    private var geracao = 0

    private func comecarCaptura() {
        guard let tela, cliente != nil else { return }
        captura?.parar()
        geracao += 1
        let minha = geracao
        let id = tela.displayID, (w, h) = tamanhoDaTela
        let nova = Captura(displayID: id, largura: w, altura: h) { [weak self] jpeg in
            MainActor.assumeIsolated {
                guard let self, self.geracao == minha else { return }
                self.enviarQuadro(jpeg)
            }
        }
        captura = nova
        Task {
            // A tela recém-criada demora um instante para aparecer na lista do ScreenCaptureKit.
            for _ in 0..<10 {
                guard geracao == minha else { return }
                switch await nova.iniciar() {
                case .ok:
                    semPermissaoDeTela = false
                    if geracao != minha { nova.parar() } // outra captura foi pedida enquanto esta iniciava
                    return
                case .semPermissao: semPermissaoDeTela = true; return
                case .telaNaoEncontrada: try? await Task.sleep(for: .milliseconds(300))
                }
            }
            diario("tablet: a tela virtual não apareceu para a captura")
        }
    }

    /// Quando foi o quadro que o tablet ainda não confirmou ("ok" depois de desenhar).
    private var esperandoDesde: Date?
    // Estatística para o log (a cada 5 s).
    private var atrasos: [TimeInterval] = []
    private var bytesEnviados = 0, quadrosEnviados = 0
    private var ultimaEstatistica = Date()

    /// A captura só entrega um quadro depois do "ok" do anterior: sem fila na rede, sem atraso acumulado.
    private func enviarQuadro(_ quadro: Data) {
        guard let cliente else { return }
        esperandoDesde = Date()
        bytesEnviados += quadro.count
        quadrosEnviados += 1
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "quadro", metadata: [meta])
        cliente.send(content: quadro, contentContext: ctx, isComplete: true, completion: .idempotent)
        registrarEstatistica()
    }

    private func enviarTexto(_ msg: [String: Any]) {
        guard let cliente, let dados = try? JSONSerialization.data(withJSONObject: msg) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "texto", metadata: [meta])
        cliente.send(content: dados, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    // MARK: Cursor

    // O cursor não vai na imagem: o Mac manda só a posição (60 vezes por segundo) e o tablet desenha a seta por cima.
    // Assim ele anda com o atraso da rede, e não com o da captura + JPEG + quadro inteiro.
    private var relogio: Timer?
    private var ultimaPosicao = ""
    private var ultimaForma: Data?
    private var tique = 0

    private func acompanharCursor() {
        relogio?.invalidate()
        relogio = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tiqueDoCursor() }
        }
    }

    private func tiqueDoCursor() {
        guard cliente != nil, let tela else { return }
        tique += 1
        // Página antiga (sem "ok") ou confirmação perdida: não trava a imagem para sempre.
        if let desde = esperandoDesde, Date().timeIntervalSince(desde) > 2 {
            esperandoDesde = nil
            captura?.liberar(tudo: true)
        }
        let b = CGDisplayBounds(tela.displayID)
        let p = CGEvent(source: nil)?.location ?? .zero
        // Escondido = o cursor está no Windows (a Divisa está mandando lá).
        let dentro = b.contains(p) && !Cursor.escondido
        if dentro, tique % 6 == 0 || ultimaForma == nil { mandarForma(b) }
        let posicao = dentro ? String(format: "%.4f %.4f", (p.x - b.minX) / b.width, (p.y - b.minY) / b.height) : ""
        guard posicao != ultimaPosicao else { return }
        ultimaPosicao = posicao
        enviarTexto(dentro ? ["t": "cursor", "x": (p.x - b.minX) / b.width, "y": (p.y - b.minY) / b.height] : ["t": "cursor"])
    }

    /// Imagem do cursor atual (seta, mãozinha, I...), só quando muda. Tamanho em fração da tela, ponto quente em fração do cursor.
    private func mandarForma(_ b: CGRect) {
        guard let cursor = NSCursor.currentSystem, let tiff = cursor.image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]), png != ultimaForma else { return }
        ultimaForma = png
        let t = cursor.image.size
        enviarTexto(["t": "forma", "png": png.base64EncodedString(), "w": t.width / b.width, "h": t.height / b.height,
                     "hx": cursor.hotSpot.x / max(t.width, 1), "hy": cursor.hotSpot.y / max(t.height, 1)])
    }

    private func registrarEstatistica() {
        let t = Date().timeIntervalSince(ultimaEstatistica)
        guard t >= 5 else { return }
        let medio = atrasos.isEmpty ? 0 : atrasos.reduce(0, +) / Double(atrasos.count)
        diario("tablet: %.0f q/s, %d KB/quadro, %.1f Mb/s, atraso até desenhar %.0f ms (máx %.0f)",
               Double(quadrosEnviados) / t, bytesEnviados / max(quadrosEnviados, 1) / 1024,
               Double(bytesEnviados) * 8 / t / 1_000_000, medio * 1000, (atrasos.max() ?? 0) * 1000)
        atrasos = []; bytesEnviados = 0; quadrosEnviados = 0
        ultimaEstatistica = Date()
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
            diario("tablet: toque em %.0f,%.0f", p.x, p.y)
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

/// Quanto da resolução do tablet vai na imagem. Menos = mais fluido, mais suave o texto.
enum Qualidade: String, CaseIterable, Identifiable {
    case fluida, equilibrada, nitida
    var id: String { rawValue }
    var nome: String {
        switch self {
        case .fluida: "Fluida"
        case .equilibrada: "Equilibrada"
        case .nitida: "Nítida"
        }
    }
    var escala: Double {
        switch self {
        case .fluida: 0.5
        case .equilibrada: 0.7
        case .nitida: 1
        }
    }
    var jpeg: Double {
        switch self {
        case .fluida: 0.6
        case .equilibrada: 0.65
        case .nitida: 0.7
        }
    }
    static var atual: Qualidade { Qualidade(rawValue: UserDefaults.standard.string(forKey: "tabletQualidade") ?? "") ?? .equilibrada }
}

/// Captura uma tela com o ScreenCaptureKit e entrega, em JPEG, só o pedaço que mudou desde o último quadro entregue.
/// Cada quadro vai com um cabeçalho de 8 bytes (UInt16 big-endian): largura e altura da imagem inteira, x e y do pedaço.
final class Captura: NSObject, SCStreamOutput, @unchecked Sendable {
    enum Resultado { case ok, semPermissao, telaNaoEncontrada }

    private let displayID: CGDirectDisplayID
    private let largura: Int, altura: Int
    private let aoQuadro: (Data) -> Void
    private var stream: SCStream?
    private let fila = DispatchQueue(label: "divisa.captura")
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private let qualidadeJPEG = Qualidade.atual.jpeg

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
        // Imagem menor que a tela, para o tablet dar conta: ele amplia de volta ao desenhar.
        let q = Qualidade.atual
        config.width = max(Int(Double(largura) * q.escala) & ~1, 2)
        config.height = max(Int(Double(altura) * q.escala) & ~1, 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false // o tablet desenha o cursor por cima (ver Tablet.tiqueDoCursor)
        config.queueDepth = 3
        config.scalesToFit = true // imagem menor que a tela: reduz a tela inteira, sem cortar
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

    // Só na fila da captura: o quadro mais novo, a soma do que mudou desde o último entregue e se o tablet já pediu o próximo.
    private var ultimo: CVPixelBuffer?
    private var sujo = CGRect.infinite // o primeiro quadro vai inteiro
    private var livre = true

    /// O tablet desenhou o quadro anterior. `tudo` reenvia a imagem inteira (confirmação perdida).
    func liberar(tudo: Bool = false) {
        fila.async { [self] in
            livre = true
            if tudo { sujo = .infinite }
            entregar()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer amostra: CMSampleBuffer, of tipo: SCStreamOutputType) {
        // Só quadros com imagem nova; os "parados" não mudam nada na tela do tablet.
        guard tipo == .screen,
              let anexos = CMSampleBufferGetSampleAttachmentsArray(amostra, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let bruto = anexos.first?[.status] as? Int, SCFrameStatus(rawValue: bruto) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(amostra) else { return }
        let rects = (anexos.first?[.dirtyRects] as? [NSDictionary])?.compactMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        // Os retângulos vêm em pixels da imagem capturada (já reduzida pela qualidade).
        sujo = rects.map { $0.reduce(sujo) { $0.union($1) } } ?? .infinite
        ultimo = pixels
        entregar()
    }

    private func entregar() {
        guard livre, let pixels = ultimo, !sujo.isNull else { return }
        let W = CVPixelBufferGetWidth(pixels), H = CVPixelBufferGetHeight(pixels)
        let r = sujo.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard !r.isNull, !r.isEmpty else { sujo = .null; return }
        // Em blocos de 16 px, os do JPEG: as bordas do pedaço encaixam sem manchar.
        let x = Int(r.minX) / 16 * 16, y = Int(r.minY) / 16 * 16
        let w = min((Int(r.maxX.rounded(.up)) + 15) / 16 * 16, W) - x, h = min((Int(r.maxY.rounded(.up)) + 15) / 16 * 16, H) - y
        // CoreImage conta y de baixo para cima.
        let pedaco = CIImage(cvPixelBuffer: pixels)
            .cropped(to: CGRect(x: x, y: H - y - h, width: w, height: h))
            .transformed(by: CGAffineTransform(translationX: CGFloat(-x), y: CGFloat(-(H - y - h))))
        guard let jpeg = ci.jpegRepresentation(of: pedaco, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                               options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: qualidadeJPEG]) else { return }
        ultimo = nil
        sujo = .null
        livre = false
        var quadro = Data(capacity: jpeg.count + 8)
        for v in [W, H, x, y] { withUnsafeBytes(of: UInt16(v).bigEndian) { quadro.append(contentsOf: $0) } }
        quadro.append(jpeg)
        DispatchQueue.main.async { self.aoQuadro(quadro) }
    }
}
