@echo off
title VALORANT stretched (portable)
rem The script self-elevates (UAC) when it needs to disable/enable monitors.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Valorant-4x3.ps1" %*
