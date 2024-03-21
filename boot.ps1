$mypath = $MyInvocation.MyCommand.Path
Write-Output "Path of the script: $mypath"
Write-Output "Args for script: $Args"

# forcing WinGet to be installed
$isWinGetRecent = (winget -v).Trim('v').TrimEnd("-preview").split('.')

# turning off progress bar to make invoke WebRequest fast
$ProgressPreference = 'SilentlyContinue'

if(!(($isWinGetRecent[0] -gt 1) -or ($isWinGetRecent[0] -ge 1 -and $isWinGetRecent[1] -ge 6))) # WinGet is greater than v1 or v1.6 or higher
{
   $paths = "Microsoft.VCLibs.x64.14.00.Desktop.appx", "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle", "Microsoft.UI.Xaml.2.7.x64.appx"
   $uris = "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx", "https://aka.ms/getwinget", "https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.7.3/Microsoft.UI.Xaml.2.7.x64.appx"
   Write-Host "Downloading WinGet and its dependencies..."

   for ($i = 0; $i -lt $uris.Length; $i++) {
       $filePath = $paths[$i]
       $fileUri = $uris[$i]
       Write-Host "Downloading: ($filePat) from $fileUri"
       Invoke-WebRequest -Uri $fileUri -OutFile $filePath
   }

   Write-Host "Installing WinGet and its dependencies..."
   
   foreach($filePath in $paths)
   {
       Write-Host "Installing: ($filePath)"
       Add-AppxPackage $filePath
   }

   Write-Host "Verifying Version number of WinGet"
   winget -v

   Write-Host "Cleaning up"
   foreach($filePath in $paths)
   {
      if (Test-Path $filePath) 
      {
         Write-Host "Deleting: ($filePath)"
         Remove-Item $filePath -verbose
      } 
      else
      {
         Write-Error "Path doesn't exits: ($filePath)"
      }
   }
}
else {
   Write-Host "WinGet in decent state, moving to executing DSC"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$dscUri = "https://raw.githubusercontent.com/crutkas/setup/main/"
$dscNonAdmin = "crutkas.nonAdmin.dsc.yml";
$dscAdmin = "crutkas.dev.dsc.yml";
$dscOffice = "crutkas.office.dsc.yml";
$dscPowerToysEnterprise = "Z:\source\powertoys\.configurations\configuration.vsEnterprise.dsc.yaml";

$dscOfficeUri = $dscUri + $dscOffice;
$dscNonAdminUri = $dscUri + $dscNonAdmin 
$dscAdminUri = $dscUri + $dscAdmin

# amazing, we can now run WinGet get fun stuff
if (!$isAdmin) {
   # Shoulder tap terminal to it gets registered moving foward
   Start-Process shell:AppsFolder\Microsoft.WindowsTerminal_8wekyb3d8bbwe!App

   Invoke-WebRequest -Uri $dscNonAdminUri -OutFile $dscNonAdmin 
   winget configuration -f $dscNonAdmin 
   
   # clean up, Clean up, everyone wants to clean up
   Remove-Item $dscNonAdmin -verbose

   # restarting for Admin now
	Start-Process PowerShell -wait -Verb RunAs "-NoProfile -ExecutionPolicy Bypass -Command `"cd '$pwd'; & '$mypath' $Args;`"";
	exit;
}
else {
   # admin section now
   # ---------------
    # ---------------
    # Installing office workload
    Write-Host "Start: Office install"
    New-Item -Path 'HKCU:\Software\Microsoft\Office\16.0\Outlook\' -Force
    New-ItemProperty -Path 'HKCU:\Software\Microsoft\Office\16.0\Outlook\' -Name 'DefaultProfile' -Value "OutlookAuto" -PropertyType String -Force

    New-Item -Path 'HKCU:\Software\Microsoft\Office\16.0\Outlook\OutlookAuto' -Force
    New-ItemProperty -Path 'HKCU:\Software\Microsoft\Office\16.0\Outlook\OutlookAuto' -Name 'Default' -Value "" -PropertyType String -Force


    New-Item -Path 'HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover' -Force
    New-ItemProperty -Path 'HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover' -Name 'ZeroConfigExchange' -Value "1" -PropertyType DWORD -Force

    gpupdate /force

    Invoke-WebRequest -Uri $dscOfficeUri -OutFile $dscOffice 
    winget configuration -f $dscOffice 
    Remove-Item $dscOffice -verbose
    Start-Process outlook.exe
    Start-Process ms-team.exe
    Write-Host "Done: Office install"
    # Ending office workload
    # ---------------
   # Forcing Windows Update -- goal is move to dsc
   Write-Host "Start: Windows Update"
    $UpdateCollection = New-Object -ComObject Microsoft.Update.UpdateColl
    $Searcher = New-Object -ComObject Microsoft.Update.Searcher
    $Session = New-Object -ComObject Microsoft.Update.Session
    $Installer = New-Object -ComObject Microsoft.Update.Installer
 
    $Searcher.ServerSelection = 2
 
    $Result = $Searcher.Search("IsInstalled=0 and IsHidden=0")
 
    $Downloader = $Session.CreateUpdateDownloader()
    $Downloader.Updates = $Result.Updates
    $Downloader.Download()
 
    $Installer.Updates = $Result.Updates
    $Installer.Install()
    Write-Host "Done: Windows Update"
    # Forcing Windows Update complete 

    # Staring dev workload
    Write-Host "Start: Dev flows install"
    Invoke-WebRequest -Uri $dscAdminUri -OutFile $dscAdmin 
    winget configuration -f $dscAdmin 

    Write-Host "Start: PowerToys dsc install"
    winget configuration -f $dscPowerToysEnterprise # no cleanup needed as this is intentionally local
   
    # clean up, Clean up, everyone wants to clean up
    Remove-Item $dscAdmin -verbose
    Write-Host "Done: Dev flows install"
    # ending dev workload
}