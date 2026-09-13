Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Called by SetupBehavior.Tests.ps1, which supplies Assert-True.
& {
    $testRoot = Split-Path -Parent $PSScriptRoot
    $commonPath = Join-Path $testRoot 'modules/CodexSetup.Common.psm1'
    $pwshPath = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })

    function Invoke-CaptureRegressionCase {
        param([string]$ChildCode, [int]$InputLength = 0, [int]$TimeoutSeconds = 5)
        # An independent watchdog keeps a future pipe regression from hanging
        # the test suite itself. No real host setup command is invoked.
        $request = @{
            commonPath=$commonPath; executable=$pwshPath; childCode=$ChildCode
            inputLength=$InputLength; timeoutSeconds=$TimeoutSeconds
        } | ConvertTo-Json -Compress
        $encodedRequest = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($request))
        $workerCode = @'
$ErrorActionPreference = 'Stop'
$request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__REQUEST__')) | ConvertFrom-Json
Import-Module $request.commonPath -Force
$module = Get-Module 'CodexSetup.Common'
$captured = @(& $module {
    param($Request)
    $childCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Request.childCode))
    Invoke-SetupProcessCapture -FilePath $Request.executable -Arguments @('-NoProfile', '-EncodedCommand', $childCommand) `
        -StandardInput ('I' * $Request.inputLength) -TimeoutSeconds $Request.timeoutSeconds
} $request)
[pscustomobject]@{ count=$captured.Count; result=$captured[-1] } | ConvertTo-Json -Depth 4 -Compress
'@
        $workerCode = $workerCode.Replace('__REQUEST__', $encodedRequest)
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $pwshPath
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($workerCode)))) {
            [void]$start.ArgumentList.Add($argument)
        }
        $worker = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $worker.StandardOutput.ReadToEndAsync()
            $stderr = $worker.StandardError.ReadToEndAsync()
            if (-not $worker.WaitForExit(15000)) { throw 'Process capture exceeded its independent 15-second test watchdog.' }
            Assert-True ($worker.ExitCode -eq 0) "Capture worker failed: $($stderr.GetAwaiter().GetResult())"
            $actual = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json
            Assert-True ($actual.count -eq 1) 'Process capture must return exactly one result object, without async task values.'
            return $actual.result
        }
        finally {
            if (-not $worker.HasExited) { $worker.Kill($true); [void]$worker.WaitForExit(2000) }
            $worker.Dispose()
        }
    }

    $duplex = Invoke-CaptureRegressionCase -InputLength 2097152 -ChildCode @'
[Console]::Out.Write(('X' * 262144))
[Console]::Error.Write(('Y' * 262144))
$received = [Console]::In.ReadToEnd()
[Console]::Out.Write(' received=' + $received.Length)
'@
    Assert-True (-not $duplex.timedOut -and $duplex.exitCode -eq 0 -and $duplex.output.Contains('received=2097152')) 'Large stdin and output must make progress simultaneously.'
    Assert-True ($duplex.output.Contains(('X' * 262144)) -and $duplex.output.Contains(('Y' * 262144))) 'Both large output streams must be drained completely.'

    $blockedInput = Invoke-CaptureRegressionCase -InputLength 2097152 -TimeoutSeconds 1 -ChildCode 'Start-Sleep -Seconds 30'
    Assert-True ($blockedInput.timedOut -and $null -eq $blockedInput.exitCode -and $blockedInput.error -eq 'timeout:1s') 'A child that never reads stdin must hit the shared timeout.'
    Assert-True ($blockedInput.elapsedMs -lt 5000) 'The timeout must include blocked stdin writes, not only process exit.'

    $nonzero = Invoke-CaptureRegressionCase -ChildCode '[Console]::Error.Write("expected failure"); exit 7'
    Assert-True ($nonzero.exitCode -eq 7 -and -not $nonzero.timedOut -and $nonzero.output.Contains('expected failure')) 'Nonzero native exits must retain their exit code and output.'

    $pidPath = Join-Path ([IO.Path]::GetTempPath()) ('codex-capture-pids-' + [guid]::NewGuid().ToString('N') + '.txt')
    $treeCode = @'
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = '__PWSH__'
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
foreach ($argument in @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30')) { [void]$start.ArgumentList.Add($argument) }
$child = [Diagnostics.Process]::Start($start)
[IO.File]::WriteAllText('__PIDFILE__', "$PID`n$($child.Id)")
$child.WaitForExit()
'@
    $treeCode = $treeCode.Replace('__PWSH__', $pwshPath.Replace("'", "''")).Replace('__PIDFILE__', $pidPath.Replace("'", "''"))
    try {
        $tree = Invoke-CaptureRegressionCase -TimeoutSeconds 2 -ChildCode $treeCode
        Assert-True ($tree.timedOut) 'A waiting child process tree must time out.'
        Assert-True (Test-Path -LiteralPath $pidPath) 'The process-tree fixture did not start before its deadline.'
        foreach ($processId in @(Get-Content -LiteralPath $pidPath)) {
            $remaining = Get-Process -Id ([int]$processId) -ErrorAction SilentlyContinue
            if ($null -ne $remaining) {
                try { Assert-True ($remaining.WaitForExit(2000)) "Timed-out fixture process $processId survived tree termination." }
                finally { $remaining.Dispose() }
            }
        }
        # A root process can exit while a descendant still holds its pipes.
        # Reading EOF must share the deadline too; the fixture cleans up this
        # deliberately orphaned child because it no longer belongs to a live tree.
        $orphanCode = $treeCode.Replace('$child.WaitForExit()', 'exit 0')
        $openPipe = Invoke-CaptureRegressionCase -TimeoutSeconds 2 -ChildCode $orphanCode
        Assert-True ($openPipe.timedOut -and $openPipe.elapsedMs -lt 6000) 'Inherited output pipes must not outlive the total capture deadline.'
    }
    finally {
        if (Test-Path -LiteralPath $pidPath) {
            foreach ($processId in @(Get-Content -LiteralPath $pidPath)) {
                $remaining = Get-Process -Id ([int]$processId) -ErrorAction SilentlyContinue
                if ($null -ne $remaining) {
                    try { $remaining.Kill($true); [void]$remaining.WaitForExit(2000) } catch { }
                    finally { $remaining.Dispose() }
                }
            }
            Remove-Item -LiteralPath $pidPath -Force
        }
    }
    Write-Host 'PASS: process capture handles full pipes, blocked stdin, nonzero exits and child-tree cleanup within one deadline'
}
