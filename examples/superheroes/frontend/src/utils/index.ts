export function formatStats(stats: HeroStats): Record<string, number> {
  return {
    strength: stats.strength,
    speed: stats.speed,
    intelligence: stats.intelligence,
    power: stats.power
  };
}
