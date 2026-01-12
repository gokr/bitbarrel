export interface Hero {
  id: number;
  name: string;
  realName: string;
  publisher: string;
  publisherId: number;
  firstAppearance: string;
  powers: Power[];
  teams: string[];
  alignment: 'Good' | 'Bad' | 'Neutral';
  stats: HeroStats;
  bio: string;
  image: string;
}

export interface HeroStats {
  strength: number;
  speed: number;
  intelligence: number;
  power: number;
}

export interface Power {
  id: number;
  name: string;
  description?: string;
}

export interface Publisher {
  id: number;
  name: string;
}

export interface Team {
  id: number;
  name: string;
  description?: string;
}

export interface QueryOptions {
  prefix: string;
  limit?: number;
  cursor?: string;
}

export interface HeroEvent {
  type: 'hero_created' | 'hero_updated' | 'hero_deleted';
  hero?: Hero;
  id?: number;
  timestamp: number;
}
