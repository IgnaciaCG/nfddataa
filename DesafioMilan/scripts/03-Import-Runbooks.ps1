<#
.SYNOPSIS
    Script para importar runbooks a Azure Automation (Fase 3)

.DESCRIPTION
    Importa los runbooks y los publica:
    - Backup-PowerPlatform.ps1: Backup diario de Power Platform y Dataverse
    - Restore-PowerPlatform.ps1: Restaurar backups de Power Platform
    - Backup-FisicoSemanal.ps1: Copia semanal a HDD local (Hybrid Worker)
    
    Usa Variables + Credentials (sin Key Vault)

.NOTES
    Autor: Milan Kurte
    Fecha: Diciembre 2025
    Versión: 1.5 (sin Key Vault)
#>

[CmdletBinding()]
param()

# ==========================================
# CONFIGURACIÓN CENTRALIZADA
# ==========================================

$ErrorActionPreference = "Stop"

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "FASE 3: Importar Runbooks" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

# Variables centralizadas (MODIFICA AQUÍ para tu proyecto)
$resourceGroupName = "rg-backups-nfd"        # ← Mismo que 01 y 02
$automationAccountName = "aa-backups-nfd"    # ← Mismo que 02
$runbooksPath = "..\runbooks"

# Runbooks a importar para Power Platform
$runbooks = @(
    @{
        Name = "Backup-PowerPlatform"
        Path = "$runbooksPath\Backup-PowerPlatform.ps1"
        Description = "Backup diario de Power Platform y Dataverse (usa Variables + Credentials)"
    },
    @{
        Name = "Restore-PowerPlatform"
        Path = "$runbooksPath\Restore-PowerPlatform.ps1"
        Description = "Restaurar backups de Power Platform y Dataverse (usa Variables + Credentials)"
    },
    @{
        Name = "Backup-FisicoSemanal"
        Path = "$runbooksPath\Backup-FisicoSemanal.ps1"
        Description = "Backup semanal a HDD on-premise (Hybrid Worker)"
    }
)

# ==========================================
# INSTALAR MÓDULOS REQUERIDOS
# ==========================================

Write-Host "`n[0/3] Instalando módulos de PowerShell..." -ForegroundColor Yellow

$requiredModules = @(
    @{
        Name = "Az.Accounts"
        ContentLink = "https://www.powershellgallery.com/api/v2/package/Az.Accounts"
    },
    @{
        Name = "Az.Storage"
        ContentLink = "https://www.powershellgallery.com/api/v2/package/Az.Storage"
    },
    @{
        Name = "Microsoft.PowerApps.Administration.PowerShell"
        ContentLink = "https://www.powershellgallery.com/api/v2/package/Microsoft.PowerApps.Administration.PowerShell"
    }
)

foreach ($module in $requiredModules) {
    Write-Host "`n  Instalando: $($module.Name)..." -ForegroundColor Cyan
    
    try {
        # Verificar si ya existe
        $existingModule = Get-AzAutomationModule `
            -ResourceGroupName $resourceGroupName `
            -AutomationAccountName $automationAccountName `
            -Name $module.Name `
            -ErrorAction SilentlyContinue
        
        if ($existingModule -and $existingModule.ProvisioningState -eq "Succeeded") {
            Write-Host "    ℹ Módulo ya instalado: $($module.Name) v$($existingModule.Version)" -ForegroundColor Gray
            continue
        }
        
        # Importar módulo
        New-AzAutomationModule `
            -ResourceGroupName $resourceGroupName `
            -AutomationAccountName $automationAccountName `
            -Name $module.Name `
            -ContentLinkUri $module.ContentLink | Out-Null
        
        Write-Host "    ✓ Módulo importado: $($module.Name) (instalando en background...)" -ForegroundColor Green
        
    } catch {
        Write-Warning "    ⚠ Error instalando $($module.Name): $_"
        Write-Host "    → Puedes instalarlo manualmente desde Azure Portal → Modules → Browse gallery" -ForegroundColor Yellow
    }
}

Write-Host "`n  ⏳ NOTA: Los módulos se instalan en background (5-10 min c/u)" -ForegroundColor Yellow
Write-Host "     Verifica en: Azure Portal → Automation Account → Modules" -ForegroundColor Gray
Write-Host "     Status debe ser: 'Available' antes de ejecutar runbooks" -ForegroundColor Gray

# ==========================================
# IMPORTAR RUNBOOKS
# ==========================================

Write-Host "`n=====================================" -ForegroundColor Cyan
Write-Host "Importando Runbooks" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

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
Write-Host ""
Write-Host "MÓDULOS INSTALADOS:" -ForegroundColor Yellow
Write-Host "  ⏳ Az.Accounts (instalando...)" -ForegroundColor Cyan
Write-Host "  ⏳ Az.Storage (instalando...)" -ForegroundColor Cyan
Write-Host "  ⏳ Microsoft.PowerApps.Administration.PowerShell (instalando...)" -ForegroundColor Cyan
Write-Host ""
Write-Host "RUNBOOKS IMPORTADOS:" -ForegroundColor Yellow
Write-Host "  Total: $($runbooks.Count)" -ForegroundColor White
Write-Host "  Estado: Published (listo para ejecutar)" -ForegroundColor White
Write-Host "  Método: Variables + Credentials (sin Key Vault)" -ForegroundColor Cyan
Write-Host ""
Write-Host "  ✓ Backup-PowerPlatform" -ForegroundColor Green
Write-Host "  ✓ Restore-PowerPlatform" -ForegroundColor Green
Write-Host "  ✓ Backup-FisicoSemanal" -ForegroundColor Green
Write-Host ""
Write-Host "⚠ ESPERAR INSTALACIÓN DE MÓDULOS:" -ForegroundColor Yellow
Write-Host "  1. Azure Portal → Automation Account → Modules" -ForegroundColor White
Write-Host "  2. Verificar que los 3 módulos tengan Status = 'Available'" -ForegroundColor White
Write-Host "  3. Tiempo estimado: 15-20 minutos total" -ForegroundColor Gray
Write-Host ""
Write-Host "PRÓXIMO PASO (después de que módulos estén 'Available'):" -ForegroundColor Magenta
Write-Host "  .\04-Configure-Schedules.ps1" -ForegroundColor White
Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
