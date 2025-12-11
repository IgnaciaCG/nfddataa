<#
.SYNOPSIS
    Otorga permisos de creación de environments al Service Principal
    
.DESCRIPTION
    Este script asigna el rol "Power Platform Administrator" al Service Principal
    para permitirle crear nuevos environments.
    
.NOTES
    Requiere:
    - Permisos de Global Administrator en Azure AD
    - Módulo Microsoft.Graph instalado
#>

# Configuración
$ServicePrincipalAppId = "7fc4ef96-8566-4adb-a579-2030dbf71c35"
$TenantId = "344457f2-bd03-46c6-9974-97bffb8f626a"

Write-Host "==========================================`n"
Write-Host "OTORGAR PERMISOS DE CREACIÓN DE ENVIRONMENTS"
Write-Host "`n=========================================="
Write-Host ""
Write-Host "App ID: $ServicePrincipalAppId"
Write-Host "Tenant: $TenantId"
Write-Host ""

# Instalar módulo si no existe
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Write-Host "Instalando módulo Microsoft.Graph..."
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

# Conectar a Microsoft Graph
Write-Host "Conectando a Microsoft Graph..."
Write-Host "(Se abrirá ventana de autenticación - usa cuenta con permisos de Global Admin)"
Write-Host ""
Connect-MgGraph -TenantId $TenantId -Scopes "RoleManagement.ReadWrite.Directory"

# Buscar el Service Principal
Write-Host "Buscando Service Principal..."
$servicePrincipal = Get-MgServicePrincipal -Filter "AppId eq '$ServicePrincipalAppId'"

if (-not $servicePrincipal) {
    Write-Host "✗ ERROR: Service Principal no encontrado" -ForegroundColor Red
    exit 1
}

Write-Host "  ✓ Service Principal encontrado" -ForegroundColor Green
Write-Host "    ID: $($servicePrincipal.Id)"
Write-Host "    Display Name: $($servicePrincipal.DisplayName)"
Write-Host ""

# Buscar el rol "Power Platform Administrator"
Write-Host "Buscando rol 'Power Platform Administrator'..."
$roleDefinition = Get-MgRoleManagementDirectoryRoleDefinition -Filter "DisplayName eq 'Power Platform Administrator'"

if (-not $roleDefinition) {
    Write-Host "✗ ERROR: Rol 'Power Platform Administrator' no encontrado" -ForegroundColor Red
    exit 1
}

Write-Host "  ✓ Rol encontrado" -ForegroundColor Green
Write-Host "    ID: $($roleDefinition.Id)"
Write-Host ""

# Verificar si ya tiene el rol asignado
Write-Host "Verificando asignaciones actuales..."
$existingAssignment = Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$($servicePrincipal.Id)' and roleDefinitionId eq '$($roleDefinition.Id)'"

if ($existingAssignment) {
    Write-Host "  ℹ El Service Principal ya tiene el rol asignado" -ForegroundColor Yellow
    Write-Host "    Fecha asignación: $($existingAssignment.CreatedDateTime)"
} else {
    Write-Host "  ℹ El rol NO está asignado actualmente"
    Write-Host ""
    
    # Asignar el rol
    Write-Host "Asignando rol 'Power Platform Administrator'..."
    try {
        $params = @{
            PrincipalId = $servicePrincipal.Id
            RoleDefinitionId = $roleDefinition.Id
            DirectoryScopeId = "/"
        }
        
        $assignment = New-MgRoleManagementDirectoryRoleAssignment -BodyParameter $params
        
        Write-Host "  ✓ Rol asignado exitosamente" -ForegroundColor Green
        Write-Host "    Assignment ID: $($assignment.Id)"
    } catch {
        Write-Host "  ✗ ERROR asignando rol" -ForegroundColor Red
        Write-Host "    Mensaje: $($_.Exception.Message)"
        exit 1
    }
}

Write-Host ""
Write-Host "==========================================`n"
Write-Host "VERIFICACIÓN FINAL"
Write-Host "`n=========================================="
Write-Host ""

# Listar todos los roles del Service Principal
$allAssignments = Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$($servicePrincipal.Id)'"

Write-Host "Roles asignados al Service Principal:"
Write-Host ""

foreach ($assignment in $allAssignments) {
    $role = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $assignment.RoleDefinitionId
    Write-Host "  • $($role.DisplayName)"
    Write-Host "    Asignado: $($assignment.CreatedDateTime)"
    Write-Host ""
}

Write-Host "==========================================`n"
Write-Host "SIGUIENTE PASO"
Write-Host "`n=========================================="
Write-Host ""
Write-Host "1. El Service Principal ahora tiene permisos para crear environments"
Write-Host ""
Write-Host "2. Ejecuta el restore nuevamente:"
Write-Host "   BackupFileName: PowerPlatform_Backup_11-12-2025 15-51-09.zip"
Write-Host "   RestoreMode: NewEnvironment"
Write-Host "   NewEnvironmentName: Dev-04"
Write-Host "   NewEnvironmentRegion: unitedstates"
Write-Host "   NewEnvironmentType: Sandbox"
Write-Host ""
Write-Host "3. La creación del environment debería funcionar ahora"
Write-Host ""

Disconnect-MgGraph
