using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace Divisa;

/// Portas e formato em PROTOCOLO.md.
static class Portas
{
    public const int Tcp = 24800;
    public const int Udp = 24801;
}

/// Anuncia este computador por broadcast UDP a cada 2 s e avisa (na thread da interface) dos anúncios dos outros.
sealed class Descoberta
{
    public event Action<JsonObject, string>? AoOuvir;
    private readonly byte[] anuncio;
    private readonly SynchronizationContext ui;
    private UdpClient? udp;

    public Descoberta(Dictionary<string, object> anuncio, SynchronizationContext ui)
    {
        this.anuncio = JsonSerializer.SerializeToUtf8Bytes(anuncio);
        this.ui = ui;
    }

    public void Iniciar()
    {
        udp = new UdpClient { EnableBroadcast = true, ExclusiveAddressUse = false };
        udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        udp.Client.Bind(new IPEndPoint(IPAddress.Any, Portas.Udp));
        _ = Task.Run(Ouvir);
        _ = Task.Run(Anunciar);
    }

    private async Task Ouvir()
    {
        while (udp != null)
        {
            try
            {
                var r = await udp.ReceiveAsync();
                if (JsonNode.Parse(r.Buffer) is JsonObject msg)
                {
                    var ip = r.RemoteEndPoint.Address.ToString();
                    ui.Post(_ => AoOuvir?.Invoke(msg, ip), null);
                }
            }
            catch (Exception e) when (e is SocketException or JsonException) { }
            catch (ObjectDisposedException) { return; }
        }
    }

    private async Task Anunciar()
    {
        var destino = new IPEndPoint(IPAddress.Broadcast, Portas.Udp);
        while (udp != null)
        {
            try { await udp.SendAsync(anuncio, anuncio.Length, destino); } catch (SocketException) { }
            await Task.Delay(2000);
        }
    }
}

/// Uma conexão TCP com o parceiro: um JSON por linha. Eventos chegam na thread da interface.
sealed class Conexao
{
    public event Action<JsonObject>? AoReceber;
    public event Action? AoFechar;
    private readonly TcpClient tcp;
    private readonly SynchronizationContext ui;
    private NetworkStream? fluxo;
    private readonly object travaEnvio = new();
    private bool fechada;

    public Conexao(TcpClient tcp, SynchronizationContext ui)
    {
        this.tcp = tcp;
        this.ui = ui;
        tcp.NoDelay = true; // movimento do mouse não pode esperar o Nagle
    }

    public static async Task<Conexao?> Para(string ip, int porta, SynchronizationContext ui)
    {
        var tcp = new TcpClient();
        try
        {
            using var limite = new CancellationTokenSource(3000);
            await tcp.ConnectAsync(ip, porta, limite.Token);
            return new Conexao(tcp, ui);
        }
        catch (Exception) { tcp.Dispose(); return null; }
    }

    public void Iniciar()
    {
        fluxo = tcp.GetStream();
        _ = Task.Run(Ler);
    }

    public void Enviar(Dictionary<string, object> msg)
    {
        if (fechada || fluxo == null) return;
        // JSON e a quebra de linha num pacote só.
        var json = JsonSerializer.SerializeToUtf8Bytes(msg);
        var dados = new byte[json.Length + 1];
        json.CopyTo(dados, 0);
        dados[^1] = 0x0A;
        try
        {
            lock (travaEnvio) fluxo.Write(dados);
        }
        catch (Exception) { Fechar(); }
    }

    public void Fechar()
    {
        if (fechada) return;
        fechada = true;
        try { tcp.Close(); } catch { }
        ui.Post(_ => AoFechar?.Invoke(), null);
    }

    private async Task Ler()
    {
        try
        {
            using var leitor = new StreamReader(fluxo!, new UTF8Encoding(false));
            while (!fechada)
            {
                var linha = await leitor.ReadLineAsync();
                if (linha == null) break;
                try
                {
                    if (JsonNode.Parse(linha) is JsonObject msg) ui.Post(_ => AoReceber?.Invoke(msg), null);
                }
                catch (JsonException) { }
            }
        }
        catch (Exception) { }
        Fechar();
    }
}

/// Escuta na porta TCP e entrega cada conexão nova na thread da interface.
sealed class Servidor
{
    public event Action<TcpClient>? AoConectar;
    private readonly SynchronizationContext ui;
    private TcpListener? ouvinte;

    public Servidor(SynchronizationContext ui) => this.ui = ui;

    public void Iniciar()
    {
        ouvinte = new TcpListener(IPAddress.Any, Portas.Tcp);
        ouvinte.Start();
        _ = Task.Run(async () =>
        {
            while (true)
            {
                try
                {
                    var c = await ouvinte.AcceptTcpClientAsync();
                    ui.Post(_ => AoConectar?.Invoke(c), null);
                }
                catch (ObjectDisposedException) { return; }
                catch (SocketException) { }
            }
        });
    }
}
