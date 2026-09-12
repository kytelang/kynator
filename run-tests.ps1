<#
.SYNOPSIS
  Run every kyte-orchestrator test via `kyte test` on Windows (PowerShell mirror of run-tests.sh).

.DESCRIPTION
  The Kyte resolver finds this package's modules through ../packages, so this must run from a checkout
  laid out beside the `lang` toolchain, with kyte.exe on PATH. We invoke from the lang/ directory so the
  stdlib resolves relative to CWD -- exactly like run-tests.sh does.

  Requirements / caveats:
    * kyte.exe must be a ReleaseFast build. A Debug kyte's leak gate exits 1 on every `kyte test`, so the
      whole suite would report red while printing "0 failed". (Build with `zig build -Doptimize=ReleaseFast`.)
    * The orchestrator is a Linux production concern. Its POSIX-only surfaces do NOT pass on Windows:
      the fd-handoff data plane (AF_UNIX / SCM_RIGHTS) and some reactor/isolation tests (e.g.
      183_isolation_sandbox, 202_live_forwarding). Use WSL2 for a full, green run; on Windows this script
      is for the platform-neutral logic tests.

.PARAMETER Filter   Optional substring; only run test files whose name contains it (e.g. -Filter config).
#>
[CmdletBinding()]
param([string]$Filter = "")

$here = $PSScriptRoot
$lang = Join-Path $here "..\..\lang"
if (-not (Test-Path $lang)) { Write-Error "expected the Kyte toolchain at $lang"; exit 1 }
if (-not (Get-Command kyte -ErrorAction SilentlyContinue) -and -not (Get-Command kyte.exe -ErrorAction SilentlyContinue)) {
  Write-Error "kyte(.exe) not found on PATH (install the toolchain; see lang/CLAUDE.md)"; exit 1
}

Push-Location $lang
try {
  $files = @()
  $files += Get-ChildItem -Path (Join-Path $here "tests") -Filter *.ky -File -ErrorAction SilentlyContinue
  $wf = Join-Path $here "webui\tests\features"
  if (Test-Path $wf) { $files += Get-ChildItem -Path $wf -Filter *.ky -File -ErrorAction SilentlyContinue }
  if ($Filter) { $files = $files | Where-Object { $_.Name -like "*$Filter*" } }

  $pass = 0; $fail = 0
  foreach ($t in $files) {
    $out = & kyte test $t.FullName 2>&1
    if ($LASTEXITCODE -eq 0 -and ($out -match ", 0 failed")) {
      Write-Host "PASS  $($t.Name)"; $pass++
    } else {
      Write-Host "FAIL  $($t.Name)"
      ($out | Select-Object -Last 6) | ForEach-Object { Write-Host "      $_" }
      $fail++
    }
  }
  Write-Host "----------------------------------------"
  Write-Host "kyte-orchestrator: $pass passed, $fail failed"
  if ($fail -ne 0) { exit 1 }
} finally {
  Pop-Location
}
