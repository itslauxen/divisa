import AppKit
import QuartzCore

/// Animação de "portal" no ponto da borda por onde o cursor passa de um computador para o outro.
/// Mesmos valores do Windows: 3 anéis #38A6CF, traço de 3 pt com brilho, defasados em 80 ms, ~450 ms, ease-out.
/// O círculo fica centrado no ponto da borda, então só a metade de dentro da tela aparece.
@MainActor
enum Portal {
    static var ligado: Bool {
        get { UserDefaults.standard.object(forKey: "portal") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "portal") }
    }

    private static let raio: CGFloat = 70
    private static let duracao: CFTimeInterval = 0.45
    private static let defasagem: CFTimeInterval = 0.08

    /// Saindo deste computador: os anéis se fecham no ponto, como se o cursor fosse sugado.
    static func saida(em ponto: CGPoint) { animar(em: ponto, abrindo: false) }

    /// Chegando neste computador: os anéis se abrem a partir do ponto e apagam.
    static func entrada(em ponto: CGPoint) { animar(em: ponto, abrindo: true) }

    /// `ponto` em coordenadas globais do CoreGraphics (origem no canto de cima à esquerda).
    private static func animar(em ponto: CGPoint, abrindo: Bool) {
        guard ligado else { return }
        let lado = (raio + 12) * 2
        // O AppKit conta y de baixo para cima, a partir da tela principal.
        let alturaPrincipal = NSScreen.screens.first?.frame.maxY ?? 0
        let centro = NSPoint(x: ponto.x, y: alturaPrincipal - ponto.y)
        let janela = NSPanel(contentRect: NSRect(x: centro.x - lado / 2, y: centro.y - lado / 2, width: lado, height: lado),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        janela.level = .screenSaver
        janela.isOpaque = false
        janela.backgroundColor = .clear
        janela.hasShadow = false
        janela.ignoresMouseEvents = true
        janela.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let raiz = CALayer()
        raiz.frame = CGRect(x: 0, y: 0, width: lado, height: lado)
        let vista = NSView(frame: raiz.frame)
        vista.wantsLayer = true
        vista.layer = raiz
        janela.contentView = vista

        let inicio = CACurrentMediaTime()
        for i in 0..<3 {
            let anel = CAShapeLayer()
            anel.frame = raiz.bounds
            anel.path = CGPath(ellipseIn: CGRect(x: lado / 2 - raio, y: lado / 2 - raio, width: raio * 2, height: raio * 2), transform: nil)
            anel.fillColor = nil
            anel.strokeColor = NSColor(red: 0x38 / 255, green: 0xA6 / 255, blue: 0xCF / 255, alpha: 1).cgColor
            anel.lineWidth = 3
            anel.shadowColor = NSColor(red: 0x62 / 255, green: 0xC5 / 255, blue: 0xEE / 255, alpha: 1).cgColor
            anel.shadowRadius = 6
            anel.shadowOpacity = 0.9
            anel.shadowOffset = .zero
            anel.opacity = 0
            raiz.addSublayer(anel)

            let escala = CABasicAnimation(keyPath: "transform.scale")
            escala.fromValue = abrindo ? 0.01 : 1
            escala.toValue = abrindo ? 1 : 0.01
            let opacidade = CABasicAnimation(keyPath: "opacity")
            opacidade.fromValue = abrindo ? 1 : 0.35
            opacidade.toValue = abrindo ? 0 : 1
            let grupo = CAAnimationGroup()
            grupo.animations = [escala, opacidade]
            grupo.duration = duracao - defasagem * 2
            grupo.beginTime = inicio + defasagem * Double(i)
            grupo.timingFunction = CAMediaTimingFunction(name: .easeOut)
            grupo.fillMode = .backwards
            anel.add(grupo, forKey: "portal")
        }

        janela.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + duracao + 0.05) { janela.orderOut(nil) }
    }
}
