# Fix Claude Desktop 0x80070020 on Windows

This PowerShell script is for a specific Claude Desktop launch failure on Windows: after an MSIX update, the app will not open and Windows says, “This file is currently used by another program.” `Start-Process "claude:"` may report the same file-in-use error.

![Claude Desktop 0x80070020 error saying this file is currently used by another program](assets/claude-file-in-use.png)

For the failure this script targets, Event Viewer shows AppModel-Runtime events `208`/`215` with error `0x80070020` (`ERROR_SHARING_VIOLATION`) while Windows tries to create the Desktop AppX container.

In my case, the useful clue was a group of orphaned `app-server-broker.mjs` processes. Their parent processes were gone, but the brokers were still alive. Stopping Claude's packaged service and removing only those orphaned brokers allowed the AppX container to start again.

This script automates that cleanup. It does not uninstall Claude, reset the app, or delete user data.

## Run it

Open PowerShell and run:

```powershell
.\Fix-ClaudeLaunch.ps1
```

Windows will ask for administrator approval because the script needs to stop `CoworkVMService` and clean up packaged Claude processes.

If your execution policy blocks the script, use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Fix-ClaudeLaunch.ps1
```

## What it does

- Stops `CoworkVMService` without changing its startup type.
- Closes the Claude MSIX process tree from children to parents.
- Finds `app-server-broker.mjs` Node processes whose parent is gone.
- Leaves active brokers and unrelated Node processes alone.
- Repeats cleanup until Claude processes and services remain stopped.
- Waits for the Claude AppX container to unmount, then launches Claude through Windows Explorer.
- Uses AppModel-Runtime events to distinguish a successful launch from error `0x80070020`.

The script is intentionally narrow. It is meant for the launch failure that produces AppModel-Runtime events `208`/`215` with error `0x80070020`. If no orphaned broker is found, the problem may have a different cause.

If an update leaves the Claude AppX container mounted after every process has stopped, Windows cannot safely release it from this script. The script reports that state without launching Claude. Sign out of Windows and sign back in, or restart Windows, then try Claude again.

This is an unofficial workaround and is not affiliated with Anthropic.
