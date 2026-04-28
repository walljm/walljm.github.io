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

# --- Validate number ---------------------------------------------------------
if ($Number -notmatch '^\+\d{8,15}$') {
  Write-Error "Number must be E.164 (e.g. +15551234567). Got: $Number"
  exit 1
}

# --- Load UI Automation assemblies ------------------------------------------
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# --- Fire the Teams deep link -----------------------------------------------
$encoded = [uri]::EscapeDataString($Number)
$url = "msteams:/l/call/0/0?users=4:$encoded"
Write-Host "Dialing $Number ..."
Start-Process $url

# --- Hunt for the "Call" button ---------------------------------------------
# The confirmation dialog appears in the Teams main window. The button has
# Name="Call" (or your locale's equivalent) and ControlType=Button.
# We poll the desktop tree until we find it or time out.

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$root = [System.Windows.Automation.AutomationElement]::RootElement

# Match by ControlType=Button AND Name=Call. Adjust the name list if your
# Teams UI is localized.
$buttonNames = @('Call', 'Place call', 'Start call')

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
  Write-Warning "Could not find the Teams 'Call' confirmation button within $TimeoutSeconds seconds. The call dialog may have a different label in your Teams locale, or Teams didn't open. Edit `$buttonNames in this script to add your locale's label."
  exit 2
}

# --- Click it ----------------------------------------------------------------
$invokePattern = $button.GetCurrentPattern(
  [System.Windows.Automation.InvokePattern]::Pattern)
$invokePattern.Invoke()

Write-Host "Call started."
