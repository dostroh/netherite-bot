# Rosegold Bot Examples

A template repository with example Minecraft bots built using [Rosegold.cr](https://github.com/RosegoldMC/rosegold.cr).

## Examples

| Bot | File | Description |
|-----|------|-------------|
| **Attack** | `src/attack.cr` | Attacks at the direction it is looking, tracks weapon durability |
| **AFK** | `src/afk.cr` | Stays connected and eats when hungry |

## Quick Start

### Option 1: Download Pre-built Binary

1. **Download the latest build** from the [Actions tab](https://github.com/RosegoldMC/example/actions) — look for the latest "Build" workflow
2. **Extract the archive** and run a bot: `./bin/attack` or `./bin/afk`

### Option 2: Build from Source

1. **Use this template** by clicking the "Use this template" button on GitHub
2. **Clone your new repository**:
   ```bash
   git clone https://github.com/yourusername/your-bot-name.git
   cd your-bot-name
   ```
3. **Install dependencies**:
   ```bash
   shards install
   ```
4. **Build and run**:
   ```bash
   shards build           # Build all bots
   shards build attack    # Build a specific bot
   ./bin/attack
   ```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVER_HOST` | `play.civmc.net` | Minecraft server address to connect to |
| `SPECTATE_HOST` | `0.0.0.0` | Host for the spectate server to bind to |
| `SPECTATE_PORT` | `25566` | Port for the spectate server |

Example:
```bash
SERVER_HOST=localhost ./bin/afk
```

## Bot Details

### Attack (`src/attack.cr`)

Connects and repeatedly attacks in the direction it is looking. Tracks weapon durability and automatically eats food. Useful for AFK mob grinders.

### AFK (`src/afk.cr`)

The simplest possible bot — stays connected and eats when hungry. Use as a starting point for new bots.

## Spectate Server

Every bot starts a spectate server (default port 25566). Connect to it with a Minecraft client to see what the bot sees in real time. Change the port with `SPECTATE_PORT`.

## Auto-Reconnect

All bots include automatic reconnection with exponential backoff. If disconnected, the bot waits 5 seconds before reconnecting, doubling the delay on each failure up to a maximum of 5 minutes. The delay resets on successful connection.

## Creating Your Own Bot

1. Copy `src/afk.cr` as a starting point
2. Add a new target in `shard.yml`:
   ```yaml
   targets:
     my_bot:
       main: src/my_bot.cr
   ```
3. Add your bot logic inside the `while bot.connected?` loop
4. Build with `shards build my_bot`

Key APIs:
- `bot.chat "message"` — send a chat message
- `bot.eat!` — eat food when hungry
- `bot.move_to(x, z)` — walk to coordinates
- `bot.inventory.pick("item")` — select an item in hotbar
- `bot.inventory.count("item")` — count items in inventory
- `bot.attack` — attack in the current look direction
- `bot.start_digging` / `bot.stop_digging` — mine blocks
- `bot.craft("item", count)` — craft items
- `bot.open_container { ... }` — interact with chests
- `bot.on EventType { |e| ... }` — listen for events

See the [Rosegold.cr documentation](https://github.com/RosegoldMC/rosegold.cr) for the full API.

## Development

```bash
shards build              # Build all bots
crystal tool format       # Format code
```

## License

MIT License — see [LICENSE](LICENSE) for details.

## Disclaimer

This software is for educational purposes. Ensure you comply with your server's rules and Minecraft's Terms of Service when using bots.
