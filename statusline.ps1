# statusline.ps1 - Claude Code statusline feed script (ASCII only, runs on every statusline refresh)
# Reads session JSON from stdin, writes ALL rate-limit windows to ~/.claude/quota-live.json,
# and prints a one-line status for the in-app statusline.

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $d = $raw | ConvertFrom-Json } catch { exit 0 }

$now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
$out = [ordered]@{ updated_at = $now }

$rl = $d.rate_limits
if ($rl) {
    foreach ($p in $rl.PSObject.Properties) {
        $w = $p.Value
        if ($null -eq $w -or $null -eq $w.used_percentage) { continue }
        $out[$p.Name] = [ordered]@{
            used_percentage = $w.used_percentage
            resets_at       = $w.resets_at
        }
    }
}

# Only persist when we actually have rate limit data, so a session without it
# never wipes the last good snapshot.
if ($out.Keys.Count -gt 1) {
    $dest = Join-Path $env:USERPROFILE '.claude\quota-live.json'
    $tmp  = "$dest.$PID.tmp"
    try {
        [IO.File]::WriteAllText($tmp, ($out | ConvertTo-Json -Depth 4))
        Move-Item -Force $tmp $dest
    } catch {
        try { Remove-Item -Force $tmp -ErrorAction SilentlyContinue } catch {}
    }
}

# Visible statusline text (ASCII to avoid console encoding issues)
$parts = @()
if ($d.model.display_name) { $parts += $d.model.display_name }
if ($rl.five_hour.used_percentage -ne $null) { $parts += ('5h {0:N0}%' -f [double]$rl.five_hour.used_percentage) }
if ($rl.seven_day.used_percentage -ne $null) { $parts += ('7d {0:N0}%' -f [double]$rl.seven_day.used_percentage) }
if ($d.context_window.used_percentage -ne $null) { $parts += ('ctx {0:N0}%' -f [double]$d.context_window.used_percentage) }
Write-Output ($parts -join ' | ')
