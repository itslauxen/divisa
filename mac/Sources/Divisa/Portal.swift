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
        let onda = Onda(borda: borda, entrando: entrando)

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

    let borda: Lado
    let entrando: Bool
    let comprimento: CGFloat
    let fundo: CGFloat
    private var inicio = Date()
    private var relogio: Timer?

    init(borda: Lado, entrando: Bool) {
        self.borda = borda
        self.entrando = entrando
        comprimento = (2 * 2.8 * Self.largura * 1.2).rounded(.up)
        fundo = (Self.profundidade * 1.2 + 14).rounded(.up) // folga para a sobra elástica e o brilho
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true } // y para baixo, como no Windows

    func comecar(aoTerminar: @escaping () -> Void) {
        inicio = Date()
        relogio = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            if Date().timeIntervalSince(self.inicio) >= Self.duracao {
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
        let p = Date().timeIntervalSince(inicio) / Self.duracao
        let env = CGFloat(Self.envelope(p))
        // Chegando, a ondulação se espalha ao longo da borda; saindo, ela se recolhe para o ponto.
        let sigma = Self.largura * CGFloat(entrando ? 0.65 + 0.55 * p : 1.2 - 0.55 * p)
        let a = env * Self.profundidade
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
        let fundoCor = CGGradient(colorsSpace: espaco, colors: [Self.cor.withAlphaComponent(150 / 255 * forca).cgColor,
                                                                  Self.cor.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
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
        traco(Self.brilho, forca / 3, 9)
        traco(Self.cor, forca, 3)
        traco(.white, forca * 2 / 3, 1)
    }
}
