[CmdletBinding()]
param(
    [switch]$Elevated,

    [ValidateRange(0, 120)]
    [int]$WaitSeconds = 30,

    [string]$TargetLocalAppData = $env:LOCALAPPDATA,

    [string]$TargetUserProfile = $env:USERPROFILE
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$serviceName = 'CoworkVMService'
$packageFamilyName = 'Claude_pzs8sxrjxfjjc'
$packageMachinePattern = 'C:\Program Files\WindowsApps\Claude_*'
$packageUserPattern = Join-Path $TargetLocalAppData "Packages\$packageFamilyName\*"
$claudePluginRoot = Join-Path $TargetUserProfile '.claude\plugins\cache\openai-codex'
$brokerRegex = [regex]::Escape($claudePluginRoot) + '[\\/].*app-server-broker\.mjs(?:\s|$)'
$packageEventRegex = 'Claude_(?:[^\s]*__)?pzs8sxrjxfjjc'
$appModelRuntimeLog = 'Microsoft-Windows-AppModel-Runtime/Admin'
$cleanupPassCount = 3

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Stop-ProcessById {
    param(
        [Parameter(Mandatory)]
        [uint32]$ProcessId,

        [Parameter(Mandatory)]
        [string]$Description
    )

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        Write-Host "Stopped $Description (PID $ProcessId)."
    }
    catch {
        # Ignore only the harmless race where the process exits by itself.
        if ($null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
            throw
        }
    }
}

function Stop-ClaudeService {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -ne $service -and $service.Status -ne 'Stopped') {
        Stop-Service -Name $serviceName -Force -ErrorAction Stop
        Write-Host "Stopped $serviceName."
    }
}

function Get-OrphanedClaudeBrokers {
    param(
        [object[]]$Processes = @(Get-CimInstance Win32_Process)
    )

    $processById = @{}
    foreach ($process in $Processes) {
        $processById[[uint32]$process.ProcessId] = $process
    }

    return @(
        $Processes | Where-Object {
            if ($_.Name -ne 'node.exe' -or ([string]$_.CommandLine) -notmatch $brokerRegex) {
                return $false
            }

            $parentId = [uint32]$_.ParentProcessId
            if (-not $processById.ContainsKey($parentId)) {
                return $true
            }

            # A newer process can reuse the dead parent's PID. In that case
            # this broker is still an orphan even though the PID exists again.
            $parent = $processById[$parentId]
            return $parent.CreationDate -gt $_.CreationDate
        }
    )
}

function Get-ClaudePackageProcesses {
    param(
        [Parameter(Mandatory)]
        [object[]]$Processes
    )

    return @(
        $Processes | Where-Object {
            $path = [string]$_.ExecutablePath

            $_.ProcessId -ne $PID -and (
                $path -like $packageMachinePattern -or
                $path -like $packageUserPattern
            )
        }
    )
}

function Get-ClaudeProcessTree {
    param(
        [Parameter(Mandatory)]
        [object[]]$Processes,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [uint32[]]$RootProcessIds
    )

    $processById = @{}
    $childrenByParentId = @{}

    foreach ($process in $Processes) {
        $processId = [uint32]$process.ProcessId
        $parentId = [uint32]$process.ParentProcessId
        $processById[$processId] = $process

        if (-not $childrenByParentId.ContainsKey($parentId)) {
            $childrenByParentId[$parentId] = [System.Collections.Generic.List[object]]::new()
        }

        $childrenByParentId[$parentId].Add($process)
    }

    $queue = [System.Collections.Queue]::new()
    foreach ($rootId in @($RootProcessIds | Sort-Object -Unique)) {
        if ($processById.ContainsKey($rootId)) {
            $queue.Enqueue([pscustomobject]@{
                Process = $processById[$rootId]
                Depth = 0
            })
        }
    }

    $seen = @{}
    $tree = [System.Collections.Generic.List[object]]::new()
    while ($queue.Count -gt 0) {
        $entry = $queue.Dequeue()
        $processId = [uint32]$entry.Process.ProcessId
        if ($seen.ContainsKey($processId)) {
            continue
        }

        $seen[$processId] = $true
        $tree.Add($entry)

        if ($childrenByParentId.ContainsKey($processId)) {
            foreach ($child in $childrenByParentId[$processId]) {
                # Ignore a stale parent PID when Windows has already reused it
                # for a process that started after this child.
                if ($child.CreationDate -lt $entry.Process.CreationDate) {
                    continue
                }

                $queue.Enqueue([pscustomobject]@{
                    Process = $child
                    Depth = $entry.Depth + 1
                })
            }
        }
    }

    return @($tree)
}

function Get-ClaudeSiloHives {
    $hiveList = Get-ItemProperty `
        -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\hivelist' `
        -ErrorAction Stop

    return @(
        $hiveList.PSObject.Properties |
            Where-Object {
                $_.Name -notmatch '^PS' -and
                ([string]$_.Value) -match [regex]::Escape("Packages\$packageFamilyName")
            } |
            ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name
                    Value = $_.Value
                }
            }
    )
}

function Invoke-ClaudeCleanupPass {
    Stop-ClaudeService

    $allProcesses = @(Get-CimInstance Win32_Process)
    $packageProcesses = @(Get-ClaudePackageProcesses -Processes $allProcesses)
    $processTree = @(
        Get-ClaudeProcessTree `
            -Processes $allProcesses `
            -RootProcessIds @($packageProcesses.ProcessId)
    )

    # Stop descendants before their packaged parent so external helpers cannot
    # outlive Claude and retain an AppX job or inherited package handle.
    foreach ($entry in @($processTree | Sort-Object Depth -Descending)) {
        $process = $entry.Process
        $description = if ($entry.Depth -gt 0) {
            "Claude child process $($process.Name)"
        }
        else {
            $process.Name
        }

        Stop-ProcessById -ProcessId ([uint32]$process.ProcessId) -Description $description
    }

    # An orphan can retain an inherited Job/handle even when
    # GetPackageFullName reports NO_PACKAGE for the process.
    $allProcesses = @(Get-CimInstance Win32_Process)
    $orphanedBrokers = @(Get-OrphanedClaudeBrokers -Processes $allProcesses)

    foreach ($broker in $orphanedBrokers) {
        Stop-ProcessById -ProcessId ([uint32]$broker.ProcessId) -Description 'orphaned app-server-broker'
    }

    # Stop it once more in case package activation restarted it during cleanup.
    Stop-ClaudeService
}

function Invoke-ClaudeCleanup {
    for ($pass = 1; $pass -le $cleanupPassCount; $pass++) {
        Invoke-ClaudeCleanupPass
        Start-Sleep -Milliseconds 500

        $allProcesses = @(Get-CimInstance Win32_Process)
        $remainingPackageProcesses = @(Get-ClaudePackageProcesses -Processes $allProcesses)
        $remainingBrokers = @(Get-OrphanedClaudeBrokers -Processes $allProcesses)
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        $serviceStopped = $null -eq $service -or $service.Status -eq 'Stopped'

        if (
            $remainingPackageProcesses.Count -eq 0 -and
            $remainingBrokers.Count -eq 0 -and
            $serviceStopped
        ) {
            return
        }

        if ($pass -lt $cleanupPassCount) {
            Write-Host "Claude cleanup is not stable yet; retrying (pass $($pass + 1)/$cleanupPassCount)..."
        }
    }

    throw 'Claude process or service cleanup did not become stable.'
}

function Wait-ForClaudeContainerCleanup {
    $deadline = (Get-Date).AddSeconds($WaitSeconds)

    do {
        $allProcesses = @(Get-CimInstance Win32_Process)
        $packageProcesses = @(Get-ClaudePackageProcesses -Processes $allProcesses)
        $orphanedBrokers = @(Get-OrphanedClaudeBrokers -Processes $allProcesses)

        if ($packageProcesses.Count -gt 0 -or $orphanedBrokers.Count -gt 0) {
            Invoke-ClaudeCleanup
        }

        # The MSIX package can reinstall/restart its auto-start service while
        # registration finishes. Keep it stopped until the launch attempt.
        Stop-ClaudeService

        if (@(Get-ClaudeSiloHives).Count -eq 0) {
            return $true
        }

        if ((Get-Date) -ge $deadline) {
            return $false
        }

        Start-Sleep -Seconds 1
    } while ($true)
}

function Get-ClaudeDesktopProcesses {
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -eq 'claude.exe' -and
                ([string]$_.ExecutablePath) -like $packageMachinePattern
            }
    )
}

function Get-ClaudeLaunchEvent {
    param(
        [Parameter(Mandatory)]
        [datetime]$Since
    )

    return @(
        Get-WinEvent `
            -FilterHashtable @{
                LogName = $appModelRuntimeLog
                StartTime = $Since
                Id = 201, 208
            } `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match $packageEventRegex } |
            Sort-Object TimeCreated -Descending |
            Select-Object -First 1
    )
}

function Wait-ForClaudeLaunch {
    param(
        [Parameter(Mandatory)]
        [datetime]$Since,

        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $claudeProcesses = @(Get-ClaudeDesktopProcesses)
        if ($claudeProcesses.Count -gt 0) {
            return [pscustomobject]@{
                Status = 'Started'
                Process = $claudeProcesses[0]
                Event = $null
            }
        }

        $launchEvent = @(Get-ClaudeLaunchEvent -Since $Since) | Select-Object -First 1
        if ($null -ne $launchEvent) {
            if ($launchEvent.Id -eq 201) {
                return [pscustomobject]@{
                    Status = 'Started'
                    Process = $null
                    Event = $launchEvent
                }
            }

            if ($launchEvent.Id -eq 208 -and $launchEvent.Message -match '0x80070020') {
                return [pscustomobject]@{
                    Status = 'SharingViolation'
                    Process = $null
                    Event = $launchEvent
                }
            }
        }

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return [pscustomobject]@{
        Status = 'TimedOut'
        Process = $null
        Event = $null
    }
}

if ($Elevated) {
    if (-not (Test-IsAdministrator)) {
        Write-Error 'The cleanup stage requires administrator privileges.'
        exit 1
    }

    try {
        Invoke-ClaudeCleanup
        if (-not (Wait-ForClaudeContainerCleanup)) {
            exit 20
        }

        exit 0
    }
    catch {
        Write-Error $_
        exit 1
    }
}

Write-Host 'Cleaning up Claude launch blockers...'

$orphanedBeforeCleanup = @(Get-OrphanedClaudeBrokers)
if ($orphanedBeforeCleanup.Count -gt 0) {
    $orphanIds = ($orphanedBeforeCleanup.ProcessId | Sort-Object) -join ', '
    Write-Host "Found orphaned Claude/Codex app-server broker PID(s): $orphanIds"
}
else {
    Write-Warning 'No orphaned Claude/Codex app-server broker was found; this exact recovery may not apply.'
}

$cleanupExitCode = 0
if ($WaitSeconds -gt 0) {
    Write-Host "Waiting up to $WaitSeconds seconds for the Claude AppX container to settle..."
}

if (Test-IsAdministrator) {
    Invoke-ClaudeCleanup
    if (-not (Wait-ForClaudeContainerCleanup)) {
        $cleanupExitCode = 20
    }
}
else {
    $hostExecutable = (Get-Process -Id $PID).Path
    $argumentLine = @(
        '-NoProfile'
        '-ExecutionPolicy Bypass'
        "-File `"$PSCommandPath`""
        '-Elevated'
        "-WaitSeconds $WaitSeconds"
        "-TargetLocalAppData `"$TargetLocalAppData`""
        "-TargetUserProfile `"$TargetUserProfile`""
    ) -join ' '

    try {
        $elevatedProcess = Start-Process `
            -FilePath $hostExecutable `
            -Verb RunAs `
            -ArgumentList $argumentLine `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
    }
    catch {
        throw "Administrator cleanup was cancelled or could not start: $($_.Exception.Message)"
    }

    $cleanupExitCode = $elevatedProcess.ExitCode
    if ($cleanupExitCode -ne 0 -and $cleanupExitCode -ne 20) {
        throw "Administrator cleanup failed with exit code $($elevatedProcess.ExitCode)."
    }
}

$allProcesses = @(Get-CimInstance Win32_Process)
$remainingPackageProcesses = @(Get-ClaudePackageProcesses -Processes $allProcesses)
$remainingBrokers = @(Get-OrphanedClaudeBrokers -Processes $allProcesses)
if ($remainingPackageProcesses.Count -gt 0) {
    throw "Claude package process cleanup did not complete (PID(s): $($remainingPackageProcesses.ProcessId -join ', '))."
}

if ($remainingBrokers.Count -gt 0) {
    throw "Orphaned app-server broker cleanup did not complete (PID(s): $($remainingBrokers.ProcessId -join ', '))."
}

$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -ne $service -and $service.Status -ne 'Stopped') {
    throw "$serviceName restarted before launch; run the script again."
}

if ($cleanupExitCode -eq 20 -or @(Get-ClaudeSiloHives).Count -gt 0) {
    Write-Warning 'Claude processes were cleaned up, but Windows still has its AppX container mounted after the update.'
    Write-Warning 'Sign out of Windows and sign back in, or restart Windows before launching Claude again.'
    return
}

Write-Host 'Launching Claude...'
$launchStartedAt = Get-Date
try {
    # Let the Windows shell handle protocol activation so Claude does not
    # inherit this PowerShell window's console handles.
    $explorerPath = Join-Path $env:WINDIR 'explorer.exe'
    Start-Process -FilePath $explorerPath -ArgumentList 'claude:' -ErrorAction Stop
}
catch {
    throw "Claude launch is still blocked: $($_.Exception.Message)"
}

$launchResult = Wait-ForClaudeLaunch -Since $launchStartedAt
switch ($launchResult.Status) {
    'Started' {
        if ($null -ne $launchResult.Process) {
            Write-Host "Claude launched successfully (PID $($launchResult.Process.ProcessId))." -ForegroundColor Green
        }
        else {
            Write-Host 'Windows created the Claude process successfully.' -ForegroundColor Green
        }
    }
    'SharingViolation' {
        Write-Warning 'Windows rejected Claude activation with AppModel-Runtime error 0x80070020.'
        if (@(Get-ClaudeSiloHives).Count -gt 0) {
            Write-Warning 'A Claude AppX container is still mounted. Sign out of Windows or restart Windows before trying again.'
        }
    }
    default {
        Write-Warning 'Claude was not detected within 15 seconds, and Windows recorded no definitive launch result.'
    }
}
