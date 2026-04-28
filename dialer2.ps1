<#
.SYNOPSIS
  Dial a list of phone numbers through Microsoft Teams, one per Spacebar press.

.DESCRIPTION
  Reads phone numbers from prospects.txt in the same directory as this script.
  Waits for the user to press SPACE before each call. For each number it fires
  the msteams: deep link and walks the UI Automation tree to find and click
  Teams' "Start Call" confirmation button.

  prospects.txt format:
    +15551234567, John Smith
    5559876543, Jane Doe
    1-555-000-1111
    # lines starting with # are ignored; blank lines too

  Controls:
    [Space] dial the next number
    [Esc]   quit

.PARAMETER TimeoutSeconds
  How long to wait for Teams' Start Call button to appear, per call. Default 10.

.EXAMPLE
  .\dialer.ps1
#>
[CmdletBinding()]
param(
  [int]$TimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'

# --- Locate prospects.txt ---------------------------------------------------
$listFile = Join-Path $PSScriptRoot 'prospects.txt'
if (-not (Test-Path $listFile)) {
  Write-Error "prospects.txt not found in $PSScriptRoot"
  exit 1
}

# --- Load UI Automation assemblies (once) -----------------------------------
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# --- Win32 helper to refocus the console window after Teams steals focus ----
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WinApi {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
}
'@

function Set-ConsoleFocus {
  [void][WinApi]::SetForegroundWindow([WinApi]::GetConsoleWindow())
}

# --- Parse the list ---------------------------------------------------------
$entries = @()
Get-Content $listFile | ForEach-Object {
  $line = $_.Trim()
  if ($line.Length -eq 0) { return }
  if ($line.StartsWith('#')) { return }
  $comma = $line.IndexOf(',')
  if ($comma -ge 0) {
    $entries += [pscustomobject]@{
      Number = $line.Substring(0, $comma).Trim()
      Name   = $line.Substring($comma + 1).Trim()
    }
  } else {
    $entries += [pscustomobject]@{ Number = $line; Name = '' }
  }
}

if ($entries.Count -eq 0) {
  Write-Warning "prospects.txt has no numbers."
  exit 0
}

# --- Helpers ----------------------------------------------------------------

# Normalize a phone number string to E.164. US default for bare 10/11-digit.
# Returns $null if the number can't be normalized.
function ConvertTo-E164 {
  param([string]$Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
  $trimmed = $Raw.Trim()
  $hasPlus = $trimmed.StartsWith('+')
  $digits  = ($trimmed -replace '\D', '')
  if ($hasPlus) {
    if ($digits.Length -lt 8 -or $digits.Length -gt 15) { return $null }
    return "+$digits"
  }
  if ($digits.Length -eq 10) { return "+1$digits" }
  if ($digits.Length -eq 11 -and $digits.StartsWith('1')) { return "+$digits" }
  return $null
}

# Block until SPACE or ESC. Drains buffered keys first so a stray press during
# a call doesn't auto-advance the next round.
function Wait-ForKey {
  while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
  while ($true) {
    $k = [Console]::ReadKey($true)
    switch ($k.Key) {
      'Spacebar' { return 'dial' }
      'Escape'   { return 'quit' }
    }
  }
}

# Fire the Teams deep link and click the "Start Call" confirmation. Returns
# $true on success, $false if the button couldn't be found within timeout.
function Invoke-TeamsCall {
  param(
    [Parameter(Mandatory)][string]$E164Number,
    [int]$TimeoutSeconds = 10
  )

  $encoded = [uri]::EscapeDataString($E164Number)
  $url = "msteams:/l/call/0/0?users=4:$encoded"
  Start-Process $url
  Start-Sleep -Milliseconds 1500  # give Teams time to render the confirmation dialog

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $root = [System.Windows.Automation.AutomationElement]::RootElement

  $buttonNames = @('Start Call', 'Start call', 'Call', 'Place call', 'Place Call')
  $nameConditions = @()
  foreach ($n in $buttonNames) {
    $nameConditions += New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, $n)
  }
  $nameCondition = if ($nameConditions.Count -eq 1) {
    $nameConditions[0]
  } else {
    New-Object System.Windows.Automation.OrCondition($nameConditions)
  }
  $typeCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button)
  $condition = New-Object System.Windows.Automation.AndCondition($typeCondition, $nameCondition)

  while ((Get-Date) -lt $deadline) {
    $button = $root.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $condition)
    if ($null -ne $button) {
      try {
        $invokePattern = $button.GetCurrentPattern(
          [System.Windows.Automation.InvokePattern]::Pattern)
        $invokePattern.Invoke()
        return $true
      } catch {
        # Stale element from a previous call's dialog — keep searching
      }
    }
    Start-Sleep -Milliseconds 250
  }

  return $false
}

# Dump UIA candidates for the Start Call button. Used when auto-click fails.
function Show-Diagnostics {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  Write-Host ""
  Write-Host "===== DIAGNOSTICS =====" -ForegroundColor Yellow

  Write-Host "--- Elements with Name containing 'call' (any control type) ---" -ForegroundColor Cyan
  $allCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::IsControlElementProperty, $true)
  $matches = $root.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants, $allCondition) |
    Where-Object { $_.Current.Name -and $_.Current.Name -match '(?i)call' }
  if ($matches) {
    $matches | ForEach-Object {
      "{0,-32} ControlType={1,-22} AutomationId='{2}'" -f `
        ("'" + $_.Current.Name + "'"),
        $_.Current.ControlType.ProgrammaticName,
        $_.Current.AutomationId
    } | Write-Host
  } else {
    Write-Host "(none found - dialog may not be open)"
  }

  Write-Host ""
  Write-Host "--- All Button-type elements on the desktop (top 50) ---" -ForegroundColor Cyan
  $btnCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button)
  $buttons = $root.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants, $btnCondition)
  if ($buttons.Count -gt 0) {
    $buttons | Select-Object -First 50 | ForEach-Object {
      "Name='{0}' AutomationId='{1}'" -f $_.Current.Name, $_.Current.AutomationId
    } | Write-Host
    if ($buttons.Count -gt 50) {
      Write-Host "... and $($buttons.Count - 50) more"
    }
  } else {
    Write-Host "(no Button elements found - UIA may be blocked in this VDI)"
  }

  Write-Host ""
  Write-Host "--- Top-level windows mentioning Teams ---" -ForegroundColor Cyan
  $winCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Window)
  $wins = $root.FindAll(
    [System.Windows.Automation.TreeScope]::Children, $winCondition) |
    Where-Object { $_.Current.Name -match '(?i)teams' }
  if ($wins) {
    $wins | ForEach-Object {
      "Name='{0}' ProcessId={1} ClassName='{2}'" -f `
        $_.Current.Name, $_.Current.ProcessId, $_.Current.ClassName
    } | Write-Host
  } else {
    Write-Host "(no Teams window visible to UIA)"
  }
  Write-Host "=======================" -ForegroundColor Yellow
}

# --- Main loop --------------------------------------------------------------
Write-Host ""
Write-Host "Loaded $($entries.Count) number(s) from prospects.txt" -ForegroundColor Green
Write-Host "Controls: [Space]=dial  [Esc]=quit"
Write-Host ""

$called = 0
$failed = 0

try {
for ($i = 0; $i -lt $entries.Count; $i++) {
  $entry = $entries[$i]
  $normalized = ConvertTo-E164 -Raw $entry.Number

  $label = if ($entry.Name) { "$($entry.Number)  ($($entry.Name))" } else { $entry.Number }
  Write-Host ("[{0}/{1}] Next: {2}" -f ($i + 1), $entries.Count, $label) -ForegroundColor Cyan

  if ($null -eq $normalized) {
    Write-Host "        Invalid number - skipping." -ForegroundColor Red
    $failed++
    continue
  }

  Write-Host "        Press [Space] to dial $normalized, [Esc] to quit." -ForegroundColor DarkGray

  $action = Wait-ForKey
  if ($action -eq 'quit') {
    Write-Host ""
    Write-Host "Quit requested." -ForegroundColor Yellow
    break
  }

  Write-Host "        Dialing $normalized ..." -ForegroundColor White
  $ok = Invoke-TeamsCall -E164Number $normalized -TimeoutSeconds $TimeoutSeconds
  if ($ok) {
    Write-Host "        Call started." -ForegroundColor Green
    $called++
  } else {
    Write-Host "        Could not find Teams 'Start Call' button within $TimeoutSeconds seconds." -ForegroundColor Red
    $failed++
    Show-Diagnostics
  }
  Set-ConsoleFocus
}

Write-Host ""
Write-Host ("Done. Called: {0}  Failed: {1}  Total: {2}" -f $called, $failed, $entries.Count) -ForegroundColor Green
} catch {
  Write-Host ""
  Write-Host "FATAL ERROR: $_" -ForegroundColor Red
  Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}

Read-Host "`nPress Enter to close"
