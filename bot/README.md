# Sanctum Discord bot

Optional companion bot. It relays dice rolls between a campaign's Session Room
and a Discord channel, and can log session activity.

The bot talks to Sanctum only over its HTTP API using a shared key — it never
touches the database directly.

## Setup

1. Create a Discord application + bot at
   <https://discord.com/developers/applications>, and copy its **bot token**.
   The bot needs the **Message Content** privileged intent.
2. In your Sanctum `.env`:

   ```sh
   DISCORD_BOT_TOKEN=your-bot-token
   BOT_API_KEY=$(openssl rand -hex 32)   # any shared secret; the api reads the same var
   ```

3. Start it alongside the stack:

   ```sh
   docker compose --profile bot up -d
   ```

4. Invite the bot to your server (OAuth2 → URL Generator → `bot` +
   `applications.commands` scopes, "Send Messages" permission).
5. In a campaign's settings in Sanctum, set the Discord guild + roll-relay
   channel IDs.

## Environment variables

| Var | Required | Notes |
|---|---|---|
| `DISCORD_BOT_TOKEN` | yes | Discord bot token |
| `BOT_API_KEY` | yes | Shared secret; must match the api service |
| `SANCTUM_API_URL` | no | Defaults to `http://api:8000/api` (in-compose) |
| `DISCORD_DEV_GUILD_ID` | no | Guild for instant slash-command sync while developing |
