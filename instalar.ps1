# Instala (ou atualiza) a Divisa no Windows. No PowerShell:
#   irm https://raw.githubusercontent.com/itslauxen/divisa/main/instalar.ps1 | iex
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # a barra de progresso deixa o download muito lento

$pasta = Join-Path $env:LOCALAPPDATA 'Programs\Divisa'
$exe = Join-Path $pasta 'Divisa.exe'
New-Item -ItemType Directory -Force -Path $pasta | Out-Null

# Fecha a versão aberta, se houver, antes de trocar.
Get-Process Divisa -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
# Se ela estava passando o mouse para o Mac, os cursores do sistema estavam trocados por um vazio: restaura.
Add-Type -Namespace Divisa -Name Cursores -MemberDefinition '[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, System.IntPtr c, uint d);'
[Divisa.Cursores]::SystemParametersInfo(0x57, 0, [IntPtr]::Zero, 0) | Out-Null

Write-Host 'Baixando a Divisa...'
Invoke-WebRequest 'https://github.com/itslauxen/divisa/releases/latest/download/Divisa-windows.exe' -OutFile $exe
Unblock-File $exe

# Atalho no Menu Iniciar.
$atalho = Join-Path ([Environment]::GetFolderPath('Programs')) 'Divisa.lnk'
$shell = New-Object -ComObject WScript.Shell
$l = $shell.CreateShortcut($atalho)
$l.TargetPath = $exe
$l.Save()

Start-Process $exe
Write-Host ''
Write-Host 'Pronto! A Divisa esta na bandeja, perto do relogio.'
Write-Host 'Se o Firewall perguntar, libere em redes privadas.'
Write-Host 'Clique com o botao direito no icone para escolher de que lado o Mac fica.'
