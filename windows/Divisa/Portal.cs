using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Divisa;

/// Efeito de "portal" na borda por onde o cursor passa. Dois efeitos (Config.PortalEfeito):
/// - "hexagonos" (campo de força): uma malha de hexágonos acende numa única frente que se abre a partir
///   do ponto quando o cursor chega, ou se fecha nele quando o cursor sai;
/// - "elastica": a borda se estica como uma membrana (curva de sino comprida) e volta, uma vez só.
/// Cor, velocidade e tamanho vêm da Config. Janela transparente, por cima de tudo, sem foco e sem pegar
/// clique. Roda na thread da interface (a mesma dos ganchos), então cada quadro é pequeno e rápido.
sealed class Portal : Form
{
    private static Portal? atual;

    private readonly bool entrando, hexagonos;
    private readonly Lado borda;
    private readonly Color cor, clara;
    private readonly float k;              // pixels por unidade do efeito
    private readonly double duracao;       // ms
    private readonly int comprimento, fundo; // tamanho da janela ao longo da borda e para dentro, em pixels
    private readonly Rectangle janela;
    private readonly DateTime inicio = DateTime.Now;
    private readonly Timer quadro = new() { Interval = 15 };

    // Campo de força (unidades do efeito; mesmos valores da página de escolha)
    private const float LadoHex = 11, RaioHex = 120, LarguraFrente = 14;
    private const double DuracaoHex = 680;
    // Elástica
    private const float Largura = 70, Profundidade = 22;
    private const double DuracaoElastica = 520;

    /// Mostra o efeito no ponto da borda. Entrando = o cursor chegou aqui; senão, saiu daqui.
    public static void Mostrar(Point ponto, Lado borda, bool entrando, Config config)
    {
        try
        {
            atual?.Close();
            atual = new Portal(ponto, borda, entrando, config);
            atual.Show();
        }
        catch (Exception e) { Log.Escrever($"portal falhou: {e.Message}"); }
    }

    private Portal(Point ponto, Lado borda, bool entrando, Config config)
    {
        this.entrando = entrando;
        this.borda = borda;
        hexagonos = config.PortalEfeito != "elastica";
        cor = LerCor(config.PortalCor, Color.FromArgb(0, 148, 37));
        clara = Clarear(cor, 0.35f);
        var tamanho = (float)Math.Clamp(config.PortalTamanho, 0.1, 3);
        var velocidade = Math.Clamp(config.PortalVelocidade, 0.2, 5);

        if (hexagonos)
        {
            // Na página de escolha, o efeito é medido contra uma tela de 760 unidades de largura;
            // aqui usamos a largura real do monitor, para ocupar a mesma parte da tela que lá.
            k = tamanho * Screen.FromPoint(ponto).Bounds.Width / 760f;
            duracao = DuracaoHex / velocidade;
            var alcance = (int)Math.Ceiling((RaioHex + LadoHex * 2) * k);
            comprimento = 2 * alcance;
            fundo = alcance;
        }
        else
        {
            k = tamanho * Escala(ponto);
            duracao = DuracaoElastica / velocidade;
            comprimento = (int)Math.Ceiling(2 * 2.8 * Largura * k * 1.2);
            fundo = (int)Math.Ceiling(Profundidade * k * 1.2 + 14 * k);
        }

        // A janela encosta na borda da área total das telas, centrada no ponto.
        var a = SystemInformation.VirtualScreen;
        janela = borda switch
        {
            Lado.Direita => new Rectangle(a.Right - fundo, ponto.Y - comprimento / 2, fundo, comprimento),
            Lado.Esquerda => new Rectangle(a.Left, ponto.Y - comprimento / 2, fundo, comprimento),
            Lado.Acima => new Rectangle(ponto.X - comprimento / 2, a.Top, comprimento, fundo),
            _ => new Rectangle(ponto.X - comprimento / 2, a.Bottom - fundo, comprimento, fundo),
        };

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        Bounds = janela;
        quadro.Tick += (_, _) => Desenhar();
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST;
            return cp;
        }
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        Desenhar();
        quadro.Start();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        quadro.Dispose();
        if (atual == this) atual = null;
        base.OnFormClosed(e);
    }

    /// Converte (s ao longo da borda, a partir do ponto; d para dentro, a partir da borda) em pixels da janela.
    private PointF Ponto(float s, float d) => borda switch
    {
        Lado.Direita => new PointF(fundo - d, comprimento / 2f + s),
        Lado.Esquerda => new PointF(d, comprimento / 2f + s),
        Lado.Acima => new PointF(comprimento / 2f + s, d),
        _ => new PointF(comprimento / 2f + s, fundo - d),
    };

    private void Desenhar()
    {
        var p = (DateTime.Now - inicio).TotalMilliseconds / duracao;
        if (p >= 1) { Close(); return; }

        using var bmp = new Bitmap(janela.Width, janela.Height, PixelFormat.Format32bppPArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            if (hexagonos) DesenharHexagonos(g, p); else DesenharElastica(g, p);
        }
        Aplicar(bmp);
    }

    // MARK: Campo de força

    private void DesenharHexagonos(Graphics g, double p)
    {
        float a = LadoHex * k, rMax = RaioHex * k, larg = LarguraFrente * k;
        var frente = (float)(entrando ? rMax * EaseOutCubic(p) : rMax * (1 - EaseOutCubic(p)));
        var geral = Math.Clamp(Math.Min(1, p * 6) * (1.15 - p), 0, 1);
        var cantos = new PointF[6];
        using var traco = new Pen(clara, 1.2f * k) { LineJoin = LineJoin.Round };
        using var miolo = new SolidBrush(cor);
        for (int r = 0; r <= 12; r++)
            for (int q = -16; q <= 16; q++)
            {
                float s = a * MathF.Sqrt(3) * (q + r / 2f), d = a * 1.5f * r;
                var dist = MathF.Sqrt(s * s + d * d);
                if (dist > rMax + a) continue;
                var i = Math.Exp(-((dist - frente) * (dist - frente)) / (2 * larg * larg)) * geral;
                if (i < 0.02) continue;
                for (int v = 0; v < 6; v++)
                {
                    var ang = Math.PI / 6 + v * Math.PI / 3;
                    cantos[v] = Ponto(s + (float)Math.Cos(ang) * a * 0.92f, d + (float)Math.Sin(ang) * a * 0.92f);
                }
                miolo.Color = Color.FromArgb((int)(255 * 0.18 * i), cor);
                g.FillPolygon(miolo, cantos);
                traco.Color = Color.FromArgb((int)(255 * 0.9 * i), clara);
                g.DrawPolygon(traco, cantos);
            }
    }

    // MARK: Elástica

    /// Quanto a borda está esticada, de 0 a ~1,08: sobe rápido com uma pequena sobra elástica e volta suave.
    private static double Envelope(double p)
    {
        if (p <= 0 || p >= 1) return 0;
        const double subida = 0.32;
        if (p < subida)
        {
            var x = p / subida - 1;
            const double c = 1.4;
            return 1 + (c + 1) * x * x * x + c * x * x;
        }
        var q = (p - subida) / (1 - subida);
        return 1 - (q < 0.5 ? 4 * q * q * q : 1 - Math.Pow(-2 * q + 2, 3) / 2);
    }

    private void DesenharElastica(Graphics g, double p)
    {
        var env = (float)Envelope(p);
        var sigma = Largura * k * (float)(entrando ? 0.65 + 0.55 * p : 1.2 - 0.55 * p);
        var a = env * Profundidade * k;
        var alcance = Math.Min(2.8f * sigma, comprimento / 2f - 1);
        if (a <= 0.3f) return;

        int n = 96;
        var curva = new PointF[n + 1];
        for (int i = 0; i <= n; i++)
        {
            var s = -alcance + 2 * alcance * i / n;
            curva[i] = Ponto(s, a * (float)Math.Exp(-s * s / (2 * sigma * sigma)));
        }
        var forca = Math.Clamp(env, 0, 1);
        using (var area = new GraphicsPath())
        {
            area.AddLine(Ponto(-alcance, 0), curva[0]);
            area.AddLines(curva);
            area.AddLine(curva[n], Ponto(alcance, 0));
            area.CloseFigure();
            using var fundoCor = new LinearGradientBrush(Ponto(0, -0.5f), Ponto(0, a + 0.5f),
                Color.FromArgb((int)(150 * forca), cor), Color.FromArgb(0, cor));
            g.FillPath(fundoCor, area);
        }
        var forte = (int)(255 * forca);
        Pen Caneta(Color c, int alfa, float largura)
        {
            using var pincel = new LinearGradientBrush(Ponto(-alcance - 1, 0), Ponto(alcance + 1, 0), Color.Transparent, Color.Transparent)
            {
                InterpolationColors = new ColorBlend
                {
                    Colors = new[] { Color.FromArgb(0, c), Color.FromArgb(alfa, c), Color.FromArgb(0, c) },
                    Positions = new[] { 0f, 0.5f, 1f },
                },
            };
            return new Pen(pincel, largura) { LineJoin = LineJoin.Round };
        }
        using (var brilho = Caneta(clara, forte / 3, 9 * k)) g.DrawCurve(brilho, curva);
        using (var traco = Caneta(cor, forte, 3 * k)) g.DrawCurve(traco, curva);
        using (var miolo = Caneta(Color.White, forte * 2 / 3, 1 * k)) g.DrawCurve(miolo, curva);
    }

    // MARK: Utilidades

    private static double EaseOutCubic(double x) => 1 - Math.Pow(1 - x, 3);

    private static Color LerCor(string? texto, Color padrao)
    {
        if (texto is { Length: 7 } && texto[0] == '#' &&
            int.TryParse(texto.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var rgb))
            return Color.FromArgb((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
        return padrao;
    }

    private static Color Clarear(Color c, float f) =>
        Color.FromArgb((int)(c.R + (255 - c.R) * f), (int)(c.G + (255 - c.G) * f), (int)(c.B + (255 - c.B) * f));

    /// Põe o bitmap (com transparência por pixel) na janela em camadas.
    private void Aplicar(Bitmap bmp)
    {
        var telaDc = GetDC(IntPtr.Zero);
        var memDc = CreateCompatibleDC(telaDc);
        var hBmp = bmp.GetHbitmap(Color.FromArgb(0));
        var antigo = SelectObject(memDc, hBmp);
        try
        {
            var tamanho = new SIZE { cx = janela.Width, cy = janela.Height };
            var origem = new PONTO { X = 0, Y = 0 };
            var destino = new PONTO { X = janela.X, Y = janela.Y };
            var mistura = new BLENDFUNCTION { BlendOp = 0, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = 1 };
            UpdateLayeredWindow(Handle, telaDc, ref destino, ref tamanho, memDc, ref origem, 0, ref mistura, 2 /* ULW_ALPHA */);
        }
        finally
        {
            SelectObject(memDc, antigo);
            DeleteObject(hBmp);
            DeleteDC(memDc);
            ReleaseDC(IntPtr.Zero, telaDc);
        }
    }

    /// Escala do monitor onde fica o ponto (1,0 = 96 dpi).
    private static float Escala(Point p)
    {
        try
        {
            var monitor = MonitorFromPoint(new PONTO { X = p.X, Y = p.Y }, 2 /* MONITOR_DEFAULTTONEAREST */);
            if (GetDpiForMonitor(monitor, 0, out var dx, out _) == 0 && dx > 0) return dx / 96f;
        }
        catch (Exception) { }
        return 1f;
    }

    private const int WS_EX_LAYERED = 0x80000, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80,
        WS_EX_NOACTIVATE = 0x8000000, WS_EX_TOPMOST = 0x8;

    [StructLayout(LayoutKind.Sequential)] private struct PONTO { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct SIZE { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref PONTO pptDst, ref SIZE psize,
        IntPtr hdcSrc, ref PONTO pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr hDC);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr hObject);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(PONTO pt, uint dwFlags);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);
}
