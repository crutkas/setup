# crutkas WinGet Configure list

This is my winget configure script to set up a new computer.  Still work in progress.  There will need to be a hybrid of Needing admin to run.  Parts have been validated on an Azure VM but needs more validation.

Most everything in the dsc.yml should work.

## Assumptions:

- New computer with Windows 11 that can boot a dev drive.
- C:\ can be shrunk by 75 gigs to create dev drive. 
- D:\ will be dev drive

## To Run:

1. Open Windows PowerShell
2. set execution policy
3. Copy boot.ps1 to your user folder
4. run `.boot.ps1`
5. reset execution policy

## TO-DO list

### Windows Terminal
- Set PowerShell 7 as default

### File Explorer
- Uncheck "Include account-based insights"
- Uncheck "show frequently used folders"
- Check Display the full path in titlebar

### Power setting
- set to performance

### Snapping configurations
- no top
- no multi-app smart suggestion

### Monitors
- All monitors 100% scale

### System tray
- Everything to visible
- Remove bluetooth icon

### Start
- More Pins
- Turn off show recently added apps
- Turn off Show most used apps
- Turn off show recently opened items in start menu
- Turn off Show recommendations

### Taskbar
- Turn off Copilot

#### Pin taskbar
Unpin everything
- Edge 
- outlook
- VS
- vs code
- Dev Home

### Notifications
- Turn on do not disturb
- Turn off outlook
- turn off teams

### audio output config
This would be the config for my desktop but i would have a var for laptops for work profile i'd group set.
- Rename one to Headphone jack
- Rename one for sonos
- disable monitor 1
- disable monitor 2
- disable yeti

### Quick Access
- Unpin video
- Unpin music
- pin d:\source

### Dark Mode settings
Cannot currently do, only dark / light.  I have hybrid
- Windows mode - dark
- App mode - light

### Edge  (Maybe regkey)
- Bing discovery disabled
- Sidebar disabled

### Authentication
- Visual Studio enterprise

### Bluetooth 
I doubt this can be scripted out to connect on a new computer.  But I can dream :)
- Add mouse
- Add Keyboard


### Logitech Option+ Settings
- Mouse wheel to ratchet only.
