# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Spike, run once at the first logon as the administrator:
# a startup task that reports on COM1 at every boot (spike-boot.ps1), Fast
# Startup and hibernation on, BitLocker on C: with the TPM and a recovery
# password, then a full power-off once C: is fully encrypted. The recovery
# password goes to COM2 only, which the host keeps in a 0600 file (the
# firmware's console output lands there too). With "plain" in variant.txt
# (the plain variant) C: stays unencrypted instead, so Linux can read its NTFS:
# device encryption is turned off, and undone if setup already started it.
function Say([string]$text) {
    $port = New-Object System.IO.Ports.SerialPort 'COM1', 115200
    $port.Open(); $port.WriteLine($text); $port.Close()
}
Say 'SPIKE-SETUP start'
$variant = 'bitlocker'
$v = Get-Content C:\spike\variant.txt -ErrorAction SilentlyContinue | Select-Object -First 1
if ($v) { $variant = $v.Trim() }
Say "SPIKE-VARIANT $variant"
schtasks /create /tn SpikeBoot /sc onstart /ru SYSTEM /rl HIGHEST /f `
    /tr 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\spike\spike-boot.ps1' | Out-Null
$out = powercfg /h on 2>&1 | Out-String
Say ("SPIKE-HIBERNATE on rc=$LASTEXITCODE " + ($out -replace '\s+', ' ').Trim())
reg add 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' /v HiberbootEnabled /t REG_DWORD /d 1 /f | Out-Null
$tpm = Get-Tpm
Say ("SPIKE-TPM present=$($tpm.TpmPresent) ready=$($tpm.TpmReady)")
# BitLocker will not start while bootable media is in a drive (0x80310030),
# and the Windows DVD still is: eject every CD drive first.
$shell = New-Object -ComObject Shell.Application
Get-CimInstance Win32_CDROMDrive | ForEach-Object { $shell.Namespace(17).ParseName($_.Drive).InvokeVerb('Eject') }
Start-Sleep -Seconds 5
Say ("SPIKE-CD loaded=" + ((Get-CimInstance Win32_CDROMDrive | Where-Object MediaLoaded).Drive -join ','))
$enabled = $true
$want = 'FullyEncrypted'
if ($variant -eq 'plain') {
    $want = 'FullyDecrypted'
    reg add 'HKLM\SYSTEM\CurrentControlSet\Control\BitLocker' /v PreventDeviceEncryption /t REG_DWORD /d 1 /f | Out-Null
    if ((Get-BitLockerVolume -MountPoint 'C:').VolumeStatus -ne 'FullyDecrypted') {
        try { Disable-BitLocker -MountPoint 'C:' -ErrorAction Stop | Out-Null }
        catch { Say "SPIKE-BITLOCKER-ERROR $($_.Exception.Message)"; $enabled = $false }
    }
} else {
    try {
        Enable-BitLocker -MountPoint 'C:' -TpmProtector -UsedSpaceOnly -SkipHardwareTest -ErrorAction Stop | Out-Null
        Add-BitLockerKeyProtector -MountPoint 'C:' -RecoveryPasswordProtector -ErrorAction Stop | Out-Null
    } catch {
        Say "SPIKE-BITLOCKER-ERROR $($_.Exception.Message)"
        $enabled = $false
    }
}
$recovery = (Get-BitLockerVolume -MountPoint 'C:').KeyProtector |
    Where-Object KeyProtectorType -eq 'RecoveryPassword' | Select-Object -First 1 -ExpandProperty RecoveryPassword
if ($recovery) {
    $port = New-Object System.IO.Ports.SerialPort 'COM2', 115200
    $port.Open(); $port.Write($recovery); $port.Close()
}
$deadline = (Get-Date).AddMinutes(30)
do {
    Start-Sleep -Seconds 10
    $v = Get-BitLockerVolume -MountPoint 'C:'
} while ($enabled -and $v.VolumeStatus -ne $want -and (Get-Date) -lt $deadline)
Say ("SPIKE-BL status=$($v.VolumeStatus) protection=$($v.ProtectionStatus) percent=$($v.EncryptionPercentage) " +
     "method=$($v.EncryptionMethod) protectors=$(($v.KeyProtector.KeyProtectorType) -join ',')")
Say 'SPIKE-SETUP done'
# Setup ends with Windows powered off for the host, whatever else is running.
Stop-Computer -Force
