@echo off
setlocal EnableExtensions
set "SQLITE_LIB="
for %%I in (%IMPORT_PATHS%) do (
    if exist "%%~I\..\lib\win64\sqlite3.lib" set "SQLITE_LIB=%%~I\..\lib\win64\sqlite3.lib"
    if exist "%%~I\..\lib\win64\sqlite3.dll" set "SQLITE_DLL=%%~I\..\lib\win64\sqlite3.dll"
)
if not defined SQLITE_LIB exit /b 1
copy /Y "%SQLITE_LIB%" "%DUB_PACKAGE_DIR%" >nul
copy /Y "%SQLITE_DLL%" "%DUB_PACKAGE_DIR%" >nul
exit /b 0
