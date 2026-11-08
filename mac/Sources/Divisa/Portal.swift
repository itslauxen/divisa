import AppKit

/// Ondulação de "portal" na borda por onde o cursor passa: a borda se estica como uma membrana elástica
/// (uma curva em forma de sino, comprida ao longo da borda) e volta, uma vez só. Saindo, a ondulação se
/// recolhe para o ponto; chegando, ela se espalha. Mesmos valores do Windows (windows/Divisa/Portal.cs).
@MainActor
enum Portal {
    static var ligado: Bool {
        get { UserDefaults.standard.object(forKey: "portal") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "portal") }
    }

    private static var atual: NSPanel?

    /// Saindo deste computador pela `borda` (o lado onde o outro fica).
    static func saida(em ponto: CGPoint, borda: Lado) { mostrar(ponto, borda, entrando: false) }

    /// Chegando neste computador pela `borda`.
    static func entrada(em ponto: CGPoint, borda: Lado) { mostrar(ponto, borda, entrando: true) }

    /// `ponto` em coordenadas globais do CoreGraphics (origem no canto de cima à esquerda).
    private static func mostrar(_ ponto: CGPoint, _ borda: Lado, entrando: Bool) {
        guard ligado else { return }
        atual?.orderOut(nil)
        let tela = Onda.telaDoPonto(ponto)
        let onda = Onda(borda: borda, entrando: entrando, larguraDaTela: tela.width)

        // A janela encosta na borda da área total das telas, centrada no ponto (como no Windows).
        let a = Onda.areaDasTelas
        let c = onda.comprimento, f = onda.fundo
        let r: CGRect = switch borda {
        case .direita: CGRect(x: a.maxX - f, y: ponto.y - c / 2, width: f, height: c)
        case .esquerda: CGRect(x: a.minX, y: ponto.y - c / 2, width: f, height: c)
        case .acima: CGRect(x: ponto.x - c / 2, y: a.minY, width: c, height: f)
        case .abaixo: CGRect(x: ponto.x - c / 2, y: a.maxY - f, width: c, height: f)
        }
        // O AppKit conta y de baixo para cima, a partir da tela principal.
        let alturaPrincipal = CGDisplayBounds(CGMainDisplayID()).height
        let quadro = NSRect(x: r.minX, y: alturaPrincipal - r.maxY, width: r.width, height: r.height)

        let janela = NSPanel(contentRect: quadro, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        janela.level = .screenSaver
        janela.isOpaque = false
        janela.backgroundColor = .clear
        janela.hasShadow = false
        janela.ignoresMouseEvents = true
        janela.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        onda.frame = NSRect(origin: .zero, size: quadro.size)
        janela.contentView = onda
        janela.orderFrontRegardless()
        atual = janela
        onda.comecar { if atual === janela { atual = nil }; janela.orderOut(nil) }
    }
}

/// Desenha a onda quadro a quadro. Coordenadas: `s` ao longo da borda a partir do ponto, `d` para dentro da tela.
private final class Onda: NSView {
    private static let largura: CGFloat = 70      // desvio da curva de sino ao longo da borda
    private static let profundidade: CGFloat = 22 // quanto a borda "afunda" para dentro, no máximo
    private static let duracao: Double = 0.52
    private static let cor = NSColor(red: 56 / 255, green: 166 / 255, blue: 207 / 255, alpha: 1)
    private static let brilho = NSColor(red: 98 / 255, green: 197 / 255, blue: 238 / 255, alpha: 1)

    static var areaDasTelas: CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    // Campo de força (hexágonos), em unidades do efeito × k. Mesmos valores do Windows.
    private static let ladoHex: CGFloat = 11
    private static let raioHex: CGFloat = 120
    private static let larguraFrente: CGFloat = 14

    let borda: Lado
    let entrando: Bool
    let comprimento: CGFloat
    let fundo: CGFloat
    /// "pixels" (o padrão), "campo" (hexágonos) ou "elastica" (a onda de antes).
    private let efeito: String
    private var hexagonos: Bool { efeito == "campo" }
    private let k: CGFloat
    private let duracao: Double
    private let corHex: NSColor
    private var inicio = Date()
    private var relogio: Timer?

    init(borda: Lado, entrando: Bool, larguraDaTela: CGFloat) {
        self.borda = borda
        self.entrando = entrando
        let ud = UserDefaults.standard
        efeito = ud.string(forKey: "portalEfeito") ?? "elastica"
        let tamanho = ud.object(forKey: "portalTamanho") as? Double ?? 0.55
        let velocidade = ud.object(forKey: "portalVelocidade") as? Double ?? 1.8
        corHex = NSColor(hex: ud.string(forKey: "portalCor") ?? "#38A6CF") ?? Self.cor
        if efeito == "pixels" {
            // Mínimo para cada quadradinho ter pelo menos 2 pt.
            k = max(CGFloat(tamanho) * larguraDaTela / 760, 2.0 / 7)
            let alcance = (7 + 2) * 1.3 * 7 * k
            comprimento = (2 * alcance).rounded(.up)
            fundo = alcance.rounded(.up)
            duracao = 0.72 / velocidade
        } else if efeito == "campo" {
            // Ocupa a mesma parte da tela que na página de efeitos (feita para 760 pt de largura).
            k = CGFloat(tamanho) * larguraDaTela / 760
            let alcance = (Self.raioHex + 2 * Self.ladoHex) * k
            comprimento = (2 * alcance).rounded(.up)
            fundo = alcance.rounded(.up)
            duracao = 0.68 / velocidade
        } else {
            // Elástica, na mesma escala da página de efeitos e dos outros efeitos.
            k = CGFloat(tamanho) * larguraDaTela / 760
            comprimento = (2 * 2.8 * Self.largura * k * 1.2).rounded(.up)
            fundo = (Self.profundidade * k * 1.2 + 14 * k).rounded(.up) // folga para a sobra elástica e o brilho
            duracao = Self.duracao / velocidade
        }
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true } // y para baixo, como no Windows

    func comecar(aoTerminar: @escaping () -> Void) {
        inicio = Date()
        relogio = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            if Date().timeIntervalSince(self.inicio) >= self.duracao {
                t.invalidate()
                aoTerminar()
            } else {
                self.needsDisplay = true
            }
        }
    }

    /// (s, d) → ponto da vista.
    private func ponto(_ s: CGFloat, _ d: CGFloat) -> CGPoint {
        switch borda {
        case .direita: CGPoint(x: fundo - d, y: comprimento / 2 + s)
        case .esquerda: CGPoint(x: d, y: comprimento / 2 + s)
        case .acima: CGPoint(x: comprimento / 2 + s, y: d)
        case .abaixo: CGPoint(x: comprimento / 2 + s, y: fundo - d)
        }
    }

    /// Quanto a borda está esticada, de 0 a ~1,08: sobe rápido com uma pequena sobra elástica e volta suave.
    private static func envelope(_ p: Double) -> Double {
        guard p > 0, p < 1 else { return 0 }
        let subida = 0.32
        if p < subida {
            let x = p / subida - 1, c = 1.4 // ease-out-back: passa um pouco de 1 e assenta
            return 1 + (c + 1) * x * x * x + c * x * x
        }
        let q = (p - subida) / (1 - subida) // ease-in-out de volta a 0
        return 1 - (q < 0.5 ? 4 * q * q * q : 1 - pow(-2 * q + 2, 3) / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let p = Date().timeIntervalSince(inicio) / duracao
        if efeito == "pixels" { return desenharPixels(g, p) }
        if hexagonos { return desenharHexagonos(g, p) }
        let env = CGFloat(Self.envelope(p))
        // Chegando, a ondulação se espalha ao longo da borda; saindo, ela se recolhe para o ponto.
        let sigma = Self.largura * k * CGFloat(entrando ? 0.65 + 0.55 * p : 1.2 - 0.55 * p)
        let a = env * Self.profundidade * k
        let alcance = min(2.8 * sigma, comprimento / 2 - 1)
        guard a > 0.3 else { return }

        // A curva: d(s) = a · e^(−s²/2σ²)
        let n = 96
        let curva = CGMutablePath()
        for i in 0...n {
            let s = -alcance + 2 * alcance * CGFloat(i) / CGFloat(n)
            let q = ponto(s, a * exp(-s * s / (2 * sigma * sigma)))
            i == 0 ? curva.move(to: q) : curva.addLine(to: q)
        }
        let forca = min(max(env, 0), 1)
        let espaco = CGColorSpace(name: CGColorSpace.sRGB)!

        // Preenchimento: da borda (mais forte) até a curva (transparente).
        let area = CGMutablePath()
        area.move(to: ponto(-alcance, 0))
        area.addPath(curva)
        area.addLine(to: ponto(alcance, 0))
        area.closeSubpath()
        g.saveGState()
        g.addPath(area)
        g.clip()
        let fundoCor = CGGradient(colorsSpace: espaco, colors: [corHex.withAlphaComponent(150 / 255 * forca).cgColor,
                                                                  corHex.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(fundoCor, start: ponto(0, -0.5), end: ponto(0, a + 0.5), options: [])
        g.restoreGState()

        // Traço da curva em três camadas, que some nas pontas ao longo da borda.
        func traco(_ cor: NSColor, _ alfa: CGFloat, _ largura: CGFloat) {
            g.saveGState()
            g.addPath(curva)
            g.setLineWidth(largura)
            g.setLineJoin(.round)
            g.setLineCap(.round)
            g.replacePathWithStrokedPath()
            g.clip()
            let gradiente = CGGradient(colorsSpace: espaco, colors: [cor.withAlphaComponent(0).cgColor, cor.withAlphaComponent(alfa).cgColor,
                                                                       cor.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.5, 1])!
            g.drawLinearGradient(gradiente, start: ponto(-alcance - 1, 0), end: ponto(alcance + 1, 0), options: [])
            g.restoreGState()
        }
        // Brilho na cor clareada 35%, como no Windows.
        let c = corHex.usingColorSpace(.sRGB) ?? corHex
        let clara = NSColor(red: c.redComponent + (1 - c.redComponent) * 0.35, green: c.greenComponent + (1 - c.greenComponent) * 0.35,
                            blue: c.blueComponent + (1 - c.blueComponent) * 0.35, alpha: 1)
        traco(clara, forca / 3, 9 * k)
        traco(c, forca, 3 * k)
        traco(.white, forca * 2 / 3, 1 * k)
    }

    // MARK: Pixels

    private func desenharPixels(_ g: CGContext, _ p: Double) {
        // Mesmo gerador pseudoaleatório da página de efeitos, para o desenho ser o mesmo.
        var x = 5 * 9301 + 49297
        func proximo() -> Double {
            x = (x * 9301 + 49297) % 233280
            return Double(x) / 233280
        }
        let tam = 7 * k
        let c = corHex.usingColorSpace(.sRGB) ?? corHex
        for _ in 0..<40 {
            let col = floor(proximo() * 7)
            let lin = ((proximo() * 2 - 1) * 7).rounded()
            let atraso = proximo() * 0.4
            let tom = proximo() * 0.5
            let alvo = CGFloat(col + 1) * tam * 1.3
            let s = CGFloat(lin) * tam * 1.3
            let tau = min(max((p - atraso) / 0.55, 0), 1)
            var d: CGFloat
            let alfa: Double
            if entrando {
                guard tau > 0 else { continue }
                d = alvo * CGFloat(Self.easeOutCubic(tau))
                alfa = p < 0.7 ? 1 : 1 - (p - 0.7) / 0.3
            } else {
                guard tau < 1 else { continue }
                d = alvo * CGFloat(1 - tau * tau * tau)
                alfa = tau < 0.1 ? tau * 10 : 1
            }
            d = (d / tam).rounded() * tam // anda em "passos de pixel"
            let cor = NSColor(red: c.redComponent + (1 - c.redComponent) * tom, green: c.greenComponent + (1 - c.greenComponent) * tom,
                              blue: c.blueComponent + (1 - c.blueComponent) * tom, alpha: 0.9 * max(alfa, 0))
            let centro = ponto(s, d), lado = 0.84 * tam
            g.setFillColor(cor.cgColor)
            g.fill(CGRect(x: centro.x - lado / 2, y: centro.y - lado / 2, width: lado, height: lado))
        }
    }

    // MARK: Campo de força

    static func telaDoPonto(_ p: CGPoint) -> CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        let telas = ids.prefix(Int(n)).map { CGDisplayBounds($0) }
        return telas.first { $0.insetBy(dx: -2, dy: -2).contains(p) } ?? CGDisplayBounds(CGMainDisplayID())
    }

    private static func easeOutCubic(_ p: Double) -> Double { 1 - pow(1 - min(max(p, 0), 1), 3) }

    private func desenharHexagonos(_ g: CGContext, _ p: Double) {
        let a = Self.ladoHex * k, rMax = Self.raioHex * k, larg = Self.larguraFrente * k
        let frente = rMax * CGFloat(entrando ? Self.easeOutCubic(p) : 1 - Self.easeOutCubic(p))
        let geral = min(max(min(1, p * 6) * (1.15 - p), 0), 1)
        // Contorno na cor clareada 35%.
        let c = corHex.usingColorSpace(.sRGB) ?? corHex
        let clara = NSColor(red: c.redComponent + (1 - c.redComponent) * 0.35, green: c.greenComponent + (1 - c.greenComponent) * 0.35,
                            blue: c.blueComponent + (1 - c.blueComponent) * 0.35, alpha: 1)
        g.setLineWidth(1.2 * k)
        g.setLineJoin(.round)
        for r in 0...12 {
            for q in -16...16 {
                let s = a * sqrt(3) * (CGFloat(q) + CGFloat(r) / 2), d = a * 1.5 * CGFloat(r)
                let dist = sqrt(s * s + d * d)
                guard dist <= rMax + a else { continue }
                let i = exp(-Double((dist - frente) * (dist - frente)) / Double(2 * larg * larg)) * geral
                guard i >= 0.02 else { continue }
                let hex = CGMutablePath()
                for v in 0..<6 {
                    let ang = Double.pi / 6 + Double(v) * Double.pi / 3
                    let q = ponto(s + CGFloat(cos(ang)) * a * 0.92, d + CGFloat(sin(ang)) * a * 0.92)
                    v == 0 ? hex.move(to: q) : hex.addLine(to: q)
                }
                hex.closeSubpath()
                g.addPath(hex)
                g.setFillColor(c.withAlphaComponent(0.18 * i).cgColor)
                g.fillPath()
                g.addPath(hex)
                g.setStrokeColor(clara.withAlphaComponent(0.9 * i).cgColor)
                g.strokePath()
            }
        }
    }
}

extension NSColor {
    /// "#009425" → cor.
    convenience init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
