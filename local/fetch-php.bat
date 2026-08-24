@echo off
rem XCall — fetch the portable PHP 8.4 runtime (run from repo root).
set URL=https://windows.php.net/downloads/releases/php-8.4.24-nts-Win32-vs17-x64.zip
set ZIP=tools\php.zip
if not exist tools mkdir tools
echo Downloading %URL%
curl -fL -o %ZIP% %URL%
if errorlevel 1 (echo Download failed & exit /b 1)
if not exist tools\php mkdir tools\php
powershell -Command "Expand-Archive -Path tools\php.zip -DestinationPath tools\php -Force"
echo PHP ready: tools\php\php.exe
