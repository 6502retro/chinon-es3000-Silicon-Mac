@echo off
cd /d "%~dp0"
set "PY="
for %%P in ("%LOCALAPPDATA%\Programs\Python\Launcher\py.exe" "%WINDIR%\py.exe") do if not defined PY if exist %%P set "PY=%%~P"
if not defined PY for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python3*") do if exist "%%D\python.exe" set "PY=%%D\python.exe"
if not defined PY (where py >nul 2>nul && set "PY=py")
if not defined PY (echo Python not found. Install it with:  winget install -e --id Python.Python.3.13 & pause & exit /b)
echo Using Python: %PY%
echo Installing build tools (first time only)...
"%PY%" -m pip install --quiet pyserial numpy pillow pyinstaller
"%PY%" -m PyInstaller --noconfirm --clean --onefile --windowed --name "Chinon ES-3000" --icon chinon.ico --add-data "chinon_params.json;." --add-data "chinon.ico;." chinon_app.py
if exist "dist\Chinon ES-3000.exe" (
  if exist "..\Chinon ES-3000.exe" copy /y "dist\Chinon ES-3000.exe" "..\Chinon ES-3000.exe" >nul
  echo.
  echo Done! The new "Chinon ES-3000.exe" is in the dist folder
  if exist "..\Chinon ES-3000.exe" echo and has been copied next to this folder.
  rmdir /s /q build 2>nul
  del "Chinon ES-3000.spec" 2>nul
) else (echo Build failed - copy the messages above to Claude.)
pause
