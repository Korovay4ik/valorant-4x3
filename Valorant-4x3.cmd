@echo off
title VALORANT stretched (portable)
rem The script self-elevates (UAC) and keeps its own window open at the end.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Valorant-4x3.ps1" %*
