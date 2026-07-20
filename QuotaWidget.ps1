# QuotaWidget.ps1 - Claude Code 额度桌面悬浮窗 v3
# 数据来源（按优先级）：
#   1) ~/.claude/quota-live.json —— CLI 终端会话的 statusline 喂数（桌面版不支持 statusline）
#   2) 官方用量接口 api.anthropic.com/api/oauth/usage —— 需要先用 claude auth login 登录一次 CLI
# 额度行按接口实际返回的维度动态生成；点击行标题可折叠/展开，状态会记住。
# 用法：wscript launch.vbs（无窗口启动）；或 powershell -File QuotaWidget.ps1 [-TestOnly]
param([switch]$TestOnly)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 单实例（自检模式跳过，避免与正在运行的悬浮窗互斥）
$script:mutex = $null
if (-not $TestOnly) {
    $script:mutex = New-Object System.Threading.Mutex($false, 'ClaudeQuotaWidgetSingleton')
    if (-not $script:mutex.WaitOne(0, $false)) { exit }
}

$script:feedPath  = Join-Path $env:USERPROFILE '.claude\quota-live.json'
$script:credPath  = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$script:statePath = Join-Path $PSScriptRoot 'widget-state.json'
$script:usageUrl  = 'https://api.anthropic.com/api/oauth/usage'
$script:tokenUrl  = 'https://console.anthropic.com/v1/oauth/token'
$script:clientId  = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'   # Claude Code 公开 OAuth client id

# 已知额度维度的中文名；接口出现未知维度时直接显示原始键名
$script:rowNames = @{
    five_hour        = '5 小时窗口'
    seven_day        = '每周额度'
    seven_day_fable  = 'Fable 每周'
    seven_day_mythos = 'Mythos 每周'
    seven_day_opus   = 'Opus 每周'
    seven_day_sonnet = 'Sonnet 每周'
}

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude 额度" SizeToContent="WidthAndHeight"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        FontFamily="Microsoft YaHei UI">
  <Window.Resources>
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Minimum" Value="0"/>
      <Setter Property="Maximum" Value="100"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border Background="#26FFFFFF" CornerRadius="4"/>
              <Border x:Name="PART_Track"/>
              <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}"
                      CornerRadius="4" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#8FFFFFFF"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Width" Value="24"/>
      <Setter Property="Height" Value="20"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#33FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid>
  <Border x:Name="MainCard" Width="248" CornerRadius="14" Background="#F21D1B26" Padding="16,12,16,10"
          BorderBrush="#30FFFFFF" BorderThickness="1">
    <StackPanel>
      <Grid Margin="0,0,0,10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="Claude 额度" Foreground="#E8E3D8"
                   FontWeight="Bold" FontSize="13" VerticalAlignment="Center"/>
        <Button Grid.Column="1" x:Name="BtnRefresh" Content="&#x27F3;" ToolTip="立即刷新"/>
        <Button Grid.Column="2" x:Name="BtnMin" Content="&#x2500;" ToolTip="最小化成小胶囊" Margin="2,0,0,0"/>
        <Button Grid.Column="3" x:Name="BtnClose" Content="&#x2715;" ToolTip="关闭" Margin="2,0,0,0"/>
      </Grid>

      <StackPanel x:Name="RowsHost"/>

      <TextBlock x:Name="TxtStatus" Text="" Foreground="#7F7B88" FontSize="10"
                 TextWrapping="Wrap"/>
    </StackPanel>
  </Border>
  <Border x:Name="PillCard" Visibility="Collapsed" CornerRadius="12" Background="#F21D1B26"
          BorderBrush="#30FFFFFF" BorderThickness="1" Padding="10,5" Cursor="Hand"
          ToolTip="点击展开">
    <StackPanel Orientation="Horizontal">
      <TextBlock Text="Claude" Foreground="#E8E3D8" FontSize="11" FontWeight="Bold" Margin="0,0,6,0"/>
      <TextBlock x:Name="PillPct" Text="--" FontSize="11" FontWeight="Bold" Foreground="#F2EFE9"/>
    </StackPanel>
  </Border>
  </Grid>
</Window>
'@

$script:win = [System.Windows.Markup.XamlReader]::Parse($xamlText)
foreach ($name in 'BtnRefresh','BtnMin','BtnClose','RowsHost','TxtStatus','MainCard','PillCard','PillPct') {
    Set-Variable -Name $name -Value $script:win.FindName($name) -Scope Script
}

$script:brushConverter = New-Object System.Windows.Media.BrushConverter
function Get-Brush([string]$hex) { $script:brushConverter.ConvertFromString($hex) }

function Get-BarColor([double]$pct) {
    if ($pct -ge 80) { '#E06A55' } elseif ($pct -ge 50) { '#E0B34C' } else { '#64B58A' }
}

# ================= 状态（位置 + 折叠 + 胶囊模式）=================
$script:collapsed = @{}
$script:isPill = $false

function Save-State {
    try {
        @{ left = $script:win.Left; top = $script:win.Top; collapsed = $script:collapsed; pill = [bool]$script:isPill } |
            ConvertTo-Json -Depth 3 | Set-Content -Path $script:statePath -Encoding UTF8
    } catch {}
}

# 尺寸变化时智能锚定：窗口靠屏幕哪半边，就固定哪一侧的边缘
# （放右下角时朝左上方展开/收起，放左上角时朝右下方，以此类推）
function Invoke-AnchoredResize([scriptblock]$Change) {
    $oldW = $script:win.ActualWidth
    $oldH = $script:win.ActualHeight
    & $Change
    $script:win.UpdateLayout()
    $newW = $script:win.ActualWidth
    $newH = $script:win.ActualHeight
    if ($oldW -gt 0 -and $newW -gt 0) {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $anchorRight  = ($script:win.Left + $oldW / 2) -gt ($wa.Left + $wa.Width / 2)
        $anchorBottom = ($script:win.Top  + $oldH / 2) -gt ($wa.Top  + $wa.Height / 2)
        if ($anchorRight)  { $script:win.Left = $script:win.Left + ($oldW - $newW) }
        if ($anchorBottom) { $script:win.Top  = $script:win.Top  + ($oldH - $newH) }
        if ($script:win.Left -lt $wa.Left) { $script:win.Left = $wa.Left }
        if ($script:win.Top  -lt $wa.Top)  { $script:win.Top  = $wa.Top }
    }
}

function Set-PillMode([bool]$pill) {
    $script:isPill = $pill
    Invoke-AnchoredResize {
        if ($pill) {
            $script:MainCard.Visibility = [System.Windows.Visibility]::Collapsed
            $script:PillCard.Visibility = [System.Windows.Visibility]::Visible
        } else {
            $script:PillCard.Visibility = [System.Windows.Visibility]::Collapsed
            $script:MainCard.Visibility = [System.Windows.Visibility]::Visible
        }
    }
    Save-State
}

# ================= 动态额度行 =================
$script:rows = [ordered]@{}

function Set-RowCollapsed([string]$key, [bool]$col) {
    $row = $script:rows[$key]
    if (-not $row) { return }
    $script:collapsed[$key] = $col
    $vis = if ($col) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
    $row.Bar.Visibility = $vis
    $row.Sub.Visibility = $vis
    $chev = if ($col) { [char]0x25B8 } else { [char]0x25BE }
    $row.Lbl.Text = ('{0} {1}' -f $chev, $row.Name)
}

function Toggle-Row([string]$key) {
    $cur = $false
    if ($script:collapsed.ContainsKey($key)) { $cur = [bool]$script:collapsed[$key] }
    Invoke-AnchoredResize { Set-RowCollapsed $key (-not $cur) }
    Save-State
}

function New-MetricRow([string]$key) {
    $name = $script:rowNames[$key]
    if (-not $name -and $key -like 'weekly_*') { $name = $key.Substring(7) + ' 每周' }
    if (-not $name) { $name = $key }

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)

    $g = New-Object System.Windows.Controls.Grid
    $g.Background = [System.Windows.Media.Brushes]::Transparent
    $g.Cursor = [System.Windows.Input.Cursors]::Hand
    $g.ToolTip = '点击折叠 / 展开'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $c2.Width = [System.Windows.GridLength]::Auto
    [void]$g.ColumnDefinitions.Add($c1)
    [void]$g.ColumnDefinitions.Add($c2)

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.FontSize = 12
    $lbl.Foreground = Get-Brush '#C9C5CF'
    $lbl.Text = ('{0} {1}' -f [char]0x25BE, $name)

    $pct = New-Object System.Windows.Controls.TextBlock
    $pct.FontSize = 12
    $pct.FontWeight = [System.Windows.FontWeights]::Bold
    $pct.Foreground = Get-Brush '#F2EFE9'
    $pct.Text = '--'
    [System.Windows.Controls.Grid]::SetColumn($pct, 1)

    [void]$g.Children.Add($lbl)
    [void]$g.Children.Add($pct)

    $bar = New-Object System.Windows.Controls.ProgressBar
    $bar.Margin = New-Object System.Windows.Thickness(0, 5, 0, 3)
    $bar.Foreground = Get-Brush '#64B58A'

    $sub = New-Object System.Windows.Controls.TextBlock
    $sub.FontSize = 10
    $sub.Foreground = Get-Brush '#9A96A3'

    [void]$panel.Children.Add($g)
    [void]$panel.Children.Add($bar)
    [void]$panel.Children.Add($sub)
    [void]$script:RowsHost.Children.Add($panel)

    $g.Tag = $key
    $g.Add_MouseLeftButtonDown({
        param($s, $e)
        $e.Handled = $true          # 别触发窗口拖动
        Toggle-Row ([string]$s.Tag)
    })

    $script:rows[$key] = @{ Key = $key; Name = $name; Panel = $panel; Lbl = $lbl; Pct = $pct; Bar = $bar; Sub = $sub }

    if ($script:collapsed.ContainsKey($key) -and [bool]$script:collapsed[$key]) {
        Set-RowCollapsed $key $true
    }
}

# ================= 数据源 1：本地喂数文件 =================
$script:lastWrite = [datetime]::MinValue
$script:data = $null

function Read-Feed {
    if (-not (Test-Path $script:feedPath)) { return ($null -ne $script:data) }
    $fi = Get-Item $script:feedPath
    if ($fi.LastWriteTime -eq $script:lastWrite -and $script:data) { return $true }
    try {
        $script:data = Get-Content $script:feedPath -Raw | ConvertFrom-Json
        $script:lastWrite = $fi.LastWriteTime
        return $true
    } catch {
        return ($null -ne $script:data)
    }
}

# ================= 数据源 2：官方用量接口 =================
function Get-OAuth {
    if (-not (Test-Path $script:credPath)) { return $null }
    try { (Get-Content $script:credPath -Raw | ConvertFrom-Json).claudeAiOauth } catch { $null }
}

function Save-OAuth($oauth) {
    try {
        $doc = Get-Content $script:credPath -Raw | ConvertFrom-Json
        $doc.claudeAiOauth = $oauth
        $tmp = $script:credPath + '.tmp'
        [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 8))
        Move-Item -Force $tmp $script:credPath
    } catch {}
}

function Update-Token($oauth) {
    $body = @{ grant_type = 'refresh_token'; refresh_token = $oauth.refreshToken; client_id = $script:clientId } | ConvertTo-Json
    # console.anthropic.com 的 WAF 会拦 PowerShell 默认 UA；anthropic-beta 头与官方 CLI 保持一致
    $hdr = @{ 'anthropic-beta' = 'oauth-2025-04-20'; 'User-Agent' = 'claude-quota-widget/1.0' }
    try {
        $resp = Invoke-RestMethod -Uri $script:tokenUrl -Method Post -ContentType 'application/json' -Body $body -Headers $hdr -TimeoutSec 8
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        if ($status -eq 429) { throw 'RATE' }
        elseif ($status -eq 400 -or $status -eq 401) { throw 'NOLOGIN' }  # refresh token 失效，需重新登录
        else { throw }
    }
    $oauth.accessToken = $resp.access_token
    if ($resp.refresh_token) { $oauth.refreshToken = $resp.refresh_token }
    if ($resp.expires_in)    { $oauth.expiresAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() + ([long]$resp.expires_in * 1000) }
    Save-OAuth $oauth
    return $oauth
}

function Get-UsageRaw {
    $oauth = Get-OAuth
    if (-not $oauth -or -not $oauth.accessToken) { throw 'NOLOGIN' }
    $nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    if ($oauth.expiresAt -and (([long]$oauth.expiresAt) - $nowMs) -lt 120000) {
        $oauth = Update-Token $oauth
    }
    $headers = @{ Authorization = 'Bearer ' + $oauth.accessToken; 'anthropic-beta' = 'oauth-2025-04-20'; 'User-Agent' = 'claude-quota-widget/1.0' }
    try {
        return (Invoke-RestMethod -Uri $script:usageUrl -Headers $headers -TimeoutSec 8)
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        if ($status -eq 401) {
            $oauth = Update-Token $oauth
            $headers.Authorization = 'Bearer ' + $oauth.accessToken
            return (Invoke-RestMethod -Uri $script:usageUrl -Headers $headers -TimeoutSec 8)
        } elseif ($status -eq 429) { throw 'RATE' } else { throw }
    }
}

function ConvertTo-Feed($r) {
    $out = [ordered]@{ updated_at = [DateTimeOffset]::Now.ToUnixTimeSeconds() }

    # 首选 limits 数组：包含 session / weekly_all / weekly_scoped（按模型细分，如 Fable）
    if ($r.limits) {
        foreach ($L in $r.limits) {
            if ($null -eq $L.percent) { continue }
            $key = [string]$L.kind
            switch ($L.kind) {
                'session'    { $key = 'five_hour' }
                'weekly_all' { $key = 'seven_day' }
                'weekly_scoped' {
                    $mn = $null
                    try { $mn = $L.scope.model.display_name } catch {}
                    if ($mn) { $key = 'weekly_' + $mn } else { $key = 'weekly_scoped' }
                }
            }
            if ($out.Contains($key)) { continue }
            $re = 0L
            if ($L.resets_at) { $re = ([DateTimeOffset]::Parse([string]$L.resets_at)).ToUnixTimeSeconds() }
            $out[$key] = [ordered]@{ used_percentage = [double]$L.percent; resets_at = $re }
        }
    }

    # 兜底：老式顶层窗口字段（five_hour / seven_day / seven_day_xxx）
    if ($out.Keys.Count -le 1) {
        foreach ($p in $r.PSObject.Properties) {
            $w = $p.Value
            if ($null -eq $w -or $w -is [string] -or $w -is [ValueType]) { continue }
            $pct = $null
            if ($null -ne $w.used_percentage) { $pct = [double]$w.used_percentage }
            elseif ($null -ne $w.utilization) { $pct = [double]$w.utilization }
            if ($null -eq $pct) { continue }
            $re = 0L
            if ($w.resets_at) {
                if ($w.resets_at -is [string]) { $re = ([DateTimeOffset]::Parse($w.resets_at)).ToUnixTimeSeconds() }
                else { $re = [long]$w.resets_at }
            }
            $out[$p.Name] = [ordered]@{ used_percentage = $pct; resets_at = $re }
        }
    }
    if ($out.Keys.Count -gt 1) {
        try {
            $tmp = $script:feedPath + '.w.tmp'
            [IO.File]::WriteAllText($tmp, ($out | ConvertTo-Json -Depth 4))
            Move-Item -Force $tmp $script:feedPath
            $script:lastWrite = (Get-Item $script:feedPath).LastWriteTime
        } catch {}
        $script:data = ($out | ConvertTo-Json -Depth 4 | ConvertFrom-Json)
        return $true
    }
    return $false
}

function Get-UsageFromApi { return (ConvertTo-Feed (Get-UsageRaw)) }

# ================= 渲染 =================
function Set-Row($row, $info, [bool]$weekly) {
    $bar = $row.Bar; $txtPct = $row.Pct; $txtSub = $row.Sub
    if (-not $info -or $null -eq $info.used_percentage) {
        $txtPct.Text = '--'; $bar.Value = 0; $txtSub.Text = '暂无数据'
        return
    }
    $pct = [double]$info.used_percentage
    $now = [DateTimeOffset]::Now
    $resetEpoch = 0L
    if ($info.resets_at) { $resetEpoch = [long]$info.resets_at }

    if ($resetEpoch -gt 0) {
        $resetTime = [DateTimeOffset]::FromUnixTimeSeconds($resetEpoch).ToLocalTime()
        if ($now -ge $resetTime) {
            $bar.Value = 0
            $bar.Foreground = Get-Brush '#64B58A'
            $txtPct.Text = '0%'
            $txtSub.Text = '窗口已重置'
            return
        }
    }

    $bar.Value = [math]::Min($pct, 100)
    $bar.Foreground = Get-Brush (Get-BarColor $pct)
    $txtPct.Text = ('{0:N0}%' -f $pct)

    if ($resetEpoch -gt 0) {
        $left = $resetTime - $now
        if ($weekly) {
            $dayNames = @('日','一','二','三','四','五','六')
            $when = ('周{0} {1:HH:mm}' -f $dayNames[[int]$resetTime.DayOfWeek], $resetTime)
            if ($left.TotalDays -ge 1) {
                $txtSub.Text = ('{0} 重置（剩 {1} 天 {2} 小时）' -f $when, [int][math]::Floor($left.TotalDays), $left.Hours)
            } else {
                $txtSub.Text = ('{0} 重置（剩 {1} 小时）' -f $when, [int][math]::Floor($left.TotalHours))
            }
        } else {
            $txtSub.Text = ('{0:HH:mm} 重置（剩 {1} 小时 {2} 分）' -f $resetTime, [int][math]::Floor($left.TotalHours), $left.Minutes)
        }
    } else {
        $txtSub.Text = ''
    }
}

$script:lastApiTry = [DateTimeOffset]::MinValue
$script:apiError = $null

function Update-Widget([switch]$Force) {
    [void](Read-Feed)

    $feedFresh = $false
    if ($script:data -and $script:data.updated_at) {
        $age = [DateTimeOffset]::Now.ToUnixTimeSeconds() - [long]$script:data.updated_at
        $feedFresh = ($age -lt 120)
    }

    if ($Force -or -not $feedFresh) {
        $nowT = [DateTimeOffset]::Now
        $throttle = if ($Force) { 5 } else { 300 }
        if (($nowT - $script:lastApiTry).TotalSeconds -ge $throttle) {
            $script:lastApiTry = $nowT
            try {
                [void](Get-UsageFromApi)
                $script:apiError = $null
            } catch {
                switch ($_.Exception.Message) {
                    'NOLOGIN' { $script:apiError = 'NOLOGIN' }
                    'RATE'    { $script:apiError = 'RATE'; $script:lastApiTry = $nowT.AddSeconds(600) }  # 被限流：约 15 分钟后再试
                    default   { $script:apiError = 'NET' }
                }
            }
        }
    } else {
        $script:apiError = $null
    }

    if (-not $script:data) {
        $script:PillPct.Text = '--'
        if ($script:apiError -eq 'NOLOGIN') {
            $script:TxtStatus.Text = '需要一次性登录：见 README 的 claude auth login 步骤'
        } elseif ($script:apiError -eq 'RATE') {
            $script:TxtStatus.Text = '接口限流中，稍后自动重试'
        } elseif ($script:apiError -eq 'NET') {
            $script:TxtStatus.Text = '接口请求失败，稍后自动重试'
        } else {
            $script:TxtStatus.Text = '等待数据…'
        }
        return
    }

    # 按数据里的维度动态建行：five_hour、seven_day 优先，其余按字母序
    $keys = @($script:data.PSObject.Properties.Name | Where-Object { $_ -ne 'updated_at' })
    $ordered = @()
    foreach ($k in @('five_hour','seven_day')) { if ($keys -contains $k) { $ordered += $k } }
    $ordered += @($keys | Where-Object { $_ -ne 'five_hour' -and $_ -ne 'seven_day' } | Sort-Object)

    foreach ($k in $ordered) {
        if (-not $script:rows.Contains($k)) { New-MetricRow $k }
        Set-Row $script:rows[$k] $script:data.$k ($k -ne 'five_hour')
    }

    try {
        $upd = [DateTimeOffset]::FromUnixTimeSeconds([long]$script:data.updated_at).ToLocalTime()
        $ageMin = ([DateTimeOffset]::Now - $upd).TotalMinutes
        $suffix = ''
        if ($script:apiError -eq 'NET') { $suffix = '（刷新失败，显示上次数据）' }
        elseif ($script:apiError -eq 'RATE') { $suffix = '（接口限流，显示上次数据）' }
        elseif ($script:apiError -eq 'NOLOGIN') { $suffix = '（登录已失效，请重新 claude auth login）' }
        if ($ageMin -ge 10) {
            $script:TxtStatus.Text = ('数据截至 {0:MM-dd HH:mm}{1}' -f $upd, $suffix)
        } else {
            $script:TxtStatus.Text = ('更新于 {0:HH:mm}{1}' -f $upd, $suffix)
        }
    } catch { $script:TxtStatus.Text = '' }

    # 胶囊模式的迷你显示：5 小时窗口百分比（含"已过重置点归零"逻辑，和大面板一致）
    try {
        $fh = $script:data.five_hour
        if ($fh -and $null -ne $fh.used_percentage) {
            $p = [double]$fh.used_percentage
            $re = 0L
            if ($fh.resets_at) { $re = [long]$fh.resets_at }
            if ($re -gt 0 -and [DateTimeOffset]::Now -ge [DateTimeOffset]::FromUnixTimeSeconds($re)) { $p = 0 }
            $script:PillPct.Text = ('{0:N0}%' -f $p)
            $script:PillPct.Foreground = Get-Brush (Get-BarColor $p)
        }
        $script:PillCard.ToolTip = '点击展开 · ' + $script:TxtStatus.Text
    } catch {}
}

# ---- 位置/折叠/胶囊状态：恢复上次，默认右上角 ----
$wa = [System.Windows.SystemParameters]::WorkArea
$script:win.Left = $wa.Right - 248 - 18   # SizeToContent 下 Width 是 NaN，用主卡片宽度常量
$script:win.Top  = $wa.Top + 16
$script:startPill = $false
if (Test-Path $script:statePath) {
    try {
        $st = Get-Content $script:statePath -Raw | ConvertFrom-Json
        $vs = [System.Windows.SystemParameters]::VirtualScreenWidth
        if ($st.left -ge -50 -and $st.left -lt ($vs - 50) -and $st.top -ge -20) {
            $script:win.Left = [double]$st.left
            $script:win.Top  = [double]$st.top
        }
        if ($st.collapsed) {
            foreach ($p in $st.collapsed.PSObject.Properties) {
                $script:collapsed[$p.Name] = [bool]$p.Value
            }
        }
        if ($st.pill) { $script:startPill = $true }
    } catch {}
}

# ---- 事件 ----
$script:win.Add_MouseLeftButtonDown({ try { $script:win.DragMove() } catch {} })
$script:BtnClose.Add_Click({ $script:win.Close() })
$script:BtnRefresh.Add_Click({ $script:lastWrite = [datetime]::MinValue; Update-Widget -Force })
$script:BtnMin.Add_Click({ Set-PillMode $true })
# 胶囊：拖动=移动窗口，原地点击=展开（位移小于 3px 视为点击）
$script:PillCard.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $l0 = $script:win.Left; $t0 = $script:win.Top
    try { $script:win.DragMove() } catch {}
    if ([math]::Abs($script:win.Left - $l0) -lt 3 -and [math]::Abs($script:win.Top - $t0) -lt 3) {
        Set-PillMode $false
    } else {
        Save-State
    }
})
$script:win.Add_Closing({ Save-State })

if ($script:startPill) { Set-PillMode $true }

# ---- 定时刷新：本地文件每 5 秒查一次；接口最多每 60 秒调一次 ----
$script:timer = New-Object System.Windows.Threading.DispatcherTimer
$script:timer.Interval = [TimeSpan]::FromSeconds(5)
$script:timer.Add_Tick({ Update-Widget })

Update-Widget -Force

if ($TestOnly) {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    try {
        $raw = Get-UsageRaw
        Write-Output ('api keys: ' + ($raw.PSObject.Properties.Name -join ', '))
        foreach ($p in $raw.PSObject.Properties) {
            Write-Output ('  ' + $p.Name + ' = ' + ($p.Value | ConvertTo-Json -Compress -Depth 4))
        }
    } catch { Write-Output ('api dump failed: ' + $_.Exception.Message) }
    foreach ($k in @($script:rows.Keys)) {
        $r = $script:rows[$k]
        Write-Output ('row [' + $k + '] ' + $r.Pct.Text + ' | ' + $r.Sub.Text + ' | bar=' + $r.Bar.Value)
    }
    Write-Output ('sta: ' + $script:TxtStatus.Text)
    exit 0
}

$script:timer.Start()
[void]$script:win.ShowDialog()
$script:timer.Stop()
if ($script:mutex) { $script:mutex.ReleaseMutex() }
