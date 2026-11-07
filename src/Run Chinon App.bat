@echo off
cd /d "%~dp0"
set "PY="
for %%P in ("%LOCALAPPDATA%\Programs\Python\Launcher\py.exe" "%WINDIR%\py.exe") do if not defined PY if exist %%P set "PY=%%~P"
if not defined PY for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python3*") do if exist "%%D\python.exe" set "PY=%%D\python.exe"
if not defined PY (where py >nul 2>nul && set "PY=py")
if not defined PY (echo Python not found. Install it with:  winget install -e --id Python.Python.3.13 & pause & exit /b)
echo Using Python: %PY%
"%PY%" -m pip install --quiet pyserial numpy pillow
set "PYW=%PY:python.exe=pythonw.exe%"
set "PYW=%PYW:\py.exe=\pyw.exe%"
if exist "%PYW%" (start "" "%PYW%" chinon_app.py) else ("%PY%" chinon_app.py)
