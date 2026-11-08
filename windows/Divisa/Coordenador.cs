using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Threading;
using System.Windows.Forms;
using static Divisa.Nativo;

namespace Divisa;

enum Lado { Esquerda, Direita, Acima, Abaixo }
enum Estado { Local, Mandando, Obedecendo }

/// Liga a rede, o mouse e o teclado. Estados e mensagens seguem PROTOCOLO.md. Tudo roda na thread da interface.
sealed class Coordenador
{
    /// Marca dos eventos que este app injeta, para não confundir com o mouse físico.
    private static readonly IntPtr Marca = new(0x0D1715A);

    public event Action? AoMudar;
    public Estado Estado { get; private set; } = Estado.Local;
    public string? Parceiro { get; private set; }
    public Config Config { get; }

    private readonly SynchronizationContext ui;
    private readonly Servidor servidor;
    private Descoberta? descoberta;
    private Conexao? conexao;
    /// Desde quando ouvimos o parceiro sem estar conectados (só para quem tem o id maior).
    private DateTime? anunciosSemConexao;
    private DateTime ultimoRecebido = DateTime.Now;
    private readonly System.Windows.Forms.Timer relogio = new() { Interval = 2000 };

    // Ganchos (os delegates ficam em campos para o coletor de lixo não levá-los).
    private readonly Gancho ganchoMouse, ganchoTeclado;
    private IntPtr idMouse, idTeclado;

    // Mandando
    private Point pino, centro;
    private uint ultimaAreaEnviada;
    private DateTime voltouEm = DateTime.MinValue;
    // Movimento juntado: o mouse lê até 1000 vezes por segundo, mas basta mandar a cada 4 ms.
    private int movX, movY;
    private long ultimoMov;
    private readonly Stopwatch cronometro = Stopwatch.StartNew();
    private readonly System.Windows.Forms.Timer sobraMov = new() { Interval = 8 };

    // Local: última posição do mouse físico e botões físicos apertados
    private Point ultimo;
    private int botoesFisicos;
    private readonly HashSet<int> modificadoresFisicos = new();

    // Obedecendo
    private Point cursor;
    private readonly HashSet<string> botoesApertados = new();
    private readonly HashSet<int> teclasApertadas = new(); // scan codes
    private DateTime ultimoCliqueHora;
    private double rodaAcumulada, rodaHAcumulada;

    public Coordenador(Config config)
    {
        Config = config;
        ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        servidor = new Servidor(ui);
        ganchoMouse = AoMouse;
        ganchoTeclado = AoTeclado;
    }

    public void Iniciar()
    {
        servidor.AoConectar += c =>
        {
            if (conexao != null) { c.Close(); return; }
            Usar(new Conexao(c, ui));
        };
        servidor.Iniciar();

        descoberta = new Descoberta(new()
        {
            ["t"] = "anuncio", ["v"] = 1, ["id"] = Config.Id, ["nome"] = Environment.MachineName, ["so"] = "windows", ["porta"] = Portas.Tcp,
        }, ui);
        descoberta.AoOuvir += Ouvir;
        descoberta.Iniciar();

        relogio.Tick += (_, _) => Batimento();
        sobraMov.Tick += (_, _) => { sobraMov.Stop(); EnviarMov(); };
        relogio.Start();

        var modulo = GetModuleHandle(null);
        idMouse = SetWindowsHookEx(WH_MOUSE_LL, ganchoMouse, modulo, 0);
        idTeclado = SetWindowsHookEx(WH_KEYBOARD_LL, ganchoTeclado, modulo, 0);
        Log.Escrever($"iniciado: id {Config.Id}, lado {Config.Lado}, telas {Area}, ganchos {idMouse != IntPtr.Zero}/{idTeclado != IntPtr.Zero}");
    }

    public void Parar()
    {
        VoltarParaLocal(avisar: true);
        if (idMouse != IntPtr.Zero) UnhookWindowsHookEx(idMouse);
        if (idTeclado != IntPtr.Zero) UnhookWindowsHookEx(idTeclado);
        Cursor.Mostrar();
    }

    /// Conecta direto num IP, para redes que bloqueiam broadcast.
    public async void Conectar(string ip)
    {
        if (conexao != null || string.IsNullOrWhiteSpace(ip)) return;
        var c = await Conexao.Para(ip.Trim(), Portas.Tcp, ui);
        if (c != null && conexao == null) Usar(c);
    }

    // MARK: Rede

    private void Ouvir(JsonObject msg, string ip)
    {
        if ((string?)msg["t"] != "anuncio" || msg["id"]?.GetValue<string>() is not string outro || outro == Config.Id) return;
        if (conexao != null) { anunciosSemConexao = null; return; }
        // Quem tem o id menor conecta na hora. O outro espera 6 s: se o firewall de lá bloquear a entrada, conecta ele.
        if (string.CompareOrdinal(Config.Id, outro) > 0)
        {
            anunciosSemConexao ??= DateTime.Now;
            if ((DateTime.Now - anunciosSemConexao.Value).TotalSeconds <= 6) return;
            anunciosSemConexao = null;
        }
        var porta = msg["porta"]?.GetValue<int>() ?? Portas.Tcp;
        _ = ConectarEm(ip, porta);
    }

    private async System.Threading.Tasks.Task ConectarEm(string ip, int porta)
    {
        var c = await Conexao.Para(ip, porta, ui);
        if (c == null) return;
        if (conexao != null) { c.Fechar(); return; }
        Usar(c);
    }

    private void Usar(Conexao c)
    {
        Log.Escrever("conectado");
        conexao = c;
        ultimoRecebido = DateTime.Now;
        c.AoReceber += Receber;
        c.AoFechar += () =>
        {
            if (conexao != c) return;
            Log.Escrever("conexão fechada");
            conexao = null;
            Parceiro = null;
            VoltarParaLocal(avisar: false);
            AoMudar?.Invoke();
        };
        c.Iniciar();
        c.Enviar(new() { ["t"] = "ola", ["v"] = 1, ["id"] = Config.Id, ["nome"] = Environment.MachineName, ["so"] = "windows", ["teclado"] = Teclado() });
    }

    /// KLID do layout de teclado em uso (ex.: "00010416" = Português Brasil ABNT2), para o outro lado usar o equivalente.
    /// Vale o layout da janela em primeiro plano, não o padrão do sistema. O HKL não traz o KLID direto (as variantes,
    /// como ABNT2 e US-International, ficam escondidas na palavra alta), então ativamos o mesmo HKL por um instante
    /// na nossa thread, lemos o nome e devolvemos o que estava.
    private static string Teclado()
    {
        var nome = new System.Text.StringBuilder(9);
        try
        {
            var janela = GetForegroundWindow();
            var hkl = janela != IntPtr.Zero ? GetKeyboardLayout(GetWindowThreadProcessId(janela, out _)) : IntPtr.Zero;
            if (hkl != IntPtr.Zero)
            {
                var nosso = GetKeyboardLayout(0);
                if (hkl == nosso) return GetKeyboardLayoutName(nome) ? nome.ToString() : "";
                ActivateKeyboardLayout(hkl, 0);
                var ok = GetKeyboardLayoutName(nome);
                ActivateKeyboardLayout(nosso, 0);
                if (ok) return nome.ToString();
            }
        }
        catch (Exception) { }
        return GetKeyboardLayoutName(nome) ? nome.ToString() : "";
    }

    private void Enviar(Dictionary<string, object> msg)
    {
        // Teclas e movimento não vão para o log: gravar disco dentro do gancho atrasa a entrada.
        if (msg["t"] is not ("mov" or "ping" or "area" or "tecla")) Log.Escrever($"-> {msg["t"]}{(msg.TryGetValue("teclado", out var tk) ? $" teclado {tk}" : "")} (estado {Estado})");
        conexao?.Enviar(msg);
    }

    private void Batimento()
    {
        if (conexao == null) return;
        if ((DateTime.Now - ultimoRecebido).TotalSeconds > 6) { conexao.Fechar(); return; }
        Enviar(new() { ["t"] = "ping" });
    }

    private void Receber(JsonObject msg)
    {
        ultimoRecebido = DateTime.Now;
        var tipoMsg = (string?)msg["t"];
        if (tipoMsg is not ("mov" or "ping")) Log.Escrever($"<- {msg.ToJsonString()} (estado {Estado})");
        switch (tipoMsg)
        {
            case "ola":
                Parceiro = (string?)msg["nome"] ?? "Outro computador";
                AoMudar?.Invoke();
                break;
            case "entrar":
                if (!Config.Ativo) { Enviar(new() { ["t"] = "liberar" }); return; }
                if (Estado == Estado.Mandando) SoltarCursor(null);
                Entrar(Numero(msg["y"] ?? msg["x"]) ?? 0.5);
                break;
            case "mov":
                if (Estado == Estado.Obedecendo) Mover(Numero(msg["dx"]) ?? 0, Numero(msg["dy"]) ?? 0);
                break;
            case "botao":
                if (Estado == Estado.Obedecendo && (string?)msg["b"] is string b) Botao(b, (bool?)msg["d"] ?? false);
                break;
            case "rolar":
                if (Estado == Estado.Obedecendo) Rolar(Numero(msg["dx"]) ?? 0, Numero(msg["dy"]) ?? 0);
                break;
            case "tecla":
                if (Estado != Estado.Obedecendo || msg["hid"] is not JsonNode h) return;
                var hid = h.GetValue<int>();
                if (Config.TrocarCtrl) hid = Teclas.Trocar(hid);
                if (Teclas.DoHid.TryGetValue(hid, out var scan)) Teclar(scan, (bool?)msg["d"] ?? false);
                break;
            case "sair":
                if (Estado == Estado.Mandando) SoltarCursor(Numero(msg["y"] ?? msg["x"]));
                break;
            case "liberar":
                if (Estado == Estado.Mandando) SoltarCursor(null);
                break;
            case "area":
                if ((string?)msg["texto"] is string texto)
                {
                    try { Clipboard.SetText(texto); } catch (ExternalException) { }
                    ultimaAreaEnviada = GetClipboardSequenceNumber(); // não devolver o mesmo texto
                }
                break;
        }
    }

    private static double? Numero(JsonNode? n)
    {
        try { return n?.GetValue<double>(); } catch { return null; }
    }

    // MARK: Telas

    private static Rectangle Area => SystemInformation.VirtualScreen;
    private bool Vertical => Config.Lado is Lado.Esquerda or Lado.Direita;

    private Point PontoNaBorda(double fracao, int dentro)
    {
        var a = Area;
        var f = Math.Clamp(fracao, 0, 1);
        return Config.Lado switch
        {
            Lado.Esquerda => new Point(a.Left + dentro, a.Top + (int)Math.Round(f * (a.Height - 1))),
            Lado.Direita => new Point(a.Right - 1 - dentro, a.Top + (int)Math.Round(f * (a.Height - 1))),
            Lado.Acima => new Point(a.Left + (int)Math.Round(f * (a.Width - 1)), a.Top + dentro),
            _ => new Point(a.Left + (int)Math.Round(f * (a.Width - 1)), a.Bottom - 1 - dentro),
        };
    }

    private double Fracao(Point p)
    {
        var a = Area;
        return Vertical ? (p.Y - a.Top) / (double)Math.Max(a.Height - 1, 1) : (p.X - a.Left) / (double)Math.Max(a.Width - 1, 1);
    }

    /// O ponto está na borda do parceiro e o movimento empurra para fora dela.
    private bool EmpurrandoBorda(Point p, double dx, double dy)
    {
        var a = Area;
        return Config.Lado switch
        {
            Lado.Esquerda => p.X <= a.Left && dx < 0,
            Lado.Direita => p.X >= a.Right - 1 && dx > 0,
            Lado.Acima => p.Y <= a.Top && dy < 0,
            _ => p.Y >= a.Bottom - 1 && dy > 0,
        };
    }

    private Dictionary<string, object> ComFracao(string tipo, double f) =>
        Vertical ? new() { ["t"] = tipo, ["y"] = f } : new() { ["t"] = tipo, ["x"] = f };

    // MARK: Mandando

    private void ComecarAMandar(Point p)
    {
        var seq = GetClipboardSequenceNumber();
        if (seq != ultimaAreaEnviada)
        {
            try { if (Clipboard.ContainsText()) Enviar(new() { ["t"] = "area", ["texto"] = Clipboard.GetText() }); } catch (ExternalException) { }
            ultimaAreaEnviada = seq;
        }
        var entrar = ComFracao("entrar", Fracao(p));
        entrar["teclado"] = Teclado(); // o layout pode ter mudado desde o "ola"
        Enviar(entrar);
        Estado = Estado.Mandando;
        if (Config.Portal) Portal.Mostrar(p, Config.Lado, entrando: false, Config);
        pino = p;
        // O cursor fica parado no meio da tela principal (escondido); cada movimento vira delta a partir dali.
        var tela = Screen.PrimaryScreen!.Bounds;
        centro = new Point(tela.Left + tela.Width / 2, tela.Top + tela.Height / 2);
        SetCursorPos(centro.X, centro.Y);
        Cursor.Esconder();
        AoMudar?.Invoke();
    }

    /// Volta de Mandando para Local. Sem fração, o cursor reaparece onde estava antes de passar.
    private void SoltarCursor(double? fracao)
    {
        Estado = Estado.Local;
        var p = fracao is double f ? PontoNaBorda(f, 2) : pino;
        SetCursorPos(p.X, p.Y);
        ultimo = p;
        voltouEm = DateTime.Now;
        Cursor.Mostrar();
        if (Config.Portal) Portal.Mostrar(p, Config.Lado, entrando: true, Config);
        AoMudar?.Invoke();
    }

    // MARK: Obedecendo

    private void Entrar(double fracao)
    {
        Estado = Estado.Obedecendo;
        cursor = PontoNaBorda(fracao, 1);
        Cursor.Mostrar();
        if (Config.Portal) Portal.Mostrar(cursor, Config.Lado, entrando: true, Config);
        MoverPara(cursor);
        AoMudar?.Invoke();
    }

    private void Mover(double dx, double dy)
    {
        if (EmpurrandoBorda(cursor, dx, dy) && botoesApertados.Count == 0)
        {
            var f = Fracao(cursor);
            SoltarTudo();
            Estado = Estado.Local;
            Enviar(ComFracao("sair", f));
            if (Config.Portal) Portal.Mostrar(cursor, Config.Lado, entrando: false, Config);
            AoMudar?.Invoke();
            return;
        }
        var a = Area;
        cursor = new Point(Math.Clamp(cursor.X + (int)dx, a.Left, a.Right - 1), Math.Clamp(cursor.Y + (int)dy, a.Top, a.Bottom - 1));
        MoverPara(cursor);
    }

    private void MoverPara(Point p)
    {
        var a = Area;
        var mi = new MOUSEINPUT
        {
            dx = (int)Math.Round((p.X - a.Left) * 65535.0 / Math.Max(a.Width - 1, 1)),
            dy = (int)Math.Round((p.Y - a.Top) * 65535.0 / Math.Max(a.Height - 1, 1)),
            dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
            dwExtraInfo = Marca,
        };
        Injetar(new INPUT { type = INPUT_MOUSE, u = new INPUTUNION { mi = mi } });
    }

    private void Botao(string b, bool apertado)
    {
        uint flag = (b, apertado) switch
        {
            ("dir", true) => MOUSEEVENTF_RIGHTDOWN, ("dir", false) => MOUSEEVENTF_RIGHTUP,
            ("meio", true) => MOUSEEVENTF_MIDDLEDOWN, ("meio", false) => MOUSEEVENTF_MIDDLEUP,
            (_, true) => MOUSEEVENTF_LEFTDOWN, _ => MOUSEEVENTF_LEFTUP,
        };
        if (apertado) { botoesApertados.Add(b); ultimoCliqueHora = DateTime.Now; } else botoesApertados.Remove(b);
        // O Windows conta o clique duplo sozinho pelo tempo entre cliques no mesmo lugar.
        Injetar(new INPUT { type = INPUT_MOUSE, u = new INPUTUNION { mi = new MOUSEINPUT { dwFlags = flag, dwExtraInfo = Marca } } });
    }

    private void Rolar(double dx, double dy)
    {
        rodaAcumulada += dy * 120;
        rodaHAcumulada += dx * 120;
        int v = (int)rodaAcumulada, h = (int)rodaHAcumulada;
        rodaAcumulada -= v;
        rodaHAcumulada -= h;
        if (v != 0) Injetar(new INPUT { type = INPUT_MOUSE, u = new INPUTUNION { mi = new MOUSEINPUT { dwFlags = MOUSEEVENTF_WHEEL, mouseData = unchecked((uint)v), dwExtraInfo = Marca } } });
        if (h != 0) Injetar(new INPUT { type = INPUT_MOUSE, u = new INPUTUNION { mi = new MOUSEINPUT { dwFlags = MOUSEEVENTF_HWHEEL, mouseData = unchecked((uint)h), dwExtraInfo = Marca } } });
    }

    private void Teclar(int scan, bool apertada)
    {
        if (apertada) teclasApertadas.Add(scan); else teclasApertadas.Remove(scan);
        uint flags = KEYEVENTF_SCANCODE;
        if ((scan & 0xE000) == 0xE000) flags |= KEYEVENTF_EXTENDEDKEY;
        if (!apertada) flags |= KEYEVENTF_KEYUP;
        var ki = new KEYBDINPUT { wScan = (ushort)(scan & 0xFF), dwFlags = flags, dwExtraInfo = Marca };
        Injetar(new INPUT { type = INPUT_KEYBOARD, u = new INPUTUNION { ki = ki } });
    }

    private void SoltarTudo()
    {
        foreach (var b in new List<string>(botoesApertados)) Botao(b, false);
        foreach (var t in new List<int>(teclasApertadas)) Teclar(t, false);
    }

    private static void Injetar(INPUT entrada) => SendInput(1, new[] { entrada }, Marshal.SizeOf<INPUT>());

    private void VoltarParaLocal(bool avisar)
    {
        switch (Estado)
        {
            case Estado.Mandando: SoltarCursor(null); break;
            case Estado.Obedecendo: SoltarTudo(); Estado = Estado.Local; AoMudar?.Invoke(); break;
        }
        if (avisar) Enviar(new() { ["t"] = "liberar" });
    }

    // MARK: Ganchos

    private IntPtr AoMouse(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return CallNextHookEx(idMouse, nCode, wParam, lParam);
        var m = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
        if (m.dwExtraInfo == Marca) return CallNextHookEx(idMouse, nCode, wParam, lParam); // nosso
        var tipo = (int)wParam;

        switch (tipo)
        {
            case WM_LBUTTONDOWN: case WM_RBUTTONDOWN: case WM_MBUTTONDOWN: botoesFisicos++; break;
            case WM_LBUTTONUP: case WM_RBUTTONUP: case WM_MBUTTONUP: botoesFisicos = Math.Max(0, botoesFisicos - 1); break;
        }

        switch (Estado)
        {
            case Estado.Mandando:
                Mandar(tipo, m);
                return (IntPtr)1; // engole
            case Estado.Obedecendo:
                // Mouse físico daqui: toma o controle de volta.
                VoltarParaLocal(avisar: true);
                break;
            case Estado.Local when tipo == WM_MOUSEMOVE:
                var p = new Point(m.pt.X, m.pt.Y);
                double dx = p.X - ultimo.X, dy = p.Y - ultimo.Y;
                var naBorda = PontoNaBordaSemDelta(p);
                ultimo = p;
                if (Config.Ativo && conexao != null && Parceiro != null && botoesFisicos == 0
                    && (DateTime.Now - voltouEm).TotalMilliseconds > 300 && naBorda && !Afastando(dx, dy))
                {
                    ComecarAMandar(p);
                    return (IntPtr)1;
                }
                break;
        }
        return CallNextHookEx(idMouse, nCode, wParam, lParam);
    }

    /// No gancho o cursor já chega limitado à tela: estar colado na borda e não estar se afastando dela basta.
    private bool PontoNaBordaSemDelta(Point p)
    {
        var a = Area;
        return Config.Lado switch
        {
            Lado.Esquerda => p.X <= a.Left,
            Lado.Direita => p.X >= a.Right - 1,
            Lado.Acima => p.Y <= a.Top,
            _ => p.Y >= a.Bottom - 1,
        };
    }

    private bool Afastando(double dx, double dy) => Config.Lado switch
    {
        Lado.Esquerda => dx > 0,
        Lado.Direita => dx < 0,
        Lado.Acima => dy > 0,
        _ => dy < 0,
    };

    private void EnviarMov()
    {
        if (movX != 0 || movY != 0) Enviar(new() { ["t"] = "mov", ["dx"] = movX, ["dy"] = movY });
        movX = movY = 0;
        ultimoMov = cronometro.ElapsedMilliseconds;
    }

    private void Mandar(int tipo, MSLLHOOKSTRUCT m)
    {
        // Clique, roda ou tecla: o movimento juntado vai antes, para manter a ordem.
        if (tipo != WM_MOUSEMOVE) EnviarMov();
        switch (tipo)
        {
            case WM_MOUSEMOVE:
                movX += m.pt.X - centro.X;
                movY += m.pt.Y - centro.Y;
                if (cronometro.ElapsedMilliseconds - ultimoMov >= 4) EnviarMov();
                else if (!sobraMov.Enabled) sobraMov.Start(); // manda o resto se o mouse parar
                return;
            case WM_LBUTTONDOWN: Enviar(new() { ["t"] = "botao", ["b"] = "esq", ["d"] = true }); break;
            case WM_LBUTTONUP: Enviar(new() { ["t"] = "botao", ["b"] = "esq", ["d"] = false }); break;
            case WM_RBUTTONDOWN: Enviar(new() { ["t"] = "botao", ["b"] = "dir", ["d"] = true }); break;
            case WM_RBUTTONUP: Enviar(new() { ["t"] = "botao", ["b"] = "dir", ["d"] = false }); break;
            case WM_MBUTTONDOWN: Enviar(new() { ["t"] = "botao", ["b"] = "meio", ["d"] = true }); break;
            case WM_MBUTTONUP: Enviar(new() { ["t"] = "botao", ["b"] = "meio", ["d"] = false }); break;
            case WM_MOUSEWHEEL:
                Enviar(new() { ["t"] = "rolar", ["dx"] = 0.0, ["dy"] = (short)(m.mouseData >> 16) / 120.0 });
                break;
            case WM_MOUSEHWHEEL:
                Enviar(new() { ["t"] = "rolar", ["dx"] = (short)(m.mouseData >> 16) / 120.0, ["dy"] = 0.0 });
                break;
        }
    }

    private IntPtr AoTeclado(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return CallNextHookEx(idTeclado, nCode, wParam, lParam);
        var k = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        if (k.dwExtraInfo == Marca) return CallNextHookEx(idTeclado, nCode, wParam, lParam); // nosso
        var tipo = (int)wParam;
        bool desce = tipo == WM_KEYDOWN || tipo == WM_SYSKEYDOWN;
        int scan = (int)k.scanCode | ((k.flags & LLKHF_EXTENDED) != 0 ? 0xE000 : 0);
        Teclas.ParaHid.TryGetValue(scan, out var hid);

        if (hid is >= 0xE0 and <= 0xE7) { if (desce) modificadoresFisicos.Add(hid); else modificadoresFisicos.Remove(hid); }

        // Ctrl+Alt+Shift+Esc: volta para cá na hora.
        if (desce && hid == 0x29 && Estado != Estado.Local && Tem(0xE0, 0xE4) && Tem(0xE2, 0xE6) && Tem(0xE1, 0xE5))
        {
            VoltarParaLocal(avisar: true);
            return (IntPtr)1;
        }

        switch (Estado)
        {
            case Estado.Mandando:
                if (hid != 0)
                {
                    EnviarMov();
                    if (Config.AltComoCmd) hid = Teclas.ComoMac(hid);
                    else if (Config.TrocarCtrl) hid = Teclas.Trocar(hid);
                    Enviar(new() { ["t"] = "tecla", ["hid"] = hid, ["d"] = desce });
                }
                return (IntPtr)1; // engole
            case Estado.Obedecendo:
                VoltarParaLocal(avisar: true);
                break;
        }
        return CallNextHookEx(idTeclado, nCode, wParam, lParam);
    }

    private bool Tem(int esquerdo, int direito) => modificadoresFisicos.Contains(esquerdo) || modificadoresFisicos.Contains(direito);
}

/// Esconde o cursor trocando os cursores do sistema por um vazio (o Windows não tem "esconder em segundo plano").
static class Cursor
{
    private static bool escondido;

    public static void Esconder()
    {
        if (escondido) return;
        var e = new byte[32 * 4];
        var x = new byte[32 * 4];
        Array.Fill(e, (byte)0xFF); // máscara AND toda 1 e XOR toda 0 = transparente
        var vazio = CreateCursor(IntPtr.Zero, 0, 0, 32, 32, e, x);
        foreach (var id in CursoresDoSistema) SetSystemCursor(CopyIcon(vazio), id);
        escondido = true;
    }

    public static void Mostrar()
    {
        if (!escondido) return;
        SystemParametersInfo(SPI_SETCURSORS, 0, IntPtr.Zero, 0);
        escondido = false;
    }
}
