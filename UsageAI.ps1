# ============================================================
#  Usage A.I  -  Claude + ChatGPT (Codex)
# ============================================================
#  Icone na bandeja do sistema com o uso dos dois servicos.
#  - Passar o mouse: flyout com logos reais + barra do uso semanal
#  - Clique esquerdo: popup com detalhes (5h, semanal, plano, etc.)
#  - Clique direito: menu (atualizar, iniciar com Windows, sair)
#
#  Seguranca: os tokens sao lidos dos arquivos que os CLIs
#  oficiais ja mantem e usados SOMENTE no header Authorization
#  das duas APIs oficiais (api.anthropic.com / chatgpt.com).
#  Nada e gravado em disco. Nenhum outro destino de rede.
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Tema visual do Windows e renderizacao de texto pelo GDI (nitida, com ClearType).
# Precisa vir antes de qualquer janela ser criada.
try {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
} catch {}

# Instancia unica: se ja houver um monitor rodando, este sai em silencio
$script:mutex = New-Object System.Threading.Mutex($false, 'Global\UsageAI_Instancia')
if (-not $script:mutex.WaitOne(0, $false)) { exit }

# APIs nativas: exibir janela sem roubar foco, DPI por monitor
Add-Type -MemberDefinition '
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(long pt, uint flags);
[DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);
' -Name NativeWin -Namespace Win32

# Per-Monitor DPI aware v2: sem isso o Windows estica o app em bitmap nos
# monitores com escala (ex: notebook a 200%), deixando tudo pixelado
$null = [Win32.NativeWin]::SetProcessDpiAwarenessContext([IntPtr](-4))

# Cantos arredondados nativos do Windows 11 (DWMWA_WINDOW_CORNER_PREFERENCE = 33, ROUND = 2)
Add-Type -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);' -Name Dwm -Namespace Win32

# Fonte de interface padrao do sistema (Segoe UI no Windows 10/11), lida do
# proprio Windows. As "Segoe UI Variable" foram descartadas de proposito: sao
# fontes variaveis, que o GDI do WinForms rasteriza mal e deixa serrilhado
$script:fontUI      = ([System.Drawing.SystemFonts]::MessageBoxFont).FontFamily.Name
$script:fontDisplay = $script:fontUI
$script:fontText    = $script:fontUI
$script:fontSmall   = $script:fontUI

# Numero da barra: usa o peso mais forte da propria familia do sistema
# ("Segoe UI Black"), que le muito melhor sobre as listras; se nao existir,
# cai para a fonte do sistema em negrito
$script:numFamilia = $script:fontUI
$script:numEstilo  = [System.Drawing.FontStyle]::Bold
try {
    $teste = New-Object System.Drawing.FontFamily("$($script:fontUI) Black")
    if ($teste.IsStyleAvailable([System.Drawing.FontStyle]::Regular)) {
        $script:numFamilia = "$($script:fontUI) Black"
        $script:numEstilo  = [System.Drawing.FontStyle]::Regular
    }
    $teste.Dispose()
} catch {}

# ------------------------------------------------------------
#  Escala de DPI: o layout e definido em pixels "logicos" (96 DPI)
#  e multiplicado pela escala do monitor onde a janela vai abrir
# ------------------------------------------------------------

$script:esc = 1.0

function S { param([double]$V) return [int][math]::Round($V * $script:esc) }

function Get-EscalaEm {
    # Fator de escala (1.0 = 100%, 2.0 = 200%) do monitor que contem o ponto
    param([int]$X, [int]$Y)
    try {
        $pt = ([long]$Y -shl 32) -bor ([long]$X -band 0xFFFFFFFFL)
        $hmon = [Win32.NativeWin]::MonitorFromPoint($pt, 2)
        $dx = [uint32]0; $dy = [uint32]0
        if ([Win32.NativeWin]::GetDpiForMonitor($hmon, 0, [ref]$dx, [ref]$dy) -eq 0 -and $dx -gt 0) { return $dx / 96.0 }
    } catch {}
    return 1.0
}

# Raio das bordas das janelas do Windows 11 (DWM usa 8 px logicos); as barras
# de progresso usam o mesmo valor, para todo o app seguir o mesmo padrao
$script:RAIO_JANELA = 8

function New-RoundedPath {
    # Caminho de retangulo com cantos arredondados, para desenho com anti-aliasing
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($R -le 0) {
        $gp.AddRectangle((New-Object System.Drawing.RectangleF $X, $Y, $W, $H))
        return $gp
    }
    $d = $R * 2
    $gp.AddArc($X, $Y, $d, $d, 180, 90)
    $gp.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $gp.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $gp.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $gp.CloseFigure()
    return $gp
}

# Barras vivas na tela, para a animacao das listras saber quem repintar
$script:barras = New-Object System.Collections.ArrayList
$script:faseListras = 0.0

function Get-CorUso {
    # Cor conforme o quanto ja foi gasto: ate 30% verde, 30-70% amarelo, acima vermelho
    param([double]$Pct)
    if ($Pct -le 30) { return [System.Drawing.Color]::FromArgb(37, 211, 102) }
    if ($Pct -le 70) { return [System.Drawing.Color]::FromArgb(250, 196, 36) }
    return [System.Drawing.Color]::FromArgb(244, 63, 63)
}

function Get-CorClara {
    # Versao clareada da cor, usada nas listras diagonais
    param([System.Drawing.Color]$Cor, [double]$Fator = 0.22)
    $m = { param($c) [int][math]::Round($c + (255 - $c) * $Fator) }
    return [System.Drawing.Color]::FromArgb((& $m $Cor.R), (& $m $Cor.G), (& $m $Cor.B))
}

function New-BarraProgresso {
    # Barra de progresso no estilo da referencia: moldura branca por fora, uma
    # linha fina escura separando, e dentro o preenchimento listrado com a ponta
    # inclinada. A porcentagem fica na extrema direita do preenchimento.
    param([int]$Largura, [int]$Altura, [double]$Pct, [System.Drawing.Color]$CorFundo, [string]$Texto = '', $Icone = $null, [single]$Raio = 0, [double]$FatorBorda = 0.12)
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Size = New-Object System.Drawing.Size($Largura, $Altura)
    $bar.BackColor = $CorFundo
    $bar.Tag = @{ Pct = [math]::Max(0, [math]::Min($Pct, 100)); Texto = $Texto; Familia = $script:numFamilia; Fase = 0.0; Icone = $Icone; Raio = $Raio; FatorBorda = $FatorBorda; Estilo = $script:numEstilo }
    ($bar.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance')).SetValue($bar, $true, $null)
    $bar.add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $w = $sender.Width; $h = $sender.Height
        $info = $sender.Tag

        # Com icone, a barra ocupa uma faixa central e o icone sobra por cima
        $bh = if ($info.Icone) { [int][math]::Round($h * 0.58) } else { $h }
        $by = [int][math]::Round(($h - $bh) / 2)

        $espBranca = [math]::Max(2, [math]::Round($bh * $info.FatorBorda))   # moldura branca
        $espEscura = [math]::Max(1, [math]::Round($bh * 0.05))               # linha fina escura
        $raio = [math]::Min($info.Raio, $bh / 2)

        # Moldura branca externa
        $gpFora = New-RoundedPath 0 $by $w $bh $raio
        $pincelBranco = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $g.FillPath($pincelBranco, $gpFora)
        $pincelBranco.Dispose(); $gpFora.Dispose()

        # Interior escuro: e a linha fina de separacao e tambem o trilho vazio
        $raioInt = [math]::Max(0, $raio - $espBranca)
        $gpDentro = New-RoundedPath $espBranca ($by + $espBranca) ($w - 2 * $espBranca) ($bh - 2 * $espBranca) $raioInt
        $pincelEscuro = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(12, 12, 12))
        $g.FillPath($pincelEscuro, $gpDentro)
        $pincelEscuro.Dispose(); $gpDentro.Dispose()

        # Area util do preenchimento
        $x0 = $espBranca + $espEscura
        $y0 = $by + $espBranca + $espEscura
        $iw = $w - 2 * ($espBranca + $espEscura)
        $ih = $bh - 2 * ($espBranca + $espEscura)
        if ($iw -le 0 -or $ih -le 0) { return }

        $cor = Get-CorUso $info.Pct
        $lw = $iw * $info.Pct / 100
        $incl = $ih * 0.55      # inclinacao da ponta e das listras

        if ($lw -gt 0) {
            # Recorte no mesmo contorno arredondado da barra, para o preenchimento
            # acompanhar as bordas em vez de terminar em canto reto
            $raioFill = [math]::Max(0, $raio - $espBranca - $espEscura)
            $gpArea = New-RoundedPath $x0 $y0 $iw $ih $raioFill
            $g.SetClip($gpArea)

            # Preenchimento com a ponta inclinada (topo avanca mais que a base)
            $dir = [math]::Min($x0 + $lw + $incl / 2, $x0 + $iw)
            $dirBase = [math]::Max($x0, $x0 + $lw - $incl / 2)
            $gpFill = New-Object System.Drawing.Drawing2D.GraphicsPath
            $gpFill.AddPolygon(@(
                (New-Object System.Drawing.PointF ([single]$x0), ([single]$y0)),
                (New-Object System.Drawing.PointF ([single]$dir), ([single]$y0)),
                (New-Object System.Drawing.PointF ([single]$dirBase), ([single]($y0 + $ih))),
                (New-Object System.Drawing.PointF ([single]$x0), ([single]($y0 + $ih)))
            ))
            $fill = New-Object System.Drawing.SolidBrush $cor
            $g.FillPath($fill, $gpFill)
            $fill.Dispose()

            # Listras inclinadas animadas, num tom mais claro da propria cor
            $g.SetClip($gpFill, [System.Drawing.Drawing2D.CombineMode]::Intersect)
            $listra = New-Object System.Drawing.SolidBrush (Get-CorClara $cor)
            $faixa = $ih * 0.38
            $periodo = $faixa * 2
            $sx = $x0 - $incl - $periodo + ($info.Fase % $periodo)
            $limite = $x0 + $lw + $incl + $periodo
            while ($sx -lt $limite) {
                $g.FillPolygon($listra, @(
                    (New-Object System.Drawing.PointF ([single]$sx), ([single]($y0 + $ih))),
                    (New-Object System.Drawing.PointF ([single]($sx + $faixa)), ([single]($y0 + $ih))),
                    (New-Object System.Drawing.PointF ([single]($sx + $faixa + $incl)), ([single]$y0)),
                    (New-Object System.Drawing.PointF ([single]($sx + $incl)), ([single]$y0))
                ))
                $sx += $periodo
            }
            $listra.Dispose()
            $gpFill.Dispose(); $gpArea.Dispose()
            $g.ResetClip()
        }

        # Posicao do icone e calculada antes do texto: com preenchimento curto
        # ele encosta no inicio da barra, e o numero precisa saber disso
        $iconLado = $h
        $iconMeio = $iconLado / 2
        $iconCx = 0
        if ($info.Icone) {
            $iconCx = $x0 + $lw
            $iconCx = [math]::Max($x0 + $iconMeio - $espBranca, [math]::Min($iconCx, $w - $iconMeio))
        }

        if ($info.Texto) {
            $familia = New-Object System.Drawing.FontFamily($info.Familia)
            $estilo = $info.Estilo
            if (-not $familia.IsStyleAvailable($estilo)) { $estilo = [System.Drawing.FontStyle]::Regular }

            # O numero e desenhado como contorno (GraphicsPath): assim da para
            # medir o traco real e posiciona-lo com exatidao, em vez de depender
            # das metricas de linha da fonte, que deixam o texto fora de centro
            $sfp = [System.Drawing.StringFormat]::GenericTypographic
            $corpo = $h
            $gpTexto = New-Object System.Drawing.Drawing2D.GraphicsPath
            $gpTexto.AddString($info.Texto, $familia, [int]$estilo, $corpo, (New-Object System.Drawing.PointF 0, 0), $sfp)
            $caixa = $gpTexto.GetBounds()

            if ($caixa.Height -gt 0) {
                $corpo = $corpo * (($ih * 0.66) / $caixa.Height)
                $gpTexto.Dispose()
                $gpTexto = New-Object System.Drawing.Drawing2D.GraphicsPath
                $gpTexto.AddString($info.Texto, $familia, [int]$estilo, $corpo, (New-Object System.Drawing.PointF 0, 0), $sfp)
                $caixa = $gpTexto.GetBounds()
            }

            # Encostado na extrema direita do preenchimento; se o preenchimento
            # for curto demais, o numero fica logo apos ele, sobre o trilho.
            # Com icone, a referencia e a borda do icone, nao a ponta do
            # preenchimento - assim a folga fica igual nos dois casos
            $margem = [math]::Max(3, $ih * 0.22)

            # Acima de 10% o numero fica sempre dentro do preenchimento: se nao
            # couber no tamanho cheio, encolhe ate caber em vez de sair para fora
            if (-not $info.Icone -and $info.Pct -ge 10) {
                $disponivel = ($lw - ($incl / 2) - 2 * $margem) * 0.92   # com folga
                if ($disponivel -gt 0 -and $caixa.Width -gt $disponivel) {
                    $fator = $disponivel / $caixa.Width
                    if ($fator -gt 0.45) {
                        $corpo = $corpo * $fator
                        $gpTexto.Dispose()
                        $gpTexto = New-Object System.Drawing.Drawing2D.GraphicsPath
                        $gpTexto.AddString($info.Texto, $familia, [int]$estilo, $corpo, (New-Object System.Drawing.PointF 0, 0), $sfp)
                        $caixa = $gpTexto.GetBounds()
                    }
                }
            }

            if ($info.Icone) {
                $folga = $iconMeio * 0.78
                $direita = $iconCx - $folga - $margem
                if ($direita - $caixa.Width -lt $x0 + $margem) {
                    $direita = [math]::Min($iconCx + $folga + $margem + $caixa.Width, $x0 + $iw - $margem)
                }
            } else {
                $direita = $x0 + $lw - ($incl / 2) - $margem
                if ($direita - $caixa.Width -lt $x0 + $margem) {
                    if ($info.Pct -ge 10) {
                        # Acima de 10% o numero nao sai do preenchimento: encosta
                        # na esquerda dele em vez de escapar para o trilho
                        $direita = $x0 + $margem + $caixa.Width
                    } else {
                        $direita = [math]::Min($x0 + $lw + $margem + $caixa.Width, $x0 + $iw - $margem)
                    }
                }
            }
            $centroX = $direita - ($caixa.Width / 2)

            $mover = New-Object System.Drawing.Drawing2D.Matrix
            $mover.Translate(($centroX - ($caixa.X + $caixa.Width / 2)), (($y0 + $ih / 2) - ($caixa.Y + $caixa.Height / 2)))
            $gpTexto.Transform($mover)

            # Sobre o amarelo o branco some, entao ali o numero vai em preto
            $sobreFaixa = ($centroX - $caixa.Width / 2) -ge $x0 -and ($centroX + $caixa.Width / 2) -le ($x0 + $lw)
            $corTexto = if ($sobreFaixa -and $info.Pct -gt 30 -and $info.Pct -le 70) {
                [System.Drawing.Color]::FromArgb(20, 20, 20)
            } else {
                [System.Drawing.Color]::White
            }
            $pincel = New-Object System.Drawing.SolidBrush $corTexto
            $g.FillPath($pincel, $gpTexto)
            $pincel.Dispose(); $mover.Dispose(); $gpTexto.Dispose(); $familia.Dispose()
        }

        # Icone da marca cavalgando a ponta do preenchimento
        if ($info.Icone) {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($info.Icone, [single]($iconCx - $iconMeio), 0.0, [single]$iconLado, [single]$iconLado)
        }
    })
    [void]$script:barras.Add($bar)
    return $bar
}

$script:POLL_MS      = 180000   # 3 minutos entre consultas automaticas
$script:APP_NAME     = 'UsageAI'

# ------------------------------------------------------------
#  Coleta de dados
# ------------------------------------------------------------

function Format-Reset {
    param($ResetTime)
    if (-not $ResetTime) { return '' }
    $delta = $ResetTime - (Get-Date)
    if ($delta.TotalSeconds -lt 0) { return 'Reiniciando...' }
    if ($delta.TotalHours -lt 24) {
        return ('Reinicia em {0}h{1:d2} ({2:HH:mm})' -f [int][math]::Floor($delta.TotalHours), $delta.Minutes, $ResetTime)
    }
    $dias = @('dom','seg','ter','qua','qui','sex','sab')
    return ('Reinicia {0} {1:HH:mm}' -f $dias[[int]$ResetTime.DayOfWeek], $ResetTime)
}

function Parse-ResetValue {
    param($Value)
    # Aceita ISO 8601 (string) ou epoch em segundos (numero)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        try { return ([DateTimeOffset]::Parse($Value)).ToLocalTime().DateTime } catch { return $null }
    }
    try { return ([DateTimeOffset]::FromUnixTimeSeconds([long]$Value)).ToLocalTime().DateTime } catch { return $null }
}

function Get-ClaudeUsage {
    $credFile = Join-Path $env:USERPROFILE '.claude\.credentials.json'
    if (-not (Test-Path $credFile)) { return @{ Error = 'Claude Code nao logado' } }
    try {
        $token = (Get-Content $credFile -Raw | ConvertFrom-Json).claudeAiOauth.accessToken
        if (-not $token) { return @{ Error = 'Token do Claude ausente' } }
        $headers = @{ 'Authorization' = "Bearer $token"; 'anthropic-beta' = 'oauth-2025-04-20' }
        $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $headers -UserAgent 'claude-code/2.1.204' -TimeoutSec 15

        $quotas = @()
        foreach ($prop in $resp.PSObject.Properties) {
            $v = $prop.Value
            if ($v -isnot [PSCustomObject]) { continue }
            if ($null -eq $v.PSObject.Properties['utilization']) { continue }
            if ($null -eq $v.utilization) { continue }
            $label = switch -Wildcard ($prop.Name) {
                'five_hour'   { 'Sessao (5h)' }
                'seven_day'   { 'Semanal' }
                'seven_day_*' { 'Semanal ' + (Get-Culture).TextInfo.ToTitleCase(($prop.Name -replace '^seven_day_', '' -replace '_', ' ')) }
                default       { (Get-Culture).TextInfo.ToTitleCase(($prop.Name -replace '_', ' ')) }
            }
            $reset = Parse-ResetValue $v.resets_at
            $pct = [math]::Round([double]$v.utilization)
            # Oculta cotas inativas (0% e sem janela de reset), ex: campos reservados como nimbus_quill
            if ($pct -eq 0 -and -not $reset) { continue }
            $quotas += @{ Label = $label; Percent = $pct; Reset = $reset }
        }
        # Limites por modelo (array "limits" com scope.model)
        if ($resp.PSObject.Properties['limits'] -and $resp.limits -is [array]) {
            foreach ($lim in $resp.limits) {
                if ($null -eq $lim.scope -or $null -eq $lim.scope.model) { continue }
                $nome = $lim.scope.model.display_name
                if (-not $nome) { continue }
                $ja = $quotas | Where-Object { $_.Label -like "*$nome*" }
                if ($ja) { continue }
                $reset = Parse-ResetValue $lim.resets_at
                $pct = [math]::Round([double]($lim.percent))
                if ($pct -eq 0 -and -not $reset) { continue }
                $quotas += @{ Label = "Semanal $nome"; Percent = $pct; Reset = $reset }
            }
        }
        if ($quotas.Count -eq 0) { return @{ Error = 'Resposta sem cotas' } }

        # Plano contratado, ex: rate_limit_tier "default_claude_max_20x" -> "Max 20x"
        $plano = ''
        try {
            $perfil = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/profile' -Headers $headers -UserAgent 'claude-code/2.1.204' -TimeoutSec 15
            $tier = [string]$perfil.organization.rate_limit_tier
            if ($tier) {
                $tier = $tier -replace '^default_', '' -replace '^claude_', ''
                $plano = (Get-Culture).TextInfo.ToTitleCase(($tier -replace '_', ' '))
                $plano = $plano -replace '(\d)X\b', '$1x'   # "Max 20X" -> "Max 20x"
            }
        } catch {}
        return @{ Quotas = $quotas; Plan = $plano }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '401') { $msg = 'Token expirado (use o Claude Code para renovar)' }
        return @{ Error = $msg }
    }
}

function Get-CodexUsage {
    $authFile = Join-Path $env:USERPROFILE '.codex\auth.json'
    if (-not (Test-Path $authFile)) { return @{ Error = 'Codex nao logado' } }
    try {
        $auth = Get-Content $authFile -Raw | ConvertFrom-Json
        $token = $auth.tokens.access_token
        if (-not $token) { return @{ Error = 'Token do Codex ausente' } }
        $headers = @{ 'Authorization' = "Bearer $token"; 'Accept' = 'application/json' }
        if ($auth.tokens.account_id) { $headers['ChatGPT-Account-Id'] = $auth.tokens.account_id }
        $resp = Invoke-RestMethod -Uri 'https://chatgpt.com/backend-api/wham/usage' -Headers $headers -UserAgent 'UsageAI/1.0' -TimeoutSec 15

        $rl = $resp.rate_limit
        if ($null -eq $rl) { return @{ Error = 'Resposta sem rate_limit' } }
        $quotas = @()
        foreach ($par in @(@('primary_window', 'Sessao (5h)'), @('secondary_window', 'Semanal'))) {
            $w = $rl.PSObject.Properties[$par[0]]
            if ($null -eq $w -or $null -eq $w.Value) { continue }
            $w = $w.Value
            $reset = $null
            foreach ($campo in @('reset_at', 'resets_at')) {
                if ($w.PSObject.Properties[$campo] -and $w.$campo) { $reset = Parse-ResetValue $w.$campo; break }
            }
            if (-not $reset -and $w.PSObject.Properties['resets_in_seconds'] -and $w.resets_in_seconds) {
                $reset = (Get-Date).AddSeconds([double]$w.resets_in_seconds)
            }
            $quotas += @{ Label = $par[1]; Percent = [math]::Round([double]$w.used_percent); Reset = $reset }
        }
        if ($quotas.Count -eq 0) { return @{ Error = 'Resposta sem janelas de uso' } }
        $plano = ''
        if ($resp.PSObject.Properties['plan_type'] -and $resp.plan_type) { $plano = (Get-Culture).TextInfo.ToTitleCase([string]$resp.plan_type) }
        return @{ Quotas = $quotas; Plan = $plano }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '401') { $msg = 'Token expirado (use o Codex para renovar)' }
        return @{ Error = $msg }
    }
}

# ------------------------------------------------------------
#  Estado
# ------------------------------------------------------------

$script:data = @{ Claude = @{ Error = 'Carregando...' }; Codex = @{ Error = 'Carregando...' }; Updated = $null }

function Get-WorstPercent {
    param($Result)
    if ($Result.Error) { return $null }
    return ($Result.Quotas | ForEach-Object { $_.Percent } | Measure-Object -Maximum).Maximum
}

function Get-SemanalPercent {
    # Percentual do uso semanal do servico (null quando em erro)
    param($Result)
    if ($Result.Error) { return $null }
    $semanal = $Result.Quotas | Where-Object { $_.Label -eq 'Semanal' } | Select-Object -First 1
    if ($semanal) { return $semanal.Percent }
    return Get-WorstPercent $Result
}

function Update-Tray {
    # Tooltip nativo desligado: o hover usa o flyout customizado com os logos reais
    $script:notify.Text = ''
}

# ------------------------------------------------------------
#  Coleta em segundo plano
# ------------------------------------------------------------
#  As consultas HTTP rodam em um runspace separado. Se rodassem na thread da
#  interface, cada coleta congelaria o icone, o hover e o clique ate a resposta
#  da API - era o que fazia o painel demorar a abrir.

$script:asyncPS = $null
$script:asyncHandle = $null

# Codigo executado no runspace: as mesmas funcoes de coleta, sem tocar na interface
$script:coletaScript = @"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Parse-ResetValue { $(${function:Parse-ResetValue}) }
function Get-ClaudeUsage { $(${function:Get-ClaudeUsage}) }
function Get-CodexUsage { $(${function:Get-CodexUsage}) }
@{ Claude = (Get-ClaudeUsage); Codex = (Get-CodexUsage); Updated = (Get-Date) }
"@

function Start-Update {
    if ($script:asyncPS) { return }   # ja existe uma coleta em andamento
    try {
        $ps = [PowerShell]::Create()
        $ps.AddScript($script:coletaScript) | Out-Null
        $script:asyncHandle = $ps.BeginInvoke()
        $script:asyncPS = $ps
    } catch {
        if ($ps) { $ps.Dispose() }
        $script:asyncPS = $null
        $script:asyncHandle = $null
    }
}

function Collect-Update {
    if (-not $script:asyncPS -or -not $script:asyncHandle) { return }
    if (-not $script:asyncHandle.IsCompleted) { return }
    try {
        $resultado = $script:asyncPS.EndInvoke($script:asyncHandle) | Select-Object -Last 1
        if ($resultado) {
            $script:data.Claude  = $resultado.Claude
            $script:data.Codex   = $resultado.Codex
            $script:data.Updated = $resultado.Updated
            Update-Tray
        }
    } catch {}
    $script:asyncPS.Dispose()
    $script:asyncPS = $null
    $script:asyncHandle = $null
}

# ------------------------------------------------------------
#  Logos reais (PNG na pasta do app)
# ------------------------------------------------------------

# Carregados via memoria para nao manter o arquivo travado em disco.
# Os PNG ja vem sem margens transparentes, extraidos das artes oficiais das marcas.
function Load-Logo {
    param([string]$Caminho)
    if (-not (Test-Path $Caminho)) { return $null }
    try {
        $bytes = [IO.File]::ReadAllBytes($Caminho)
        $ms = New-Object System.IO.MemoryStream(, $bytes)
        return [System.Drawing.Image]::FromStream($ms)
    } catch { return $null }
}
$script:logoClaude = Load-Logo (Join-Path $PSScriptRoot 'LogoClaude.png')
$script:logoGpt = Load-Logo (Join-Path $PSScriptRoot 'LogoChatGPT.png')
$script:nomeClaude = Load-Logo (Join-Path $PSScriptRoot 'NomeClaude.png')
$script:nomeGpt = Load-Logo (Join-Path $PSScriptRoot 'NomeChatGPT.png')

# Equalizacao optica entre as tipografias das marcas. Medido nos arquivos: a
# altura da maiuscula "C" e praticamente igual nas duas (diferenca de 2,5%),
# mas a do ChatGPT tem traco bem mais encorpado e por isso parece maior; o
# fator abaixo compensa a altura da caixa mais esse peso visual.
$script:nomeFator = @{ 'claude' = 1.0; 'gpt' = 0.93 }

# Reamostragem de alta qualidade no tamanho exato de exibicao (evita o
# redimensionamento serrilhado do PictureBox), com cache por tamanho
$script:logoCache = @{}
function Get-LogoEscalado {
    param([string]$Chave, $Img, [int]$Px)
    if ($null -eq $Img -or $Px -le 0) { return $null }
    $k = "$Chave-$Px"
    if (-not $script:logoCache.ContainsKey($k)) {
        $b = New-Object System.Drawing.Bitmap $Px, $Px
        $g = [System.Drawing.Graphics]::FromImage($b)
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.SmoothingMode = 'HighQuality'
        $g.PixelOffsetMode = 'HighQuality'
        # Encaixa preservando a proporcao, centralizado no quadro
        $razao = [math]::Min($Px / $Img.Width, $Px / $Img.Height)
        $dw = [int][math]::Round($Img.Width * $razao)
        $dh = [int][math]::Round($Img.Height * $razao)
        $g.DrawImage($Img, [int](($Px - $dw) / 2), [int](($Px - $dh) / 2), $dw, $dh)
        $g.Dispose()
        $script:logoCache[$k] = $b
    }
    return $script:logoCache[$k]
}

function Get-NomeEscalado {
    # Tipografia oficial da marca, normalizada por altura (mesmo tamanho visual
    # para as duas marcas), reamostrada em alta qualidade
    param([string]$Chave, $Img, [int]$AlturaPx)
    if ($null -eq $Img -or $AlturaPx -le 0) { return $null }
    $k = "nome-$Chave-$AlturaPx"
    if (-not $script:logoCache.ContainsKey($k)) {
        $larg = [int][math]::Round($Img.Width * $AlturaPx / $Img.Height)
        $b = New-Object System.Drawing.Bitmap $larg, $AlturaPx
        $g = [System.Drawing.Graphics]::FromImage($b)
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.SmoothingMode = 'HighQuality'
        $g.PixelOffsetMode = 'HighQuality'
        $g.DrawImage($Img, 0, 0, $larg, $AlturaPx)
        $g.Dispose()
        $script:logoCache[$k] = $b
    }
    return $script:logoCache[$k]
}

# ------------------------------------------------------------
#  Popup de detalhes
# ------------------------------------------------------------

$script:popup = $null
$script:abrindoPopup = $false

function Add-ProviderSection {
    param($Form, [ref]$Y, [string]$Titulo, $Result, [System.Drawing.Color]$CorTitulo, [string]$LogoChave, $LogoImg, $NomeImg)

    $tituloX = S 16
    $logo = Get-LogoEscalado $LogoChave $LogoImg (S 24)
    if ($logo) {
        $pic = New-Object System.Windows.Forms.PictureBox
        $pic.Image = $logo
        $pic.SizeMode = 'Zoom'
        $pic.Size = New-Object System.Drawing.Size((S 24), (S 24))
        $pic.Location = New-Object System.Drawing.Point((S 16), $Y.Value)
        $pic.BackColor = [System.Drawing.Color]::Transparent
        $Form.Controls.Add($pic)
        $tituloX = S 48
    }

    # Nome: tipografia oficial da marca, equalizada opticamente entre as marcas
    $alturaNome = [int][math]::Round((S 16) * $script:nomeFator[$LogoChave])
    $nomeImg = Get-NomeEscalado $LogoChave $NomeImg $alturaNome
    if ($nomeImg) {
        $picNome = New-Object System.Windows.Forms.PictureBox
        $picNome.Image = $nomeImg
        $picNome.SizeMode = 'AutoSize'
        $picNome.Location = New-Object System.Drawing.Point($tituloX, ($Y.Value + [int](((S 24) - $alturaNome) / 2)))
        $picNome.BackColor = [System.Drawing.Color]::Transparent
        $Form.Controls.Add($picNome)
    } else {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $Titulo
        $lbl.Font = New-Object System.Drawing.Font($script:fontDisplay, 12, [System.Drawing.FontStyle]::Bold)
        $lbl.ForeColor = $CorTitulo
        $lbl.Location = New-Object System.Drawing.Point($tituloX, $Y.Value)
        $lbl.AutoSize = $true
        $Form.Controls.Add($lbl)
    }
    $Y.Value += S 30

    # Plano contratado, logo abaixo do nome da IA (alinhado com o nome)
    if ($Result.Plan) {
        $pl = New-Object System.Windows.Forms.Label
        $pl.Text = ('Plano {0}' -f $Result.Plan)
        $pl.Font = New-Object System.Drawing.Font($script:fontSmall, 9)
        $pl.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
        # Alinhado com a margem esquerda (onde comeca a imagem do logo), nao com o nome
        $pl.Location = New-Object System.Drawing.Point((S 16), $Y.Value)
        $pl.AutoSize = $true
        $Form.Controls.Add($pl)
        $Y.Value += S 24
    } else {
        $Y.Value += S 4
    }

    if ($Result.Error) {
        $err = New-Object System.Windows.Forms.Label
        $err.Text = $Result.Error
        $err.Font = New-Object System.Drawing.Font($script:fontText, 10)
        $err.ForeColor = [System.Drawing.Color]::FromArgb(220, 120, 120)
        $err.Location = New-Object System.Drawing.Point((S 16), $Y.Value)
        $err.AutoSize = $true
        $Form.Controls.Add($err)
        $Y.Value += S 30
        return
    }

    foreach ($q in $Result.Quotas) {
        $rot = New-Object System.Windows.Forms.Label
        $rot.Text = $q.Label
        $rot.Font = New-Object System.Drawing.Font($script:fontText, 10)
        $rot.ForeColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
        $rot.Location = New-Object System.Drawing.Point((S 16), $Y.Value)
        $rot.AutoSize = $true
        $Form.Controls.Add($rot)
        $Y.Value += S 24

        $barra = New-BarraProgresso ($Form.ClientSize.Width - (S 32)) (S 24) $q.Percent $Form.BackColor ('{0}%' -f $q.Percent) $null (S $script:RAIO_JANELA) 0.08
        $barra.Location = New-Object System.Drawing.Point((S 16), $Y.Value)
        $Form.Controls.Add($barra)
        $Y.Value += S 28

        if ($q.Reset) {
            $res = New-Object System.Windows.Forms.Label
            $res.Text = Format-Reset $q.Reset
            $res.Font = New-Object System.Drawing.Font($script:fontSmall, 9)
            $res.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
            $res.Location = New-Object System.Drawing.Point((S 16), $Y.Value)
            $res.AutoSize = $true
            $Form.Controls.Add($res)
            $Y.Value += S 20
        }
        $Y.Value += S 6
    }
    $Y.Value += S 10
}

# ------------------------------------------------------------
#  Flyout de hover (logos reais + barra do uso semanal)
# ------------------------------------------------------------

$script:hover = $null
$script:hoverAnchor = $null

function Show-HoverFlyout {
    if ($script:popup -and -not $script:popup.IsDisposed -and $script:popup.Visible) { return }
    if ($script:hover -and -not $script:hover.IsDisposed -and $script:hover.Visible) { return }

    $pos = [System.Windows.Forms.Cursor]::Position
    $script:esc = Get-EscalaEm $pos.X $pos.Y

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.StartPosition = 'Manual'
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 44)
    $f.ClientSize = New-Object System.Drawing.Size((S 252), (S 90))

    $itens = @(
        @{ Chave = 'claude'; Logo = $script:logoClaude; Result = $script:data.Claude },
        @{ Chave = 'gpt';    Logo = $script:logoGpt;    Result = $script:data.Codex }
    )

    # So as barras, com o icone da marca cavalgando a ponta do preenchimento
    $alturaLinha = S 34
    $largBarra = $f.ClientSize.Width - (S 24)

    $y = S 10
    foreach ($item in $itens) {
        $pct = Get-SemanalPercent $item.Result
        if ($null -ne $pct) {
            $icone = Get-LogoEscalado $item.Chave $item.Logo $alturaLinha
            $barra = New-BarraProgresso $largBarra $alturaLinha $pct $f.BackColor ('{0}%' -f $pct) $icone (S $script:RAIO_JANELA) 0.08
            $barra.Location = New-Object System.Drawing.Point((S 12), $y)
            $f.Controls.Add($barra)
        } else {
            $lblErr = New-Object System.Windows.Forms.Label
            $lblErr.Text = $item.Result.Error
            $lblErr.Font = New-Object System.Drawing.Font($script:fontText, 9)
            $lblErr.ForeColor = [System.Drawing.Color]::FromArgb(220, 120, 120)
            $lblErr.Location = New-Object System.Drawing.Point((S 12), ($y + (S 8)))
            $lblErr.AutoSize = $true
            $f.Controls.Add($lblErr)
        }

        $y += $alturaLinha + (S 8)
    }
    $f.ClientSize = New-Object System.Drawing.Size((S 252), ($y + (S 2)))

    # Cantos arredondados do Windows 11
    $pref = 2
    [Win32.Dwm]::DwmSetWindowAttribute($f.Handle, 33, [ref]$pref, 4) | Out-Null

    # Perto do cursor, acima da barra de tarefas, no monitor onde o mouse esta
    $area = ([System.Windows.Forms.Screen]::FromPoint($pos)).WorkingArea
    $cx = $pos.X - [int]($f.Width / 2)
    $cx = [math]::Max($area.Left + (S 8), [math]::Min($cx, $area.Right - $f.Width - (S 8)))
    $f.Location = New-Object System.Drawing.Point($cx, ($area.Bottom - $f.Height - (S 8)))

    # SW_SHOWNA: mostra sem ativar, para nao tirar o foco do que o usuario esta fazendo
    [Win32.NativeWin]::ShowWindow($f.Handle, 8) | Out-Null
    $script:hover = $f
    $script:hoverAnchor = $pos
}

function Hide-HoverFlyout {
    if ($script:hover -and -not $script:hover.IsDisposed) { $script:hover.Close() }
    $script:hover = $null
}

function Show-Popup {
    # Trava de reentrancia: cliques repetidos enquanto o painel e montado
    # ficam na fila de eventos e abririam uma janela cada
    if ($script:abrindoPopup) { return }
    $script:abrindoPopup = $true
    try {
        Build-Popup
    } finally {
        $script:abrindoPopup = $false
    }
}

function Build-Popup {
    Hide-HoverFlyout
    if ($script:popup -and -not $script:popup.IsDisposed) {
        $script:popup.Close()
        $script:popup = $null
    }

    # Nenhuma chamada de rede aqui: o painel abre na hora com os dados em cache
    # (a hora da coleta fica no canto superior direito). A atualizacao roda no
    # temporizador de fundo e no item "Atualizar agora" do menu.

    $pos = [System.Windows.Forms.Cursor]::Position
    $script:esc = Get-EscalaEm $pos.X $pos.Y

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.StartPosition = 'Manual'
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 44)
    $f.ClientSize = New-Object System.Drawing.Size((S 320), (S 400))
    $f.KeyPreview = $true

    # Cantos arredondados nativos do Windows 11
    $pref = 2
    [Win32.Dwm]::DwmSetWindowAttribute($f.Handle, 33, [ref]$pref, 4) | Out-Null

    $y = S 14

    # Data/hora da ultima atualizacao, no canto superior direito
    if ($script:data.Updated) {
        $carimbo = New-Object System.Windows.Forms.Label
        $carimbo.Text = $script:data.Updated.ToString('dd/MM HH:mm')
        $carimbo.Font = New-Object System.Drawing.Font($script:fontSmall, 9)
        $carimbo.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
        $carimbo.TextAlign = 'MiddleRight'
        $carimbo.Size = New-Object System.Drawing.Size((S 120), (S 20))
        $carimbo.Location = New-Object System.Drawing.Point(($f.ClientSize.Width - (S 120) - (S 16)), ($y + (S 3)))
        $f.Controls.Add($carimbo)
    }

    Add-ProviderSection $f ([ref]$y) 'Claude'  $script:data.Claude ([System.Drawing.Color]::FromArgb(217, 119, 87))  'claude' $script:logoClaude $script:nomeClaude
    Add-ProviderSection $f ([ref]$y) 'ChatGPT' $script:data.Codex  ([System.Drawing.Color]::FromArgb(116, 170, 156)) 'gpt'    $script:logoGpt    $script:nomeGpt

    $f.ClientSize = New-Object System.Drawing.Size((S 320), ($y + (S 4)))

    # Canto inferior direito do monitor onde o mouse esta, acima da barra de tarefas
    $area = ([System.Windows.Forms.Screen]::FromPoint($pos)).WorkingArea
    $f.Location = New-Object System.Drawing.Point(($area.Right - $f.Width - (S 12)), ($area.Bottom - $f.Height - (S 12)))

    $f.add_Deactivate({ $this.Close() })
    $f.add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $this.Close() } })

    $script:popup = $f
    $f.Show()
    $f.Activate()
}

# ------------------------------------------------------------
#  Iniciar com o Windows (chave Run do usuario atual)
# ------------------------------------------------------------

$script:runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Get-AutostartEnabled {
    $v = Get-ItemProperty -Path $script:runKey -Name $script:APP_NAME -ErrorAction SilentlyContinue
    return ($null -ne $v)
}

function Toggle-Autostart {
    param($MenuItem)
    if (Get-AutostartEnabled) {
        Remove-ItemProperty -Path $script:runKey -Name $script:APP_NAME -ErrorAction SilentlyContinue
        $MenuItem.Checked = $false
    } else {
        $launcher = Join-Path $PSScriptRoot 'Iniciar Usage A.I.vbs'
        Set-ItemProperty -Path $script:runKey -Name $script:APP_NAME -Value ('wscript.exe "{0}"' -f $launcher)
        $MenuItem.Checked = $true
    }
}

# ------------------------------------------------------------
#  Montagem: NotifyIcon, menu, timers, loop de mensagens
# ------------------------------------------------------------

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon = New-Object System.Drawing.Icon((Join-Path $PSScriptRoot 'UsageAI.ico'))
$script:notify.Visible = $true
$script:notify.Text = 'Usage A.I'

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miDetalhes = $menu.Items.Add('Ver detalhes')
$miAtualizar = $menu.Items.Add('Atualizar agora')
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miAuto = $menu.Items.Add('Iniciar com o Windows')
$miAuto.Checked = Get-AutostartEnabled
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miSair = $menu.Items.Add('Sair')

$miDetalhes.add_Click({ Show-Popup })
$miAtualizar.add_Click({ Start-Update })
$miAuto.add_Click({ Toggle-Autostart $miAuto })
$miSair.add_Click({
    $script:notify.Visible = $false
    $script:notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
$script:notify.ContextMenuStrip = $menu

$script:notify.add_MouseClick({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Popup }
})

# Hover: mostra o flyout enquanto o mouse esta sobre o icone; some quando sai.
# O fechamento e por distancia do ponto de abertura (nao por tempo): com o mouse
# parado sobre o icone nao chegam eventos de movimento, e um fechamento por tempo
# faria o flyout piscar (fecha -> mouse mexe 1px -> reabre).
$script:notify.add_MouseMove({ Show-HoverFlyout })

$hoverTimer = New-Object System.Windows.Forms.Timer
$hoverTimer.Interval = 300
$hoverTimer.add_Tick({
    if (-not ($script:hover -and -not $script:hover.IsDisposed -and $script:hover.Visible)) { return }
    $pos = [System.Windows.Forms.Cursor]::Position
    if ($script:hover.Bounds.Contains($pos)) { return }
    $dx = $pos.X - $script:hoverAnchor.X
    $dy = $pos.Y - $script:hoverAnchor.Y
    if ([math]::Sqrt($dx * $dx + $dy * $dy) -gt (S 70)) { Hide-HoverFlyout }
})
$hoverTimer.Start()

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $script:POLL_MS
$timer.add_Tick({ Start-Update })
$timer.Start()

# Recolhe o resultado da coleta em segundo plano assim que ela termina
$coletaTimer = New-Object System.Windows.Forms.Timer
$coletaTimer.Interval = 400
$coletaTimer.add_Tick({ Collect-Update })
$coletaTimer.Start()

# Animacao das listras: avanca a fase e repinta so as barras visiveis
$animaTimer = New-Object System.Windows.Forms.Timer
$animaTimer.Interval = 60
$animaTimer.add_Tick({
    $script:faseListras += 0.8
    for ($i = $script:barras.Count - 1; $i -ge 0; $i--) {
        $b = $script:barras[$i]
        if ($null -eq $b -or $b.IsDisposed) { $script:barras.RemoveAt($i); continue }
        if ($b.Visible -and $b.Tag.Pct -gt 0) {
            $b.Tag.Fase = $script:faseListras
            $b.Invalidate()
        }
    }
})
$animaTimer.Start()

Start-Update
[System.Windows.Forms.Application]::Run()
