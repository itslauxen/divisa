import Foundation

/// Registro em ~/Library/Logs/Divisa.log (e no console), para entender o que aconteceu depois.
func diario(_ formato: String, _ args: CVarArg...) {
    let texto = String(format: formato, arguments: args)
    NSLog("[Divisa] %@", texto)
    let linha = "\(Diario.hora.string(from: Date())) \(texto)\n"
    Diario.fila.async {
        guard let dados = linha.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: Diario.arquivo) {
            h.seekToEndOfFile()
            h.write(dados)
            try? h.close()
        } else {
            try? dados.write(to: Diario.arquivo)
        }
    }
}

enum Diario {
    static let arquivo = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Divisa.log")
    static let fila = DispatchQueue(label: "divisa.diario")
    static let hora: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
