# --- 1) VARIABLES & DRIVE MAPPING ---

# Share and local drive
$shareRoot    = '\\hlsyno1\videoshares\ducks'
$psDriveName  = 'Ducks'
#–– CONFIG ––
$ffmpeg         = Join-Path $env:USERPROFILE 'AppData\Local\UniGetUI\Chocolatey\bin\ffmpeg.exe'
$outputRoot     = 'J:\videos'
$transcodeRoot  = 'J:\videos\Transcode'

# test with a single date-folder:
$dateName = '2025-07-16'
$inDir    = Join-Path 'Ducks:' $dateName
$tempDir  = Join-Path $transcodeRoot $dateName
$outFile  = Join-Path $outputRoot "$dateName-stitched.mp4"

# make sure temp-dir exists
if (-not (Test-Path $tempDir)) {
    New-Item -Path $tempDir -ItemType Directory | Out-Null
}

Write-Host "▶ Normalizing all AVIs in $inDir → $tempDir" -ForegroundColor Cyan

# 1) Transcode each .avi → mp4 @ 1280:960 & 10fps
Get-ChildItem -Path $inDir -Filter '*.avi' | Sort-Object Name | ForEach-Object {
    $src  = $_.FullName
    $dst  = Join-Path $tempDir ($_.BaseName + '.mp4')
    if (-not (Test-Path $dst)) {
        Write-Host "  • Transcoding $($_.Name)…"
        & $ffmpeg `
          -hide_banner -loglevel fatal -stats `
          -i $src `
          -vf "scale=1280:960:flags=lanczos" `
          -c:v h264_amf -b:v 8M `
          -c:a aac    -b:a 192k `
          -y $dst
    }
    else {
        Write-Host "  • Skipping existing $($_.Name).mp4"
    }
}

# 2) Build a concat list from those temp .mp4s
$listFile = Join-Path $tempDir 'concat_list.txt'
Get-ChildItem -Path $tempDir -Filter '*.mp4' | Sort-Object Name |
    ForEach-Object { "file '$($_.FullName)'" } |
    Set-Content -Path $listFile -Encoding ASCII

# 3) Do a fast copy-mode stitch
Write-Host "`n▶ Stitching into $outFile" -ForegroundColor Cyan
& $ffmpeg `
  -hide_banner -loglevel fatal -stats `
  -f concat -safe 0 -i $listFile `
  -c copy -y $outFile
  

if ($LASTEXITCODE -eq 0) { Write-Host "✔ Completed: $outFile" -ForegroundColor Green } else { Write-Warning "✘ Failed: $dateName" }
