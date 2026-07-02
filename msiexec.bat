@echo off
mkdir C:\gpo_logs
echo Script lance le %date% %time% > C:\gpo_logs\glpi.txt

msiexec /i "\\SRV-AD\GPO\GLPI\GLPI-Agent-1.17-x64.msi" /qn /norestart SERVER=http://192.168.1.108/front/inventory.php TAG=AD RUNNOW=1 /l*v C:\gpo_logs\glpi_msi.txt