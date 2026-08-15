[CmdletBinding()]
param(
    [switch]$Elevated,

    [ValidateRange(0, 120)]
    [int]$WaitSeconds = 10,

    [string]$TargetLocalAppData = $env:LOCALAPPDATA,

    [string]$TargetUserProfile = $env:USERPROFILE
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$serviceName = 'CoworkVMService'
$packageMachinePattern = 'C:\Program Files\WindowsApps\Claude_*'
$packageUserPattern = Join-Path $TargetLocalAppData 'Packages\Claude_pzs8sxrjxfjjc\*'
$claudePluginRoot = Join-Path $TargetUserProfile '.claude\plugins\cache\openai-codex'
$brokerRegex = [regex]::Escape($claudePluginRoot) + '[\\/].*app-server-broker\.mjs(?:\s|$)'

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

function Invoke-ClaudeCleanup {
    Stop-ClaudeService

    $allProcesses = @(Get-CimInstance Win32_Process)
    $relatedProcesses = @(
        $allProcesses | Where-Object {
            $path = [string]$_.ExecutablePath

            $_.ProcessId -ne $PID -and (
                $path -like $packageMachinePattern -or
                $path -like $packageUserPattern
            )
        }
    )

    foreach ($process in $relatedProcesses) {
        Stop-ProcessById -ProcessId ([uint32]$process.ProcessId) -Description $process.Name
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

function Wait-ForClaudeContainerCleanup {
    if ($WaitSeconds -le 0) {
        return
    }

    Write-Host "Waiting $WaitSeconds seconds for the AppX container to settle..."
    for ($second = 0; $second -lt $WaitSeconds; $second++) {
        Start-Sleep -Seconds 1

        # The MSIX package can reinstall/restart its auto-start service while
        # registration finishes. Keep it stopped until the launch attempt.
        Stop-ClaudeService
    }
}

if ($Elevated) {
    if (-not (Test-IsAdministrator)) {
        Write-Error 'The cleanup stage requires administrator privileges.'
        exit 1
    }

    try {
        Invoke-ClaudeCleanup
        Wait-ForClaudeContainerCleanup
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

if (Test-IsAdministrator) {
    Invoke-ClaudeCleanup
    Wait-ForClaudeContainerCleanup
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

    if ($elevatedProcess.ExitCode -ne 0) {
        throw "Administrator cleanup failed with exit code $($elevatedProcess.ExitCode)."
    }
}

$remainingBrokers = @(Get-OrphanedClaudeBrokers)
if ($remainingBrokers.Count -gt 0) {
    throw "Orphaned app-server broker cleanup did not complete (PID(s): $($remainingBrokers.ProcessId -join ', '))."
}

$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -ne $service -and $service.Status -ne 'Stopped') {
    throw "$serviceName restarted before launch; run the script again."
}

Write-Host 'Launching Claude...'
try {
    # Let the Windows shell handle protocol activation so Claude does not
    # inherit this PowerShell window's console handles. A direct launch can
    # stream Electron logs here and close Claude when the terminal exits.
    $explorerPath = Join-Path $env:WINDIR 'explorer.exe'
    Start-Process -FilePath $explorerPath -ArgumentList 'claude:' -ErrorAction Stop
}
catch {
    throw "Claude launch is still blocked: $($_.Exception.Message)"
}

$deadline = (Get-Date).AddSeconds(15)
$claudeProcesses = @()
do {
    Start-Sleep -Milliseconds 500
    $claudeProcesses = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -eq 'claude.exe' -and
                ([string]$_.ExecutablePath) -like $packageMachinePattern
            }
    )
} while ($claudeProcesses.Count -eq 0 -and (Get-Date) -lt $deadline)

if ($claudeProcesses.Count -eq 0) {
    Write-Warning 'The launch request was accepted, but Claude was not detected within 15 seconds.'
}
else {
    $mainPid = $claudeProcesses[0].ProcessId
    Write-Host "Claude launched successfully (PID $mainPid)." -ForegroundColor Green
}
