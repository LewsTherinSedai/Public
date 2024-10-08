<# 
====================================================
|  7D2D Powershell Backup Script                   |
| Created by: TayschrennSedai                      |
| Contact: github.com/LewsTherinSedai              |
| Revision: 1.2                                    |
====================================================

.AUTHOR
    LewsTherinSedai on Git

.DATE
    2024-09-10

.VERSION
    1.2

.LICENSE
    GPL v3.0

.PARAMETER backup
    Default is "Default" but can also use ALL

.PARAMETER type
    Probably not needed, technically - but you can also use -backup -type ALL

.EXAMPLE
     You can also automate this with a basic switch:
.\Backup7d2d.ps1 -backup 
     (By default this option will backup the default save folder only)
.\Backup7d2d.ps1 -backup ALL
     (This will backup ALL the save folders)


.REQUIREMENTS
    - This also assumes you have 7zip installed - if not, a default install from https://ninite.com/7zip/ will be this path 99.9% of the time 

.NOTES
    - I might improve this script more in the future, I mostly just built it to be lazy

.FUTUREWORK
    - Linux support?
    - Could add some logic to allow passing source/destinations, but at that point you could just use robocopy or something
#>
# Define parameters for automation
param (
    [switch]$backup,
    [ValidateSet("Default", "All")]
    [string]$type = "Default"
)

# Define paths
$userProfile = [System.Environment]::GetFolderPath("UserProfile")
$SaveGameFolder = "$userProfile\AppData\Roaming\7DaysToDie\Saves\Gulaso Territory"  # Example save path
$AllSavesFolder = "$userProfile\AppData\Roaming\7DaysToDie\Saves"
$DocumentsFolder = [System.Environment]::GetFolderPath("MyDocuments")
$BackupPath = "$DocumentsFolder\7d2dBackups"
$sevenZipPath = "C:\Program Files\7-Zip\7z.exe"  # Adjust this path if 7-Zip is installed elsewhere

# Extract the last folder name from $SaveGameFolder and replace spaces with underscores
$defaultSavePrefix = (Split-Path $SaveGameFolder -Leaf) -replace ' ', '_'
$allSavesPrefix = "ALLSAVES"

# Ensure the 7d2dBackups folder exists
if (-Not (Test-Path -Path $BackupPath)) {
    New-Item -Path $BackupPath -ItemType Directory
    Write-Host "Created backup folder at: $BackupPath"
}

# Function to backup a specific folder
function Backup-Folder {
    param (
        [string]$folderToBackup,
        [string]$backupType
    )

    # Determine backup filename prefix based on backup type
    if ($backupType -eq "Default") {
        $backupFileNamePrefix = $defaultSavePrefix
        Write-Host "Backup file prefix (Default): $backupFileNamePrefix"
    } elseif ($backupType -eq "All") {
        $backupFileNamePrefix = $allSavesPrefix
        Write-Host "Backup file prefix (All): $backupFileNamePrefix"
    } elseif ($backupType -eq "PreRestore") {
        $backupFileNamePrefix = "$defaultSavePrefix-PreRestore"
        Write-Host "Backup file prefix (PreRestore): $backupFileNamePrefix"
    } else {
        Write-Error "Invalid backup type"
        exit
    }

    # Get current date and time to append to the filename (format: YYYYMMDD_HHmmss)
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $destinationZip = "$BackupPath\$backupFileNamePrefix`_$timestamp.zip"

    # Output for debugging
    Write-Host "Destination zip path: $destinationZip"

    # Check if 7z.exe exists
    if (-Not (Test-Path $sevenZipPath)) {
        Write-Error "7-Zip executable not found at $sevenZipPath. Please ensure 7-Zip is installed and the path is correct."
        exit
    }

    # Ensure folder paths are properly escaped
    $folderToBackupEscaped = "`"$folderToBackup\*`""  # Include only the contents of the folder
    $destinationZipEscaped = "`"$destinationZip`""
    
    # Run 7-Zip to compress the folder contents
    $arguments = "a -tzip $destinationZipEscaped $folderToBackupEscaped"
    Write-Host "Executing 7-Zip command: $sevenZipPath $arguments"
    Start-Process -FilePath $sevenZipPath -ArgumentList $arguments -NoNewWindow -Wait

    # Check if the backup was successful
    if (Test-Path $destinationZip) {
        Write-Host "Backup successful: $destinationZip"
    } else {
        Write-Error "Backup failed!"
    }
}

# Function to restore a specific folder from a .7z file
function Restore-Folder {
    param (
        [string]$restorePath,
        [string]$restoreFile
    )

    # Backup the folder before restoring (PreRestore backup)
    Backup-Folder -folderToBackup $restorePath -backupType "PreRestore"

    # Extract the selected .7z file
    $arguments = "x `"$restoreFile`" -o`"$restorePath`" -aoa"
    Write-Host "Executing 7-Zip command: $sevenZipPath $arguments"
    Start-Process -FilePath $sevenZipPath -ArgumentList $arguments -NoNewWindow -Wait

    Write-Host "Restore completed from $restoreFile"
}

# Function to list and select backups
function Select-Backup {
    param (
        [string]$backupPattern,
        [int]$maxResults
    )

    # Get a list of backup files matching the pattern and sort by creation date
    $backupFiles = Get-ChildItem -Path $BackupPath -Filter "$backupPattern*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First $maxResults

    if (-Not $backupFiles) {
        Write-Error "No backups found matching the pattern: $backupPattern"
        return $null
    }

    # Display the backups for the user to select
    Write-Host "Select a backup to restore:"
    for ($i = 0; $i -lt $backupFiles.Count; $i++) {
        Write-Host "$($i + 1). $($backupFiles[$i].Name)"
    }

    $selection = Read-Host "Please select a backup (1-$($backupFiles.Count))"
    if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $backupFiles.Count) {
        return $backupFiles[[int]$selection - 1].FullName
    } else {
        Write-Host "Invalid selection."
        return $null
    }
}

# Check for command-line switches
if ($backup) {
    if ($type -eq "Default") {
        Write-Host "Running backup for default save..."
        Backup-Folder -folderToBackup $SaveGameFolder -backupType "Default"
    } elseif ($type -eq "All") {
        Write-Host "Running backup for all saves..."
        Backup-Folder -folderToBackup $AllSavesFolder -backupType "All"
    }
    exit  # Exit after running the specified task
}

# Menu with ASCII Header (interactive mode)
while ($true) {
    Clear-Host
    
    # ASCII Art and Header Information
    Write-Host "
                __--_--_-_
               ( I wish I  )" -ForegroundColor Magenta
    Write-Host "              ( were a real )" -ForegroundColor Magenta
    Write-Host "              (    llama   )" -ForegroundColor Magenta
    Write-Host "               ( in Peru! )" -ForegroundColor Magenta
    Write-Host "              o (__--_--_)" -ForegroundColor Magenta
    Write-Host "           , o" -ForegroundColor Magenta
    Write-Host "          ~)" -ForegroundColor Green
    Write-Host "           (_---;" -ForegroundColor Green
    Write-Host "              /|~|\ " -ForegroundColor Green
    Write-Host "           /  /  /  |" -ForegroundColor Green

    Write-Host "
    ====================================================
    |  7D2D Powershell Backup Script                   |
    | Created by: RDW                                  |
    | Contact: github.com/LewsTherinSedai              |
    | Revision: 1.1                                    |
    ====================================================" -ForegroundColor Cyan

    # Menu Options
    Write-Host "Menu:"
    Write-Host "1. Backup default save ($defaultSavePrefix)"
    Write-Host "2. Backup ALL saves"
    Write-Host "3. Restore default save"
    Write-Host "4. Restore ALL saves"
    Write-Host "5. Exit"
    
    $choice = Read-Host "Please select an option (1-5)"

    switch ($choice) {
        1 {
            # Backup the default save folder
            Backup-Folder -folderToBackup $SaveGameFolder -backupType "Default"
        }
        2 {
            # Backup all saves folder
            Backup-Folder -folderToBackup $AllSavesFolder -backupType "All"
        }
        3 {
            # Restore the default save folder
            $selectedBackup = Select-Backup -backupPattern $defaultSavePrefix -maxResults 10
            if ($selectedBackup) {
                Restore-Folder -restorePath $SaveGameFolder -restoreFile $selectedBackup
            }
        }
        4 {
            # Restore all saves folder
            $selectedBackup = Select-Backup -backupPattern $allSavesPrefix -maxResults 2
            if ($selectedBackup) {
                Restore-Folder -restorePath $AllSavesFolder -restoreFile $selectedBackup
            }
        }
        5 {
            Exit  # Fully exits the script
        }
        default {
            Write-Host "Invalid option. Please select again."
        }
    }

    Pause  # Pause after each action before returning to the menu
}