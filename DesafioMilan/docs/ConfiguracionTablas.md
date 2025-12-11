# Configuración de Tablas para Backup

## Estrategia Actual: Auto-detección de Relaciones

El backup detecta automáticamente tablas relacionadas usando metadata de Dataverse.

### Tablas Críticas (Manuales)

Definidas en `$criticalTables`:
```powershell
$criticalTables = @(
    "cr8df_actividadcalendarios",
    "cr391_calendario2s", 
    "cr391_casosfluentpivots",
    "cr8df_usuarios"
)
```

### Tablas Relacionadas (Auto-detectadas)

El script busca relaciones **Many-to-One (N:1)** de las tablas críticas.

**Ejemplo:**
- Si `cr8df_actividadcalendarios` tiene lookup a `account` → Exporta `account`
- Si `cr391_casosfluentpivots` tiene lookup a `incident` → Exporta `incident`

### Filtros Aplicados

Se **excluyen** automáticamente:
- `systemuser` (usuario del sistema)
- `businessunit` (unidad de negocio)
- `organization` (organización)
- `owner` (propietario genérico)
- Tablas que empiezan con `system*`

### Cómo Agregar Más Filtros

Si quieres **excluir tablas standard de Microsoft** (solo exportar custom):

```powershell
# En línea ~385 del runbook, cambiar:
if ($relatedTable -and 
    $relatedTable -notlike 'system*' -and
    $relatedTable -ne 'organization' -and
    $relatedTable -ne 'businessunit' -and
    $relatedTable -ne 'owner' -and
    $allTablesToExport -notcontains $relatedTable) {

# Por esto (solo tablas custom con prefijo):
if ($relatedTable -and 
    ($relatedTable -like 'cr8df_*' -or $relatedTable -like 'cr391_*') -and  # Solo custom tables
    $allTablesToExport -notcontains $relatedTable) {
```

### Cómo Agregar Más Tablas Críticas

Edita el array `$criticalTables` en el runbook:

```powershell
$criticalTables = @(
    "cr8df_actividadcalendarios",
    "cr391_calendario2s", 
    "cr391_casosfluentpivots",
    "cr8df_usuarios",
    "nueva_tabla_custom",        # ← Agregar aquí
    "otra_tabla_importante"      # ← O aquí
)
```

Luego reimporta: `.\03-Import-Runbooks.ps1`

### Estimación de Tamaño

| Escenario | Registros | Tamaño Estimado |
|-----------|-----------|-----------------|
| Solo 4 tablas críticas | 100-500 | 50-200 KB |
| + 3-5 relaciones standard | +500-2000 | +200-800 KB |
| + Custom tables grandes | +5000+ | +2-5 MB |

**Lifecycle policy se encarga de mover a Cold después de 60 días.**

### Tipos de Relaciones Detectadas

- **Many-to-One (N:1)** ✅ Detectado (lookup fields)
- **One-to-Many (1:N)** ❌ No detectado (evita explosión de datos)
- **Many-to-Many (N:N)** ❌ No detectado (tablas intermedias no críticas)

Si necesitas **1:N o N:N**, agrégalas manualmente a `$criticalTables`.

### Ventajas de la Auto-detección

1. ✅ **Integridad referencial** automática
2. ✅ **Sin errores de restore** por lookups faltantes
3. ✅ **Dinámico** - si agregas lookup a tabla crítica, se exporta automáticamente
4. ✅ **Eficiente** - solo exporta lo necesario

### Ejemplo Real de Log

```json
{
  "timestamp": "2025-12-10T20:30:00Z",
  "solution": "miApp",
  "criticalTables": ["cr8df_actividadcalendarios", "cr391_calendario2s", "cr391_casosfluentpivots", "cr8df_usuarios"],
  "relatedTablesDetected": ["account", "contact", "incident"],
  "totalTablesExported": 7,
  "totalRecords": 1093,
  "backupSizeMB": 0.8
}
```
