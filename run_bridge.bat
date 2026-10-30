@echo off
rem Edit the three paths below, then double-click.
set GAMELOG=C:\Games\SupremeCommander\Git-LOUD\bin\Loud-Dev.log
set SERVER=http://127.0.0.1:8080/v1
set MODEL=

python "%~dp0bridge\llm_bridge.py" --log "%GAMELOG%" --inbox "%~dp0bridge\inbox.lua" --server %SERVER% --model "%MODEL%" -v
pause
