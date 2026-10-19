@echo off
cd /d "%~dp0"
".venv\Scripts\python.exe" hand_tracking.py
if errorlevel 1 pause
