@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0..\native"
cl /nologo /std:c++17 /O2 /MT /EHsc /W3 /LD bridge.cpp user32.lib /link /OUT:discord_game_sdk.dll
exit /b %errorlevel%
