using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Divisa;

/// Ondulação de "portal" na borda por onde o cursor passa: a borda se estica como uma
/// membrana elástica (uma curva em forma de sino, comprida ao longo da borda) e volta,
/// uma vez só. Saindo, a ondulação se recolhe para o ponto; chegando, ela se espalha.
/// Janela transparente, por cima de tudo, sem foco e sem pegar clique. Roda na thread da
/// interface (a mesma dos ganchos), então cada quadro é pequeno e rápido.
sealed class Portal : Form
{
    // Em pontos (multiplicados pela escala do monitor).
    private const float Largura = 70;     // desvio da curva de sino ao longo da borda
    private const float Profundidade = 22; // quanto a borda "afunda" para dentro, no máximo
    private const double Duracao = 520;    // ms
    private static readonly Color Cor = Color.FromArgb(56, 166, 207);
    private static readonly Color Brilho = Color.FromArgb(98, 197, 238);

    private static Portal? atual;

    private readonly bool entrando;
    private readonly Lado borda;
    private readonly float escala, sigma0, profundidade;
    private readonly int comprimento, fundo; // tamanho da janela ao longo da borda e para dentro, em pixels
    private readonly Rectangle janela;
    private readonly DateTime inicio = DateTime.Now;
    private readonly Timer quadro = new() { Interval = 15 };

    /// Mostra a ondulação no ponto da borda. Entrando = o cursor chegou aqui; senão, saiu daqui.
    public static void Mostrar(Point ponto, Lado borda, bool entrando)
    {
        try
        {
            atual?.Close();
            atual = new Portal(ponto, borda, entrando);
            atual.Show();
        }
        catch (Exception e) { Log.Escrever($"portal falhou: {e.Message}"); }
    }

    private Portal(Point ponto, Lado borda, bool entrando)
    {
        this.entrando = entrando;
        this.borda = borda;
        escala = Escala(ponto);
        sigma0 = Largura * escala;
        profundidade = Profundidade * escala;
        comprimento = (int)Math.Ceiling(2 * 2.8 * sigma0 * 1.2);
        fundo = (int)Math.Ceiling(profundidade * 1.2 + 14 * escala); // folga para a sobrecarga elástica e o brilho

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

    /// Converte (s ao longo da borda, a partir do centro; d para dentro, a partir da borda) em pixels da janela.
    private PointF Ponto(float s, float d) => borda switch
    {
        Lado.Direita => new PointF(fundo - d, comprimento / 2f + s),
        Lado.Esquerda => new PointF(d, comprimento / 2f + s),
        Lado.Acima => new PointF(comprimento / 2f + s, d),
        _ => new PointF(comprimento / 2f + s, fundo - d),
    };

    /// Quanto a borda está esticada, de 0 a ~1,08: sobe rápido com uma pequena sobra elástica e volta suave.
    private static double Envelope(double p)
    {
        if (p <= 0 || p >= 1) return 0;
        const double subida = 0.32;
        if (p < subida)
        {
            var x = p / subida - 1; // ease-out-back: passa um pouco de 1 e assenta
            const double c = 1.4;
            return 1 + (c + 1) * x * x * x + c * x * x;
        }
        var q = (p - subida) / (1 - subida); // ease-in-out de volta a 0
        return 1 - (q < 0.5 ? 4 * q * q * q : 1 - Math.Pow(-2 * q + 2, 3) / 2);
    }

    private void Desenhar()
    {
        var p = (DateTime.Now - inicio).TotalMilliseconds / Duracao;
        if (p >= 1) { Close(); return; }

        var env = (float)Envelope(p);
        // Chegando, a ondulação se espalha ao longo da borda; saindo, ela se recolhe para o ponto.
        var sigma = sigma0 * (float)(entrando ? 0.65 + 0.55 * p : 1.2 - 0.55 * p);
        var a = env * profundidade;
        var alcance = Math.Min(2.8f * sigma, comprimento / 2f - 1);

        using var bmp = new Bitmap(janela.Width, janela.Height, PixelFormat.Format32bppPArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            if (a > 0.3f)
            {
                // A curva: d(s) = a · e^(−s²/2σ²)
                int n = 96;
                var curva = new PointF[n + 1];
                for (int i = 0; i <= n; i++)
                {
                    var s = -alcance + 2 * alcance * i / n;
                    curva[i] = Ponto(s, a * (float)Math.Exp(-s * s / (2 * sigma * sigma)));
                }

                // Preenchimento: da borda (mais forte) até a curva (transparente).
                using (var area = new GraphicsPath())
                {
                    area.AddLine(Ponto(-alcance, 0), curva[0]);
                    area.AddLines(curva);
                    area.AddLine(curva[n], Ponto(alcance, 0));
                    area.CloseFigure();
                    var forca = Math.Clamp(env, 0, 1);
                    using var fundoCor = new LinearGradientBrush(Ponto(0, -0.5f), Ponto(0, a + 0.5f),
                        Color.FromArgb((int)(150 * forca), Cor), Color.FromArgb(0, Cor));
                    g.FillPath(fundoCor, area);
                }

                // Traço da curva, que some nas pontas ao longo da borda.
                var forte = (int)(255 * Math.Clamp(env, 0, 1));
                Pen Caneta(Color cor, int alfa, float largura)
                {
                    var pincel = new LinearGradientBrush(Ponto(-alcance - 1, 0), Ponto(alcance + 1, 0), Color.Transparent, Color.Transparent)
                    {
                        InterpolationColors = new ColorBlend
                        {
                            Colors = new[] { Color.FromArgb(0, cor), Color.FromArgb(alfa, cor), Color.FromArgb(0, cor) },
                            Positions = new[] { 0f, 0.5f, 1f },
                        },
                    };
                    var caneta = new Pen(pincel, largura) { LineJoin = LineJoin.Round };
                    pincel.Dispose();
                    return caneta;
                }
                using (var brilho = Caneta(Brilho, forte / 3, 9 * escala)) g.DrawCurve(brilho, curva);
                using (var traco = Caneta(Cor, forte, 3 * escala)) g.DrawCurve(traco, curva);
                using (var miolo = Caneta(Color.White, forte * 2 / 3, 1 * escala)) g.DrawCurve(miolo, curva);
            }
        }
        Aplicar(bmp);
    }

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
