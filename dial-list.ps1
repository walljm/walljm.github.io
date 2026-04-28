<#
.SYNOPSIS
  Read phone numbers from prospects.txt and dial each via dialer.ps1, pausing
  for a Spacebar press before every call.

.DESCRIPTION
  Looks for prospects.txt in the same directory as this script. One number per
  line; blank lines and lines starting with # are ignored. Optional name after
  a comma (e.g. "+15551234567, John Smith") is shown but not required.

  Press SPACE to dial the next number.
  Press ESC  to quit.

.EXAMPLE
  .\dial-list.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# --- Locate files -----------------------------------------------------------
$dialer = Join-Path $PSScriptRoot 'dialer.ps1'
$listFile = Join-Path $PSScriptRoot 'prospects.txt'

if (-not (Test-Path $dialer)) {
  Write-Error "dialer.ps1 not found in $PSScriptRoot"
  exit 1
}
if (-not (Test-Path $listFile)) {
  Write-Error "prospects.txt not found in $PSScriptRoot"
  exit 1
}

# --- Load and parse the list ------------------------------------------------
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

Write-Host ""
Write-Host "Loaded $($entries.Count) number(s) from prospects.txt" -ForegroundColor Green
Write-Host "Controls: [Space]=dial  [Esc]=quit"
Write-Host ""

# --- Helper: block until Space or Esc is pressed ----------------------------
function Wait-ForKey {
  # Drain any buffered keys first so a stray press doesn't auto-advance
  while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
  while ($true) {
    $k = [Console]::ReadKey($true)
    switch ($k.Key) {
      'Spacebar' { return 'dial' }
      'Escape'   { return 'quit' }
    }
    # Any other key: ignore and keep waiting
  }
}

# --- Main loop --------------------------------------------------------------
$called = 0

for ($i = 0; $i -lt $entries.Count; $i++) {
  $entry = $entries[$i]
  $label = if ($entry.Name) { "$($entry.Number)  ($($entry.Name))" } else { $entry.Number }

  Write-Host ("[{0}/{1}] Next: {2}" -f ($i + 1), $entries.Count, $label) -ForegroundColor Cyan
  Write-Host "        Press [Space] to dial, [Esc] to quit." -ForegroundColor DarkGray

  $action = Wait-ForKey
  if ($action -eq 'quit') {
    Write-Host ""
    Write-Host "Quit requested." -ForegroundColor Yellow
    break
  }

  & $dialer -Number $entry.Number
  $rc = $LASTEXITCODE
  if ($rc -eq 0) {
    Write-Host "        Dialed." -ForegroundColor Green
    $called++
  } else {
    Write-Host "        Dial failed (exit $rc)." -ForegroundColor Red
  }
}

Write-Host ""
Write-Host "Done. Called: $called  Total: $($entries.Count)" -ForegroundColor Green
