<#
.SYNOPSIS
    Agrega campos de marcadores a tablas Dataverse para restore

.DESCRIPTION
    Este script agrega automáticamente los campos requeridos para el restore con marcadores:
    - cr8df_backupid (Text, 100 chars)
    - cr8df_fecharestore (DateTime)
    
    A las tablas especificadas en Dataverse.

.PARAMETER EnvironmentUrl
    URL del environment Dataverse
    Ejemplo: "https://org35482f4d.crm2.dynamics.com"

.PARAMETER TablesToUpdate
    Array de nombres lógicos de tablas a actualizar
    Default: Tablas críticas del proyecto

.EXAMPLE
    .\Add-RestoreMarkerFields.ps1 -EnvironmentUrl "https://org35482f4d.crm2.dynamics.com"

.NOTES
    Requiere:
    - Service Principal con permisos System Customizer o System Administrator
    - Acceso a Dataverse Web API
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$EnvironmentUrl,
    
    [Parameter(Mandatory=$false)]
    [string[]]$TablesToUpdate = @(
        "cr8df_actividadcalendario",
        "cr391_calendario2",
        "cr391_casosfluentpivot",
        "cr8df_usuario"
    )
)

Write-Output "=========================================="
Write-Output "Agregar Campos de Marcadores a Tablas"
Write-Output "=========================================="
Write-Output ""
Write-Output "Environment: $EnvironmentUrl"
Write-Output "Tablas a actualizar: $($TablesToUpdate.Count)"
Write-Output ""

# ==========================================
# AUTENTICACIÓN
# ==========================================

Write-Output "[1/3] Autenticando..."

# Leer credenciales
$appId = Read-Host "App ID (Service Principal)"
$clientSecret = Read-Host "Client Secret" -AsSecureString
$tenantId = Read-Host "Tenant ID"

# Convertir SecureString a String
$clientSecretPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($clientSecret)
)

# Obtener token
$tokenBody = @{
    client_id = $appId
    client_secret = $clientSecretPlain
    scope = "$EnvironmentUrl/.default"
    grant_type = "client_credentials"
}

$tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"

try {
    $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
    $accessToken = $tokenResponse.access_token
    
    Write-Output "  ✓ Token obtenido"
} catch {
    Write-Output "  ✗ Error obteniendo token"
    Write-Output "  Detalles: $($_.Exception.Message)"
    exit 1
}

# Headers para API
$headers = @{
    "Authorization" = "Bearer $accessToken"
    "Content-Type" = "application/json"
    "OData-MaxVersion" = "4.0"
    "OData-Version" = "4.0"
    "Accept" = "application/json"
}

# ==========================================
# AGREGAR CAMPOS
# ==========================================

Write-Output ""
Write-Output "[2/3] Agregando campos a tablas..."
Write-Output ""

$successCount = 0
$errorCount = 0

foreach ($tableName in $TablesToUpdate) {
    Write-Output "Procesando tabla: $tableName"
    
    try {
        # Obtener metadata de la tabla
        $entityUrl = "$EnvironmentUrl/api/data/v9.2/EntityDefinitions(LogicalName='$tableName')"
        $entityResponse = Invoke-RestMethod -Uri $entityUrl -Method Get -Headers $headers
        $entityMetadataId = $entityResponse.MetadataId
        
        Write-Output "  → Entity Metadata ID: $entityMetadataId"
        
        # ==========================================
        # CAMPO 1: cr8df_backupid (Text)
        # ==========================================
        
        Write-Output "  [1/2] Agregando campo: cr8df_backupid"
        
        $field1 = @{
            "@odata.type" = "Microsoft.Dynamics.CRM.StringAttributeMetadata"
            "AttributeType" = "String"
            "AttributeTypeName" = @{
                "Value" = "StringType"
            }
            "MaxLength" = 100
            "FormatName" = @{
                "Value" = "Text"
            }
            "SchemaName" = "cr8df_backupid"
            "RequiredLevel" = @{
                "Value" = "None"
                "CanBeChanged" = $true
            }
            "DisplayName" = @{
                "@odata.type" = "Microsoft.Dynamics.CRM.Label"
                "LocalizedLabels" = @(
                    @{
                        "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel"
                        "Label" = "Backup ID"
                        "LanguageCode" = 1033
                    }
                )
            }
            "Description" = @{
                "@odata.type" = "Microsoft.Dynamics.CRM.Label"
                "LocalizedLabels" = @(
                    @{
                        "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel"
                        "Label" = "ID único del backup que originó este registro"
                        "LanguageCode" = 1033
                    }
                )
            }
        }
        
        $createFieldUrl = "$EnvironmentUrl/api/data/v9.2/EntityDefinitions($entityMetadataId)/Attributes"
        
        try {
            Invoke-RestMethod -Uri $createFieldUrl -Method Post -Headers $headers -Body ($field1 | ConvertTo-Json -Depth 10) | Out-Null
            Write-Output "    ✓ cr8df_backupid creado"
        } catch {
            if ($_.Exception.Message -like "*already exists*") {
                Write-Output "    ℹ cr8df_backupid ya existe (skip)"
            } else {
                throw
            }
        }
        
        # ==========================================
        # CAMPO 2: cr8df_fecharestore (DateTime)
        # ==========================================
        
        Write-Output "  [2/2] Agregando campo: cr8df_fecharestore"
        
        $field2 = @{
            "@odata.type" = "Microsoft.Dynamics.CRM.DateTimeAttributeMetadata"
            "AttributeType" = "DateTime"
            "AttributeTypeName" = @{
                "Value" = "DateTimeType"
            }
            "Format" = "DateAndTime"
            "ImeMode" = "Disabled"
            "DateTimeBehavior" = @{
                "Value" = "UserLocal"
            }
            "SchemaName" = "cr8df_fecharestore"
            "RequiredLevel" = @{
                "Value" = "None"
                "CanBeChanged" = $true
            }
            "DisplayName" = @{
                "@odata.type" = "Microsoft.Dynamics.CRM.Label"
                "LocalizedLabels" = @(
                    @{
                        "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel"
                        "Label" = "Fecha Restore"
                        "LanguageCode" = 1033
                    }
                )
            }
            "Description" = @{
                "@odata.type" = "Microsoft.Dynamics.CRM.Label"
                "LocalizedLabels" = @(
                    @{
                        "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel"
                        "Label" = "Fecha y hora en que se restauró este registro desde backup"
                        "LanguageCode" = 1033
                    }
                )
            }
        }
        
        try {
            Invoke-RestMethod -Uri $createFieldUrl -Method Post -Headers $headers -Body ($field2 | ConvertTo-Json -Depth 10) | Out-Null
            Write-Output "    ✓ cr8df_fecharestore creado"
        } catch {
            if ($_.Exception.Message -like "*already exists*") {
                Write-Output "    ℹ cr8df_fecharestore ya existe (skip)"
            } else {
                throw
            }
        }
        
        Write-Output "  ✓ Campos agregados a $tableName"
        $successCount++
        
    } catch {
        Write-Output "  ✗ Error en $tableName"
        Write-Output "    Detalle: $($_.Exception.Message)"
        $errorCount++
    }
    
    Write-Output ""
}

# ==========================================
# PUBLICAR CUSTOMIZACIONES
# ==========================================

Write-Output "[3/3] Publicando customizaciones..."

try {
    $publishUrl = "$EnvironmentUrl/api/data/v9.2/PublishAllXml"
    $publishBody = @{
        ParameterXml = "<importexportxml></importexportxml>"
    } | ConvertTo-Json
    
    Invoke-RestMethod -Uri $publishUrl -Method Post -Headers $headers -Body $publishBody | Out-Null
    
    Write-Output "  ✓ Customizaciones publicadas"
    Write-Output ""
    Write-Output "  IMPORTANTE: Espera 1-2 minutos para que los cambios se propaguen"
    
} catch {
    Write-Output "  ⚠ Error publicando (puede que necesites publicar manualmente)"
    Write-Output "  Ve a: Power Apps Maker Portal → Solutions → Publish All Customizations"
}

# ==========================================
# RESUMEN
# ==========================================

Write-Output ""
Write-Output "=========================================="
Write-Output "RESUMEN"
Write-Output "=========================================="
Write-Output "Tablas procesadas: $($TablesToUpdate.Count)"
Write-Output "  ✓ Exitosas: $successCount"
Write-Output "  ✗ Con errores: $errorCount"
Write-Output ""
Write-Output "CAMPOS AGREGADOS:"
Write-Output "  • cr8df_backupid (Text, 100 chars)"
Write-Output "  • cr8df_fecharestore (DateTime)"
Write-Output ""
Write-Output "PRÓXIMOS PASOS:"
Write-Output "  1. Verifica campos en Power Apps Maker Portal"
Write-Output "  2. Espera 1-2 minutos para propagación"
Write-Output "  3. Ejecuta runbook de restore"
Write-Output "=========================================="
