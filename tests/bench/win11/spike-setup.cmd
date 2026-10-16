@echo off
REM SPDX-License-Identifier: GPL-3.0-or-later
REM SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
rem Spike, first logon: install the boot task, then turn
rem BitLocker on (or, with variant.txt saying "plain", keep it off) and power
rem off once C: is fully encrypted (or decrypted).
mkdir C:\spike 2>nul
copy /y "%~dp0spike-boot.ps1" C:\spike\ >nul
copy /y "%~dp0spike-setup.ps1" C:\spike\ >nul
if exist "%~dp0variant.txt" copy /y "%~dp0variant.txt" C:\spike\ >nul
powershell -NoProfile -ExecutionPolicy Bypass -File C:\spike\spike-setup.ps1
