
## Visión general del flujo de respaldo

Vamos a usar  **tres capas** :

1. **M365 / Power Platform + SharePoint** → donde vive la solución.
2. **Azure** → donde se orquesta y guarda el respaldo diario.
3. **On-premise (HDD)** → copia física semanal como contingencia extrema.

---

## Plataformas y tecnologías involucradas

* **Power Platform (M365)**
  * Ambiente donde está la app principal, solución, flujos y (posible) Dataverse.
* **SharePoint Online (M365)**
  * Sitio / biblioteca con la documentación de la solución.
* **Microsoft Entra ID (Azure AD)**
  * Manejo de identidades y permisos (IAM).
  * Identidad técnica / managed identity para ejecutar los respaldos.
  * Roles para controlar quién puede leer/escribir respaldos.
* **Azure Automation**
  * Servicio que ejecuta **runbooks** programados (scripts) todos los días.
  * Se encarga de:
    * Conectarse a Power Platform para exportar la solución y datos críticos.
    * Conectarse a SharePoint para respaldar la documentación.
* **Azure Storage Account (Blob Storage, tier Cool)**
  * “Bodega” en la nube donde se guardan los archivos de respaldo:
    * Respaldos de Power Platform (solutions, CSV/JSON de datos).
    * Respaldos de SharePoint (zips de bibliotecas).
    * Logs de ejecución.
* **On-premise HDD (copia física semanal)**
  * Disco físico proporcionado por tu jefe.
  * Recibe una copia semanal del contenido del Storage Account usando una herramienta tipo **AzCopy** desde un PC admin.

*(Opcional si decides usarlo)*

* **Microsoft 365 Backup**
  * Servicio nativo de Microsoft para backup/restore rápido de SharePoint.
  * Se podría usar como capa específica para SharePoint, complementando lo que ya haces en Azure.

---

## Flujo diario (capa principal en Azure)

1. **02:00 AM aprox.** → Azure Automation dispara el runbook de respaldo.
2. La **identidad técnica** se autentica vía Entra ID con permisos limitados.
3. El runbook:
   * Exporta la **solución de Power Platform** (y datos críticos si aplica).
   * Extrae y empaqueta la **biblioteca de SharePoint** relevante.
4. Los archivos generados se guardan en la  **Storage Account** :
   * Contenedor `pp-backup` para Power Platform.
   * Contenedor `sp-backup` para SharePoint.
5. Se escriben **logs** en un contenedor `logs` para tener evidencia de que el respaldo corrió bien.
6. Con esto, siempre hay un respaldo con una antigüedad máxima de 24 h →  **cumple RPO** .

---

## Flujo semanal (capa física de contingencia)

1. Una vez a la semana, un admin autorizado:
   * Accede al Storage Account.
   * Usa **AzCopy** (u otra herramienta) para copiar los respaldos recientes al  **HDD externo** .
2. Registra la fecha y contenido de la copia.
3. El HDD se almacena en un lugar físico seguro.
4. Esta capa se usa solo si falla todo lo demás (caída de tenant / suscripción, incidente mayor).

---

## Restauración (vista general)

* **Caso normal (fallo lógico / pérdida parcial)**
  * Se toma el último respaldo desde Azure Storage.
  * Se importa la solución en Power Platform y se restauran documentos de SharePoint.
  * Se espera completar esto en menos de **6 horas** →  **cumple RTO** .
* **Caso extremo (tenant o suscripción comprometida)**
  * Se usa la copia del HDD para montar la solución en otro ambiente / tenant.
