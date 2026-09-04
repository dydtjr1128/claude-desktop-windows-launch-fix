[CmdletBinding()]
param(
    [switch]$Elevated,

    [ValidateRange(0, 120)]
    [int]$WaitSeconds = 10,

    [string]$TargetLocalAppData = $env:LOCALAPPDATA,

    [string]$TargetUserProfile = $env:USERPROFILE,

    [string]$TargetUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$serviceName = 'CoworkVMService'
$packageFamilyName = 'Claude_pzs8sxrjxfjjc'
$packagePublisherId = $packageFamilyName.Substring(
    $packageFamilyName.IndexOf('_') + 1
)
$packageMachinePattern = 'C:\Program Files\WindowsApps\Claude_*'
$packageUserPattern = Join-Path $TargetLocalAppData "Packages\$packageFamilyName\*"
$claudePluginRoot = Join-Path $TargetUserProfile '.claude\plugins\cache\openai-codex'
$brokerRegex = [regex]::Escape($claudePluginRoot) + '[\\/].*app-server-broker\.mjs(?:\s|$)'
$packageEventRegex = 'Claude_(?:[^\s]*__)?pzs8sxrjxfjjc'
$appModelRuntimeLog = 'Microsoft-Windows-AppModel-Runtime/Admin'
$cleanupPassCount = 3
$containerStableSeconds = 3
$launchStableSeconds = 2

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-ClaudeContainerJobInterop {
    if ($null -ne ('ClaudeLaunchFix.ContainerJobInspector' -as [type])) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ClaudeLaunchFix
{
    public static class ContainerJobInspector
    {
        [StructLayout(LayoutKind.Sequential)]
        struct UnicodeString
        {
            public ushort Length;
            public ushort MaximumLength;
            public IntPtr Buffer;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ObjectAttributes
        {
            public int Length;
            public IntPtr RootDirectory;
            public IntPtr ObjectName;
            public uint Attributes;
            public IntPtr SecurityDescriptor;
            public IntPtr SecurityQualityOfService;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ObjectDirectoryInformation
        {
            public UnicodeString Name;
            public UnicodeString TypeName;
        }

        [DllImport("ntdll.dll")]
        static extern int NtOpenDirectoryObject(
            out IntPtr directoryHandle,
            uint desiredAccess,
            ref ObjectAttributes objectAttributes);

        [DllImport("ntdll.dll")]
        static extern int NtQueryDirectoryObject(
            IntPtr directoryHandle,
            IntPtr buffer,
            uint bufferLength,
            [MarshalAs(UnmanagedType.U1)] bool returnSingleEntry,
            [MarshalAs(UnmanagedType.U1)] bool restartScan,
            ref uint context,
            out uint returnLength);

        [DllImport("ntdll.dll")]
        static extern int NtOpenJobObject(
            out IntPtr jobHandle,
            uint desiredAccess,
            ref ObjectAttributes objectAttributes);

        [DllImport("ntdll.dll")]
        static extern int NtClose(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool QueryInformationJobObject(
            IntPtr jobHandle,
            int informationClass,
            IntPtr information,
            uint informationLength,
            out uint returnLength);

        static IntPtr CreateUnicodeString(
            string value,
            out IntPtr textPointer)
        {
            textPointer = Marshal.StringToHGlobalUni(value);
            UnicodeString unicodeString = new UnicodeString
            {
                Length = (ushort)(value.Length * 2),
                MaximumLength = (ushort)((value.Length + 1) * 2),
                Buffer = textPointer
            };
            IntPtr unicodeStringPointer = Marshal.AllocHGlobal(
                Marshal.SizeOf(typeof(UnicodeString)));
            Marshal.StructureToPtr(
                unicodeString,
                unicodeStringPointer,
                false);
            return unicodeStringPointer;
        }

        static ObjectAttributes CreateObjectAttributes(IntPtr objectName)
        {
            return new ObjectAttributes
            {
                Length = Marshal.SizeOf(typeof(ObjectAttributes)),
                ObjectName = objectName,
                Attributes = 0x40
            };
        }

        public static string[] GetRootJobNames()
        {
            IntPtr textPointer;
            IntPtr objectName = CreateUnicodeString("\\", out textPointer);
            ObjectAttributes attributes = CreateObjectAttributes(objectName);
            IntPtr directoryHandle;
            int status = NtOpenDirectoryObject(
                out directoryHandle,
                0x0001,
                ref attributes);
            Marshal.FreeHGlobal(objectName);
            Marshal.FreeHGlobal(textPointer);

            if (status < 0)
            {
                throw new InvalidOperationException(
                    "NtOpenDirectoryObject failed with 0x" +
                    status.ToString("X8"));
            }

            try
            {
                List<string> jobNames = new List<string>();
                uint context = 0;
                bool restartScan = true;
                IntPtr buffer = Marshal.AllocHGlobal(65536);

                try
                {
                    while (true)
                    {
                        uint returned;
                        status = NtQueryDirectoryObject(
                            directoryHandle,
                            buffer,
                            65536,
                            true,
                            restartScan,
                            ref context,
                            out returned);
                        restartScan = false;

                        if (status < 0)
                        {
                            break;
                        }

                        ObjectDirectoryInformation information =
                            (ObjectDirectoryInformation)Marshal.PtrToStructure(
                                buffer,
                                typeof(ObjectDirectoryInformation));
                        string name = Marshal.PtrToStringUni(
                            information.Name.Buffer,
                            information.Name.Length / 2);
                        string typeName = Marshal.PtrToStringUni(
                            information.TypeName.Buffer,
                            information.TypeName.Length / 2);

                        if (String.Equals(
                            typeName,
                            "Job",
                            StringComparison.Ordinal))
                        {
                            jobNames.Add(name);
                        }
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }

                return jobNames.ToArray();
            }
            finally
            {
                NtClose(directoryHandle);
            }
        }

        public static long[] GetProcessIds(string jobName)
        {
            string nativePath = "\\" + jobName;
            IntPtr textPointer;
            IntPtr objectName = CreateUnicodeString(
                nativePath,
                out textPointer);
            ObjectAttributes attributes = CreateObjectAttributes(objectName);
            IntPtr jobHandle;
            int status = NtOpenJobObject(
                out jobHandle,
                0x0004,
                ref attributes);
            Marshal.FreeHGlobal(objectName);
            Marshal.FreeHGlobal(textPointer);

            if (status < 0)
            {
                throw new InvalidOperationException(
                    "NtOpenJobObject failed for " + jobName + " with 0x" +
                    status.ToString("X8"));
            }

            try
            {
                int capacity = 4096;
                IntPtr buffer = Marshal.AllocHGlobal(
                    8 + IntPtr.Size * capacity);

                try
                {
                    uint returned;
                    if (!QueryInformationJobObject(
                        jobHandle,
                        3,
                        buffer,
                        (uint)(8 + IntPtr.Size * capacity),
                        out returned))
                    {
                        throw new Win32Exception(
                            Marshal.GetLastWin32Error());
                    }

                    uint count = (uint)Marshal.ReadInt32(buffer, 4);
                    long[] processIds = new long[count];
                    for (int index = 0; index < count; index++)
                    {
                        processIds[index] = IntPtr.Size == 8
                            ? Marshal.ReadInt64(buffer, 8 + index * 8)
                            : Marshal.ReadInt32(buffer, 8 + index * 4);
                    }
                    return processIds;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            finally
            {
                NtClose(jobHandle);
            }
        }
    }
}
'@ -Language CSharp
}

function Get-ClaudeUserContainerJobs {
    Initialize-ClaudeContainerJobInterop

    $jobSuffix = "__$packagePublisherId-$TargetUserSid"
    return @(
        [ClaudeLaunchFix.ContainerJobInspector]::GetRootJobNames() |
            Where-Object {
                $_.StartsWith(
                    'Container_Claude_',
                    [StringComparison]::OrdinalIgnoreCase
                ) -and
                $_.EndsWith(
                    $jobSuffix,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    )
}

function Get-ClaudeContainerJobMembers {
    $members = foreach ($jobName in @(Get-ClaudeUserContainerJobs)) {
        foreach ($processId in @(
            [ClaudeLaunchFix.ContainerJobInspector]::GetProcessIds($jobName)
        )) {
            if ($processId -ne $PID) {
                [pscustomobject]@{
                    JobName = $jobName
                    ProcessId = [uint32]$processId
                }
            }
        }
    }

    return @($members)
}

function Stop-ClaudeContainerJobMembers {
    $members = @(Get-ClaudeContainerJobMembers)
    if ($members.Count -eq 0) {
        return
    }

    $allProcesses = @(Get-CimInstance Win32_Process)
    $processById = @{}
    foreach ($process in $allProcesses) {
        $processById[[uint32]$process.ProcessId] = $process
    }

    foreach ($job in @($members | Group-Object JobName)) {
        Write-Host "Found stale Claude AppX container job $($job.Name)."

        foreach ($member in $job.Group) {
            $description = 'stale Claude container member'
            if ($processById.ContainsKey($member.ProcessId)) {
                $description = "stale Claude container member $($processById[$member.ProcessId].Name)"
            }

            Stop-ProcessById `
                -ProcessId $member.ProcessId `
                -Description $description
        }
    }
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
    $rootProcessIds = @(
        $packageProcesses | ForEach-Object { [uint32]$_.ProcessId }
    )
    $processTree = @(
        Get-ClaudeProcessTree `
            -Processes $allProcesses `
            -RootProcessIds $rootProcessIds
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

    # Some non-packaged descendants remain assigned to Claude's per-user
    # AppX Job after their Claude parent exits. Stop only members of that
    # exact package/user Job so Windows can destroy the stale container.
    Stop-ClaudeContainerJobMembers

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
        $remainingJobMembers = @(Get-ClaudeContainerJobMembers)
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        $serviceStopped = $null -eq $service -or $service.Status -eq 'Stopped'

        if (
            $remainingPackageProcesses.Count -eq 0 -and
            $remainingBrokers.Count -eq 0 -and
            $remainingJobMembers.Count -eq 0 -and
            $serviceStopped
        ) {
            return
        }

        if ($pass -lt $cleanupPassCount) {
            Write-Host "Claude cleanup is not stable yet; retrying (pass $($pass + 1)/$cleanupPassCount)..."
        }
    }

    throw 'Claude process, container Job, or service cleanup did not become stable.'
}

function Wait-ForClaudeContainerCleanup {
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $requiredStableSeconds = [Math]::Min($containerStableSeconds, $WaitSeconds)
    $stableSince = $null

    do {
        $allProcesses = @(Get-CimInstance Win32_Process)
        $packageProcesses = @(Get-ClaudePackageProcesses -Processes $allProcesses)
        $orphanedBrokers = @(Get-OrphanedClaudeBrokers -Processes $allProcesses)
        $containerJobMembers = @(Get-ClaudeContainerJobMembers)
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        $serviceRunning = $null -ne $service -and $service.Status -ne 'Stopped'
        $cleanupActivityDetected =
            $packageProcesses.Count -gt 0 -or
            $orphanedBrokers.Count -gt 0 -or
            $containerJobMembers.Count -gt 0 -or
            $serviceRunning

        if (
            $packageProcesses.Count -gt 0 -or
            $orphanedBrokers.Count -gt 0 -or
            $containerJobMembers.Count -gt 0
        ) {
            Invoke-ClaudeCleanup
        }

        # The MSIX package can reinstall/restart its auto-start service while
        # registration finishes. Keep it stopped until the launch attempt.
        Stop-ClaudeService

        $siloHives = @(Get-ClaudeSiloHives)
        if (-not $cleanupActivityDetected -and $siloHives.Count -eq 0) {
            if ($requiredStableSeconds -le 0) {
                return $true
            }

            if ($null -eq $stableSince) {
                $stableSince = Get-Date
            }
            elseif (((Get-Date) - $stableSince).TotalSeconds -ge $requiredStableSeconds) {
                return $true
            }
        }
        else {
            $stableSince = $null
        }

        if ((Get-Date) -ge $deadline) {
            return $false
        }

        Start-Sleep -Milliseconds 500
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
                Id = 201, 208, 215
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
        [int]$TimeoutSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $stableProcessId = [uint32]0
    $stableSince = $null
    $lastLaunchEvent = $null

    do {
        $claudeProcesses = @(Get-ClaudeDesktopProcesses)
        if ($claudeProcesses.Count -gt 0) {
            $candidate = @(
                $claudeProcesses | Sort-Object CreationDate
            ) | Select-Object -First 1
            $candidateProcessId = [uint32]$candidate.ProcessId

            if ($stableProcessId -ne $candidateProcessId) {
                $stableProcessId = $candidateProcessId
                $stableSince = Get-Date
            }
            elseif (((Get-Date) - $stableSince).TotalSeconds -ge $launchStableSeconds) {
                return [pscustomobject]@{
                    Status = 'Started'
                    Process = $candidate
                    Event = $lastLaunchEvent
                }
            }
        }
        else {
            $stableProcessId = [uint32]0
            $stableSince = $null
        }

        $launchEvent = @(Get-ClaudeLaunchEvent -Since $Since) | Select-Object -First 1
        if ($null -ne $launchEvent) {
            $lastLaunchEvent = $launchEvent

            if (
                $launchEvent.Id -in 208, 215 -and
                $launchEvent.Message -match '0x80070020'
            ) {
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
        Status = if ($null -ne $lastLaunchEvent -and $lastLaunchEvent.Id -eq 201) {
            'ExitedEarly'
        }
        else {
            'TimedOut'
        }
        Process = $null
        Event = $lastLaunchEvent
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
        "-TargetUserSid `"$TargetUserSid`""
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
    # Use Explorer for protocol activation so Claude is detached from this
    # PowerShell console. This is also the same user session being repaired.
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
        Write-Warning 'Windows rejected Claude activation with error 0x80070020 after cleanup.'
        if (@(Get-ClaudeSiloHives).Count -gt 0) {
            Write-Warning 'A Claude AppX container is still mounted. Sign out of Windows or restart Windows before trying again.'
        }
    }
    'ExitedEarly' {
        Write-Warning 'Windows created Claude, but the process exited before it remained stable for 2 seconds.'
    }
    default {
        Write-Warning 'Claude was not detected within 10 seconds, and Windows recorded no definitive launch result.'
    }
}
