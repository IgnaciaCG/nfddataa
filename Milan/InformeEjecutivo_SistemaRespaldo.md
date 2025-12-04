# **INFORME EJECUTIVO**

# **Sistema de Respaldo Empresarial**

## **Power Platform + SharePoint Online**

---

**Preparado por:** Milan Kurte
**Fecha:** Diciembre 2025
**Cliente:** No Frontiers Data
**Versión:** 1.0

---

## **RESUMEN EJECUTIVO**

Este documento presenta la solución de respaldo diseñada para proteger los activos digitales críticos de la organización alojados en **Microsoft Power Platform** y **SharePoint Online**. La solución garantiza la continuidad operacional ante pérdidas de datos, fallas técnicas o incidentes de seguridad, con una inversión mensual de apenas **USD $4-8**, muy por debajo del presupuesto aprobado de USD $60. Adicionalmente, la **automatización completa** del proceso genera un **ahorro neto de $72-76 mensuales** vs. procesos manuales tradicionales.

### **Indicadores Clave de la Solución**

| Indicador                                 | Valor                            | Significado                                      |
| ----------------------------------------- | -------------------------------- | ------------------------------------------------ |
| **RPO (Pérdida máxima de datos)** | 24 horas                         | Máximo un día de información podría perderse |
| **RTO (Tiempo de recuperación)**   | 6 horas                          | Sistema operativo en menos de 6 horas            |
| **Frecuencia de respaldo**          | Diaria + Semanal (automatizadas) | Protección continua sin intervención manual    |
| **Retención de datos**             | 30 días                         | Un mes de historial de respaldos                 |
| **Costo mensual**                   | USD $4-8                         | 7-13% del presupuesto disponible                 |
| **Ahorro vs. manual**               | USD $72-76/mes                   | Eliminación de 4h/mes de trabajo manual         |
| **Eficiencia presupuestaria**       | 87-93%                           | Amplio margen para crecimiento                   |

---

## **1. CONTEXTO Y NECESIDAD DEL NEGOCIO**

### **1.1 ¿Por qué necesitamos un sistema de respaldo?**

La organización depende críticamente de:

- **Aplicaciones de negocio** desarrolladas en Power Platform (Power Apps, Power Automate)
- **Documentación corporativa** almacenada en SharePoint Online
- **Datos operacionales** en bases de datos Dataverse

La pérdida de estos activos podría resultar en:

- Paralización de operaciones críticas
- Pérdida de información de clientes
- Incumplimiento de compromisos contractuales
- Daño reputacional y pérdidas financieras

### **1.2 Alcance de la Protección**

**Lo que SÍ se respaldará:**

Aplicaciones Power Apps (Canvas y Model-Driven)
Flujos automatizados de Power Automate
Soluciones completas de Power Platform
Datos críticos de tablas Dataverse
Bibliotecas de documentos en SharePoint
Estructura de carpetas y archivos
Configuraciones y metadatos relevantes

**Lo que NO requiere respaldo:**

Exchange / correos electrónicos (fuera del alcance)
OneDrive personal de usuarios
Microsoft Teams (no forma parte de la solución productiva)

---

## **2. ARQUITECTURA DE LA SOLUCIÓN**

### **2.1 Componentes Principales**

La solución utiliza exclusivamente tecnologías nativas de **Microsoft Azure** y **Microsoft 365**, garantizando compatibilidad total, soporte oficial y costos predecibles.

```
┌─────────────────────────────────────────────────────────────────┐
│                     PLATAFORMAS PRODUCTIVAS                     │
├──────────────────────────────┬──────────────────────────────────┤
│      Power Platform          │      SharePoint Online           │
│  • Aplicaciones              │  • Documentos                    │
│  • Flujos                    │  • Bibliotecas                   │
│  • Datos Dataverse           │  • Estructura de carpetas        │
└──────────────┬───────────────┴──────────────┬───────────────────┘
               │                              │
               │     Respaldo Automático      │
               │        (Diario 02:00 AM)     │
               │                              │
               ▼                              ▼
┌──────────────────────────────────────────────────────────────────┐
│              AZURE AUTOMATION (Orquestador)                      │
│  • Programación automática                                      │
│  • Autenticación segura (Managed Identity)                      │
│  • Manejo inteligente de errores                                │
└──────────────────────────┬───────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│           AZURE STORAGE ACCOUNT (Almacenamiento)                 │
│  ┌────────────────┬────────────────┬──────────────────┐         │
│  │  pp-backup     │  sp-backup     │     logs         │         │
│  │  Power Platf.  │  SharePoint    │   Auditoría      │         │
│  └────────────────┴────────────────┴──────────────────┘         │
│                                                                  │
│  Retención: 30 días | Tipo: Cool (optimizado costos)            │
└──────────────────────────┬───────────────────────────────────────┘
                           │
                           │ Copia Semanal Automatizada (Viernes 20:00)
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│         HYBRID RUNBOOK WORKER (PC On-Premise)                    │
│  • Ejecuta runbook localmente vía Azure Automation              │
│  • Descarga automática con AzCopy                               │
│  • Logs centralizados en Azure Portal                           │
└──────────────────────────┬───────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│              DISCO DURO FÍSICO (Contingencia)                    │
│  • Ubicación: PC dedicado en oficina principal                  │
│  • Responsable: Jefe de Tecnología                              │
│  • Automatización: 100% vía Hybrid Worker                       │
└──────────────────────────────────────────────────────────────────┘
```

### **2.2 ¿Cómo funciona el sistema?**

**FASE 1: Respaldo Automático (Diario - 02:00 AM)**

1. **Inicio automático** - El sistema se activa sin intervención humana
2. **Autenticación segura** - Conexión certificada a Power Platform y SharePoint
3. **Exportación inteligente** - Descarga selectiva de componentes críticos
4. **Compresión optimizada** - Reducción de tamaño para ahorro de espacio
5. **Almacenamiento seguro** - Carga cifrada a Azure Storage Account
6. **Registro de auditoría** - Generación de logs para trazabilidad

**FASE 2: Gestión de Ciclo de Vida (Automática)**

- **Días 1-7**: Respaldos en almacenamiento rápido (acceso inmediato)
- **Días 8-30**: Migración a almacenamiento económico (ahorro de costos)
- **Día 31+**: Eliminación automática (optimización de espacio)

**FASE 3: Respaldo Físico (Semanal - Viernes 20:00)**

- Copia **automatizada** vía Hybrid Runbook Worker
- Sincronización desde Azure Storage usando AzCopy
- Ejecución local en PC on-premise sin intervención manual
- Logs centralizados en Azure Automation
- Protección contra fallas catastróficas del servicio cloud

### **2.3 Innovación: Hybrid Runbook Worker**

La solución implementa una **característica técnica avanzada** que la diferencia de alternativas tradicionales:

**¿Qué es el Hybrid Runbook Worker?**

- Agente instalado en un PC on-premise que se conecta a Azure Automation
- Permite ejecutar scripts automatizados **localmente** desde la nube
- Sin costo adicional (incluido en Azure Automation)

**Beneficios para el negocio:**

- **Eliminación de intervención humana** - Copia semanal 100% automatizada
- **Ahorro de $960/año** - Sin necesidad de dedicar 1 hora semanal
- **Confiabilidad superior** - Sin riesgo de olvido o error humano
- **Gestión centralizada** - Programación y logs desde Azure Portal
- **Seguridad mejorada** - Solo permisos de lectura (SAS token limitado)

**Comparativa:**

| Aspecto                        | Proceso Manual Tradicional | Hybrid Worker (Implementado) |
| ------------------------------ | -------------------------- | ---------------------------- |
| **Intervención humana** | Requerida cada semana      | Cero                         |
| **Riesgo de olvido**     | Alto                       | Eliminado                    |
| **Costo de personal**    | $80/mes | $0               |                              |
| **Logs y trazabilidad**  | Manual                     | Automático en Azure         |
| **Consistencia**         | Variable                   | Garantizada                  |

---

## **3. ESTRATEGIA DE CONTINUIDAD OPERACIONAL**

### **3.1 Objetivos de Recuperación**

| Concepto                                 | Objetivo | Significado para el Negocio                                                |
| ---------------------------------------- | -------- | -------------------------------------------------------------------------- |
| **RPO** (Recovery Point Objective) | 24 horas | En el peor escenario, se perderían máximo los cambios de un día laboral |
| **RTO** (Recovery Time Objective)  | 6 horas  | El sistema estaría operativo nuevamente en menos de una jornada laboral   |

### **3.2 Justificación de la Cadencia Diaria**

**¿Por qué respaldamos una vez al día y no continuamente?**

1. **Equilibrio costo-beneficio**: Respaldos más frecuentes multiplicarían costos sin beneficio proporcional
2. **Límites tecnológicos**: Microsoft impone restricciones de uso de APIs que penalizan llamadas excesivas
3. **Naturaleza de los datos**: La documentación y aplicaciones no cambian minuto a minuto
4. **Horario optimizado**: 02:00 AM minimiza impacto en usuarios y maximiza disponibilidad de recursos
5. **Cumplimiento de SLA**: Satisface el RPO de 24 horas acordado

---

## **4. PLANES DE RECUPERACIÓN ANTE DESASTRES**

### **Escenario 1: Pérdida Parcial (Aplicación o Flujo Individual)**

**Probabilidad:** Media | **Impacto:** Bajo | **RTO Real:** 1-2 horas

**Proceso de Recuperación:**

1. Identificar el componente afectado
2. Descargar respaldo más reciente desde Azure
3. Importar solución en Power Platform
4. Validar funcionalidad
5. Notificar usuarios de recuperación completada

**Ejemplo práctico:** Si un flujo de Power Automate se corrompe, el equipo técnico puede restaurarlo desde el respaldo nocturno en menos de 2 horas.

---

### **Escenario 2: Pérdida Total de SharePoint**

**Probabilidad:** Baja | **Impacto:** Alto | **RTO Real:** 2-4 horas

**Proceso de Recuperación:**

1. Acceder al contenedor `sp-backup` en Azure
2. Descargar archivo comprimido más reciente
3. Restaurar biblioteca completa en SharePoint
4. Verificar estructura de carpetas y permisos
5. Comunicar disponibilidad a usuarios

**Ejemplo práctico:** Ante eliminación accidental masiva de documentos, se recupera la biblioteca completa desde el respaldo, manteniendo la estructura organizacional intacta.

---

### **Escenario 3: Falla Catastrófica del Tenant Microsoft**

**Probabilidad:** Muy Baja | **Impacto:** Crítico | **RTO Real:** 4-6 horas

**Proceso de Recuperación:**

1. Activar protocolo de contingencia
2. Recuperar respaldos desde disco duro físico
3. Provisionar ambiente alternativo (desarrollo o nuevo tenant)
4. Restaurar soluciones y documentación
5. Migrar usuarios al ambiente temporal
6. Coordinar con Microsoft para recuperación definitiva

**Protección adicional:** El respaldo semanal automatizado vía Hybrid Runbook Worker garantiza que siempre exista una copia off-cloud actualizada, sin depender de intervención humana que pueda olvidarse.

---

## **5. SEGURIDAD Y CONTROL DE ACCESOS**

### **5.1 Principios de Seguridad Implementados**

**Mínimo Privilegio:**

- Solo las identidades autorizadas pueden acceder a respaldos
- Permisos específicos por función (lectura vs. escritura vs. eliminación)
- Revisión trimestral de permisos activos

**Autenticación Segura:**

- Uso de identidades gestionadas (sin contraseñas)
- Certificados digitales para servicios automatizados
- Integración con Microsoft Entra ID (Azure AD)

**Trazabilidad Total:**

- Registro detallado de cada ejecución de respaldo
- Logs estructurados con fecha, hora y resultados
- Auditoría de accesos a datos respaldados

### **5.2 Matriz de Permisos**

| Actor                            | Puede Ejecutar Respaldo | Puede Leer Respaldos | Puede Restaurar | Puede Eliminar       |
| -------------------------------- | ----------------------- | -------------------- | --------------- | -------------------- |
| **Sistema Automatizado**   | Sí                     | Sí                  | No              | No                   |
| **Administrador Técnico** | Sí                     | Sí                  | Sí             | Solo con aprobación |
| **Jefe de Tecnología**    | Sí                     | Sí                  | Sí             | Sí                  |
| **Usuario Final**          | No                      | No                   | No              | No                   |

---

## **6. ANÁLISIS FINANCIERO**

### **6.1 Desglose de Costos Mensuales**

| Servicio                         | Función                                           | Costo Mensual (USD) |
| -------------------------------- | -------------------------------------------------- | ------------------- |
| **Azure Storage Account**  | Almacenamiento de respaldos (Cool tier, ~50GB)     | $1.50 - $3.00       |
| **Azure Automation**       | Orquestación (2 diarios + 1 semanal) ~650 min/mes | $1.30 - $2.00       |
| **Hybrid Runbook Worker**  | Agente gratuito, sin licencia adicional            | $0.00               |
| **Transferencia de Datos** | Descarga semanal (~50 GB/mes)                      | $1.00 - $2.00       |
| **Logs y Monitoreo**       | Auditoría y alertas                               | $0.50 - $1.00       |
| **HDD On-Premise**         | Reutilización de equipo existente                 | $0.00               |

**TOTAL PROYECTADO:** USD $4.30 - $8.00 por mes

### **6.2 Ahorro por Automatización**

| Método                                        | Costo Azure                                        | Esfuerzo Humano         | Costo Total Mensual | Confiabilidad |
| ---------------------------------------------- | -------------------------------------------------- | ----------------------- | ------------------- | ------------- |
| **Copia manual semanal**                 | $4-8 | ~1h/semana × $20/h = $80 |**$84-88** | Media (puede olvidarse) |                     |               |
| **Hybrid Runbook Worker (implementado)** | $4-8 | $0 (100% automatizado)                      | **$4-8**          | Alta (garantizado)  |               |

**Ahorro mensual:** ~$80 en tiempo de personal
**Beneficio adicional:** Eliminación total del riesgo de olvido humano

### **6.3 Comparación con Alternativas Comerciales**

| Solución                                    | Costo Mensual | Limitaciones                                                              |
| -------------------------------------------- | ------------- | ------------------------------------------------------------------------- |
| **Solución Propuesta (Nativa Azure)** | $4-8          | Ninguna significativa                                                     |
| **Veeam Backup for M365**              | $35-50        | Requiere infraestructura adicional, no soporta Power Platform nativamente |
| **AvePoint Cloud Backup**              | $50-80        | Alto costo, funcionalidad redundante                                      |
| **Sin respaldo**                       | $0            | ⚠️**RIESGO INACEPTABLE** - Pérdida total ante incidentes         |

**Conclusión:** La solución propuesta ofrece **protección empresarial al 10-15% del costo de alternativas comerciales** y **ahorra $80/mes vs. proceso manual**.

### **6.4 Retorno de Inversión (ROI)**

**Escenario hipotético de pérdida de datos:**

- Costo de reconstrucción manual de aplicaciones: USD $5,000 - $15,000
- Pérdida de productividad (10 usuarios x 3 días): USD $3,000 - $8,000
- Potencial pérdida de clientes: USD $10,000+
- **TOTAL POTENCIAL DE PÉRDIDA:** USD $18,000 - $33,000

**Inversión anual en respaldos:** USD $52 - $96
**Ahorro anual vs. manual:** USD $960

**ROI:** El sistema se **auto-financia** con el ahorro de tiempo humano y se paga **188-634 veces** ante un solo incidente evitado.

---

## **7. GOBERNANZA Y CUMPLIMIENTO**

### **7.1 Indicadores de Desempeño (KPIs)**

El sistema incluye monitoreo continuo con alertas automáticas:

| KPI                                     | Meta          | Medición    |
| --------------------------------------- | ------------- | ------------ |
| **Tasa de éxito de respaldos**   | ≥ 99%        | Diaria       |
| **Tiempo promedio de ejecución** | ≤ 15 minutos | Por respaldo |
| **Crecimiento mensual de datos**  | ≤ 20%        | Mensual      |
| **Disponibilidad de respaldos**   | 100%          | Continua     |

### **7.2 Procedimientos Operativos**

**Responsabilidades Definidas:**

| Actividad                                  | Responsable            | Frecuencia             |
| ------------------------------------------ | ---------------------- | ---------------------- |
| Monitoreo de ejecuciones automáticas      | Administrador Técnico | Diaria                 |
| Monitoreo de respaldo físico automatizado | Administrador Técnico | Semanal (revisar logs) |
| Verificación de integridad de respaldos   | Administrador Técnico | Quincenal              |
| Simulacro de restauración                 | Equipo Técnico        | Trimestral             |
| Revisión de permisos y accesos            | Jefe de Tecnología    | Trimestral             |
| Auditoría completa del sistema            | Auditoría Interna     | Anual                  |

### **7.3 Mejora Continua**

El sistema incluye mecanismos de mejora continua:

- **Logs estructurados** para análisis de tendencias
- **Alertas proactivas** ante anomalías
- **Revisión trimestral** de eficiencia y costos
- **Actualización semestral** de procedimientos de restauración

---

## **8. GESTIÓN DE RIESGOS**

### **8.1 Riesgos Identificados y Mitigaciones**

| Riesgo                                         | Probabilidad | Impacto  | Mitigación Implementada                                             |
| ---------------------------------------------- | ------------ | -------- | -------------------------------------------------------------------- |
| **Fallo del respaldo automático**       | Baja         | Alto     | Alertas inmediatas + revisión diaria de logs                        |
| **Exceso de presupuesto Azure**          | Muy Baja     | Medio    | Diseño optimizado (usa 15% del límite) + alertas de costo          |
| **Corrupción de datos respaldados**     | Muy Baja     | Alto     | Múltiples versiones (30 días) + copia física semanal automatizada |
| **Pérdida del disco físico**           | Baja         | Medio    | 4 discos en rotación + ubicación segura                            |
| **Limitaciones de APIs Microsoft**       | Baja         | Medio    | Respaldo nocturno + manejo inteligente de reintentos                 |
| **Indisponibilidad prolongada de Azure** | Muy Baja     | Crítico | Respaldo físico off-cloud semanal                                   |
| **Error humano en restauración**        | Media        | Medio    | Documentación detallada + capacitación trimestral                  |
| **PC on-premise apagado durante backup** | Baja         | Bajo     | Alerta automática + ejecución manual siguiente día hábil         |

### **8.2 Plan de Comunicación ante Incidentes**

**Niveles de Escalamiento:**

1. **Nivel 1 - Fallo detectado:** Administrador Técnico investiga (30 min)
2. **Nivel 2 - Requiere restauración:** Jefe de Tecnología aprueba (1 hora)
3. **Nivel 3 - Incidente mayor:** Dirección General informada (2 horas)
4. **Nivel 4 - Crisis:** Comunicación a clientes afectados (4 horas)

---

## **9. CRONOGRAMA DE IMPLEMENTACIÓN**

### **Fase 1: Preparación (Semana 1)**

- ✅ Aprovisionamiento de Azure Storage Account
- ✅ Configuración de Azure Automation Account
- ✅ Creación de identidades de servicio
- ✅ Asignación de permisos RBAC

### **Fase 2: Desarrollo (Semanas 2-3)**

- ✅ Desarrollo de scripts de respaldo Power Platform
- ✅ Desarrollo de scripts de respaldo SharePoint
- ✅ Desarrollo de runbook para Hybrid Worker
- ✅ Implementación de logs estructurados
- ✅ Configuración de políticas de retención

### **Fase 3: Pruebas (Semana 4)**

- ✅ Pruebas de respaldo en ambiente de desarrollo
- ✅ Instalación y configuración de Hybrid Worker
- ✅ Prueba de sincronización con AzCopy
- ✅ Simulacro de restauración completa
- ✅ Validación de tiempos RTO/RPO
- ✅ Ajustes y optimizaciones

### **Fase 4: Producción (Semana 5)**

- ⏳ Migración a ambiente productivo
- ⏳ Primer respaldo automático nocturno
- ⏳ Monitoreo intensivo durante 2 semanas
- ⏳ Entrega de documentación operativa

### **Fase 5: Operación (Continua)**

- 🔄 Respaldos automáticos diarios (nube)
- 🔄 Respaldos automáticos semanales (físico vía Hybrid Worker)
- 🔄 Monitoreo de jobs en Azure Portal
- 🔄 Simulacros trimestrales de restauración
- 🔄 Renovación mensual de SAS tokens
- 🔄 Mejora continua

---

## **10. BENEFICIOS ESTRATÉGICOS**

### **Para el Negocio:**

✅ **Protección de activos digitales críticos** valorados en decenas de miles de dólares
✅ **Continuidad operacional garantizada** con RTO de 6 horas
✅ **Cumplimiento de compromisos contractuales** con clientes
✅ **Reducción de riesgo reputacional** ante pérdida de datos
✅ **Tranquilidad organizacional** ante amenazas tecnológicas

### **Para el Área Técnica:**

✅ **Automatización completa** sin intervención manual (ni diaria ni semanal)
✅ **Trazabilidad total** de ejecuciones en Azure Portal
✅ **Alertas proactivas** ante anomalías o fallos
✅ **Gestión centralizada** de backups cloud y físicos
✅ **Documentación exhaustiva** de procedimientos
✅ **Arquitectura escalable** para crecimiento futuro

### **Para la Dirección:**

✅ **Inversión mínima** (USD $4-8/mes) con protección máxima
✅ **Ahorro operativo** de $80/mes vs. proceso manual
✅ **ROI excepcional** (188-634x ante un incidente)
✅ **Eliminación de dependencia humana** en proceso crítico
✅ **Cumplimiento de mejores prácticas** de la industria
✅ **Auditoría facilitada** con logs estructurados
✅ **Gobernanza clara** con KPIs medibles

---

## **11. RECOMENDACIONES Y PRÓXIMOS PASOS**

### **Recomendaciones Inmediatas:**

1. ✅ **Aprobar implementación** de la solución propuesta
2. ✅ **Designar PC on-premise** para Hybrid Runbook Worker
3. ✅ **Asegurar conectividad** del PC (encendido en horario de backup)
4. ✅ **Aprovisionar disco duro local** en PC (mínimo 100 GB)
5. ✅ **Programar capacitación** del equipo técnico en procedimientos de restauración
6. ✅ **Establecer calendario** de simulacros trimestrales

### **Próximos Pasos (60 días):**

**Semanas 1-2:**

- Inicio de implementación técnica
- Configuración de infraestructura Azure

**Semanas 3-4:**

- Desarrollo y pruebas de scripts
- Simulacro de restauración en ambiente dev

**Semanas 5-6:**

- Puesta en producción
- Primera copia física a disco externo

**Semanas 7-8:**

- Monitoreo intensivo
- Ajustes basados en métricas reales

### **Hitos Clave:**

| Hito                                           | Fecha Objetivo | Entregable                           |
| ---------------------------------------------- | -------------- | ------------------------------------ |
| **Infraestructura aprovisionada**        | Semana 1       | Storage + Automation configurados    |
| **Scripts desarrollados**                | Semana 3       | Código listo para pruebas           |
| **Simulacro exitoso**                    | Semana 4       | Evidencia de restauración funcional |
| **Primer respaldo productivo**           | Semana 5       | Sistema operativo 24/7               |
| **Primer respaldo físico automatizado** | Semana 6       | Hybrid Worker ejecutado exitosamente |
| **Documentación completa**              | Semana 8       | Runbooks operativos entregados       |

---

## **12. CONCLUSIONES**

La solución de respaldo propuesta representa una **inversión estratégica de bajo costo y alto valor** para la protección de activos digitales críticos de la organización.

### **Conclusiones Clave:**

1. **✅ CUMPLIMIENTO TOTAL** de objetivos de negocio (RPO 24h, RTO 6h)
2. **✅ EFICIENCIA FINANCIERA** excepcional (uso del 7-13% del presupuesto disponible)
3. **✅ AHORRO OPERATIVO** de $960/año vs. proceso manual
4. **✅ ARQUITECTURA SÓLIDA** basada en tecnologías Microsoft nativas y probadas
5. **✅ AUTOMATIZACIÓN 100%** - Cero intervención manual recurrente (diaria o semanal)
6. **✅ SEGURIDAD ROBUSTA** con controles de acceso multinivel y trazabilidad completa
7. **✅ ESCALABILIDAD GARANTIZADA** para crecimiento futuro sin rediseño
8. **✅ CONTINGENCIA INTEGRAL** con respaldo físico automatizado off-cloud
9. **✅ GOBERNANZA CLARA** con KPIs, procedimientos y responsabilidades definidas

### **Declaración Final:**

Este sistema de respaldo **no es un gasto, es una póliza de seguro** contra pérdidas potenciales de decenas de miles de dólares. Su implementación es **técnicamente factible, financieramente eficiente y operacionalmente sostenible**.

La inversión de **USD $4-8 mensuales** protege activos digitales valorados en más de **USD $50,000** (considerando costo de reconstrucción, pérdida de productividad y riesgo reputacional). Adicionalmente, la automatización completa genera un **ahorro neto de $72-76 mensuales** comparado con procesos manuales.

**Recomendación:** Aprobar la implementación inmediata de esta solución como parte de la estrategia de gestión de riesgos tecnológicos de la organización.

---

## **ANEXOS**

### **Anexo A: Glosario de Términos**

| Término                        | Definición                                                                 |
| ------------------------------- | --------------------------------------------------------------------------- |
| **RPO**                   | Recovery Point Objective - Pérdida máxima de datos aceptable              |
| **RTO**                   | Recovery Time Objective - Tiempo máximo para restaurar operaciones         |
| **Azure**                 | Plataforma de nube de Microsoft                                             |
| **Power Platform**        | Suite de aplicaciones low-code de Microsoft                                 |
| **Dataverse**             | Base de datos empresarial de Microsoft                                      |
| **SharePoint**            | Plataforma de gestión documental de Microsoft                              |
| **Hybrid Runbook Worker** | Agente que ejecuta scripts de Azure Automation en equipos on-premise        |
| **SAS Token**             | Secure Access Signature - Token temporal de acceso limitado a Azure Storage |
| **Managed Identity**      | Identidad de servicio gestionada automáticamente por Azure                 |
| **RBAC**                  | Role-Based Access Control - Control de acceso basado en roles               |
| **Lifecycle Policy**      | Política automática de gestión de ciclo de vida de datos                 |
| **Throttling**            | Limitación de velocidad de llamadas a APIs                                 |

### **Anexo B: Contactos Clave**

| Rol                               | Responsabilidad             | Contacto     |
| --------------------------------- | --------------------------- | ------------ |
| **Arquitecto de Solución** | Diseño e implementación   | Milan Kurte  |
| **Administrador Técnico**  | Operación diaria           | [A designar] |
| **Jefe de Tecnología**     | Aprobaciones y contingencia | [A designar] |
| **Soporte Microsoft**       | Escalamiento técnico       | Portal Azure |

### **Anexo C: Referencias**

- Documentación oficial: Azure Backup & Recovery
- Microsoft Power Platform Admin Guide
- SharePoint Online Limits and Boundaries
- Azure Cost Management Best Practices
- Microsoft 365 Security & Compliance

---

**FIN DEL INFORME EJECUTIVO**

*Este documento es confidencial y está destinado exclusivamente para uso interno de No Frontiers Data.*

---

**Preparado por:** Milan Kurte
**Revisado por:** [Pendiente]
**Aprobado por:** [Pendiente]
**Fecha de revisión:** Diciembre 2025
**Próxima revisión:** Marzo 2026
