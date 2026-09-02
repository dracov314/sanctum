import re
import random
from dataclasses import dataclass
import discord
from discord import app_commands
from discord.ext import commands

# Matches: [N]d<sides>[kh/kl<keep>][!<vals>][~<vals>][fz][+/-<mod>...]
# Examples: d20, 2d6, 4d6kh3, 2d20adv, 3d6!, 1d10fz, 1d10!10~1, 1d8+3
# fz = Fuzion shorthand: explode on max face, implode on 1
_DICE_RE = re.compile(
    r"^(?P<count>\d+)?d(?P<sides>\d+)"
    r"(?:(?P<keep_dir>kh|kl)(?P<keep_n>\d+))?"
    r"(?:!(?P<explode_on>[\d,]*))?"
    r"(?:~(?P<implode_on>[\d,]*))?"
    r"(?P<fz>fz)?"
    r"(?P<mods>(?:[+-]\d+)+)?$",
    re.IGNORECASE,
)
_ADV_RE = re.compile(
    r"^(?P<count>\d+)?d(?P<sides>\d+)(?P<adv>adv|dis|advantage|disadvantage)$",
    re.IGNORECASE,
)


@dataclass
class RollResult:
    notation: str
    # Each inner list is one die's chain: [initial, explode1, explode2, ...]
    chains: list[list[int]]
    kept_indices: list[int]
    modifier: int
    total: int
    advantage: str | None = None

    @property
    def die_totals(self) -> list[int]:
        return [sum(c) for c in self.chains]

    @property
    def kept_totals(self) -> list[int]:
        return [sum(self.chains[i]) for i in self.kept_indices]


def _roll_chain(
    sides: int,
    explode_on: set[int],
    implode_on: set[int] = frozenset(),
    max_extra: int | None = None,  # None = unlimited; 1 = Fuzion rule (one reroll only)
) -> list[int]:
    chain = []
    roll = random.randint(1, sides)
    chain.append(roll)
    extras = 0
    if roll in explode_on:
        while max_extra is None or extras < max_extra:
            roll = random.randint(1, sides)
            chain.append(roll)
            extras += 1
            if roll not in explode_on:
                break
    elif roll in implode_on:
        while max_extra is None or extras < max_extra:
            roll = random.randint(1, sides)
            chain.append(-roll)
            extras += 1
            if roll not in implode_on:
                break
    return chain


def _fmt_chain(chain: list[int]) -> str:
    parts = [str(chain[0])]
    for r in chain[1:]:
        parts.append(f"~ {abs(r)}" if r < 0 else f"| {r}")
    return " ".join(parts)


def parse_and_roll(notation: str) -> RollResult:
    notation = notation.strip().replace(" ", "")

    adv_match = _ADV_RE.match(notation)
    if adv_match:
        sides = int(adv_match.group("sides"))
        adv_type = adv_match.group("adv").lower()
        rolls = [random.randint(1, sides), random.randint(1, sides)]
        is_adv = adv_type in ("adv", "advantage")
        kept_idx = [rolls.index(max(rolls))] if is_adv else [rolls.index(min(rolls))]
        chains = [[r] for r in rolls]
        total = sum(chains[i][0] for i in kept_idx)
        return RollResult(
            notation=notation,
            chains=chains,
            kept_indices=kept_idx,
            modifier=0,
            total=total,
            advantage="adv" if is_adv else "dis",
        )

    m = _DICE_RE.match(notation)
    if not m:
        raise ValueError(f"Couldn't parse dice notation: `{notation}`")

    count = int(m.group("count") or 1)
    sides = int(m.group("sides"))
    keep_dir = (m.group("keep_dir") or "").lower()
    keep_n = int(m.group("keep_n")) if m.group("keep_n") else None
    mods_str = m.group("mods") or ""
    modifier = sum(int(x) for x in re.findall(r"[+-]\d+", mods_str))

    # Build explode set — ! alone means max face, !vals means those specific values
    explode_on: set[int] = set()
    raw = m.group("explode_on")
    if raw is not None:
        explode_on = {int(v) for v in raw.split(",") if v.strip()} if raw.strip() else {sides}

    # Build implode set — ~ alone means 1, ~vals means those specific values
    implode_on: set[int] = set()
    raw_imp = m.group("implode_on")
    if raw_imp is not None:
        implode_on = {int(v) for v in raw_imp.split(",") if v.strip()} if raw_imp.strip() else {1}

    # fz shorthand: explode on max, implode on 1 (only fills what isn't already set)
    if m.group("fz"):
        if not explode_on:
            explode_on = {sides}
        if not implode_on:
            implode_on = {1}

    if count < 1 or count > 100:
        raise ValueError("Dice count must be between 1 and 100")
    if sides < 2 or sides > 10000:
        raise ValueError("Sides must be between 2 and 10000")

    # fz uses Fuzion rules: one extra roll max; bare ! / ~ chain freely for other systems
    max_extra = 1 if m.group("fz") else None
    chains = [_roll_chain(sides, explode_on, implode_on, max_extra=max_extra) for _ in range(count)]
    die_totals = [sum(c) for c in chains]

    if keep_dir == "kh" and keep_n:
        kept_indices = sorted(range(count), key=lambda i: die_totals[i], reverse=True)[:keep_n]
    elif keep_dir == "kl" and keep_n:
        kept_indices = sorted(range(count), key=lambda i: die_totals[i])[:keep_n]
    else:
        kept_indices = list(range(count))

    total = sum(die_totals[i] for i in kept_indices) + modifier
    return RollResult(
        notation=notation,
        chains=chains,
        kept_indices=kept_indices,
        modifier=modifier,
        total=total,
    )


def _build_roll_embed(result: RollResult, label: str | None, target: int | None = None) -> discord.Embed:
    kept_set = set(result.kept_indices)
    die_totals = result.die_totals
    kept_totals = result.kept_totals

    success = (result.total >= target) if target is not None else None
    color = (
        0x22C55E if success is True
        else 0xEF4444 if success is False
        else 0xFFD700 if all(t == max(die_totals) for t in kept_totals)
        else 0xFF4444 if all(t == min(die_totals) for t in kept_totals)
        else 0x9333EA
    )

    title = f"🎲 {result.notation.upper()}"
    if label:
        title += f" — {label}"

    embed = discord.Embed(title=title, color=color)

    rolls_parts = []
    for i, chain in enumerate(result.chains):
        text = _fmt_chain(chain)
        if len(chain) > 1:
            text += f" = {sum(chain)}"
        if i in kept_set:
            text = f"**{text}**"
        else:
            text = f"~~{text}~~"
        rolls_parts.append(text)

    embed.add_field(name="Rolls", value=", ".join(rolls_parts) or "—", inline=False)

    if result.modifier != 0:
        sign = "+" if result.modifier > 0 else ""
        embed.add_field(name="Modifier", value=f"{sign}{result.modifier}", inline=True)

    if result.advantage:
        embed.add_field(
            name="Mode",
            value="Advantage" if result.advantage == "adv" else "Disadvantage",
            inline=True,
        )

    embed.add_field(name="Total", value=f"**{result.total}**", inline=True)

    if target is not None:
        embed.add_field(name="Target", value=str(target), inline=True)
        embed.add_field(name="Result", value="✅ **SUCCESS**" if success else "❌ **FAILURE**", inline=True)

    if any(len(c) > 1 and c[1] > 0 for c in result.chains):
        embed.set_footer(text="⚡ Exploding — rolled max, rerolled and added")
    elif any(len(c) > 1 and c[1] < 0 for c in result.chains):
        embed.set_footer(text="💀 Fumble — rolled 1, rerolled and subtracted")

    return embed


class DiceCog(commands.Cog, name="Dice"):
    def __init__(self, bot: commands.Bot):
        self.bot = bot

    @app_commands.command(name="roll", description="Roll dice using standard notation.")
    @app_commands.describe(
        dice="Notation: 2d6  1d20+5  4d6kh3  2d20adv  3d6!  1d10fz  1d10!10~1  1d8+3",
        label="Optional label (e.g. 'Stealth check' or 'Handgun attack')",
        target="Target number — shows success/fail if provided",
        secret="Only show the result to you",
    )
    async def roll(
        self,
        interaction: discord.Interaction,
        dice: str,
        label: str | None = None,
        target: int | None = None,
        secret: bool = False,
    ):
        # Allow target:N inline in the dice string (e.g. 1d10!+6+3target:15)
        inline = re.search(r'target:(\d+)', dice, re.IGNORECASE)
        if inline:
            if target is None:
                target = int(inline.group(1))
            dice = dice[:inline.start()] + dice[inline.end():]
        try:
            result = parse_and_roll(dice)
        except ValueError as e:
            await interaction.response.send_message(f"❌ {e}", ephemeral=True)
            return
        embed = _build_roll_embed(result, label, target)
        await interaction.response.send_message(embed=embed, ephemeral=secret)

    @app_commands.command(name="multiroll", description="Roll multiple dice expressions at once.")
    @app_commands.describe(dice="Space-separated expressions, e.g. '4d6kh3 4d6kh3 4d6kh3'")
    async def multiroll(self, interaction: discord.Interaction, dice: str):
        expressions = dice.strip().split()
        if len(expressions) > 10:
            await interaction.response.send_message("Maximum 10 expressions at once.", ephemeral=True)
            return
        embeds = []
        for expr in expressions:
            try:
                result = parse_and_roll(expr)
                embeds.append(_build_roll_embed(result, None))
            except ValueError as e:
                await interaction.response.send_message(f"❌ {e}", ephemeral=True)
                return
        await interaction.response.send_message(embeds=embeds[:10])

async def setup(bot: commands.Bot):
    await bot.add_cog(DiceCog(bot))
