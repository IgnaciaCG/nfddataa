<#
.SYNOPSIS
    Script para importar runbooks a Azure Automation (Fase 3)

.DESCRIPTION
    Importa los runbooks y los publica:
    - Backup-PowerPlatform.ps1: Backup diario de Power Platform y Dataverse
    - Restore-PowerPlatform.ps1: Restaurar backups de Power Platform
    - Backup-FisicoSemanal.ps1: Copia semanal a HDD local (Hybrid Worker)

.NOTES
    Autor: Milan Kurte
    Fecha: Diciembre 2025
    Versión: 1.0
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "FASE 3: Importar Runbooks" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

# Variables
$resourceGroupName = "rg-backups-nfd"
$automationAccountName = "aa-backups-nfd"
$runbooksPath = "..\runbooks"

# Runbooks a importar para Power Platform
$runbooks = @(
    @{
        Name = "Backup-PowerPlatform"
        Path = "$runbooksPath\Backup-PowerPlatform.ps1"
        Description = "Backup diario de Power Platform y Dataverse"
    },
    @{
        Name = "Restore-PowerPlatform"
        Path = "$runbooksPath\Restore-PowerPlatform.ps1"
        Description = "Restaurar backups de Power Platform y Dataverse"
    },
    @{
        Name = "Backup-FisicoSemanal"
        Path = "$runbooksPath\Backup-FisicoSemanal.ps1"
        Description = "Backup semanal a HDD on-premise (Hybrid Worker)"
    }
)

# ==========================================
# IMPORTAR RUNBOOKS
# ==========================================

$counter = 1
foreach ($runbook in $runbooks) {
    Write-Host "`n[$counter/$($runbooks.Count)] Importando: $($runbook.Name)..." -ForegroundColor Yellow
    
    try {
        # Verificar que el archivo existe
        if (-not (Test-Path $runbook.Path)) {
            throw "Archivo no encontrado: $($runbook.Path)"
        }
        
        # Importar y publicar
        Import-AzAutomationRunbook `
            -ResourceGroupName $resourceGroupName `
            -AutomationAccountName $automationAccountName `
            -Name $runbook.Name `
            -Path $runbook.Path `
            -Type PowerShell `
            -Description $runbook.Description `
            -Published `
            -Force | Out-Null
        
        Write-Host "  ✓ Runbook importado y publicado: $($runbook.Name)" -ForegroundColor Green
        
    } catch {
        Write-Error "  ✗ Error importando $($runbook.Name): $_"
    }
    
    $counter++
}

# ==========================================
# RESUMEN
# ==========================================

Write-Host "`n=====================================" -ForegroundColor Cyan
Write-Host "✓ FASE 3 COMPLETADA" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Runbooks importados: $($runbooks.Count)" -ForegroundColor White
Write-Host "Estado: Published (listo para ejecutar)" -ForegroundColor White
Write-Host "`nPróximo paso: .\04-Configure-Schedules.ps1" -ForegroundColor Magenta
Write-Host "=====================================" -ForegroundColor Cyan
