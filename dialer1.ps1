<#
.SYNOPSIS
  Place a Teams PSTN call to a phone number and auto-click the "Call" confirmation.

.DESCRIPTION
  Fires the msteams: deep link, then walks the UI Automation tree looking for the
  Teams confirmation dialog's "Call" button and invokes it. Works with the new
  Teams client (ms-teams.exe).

.PARAMETER Number
  Phone number in E.164 format (e.g. +15551234567). Required.

.PARAMETER TimeoutSeconds
  How long to keep looking for the Call button before giving up. Default 10.

.EXAMPLE
  .\dial-teams.ps1 -Number "+15551234567"
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Number,

  [int]$TimeoutSeconds = 10
)

# --- Normalize to E.164 (US default) ----------------------------------------
# Accepts:
#   +15551234567     -> kept (8-15 digits after the +)
#   5551234567       -> +15551234567  (US default)
#   1-555-123-4567   -> +15551234567  (formatting stripped, leading 1)
#   (555) 123-4567   -> +15551234567  (formatting stripped, US default)
# Rejects anything else.
$trimmed = $Number.Trim()
$hasPlus = $trimmed.StartsWith('+')
$digits  = ($trimmed -replace '\D', '')

if ($hasPlus) {
  if ($digits.Length -lt 8 -or $digits.Length -gt 15) {
    Write-Error "Number with + must have 8-15 digits. Got: $Number"
    exit 1
  }
  $normalized = "+$digits"
}
elseif ($digits.Length -eq 10) {
  $normalized = "+1$digits"
}
elseif ($digits.Length -eq 11 -and $digits.StartsWith('1')) {
  $normalized = "+$digits"
}
else {
  Write-Error "Number must be E.164 (+15551234567), 10-digit US (5551234567), or 11-digit with leading 1. Got: $Number"
  exit 1
}

# --- Load UI Automation assemblies ------------------------------------------
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# --- Fire the Teams deep link -----------------------------------------------
$encoded = [uri]::EscapeDataString($normalized)
$url = "msteams:/l/call/0/0?users=4:$encoded"
Write-Host "Dialing $normalized ..."
Start-Process $url

# --- Hunt for the "Call" button ---------------------------------------------
# The confirmation dialog appears in the Teams main window. The button has
# Name="Call" (or your locale's equivalent) and ControlType=Button.
# We poll the desktop tree until we find it or time out.

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$root = [System.Windows.Automation.AutomationElement]::RootElement

# Match by ControlType=Button AND Name=Call. Adjust the name list if your
# Teams UI is localized.
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

$button = $null
while ((Get-Date) -lt $deadline) {
  $button = $root.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    $condition)
  if ($null -ne $button) { break }
  Start-Sleep -Milliseconds 250
}

if ($null -eq $button) {
  Write-Warning "Could not find a Button matching $($buttonNames -join ', ') within $TimeoutSeconds seconds."
  Write-Host ""
  Write-Host "===== DIAGNOSTICS =====" -ForegroundColor Yellow
  Write-Host "Dumping candidate elements so we can see what Teams is actually exposing."
  Write-Host ""

  # 1. Anything (any control type) whose Name contains 'call'
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
    Write-Host "(none found - the dialog may not be open, or Name is empty/different)"
  }
  Write-Host ""

  # 2. All Button-type elements visible on the desktop
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
    Write-Host "(no Button elements found at all - UIA may be blocked in this VDI)"
  }
  Write-Host ""

  # 3. Top-level Teams windows
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
  Write-Host ""
  Write-Host "Copy the output above and share it. The 'Name' value of the Start Call"
  Write-Host "button is what we need to add to `$buttonNames at the top of the script."
  Write-Host "=======================" -ForegroundColor Yellow
  exit 2
}

# --- Click it ----------------------------------------------------------------
$invokePattern = $button.GetCurrentPattern(
  [System.Windows.Automation.InvokePattern]::Pattern)
$invokePattern.Invoke()

Write-Host "Call started."
