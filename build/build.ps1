#Requires -Version 5.1
# Membangun dist\XGPopupGuard-Setup.exe dari file solusi di folder induk.
# Jalankan: powershell -NoProfile -ExecutionPolicy Bypass -File D:\XGPopupGuard\build\build.ps1
$ErrorActionPreference = 'Stop'
$root  = Split-Path $PSScriptRoot -Parent
$dist  = Join-Path $root 'dist'
$files = @('Install-XGPopupGuard.ps1', 'XGPopupGuard.ps1', 'XGPopupGuard.Escalate.ps1', 'XGGuard.Common.ps1', 'XGGuard.Win32.cs')
$csc   = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path $csc)) { throw "csc.exe tidak ditemukan: $csc" }

$entries = foreach ($f in $files) {
    $p = Join-Path $root $f
    if (-not (Test-Path $p)) { throw "File hilang: $p" }
    '            {{ "{0}", "{1}" }},' -f $f, (Get-FileHash $p -Algorithm SHA256).Hash
}
"Source SHA256:"; $entries | ForEach-Object { "  $($_.Trim())" }
$src = (Get-Content (Join-Path $PSScriptRoot 'Setup.cs') -Raw).Replace('/*HASHES*/', ($entries -join "`r`n"))
$genDir = Join-Path ([IO.Path]::GetTempPath()) ("xgsetup-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $genDir | Out-Null
$gen = Join-Path $genDir 'Setup.g.cs'
try {
    Set-Content $gen $src -Encoding UTF8
    New-Item -ItemType Directory -Force $dist | Out-Null
    $out = Join-Path $dist 'XGPopupGuard-Setup.exe'
    $resArgs = $files | ForEach-Object { '/resource:"{0}",{1}' -f (Join-Path $root $_), $_ }
    & $csc /nologo /target:exe /platform:anycpu /optimize+ "/win32manifest:$(Join-Path $PSScriptRoot 'app.manifest')" "/out:$out" @resArgs $gen
    if ($LASTEXITCODE -ne 0) { throw "Kompilasi gagal ($LASTEXITCODE)" }
} finally {
    Remove-Item -LiteralPath $genDir -Recurse -Force -ErrorAction SilentlyContinue
}
"Built: $out"
"SHA256: $((Get-FileHash $out -Algorithm SHA256).Hash)"
