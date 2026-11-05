# RTSPKiosk

A UWP app that plays one RTSP camera, with audio, full screen, from the moment it launches.
It is built to run unattended as a single-app kiosk under Assigned Access on
Windows 11 IoT Enterprise LTSC 2024.

- Starts the stream at launch with no interaction, and hides the pointer.
- Keeps the display awake.
- Reconnects by itself if the camera is offline, the network is late at boot, or the stream
  ends or stalls. The reason is shown on screen between attempts.
- Re-reads the configuration on every connection attempt, so changes apply without a reinstall
  on the next reconnect (or the next restart of the app).
- Decodes through FFmpeg ([FFmpegInteropX](https://github.com/ffmpeginteropx/FFmpegInteropX)),
  so typical camera codecs work: H.264 and H.265 video, and G.711, G.726 and AAC audio.

## Configuration

`config.json` is read from the first of these locations that exists:

| Location | Use |
| --- | --- |
| `%LOCALAPPDATA%\Packages\<PackageFamilyName>\LocalState\config.json` | Per-user override, inside the kiosk account's profile |
| `C:\ProgramData\RTSPKiosk\config.json` | Machine-wide; deployed and locked down by `Install-Kiosk.ps1` |

```json
{
  "url": "rtsp://192.168.1.64:554/Streaming/Channels/101",
  "username": "viewer",
  "password": "change-me",
  "transport": "tcp"
}
```

| Key | Required | Notes |
| --- | --- | --- |
| `url` | Yes | `rtsp://` or `rtsps://` address. The path is camera-specific; the example is a Hikvision main stream. |
| `username`, `password` | No | Written as plain text, without percent-encoding; the app encodes them. Omit for an open stream. |
| `transport` | No | `tcp` (default) or `udp`. Prefer `tcp`: it passes through Windows Firewall without an inbound rule and tolerates packet loss. |

The password is stored in plain text, protected by file permissions. The machine-wide file is
readable only by Administrators, SYSTEM, the kiosk account and the app. Use a view-only camera
account.

Use the camera's stream that carries audio: many cameras default to video-only. If the stream
has no audio track, the app shows "No audio track in this stream" in the corner.

## Build

Requires Windows, the Windows SDK 10.0.26100, and Visual Studio 2022 with the **Universal Windows
Platform development** workload and the **C++ (v143) Universal Windows Platform tools** component.
With Build Tools alone, the equivalent workload is `Microsoft.VisualStudio.Workload.UniversalBuildTools`
(include its recommended components).

```powershell
.\scripts\Build-Package.ps1              # x64; add -Platform ARM64 for ARM devices
```

The build tooling doesn't supply `Microsoft.VCLibs.140.00` for ARM64. On an ARM64 device, install
that framework package first if the device doesn't already have it. x64 builds include it.

This creates `dist\` with the signed package, its framework dependencies, the public certificate,
`Install-Kiosk.ps1` and `config.sample.json`. A self-signed certificate is created on first
use. It stays in your user certificate store, so later builds can update installed devices.

## Deploy to the kiosk device

1. Create a standard local account for the kiosk, for example `kiosk`.
2. Copy `dist\` to the device and save the sample as `config.json` with the camera's details.
3. In an elevated PowerShell in that folder:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\Install-Kiosk.ps1 -KioskUser kiosk -ConfigPath .\config.json -EnableKiosk
   ```

4. Delete the `config.json` you copied, since the installed copy is the protected one.
5. Set up automatic sign-in for the kiosk account (`Set-AssignedAccess` doesn't do this), then
   restart and confirm the stream appears.

Alternatively, leave off `-EnableKiosk` and choose **Settings > Accounts > Other users > Kiosk**,
which also sets up automatic sign-in for an account it creates.

To leave the kiosk session, press Ctrl+Alt+Del and sign out.

## Troubleshooting

If the app doesn't start, try launching it, then run this in an elevated PowerShell on the device.
It changes nothing, doesn't read the password, and writes `RTSPKiosk-diagnostics.txt` next to itself:

```powershell
powershell -ExecutionPolicy Bypass -File .\Get-KioskDiagnostics.ps1
```

UWP apps can't start from the built-in Administrator account, or on any account when UAC is
disabled (`EnableLUA` = 0). Test from a standard account with UAC enabled. Crashes are recorded
in `crash.log` in the app's `LocalState` folder.

| On screen | Likely cause |
| --- | --- |
| `No configuration found` | `config.json` isn't in either location. |
| `Access denied reading ...` | The app is running as an account other than the one given to `-KioskUser`, which is the only non-admin account allowed to read the machine-wide file. Sign in as the kiosk account. If it still appears there, re-run `Install-Kiosk.ps1`. |
| `Could not open ...: COMException (0x80004005)` | Wrong address, path or credentials, or the camera is unreachable. Test the same URL from VLC on another PC. |
| `The stream stalled.` | The camera stopped sending for 15 seconds. Check its network and stream limit. |
| Video but no sound | Check for the corner notice, then the camera's audio setting, and the device's default audio output. |

## Licensing

The app uses FFmpegInteropX (Apache-2.0) and FFmpeg built under the LGPL 2.1 or later, as separate
DLLs. If you distribute the package, include those notices; the FFmpeg package's `licenses` folder
has the texts.
