import logging
from datetime import datetime, timezone
import discord
from discord import app_commands
from discord.ext import commands
from .. import api_client
from ..api_client import SanctumAPIError

log = logging.getLogger(__name__)

# guild_id -> active session state
_sessions: dict[int, dict] = {}


def _session_embed(campaign_name: str, session_num: int, started_at: str) -> discord.Embed:
    embed = discord.Embed(
        title=f"Session {session_num} — {campaign_name}",
        description="Session is now active. Use `/note` to log moments as they happen.",
        color=0x7C3AED,
    )
    embed.add_field(name="Started", value=started_at[:10], inline=True)
    embed.set_footer(text="Lorekeeper — powered by Sanctum")
    return embed


def _summary_embed(campaign_name: str, session_num: int, summary: str | None, duration: str) -> discord.Embed:
    embed = discord.Embed(
        title=f"Session {session_num} Complete — {campaign_name}",
        color=0x7C3AED,
    )
    embed.add_field(name="Duration", value=duration, inline=True)
    if summary:
        embed.add_field(name="Session Summary", value=summary[:1020], inline=False)
    embed.set_footer(text="Lorekeeper — powered by Sanctum")
    return embed


def _duration(started_iso: str) -> str:
    start = datetime.fromisoformat(started_iso)
    delta = datetime.now(timezone.utc) - start
    h, rem = divmod(int(delta.total_seconds()), 3600)
    m = rem // 60
    return f"{h}h {m}m" if h else f"{m}m"


class SessionCog(commands.Cog, name="Session"):
    def __init__(self, bot: commands.Bot):
        self.bot = bot

    # ── /start_session ────────────────────────────────────────────────────────

    @app_commands.command(name="start_session", description="Begin a new game session for a campaign.")
    @app_commands.describe(game="The campaign name (must exist in Sanctum)")
    @app_commands.guild_only()
    async def start_session(self, interaction: discord.Interaction, game: str):
        guild_id = interaction.guild_id
        assert guild_id is not None

        if guild_id in _sessions:
            active = _sessions[guild_id]
            await interaction.response.send_message(
                f"A session is already running for **{active['campaign_name']}**. "
                "Use `/end_session` first.",
                ephemeral=True,
            )
            return

        await interaction.response.defer()

        try:
            result = await api_client.start_session(game, str(guild_id))
        except SanctumAPIError as e:
            if e.status == 404:
                await interaction.followup.send(
                    f"No campaign named **{game}** found in Sanctum. "
                    "Create it on the website first.",
                    ephemeral=True,
                )
            else:
                await interaction.followup.send(f"Sanctum API error: {e.detail}", ephemeral=True)
            return

        _sessions[guild_id] = {
            "session_id": result["session_id"],
            "campaign_name": result["campaign_name"],
            "session_number": result["session_number"],
            "started_at": datetime.now(timezone.utc).isoformat(),
            "text_channel_id": interaction.channel_id,
        }

        embed = _session_embed(
            result["campaign_name"],
            result["session_number"],
            _sessions[guild_id]["started_at"],
        )
        await interaction.followup.send(embed=embed)
        log.info("Session %d started for '%s' in guild %d", result["session_number"], game, guild_id)

    # ── /note ─────────────────────────────────────────────────────────────────

    @app_commands.command(name="note", description="Log a note into the current session.")
    @app_commands.describe(
        text="What happened — character actions, plot beats, memorable moments",
        gm_only="Mark this note as GM-only (hidden from players on the website)",
    )
    @app_commands.guild_only()
    async def note(self, interaction: discord.Interaction, text: str, gm_only: bool = False):
        guild_id = interaction.guild_id
        assert guild_id is not None

        if guild_id not in _sessions:
            await interaction.response.send_message(
                "No active session. Use `/start_session` first.", ephemeral=True
            )
            return

        session = _sessions[guild_id]
        author = interaction.user.display_name
        content = f"**{author}:** {text}"

        try:
            await api_client.add_note(session["session_id"], content, gm_only)
        except SanctumAPIError as e:
            await interaction.response.send_message(f"Failed to save note: {e.detail}", ephemeral=True)
            return

        await interaction.response.send_message(
            f"{'🔒 ' if gm_only else ''}Note logged for Session {session['session_number']}.",
            ephemeral=True,
        )

    # ── /end_session ──────────────────────────────────────────────────────────

    @app_commands.command(name="end_session", description="End the current session and post the summary.")
    @app_commands.describe(summary="Optional summary of what happened this session")
    @app_commands.guild_only()
    async def end_session(self, interaction: discord.Interaction, summary: str | None = None):
        guild_id = interaction.guild_id
        assert guild_id is not None

        if guild_id not in _sessions:
            await interaction.response.send_message("No session is currently running.", ephemeral=True)
            return

        await interaction.response.defer()

        session = _sessions.pop(guild_id)
        duration = _duration(session["started_at"])

        try:
            await api_client.end_session(session["session_id"], summary)
        except SanctumAPIError as e:
            await interaction.followup.send(f"Warning: failed to save session to Sanctum: {e.detail}")

        embed = _summary_embed(
            session["campaign_name"],
            session["session_number"],
            summary,
            duration,
        )
        await interaction.followup.send(embed=embed)
        log.info("Session %d ended for '%s'", session["session_number"], session["campaign_name"])

    # ── /complete_campaign ────────────────────────────────────────────────────

    @app_commands.command(name="complete_campaign", description="Mark a campaign as complete.")
    @app_commands.describe(game="The campaign name")
    @app_commands.guild_only()
    async def complete_campaign(self, interaction: discord.Interaction, game: str):
        # End active session first if one is running for this campaign
        guild_id = interaction.guild_id
        assert guild_id is not None

        active = _sessions.get(guild_id)
        if active and active["campaign_name"].lower() == game.lower():
            await interaction.response.send_message(
                f"Session {active['session_number']} is still active — end it with `/end_session` first.",
                ephemeral=True,
            )
            return

        await interaction.response.send_message(
            f"Campaign **{game}** marked as complete.\n"
            "Visit Sanctum to generate a full campaign retrospective.",
            ephemeral=False,
        )

    # ── /campaign_status ──────────────────────────────────────────────────────

    @app_commands.command(name="campaign_status", description="Check the status of a campaign.")
    @app_commands.describe(game="Campaign name")
    @app_commands.guild_only()
    async def campaign_status(self, interaction: discord.Interaction, game: str):
        await interaction.response.defer(ephemeral=True)

        try:
            campaign = await api_client.find_campaign(game)
        except SanctumAPIError as e:
            if e.status == 404:
                await interaction.followup.send(f"No campaign named **{game}** found.", ephemeral=True)
            else:
                await interaction.followup.send(f"API error: {e.detail}", ephemeral=True)
            return

        guild_id = interaction.guild_id
        active = _sessions.get(guild_id)
        is_active = active and active["campaign_name"].lower() == game.lower()

        embed = discord.Embed(title=f"Campaign — {campaign['name']}", color=0x7C3AED)
        if campaign.get("description"):
            embed.description = campaign["description"]
        if campaign.get("game_system_id"):
            embed.add_field(name="System", value=campaign["game_system_id"], inline=True)
        embed.add_field(
            name="Session",
            value=f"Active (Session {active['session_number']})" if is_active else "No active session",
            inline=True,
        )
        embed.add_field(
            name="Lore",
            value=f"View full chronicle on Sanctum",
            inline=False,
        )
        embed.set_footer(text="Lorekeeper — powered by Sanctum")
        await interaction.followup.send(embed=embed, ephemeral=True)

    # ── /lorekeeper ───────────────────────────────────────────────────────────

    @app_commands.command(name="lorekeeper", description="About Lorekeeper and upcoming features.")
    async def about(self, interaction: discord.Interaction):
        embed = discord.Embed(
            title="Lorekeeper",
            description="Your campaign's memory — powered by Sanctum.",
            color=0x7C3AED,
        )
        embed.add_field(
            name="Active Features",
            value=(
                "🎲 `/roll` — dice roller (2d6, 1d10!10+6+3, 4d6kh3, d20adv…)\n"
                "🎯 `/roll target:15` — add a target number for success/fail\n"
                "📖 `/start_session` — begin a session\n"
                "📝 `/note` — log moments mid-session\n"
                "✅ `/end_session` — wrap up and post summary\n"
                "📊 `/campaign_status` — view campaign info\n"
                "🎯 `/set_roll_channel` — relay Sanctum session-room rolls here"
            ),
            inline=False,
        )
        embed.add_field(
            name="Coming Soon",
            value=(
                "🎙️ Voice channel transcription\n"
                "🤖 AI-powered session summaries\n"
                "🔍 Automatic OOC filtering"
            ),
            inline=False,
        )
        embed.set_footer(text="Lorekeeper — powered by Sanctum")
        await interaction.response.send_message(embed=embed)


async def setup(bot: commands.Bot):
    await bot.add_cog(SessionCog(bot))
