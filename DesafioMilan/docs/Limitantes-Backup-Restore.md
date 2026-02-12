# Limitantes y Consideraciones del Sistema Backup/Restore

**Fecha:** 19-12-2025  
**Versión Backup:** 5.0  
**Versión Restore:** 5.2  

---

## 📋 ÍNDICE

1. [Limitantes al Exportar (Backup)](#limitantes-backup)
2. [Limitantes al Importar (Restore)](#limitantes-restore)
3. [Limitantes de Power Platform](#limitantes-platform)
4. [Limitantes de Arquitectura](#limitantes-arquitectura)
5. [Workarounds y Soluciones](#workarounds)

---

## 🔴 LIMITANTES AL EXPORTAR (Backup)

### 1. **Formula Columns NO se exportan correctamente**

**Problema:**
- Campos con fórmulas Power Fx causan `NullReferenceException` al importar
- Backup v5.0 los ELIMINA automáticamente del customizations.xml

**Impacto:**
- Fórmulas se pierden en el backup
- Deben recrearse MANUALMENTE después del restore

**Evidencia:**
```json
// environment-config.json
"FormulasRemoved": {
  "Count": 2,
  "Fields": [
    "cr8df_actividadcalendario.cr8df_formula1",
    "cr8df_usuario.cr8df_calculatedfield"
  ]
}
```

**Solución actual:**
- ✅ Backup detecta y remueve fórmulas automáticamente
- ✅ Documenta qué campos tenían fórmulas
- ❌ Usuario debe recrear manualmente después del restore

**Mejora futura (v6.0):**
- Exportar definición de fórmulas a JSON separado
- Incluir guía paso a paso para recrearlas

---

### 2. **Tablas System-Managed se exportan pero NO se restauran**

**Problema:**
- Se exportan 520 tablas pero solo ~400 son restaurables
- 84 tablas system-managed se intentan restaurar y fallan

**Tablas problemáticas:**
```
- aicopilot*, aiplugin* (16 tablas) - AI features específicos del environment
- appaction*, appelement* (8 tablas) - Configuración UI no portable
- agent* (6 tablas) - AI agents específicos
- attribute, entity, entitykey (metadata) - Gestionado por Dataverse
- customapi, botcomponent, catalog - System-managed
- dvtablesearch, emailserverprofile - Requieren precondiciones
- elasticfileattachment, entityrelationship - No restaurables
```

**Impacto:**
- ~15-20% de las tablas exportadas NO se pueden restaurar
- Desperdicio de espacio en backup (~1-2 MB)
- Intentos fallidos en restore (aunque ahora se filtran)

**Solución actual (v5.2):**
- ✅ Restore filtra automáticamente 84 tablas system-managed
- ❌ Backup aún las exporta (innecesario)

**Mejora futura (v6.0):**
- Agregar filtro en Backup para NO exportar estas tablas
- Reducir tamaño de backup ~20%

---

### 3. **Connections y Credentials NO se exportan**

**Problema:**
- Conexiones a servicios externos (SharePoint, SQL, APIs) NO se incluyen
- Connection References se exportan pero sin credenciales

**Impacto:**
- Flujos de Power Automate fallan después del restore
- Canvas Apps con conexiones externas no funcionan
- Usuario debe reconfigurar conexiones manualmente

**Ejemplo:**
```
miApp contiene:
- 3 flows de Power Automate (usan SharePoint connection)
- 1 canvas app (usa SQL Server connection)

Después del restore:
❌ Flows en estado "suspended" (conexión inválida)
❌ Canvas app muestra error al abrir
```

**Solución actual:**
- ⚠️ Ninguna - limitación de Power Platform

**Workaround:**
1. Después del restore, ir a Power Automate → Connections
2. Recrear cada conexión manualmente
3. Re-activar los flows afectados

---

### 4. **Datos relacionales pueden tener referencias rotas**

**Problema:**
- Si tabla A referencia tabla B (lookup/relationship)
- Y la tabla B no existe en el restore → Error 400 Bad Request

**Ejemplo:**
```json
// cr8df_actividadcalendario.json
{
  "cr8df_actividadcalendarioid": "abc123",
  "cr8df_usuario": "/cr8df_usuarios(def456)",  // Lookup a cr8df_usuario
  ...
}
```

Si `cr8df_usuario` (def456) NO existe en el environment destino:
- Error 400 al insertar el registro
- Referencia queda rota

**Impacto:**
- ~5-10% de registros pueden fallar por lookups rotos
- Especialmente en environments parcialmente poblados

**Solución actual:**
- ✅ v5.2 importa TODAS las soluciones → más tablas disponibles
- ✅ Orden de importación por prioridad (más datos primero)
- ⚠️ No hay validación de integridad referencial

**Mejora futura (v6.0):**
- Analizar dependencias entre tablas
- Ordenar inserción por grafos de dependencias
- Validar que lookups existan antes de insertar

---

### 5. **Solo se exporta 1 environment a la vez**

**Problema:**
- No hay soporte para multi-environment backup
- No se pueden comparar environments

**Impacto:**
- Para backupear 5 environments → 5 ejecuciones manuales
- No hay dashboard de estado de backups

**Solución actual:**
- ⚠️ Limitación de diseño

**Mejora futura (v7.0):**
- Parámetro `-Environments @('Dev-01', 'Dev-02', 'Prod')`
- Backup paralelo de múltiples environments
- Dashboard de estado

---

## 🔴 LIMITANTES AL IMPORTAR (Restore)

### 1. **Solo modo NewEnvironment es funcional**

**Problema:**
- Modos `UpdateCurrent` y `CreateCopy` están **DESHABILITADOS**
- Solo restauran solución (metadata), NO restauran datos

**Estado:**
```powershell
# v5.2 - Solo un modo funcional
-RestoreMode "NewEnvironment"  ✅ Funciona (solución + datos)
-RestoreMode "UpdateCurrent"   ❌ Deshabilitado (solo solución)
-RestoreMode "CreateCopy"      ❌ Deshabilitado (solo solución)
```

**Impacto:**
- No se puede hacer restore incremental
- No se puede comparar datos (original vs backup)
- Restore es "todo o nada"

**Solución actual:**
- ⚠️ Usar solo NewEnvironment (environment limpio)

**Mejora futura (v6.0):**
- Re-habilitar UpdateCurrent con upsert inteligente
- CreateCopy con marcadores temporales

---

### 2. **Token OAuth expira después de 60-120 minutos**

**Problema:**
- Ejecuciones largas (>2 horas) → Error 401 Unauthorized
- Todas las inserciones posteriores fallan

**Evidencia:**
```
15:01:17 - Autenticación exitosa
17:14:40 - Error 401 Unauthorized (2h 13min después)
  Error: TOKEN EXPIRADO (>2 horas de ejecución)
```

**Impacto:**
- Restore de backups grandes (>60k registros) falla parcialmente
- Última parte de las tablas no se restaura

**Solución actual (v5.2):**
- ✅ Detecta y muestra mensaje claro
- ❌ NO re-autentica automáticamente

**Mejora futura (v5.3):**
```powershell
# Cada 10 tablas, verificar tiempo transcurrido
if (((Get-Date) - $script:lastAuthTime).TotalMinutes -gt 60) {
    # Re-autenticar automáticamente
    Add-PowerAppsAccount -TenantID $tenantId ...
    $script:lastAuthTime = Get-Date
}
```

---

### 3. **Importación es SECUENCIAL (no paralela)**

**Problema:**
- Soluciones se importan una por una
- Datos se insertan de 1 en 1 (no batch)

**Tiempos:**
```
1 solución: ~2-3 minutos
6 soluciones: ~12-18 minutos  (6 * 3)

1000 registros: ~15 segundos
60,000 registros: ~15 minutos (60 * 15)
```

**Impacto:**
- Restore de 60k registros puede tomar 30-40 minutos
- No aprovecha paralelismo de Azure

**Solución actual:**
- ⚠️ Limitación de diseño

**Mejora futura (v6.0):**
- Importación paralela de soluciones (si no hay dependencias)
- Batch insert (100 registros por request)
- Reducir tiempo ~70% (40min → 12min)

---

### 4. **No hay rollback automático si falla**

**Problema:**
- Si restore falla a mitad → environment queda en estado inconsistente
- Solución parcialmente importada + datos parciales

**Ejemplo:**
```
✅ miApp importada (solución completa)
❌ FluentPivotPrueba falla (error de dependencias)
✅ 30,000 registros insertados
❌ 31,000 registros fallan (token expirado)

Resultado: Environment corrupto
- Mitad de los datos
- Una solución faltante
- No hay forma de "deshacer"
```

**Impacto:**
- En caso de fallo → environment debe limpiarse manualmente
- No hay punto de restauración

**Solución actual:**
- ⚠️ Backup preventivo al inicio (manual)
- Lock file previene ejecuciones concurrentes

**Mejora futura (v7.0):**
- Transacciones simuladas (snapshot inicial)
- Rollback automático si falla
- Checkpoint cada N tablas

---

### 5. **Dependencias entre soluciones NO se validan**

**Problema:**
- Si Solution A depende de Solution B
- Y B no se importa primero → Error

**Ejemplo:**
```
FluentPivotPrueba depende de miApp (base)
Orden de importación:
  1. FluentPivotPrueba ❌ Falla (dependencia no satisfecha)
  2. miApp ✅ Importa

Debería ser:
  1. miApp ✅ 
  2. FluentPivotPrueba ✅
```

**Solución actual (v5.2):**
- ✅ Ordena por "score" (más datos = más importante)
- ⚠️ NO analiza dependencias declaradas en solution.xml

**Mejora futura (v6.0):**
```powershell
# Leer dependencies de cada solution.xml
<UniqueName>miApp</UniqueName>
<Dependencies>
  <Dependency version="1.0">
    <RequiredSolutionUniqueName>BaseLibrary</RequiredSolutionUniqueName>
  </Dependency>
</Dependencies>

# Crear grafo de dependencias
# Ordenar topológicamente
# Importar en orden correcto
```

---

## 🔴 LIMITANTES DE POWER PLATFORM

### 1. **No existe API para backup nativo**

**Problema:**
- Power Platform NO tiene API de backup/restore completo
- Debemos usar:
  - Solutions API (metadata)
  - Dataverse Web API (datos)
  - Admin API (environments)

**Impacto:**
- Solución es "custom" y frágil
- Cada cambio de API puede romper el runbook
- No hay garantía de consistencia

**Comparación con competencia:**
```
Salesforce: Backup API nativa (full, incremental, point-in-time)
Dynamics 365: Backup automático cada 24h
AWS RDS: Snapshots automáticos + point-in-time recovery
```

**Power Platform:**
```
❌ No hay backup API
❌ No hay snapshots
❌ No hay point-in-time recovery
✅ Solo: Export solution manual + Data Export Service (pago extra)
```

---

### 2. **Límites de API (throttling)**

**Problema:**
- Dataverse API tiene límites de rate
- 6,000 requests / 5 minutos / usuario

**Cálculo:**
```
60,000 registros * 1 request cada uno = 60,000 requests
60,000 / 6,000 = 10 ventanas de 5 minutos
10 * 5 min = 50 minutos MÍNIMO

Real: ~40-60 minutos (con throttling y retries)
```

**Impacto:**
- Restore lento (inevitable)
- Puede causar 429 Too Many Requests
- No hay forma de acelerar

**Solución actual:**
- ⚠️ Inserción secuencial respeta límites implícitamente

**Mejora futura:**
- Implementar retry exponencial en 429
- Batch inserts (reduce requests a 60,000/100 = 600)

---

### 3. **Managed Solutions NO se pueden modificar**

**Problema:**
- Si la solución en el backup es Managed
- NO se puede modificar después del restore
- NO se pueden agregar campos custom

**Impacto:**
- Environment destino queda "bloqueado"
- No se puede extender la aplicación

**Solución actual:**
- ⚠️ Detecta Managed vs Unmanaged y advierte

**Workaround:**
- Re-exportar como Unmanaged desde origen
- O crear nueva solución Unmanaged en destino

---

## 🔴 LIMITANTES DE ARQUITECTURA

### 1. **Azure Automation tiene timeout de 3 horas**

**Problema:**
- Jobs de Azure Automation tienen límite de 3 horas
- Si backup/restore toma más → se aborta

**Cálculo:**
```
Backup grande:
- 7 soluciones * 5 min = 35 min
- 100k registros * 1 seg = 100 min
Total: ~135 minutos ✅ OK

Backup muy grande:
- 15 soluciones * 5 min = 75 min
- 500k registros * 1 seg = 500 min
Total: ~575 minutos ❌ TIMEOUT (>180 min)
```

**Impacto:**
- Backups de environments muy grandes (>100k registros) no son viables
- Se necesitaría approach diferente

**Solución actual:**
- ⚠️ Solo funciona para environments medianos (<100k registros)

**Mejora futura:**
- Usar Azure Functions Durable (sin timeout)
- O dividir en múltiples jobs chained

---

### 2. **Storage Account no tiene versionado**

**Problema:**
- Cada backup sobrescribe el anterior (si mismo nombre)
- No hay historial de versiones

**Impacto:**
- Si backup corrupto sobrescribe backup bueno → pérdida de datos
- No hay forma de "volver" a backup anterior

**Solución actual:**
- ✅ Timestamp en nombre de archivo evita sobrescritura
```
PowerPlatform_Backup_18-12-2025 14-56-44.zip
PowerPlatform_Backup_19-12-2025 08-30-15.zip
```

**Mejora futura:**
- Habilitar blob versioning en Storage Account
- Retención configurable (7/30/90 días)
- Lifecycle policy para borrar backups antiguos

---

### 3. **No hay encriptación end-to-end**

**Problema:**
- Datos sensibles (emails, phones, etc.) se exportan en texto plano
- ZIP NO está encriptado
- Storage Account usa encryption at-rest pero admin puede leer

**Impacto de seguridad:**
```
ALTO RIESGO:
- Datos personales (GDPR/LGPD)
- Información financiera
- Secretos de negocio

Si storage account se compromete:
→ Todos los datos expuestos
```

**Solución actual:**
- ⚠️ Solo encryption at-rest de Azure Storage
- ❌ No hay encriptación client-side

**Mejora futura (v7.0):**
```powershell
# Encriptar ZIP con AES-256 usando Azure Key Vault
$key = Get-AzKeyVaultSecret -VaultName "MyVault" -Name "BackupKey"
Protect-Zip -Path $zipPath -Key $key.SecretValue

# En restore:
$key = Get-AzKeyVaultSecret -VaultName "MyVault" -Name "BackupKey"
Unprotect-Zip -Path $zipPath -Key $key.SecretValue
```

---

## ✅ WORKAROUNDS Y SOLUCIONES

### 1. **Para Formula Columns**

**Problema:** Se pierden en el backup

**Solución:**
1. Documentar fórmulas ANTES del backup
2. Recrear manualmente DESPUÉS del restore
3. Usar environment-config.json como checklist

```powershell
# Script helper (futuro)
$formulas = Get-Content "environment-config.json" | ConvertFrom-Json
foreach ($formula in $formulas.FormulasRemoved.Fields) {
    Write-Host "Recrear: $formula"
}
```

---

### 2. **Para Token Expirado (401)**

**Problema:** Token expira en 60-120 min

**Solución temporal:**
- Ejecutar restore en environment limpio (menos tiempo)
- Dividir backup en múltiples archivos
- Importar soluciones por separado

**Solución permanente (v5.3):**
```powershell
# Re-autenticación automática implementada
```

---

### 3. **Para Connections rotas**

**Problema:** Flujos y apps no funcionan después del restore

**Checklist post-restore:**
```
□ 1. Power Automate → Connections → Recrear todas
□ 2. Flows → Re-activar (Edit → Save)
□ 3. Canvas Apps → Edit → Re-connect data sources → Publish
□ 4. Probar funcionalidad crítica
```

---

### 4. **Para Dependencies entre soluciones**

**Problema:** Orden de importación incorrecto

**Workaround manual:**
```powershell
# 1. Listar soluciones en backup
$solutions = Get-ChildItem "extracted/solutions/*.zip"

# 2. Identificar base solutions (sin dependencias)
# Base: miApp, PowerAppsCore
# Dependent: FluentPivotPrueba (depende de miApp)

# 3. Ejecutar restore múltiples veces con parámetro específico
.\Restore-PowerPlatform.ps1 -SolutionName "miApp"
.\Restore-PowerPlatform.ps1 -SolutionName "FluentPivotPrueba"
```

---

### 5. **Para Managed Solutions**

**Problema:** No se pueden modificar después del restore

**Workaround:**
```
1. En environment ORIGEN:
   - Export como Unmanaged

2. En environment DESTINO (después del restore):
   - Si necesitas extender:
     - Crear nueva solución Unmanaged
     - Agregar componentes de la Managed como "Extend"
```

---

## 📊 RESUMEN DE LIMITANTES POR PRIORIDAD

### 🔴 CRÍTICOS (Impiden uso en producción)

| Limitante | Impacto | Workaround Disponible |
|-----------|---------|---------------------|
| Formula Columns perdidas | Alto | ✅ Manual (recrear) |
| Token expira (401) | Alto | ⚠️ Parcial (dividir backup) |
| No hay rollback | Alto | ❌ No |
| Managed Solutions inmutables | Medio-Alto | ✅ Re-exportar Unmanaged |

### 🟡 IMPORTANTES (Afectan eficiencia)

| Limitante | Impacto | Workaround Disponible |
|-----------|---------|---------------------|
| Importación secuencial | Medio | ❌ No (rediseño) |
| 84 tablas no restaurables | Medio | ✅ Filtradas automáticamente |
| Connections rotas | Medio | ✅ Manual (recrear) |
| Dependencies no validadas | Medio | ✅ Manual (orden correcto) |

### 🟢 MENORES (Mejoras deseables)

| Limitante | Impacto | Workaround Disponible |
|-----------|---------|---------------------|
| Solo 1 environment por backup | Bajo | ✅ Múltiples ejecuciones |
| No hay versionado | Bajo | ✅ Timestamp en nombre |
| No hay encriptación E2E | Bajo-Medio | ❌ Requiere Key Vault |

---

## 🎯 ROADMAP DE MEJORAS

### v5.3 (Próxima - Enero 2026)
- ✅ Re-autenticación automática cada 60 min
- ✅ Retry en 429 Too Many Requests
- ✅ Checkpoint cada 1000 registros

### v6.0 (Q1 2026)
- ✅ Batch inserts (100 records/request)
- ✅ Análisis de dependencias entre soluciones
- ✅ Filtro de system-managed en Backup
- ✅ Export de definiciones de fórmulas a JSON
- ✅ Validación de integridad referencial

### v7.0 (Q2 2026)
- ✅ Encriptación client-side con Key Vault
- ✅ Multi-environment backup paralelo
- ✅ Rollback automático con snapshots
- ✅ Dashboard de estado de backups
- ✅ Migración a Azure Functions Durable

---

**Autor:** GitHub Copilot  
**Fecha:** 19-12-2025  
**Versión documento:** 1.0
