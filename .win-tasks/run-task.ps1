# run-task.ps1 -TaskFile <path> -Name <name>
# Runs one development task through `dsh headless` (claude-opus-5-5) detached from A2A.
param([Parameter(Mandatory=$true)][string]$TaskFile, [Parameter(Mandatory=$true)][string]$Name)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Console]::InputEncoding = [Text.Encoding]::UTF8
$repo = 'C:\Users\morrow\coding\reset-rune'
$logDir = Join-Path $repo '.build\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir "task-$Name.log"
$result = Join-Path $logDir "task-$Name.result.md"
$events = Join-Path $logDir "task-$Name.events.jsonl"
$promptFile = Join-Path $logDir "task-$Name.prompt.txt"
$patch = Join-Path $env:USERPROFILE '.dsh\a2a-work\win-headless.yml'
$dsh = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd'
foreach ($v in 'http_proxy','https_proxy','HTTP_PROXY','HTTPS_PROXY','all_proxy','ALL_PROXY') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
$env:PATH = "$env:USERPROFILE\.cargo\bin;$env:PATH"
$env:RESET_RUNE_TEST_NODE = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\node.exe'
Set-Location $repo
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($log, "=== BEGIN $Name $(Get-Date -Format o)`n", $utf8)
$brief = [IO.File]::ReadAllText((Join-Path $repo '.build\win-setup\WINDOWS-BRIEF.md'), $utf8)
$task = [IO.File]::ReadAllText($TaskFile, $utf8)
$hdr1 = [IO.File]::ReadAllText((Join-Path $env:USERPROFILE '.dsh\a2a-work\prompt-header.txt'), $utf8)
$prompt = "$hdr1`n`n$brief`n`n=====`n`n$task"
[IO.File]::WriteAllText($promptFile, $prompt, $utf8)
# cmd handles the stdin redirect as raw bytes so dsh receives UTF-8 verbatim.
$cmdLine = "chcp 65001 >nul & `"$dsh`" --profile headless --patch `"$patch`" --json - < `"$promptFile`" > `"$events`" 2>> `"$log`""
try { & cmd.exe /d /c $cmdLine; $code = $LASTEXITCODE } catch { [IO.File]::AppendAllText($log, "launch error: $($_.Exception.Message)`n", $utf8); $code = -2 }
# Extract the final text from the NDJSON event stream.
$final = ''
if (Test-Path $events) {
  foreach ($line in [IO.File]::ReadLines($events, $utf8)) {
    try { $o = $line | ConvertFrom-Json } catch { continue }
    if ($o.type -eq 'final') { $final = $o.text }
  }
}
[IO.File]::WriteAllText($result, $final, $utf8)
[IO.File]::AppendAllText($log, "=== EXIT $Name code=$code $(Get-Date -Format o)`n", $utf8)
