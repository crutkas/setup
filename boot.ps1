$mypath = $MyInvocation.MyCommand.Path
Write-Output "Path of the script: $mypath"
Write-Output "Args for script: $Args"

# forcing WinGet to be installed
& .\bootstrapWinGet.ps1

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$dscUri = "https://raw.githubusercontent.com/crutkas/setup/main/"
$dscNonAdmin = "crutkas.nonAdmin.dsc.yml";
$dscAdmin = "crutkas.dsc.yml";

$dscNonAdminUri = $dscUri + $dscNonAdmin 
$dscAdminUri = $dscUri + $dscAdmin

# amazing, we can now run WinGet get fun stuff
if (!$isAdmin) {
   # love tap terminal to it gets registered moving foward
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
   Invoke-WebRequest -Uri $dscAdminUri -OutFile $dscAdmin 
   winget configuration -f $dscAdmin 
   
   # clean up, Clean up, everyone wants to clean up
   Remove-Item $dscAdmin -verbose
}
