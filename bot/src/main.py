import asyncio
import logging
import discord
from discord.ext import commands
from .config import DISCORD_BOT_TOKEN, DISCORD_DEV_GUILD_ID

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("lorekeeper")

_COGS = [
    "src.cogs.dice",
    "src.cogs.session",
    "src.cogs.rolls",
]


class Lorekeeper(commands.Bot):
    def __init__(self):
        intents = discord.Intents.default()
        intents.message_content = True
        super().__init__(command_prefix="!", intents=intents)

    async def setup_hook(self):
        for cog in _COGS:
            await self.load_extension(cog)
            log.info("Loaded cog: %s", cog)

        if DISCORD_DEV_GUILD_ID:
            # Guild-scoped commands sync instantly; global ones can take up to
            # an hour. Running both at once made every command appear twice
            # in the dev guild (its own cached global copy + the new guild
            # copy). Single-server deployment, so drop global registration
            # entirely while a dev guild is set — guild-only, no duplicates.
            guild = discord.Object(id=int(DISCORD_DEV_GUILD_ID))
            self.tree.copy_global_to(guild=guild)
            await self.tree.sync(guild=guild)
            log.info("Slash commands synced instantly to dev guild %s", DISCORD_DEV_GUILD_ID)
            self.tree.clear_commands(guild=None)
            await self.tree.sync()
            log.info("Cleared global command registration (guild-only while DISCORD_DEV_GUILD_ID is set)")
        else:
            await self.tree.sync()
            log.info("Slash commands synced globally (can take up to an hour to appear)")

    async def on_ready(self):
        log.info("Lorekeeper online as %s (%d)", self.user, self.user.id)
        await self.change_presence(
            activity=discord.Activity(
                type=discord.ActivityType.watching,
                name="your campaigns",
            )
        )


def main():
    bot = Lorekeeper()
    bot.run(DISCORD_BOT_TOKEN, log_handler=None)


if __name__ == "__main__":
    main()
