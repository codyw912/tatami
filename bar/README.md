# tatami-bar

An optional bar that sits over the macOS menu bar. tatami does not need it, and it talks
to tatami only through the command line (`tatami events --json` and `tatami query ...
--json`), so it is a separate program in Swift rather than part of the Zig binary.

- Left: an optional logo, the workspaces (click one to switch, the focused one filled) and
  the focused window's title.
- Right: menu-bar apps of your choice, the battery and the clock.
- Hover anywhere but a workspace or an icon and the bar fades out to show the real menu
  bar; move away and it comes back. Hidden while the focused window is native fullscreen.
- Redraws on every tatami event, so a workspace switch shows at once.

## Install

```sh
./bar/install.sh      # needs swiftc: xcode-select --install
./bar/uninstall.sh
```

The bar works without any permission. Clicking a menu-bar app in it needs Accessibility
(System Settings › Privacy & Security › Accessibility), which keeps across rebuilds only
when the binary is signed, as for tatami (see [docs/INSTALL.md](../docs/INSTALL.md)).

## Configure

`~/.config/tatami/bar.conf`, one `<key> <value>` per line. Every key is optional, and
without the file the bar uses the system's colours and font, so it fits light and dark
mode. [example.conf](example.conf) lists every key with its default.

```
font rounded
logo ◕‿◕
background #f8f3ea
accent #2f47a0
tray tailscale
```

`tatami-bar check` reports lines it cannot read (they are skipped; the rest applies), and
`pkill -HUP tatami-bar` reloads the file.

Gaps between windows are tatami's own setting, in `tatami.conf`: `gap inner 10` and
`gap outer 10`.

## Tray

`tray <bundle-id>` shows that app's icon; a click presses the app's real menu-bar item,
so its own menu opens. If a menu-bar manager such as Bartender has moved that item off
screen, macOS opens the menu where the item is, not under the bar.

`tray tailscale` gets a menu of its own from the Tailscale CLI, always under the icon:
connect or disconnect, this device's address (click to copy), the exit node, and the
admin console. Its dot is green when connected, and the exit node in use is shown beside
it.

## Key bindings

`tatami-bar keys` shows every key binding tatami has loaded, in a panel in the middle of
the screen, and hides it when run again; Esc, q or a click elsewhere hides it too. Bind it in
`tatami.conf`:

```
bind ctrl-alt-shift-slash : exec ~/.local/bin/tatami-bar keys
```

The bindings come from tatami over its socket, so the sheet shows what is loaded. Each
group is titled with the comment above it in `tatami.conf`, up to the first " (". Known
commands read in words ("Swap window left"), and runs such as `workspace 1` to `workspace
9` on one set of modifiers share a row. A short list of command-line commands closes it.

`keys-style` sets how a chord's modifiers are written; the final key always has a chip of
its own: `symbols` (⌃⌥⇧, the default), `plus` (Ctrl+Alt+Shift+), `words` (ctrl alt
shift) or `mono` (a small chip for each). Outside `symbols`, Return, Tab and Esc are
spelled out and arrows stay arrows. `keys-colors on` gives each modifier a colour of its
own: `keys-ctrl-color`, `keys-alt-color`, `keys-shift-color` and `keys-cmd-color`.
