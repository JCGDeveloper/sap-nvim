# Issues conocidos / pendientes de mirar

## Resuelto

- **osql / messageclass se colgaban vía nvim (RESUELTO):** `datapreview osql` y
  `messageclass read` SE CUELGAN para siempre cuando se lanzan con `vim.fn.jobstart`
  (CODE=143 al matarlos), aunque por CLI van al instante. Otros comandos (`table/class/program
  read`) sí van con jobstart. **Fix:** usar `vim.fn.system()` (síncrono) para esos dos. Bloquea
  brevemente pero es fiable. Aplicado en `core/data.lua` y `core/textsymbol.lua`.

## Pendiente

- **Crear/editar text symbols (elementos de texto) vía ADT:** la ESCRITURA no sale (HTTP
  423 Locked / 000). Requiere una sesión ADT **stateful** (lock+PUT en la MISMA sesión), y con
  curl-por-llamada no se mantiene; sapcli no expone text symbols. Necesita un helper con
  sesión persistente (p.ej. un pequeño script Python usando las libs de sapcli, o mantener
  una conexión viva). VER text symbols sí funciona (`:SapTextElements`). Crear desde MESSAGE
  avisa que no está soportado; usar la clase de mensajes (SE91) mientras tanto.

- **preview_select (`<leader>avs`) — "'.' is invalid here":** el usuario reportó el error
  pese a la limpieza (que en tests deja el SQL sin punto desde cualquier posición). Repro
  pendiente con su SELECT EXACTO / verificar reinicio. Prioridad baja (alternativa:
  `<leader>avq` con WHERE literal).
