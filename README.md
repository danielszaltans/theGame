# theGame

A co-op zombie swarm roguelike for up to 6 players. One player hosts, the rest join.

## Play

Download the launcher once and start the game with it every time. It updates the game by itself.

- **Windows:** [theGame.exe](https://github.com/danielszaltans/theGame/releases/latest/download/theGame.exe).
  Windows shows "Windows protected your PC" the first time: click *More info*, then *Run anyway*.
- **Linux:** [theGame-linux](https://github.com/danielszaltans/theGame/releases/latest/download/theGame-linux),
  then `chmod +x theGame-linux && ./theGame-linux`.

Move with WASD or the arrow keys.

## Playing together

One player clicks **Host a game**. Everyone else types the host's address and clicks **Join a game**.
Everyone must be on the same version; the launcher takes care of that.

The host has to be reachable on **UDP port 24565**:

- Same Wi-Fi/LAN: use the host's local address (like `192.168.1.20`).
- Over the internet, the easy way: everyone installs [Tailscale](https://tailscale.com) and joins
  the same network, then uses the host's Tailscale address (like `100.x.y.z`).
- Over the internet, the other way: the host forwards UDP port 24565 on their router and shares
  their public IP.

## Development

Tools are pinned in `mise.toml` (`mise install`).

- `game/` is the Godot 4 project: `godot --path game`.
- `launcher/` is the Go launcher.

Start a second copy that joins a local host without clicking:
`godot --path game -- --host` and `godot --path game -- --join=127.0.0.1 --name=Two`.

## Releasing an update

```sh
git tag v0.2.0
git push origin v0.2.0
```

GitHub Actions builds the game for Windows and Linux and publishes the release.
Launchers pick it up the next time they start.
