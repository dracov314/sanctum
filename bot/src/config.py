import os
from dotenv import load_dotenv

load_dotenv()

DISCORD_BOT_TOKEN: str = os.environ["DISCORD_BOT_TOKEN"]
BOT_API_KEY: str = os.environ["BOT_API_KEY"]
SANCTUM_API_URL: str = os.environ.get("SANCTUM_API_URL", "http://api:8000/api")

# Optional: a guild to sync slash commands to immediately (guild-scoped syncs
# are instant, global syncs can take up to an hour to show up everywhere).
# Set this while iterating on new commands; global sync still runs regardless
# so every other server gets them once Discord's cache catches up.
DISCORD_DEV_GUILD_ID: str | None = os.environ.get("DISCORD_DEV_GUILD_ID") or None
