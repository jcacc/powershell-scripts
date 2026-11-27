@echo off
rem Launches AdminDeck (WPF frontend for the scripts in this repo) without a console window.
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0AdminDeck\AdminDeck.ps1"
