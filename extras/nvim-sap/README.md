# Neovim SAP — IDE completo y aislado (`nvim-sap`)

Un Neovim **independiente** de tu configuración personal, montado como un IDE SAP
completo: dashboard propio, colores propios, completado/debugger ADT, statusline con
info del objeto, pickers, git, y sesión que solo recuerda objetos SAP. No comparte
plugins, historial ni sesión con tu `nvim` normal.

## Instalación

```sh
# 1. Copia esta carpeta a la config del appname nvim-sap
mkdir -p ~/.config/nvim-sap
cp -r extras/nvim-sap/{init.lua,lua} ~/.config/nvim-sap/

# 2. Alias en tu shell (~/.zshrc / ~/.bashrc)
echo "alias nvim-sap='NVIM_APPNAME=nvim-sap nvim'" >> ~/.zshrc && source ~/.zshrc

# 3. Primer arranque: instala plugins (lazy). Espera y reinicia.
nvim-sap
```

> El plugin se carga con `dir = ~/sap-nvim` (tu copia de trabajo): lo que edites o
> añadas en `~/sap-nvim` se aplica en `nvim-sap` al reiniciar. Ajusta la ruta en
> `lua/plugins/sap.lua` si tu copia está en otro sitio.

## Estructura

```
~/.config/nvim-sap/
├── init.lua                 bootstrap (leader, sap_mode, lazy)
└── lua/
    ├── config/
    │   ├── options.lua       opciones del editor
    │   └── keymaps.lua       atajos GENERALES + pickers + stepping de nvim-dap
    └── plugins/
        ├── ui.lua            tema, lualine, which-key, snacks
        ├── coding.lua        blink (ADT), treesitter (master), telescope, mini, gitsigns
        ├── debug.lua         nvim-dap + dap-ui + virtual-text (signos de breakpoint)
        └── sap.lua           EL PLUGIN sap-nvim (dir=~/sap-nvim, sap_mode=true)
```

## Qué incluye

- **Toda la funcionalidad del plugin sap-nvim** y sus atajos: `<leader>a*` (IDE),
  `<leader>c*` (CDS preview/SQL/OData/grafo + CTS órdenes), `<leader>d*` (ALV/debug),
  `gd`/`K`/`gr`, completado ADT + `@` anotaciones.
- **Dashboard SAP** al arrancar (`:SapHome`), `␣␣` para saltar entre buffers, `-`
  vuelve al dashboard, y restauración de sesión SOLO de objetos SAP.
- **Editor completo**: tema, statusline con el objeto SAP y estado del debug,
  which-key (menú de `<leader>`), pickers (`<leader>f*`), git en el margen, pares/
  comentarios/surround.
- **Debugger** con stepping estándar: `<leader>d` + `b/B/c/i/o/O/r/t/u/e` y
  `F5/F10/F11/F12`. Iniciar la sesión ABAP: `<leader>ad`. Breakpoints visibles en la
  barra izquierda (signo `●` rojo).

## Activarlo en tu propia config (sin appname aparte)

```lua
require("sap-nvim").setup({ sap_mode = true })
```

> Sin `sap_mode`, el plugin no toca keymaps globales ni autocomandos: solo añade el
> comando `:SapHome`. Así no interfiere con tu configuración personal.
