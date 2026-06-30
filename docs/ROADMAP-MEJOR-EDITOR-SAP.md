# Roadmap para superar SAP GUI, VSCode y Eclipse

Objetivo: convertir sap-nvim en una herramienta fiable para desarrollo ABAP diario en sistemas reales. Esta lista asume que ya existen las bases actuales: ADT/sapcli, repositorio, transportes, activación, completado, hover, quickfix, ATC/AUnit, dumps, data browser, debugger cockpit y seguridad productiva.

## P0 — imprescindible antes de uso productivo serio

1. **Certificación productiva end-to-end**
   - Validar con perfiles `dev`, `qa` y `prod`.
   - Casos: TLS obligatorio, 401 pausado, usuario sin permisos, objeto estándar read-only, lock ajeno, transporte ajeno, paquete sandbox, paquete productivo.
   - Criterio: ninguna acción sensible se ejecuta sin opt-in y confirmación exacta.

2. **Debugger ABAP de nivel SAP GUI**
   - Breakpoints condicionales.
   - Debug update task, system debugging, RFC/background/job cuando ADT lo permita.
   - Watches persistentes por proyecto.
   - Tablas grandes con paginación real y filtros.
   - Limpieza robusta de listeners/sesiones tras errores o cierre de Neovim.

3. **SE80 completo en el Repository Explorer**
   - Paquetes/subpaquetes, FUGR/FM, includes, DDIC editable, dynpros/screens, GUI status/menu painter, enhancements/BAdIs, textos, mensajes y locks.
   - Fallback directo a SAP GUI por URI cuando ADT no cubra el editor estructurado.

## P1 — ganar productividad frente a VSCode/Eclipse

4. **Release/CTS operativo**
   - Orden de release con tareas/usuarios reales por ADT.
   - Diff por objeto transportado.
   - Dependencias, locks, inactivos, ATC y readiness en una sola pantalla.
   - Integración con import queue o enlace claro a STMS/SE09 cuando no exista endpoint seguro.

5. **Quality cockpit profesional**
   - Variantes ATC centrales.
   - Worklists remotas completas.
   - Exenciones con motivo, aprobador y estado, solo tras validar endpoint y permisos.
   - Tendencias de calidad por paquete/transporte.
   - Gate configurable antes de activar/liberar.

6. **Refactoring semántico remoto**
   - Rename repository-wide con preview de deltas.
   - Extract method remoto/ADT si existe.
   - Implement interface/method.
   - Call hierarchy y type hierarchy navegables.
   - Confirmación por objeto y diff antes de escribir.

7. **Workbench de datos tipo SE16N/ALV**
   - Grid filtrable, ordenable y paginado.
   - Metadata DDIC visible.
   - CDS con parámetros.
   - Export CSV/JSON.
   - Enlace desde tablas del debugger al data browser.

8. **Editores estructurados DDIC/RAP/OData**
   - Tablas: campos, keys, technical settings.
   - Dominios: fixed values.
   - Search helps y number ranges con create real validado.
   - Service definitions/bindings y publicación.
   - Behavior definitions con asistentes.

## P2 — equipo, soporte y mantenimiento

9. **gCTS/abapGit real**
   - Status, branch, pull/push, diff, conflictos y preview.
   - Confirmación fuerte para operaciones masivas.
   - Integración con repositorio y transportes.

10. **Documentación ABAP profunda**
    - ABAP Doc HTML.
    - Signature help dedicada.
    - Completion lazy-doc por item.
    - Enlaces oficiales SAP contextuales por BAPI, clase, FM, dominio y tabla.

11. **Observabilidad y soporte**
    - Historial de acciones remotas.
    - Export audit/log sin secretos.
    - Diagnóstico de roles/permisos por endpoint.
    - Monitor de jobs.
    - Recuperación guiada de locks/sesiones.

## P3 — experiencia integrada

12. **Dashboard profesional**
    - Home unificada: contexto, repositorio, transportes, calidad, debugger, favoritos, logs y acciones recientes.
    - Perfiles por proyecto.
    - Comandos discoverables sin memorizar keymaps.

13. **Pulido final de UX**
    - Menús por contexto.
    - Which-key completo.
    - Ayuda integrada por pantalla.
    - Mensajes de error con acción siguiente concreta.

## Orden recomendado

1. Cerrar P0 con validación viva real siguiendo `docs/VALIDACION-MANANA.md`.
2. Hacer release/CTS + debugger avanzado.
3. Completar SE80/DDIC/RAP.
4. Añadir refactors semánticos y workbench de datos.
5. Pulir dashboard, documentación y soporte.
