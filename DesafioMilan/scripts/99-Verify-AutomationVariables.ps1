# ==========================================
# Verificar Variables de Azure Automation
# ==========================================
# Este script verifica que todas las variables necesarias
# estén creadas correctamente en Azure Automation

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "rg-powerplatform-automation",
    
    [Parameter(Mandatory=$false)]
    [string]$AutomationAccountName = "aa-powerplatform-backup"
)

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "VERIFICAR VARIABLES DE AUTOMATION" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Conectar a Azure si no está conectado
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "Conectando a Azure..." -ForegroundColor Yellow
        Connect-AzAccount
    }
} catch {
    Write-Host "Conectando a Azure..." -ForegroundColor Yellow
    Connect-AzAccount
}

Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor White
Write-Host "Automation Account: $AutomationAccountName" -ForegroundColor White
Write-Host ""

# Variables requeridas
$requiredVariables = @(
    @{Name="PP-ServicePrincipal-TenantId"; Encrypted=$false; Description="GUID del tenant Azure AD"},
    @{Name="PP-EnvironmentName"; Encrypted=$false; Description="GUID del environment Power Platform"},
    @{Name="StorageAccountName"; Encrypted=$false; Description="Nombre del Storage Account"},
    @{Name="StorageAccountKey"; Encrypted=$true; Description="Access Key del Storage Account"},
    @{Name="PP-ServicePrincipal-AppId"; Encrypted=$false; Description="App ID del Service Principal"},
    @{Name="PP-SolutionName"; Encrypted=$false; Description="Nombre de la solución a respaldar"}
)

Write-Host "Verificando variables requeridas..." -ForegroundColor Cyan
Write-Host ""

$allVariablesExist = $true
$variablesStatus = @()

foreach ($reqVar in $requiredVariables) {
    try {
        $variable = Get-AzAutomationVariable `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $reqVar.Name `
            -ErrorAction Stop
        
        $status = @{
            Name = $reqVar.Name
            Exists = $true
            Encrypted = $variable.Encrypted
            Value = if ($variable.Encrypted) { "***ENCRYPTED***" } else { $variable.Value }
            Description = $reqVar.Description
            ExpectedEncryption = $reqVar.Encrypted
            EncryptionMatch = ($variable.Encrypted -eq $reqVar.Encrypted)
        }
        
        $variablesStatus += $status
        
        if ($status.EncryptionMatch) {
            Write-Host "  ✓ $($reqVar.Name)" -ForegroundColor Green
            Write-Host "    Valor: $($status.Value)" -ForegroundColor Gray
            Write-Host "    Encriptada: $($variable.Encrypted)" -ForegroundColor Gray
        } else {
            Write-Host "  ⚠ $($reqVar.Name) - ERROR DE ENCRIPTACIÓN" -ForegroundColor Yellow
            Write-Host "    Esperada: $($reqVar.Encrypted), Actual: $($variable.Encrypted)" -ForegroundColor Yellow
            $allVariablesExist = $false
        }
        
    } catch {
        $status = @{
            Name = $reqVar.Name
            Exists = $false
            Encrypted = $null
            Value = $null
            Description = $reqVar.Description
            ExpectedEncryption = $reqVar.Encrypted
            EncryptionMatch = $false
        }
        
        $variablesStatus += $status
        
        Write-Host "  ✗ $($reqVar.Name) - NO EXISTE" -ForegroundColor Red
        Write-Host "    Descripción: $($reqVar.Description)" -ForegroundColor Gray
        $allVariablesExist = $false
    }
    
    Write-Host ""
}

# Verificar Credential
Write-Host "Verificando credential..." -ForegroundColor Cyan
Write-Host ""

try {
    $credential = Get-AzAutomationCredential `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name "PP-ServicePrincipal" `
        -ErrorAction Stop
    
    Write-Host "  ✓ PP-ServicePrincipal" -ForegroundColor Green
    Write-Host "    Username: $($credential.UserName)" -ForegroundColor Gray
    Write-Host ""
    
} catch {
    Write-Host "  ✗ PP-ServicePrincipal - NO EXISTE" -ForegroundColor Red
    Write-Host "    Debes crear este credential con:" -ForegroundColor Yellow
    Write-Host "      Username: App ID del Service Principal" -ForegroundColor Yellow
    Write-Host "      Password: Client Secret del Service Principal" -ForegroundColor Yellow
    Write-Host ""
    $allVariablesExist = $false
}

# Resumen
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "RESUMEN" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

$existingCount = ($variablesStatus | Where-Object { $_.Exists }).Count
$totalCount = $variablesStatus.Count

Write-Host "Variables encontradas: $existingCount / $totalCount" -ForegroundColor White

if ($allVariablesExist) {
    Write-Host ""
    Write-Host "✓ Todas las variables y credentials están configuradas correctamente" -ForegroundColor Green
    Write-Host ""
    Write-Host "Puedes ejecutar los runbooks de Backup y Restore" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "⚠ Faltan variables o credentials" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Para crear las variables faltantes, ejecuta:" -ForegroundColor Yellow
    Write-Host "  .\02-Setup-Automation.ps1" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "O créalas manualmente en Azure Portal:" -ForegroundColor Yellow
    Write-Host "  Automation Account → Variables → Add a variable" -ForegroundColor Cyan
}

Write-Host "==========================================" -ForegroundColor Cyan
