import AppKit
import CoreImage.CIFilterBuiltins
import ServiceManagement
import SwiftUI

@main
struct DivisaApp: App {
    @StateObject private var coordenador = Coordenador()
    @StateObject private var tablet = Tablet()

    var body: some Scene {
        MenuBarExtra {
            Painel(c: coordenador, tablet: tablet)
        } label: {
            Image(systemName: coordenador.estado == .local ? "rectangle.split.2x1" : "rectangle.split.2x1.fill")
                .task {
                    coordenador.iniciar()
                    tablet.comecar()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Janelinha da barra de menus: com quem está conectado, de que lado ele fica e permissões.
private struct Painel: View {
    @ObservedObject var c: Coordenador
    @ObservedObject var tablet: Tablet
    @State private var ip = ""
    @State private var abrirAoIniciar = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.2x1.fill")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Divisa").fontWeight(.semibold)
                    HStack(spacing: 5) {
                        Circle().fill(corDoEstado).frame(width: 7, height: 7)
                        Text(textoDoEstado).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("Ativo", isOn: $c.ativo).toggleStyle(.switch).labelsHidden()
            }

            if !c.acessibilidade {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Para ler e mandar o mouse e o teclado, libere a Divisa em Acessibilidade.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button("Liberar Acessibilidade") { c.pedirAcessibilidade() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("O outro computador fica").font(.caption).foregroundStyle(.secondary)
                Picker("Lado", selection: $c.lado) {
                    ForEach(Lado.allCases) { Text($0.nome).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            if c.parceiro == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Não achou sozinho? Conecte pelo IP do outro computador.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("192.168.1.10", text: $ip).textFieldStyle(.roundedBorder)
                        Button("Conectar") { c.conectar(ip: ip.trimmingCharacters(in: .whitespaces)) }
                    }
                }
            }

            Divider()
            secaoTablet

            Text("Atalho de emergência: ⌃⌥⇧⎋ traz o mouse de volta.").font(.caption2).foregroundStyle(.tertiary)
            Divider()
            Toggle("Abrir ao iniciar o Mac", isOn: Binding(get: { abrirAoIniciar }, set: { liga in
                try? liga ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                abrirAoIniciar = SMAppService.mainApp.status == .enabled
            }))
            Button("Sair da Divisa") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 320)
    }

    private var secaoTablet: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tela no tablet").fontWeight(.medium)
                    Text(tablet.conectado ? "Tablet conectado" : "Abra o endereço no navegador do tablet")
                        .font(.caption).foregroundStyle(tablet.conectado ? Color.green : .secondary)
                }
                Spacer()
                Toggle("Tela no tablet", isOn: $tablet.ligado).toggleStyle(.switch).labelsHidden()
            }
            if tablet.ligado {
                if tablet.semPermissaoDeTela {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Para mandar a imagem, libere a Divisa em Gravação de Tela e reabra o app.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Button("Abrir Ajustes") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
                }
                if !tablet.conectado {
                    HStack(spacing: 12) {
                        if let qr = Self.qr(tablet.endereco) {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 96, height: 96)
                                .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(.white))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Aponte a câmera do tablet ou digite:").font(.caption).foregroundStyle(.secondary)
                            Text(tablet.endereco).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private static func qr(_ texto: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(texto.utf8)
        f.correctionLevel = "M"
        guard let saida = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(saida, from: saida.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: saida.extent.width, height: saida.extent.height))
    }

    private var corDoEstado: Color {
        guard c.ativo else { return .yellow }
        return c.parceiro == nil ? .orange : .green
    }

    private var textoDoEstado: String {
        guard let p = c.parceiro else { return "Procurando o outro computador…" }
        switch c.estado {
        case .local: return "Conectado a \(p)"
        case .mandando: return "Mandando em \(p)"
        case .obedecendo: return "\(p) está no controle"
        }
    }
}
