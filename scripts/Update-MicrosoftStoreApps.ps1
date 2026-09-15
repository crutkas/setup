#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateRange(2, 20)]
    [int]$MaxPasses = 8,

    [ValidateRange(1, 120)]
    [int]$CommandTimeoutMinutes = 20,

    [ValidateRange(1, 300)]
    [int]$SettleSeconds = 15,

    [ValidateRange(1, 16)]
    [int]$ThrottleLimit = 4,

    [switch]$SkipStoreBootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$storeAliasPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\store.exe'
$timeoutSeconds = $CommandTimeoutMinutes * 60

function Format-ExitCode {
    param([int]$ExitCode)
    $unsigned = [int64]$ExitCode -band 0xFFFFFFFF
    return '{0} (0x{1:X8})' -f $ExitCode, $unsigned
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [bool]$ShowOutput = $true,
        [string]$StandardInput = ''
    )

    $process = $null
    try {
        Write-Host "==> $Activity"
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $FilePath
        $startInfo.Arguments = (($ArgumentList | ForEach-Object {
            '"' + ([string]$_).Replace('"', '\"') + '"'
        }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo

        if (-not $process.Start()) {
            throw "Could not start '$FilePath'."
        }

        # Start async reads via .NET Tasks *before* WaitForExit. This is
        # the standard deadlock-safe pattern: it doesn't depend on the
        # PowerShell event queue (Register-ObjectEvent was unreliable
        # here), and the tasks complete on their own once each stream
        # closes at process exit.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if ($StandardInput.Length -gt 0) {
            $process.StandardInput.Write($StandardInput)
        }
        $process.StandardInput.Close()

        $started = Get-Date
        $nextHeartbeat = 15
        while (-not $process.WaitForExit(1000)) {
            $elapsedSeconds = [int]((Get-Date) - $started).TotalSeconds
            if ($elapsedSeconds -ge $TimeoutSeconds) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                throw "$Activity timed out after $TimeoutSeconds seconds."
            }
            if ($elapsedSeconds -ge $nextHeartbeat) {
                Write-Host "    Still running ($elapsedSeconds seconds elapsed)..."
                $nextHeartbeat += 15
            }
        }

        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        if ($ShowOutput -and $stdout.Trim().Length -gt 0) {
            Write-Host $stdout.TrimEnd()
        }
        if ($ShowOutput -and $stderr.Trim().Length -gt 0) {
            Write-Warning $stderr.TrimEnd()
        }

        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Output   = ($stdout + [Environment]::NewLine + $stderr).Trim()
        }
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Invoke-ElevatedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    # Some tools (e.g. wsreset.exe) have a manifest that requires
    # elevation. CreateProcess cannot auto-elevate while redirecting
    # stdio, so this path uses ShellExecute + the "runas" verb instead;
    # that means no captured output, only an exit code.
    Write-Host "==> $Activity (elevated; a UAC prompt may appear)"

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (($ArgumentList | ForEach-Object {
        '"' + ([string]$_).Replace('"', '\"') + '"'
    }) -join ' ')
    $startInfo.UseShellExecute = $true
    $startInfo.Verb = 'runas'

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        if ($null -eq $process) {
            throw "Could not start '$FilePath'."
        }

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw "$Activity timed out after $TimeoutSeconds seconds."
        }

        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Output   = ''
        }
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Get-StorePackage {
    return Get-AppxPackage -Name Microsoft.WindowsStore -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
}

function Wait-StoreCli {
    param([ValidateRange(1, 1800)][int]$TimeoutSeconds = 300)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $package = Get-StorePackage
        if ($null -ne $package -and
            (Test-Path -LiteralPath $storeAliasPath -PathType Leaf)) {
            return $storeAliasPath
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    throw "Microsoft Store CLI did not appear within $TimeoutSeconds seconds."
}

function ConvertTo-NormalizedLines {
    param([string]$Text)
    $withoutAnsi = [regex]::Replace(
        $Text,
        "$([char]27)\[[0-?]*[ -/]*[@-~]",
        ''
    )
    return @(
        $withoutAnsi -split "(`r`n|`n|`r)" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_.Length -gt 0 }
    )
}

function Get-StoreUpdateNames {
    param([Parameter(Mandatory)][string]$Text)

    $withoutAnsi = [regex]::Replace(
        $Text,
        "$([char]27)\[[0-?]*[ -/]*[@-~]",
        ''
    )
    $tableSeparatorPattern = '[|' + [regex]::Escape([string][char]0x2502) + ']'
    $names = [Collections.Generic.List[string]]::new()
    $currentNameParts = [Collections.Generic.List[string]]::new()

    foreach ($line in ($withoutAnsi -split "(`r`n|`n|`r)")) {
        if ($line -notmatch $tableSeparatorPattern) {
            continue
        }

        $columns = $line -split $tableSeparatorPattern
        if ($columns.Count -lt 6) {
            continue
        }

        $namePart = $columns[1].Trim()
        $version = $columns[3].Trim()
        $date = $columns[4].Trim()
        $startsNewApp = $version -match '\d' -and $date -match '\d'

        if ($startsNewApp) {
            if ($currentNameParts.Count -gt 0) {
                $names.Add(($currentNameParts -join ' ').Trim())
                $currentNameParts.Clear()
            }
            if ($namePart.Length -gt 0) {
                $currentNameParts.Add($namePart)
            }
        }
        elseif ($currentNameParts.Count -gt 0 -and
            $version.Length -eq 0 -and $date.Length -eq 0 -and
            $namePart.Length -gt 0) {
            $currentNameParts.Add($namePart)
        }
    }

    if ($currentNameParts.Count -gt 0) {
        $names.Add(($currentNameParts -join ' ').Trim())
    }

    return @($names | Where-Object { $_.Length -gt 0 } | Select-Object -Unique)
}

function Invoke-StoreUpdatesInParallel {
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string[]]$AppNames,
        [Parameter(Mandatory)][int]$ThrottleLimit,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $queue = [Collections.Generic.Queue[string]]::new()
    foreach ($appName in $AppNames) {
        $queue.Enqueue($appName)
    }

    $jobScript = {
        param([string]$StorePath, [string]$AppName)
        $ErrorActionPreference = 'Stop'
        try {
            $output = (& $StorePath update $AppName --apply 2>&1 | Out-String).Trim()
            [pscustomobject]@{
                AppName  = $AppName
                ExitCode = [int]$LASTEXITCODE
                Output   = $output
            }
        }
        catch {
            [pscustomobject]@{
                AppName  = $AppName
                ExitCode = -1
                Output   = $_.Exception.Message
            }
        }
    }

    $running = @()
    $results = @()
    $nextHeartbeat = (Get-Date).AddSeconds(15)

    try {
        while ($queue.Count -gt 0 -or $running.Count -gt 0) {
            while ($queue.Count -gt 0 -and $running.Count -lt $ThrottleLimit) {
                $appName = $queue.Dequeue()
                Write-Host "    Starting update request: $appName"
                $job = Start-Job -ScriptBlock $jobScript `
                    -ArgumentList $StorePath, $appName
                Add-Member -InputObject $job -NotePropertyName StoreAppName `
                    -NotePropertyValue $appName
                Add-Member -InputObject $job -NotePropertyName StoreStartedAt `
                    -NotePropertyValue (Get-Date)
                $running += $job
            }

            $completed = @($running | Where-Object {
                $_.State -in @('Completed', 'Failed', 'Stopped')
            })
            foreach ($job in $completed) {
                $payload = @(Receive-Job -Job $job -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.PSObject.Properties.Name -contains 'ExitCode'
                    }) | Select-Object -Last 1

                if ($null -eq $payload) {
                    $payload = [pscustomobject]@{
                        AppName  = $job.StoreAppName
                        ExitCode = -1
                        Output   = "Background job ended in state '$($job.State)'."
                    }
                }

                Write-Host ''
                Write-Host "---- $($payload.AppName) ----"
                if (-not [string]::IsNullOrWhiteSpace($payload.Output)) {
                    Write-Host $payload.Output
                }
                if ($payload.ExitCode -eq 0) {
                    Write-Host "[REQUESTED] $($payload.AppName)"
                }
                else {
                    Write-Warning "$($payload.AppName) returned $(Format-ExitCode $payload.ExitCode)."
                }

                $results += $payload
                $running = @($running | Where-Object { $_.Id -ne $job.Id })
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }

            $timedOut = @($running | Where-Object {
                ((Get-Date) - $_.StoreStartedAt).TotalSeconds -ge $TimeoutSeconds
            })
            foreach ($job in $timedOut) {
                Stop-Job -Job $job -ErrorAction SilentlyContinue
                $results += [pscustomobject]@{
                    AppName  = $job.StoreAppName
                    ExitCode = -1
                    Output   = "Timed out after $TimeoutSeconds seconds."
                }
                Write-Warning "$($job.StoreAppName) timed out after $TimeoutSeconds seconds."
                $running = @($running | Where-Object { $_.Id -ne $job.Id })
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }

            if ((Get-Date) -ge $nextHeartbeat -and $running.Count -gt 0) {
                Write-Host "    $($running.Count) update request(s) still running; $($queue.Count) queued..."
                $nextHeartbeat = (Get-Date).AddSeconds(15)
            }
            if ($running.Count -gt 0 -and $completed.Count -eq 0) {
                Start-Sleep -Seconds 1
            }
        }
    }
    finally {
        foreach ($job in $running) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
    return $results
}

$storeBefore = Get-StorePackage
if ($null -eq $storeBefore) {
    throw 'Microsoft Store is not installed for the current user.'
}
Write-Host "Microsoft Store package before bootstrap: $($storeBefore.Version)"

if (-not $SkipStoreBootstrap) {
    # Updating the Store package itself through `winget --source msstore`
    # asks the Store's own backend to update the Store, which can hang
    # (self-referential AppX/Store service lock). `wsreset -u` is the
    # fire-and-forget trigger the Store client uses internally to kick off
    # its own update/cache refresh. In practice a single call is sometimes
    # not enough to unstick a stalled Store CLI, so this is re-triggered
    # periodically while polling below, rather than fired only once.
    $wsresetPath = Join-Path $env:SystemRoot 'System32\wsreset.exe'
    if (-not (Test-Path -LiteralPath $wsresetPath -PathType Leaf)) {
        throw "wsreset.exe was not found at '$wsresetPath'."
    }

    function Invoke-WsReset {
        $result = $null
        try {
            $result = Invoke-NativeProcess -FilePath $wsresetPath -ArgumentList @('-u') `
                -Activity 'Triggering Microsoft Store cache reset and update (wsreset -u)' `
                -TimeoutSeconds 120 -ShowOutput $false
        }
        catch {
            if ($_.Exception.Message -match 'requires elevation') {
                Write-Host '    wsreset -u requires elevation in this context; retrying elevated.'
                $result = Invoke-ElevatedProcess -FilePath $wsresetPath -ArgumentList @('-u') `
                    -Activity 'Triggering Microsoft Store cache reset and update (wsreset -u, elevated)' `
                    -TimeoutSeconds 120
            }
            else {
                throw
            }
        }
        return $result
    }

    $wsreset = Invoke-WsReset

    if ($null -eq $wsreset) {
        throw 'wsreset -u returned no result.'
    }
    if ($wsreset.ExitCode -ne 0) {
        throw "wsreset -u failed with exit code $(Format-ExitCode $wsreset.ExitCode)."
    }

    Write-Host '[OK] wsreset -u triggered; polling for a responsive Store CLI.'

    $bootstrapDeadline = (Get-Date).AddSeconds(300)
    $nextWsResetRetry = (Get-Date).AddSeconds(60)
    $storeCliReady = $false
    do {
        $storePathCandidate = $null
        try {
            $storePathCandidate = Wait-StoreCli -TimeoutSeconds 15
        }
        catch {
            $storePathCandidate = $null
        }

        if ($null -ne $storePathCandidate) {
            $probeHelp = Invoke-NativeProcess -FilePath $storePathCandidate `
                -ArgumentList @('updates', '--help') `
                -Activity 'Probing Store CLI responsiveness' `
                -TimeoutSeconds 30 -ShowOutput $false

            if ($null -ne $probeHelp -and $probeHelp.ExitCode -eq 0 -and
                $probeHelp.Output -match '(?m)^\s*--apply\s') {
                $storeCliReady = $true
                break
            }
        }

        # A single wsreset -u is not always enough to unstick a stalled
        # Store CLI; re-trigger it roughly once a minute while we wait.
        if ((Get-Date) -ge $nextWsResetRetry) {
            Write-Host '    Store CLI still not responsive; re-triggering wsreset -u.'
            Invoke-WsReset | Out-Null
            $nextWsResetRetry = (Get-Date).AddSeconds(60)
        }

        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $bootstrapDeadline)

    if (-not $storeCliReady) {
        throw 'Microsoft Store CLI did not become responsive after wsreset -u within 300 seconds.'
    }
}

$storePath = Wait-StoreCli
$storeAfter = Get-StorePackage
Write-Host "[OK] Microsoft Store CLI is available; package version $($storeAfter.Version)."

$help = Invoke-NativeProcess -FilePath $storePath `
    -ArgumentList @('updates', '--help') `
    -Activity 'Verifying Store CLI update support' `
    -TimeoutSeconds 60 -ShowOutput $false
if ($help.ExitCode -ne 0 -or $help.Output -notmatch '(?m)^\s*--apply\s') {
    throw "Store CLI is present but does not expose 'updates --apply'."
}

$consecutiveEmptyChecks = 0
$completedPass = 0

for ($pass = 1; $pass -le $MaxPasses; $pass++) {
    $completedPass = $pass
    Write-Host ''
    Write-Host "----- Microsoft Store update pass $pass of $MaxPasses -----"
    $storePath = Wait-StoreCli -TimeoutSeconds 120

    $check = Invoke-NativeProcess -FilePath $storePath `
        -ArgumentList @('updates') `
        -Activity 'Checking for pending Microsoft Store updates' `
        -TimeoutSeconds $timeoutSeconds `
        -StandardInput "n`r`n"
    if ($check.ExitCode -ne 0) {
        throw "Store update check failed with exit code $(Format-ExitCode $check.ExitCode)."
    }

    $checkLines = @(ConvertTo-NormalizedLines $check.Output)
    $hasPendingUpdates = $checkLines.Count -gt 0 -and
        $check.Output -notmatch '(?im)no updates|no available updates|up to date'

    if (-not $hasPendingUpdates) {
        $consecutiveEmptyChecks++
        Write-Host "[OK] No Store updates are pending ($consecutiveEmptyChecks of 2 confirmations)."
        if ($consecutiveEmptyChecks -eq 2) {
            break
        }
        Start-Sleep -Seconds $SettleSeconds
        continue
    }

    $consecutiveEmptyChecks = 0
    $updateNames = @(Get-StoreUpdateNames $check.Output)
    if ($updateNames.Count -eq 0) {
        throw 'Store reported pending updates, but their names could not be parsed safely.'
    }

    Write-Host "Found $($updateNames.Count) pending Store update(s):"
    $updateNames | ForEach-Object { Write-Host "  - $_" }

    $updateResults = @(Invoke-StoreUpdatesInParallel `
        -StorePath $storePath -AppNames $updateNames `
        -ThrottleLimit $ThrottleLimit -TimeoutSeconds $timeoutSeconds)
    $failedUpdates = @($updateResults | Where-Object { $_.ExitCode -ne 0 })
    if ($failedUpdates.Count -gt 0) {
        $failedNames = ($failedUpdates.AppName | Sort-Object -Unique) -join ', '
        throw "$($failedUpdates.Count) Store update request(s) failed: $failedNames."
    }

    Write-Host '[OK] Every per-app update request was accepted; waiting before verification.'
    Start-Sleep -Seconds $SettleSeconds
}

if ($consecutiveEmptyChecks -lt 2) {
    throw "Microsoft Store updates did not converge after $MaxPasses passes."
}

$finalStore = Get-StorePackage
Write-Host ''
Write-Host '[SUCCESS] Microsoft Store reports no pending updates twice in succession.'

[pscustomobject]@{
    Status       = 'FullyUpdated'
    StoreVersion = [string]$finalStore.Version
    Passes       = $completedPass
    VerifiedAt   = Get-Date
}
