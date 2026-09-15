#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [ValidateRange(1, 20)]
    [int]$MaxPasses = 6,

    [ValidateRange(1, 300)]
    [int]$SettleSeconds = 10,

    [ValidateRange(1, 60)]
    [int]$PollIntervalSeconds = 2,

    [ValidateRange(1, 480)]
    [int]$CommandTimeoutMinutes = 90,

    # Also register and search the "Microsoft Update" service, which adds
    # Office, driver, and other optional updates beyond core Windows Update.
    [switch]$IncludeMicrosoftUpdate,

    # If a restart is required to finish installing updates, restart
    # automatically instead of just reporting it. Off by default because an
    # unexpected restart can lose unsaved work.
    [switch]$AllowReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Conventional Windows/MSI exit code meaning "succeeded, restart required".
$rebootRequiredExitCode = 3010
$timeoutSeconds = $CommandTimeoutMinutes * 60
$microsoftUpdateServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'

function Format-HResult {
    param([int]$Code)
    $unsigned = [int64]$Code -band 0xFFFFFFFF
    return '{0} (0x{1:X8})' -f $Code, $unsigned
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Wait-AsyncJob {
    # Windows Update Agent's BeginDownload/BeginInstall return a job you can
    # poll for progress via GetProgress() without needing to implement the
    # COM progress-callback interfaces. This avoids the exact problem the
    # Store updater had (blocking with zero visibility).
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$PollIntervalSeconds,
        [Parameter(Mandatory)]$UpdatesCollection
    )

    $started = Get-Date
    $lastPercent = -1
    $nextHeartbeat = 30

    while (-not $Job.IsCompleted) {
        $elapsedSeconds = [int]((Get-Date) - $started).TotalSeconds
        if ($elapsedSeconds -ge $TimeoutSeconds) {
            throw "$Activity timed out after $TimeoutSeconds seconds."
        }

        $progress = $Job.GetProgress()
        $percent = $progress.PercentComplete

        if ($percent -ne $lastPercent -or $elapsedSeconds -ge $nextHeartbeat) {
            $currentTitle = ''
            $currentIndex = $progress.CurrentUpdateIndex
            if ($currentIndex -ge 0 -and $currentIndex -lt $UpdatesCollection.Count) {
                $currentTitle = " - $($UpdatesCollection.Item($currentIndex).Title)"
            }
            Write-Host "    $Activity`: $percent%$currentTitle"
            $lastPercent = $percent
            $nextHeartbeat = $elapsedSeconds + 30
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

if (-not (Test-IsElevated)) {
    throw 'This script must run elevated (as Administrator); installing Windows Updates requires admin rights.'
}

$Session = New-Object -ComObject Microsoft.Update.Session
$Searcher = $Session.CreateUpdateSearcher()
$Searcher.ServerSelection = 2

if ($IncludeMicrosoftUpdate) {
    $ServiceManager = New-Object -ComObject Microsoft.Update.ServiceManager
    $existing = $null
    for ($i = 0; $i -lt $ServiceManager.Services.Count; $i++) {
        if ($ServiceManager.Services.Item($i).ServiceID -eq $microsoftUpdateServiceId) {
            $existing = $ServiceManager.Services.Item($i)
            break
        }
    }
    if ($null -eq $existing) {
        Write-Host 'Registering the Microsoft Update service (Office/driver/optional updates)...'
        $ServiceManager.AddService2($microsoftUpdateServiceId, 7, '') | Out-Null
    }
    $Searcher.ServerSelection = 3
    $Searcher.ServiceID = $microsoftUpdateServiceId
}

$consecutiveEmptyChecks = 0
$completedPass = 0
$totalInstalled = 0
$rebootRequired = $false

for ($pass = 1; $pass -le $MaxPasses; $pass++) {
    $completedPass = $pass
    Write-Host ''
    Write-Host "----- Windows Update pass $pass of $MaxPasses -----"
    Write-Host '==> Searching for applicable updates'

    try {
        $searchResult = $Searcher.Search('IsInstalled=0 and IsHidden=0')
    }
    catch {
        throw "Windows Update search failed: $($_.Exception.Message)"
    }

    if ($searchResult.ResultCode -ne 2) {
        throw "Windows Update search did not succeed. ResultCode: $(Format-HResult $searchResult.ResultCode)"
    }

    $pendingUpdates = $searchResult.Updates
    if ($pendingUpdates.Count -eq 0) {
        $consecutiveEmptyChecks++
        Write-Host "[OK] No applicable updates found ($consecutiveEmptyChecks of 2 confirmations)."
        if ($consecutiveEmptyChecks -ge 2) {
            break
        }
        Start-Sleep -Seconds $SettleSeconds
        continue
    }
    $consecutiveEmptyChecks = 0

    Write-Host "Found $($pendingUpdates.Count) applicable update(s):"
    for ($i = 0; $i -lt $pendingUpdates.Count; $i++) {
        $update = $pendingUpdates.Item($i)
        Write-Host "  - $($update.Title)"
        if (-not $update.EulaAccepted) {
            $update.AcceptEula() | Out-Null
        }
    }

    $updatesToDownload = New-Object -ComObject Microsoft.Update.UpdateColl
    for ($i = 0; $i -lt $pendingUpdates.Count; $i++) {
        $update = $pendingUpdates.Item($i)
        if (-not $update.IsDownloaded) {
            $updatesToDownload.Add($update) | Out-Null
        }
    }

    if ($updatesToDownload.Count -gt 0) {
        Write-Host "==> Downloading $($updatesToDownload.Count) update(s)"
        $Downloader = $Session.CreateUpdateDownloader()
        $Downloader.Updates = $updatesToDownload
        $downloadJob = $Downloader.BeginDownload($null, $null, $null)
        Wait-AsyncJob -Job $downloadJob -Activity 'Download progress' `
            -TimeoutSeconds $timeoutSeconds -PollIntervalSeconds $PollIntervalSeconds `
            -UpdatesCollection $updatesToDownload
        $downloadResult = $Downloader.EndDownload($downloadJob)

        for ($i = 0; $i -lt $updatesToDownload.Count; $i++) {
            $updateResult = $downloadResult.GetUpdateResult($i)
            $title = $updatesToDownload.Item($i).Title
            if ($updateResult.ResultCode -eq 2) {
                Write-Host "    [OK] Downloaded: $title"
            }
            else {
                Write-Warning "    Download issue ($(Format-HResult $updateResult.HResult)): $title"
            }
        }

        if ($downloadResult.ResultCode -notin @(2, 3)) {
            throw "Download did not succeed. ResultCode: $(Format-HResult $downloadResult.ResultCode)"
        }
    }
    else {
        Write-Host '[OK] All applicable updates were already downloaded.'
    }

    $updatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
    for ($i = 0; $i -lt $pendingUpdates.Count; $i++) {
        $update = $pendingUpdates.Item($i)
        if ($update.IsDownloaded) {
            $updatesToInstall.Add($update) | Out-Null
        }
    }

    if ($updatesToInstall.Count -eq 0) {
        Write-Warning 'No updates were downloaded successfully; skipping install for this pass.'
        Start-Sleep -Seconds $SettleSeconds
        continue
    }

    Write-Host "==> Installing $($updatesToInstall.Count) update(s)"
    $Installer = $Session.CreateUpdateInstaller()
    $Installer.Updates = $updatesToInstall
    $installJob = $Installer.BeginInstall($null, $null, $null)
    Wait-AsyncJob -Job $installJob -Activity 'Install progress' `
        -TimeoutSeconds $timeoutSeconds -PollIntervalSeconds $PollIntervalSeconds `
        -UpdatesCollection $updatesToInstall
    $installResult = $Installer.EndInstall($installJob)

    for ($i = 0; $i -lt $updatesToInstall.Count; $i++) {
        $updateResult = $installResult.GetUpdateResult($i)
        $title = $updatesToInstall.Item($i).Title
        if ($updateResult.ResultCode -eq 2) {
            Write-Host "    [OK] Installed: $title"
            $totalInstalled++
        }
        else {
            Write-Warning "    Install issue ($(Format-HResult $updateResult.HResult)): $title"
        }
    }

    if ($installResult.RebootRequired) {
        $rebootRequired = $true
        Write-Host ''
        Write-Warning 'A restart is required to finish installing updates.'
    }

    if ($installResult.ResultCode -notin @(2, 3)) {
        throw "Install did not fully succeed. ResultCode: $(Format-HResult $installResult.ResultCode)"
    }

    if ($rebootRequired) {
        Write-Host 'Stopping further passes until the pending restart completes.'
        break
    }

    Start-Sleep -Seconds $SettleSeconds
}

Write-Host ''

if ($rebootRequired) {
    Write-Host "[PENDING] $totalInstalled update(s) installed across $completedPass pass(es); a restart is required."
    if ($AllowReboot) {
        Write-Host 'Restarting now because -AllowReboot was specified...'
        Restart-Computer -Force
    }
    else {
        Write-Host 'Re-run this script after restarting to check for further updates.'
    }
    exit $rebootRequiredExitCode
}

if ($consecutiveEmptyChecks -lt 2) {
    throw "Windows Update did not converge to a fully up-to-date state after $MaxPasses passes."
}

Write-Host "[SUCCESS] Windows reports no pending updates twice in succession. $totalInstalled update(s) installed across $completedPass pass(es)."

[pscustomobject]@{
    Status           = 'FullyUpdated'
    UpdatesInstalled = $totalInstalled
    Passes           = $completedPass
    VerifiedAt       = Get-Date
}
