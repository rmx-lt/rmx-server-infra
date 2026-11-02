# MQTT tests for mqtt.rmx.lt, run from the Windows PC over the internet.
# Needs the Mosquitto clients for Windows (C:\Program Files\mosquitto) and `ssh rmx-vps`.
# Run from the repo folder:
#   powershell -ExecutionPolicy Bypass -File services\mosquitto\tests\mqtt-tests.ps1
# Passwords are read from the server into memory only and never printed.
# Uses the logins app + mower-01 and the topics mower/mower-01/... and mower/mower-02/...
$ErrorActionPreference = 'Continue'
$H = 'mqtt.rmx.lt'
$bin = 'C:\Program Files\mosquitto'
$sub = "$bin\mosquitto_sub.exe"; $pub = "$bin\mosquitto_pub.exe"

# The Windows Mosquitto clients can't read the Windows certificate store
# (--tls-use-os-certs finds nothing and fails with "protocol error"), so export
# Windows' trusted root CAs to a PEM file and pass it with --cafile.
$roots = "$env:TEMP\windows-roots.pem"
$sb = [Text.StringBuilder]::new()
Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root | Sort-Object Thumbprint -Unique | ForEach-Object {
    [void]$sb.AppendLine('-----BEGIN CERTIFICATE-----')
    [void]$sb.AppendLine([Convert]::ToBase64String($_.RawData, 'InsertLineBreaks'))
    [void]$sb.AppendLine('-----END CERTIFICATE-----')
}
[IO.File]::WriteAllText($roots, $sb.ToString().Replace("`r`n", "`n"))
$tls = @('-h', $H, '-p', '8883', '--cafile', $roots, '-V', '5')
$results = @()
function Result($name, $ok, $detail) {
    $script:results += [pscustomobject]@{ Test = $name; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Detail = $detail }
}

# Passwords: read from the server into memory only, never printed.
$pw = @{}
ssh -o BatchMode=yes rmx-vps 'sudo cat /opt/rmx-vps/services/mosquitto/data/credentials.txt' |
    Where-Object { $_ -notmatch '^#' -and $_ } | ForEach-Object { $u, $p = $_ -split ' ', 2; $pw[$u] = $p }
if (-not $pw['app'] -or -not $pw['mower-01']) { throw 'could not read credentials' }
$app = @('-u', 'app', '-P', $pw['app']); $m1 = @('-u', 'mower-01', '-P', $pw['mower-01'])

# Start a subscriber as its own process (output to a temp file).
# mosquitto_sub's -W timeout doesn't work on Windows, so Stop-Sub waits and kills it.
$n = 0
function Start-Sub($authArgs, $topic, $count = 1) {
    $script:n++; $f = "$env:TEMP\mqtt-test-$script:n.out"
    $a = ($tls + $authArgs + @('-t', $topic, '-C', $count, '-v')) | ForEach-Object { if ($_ -match ' ') { "`"$_`"" } else { $_ } }
    $p = Start-Process $sub -ArgumentList $a -RedirectStandardOutput $f -RedirectStandardError "$f.err" -NoNewWindow -PassThru
    Start-Sleep 3   # let it connect and subscribe
    [pscustomobject]@{ P = $p; F = $f }
}
function Stop-Sub($s, $wait = 8) {
    if (-not $s.P.WaitForExit($wait * 1000)) { $s.P.Kill(); $s.P.WaitForExit() }
    $out = (Get-Content $s.F, "$($s.F).err" -ErrorAction SilentlyContinue) -join ' '
    Remove-Item $s.F, "$($s.F).err" -ErrorAction SilentlyContinue
    $out
}

# 1. TLS: certificate chain validated by Windows (.NET SslStream, system trust store)
try {
    $tcp = [Net.Sockets.TcpClient]::new($H, 8883)
    $ssl = [Net.Security.SslStream]::new($tcp.GetStream(), $false)
    $ssl.AuthenticateAsClient($H)   # throws if chain or hostname is invalid
    $c = [Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate
    Result 'TLS chain valid for mqtt.rmx.lt' $true "$($ssl.SslProtocol), $($c.Subject), issuer $($c.Issuer -replace ',.*'), until $($c.NotAfter.ToString('yyyy-MM-dd'))"
    $ssl.Dispose(); $tcp.Dispose()
} catch { Result 'TLS chain valid for mqtt.rmx.lt' $false $_.Exception.Message }

# 1b. TLS 1.1 must be refused
try {
    $tcp = [Net.Sockets.TcpClient]::new($H, 8883)
    $ssl = [Net.Security.SslStream]::new($tcp.GetStream(), $false)
    $ssl.AuthenticateAsClient($H, $null, [Security.Authentication.SslProtocols]::Tls11, $false)
    Result 'TLS 1.1 refused' $false "negotiated $($ssl.SslProtocol)"
} catch { Result 'TLS 1.1 refused' $true 'handshake failed (as expected)' } finally { if ($tcp) { $tcp.Dispose() } }

# 2. mower-01 publishes telemetry, app receives it
$j = Start-Sub $app 'mower/+/telemetry'
& $pub @tls @m1 -t 'mower/mower-01/telemetry' -m '{"test":"telemetry"}' -q 1 2>&1 | Out-Null
$out = Stop-Sub $j
Result 'mower-01 publishes own telemetry' ("$out" -match 'mower/mower-01/telemetry .*telemetry') "$out"

# 3. app sends a command, mower-01 (subscribed to its cmd topic) receives it
$j = Start-Sub $m1 'mower/mower-01/cmd'
& $pub @tls @app -t 'mower/mower-01/cmd' -m '{"id":"t1","cmd":"noop"}' -q 1 2>&1 | Out-Null
$out = Stop-Sub $j
Result 'mower-01 subscribes to own cmd' ("$out" -match 'mower/mower-01/cmd .*noop') "$out"

# 4. Retained status: mower-01 publishes retained "online"; a later subscriber gets it
& $pub @tls @m1 -t 'mower/mower-01/status' -m 'online' -r -q 1 2>&1 | Out-Null
$out = Stop-Sub (Start-Sub $app 'mower/mower-01/status') 5
Result 'retained status kept' ("$out" -match 'status online') "$out"

# 5. mower-01 listens on mower-02's cmd topic (and on all of mower/#): the app's command must not reach it
$j1 = Start-Sub $m1 'mower/mower-02/cmd'
& $pub @tls @app -t 'mower/mower-02/cmd' -m 'secret-cmd' -q 1 2>&1 | Out-Null
$out = Stop-Sub $j1 5
Result 'mower-01 gets nothing from mower-02 topics' (-not ("$out" -match 'secret-cmd')) "mower-01 saw: $(if ($out) { $out } else { 'nothing' })"
$j1 = Start-Sub $m1 'mower/#'
& $pub @tls @app -t 'mower/mower-02/telemetry' -m 'other-mower' -q 1 2>&1 | Out-Null
$out = Stop-Sub $j1 5
Result 'mower-01 wildcard sees no other mower' (-not ("$out" -match 'other-mower')) "mower-01 saw: $(if ($out) { $out } else { 'nothing' })"

# 6. mower-01 publishes to mower-02's topic: refused (app listens to check nothing arrives)
$j = Start-Sub $app 'mower/mower-02/#'
$out = & $pub @tls @m1 -t 'mower/mower-02/telemetry' -m 'spoof' -q 1 2>&1
$got = Stop-Sub $j 5
Result 'mower-01 cannot publish to mower-02' (-not ("$got" -match 'spoof')) "pub said: $(if ($out) { $out } else { '(nothing)' }) | app saw: $(if ("$got" -match 'spoof') { 'spoof!' } else { 'nothing' })"

# 7. Anonymous refused
$out = & $pub @tls -t 'mower/mower-01/telemetry' -m 'anon' 2>&1
Result 'anonymous refused' ("$out" -match 'not authori|refused|bad user') "$out"

# 8. Wrong password refused
$out = & $pub @tls -u 'mower-01' -P 'wrong-password' -t 'mower/mower-01/telemetry' -m 'x' 2>&1
Result 'wrong password refused' ("$out" -match 'not authori|refused|bad user') "$out"

# 9. Client ID is forced to the username: a 2nd mower-01 login replaces the 1st
$j = Start-Sub ($m1 + @('-i', 'first')) 'mower/mower-01/cmd'
& $pub @tls @m1 -i 'second' -t 'mower/mower-01/telemetry' -m 'x' 2>&1 | Out-Null
$null = Stop-Sub $j 3
# Filtered here, not with grep on the server: Windows PowerShell 5.1 mangles
# double quotes inside native-command arguments.
$log = ssh -o BatchMode=yes rmx-vps 'docker compose -f /opt/rmx-vps/services/compose.yaml logs --no-log-prefix --since 30s mosquitto 2>&1' |
    Select-String -Pattern 'already connected|closing old|session taken over' |
    Select-Object -Last 2 | ForEach-Object { $_.Line -replace '\d+\.\d+\.\d+\.\d+', 'PC-IP' }
Result 'client ID forced to username' ("$log" -match 'mower-01') "server log: $log"

# 10. Plain MQTT port 1883 not reachable from the internet
$t = Test-NetConnection $H -Port 1883 -WarningAction SilentlyContinue
Result 'port 1883 closed' (-not $t.TcpTestSucceeded) "TcpTestSucceeded=$($t.TcpTestSucceeded)"

# Clean up: clear the retained test status
& $pub @tls @m1 -t 'mower/mower-01/status' -n -r -q 1 2>&1 | Out-Null
$pw.Clear()

$results | Format-Table -AutoSize -Wrap
