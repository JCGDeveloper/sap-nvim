# Productivo: sapcli vs ADT directo

Fecha: 2026-06-26

## Estado guardado

- CDS se crea por ADT directo con `language/masterLanguage = ES`.
- `ZCDS_PRUEBA2` fue creada en `$TMP`, validada con `checkruns`, activada y ya no aparece inactiva.
- `<leader>aR` vuelve a ejecutar el programa/report (`:SapRun`, WebGUI/SE38).
- `<leader>aA` activa raíz + includes relacionados (`:SapActivateRecursive`).
- `<leader>aa` activa solo el objeto actual (`:SapActivate`).
- Activación masiva usa ADT `/sap/bc/adt/activation` con preaudit y activación final.
- Debugger y preview de variables usan ADT directo y deben seguir endureciéndose para productivo.
- Modo productivo inicial añadido:
  - `productive.safe_mode = true`;
  - `productive.confirm_destructive = true`;
  - borrar objetos, liberar transportes, borrar transportes y reasignar transportes exige escribir el nombre/ID exacto.
- Endurecimiento final de perfiles:
  - `profile = "dev" | "qa" | "prod"`;
  - `prod` arranca en `read_only=true`, exige TLS verificado y bloquea create/write/release/delete/set-variable salvo opt-in explícito;
  - `sapcli` y ADT directo comparten gates centrales para acciones sensibles;
  - cada intento sensible permitido o bloqueado se registra en el audit log local JSONL.
- Edición principal migrada a ADT directo:
  - `source.open` lee por `GET <obj>/source/main`;
  - `source.push` guarda por `LOCK -> PUT source/main -> UNLOCK`;
  - `:SapActivate` guarda por ADT y activa por `/sap/bc/adt/activation`;
  - `sapcli read/write` queda solo como fallback de lectura para tipos no soportados por ADT.

## Criterio técnico

Para desarrollo profesional/productivo, la regla debe ser:

- Usar ADT directo para operaciones editoriales finas, interactivas o críticas: leer/escribir source con lock explícito, crear objetos, syntax check, activación, debugger, hover, navegación, quickfix, preview.
- Mantener `sapcli` donde aporta una API estable de alto nivel o donde todavía no compensa reimplementar: configuración inicial, gCTS, AUnit/ATC, CTS básico, data preview OSQL, utilidades puntuales.
- No lanzar `sapcli` si la conexión no está validada por `adt_http.ready()`, para evitar ráfagas de login y bloqueos de usuario.
- Para productivo, preferir respuestas ADT estructuradas a parsear stdout humano de `sapcli`.

## Qué conviene migrar a ADT

Prioridad alta:

- `source.open/read`: migrado a ADT directo para programas, includes, clases, interfaces, grupos de función, DDIC y RAP/CDS. Mantener fallback `sapcli` solo para casos raros.
- `source.push/write`: migrado a ADT directo con lock stateful, `PUT source/main`, unlock y transporte.
- Creación genérica de objetos (`new.lua`): CDS ya está migrado porque `sapcli` hardcodeaba `EN`. Programas/clases/interfaces/DDIC pueden tener el mismo problema de idioma en sistemas ES; conviene migrarlos por ADT directo progresivamente.
- Borrado (`source.delete`, `transaction.delete`, mensajes): operación destructiva. Si se mantiene, debe ir con confirmación fuerte y filtro propietario; mejor ADT directo o desactivar por defecto en modo productivo.
- Search global que usa `sapcli abap find`: migrar a `/sap/bc/adt/repository/informationsystem/search`, que ya se usa en partes del plugin y es más estructurado.

Prioridad media:

- Where-used/diff/read definitions: migrar a ADT cuando existan endpoints claros y mantener `sapcli` como fallback.
- Package browser/list/stat: ADT directo para estructura de paquete si el sistema expone discovery compatible; `sapcli package list` puede quedar como fallback.
- Message class: migrar lectura/edición a ADT o mantener con restricciones si `sapcli` es la única ruta estable.

Mantener por ahora en `sapcli`:

- `sapcli config ...`: sigue siendo la fuente de configuración actual (`~/.sapcli/config.yml`), aunque la contraseña debe tratarse como riesgo.
- `sapcli cts release/reassign/contents`: útil hasta validar endpoints ADT y payloads en más releases SAP.
  `:SapTransports`, `:SapTransportCreate` y `:SapTransportDelete` ya delegan en `core.cts`
  por ADT directo, con usuario real de la sesión y confirmación fuerte para delete.
- `sapcli aunit run` y `sapcli atc run`: útiles como runners de alto nivel. Migrar solo si ADT da una ventaja real en navegación de resultados.
- `sapcli datapreview osql`: útil para tablas/queries. Para CDS preview ya hay ADT.
- `sapcli gcts`: mantener, es integración específica.

## Riesgos productivos detectados

- Contraseñas: `:SapSetup` ya no escribe password en `~/.sapcli/config.yml`; usa keyring/DPAPI tras validar. Si existe un config antiguo con `password:`, conviene limpiarlo. El plugin lo ignora salvo `security.allow_plaintext_password=true`.
- Operaciones destructivas: `delete` y release/reassign/delete de transportes ya requieren confirmación fuerte por nombre/ID exacto. Siguiente mejora: quitar atajos destructivos o dejarlos detrás de `safe_mode`.
- `sapcli` puede ocultar detalles reales en excepciones genéricas. Ejemplo resuelto: CDS fallaba con `ExceptionResourceCreationFailure`, pero el body real decía que el idioma `EN` no coincidía con `ES`.
- Parsear stdout humano es frágil para quickfix/productivo. ADT XML/JSON estructurado es preferible.
- Locks: en ADT directo hay que asegurar unlock en error y sesión stateful. Si se hace bien, es más auditable que delegar todo a `sapcli`.

## Validaciones necesarias antes de productivo

- `:SapDoctor` comprueba:
  - perfil activo (`dev`, `qa`, `prod`) y contexto visible `SID/mandante/usuario`;
  - conexión validada sin exponer password;
  - permisos `0600` de `~/.sapcli/config.yml`;
  - ausencia de `password:` legacy en `~/.sapcli/config.yml`;
  - `password:` legacy deshabilitado por defecto;
  - `safe_mode`, confirmaciones destructivas y borrados remotos bloqueados por defecto;
  - TLS verificado; con `productive.require_tls=true` se marca como requisito de productivo;
  - create/write/release/delete/set-variable bloqueados por defecto en `prod`;
  - auditoría local de acciones sensibles activa;
  - permisos/errores típicos `401`/`403`/`S_ADT`/`S_CTS`.
- `:SapLiveCheck` ejecuta pruebas vivas no destructivas:
  - endpoints ADT necesarios por discovery;
  - búsqueda ADT por Information System;
  - daemon ADT keep-alive;
  - activación inactiveobjects;
  - lecturas `sapcli` vía wrapper validado.
- Creación/lectura/check de objeto temporal en `$TMP` debe hacerse solo si el usuario acepta una
  prueba de escritura explícita.
- Modo productivo:
  - bloquear `delete` por defecto o exigir escribir el nombre exacto; ahora exige nombre exacto;
  - release/reassign/delete transport con owner filter y confirmación explícita; ahora exige ID exacto;
  - no escribir objetos que no sean del usuario sin aviso;
  - no ejecutar runners si `adt_http.ready()` es false.
- Pruebas reales mínimas:
  - crear programa `$TMP`, escribir, check, activar, ejecutar;
  - crear CDS `$TMP`, escribir, check, activar;
  - abrir include, activar raíz + includes;
  - debugger: break, run report, step into/over, refresh variables y preview tabla;
  - transportes: listar solo propios y no liberar sin confirmación.

## Próximo bloque de trabajo

1. Auditar cada llamada `sapcli` restante y clasificarla como:
   `mantener`, `migrar a ADT`, `fallback`, `bloquear en productivo`.
2. Validar escritura ADT también con un programa `$TMP` de pruebas antes de tocar reports reales.
3. Promover tests headless permanentes para debugger/cockpit y gate anti-401.
4. Completar migraciones ADT donde el output textual de `sapcli` sea frágil.

## Pruebas realizadas

- `ZCDS_PRUEBA2`:
  - abierto por ADT;
  - guardado con lock/PUT/unlock por ADT escribiendo el mismo contenido;
  - activado por ADT;
  - `inactive_after=false`.
- `ZEJEMPLO`:
  - abierto por ADT como programa;
  - URI: `/sap/bc/adt/programs/programs/zejemplo`;
  - lectura correcta, sin tocar el contenido.

## Correcciones 2026-06-27

- CDS completion:
  - el completion source vuelve a habilitar filetype `ddl`;
  - `intel.proposals_async()` enruta a CDS usando `cds.is_cds_buf()`, aunque el buffer tenga `filetype=abap`;
  - `core.cds.completion()` ya no mezcla keywords cuando el contexto es de campos (`alias.`, `alias-`, anotaciones);
  - `ddicrepositoryaccess` parsea atributos `*:name`, no solo `adtcore:name`.
- Debugger:
  - IDs de variables escapados en XML para field-symbols y nombres con caracteres especiales;
  - `META_TYPE` normalizado, y `TABLE_LINES > 0` fuerza tratamiento como tabla;
  - expansión de tablas con fallback: primero `getVariables(ID[1..N])`, luego `getChildVariables(table_id)`;
  - watches/expressions anuncian `supportsCompletionsRequest` e implementan `completions`;
  - preview de tablas usa el mismo helper de expansión que DAP.
- Breakpoints:
  - `:SapDapClearBreakpoints` / `<leader>db` limpia breakpoints del buffer actual;
  - `:SapDapClearBreakpointsRecursive` / `<leader>dB` limpia raíz + includes relacionados;
  - si hay sesión ADT activa, intenta limpiar también los breakpoints remotos SAP por ID/fuente.
- Activación recursiva:
  - `<leader>aA` desde un include detecta el programa raíz y los includes relacionados antes de activar;
  - los objetos no locales ya no ofrecen `$TMP` ni reutilizan una selección local previa;
  - si SAP responde que el objeto ya está bloqueado en otra orden, se extrae esa orden del mensaje y se reintenta una vez con ella.
- Productivo / transportes:
  - `:SapListAllTransports` y `<leader>atL` muestran todas las órdenes visibles por ADT/CTS;
  - el selector de guardado sigue priorizando órdenes asignables al objeto para evitar usar una orden incorrecta.

## Roles y visibilidad en productivo

- Eclipse ADT y VSCode no aplican un modelo propio de roles: llaman endpoints ADT y el backend SAP
  filtra por las autorizaciones reales del usuario (por ejemplo repositorio, paquete/objeto, CTS,
  debug y ejecución). sap-nvim debe hacer lo mismo: no ocultar artificialmente objetos salvo que el
  usuario elija un filtro, y no intentar saltarse rechazos de SAP.
- Búsqueda global:
  - `:SapSearchLive` usa `/sap/bc/adt/repository/informationsystem/search`;
  - la visibilidad la decide SAP; el plugin solo añade filtros explícitos de tipo cuando se piden.
- Transportes:
  - `:SapListAllTransports` usa ADT CTS search configuration con usuario vacío y muestra lo que SAP
    permite ver;
  - `:SapListTransports` usa el usuario SAP real de la sesión ADT, no el alias local del contexto;
  - `source.resolve_transport()` usa `transportchecks` para pedir órdenes asignables al objeto;
  - el transporte recordado queda limitado a contexto SAP + cliente + paquete, para no reutilizar
    una orden de otro paquete/sistema.
- Seguridad:
  - comandos CTS destructivos exigen conexión validada;
  - borrado de orden por ADT exige escribir el ID exacto cuando `productive.confirm_destructive=true`;
  - objetos con nombre estándar/no cliente se abren como buffers read-only en `productive.safe_mode`;
  - metadata DDIC sin editor de código se muestra como XML ADT read-only y `:SapPush`/`:SapDelete`
    quedan bloqueados aunque el usuario fuerce `modifiable`;
  - `:SapActivate`/`:SapPushActivate` exige confirmar el nombre del objeto cuando la activación usa
    transporte o no puede demostrar que el objeto es `$TMP`;
  - activaciones masivas por `adt.activate_bulk` también piden confirmación en `safe_mode`;
  - `adt_http.raw()` codifica query params para locks, `configUri`, `corrNr`, etc.;
  - activación ADT ya no marca éxito si el HTTP no es 2xx o si SAP devuelve una excepción.
- `:SapDoctor` usa búsqueda global acotada (`*`, max 5) en vez de asumir que productivo trabaja con
  objetos `Z*`.
- `:SapDoctor` clasifica señales típicas de autorización/login (`401`, `403`, `S_ADT`, `S_CTS`,
  `S_DEVELOP`) y recomienda validar con `SU53`/`STAUTHTRACE` cuando SAP las devuelve.

## Validación 2026-06-27: roles/visibilidad/productivo

- `:SapListAllTransports` probado en vivo: devolvió órdenes visibles de `SEIDOR1` y `SEIJC2`.
- Búsqueda ADT global probada en vivo:
  - paquetes `Z*`: resultados `DEVC/K`;
  - transacciones `Z*`: resultados `TRAN/T`;
  - programas estándar `SAPM*`: resultados `PROG/I`.
- `adt.fetch_transport_orders()` probado con entorno exportado desde sesión validada:
  - `SAP_USER=seijc2`;
  - no intenta prompt de contraseña en terminal.
- `<leader>aA` probado otra vez tras endurecer query params:
  - guardó `ZCAR_PRACFINAL_JCG_TOP` por ADT;
  - detectó bloqueo en `S4FK901556` y reintentó con esa orden;
  - activó raíz + relacionados;
  - sesión siguió validando `200`.
- Activación negativa con URI inexistente:
  - no notificó éxito;
  - generó quickfix con errores SAP.
- Confirmación destructiva ADT:
  - `:SapDeleteTransport` no ejecuta `DELETE` si no se escribe el ID exacto.

## Pendientes de validación SAP en vivo

- Abrir un objeto estándar visible, por ejemplo `CL_ABAP*` o `SAPM*`, y confirmar que queda
  `readonly`/`nomodifiable` con mensaje de solo lectura.
- Ejecutar `:SapPushActivate` sobre un objeto transportado de pruebas y confirmar que pide escribir
  el nombre exacto antes de activar.
- Ejecutar `:SapDoctor` con un usuario sin permisos CTS/ADT suficientes y comprobar que el reporte
  añade la sección `Permisos/autorizaciones detectados`.
