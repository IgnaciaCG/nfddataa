<#
.SYNOPSIS
    Script para configurar schedules de runbooks (Fase 4)

.DESCRIPTION
    Crea los schedules automáticos:
    - Backup-PowerPlatform: Diario 02:00 AM
    - Backup-FisicoSemanal: Domingo 02:00 AM

.NOTES
    Autor: Milan Kurte
    Fecha: Diciembre 2025
    Versión: 1.0
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "FASE 4: Configurar Schedules" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

# Variables
$resourceGroupName = "rg-backups-nfd"
$automationAccountName = "aa-backups-nfd"
$timeZone = "Eastern Standard Time"  # Ajustar según tu zona horaria

# ==========================================
# 1. SCHEDULE POWER PLATFORM
# ==========================================

Write-Host "`n[1/2] Creando schedule para Power Platform..." -ForegroundColor Yellow

try {
    $startTime = (Get-Date "02:00").AddDays(1)
    
    $schedulePP = New-AzAutomationSchedule `
        -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -Name "Daily-PowerPlatform-02AM" `
        -StartTime $startTime `
        -DayInterval 1 `
        -TimeZone $timeZone `
        -Description "Backup diario de Power Platform a las 02:00 AM"
    
    # Vincular a runbook
    Register-AzAutomationScheduledRunbook `
        -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -RunbookName "Backup-PowerPlatform" `
        -ScheduleName "Daily-PowerPlatform-02AM" | Out-Null
    
    Write-Host "  ✓ Schedule creado y vinculado: Diario 02:00 AM" -ForegroundColor Green
    
} catch {
    Write-Error "  ✗ Error creando schedule Power Platform: $_"
}

# ==========================================
# 2. SCHEDULE BACKUP FÍSICO
# ==========================================

Write-Host "`n[2/2] Creando schedule para Backup Físico..." -ForegroundColor Yellow

try {
    # Obtener próximo domingo
    $today = Get-Date
    $daysUntilSunday = 7 - [int]$today.DayOfWeek
    $nextSunday = $today.AddDays($daysUntilSunday).Date.AddHours(2)
    
    $schedulePhysical = New-AzAutomationSchedule `
        -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -Name "Weekly-Physical-Sunday-02AM" `
        -StartTime $nextSunday `
        -WeekInterval 1 `
        -DaysOfWeek "Sunday" `
        -TimeZone $timeZone `
        -Description "Backup semanal a HDD físico (Domingo 02:00 AM)"
    
    Register-AzAutomationScheduledRunbook `
        -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -RunbookName "Backup-FisicoSemanal" `
        -ScheduleName "Weekly-Physical-Sunday-02AM" | Out-Null
    
    Write-Host "  ✓ Schedule creado y vinculado: Semanal Domingo 02:00 AM" -ForegroundColor Green
    Write-Host "  ⚠ NOTA: Este runbook requiere Hybrid Worker configurado" -ForegroundColor Yellow
    
} catch {
    Write-Error "  ✗ Error creando schedule Backup Físico: $_"
}

# ==========================================
# RESUMEN
# ==========================================

Write-Host "`n=====================================" -ForegroundColor Cyan
Write-Host "✓ FASE 4 COMPLETADA" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Schedules configurados: 2" -ForegroundColor White
Write-Host "  - Power Platform: Diario 02:00 AM" -ForegroundColor Cyan
Write-Host "  - Backup Físico: Domingo 02:00 AM" -ForegroundColor Cyan
Write-Host "`nZona Horaria: $timeZone" -ForegroundColor White
Write-Host "`n⚠ PRÓXIMOS PASOS:" -ForegroundColor Yellow
Write-Host "1. Instalar Hybrid Runbook Worker (para backup físico)" -ForegroundColor Magenta
Write-Host "2. Probar runbooks manualmente desde Azure Portal" -ForegroundColor Magenta
Write-Host "3. Configurar alertas de monitoreo" -ForegroundColor Magenta
Write-Host "=====================================" -ForegroundColor Cyan
