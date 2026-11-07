import AppKit
import SwiftUI

@main
struct DivisaApp: App {
    @StateObject private var coordenador = Coordenador()

    var body: some Scene {
        MenuBarExtra {
            Painel(c: coordenador)
        } label: {
            Image(systemName: coordenador.estado == .local ? "rectangle.split.2x1" : "rectangle.split.2x1.fill")
                .task { coordenador.iniciar() }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Janelinha da barra de menus: com quem está conectado, de que lado ele fica e permissões.
private struct Painel: View {
    @ObservedObject var c: Coordenador
    @State private var ip = ""

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

            Text("Atalho de emergência: ⌃⌥⇧⎋ traz o mouse de volta.").font(.caption2).foregroundStyle(.tertiary)
            Divider()
            Button("Sair da Divisa") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 320)
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
