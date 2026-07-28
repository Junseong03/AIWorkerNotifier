[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AIWorkerNotifier'
$inbox = Join-Path $runtime 'inbox'

& (Join-Path $root 'bin\ai-task-complete.ps1') `
    -Task 'UNIT-SMOKE' `
    -Status 'LOCAL_IMPLEMENTED' `
    -Summary '한글 이벤트 생성 시험' `
    -NextAction 'DRY_RUN_PROCESS' `
    -Tests '1 passed' `
    -AgentRole 'TEST' `
    -Source 'test-script' `
    -Scope 'task' `
    -DispatchId 'unit-smoke-1'

$file = Get-ChildItem -LiteralPath $inbox -Filter '*.json' -File | Sort-Object CreationTimeUtc -Descending | Select-Object -First 1
if ($null -eq $file) { throw '이벤트 파일이 생성되지 않았습니다.' }
$event = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
if ($event.schemaVersion -ne 1) { throw 'schemaVersion 불일치' }
if ($event.task -ne 'UNIT-SMOKE') { throw 'task 불일치' }
if ($event.summary -ne '한글 이벤트 생성 시험') { throw 'UTF-8 summary 불일치' }
if (Get-ChildItem -LiteralPath $inbox -Filter '*.tmp' -File -ErrorAction SilentlyContinue) { throw 'tmp 파일이 남았습니다.' }

& (Join-Path $root 'bin\AIWorkerNotifier.ps1') -DryRun -Once -Backlog
Write-Host 'PASS: event creation + dry-run processing'
