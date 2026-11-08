using System;
using System.IO;
using System.Text.Json;

namespace Divisa;

/// Ajustes guardados em %APPDATA%\Divisa\config.json.
sealed class Config
{
    public string Id { get; set; } = Guid.NewGuid().ToString().ToLowerInvariant();
    public bool Ativo { get; set; } = true;
    public Lado Lado { get; set; } = Lado.Direita;
    /// Ctrl ↔ Cmd/Win, para Cmd+C no Mac virar Ctrl+C aqui e Ctrl+C daqui virar Cmd+C no Mac.
    public bool TrocarCtrl { get; set; } = true;
    /// Mandando no Mac com o teclado daqui: Alt vira Cmd e Windows vira Option, como as posições no teclado do Mac
    /// (Ctrl continua Ctrl). Quando ligado, vale no lugar do TrocarCtrl para o que sai daqui.
    public bool AltComoCmd { get; set; } = true;
    /// Onda de "portal" na borda quando o cursor passa de um computador para o outro.
    public bool Portal { get; set; } = true;

    private static string Arquivo => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Divisa", "config.json");

    public static Config Carregar()
    {
        try
        {
            if (File.Exists(Arquivo) && JsonSerializer.Deserialize<Config>(File.ReadAllText(Arquivo)) is Config c) return c;
        }
        catch (Exception) { }
        var nova = new Config();
        nova.Salvar();
        return nova;
    }

    public void Salvar()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Arquivo)!);
        File.WriteAllText(Arquivo, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }
}
