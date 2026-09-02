import io
import logging
import time
import discord
import httpx
from discord import app_commands
from discord.ext import commands, tasks
from .. import api_client
from ..api_client import SanctumAPIError

log = logging.getLogger(__name__)

# Short TTL so a mid-session transformation-form switch shows the new form's
# portrait on rolls within ~a minute.
_PORTRAIT_TTL = 90


def _fmt_dice(dice: list[dict]) -> str:
    parts = []
    for d in dice:
        v = d.get("v")
        kind = d.get("kind", "base")
        if kind == "add":
            parts.append(f"| {v}")
        elif kind == "sub":
            parts.append(f"~ {v}")
        else:
            parts.append(str(v))
    return " ".join(parts) if parts else "—"


def _build_relay_embed(payload: dict, author_name: str, portrait_ref: str | None = None) -> discord.Embed:
    mode = payload.get("mode", "skill")
    who = payload.get("who") or author_name
    label = payload.get("label") or ""
    attr_used = payload.get("attr_used")
    total = payload.get("total")
    crit = payload.get("crit", False)
    fumble = payload.get("fumble", False)

    vs_defender = payload.get("vs_defender")
    margin = payload.get("margin")
    missed = vs_defender is not None and margin is not None and margin <= 0

    color = 0xEF4444 if missed else 0x22C55E if crit else 0xEF4444 if fumble else 0x9333EA
    verb = "dealt damage —" if mode == "damage" else "rolled"
    title = f"🎲 {who} {verb} {label}".rstrip()
    if attr_used:
        title += f" ({attr_used})"

    embed = discord.Embed(title=title, color=color)
    if portrait_ref:
        embed.set_thumbnail(url=portrait_ref)
    dice = payload.get("dice") or []
    if dice:
        embed.add_field(name="Dice", value=_fmt_dice(dice), inline=True)

    base, dice_sum = payload.get("base"), payload.get("dice_sum")
    if base is not None and dice_sum is not None:
        sign = "-" if dice_sum < 0 else "+"
        math_value = f"{base} {sign} {abs(dice_sum)}"
        bonus = payload.get("bonus") or 0
        if bonus:
            math_value += f"  *(incl. {'+' if bonus > 0 else ''}{bonus} bonus)*"
        embed.add_field(name="Math", value=math_value, inline=True)

    if total is not None:
        embed.add_field(name="Total", value=f"**{total}**", inline=True)

    if vs_defender is not None:
        mos = min(margin, 6) if margin is not None else None
        embed.add_field(
            name="vs Defender",
            value=(f"❌ MISS — {vs_defender} (Margin {margin})" if missed
                   else f"✅ HIT — {vs_defender} (Margin {margin}, MOS {mos})"),
            inline=False,
        )

    haki_dice = payload.get("haki_dice")
    if haki_dice:
        embed.add_field(
            name="Armament Haki",
            value=f"+{haki_dice}d6 ({payload.get('haki_endurance_spent')} Endurance spent)",
            inline=False,
        )

    if crit:
        embed.set_footer(text="⚡ Max roll — rerolled and added")
    elif fumble:
        embed.set_footer(text="💀 Fumble — rerolled and subtracted")

    return embed


class RollsCog(commands.Cog, name="Rolls"):
    def __init__(self, bot: commands.Bot):
        self.bot = bot
        self._last_seen: dict[str, str] = {}   # campaign_id -> last roll id relayed
        self._seeded: set[str] = set()          # campaign_ids with an established baseline
        # char_id -> (fetched_at, (bytes, ext) | None). None = "no portrait", cached
        # too so we don't refetch a 404 every roll.
        self._portraits: dict[str, tuple[float, tuple[bytes, str] | None]] = {}
        self.poll_rolls.start()

    def cog_unload(self):
        self.poll_rolls.cancel()

    async def _portrait(self, char_id: str) -> tuple[bytes, str] | None:
        now = time.monotonic()
        cached = self._portraits.get(char_id)
        if cached and now - cached[0] < _PORTRAIT_TTL:
            return cached[1]
        try:
            result = await api_client.get_character_portrait(char_id)
        except (SanctumAPIError, httpx.HTTPError) as e:
            log.warning("Failed to fetch portrait for character %s: %s", char_id, e)
            return cached[1] if cached else None
        self._portraits[char_id] = (now, result)
        return result

    # ── /set_roll_channel ────────────────────────────────────────────────────

    @app_commands.command(
        name="set_roll_channel",
        description="Post live dice-roll results from Sanctum into a channel.",
    )
    @app_commands.describe(
        channel="Where to post rolls — defaults to the channel you're in",
        game="Campaign name — only needed if Sanctum has more than one campaign",
    )
    @app_commands.checks.has_permissions(manage_guild=True)
    @app_commands.guild_only()
    async def set_roll_channel(
        self,
        interaction: discord.Interaction,
        channel: discord.TextChannel | None = None,
        game: str | None = None,
    ):
        guild_id = interaction.guild_id
        assert guild_id is not None
        target = channel or interaction.channel

        await interaction.response.defer(ephemeral=True)
        try:
            result = await api_client.set_roll_channel(str(guild_id), str(target.id), game)
        except SanctumAPIError as e:
            if e.status == 404:
                msg = (f"No campaign named **{game}** found in Sanctum." if game
                       else "No campaigns exist in Sanctum yet — create one first.")
                await interaction.followup.send(msg, ephemeral=True)
            elif e.status == 409:
                await interaction.followup.send(f"⚠️ {e.detail} (use the `game` option)", ephemeral=True)
            else:
                await interaction.followup.send(f"Sanctum API error: {e.detail}", ephemeral=True)
            return

        # A campaign that just got (re)pointed at a channel should start relaying
        # from here, not replay whatever's already in _last_seen from before.
        self._seeded.discard(result["campaign_id"])
        self._last_seen.pop(result["campaign_id"], None)

        await interaction.followup.send(
            f"🎲 Rolls from **{result['campaign_name']}** will now be posted in {target.mention}.",
            ephemeral=True,
        )
        log.info("Roll channel set for '%s' -> #%s (guild %d)", result["campaign_name"], target.name, guild_id)

    @set_roll_channel.error
    async def set_roll_channel_error(self, interaction: discord.Interaction, error: app_commands.AppCommandError):
        if isinstance(error, app_commands.MissingPermissions):
            await interaction.response.send_message(
                "You need the **Manage Server** permission to set the roll channel.", ephemeral=True
            )
        else:
            raise error

    # ── Relay loop ───────────────────────────────────────────────────────────

    @tasks.loop(seconds=1)
    async def poll_rolls(self):
        # A transient network blip (e.g. the API container restarting) used to
        # raise httpx.ConnectError here, which discord.ext.tasks treats as fatal
        # and silently kills the whole poll loop forever — no more roll relays
        # until the bot itself is restarted. httpx.HTTPError catches those
        # alongside SanctumAPIError so a hiccup just gets skipped and retried
        # next tick instead of ending the loop.
        try:
            channels = await api_client.list_roll_channels()
        except (SanctumAPIError, httpx.HTTPError) as e:
            log.warning("Failed to list roll channels: %s", e)
            return

        for entry in channels:
            campaign_id = entry["campaign_id"]
            since_id = self._last_seen.get(campaign_id)

            try:
                rolls = await api_client.get_recent_rolls(campaign_id, since_id)
            except (SanctumAPIError, httpx.HTTPError) as e:
                log.warning("Failed to fetch rolls for '%s': %s", entry["campaign_name"], e)
                continue

            if not rolls:
                continue

            # First sight of this campaign (bot start or a freshly-set channel)
            # — establish a baseline without posting so history doesn't flood
            # the channel; only rolls from here forward get relayed.
            if campaign_id not in self._seeded:
                self._seeded.add(campaign_id)
                self._last_seen[campaign_id] = rolls[-1]["id"]
                continue

            channel = self.bot.get_channel(int(entry["channel_id"]))
            if channel is None:
                try:
                    channel = await self.bot.fetch_channel(int(entry["channel_id"]))
                except discord.HTTPException:
                    log.warning(
                        "Roll channel %s for '%s' isn't reachable — check it still exists "
                        "and the bot has access.", entry["channel_id"], entry["campaign_name"],
                    )
                    self._last_seen[campaign_id] = rolls[-1]["id"]
                    continue

            for roll in rolls:
                if roll.get("source") == "discord":
                    continue  # don't echo a roll back into the guild it came from
                payload = roll.get("payload") or {}

                # Attach the rolling character's primary portrait as the embed
                # thumbnail. Re-served as an attachment (not a URL) so the image
                # endpoint stays behind bot-key auth.
                file: discord.File | None = None
                portrait_ref: str | None = None
                char_id = payload.get("char_id")
                if char_id:
                    thumb = await self._portrait(char_id)
                    if thumb:
                        data, ext = thumb
                        file = discord.File(io.BytesIO(data), filename=f"portrait.{ext}")
                        portrait_ref = f"attachment://portrait.{ext}"

                embed = _build_relay_embed(payload, roll.get("author_name") or "Someone", portrait_ref)

                try:
                    await channel.send(embed=embed, file=file)
                except discord.HTTPException as e:
                    log.warning("Failed to post roll to channel %s: %s", entry["channel_id"], e)

            self._last_seen[campaign_id] = rolls[-1]["id"]

    @poll_rolls.before_loop
    async def before_poll_rolls(self):
        await self.bot.wait_until_ready()

    @poll_rolls.error
    async def poll_rolls_error(self, error: BaseException):
        # Last-resort net: tasks.loop stops for good on any exception that
        # escapes the loop body, so anything unexpected here still gets
        # logged and the loop restarted rather than dying silently.
        log.error("poll_rolls crashed, restarting loop: %s", error, exc_info=error)
        if not self.poll_rolls.is_running():
            self.poll_rolls.restart()


async def setup(bot: commands.Bot):
    await bot.add_cog(RollsCog(bot))
