# tatami-bar

An optional bar that sits over the macOS menu bar. tatami does not need it, and it talks
to tatami only through the command line (`tatami events --json` and `tatami query ...
--json`), so it is a separate program in Swift rather than part of the Zig binary.

- Left: an optional logo, the workspaces (click one to switch, the focused one filled) and
  the focused window's title.
- Right: menu-bar apps of your choice, tray plugins (Tailscale, sound output), the battery
  and the clock.
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

`tray sound` shows a speaker; a click lists the sound output devices, as Sound settings
does, with a tick on the one in use, under a small volume slider. Pick one to play
through it. It follows changes made elsewhere, such as plugging in headphones. An output
whose volume macOS cannot set (an audio interface with a hardware knob) shows no slider.

`tray openusage:<provider>` shows one limit from
[OpenUsage](https://github.com/robinebers/openusage): the provider's mark and what is
left, such as `95%`. `<provider>` is a kind (`claude`, `codex`, `cursor`, ...), which takes
its first account, or one account's id (`codex@1a2b3c4d`). The limit is `weekly` unless
named after a dot, as in `openusage:codex.session`; the `resources` of each account in
the JSON that `openusage` prints are the names to use. `openusage-show used` shows what is
used instead. The numbers come from the command line tool inside the app, which prints
what the app last fetched and never fetches itself. A muted dot means they are stale or
missing: OpenUsage is not running, its refreshes fail, or the account has no such limit.
A click opens OpenUsage's panel.

### Plugins

`tailscale`, `sound` and `openusage` are plugins: a class in `tatami-bar.swift` that
conforms to `TrayPlugin` (a name, an icon, an optional status dot and text, and a menu)
and is listed in `Tray.init`, or made from the entry by `Tray.plugin` when the entry
names what to show. A template image such as an SF Symbol is drawn in the `foreground`
colour.
