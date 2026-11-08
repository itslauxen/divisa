import Carbon

/// Troca a fonte de entrada (layout de teclado) do Mac enquanto o outro computador manda, para as teclas do
/// teclado dele saírem com o desenho certo: a Divisa manda a posição física da tecla, e quem decide o caractere
/// é o layout ativo aqui. Ao devolver o controle, volta ao layout de antes.
@MainActor
enum Layout {
    private static var anterior: TISInputSource?
    /// Layout que a Divisa ativou só para a ocasião; é desativado de novo na volta.
    private static var ativadoPorNos: TISInputSource?

    /// Layout do Mac que corresponde ao layout informado pelo Windows (KLID, ex.: "00010416").
    static func doMac(paraWindows klid: String?) -> String? {
        switch klid?.uppercased() {
        case "00000416", "00010416": "com.apple.keylayout.Brazilian-ABNT2"
        case "00000409": "com.apple.keylayout.US"
        case "00020409": "com.apple.keylayout.USInternational-PC"
        case "00000816": "com.apple.keylayout.Portuguese"
        case "0000080A", "0000040A", "00000C0A": "com.apple.keylayout.Spanish-ISO"
        default: nil
        }
    }

    /// Id do layout ativo agora (ex.: "com.apple.keylayout.Brazilian-Pro"), para mandar ao outro lado.
    static var atual: String { id(TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()) }

    static func usar(_ alvoID: String) {
        guard anterior == nil, let alvo = fonte(alvoID) else { return }
        let agora = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard id(agora) != alvoID else { return }
        if !(propriedade(alvo, kTISPropertyInputSourceIsEnabled) as? Bool ?? false) {
            TISEnableInputSource(alvo)
            ativadoPorNos = alvo
        }
        anterior = agora
        TISSelectInputSource(alvo)
        diario("teclado: %@ enquanto o outro computador manda", alvoID)
    }

    static func restaurar() {
        guard let anterior else { return }
        TISSelectInputSource(anterior)
        if let ativadoPorNos { TISDisableInputSource(ativadoPorNos) }
        diario("teclado: de volta para %@", id(anterior))
        self.anterior = nil
        ativadoPorNos = nil
    }

    private static func fonte(_ id: String) -> TISInputSource? {
        let filtro = [kTISPropertyInputSourceID as String: id] as CFDictionary
        return (TISCreateInputSourceList(filtro, true)?.takeRetainedValue() as? [TISInputSource])?.first
    }

    private static func propriedade(_ s: TISInputSource, _ chave: CFString) -> AnyObject? {
        TISGetInputSourceProperty(s, chave).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
    }

    private static func id(_ s: TISInputSource) -> String { propriedade(s, kTISPropertyInputSourceID) as? String ?? "" }
}
