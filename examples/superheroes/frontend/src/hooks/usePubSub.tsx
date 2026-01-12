import { createSignal, onCleanup } from 'solid-js';
import type { BitBarrelClient } from '../../../clients/typescript';
import type { PubSubEvent } from '../../../clients/typescript';
import type { HeroEvent, Hero } from '../types';

export function usePubSub(
  client: () => BitBarrelClient | null,
  onHeroChange: (event: HeroEvent) => void
) {
  const [subId, setSubId] = createSignal<string | null>(null);
  const [messages, setMessages] = createSignal<PubSubEvent[]>([]);

  const subscribe = async () => {
    const c = client();
    if (!c) return;

    const id = await c.subscribe('superheroes:*');
    setSubId(id);

    const handleEvent = (event: PubSubEvent) => {
      setMessages((prev) => [event, ...prev]);

      try {
        const data = JSON.parse(event.payload);
        const heroEvent = data as HeroEvent;
        onHeroChange(heroEvent);
      } catch (e) {
        console.error('Failed to parse pubsub event:', e);
      }
    };

    c.on('pubsub', handleEvent);
    c.setMessageHandler(handleEvent);
  };

  const unsubscribe = async () => {
    const id = subId();
    const c = client();
    if (id && c) {
      try {
        await c.unsubscribe(id);
      } catch (e) {
        console.error('Failed to unsubscribe:', e);
      }
      setSubId(null);
    }
  };

  const publishUpdate = async (event: HeroEvent) => {
    const c = client();
    if (!c) return;
    await c.publish('superheroes:updates', 0, JSON.stringify(event));
  };

  onCleanup(() => {
    unsubscribe();
  });

  return {
    subscribe,
    unsubscribe,
    publishUpdate,
    messages
  };
}
