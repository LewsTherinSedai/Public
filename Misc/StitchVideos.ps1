# --- 1) VARIABLES & DRIVE MAPPING ---
# --- MAPPING THE UNC SHARE TO A PSDrive NAMED 'Ducks' ---
# Only create it if it isn't already mapped
if (-not (Get-PSDrive -Name Ducks -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name Ducks -PSProvider FileSystem -Root '\\hlsyno1\videoshares\DucksMoved\ToBe'
    Write-Host "✔ Mapped '\\hlsyno1\videoshares\ducksMoved\ToBe' to Ducks:" -ForegroundColor Green } else {Write-Host "ℹ️  PSDrive 'Ducks:' already exists."
}
# Share and local drive
$psDriveName  = 'Ducks'
# --- CONFIGURE PATHS & TOOLS ---
$ffmpeg     = Join-Path $env:USERPROFILE 'AppData\Local\UniGetUI\Chocolatey\bin\ffmpeg.exe'
$sourceDrive= 'Ducks:'                  # Your UNC share as a PSDrive
$outputRoot = 'D:\videos'               # Where stitched files & lists go

# make sure output folder exists
if (-not (Test-Path $outputRoot)) { New-Item -Path $outputRoot -ItemType Directory | Out-Null }
# --- 2) PROCESS EACH DATE FOLDER ---
Get-ChildItem -Path $sourceDrive -Directory | ForEach-Object {

    $dateName = $_.Name
    $inDir    = $_.FullName
    $listFile = Join-Path $outputRoot "$dateName-concat-list.txt"
    $outFile  = Join-Path $outputRoot "$dateName-stitched.avi"

    Write-Host "`n▶ Processing folder: $dateName" -ForegroundColor Cyan

    # Build the concat list
    Get-ChildItem -Path $inDir -Filter '*.avi' |
      Sort-Object Name |
      ForEach-Object { "file '$($_.FullName)'" } |
      Set-Content -Path $listFile -Encoding ASCII

    # Run FFmpeg in copy‐mode into an AVI container
    $args = @(
      '-hide_banner'
      '-loglevel', 'fatal'
      '-stats'
      '-f',        'concat'
      '-safe',     '0'
      '-i',        $listFile
      '-c',        'copy'
      '-y',        $outFile
    )

    & $ffmpeg @args
# 3) Report success/failure
if ($LASTEXITCODE -eq 0) { Write-Host "✔ Completed: $outFile" -ForegroundColor Green } else { Write-Warning "✘ Failed: $dateName" }
}
