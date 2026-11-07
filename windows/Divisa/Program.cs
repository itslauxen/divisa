using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Divisa;

static class Program
{
    [STAThread]
    static void Main()
    {
        using var unico = new Mutex(true, "Divisa-dev.lauxen", out var primeiro);
        if (!primeiro) return;
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2); // coordenadas em pixels reais, iguais às dos ganchos
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        // Se algo der errado, o cursor nunca fica invisível.
        AppDomain.CurrentDomain.ProcessExit += (_, _) => Cursor.Mostrar();
        AppDomain.CurrentDomain.UnhandledException += (_, _) => Cursor.Mostrar();
        Application.Run(new Bandeja());
    }
}

/// Ícone na bandeja do Windows com o estado e os ajustes.
sealed class Bandeja : ApplicationContext
{
    private readonly Coordenador c;
    private readonly NotifyIcon icone;
    private readonly ToolStripMenuItem estado, ativo, trocar, iniciarComWindows;
    private readonly ToolStripMenuItem[] lados;

    public Bandeja()
    {
        // Precisa de uma janela criada para a thread ter SynchronizationContext antes do coordenador.
        _ = new Control().Handle;
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());

        c = new Coordenador(Config.Carregar());
        estado = new ToolStripMenuItem("Procurando o outro computador…") { Enabled = false };
        ativo = new ToolStripMenuItem("Ativo", null, (_, _) => { c.Config.Ativo = !c.Config.Ativo; Salvar(); }) { Checked = c.Config.Ativo };
        trocar = new ToolStripMenuItem("Trocar Ctrl e Cmd", null, (_, _) => { c.Config.TrocarCtrl = !c.Config.TrocarCtrl; Salvar(); }) { Checked = c.Config.TrocarCtrl };
        iniciarComWindows = new ToolStripMenuItem("Iniciar com o Windows", null, (_, _) => AlternarInicio()) { Checked = IniciaComWindows };

        var nomes = new[] { ("À esquerda", Lado.Esquerda), ("À direita", Lado.Direita), ("Em cima", Lado.Acima), ("Embaixo", Lado.Abaixo) };
        lados = Array.ConvertAll(nomes, n => new ToolStripMenuItem(n.Item1, null, (_, _) => { c.Config.Lado = n.Item2; Salvar(); }) { Tag = n.Item2 });
        var menuLado = new ToolStripMenuItem("O outro computador fica");
        menuLado.DropDownItems.AddRange(lados);

        var menu = new ContextMenuStrip();
        menu.Items.AddRange(new ToolStripItem[]
        {
            estado, new ToolStripSeparator(), ativo, menuLado, trocar,
            new ToolStripMenuItem("Conectar por IP…", null, (_, _) => PedirIp()),
            iniciarComWindows, new ToolStripSeparator(),
            new ToolStripMenuItem("Sair da Divisa", null, (_, _) => Sair()),
        });

        icone = new NotifyIcon { Icon = DesenharIcone(false), Text = "Divisa", ContextMenuStrip = menu, Visible = true };
        c.AoMudar += Atualizar;
        Atualizar();
        c.Iniciar();
    }

    private void Salvar()
    {
        c.Config.Salvar();
        Atualizar();
    }

    private void Atualizar()
    {
        estado.Text = c.Parceiro is not string p ? "Procurando o outro computador…" : c.Estado switch
        {
            Estado.Mandando => $"Mandando em {p}",
            Estado.Obedecendo => $"{p} está no controle",
            _ => $"Conectado a {p}",
        };
        icone.Text = "Divisa · " + estado.Text[..Math.Min(estado.Text.Length, 50)];
        icone.Icon = DesenharIcone(c.Estado != Estado.Local);
        ativo.Checked = c.Config.Ativo;
        trocar.Checked = c.Config.TrocarCtrl;
        foreach (var l in lados) l.Checked = (Lado)l.Tag! == c.Config.Lado;
    }

    private void PedirIp()
    {
        using var f = new Form { Text = "Conectar por IP", FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterScreen,
            ClientSize = new Size(320, 96), MaximizeBox = false, MinimizeBox = false, TopMost = true };
        var rotulo = new Label { Text = "IP do outro computador:", Left = 12, Top = 12, AutoSize = true };
        var campo = new TextBox { Left = 12, Top = 34, Width = 296 };
        var ok = new Button { Text = "Conectar", Left = 228, Top = 62, Width = 80, DialogResult = DialogResult.OK };
        f.Controls.AddRange(new Control[] { rotulo, campo, ok });
        f.AcceptButton = ok;
        if (f.ShowDialog() == DialogResult.OK) c.Conectar(campo.Text);
    }

    private const string ChaveInicio = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private static bool IniciaComWindows => Registry.CurrentUser.OpenSubKey(ChaveInicio)?.GetValue("Divisa") != null;

    private void AlternarInicio()
    {
        using var chave = Registry.CurrentUser.OpenSubKey(ChaveInicio, true)!;
        if (IniciaComWindows) chave.DeleteValue("Divisa", false);
        else chave.SetValue("Divisa", $"\"{Application.ExecutablePath}\"");
        iniciarComWindows.Checked = IniciaComWindows;
    }

    private void Sair()
    {
        c.Parar();
        icone.Visible = false;
        Application.Exit();
    }

    /// Dois retângulos lado a lado; o da direita aceso quando o mouse está passando.
    private static Icon DesenharIcone(bool aceso)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using var caneta = new Pen(Color.White, 2.5f);
            using var cheio = new SolidBrush(Color.FromArgb(56, 166, 207));
            g.DrawRectangle(caneta, 2, 7, 12, 18);
            if (aceso) g.FillRectangle(cheio, 18, 7, 12, 18);
            g.DrawRectangle(caneta, 18, 7, 12, 18);
        }
        return Icon.FromHandle(bmp.GetHicon());
    }
}
