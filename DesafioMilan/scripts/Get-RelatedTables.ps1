<#
.SYNOPSIS
    Script auxiliar para encontrar tablas relacionadas automáticamente

.DESCRIPTION
    Analiza las tablas críticas y encuentra todas las tablas relacionadas
    mediante Lookup fields, N:N relationships, etc.

.PARAMETER Tables
    Array de nombres de tablas base a analizar

.EXAMPLE
    .\Get-RelatedTables.ps1 -Tables @("cr8df_actividadcalendarios", "cr391_calendario2s")
#>

param(
    [Parameter(Mandatory=$false)]
    [string[]]$Tables = @("cr8df_actividadcalendarios", "cr391_calendario2s", "cr391_casosfluentpivots", "cr8df_usuarios")
)

$ErrorActionPreference = "Stop"

Write-Host "`n=====================================" -ForegroundColor Cyan
Write-Host "Analizando tablas relacionadas" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

# Conectar a Azure y obtener token
Write-Host "`n[1/3] Conectando a Dataverse..." -ForegroundColor Yellow

try {
    # Valores desde Automation Variables (ajusta localmente si es necesario)
    $appId = "7fc4ef96-8566-4adb-a579-2030dbf71c35"
    $tenantId = "344457f2-bd03-46c6-9974-97bffb8f626a"
    $dataverseUrl = "https://org35482f4d.crm2.dynamics.com"
    
    # Leer Client Secret desde archivo seguro o prompt
    $clientSecret = Read-Host "Client Secret del Service Principal" -AsSecureString
    $clientSecretPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($clientSecret)
    )
    
    # Obtener token OAuth2
    $tokenBody = @{
        client_id = $appId
        client_secret = $clientSecretPlain
        scope = "$dataverseUrl/.default"
        grant_type = "client_credentials"
    }
    
    $tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
    $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
    $token = $tokenResponse.access_token
    
    Write-Host "  ✓ Token obtenido exitosamente" -ForegroundColor Green
    
} catch {
    Write-Error "Error conectando a Dataverse: $_"
    exit 1
}

# Analizar relationships
Write-Host "`n[2/3] Analizando relaciones..." -ForegroundColor Yellow

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
    "OData-MaxVersion" = "4.0"
    "OData-Version" = "4.0"
}

$allRelatedTables = @{}

foreach ($table in $Tables) {
    Write-Host "`n  📊 Tabla: $table" -ForegroundColor Cyan
    
    try {
        # Obtener metadata de la tabla
        $metadataUrl = "$dataverseUrl/api/data/v9.2/EntityDefinitions(LogicalCollectionName='$table')?`$select=LogicalName&`$expand=ManyToOneRelationships(`$select=ReferencingEntity,ReferencedEntity),OneToManyRelationships(`$select=ReferencingEntity,ReferencedEntity),ManyToManyRelationships(`$select=Entity1LogicalName,Entity2LogicalName)"
        
        $metadata = Invoke-RestMethod -Uri $metadataUrl -Headers $headers -Method Get
        
        # Procesar Many-to-One (Lookups)
        $lookups = $metadata.ManyToOneRelationships | Where-Object { $_.ReferencedEntity -ne 'systemuser' -and $_.ReferencedEntity -ne 'businessunit' -and $_.ReferencedEntity -ne 'owner' }
        foreach ($lookup in $lookups) {
            if (-not $allRelatedTables.ContainsKey($lookup.ReferencedEntity)) {
                $allRelatedTables[$lookup.ReferencedEntity] = "Lookup desde $table"
            }
        }
        
        # Procesar One-to-Many (tablas que apuntan a esta)
        $oneToMany = $metadata.OneToManyRelationships | Where-Object { $_.ReferencingEntity -ne 'systemuser' -and $_.ReferencingEntity -ne 'businessunit' }
        foreach ($rel in $oneToMany) {
            if (-not $allRelatedTables.ContainsKey($rel.ReferencingEntity)) {
                $allRelatedTables[$rel.ReferencingEntity] = "Referencia a $table"
            }
        }
        
        # Procesar Many-to-Many
        $manyToMany = $metadata.ManyToManyRelationships
        foreach ($rel in $manyToMany) {
            $otherEntity = if ($rel.Entity1LogicalName -eq $metadata.LogicalName) { $rel.Entity2LogicalName } else { $rel.Entity1LogicalName }
            if (-not $allRelatedTables.ContainsKey($otherEntity)) {
                $allRelatedTables[$otherEntity] = "N:N con $table"
            }
        }
        
        Write-Host "    ✓ Análisis completado" -ForegroundColor Green
        
    } catch {
        Write-Warning "    ⚠ Error analizando $table: $_"
    }
}

# Mostrar resultados
Write-Host "`n[3/3] Resultados:" -ForegroundColor Yellow
Write-Host "`n=====================================" -ForegroundColor Cyan
Write-Host "TABLAS RELACIONADAS ENCONTRADAS" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Cyan

if ($allRelatedTables.Count -eq 0) {
    Write-Host "`n  ℹ No se encontraron tablas relacionadas" -ForegroundColor Yellow
    Write-Host "  Las tablas actuales son independientes o solo relacionan con tablas estándar" -ForegroundColor Yellow
} else {
    Write-Host ""
    $allRelatedTables.GetEnumerator() | Sort-Object Name | ForEach-Object {
        Write-Host "  • $($_.Key)" -ForegroundColor White -NoNewline
        Write-Host " ($($_.Value))" -ForegroundColor Gray
    }
    
    # Generar array para agregar al runbook
    Write-Host "`n=====================================" -ForegroundColor Cyan
    Write-Host "CÓDIGO PARA RUNBOOK" -ForegroundColor Yellow
    Write-Host "=====================================" -ForegroundColor Cyan
    
    $allTables = $Tables + ($allRelatedTables.Keys | Sort-Object)
    $tableArray = "`$tables = @("
    $tableArray += ($allTables | ForEach-Object { "`"$_`"" }) -join ", "
    $tableArray += ")"
    
    Write-Host ""
    Write-Host $tableArray -ForegroundColor Green
    Write-Host ""
}

Write-Host "=====================================" -ForegroundColor Cyan
