@echo off
REM ==========================================================================
REM  GPO startup wrapper for install-logging-windows.ps1
REM
REM  The classic Group Policy "Scripts" tab launches .bat/.cmd natively but
REM  does NOT launch .ps1 reliably, so this wrapper calls PowerShell with
REM  -ExecutionPolicy Bypass. Point your GPO startup script at THIS .bat.
REM
REM  >>> EDIT THE LINE BELOW <<<  (set your Logstash host/port + source mode)
REM ==========================================================================

REM  Option A - download binaries from the internet:
set WLB_ARGS=-LogstashHost 192.168.1.104 -LogstashPort 5044

REM  Option B - use a local share that already contains winlogbeat.zip + Sysmon.zip
REM  (uncomment and edit; comment out Option A):
REM set WLB_ARGS=-LogstashHost 192.168.4.102 -SourcePath \\YOURSERVER\share

REM  Folder where install-logging-windows.ps1 lives (same folder as this .bat):
set SCRIPT_DIR=%~dp0

powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File "%SCRIPT_DIR%install-logging-windows.ps1" %WLB_ARGS%
exit /b %ERRORLEVEL%
