import { createSignal } from 'solid-js';
import type { BitBarrelClient } from '@bitbarrel/client';
import type { Hero, QueryOptions } from '../types';

export function useHeroes(client: () => BitBarrelClient | null) {
  const [heroes, setHeroes] = createSignal<Hero[]>([]);
  const [loading, setLoading] = createSignal(false);
  const [cursor, setCursor] = createSignal('');
  const [hasMore, setHasMore] = createSignal(true);
  const [total, setTotal] = createSignal(0);

  const loadHeroes = async (opts: QueryOptions) => {
    const c = client();
    if (!c) return;

    setLoading(true);
    try {
      const result = await c.prefixQuery(
        opts.prefix,
        { limit: opts.limit || 20, cursor: opts.cursor || '' }
      );
      const heroesData = result.items
        .filter(([key]) => key.startsWith('hero:'))
        .map(([, value]) => JSON.parse(value) as Hero);

      setHeroes(heroesData);
      setCursor(result.nextCursor);
      setHasMore(result.hasMore);
      setTotal(result.items.length);
    } finally {
      setLoading(false);
    }
  };

  const loadMore = async () => {
    if (!hasMore() || loading()) return;
    await loadHeroes({ prefix: 'hero:', limit: 20, cursor: cursor() });
  };

  const loadByPublisher = async (publisherId: number) => {
    const c = client();
    if (!c) return;

    setLoading(true);
    try {
      const heroIds = await c.getOrDefault(`publisher:heroes:${publisherId}`, '');
      const ids = heroIds.split(',').filter(Boolean);

      const heroPromises = ids.map(async (id) => {
        try {
          const value = await c.get(`hero:${id}`);
          return JSON.parse(value) as Hero;
        } catch {
          return null;
        }
      });

      const results = await Promise.all(heroPromises);
      const heroesData = results.filter((h): h is Hero => h !== null);

      setHeroes(heroesData);
      setHasMore(false);
      setCursor('');
    } finally {
      setLoading(false);
    }
  };

  const searchHeroes = async (name: string) => {
    const c = client();
    if (!c) return;

    setLoading(true);
    try {
      const heroId = await c.getOrDefault(`hero:name:${name.toLowerCase()}`, '');
      if (heroId) {
        const value = await c.get(`hero:${heroId}`);
        setHeroes([JSON.parse(value)]);
      } else {
        setHeroes([]);
      }
      setHasMore(false);
      setCursor('');
    } finally {
      setLoading(false);
    }
  };

  return {
    heroes,
    loading,
    cursor,
    hasMore,
    total,
    loadHeroes,
    loadMore,
    loadByPublisher,
    searchHeroes
  };
}
