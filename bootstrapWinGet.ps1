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