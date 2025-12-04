
# **REQUISITOS COMPLETOS DEL DESAFÍO**

---

# **1. Requisitos del negocio**

1.1. Diseñar, documentar e implementar un **sistema de respaldo** para una solución productiva real de un cliente importante.

1.2. La solución a respaldar está compuesta por:

* **Power Platform** (aplicaciones, soluciones, flujos, configuraciones y datos relevantes).
* **Microsoft SharePoint Online** (documentación asociada).

  1.3. El sistema debe permitir **recuperar la solución** ante fallos, pérdidas o corrupción de datos.

---

# **2. Alcance funcional del respaldo**

2.1. La solución debe respaldar  **ambas plataformas** :

### A. **Power Platform**

* Solución productiva (Solution export).
* Aplicaciones (Canvas/Model-Driven).
* Flujos de Power Automate asociados.
* Tablas críticas de Dataverse (si aplican).
* Configuraciones, conectores y parámetros relevantes.

### B. **SharePoint Online**

* Biblioteca que contiene la documentación del cliente.
* Archivos, carpetas y estructura.
* Metadata básica (creación/modificación), si es pertinente.

2.2. La **cadencia de respaldo** debe ser definida por ti y  **justificada** .

2.3. La estrategia debe incluir:

* **Backup principal en Azure (diario)** para cumplir RPO.
* **Backup on-premise (semanal)** como parte del plan de contingencia.

2.4. Debe contemplar escenarios de restauración:

* Parcial (pérdida de un componente).
* Total (fallo completo del ambiente productivo).
* Escenario extremo (indisponibilidad del tenant o de la suscripción).

---

# **3. Requisitos de continuidad operacional**

### 3.1. **RPO = 24 horas**

* Se admite como máximo la pérdida de los cambios de un día.
* El diseño debe garantizar al menos  **un respaldo completo diario en Azure** .

### 3.2. **RTO = 6 horas**

* El proceso de restauración debe ser realizable completamente en menos de 6 horas.
* La documentación debe describir el paso a paso y justificar que el tiempo es razonable.

---

# **4. Requisitos técnicos (Azure y M365)**

4.1. Toda la solución debe ejecutarse dentro del  **entorno Azure/M365 asignado** .

4.2. Se dispone del tenant con usuario:

`milan.kurte@nofrontiersdata.com`

4.3. Se permite usar  **cualquier servicio de Azure** , siempre que cumpla con:

* Presupuesto
* Seguridad mínima
* Justificación técnica

4.4. La solución debe funcionar finalmente en el  **ambiente productivo real** .

4.5. Se puede pedir la creación de un **ambiente de desarrollo** para pruebas.

4.6. No se pueden usar **equipos físicos** como parte de la arquitectura principal del respaldo.

* Solo se permiten en el  **plan de contingencia** .

---

# **5. Requisitos de seguridad e IAM**

**Clave: IAM ≠ servicio de AWS.**

Aquí se refiere a  **Identity and Access Management** , implementado en Azure mediante:

### 5.1. **Microsoft Entra ID (Azure AD)**

* Autenticación de identidades.
* Creación de:
  * Usuarios
  * Grupos
  * Service Principals
  * Managed Identities

### 5.2. **Azure RBAC**

Debe controlar:

* Quién puede **ejecutar** el proceso de respaldo.
* Quién puede **escribir** en el Storage Account.
* Quién puede **leer/restaurar** los respaldos.

Roles típicos:

* Storage Blob Data Contributor (para la identidad de respaldo).
* Storage Blob Data Reader (para restauración).
* Permisos específicos sobre Power Platform y SharePoint solo para la identidad de servicio.

### 5.3. Debes evitar:

* Permisos globales innecesarios.
* Uso de credenciales sin control.
* Uso de identidades humanas para automatización (preferir Managed Identity).

---

# **6. Requisitos de costos**

6.1. La suscripción de Azure tiene un  **límite de 60 USD por 30 días** .

* Si superas el presupuesto, la suscripción se desactiva y  **fallas el desafío** .

6.2. El diseño debe incluir:

* Uso eficiente de Storage (ideal tier Cool).
* Azure Automation como servicio orquestador (bajo costo).
* Evitar VMs, servicios premium, o SaaS externos que excedan el presupuesto.
* Minimizar egresos de datos desde Azure.

---

# **7. Requisitos sobre límites de llamadas a APIs** (MUY IMPORTANTE)

Azure, Power Platform y Microsoft Graph tienen límites de API, por lo que:

### 7.1. La solución debe **minimizar las llamadas** para evitar:

* Throttling (HTTP 429).
* Bloqueo temporal.
* Interrupción del proceso de respaldo.

### 7.2. Debes considerar:

* Power Platform API concurrency / daily limits.
* SharePoint/Graph API throttling.
* Dataverse consumption units (si corresponde).
* Azure service limits.

### 7.3. Implicancias prácticas:

* La **cadencia diaria** para respaldos en Azure es adecuada.
* No puedes hacer respaldos cada hora o cada pocos minutos.
* Los respaldos deben estar diseñados para:
  * Leer de forma paginada.
  * Manejar reintentos con backoff exponencial.
  * Evitar escaneo completo innecesario.

### 7.4. El backup on-premise semanal  **no afecta APIs** , ya que se copia desde el Storage Account, no desde M365.

---

# **8. Requisitos del proceso de respaldo**

El diseño debe incluir:

8.1. **Cadencia:**

* Diaria en Azure (principal).
* Semanal on-premise (contingencia).

8.2. **Orquestación:**

* Runbooks en Azure Automation o scripts programados.

8.3. **Almacenamiento:**

* Azure Storage Account con contenedores separados:
  * `pp-backup`
  * `sp-backup`
  * `logs`

8.4. **Evidencias del respaldo:**

* Logs de ejecución.
* Fechas de backup.
* Trazabilidad.

---

# **9. Requisitos de documentación**

Se deben entregar:

### 9.1. **Documentación técnica**

* Diseño de arquitectura con diagramas.
* Tecnologías utilizadas.
* Flujos de respaldo.
* Justificación de decisiones (IAM, costos, APIs, cadencia).

### 9.2. **Documentación del proceso**

* Horarios y cadencia.
* Procedimiento de ejecución.
* Evidencias del respaldo.
* Manejo de fallas y reintentos.

### 9.3. **Plan de contingencia**

* Escenarios contemplados:
  * Pérdida parcial
  * Pérdida total
  * Caída del tenant
* Proceso de restauración
* Rol del respaldo on-premise semanal

### 9.4. **Sistema funcionando**

Debe haber:

* Automatización activa
* Respaldos en Storage Account
* Prueba o simulación de restauración documentada

---

# **10. Requisitos implícitos**

10.1. Buenas prácticas de ingeniería:

* Mínimo privilegio
* Segregación de roles
* Uso de naming convention
* Versionado de respaldos

10.2. Diseño simple, mantenible y justificable.

10.3. Capacidad de explicar decisiones técnicas y sus costos.

---