# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Spike, at every boot as SYSTEM: print WINDOWS-BOOT-OK, the
# BitLocker state, its PCR profile, the sleep states (powercfg /a) and the
# evaluation's expiry, Fast Startup's setting (HiberbootEnabled) and how this
# boot started (Kernel-Boot event 27: 0x0 cold, 0x1 Fast Startup, 0x2 resume)
# on COM1, then act on the host's control CD (label SPIKECTL, action.txt):
# "off" powers off fully, "hibernate" powers off with Fast Startup (a hybrid
# shutdown, as the power button does), "hibernate-full" hibernates
# (shutdown /h) and, once resumed, says SPIKE-RESUMED and powers off fully,
# and no CD leaves Windows running.
function Say([string]$text) {
    $port = New-Object System.IO.Ports.SerialPort 'COM1', 115200
    $port.Open(); $port.WriteLine($text); $port.Close()
}
Say 'WINDOWS-BOOT-OK'
$v = Get-BitLockerVolume -MountPoint 'C:'
Say ("SPIKE-BL status=$($v.VolumeStatus) protection=$($v.ProtectionStatus) percent=$($v.EncryptionPercentage)")
$pcr = manage-bde -protectors -get C: | Select-String 'PCR Validation Profile' -Context 0,1
if ($pcr) { Say ("SPIKE-PCR " + (($pcr.Context.PostContext + $pcr.Line) -join ' ').Trim()) }
$power = powercfg /a | Out-String
Say ("SPIKE-POWER " + ($power -replace '\s+', ' ').Trim())
$xpr = cscript //nologo C:\Windows\System32\slmgr.vbs /xpr | Out-String
Say ("SPIKE-XPR " + ($xpr -replace '\s+', ' ').Trim())
$hb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
$bt = Get-WinEvent -FilterHashtable @{LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Boot'; Id = 27} -MaxEvents 1 -ErrorAction SilentlyContinue
Say ("SPIKE-BOOTTYPE hiberboot=$hb " + ($(if ($bt) { $bt.Message } else { 'no event 27' }) -replace '\s+', ' ').Trim())
$ctl = $null
for ($i = 0; $i -lt 30 -and -not $ctl; $i++) {
    $ctl = Get-Volume | Where-Object FileSystemLabel -eq 'SPIKECTL' | Select-Object -First 1
    if (-not $ctl) { Start-Sleep -Seconds 1 }
}
if (-not $ctl) { Say 'SPIKE-ACTION none'; exit 0 }
$action = (Get-Content "$($ctl.DriveLetter):\action.txt" -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
Say "SPIKE-ACTION $action"
# shutdown.exe has no /full: /s without /hybrid is the full shutdown (with
# /full it printed its usage and left Windows running, 2026-10-14). Its result
# goes to COM1, and a full power-off still falls back to Stop-Computer.
switch ($action) {
    'off' {
        $out = shutdown /s /t 0 2>&1 | Out-String
        Say ("SPIKE-SHUTDOWN full rc=$LASTEXITCODE " + ($out -replace '\s+', ' ').Trim())
        Start-Sleep -Seconds 60
        Say 'SPIKE-SHUTDOWN still running; Stop-Computer -Force'
        Stop-Computer -Force
    }
    'hibernate' {
        $out = shutdown /s /hybrid /t 0 2>&1 | Out-String
        Say ("SPIKE-SHUTDOWN hybrid rc=$LASTEXITCODE " + ($out -replace '\s+', ' ').Trim())
    }
    'hibernate-full' {
        $out = shutdown /h 2>&1 | Out-String
        Say ("SPIKE-SHUTDOWN hibernate rc=$LASTEXITCODE " + ($out -replace '\s+', ' ').Trim())
        # This script carries on here after the resume.
        Start-Sleep -Seconds 30
        Say 'SPIKE-RESUMED'
        shutdown /s /t 0
    }
}
