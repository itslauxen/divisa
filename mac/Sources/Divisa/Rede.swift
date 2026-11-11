import Foundation
import Network

/// Portas e formato estão em PROTOCOLO.md.
enum Portas {
    static let tcp: UInt16 = 24800
    static let udp: UInt16 = 24801
}

/// Uma mensagem do protocolo: um dicionário JSON, com o tipo em "t".
typealias Mensagem = [String: Any]

/// Anuncia este computador por broadcast UDP a cada 2 s e avisa dos anúncios dos outros.
/// Usa sockets BSD porque o Network.framework não faz broadcast de um jeito simples.
final class Descoberta {
    /// (anúncio, IP de quem mandou)
    var aoOuvir: ((Mensagem, String) -> Void)?
    /// Calada, não anuncia este computador (o outro não acha nem conecta).
    var calada = false
    private let anuncio: Data
    private var sock: Int32 = -1
    private var timer: DispatchSourceTimer?

    init(anuncio: Mensagem) {
        self.anuncio = (try? JSONSerialization.data(withJSONObject: anuncio)) ?? Data()
    }

    func iniciar() {
        sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return diario("udp: socket falhou") }
        var sim: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &sim, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &sim, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &sim, socklen_t(MemoryLayout<Int32>.size))
        var end = sockaddr_in()
        end.sin_family = sa_family_t(AF_INET)
        end.sin_port = Portas.udp.bigEndian
        end.sin_addr.s_addr = INADDR_ANY
        let ligou = withUnsafePointer(to: &end) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if ligou != 0 { diario("udp: bind falhou (%d)", errno) }

        let s = sock
        Thread.detachNewThread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 2048)
            while true {
                var origem = sockaddr_in()
                var tam = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &origem) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(s, &buf, buf.count, 0, $0, &tam) }
                }
                if n <= 0 { if self == nil { return }; continue }
                guard let msg = try? JSONSerialization.jsonObject(with: Data(buf[0..<n])) as? Mensagem else { continue }
                let ip = String(cString: inet_ntoa(origem.sin_addr))
                DispatchQueue.main.async { self?.aoOuvir?(msg, ip) }
            }
        }

        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now(), repeating: 2)
        t.setEventHandler { [weak self] in self?.anunciar() }
        t.resume()
        timer = t
    }

    private func anunciar() {
        if calada { return }
        var destino = sockaddr_in()
        destino.sin_family = sa_family_t(AF_INET)
        destino.sin_port = Portas.udp.bigEndian
        destino.sin_addr.s_addr = INADDR_BROADCAST
        anuncio.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destino) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(sock, bytes.baseAddress, anuncio.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

/// Uma conexão TCP com o parceiro: um JSON por linha.
final class Conexao {
    var aoReceber: ((Mensagem) -> Void)?
    var aoFechar: (() -> Void)?
    private let conexao: NWConnection
    private var sobra = Data()
    private var fechada = false

    init(_ conexao: NWConnection) {
        self.conexao = conexao
    }

    static func para(ip: String, porta: UInt16) -> Conexao {
        let opcoes = NWProtocolTCP.Options()
        opcoes.noDelay = true // movimento do mouse não pode esperar o Nagle
        return Conexao(NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: porta)!,
                                    using: NWParameters(tls: nil, tcp: opcoes)))
    }

    func iniciar(aoAbrir: @escaping () -> Void) {
        conexao.stateUpdateHandler = { [weak self] estado in
            switch estado {
            case .ready: aoAbrir()
            case .failed(let erro):
                diario("tcp: falhou %@", erro.localizedDescription)
                self?.fechar()
            case .cancelled: self?.fechar()
            default: break
            }
        }
        conexao.start(queue: .main)
        ler()
    }

    func enviar(_ msg: Mensagem) {
        guard !fechada, var dados = try? JSONSerialization.data(withJSONObject: msg) else { return }
        dados.append(0x0A)
        conexao.send(content: dados, completion: .contentProcessed { [weak self] erro in
            if erro != nil { self?.fechar() }
        })
    }

    func fechar() {
        guard !fechada else { return }
        fechada = true
        conexao.cancel()
        aoFechar?()
    }

    private func ler() {
        conexao.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] dados, _, terminou, erro in
            guard let self else { return }
            if let dados { self.sobra.append(dados); self.separar() }
            if terminou || erro != nil { self.fechar(); return }
            self.ler()
        }
    }

    private func separar() {
        while let fim = sobra.firstIndex(of: 0x0A) {
            let linha = sobra[sobra.startIndex..<fim]
            sobra.removeSubrange(sobra.startIndex...fim)
            if let msg = try? JSONSerialization.jsonObject(with: linha) as? Mensagem { aoReceber?(msg) }
        }
    }
}

/// Escuta na porta TCP e entrega cada conexão nova.
final class Servidor {
    var aoConectar: ((NWConnection) -> Void)?
    private var ouvinte: NWListener?

    func iniciar() {
        let opcoes = NWProtocolTCP.Options()
        opcoes.noDelay = true
        guard let o = try? NWListener(using: NWParameters(tls: nil, tcp: opcoes), on: NWEndpoint.Port(rawValue: Portas.tcp)!) else {
            return diario("tcp: não deu para escutar na porta %d", Portas.tcp)
        }
        o.newConnectionHandler = { [weak self] c in self?.aoConectar?(c) }
        o.start(queue: .main)
        ouvinte = o
    }
}
