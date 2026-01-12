import { Component, createEffect, createSignal, Show, onMount } from 'solid-js';
import { render } from 'solid-js/web';
import { useBitBarrel, bitbarrelClient, setBitbarrelClient } from './hooks/useBitBarrel';
import { useHeroes } from './hooks/useHeroes';
import { usePubSub } from './hooks/usePubSub';
import { HeroCard } from './components/HeroCard';
import { Pagination } from './components/Pagination';
import { HeroForm } from './components/HeroForm';
import { HeroDetail } from './components/HeroDetail';
import { SearchBar } from './components/SearchBar';
import type { Hero, HeroEvent } from './types';
import './styles/index.css';

const ALL_PUBLISHERS = ['Marvel Comics', 'DC Comics', 'Image Comics', 'Dark Horse'];
const ALL_POWERS = [
  'Super Strength', 'Flight', 'Speed', 'Intelligence', 'Durability', 'Energy Projector',
  'Mental Powers', 'Magic', 'Technology', 'Weapons', 'Stealth', 'Agility', 'Regeneration',
  'Teleportation', 'Telepathy', 'Telekinesis', 'Elemental', 'Shape-shifting', 'Immortality',
  'Strength', 'Invulnerability'
];

export const App: Component = () => {
  const { client, connected, connect } = useBitBarrel();
  const [selectedHero, setSelectedHero] = createSignal<Hero | null>(null);
  const [showForm, setShowForm] = createSignal(false);
  const [heroList, setHeroList] = createSignal<Hero[]>([]);
  const [editHero, setEditHero] = createSignal<Hero | undefined>();
  const [statusMessage, setStatusMessage] = createSignal('');
  const [hasLoaded, setHasLoaded] = createSignal(false);

  const { heroes, loading, cursor, hasMore, loadHeroes, loadMore } = useHeroes(client);

  const { subscribe, publishUpdate } = usePubSub(
    client,
    (event: HeroEvent) => {
      setStatusMessage(`Update: ${event.type.replace('_', ' ')}`);
      setTimeout(() => setStatusMessage(''), 3000);

      switch (event.type) {
        case 'hero_created':
          if (event.hero) {
            setHeroList((prev) => [...prev, event.hero!]);
          }
          break;
        case 'hero_updated':
          if (event.hero) {
            setHeroList((prev) =>
              prev.map((h) => (h.id === event.hero?.id ? event.hero! : h))
            );
            if (selectedHero()?.id === event.hero?.id) {
              setSelectedHero(event.hero);
            }
          }
          break;
        case 'hero_deleted':
          setHeroList((prev) => prev.filter((h) => h.id !== event.id));
          if (selectedHero()?.id === event.id) {
            setSelectedHero(null);
          }
          break;
      }
    }
  );

  const handleSearch = (query: string) => {
    const c = client();
    if (!c) return;

    if (!query || query.trim() === '') {
      loadHeroes({ prefix: 'hero:', limit: 20 });
      return;
    }

    const searchTerm = query.toLowerCase();
    const filtered = heroList().filter(
      (h) =>
        h.name.toLowerCase().includes(searchTerm) ||
        h.realName?.toLowerCase().includes(searchTerm)
    );

    setHeroList(filtered);
  };

  const handleFilterPublisher = async (publisher: string | null) => {
    if (!publisher) {
      loadHeroes({ prefix: 'hero:', limit: 20 });
      return;
    }

    const c = client();
    if (!c) return;

    const publisherId = ALL_PUBLISHERS.indexOf(publisher) + 1;
    const heroIds = await c.getOrDefault(`publisher:heroes:${publisherId}`, '');
    const ids = heroIds.split(',').filter(Boolean);

    if (ids.length === 0) {
      setHeroList([]);
      return;
    }

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
    setHeroList(heroesData);
  };

  const openForm = (hero?: Hero) => {
    setEditHero(hero);
    setShowForm(true);
    setSelectedHero(null);
  };

  const closeForm = () => {
    setShowForm(false);
    setEditHero(undefined);
  };

  const closeDetail = () => {
    setSelectedHero(null);
  };

  const selectHero = (hero: Hero) => {
    setSelectedHero(hero);
    setShowForm(false);
  };

  onMount(async () => {
    try {
      await connect();
      setHasLoaded(true);
    } catch (error) {
      console.error('Failed to connect:', error);
      setStatusMessage('Failed to connect to BitBarrel server');
    }
  });

  createEffect(async () => {
    if (connected() && !bitbarrelClient()) {
      const c = client();
      if (c) {
        setBitbarrelClient(c);
        subscribe();

        try {
          await loadHeroes({ prefix: 'hero:', limit: 20 });
        } catch (error) {
          console.error('Failed to load heroes:', error);
          setStatusMessage('Failed to load heroes');
        }
      }
    }
  });

  createEffect(() => {
    if (hasLoaded() && !loading()) {
      setHeroList(heroes());
    }
  });

  return (
    <div class="app">
      <header class="header">
        <h1>BitBarrel Superheroes</h1>
        <div class="header-actions">
          <div
            class={`connection-status ${
              connected() ? 'connected' : 'disconnected'
            }`}
          >
            <span
              class={`status-dot ${connected() ? 'connected' : 'disconnected'}`}
            ></span>
            {connected() ? 'Connected' : 'Disconnected'}
          </div>
        </div>
      </header>

      <main class="main">
        <Show when={statusMessage()}>
          <div class="status-message">{statusMessage()}</div>
        </Show>

        <Show when={!selectedHero() && !showForm()}>
          <SearchBar
            allPublishers={ALL_PUBLISHERS}
            onSearch={handleSearch}
            onFilterPublisher={handleFilterPublisher}
          />

          <div class="actions">
            <button class="btn btn-primary" type="button" onClick={() => openForm()}>
              Add New Hero
            </button>
            <span class="hero-count">{heroList().length} heroes</span>
          </div>

          <Show when={loading() && heroList().length === 0}>
            <div class="loading-container">
              <div class="spinner"></div>
              <p>Connecting to BitBarrel...</p>
            </div>
          </Show>

          <Show when={!loading() || heroList().length > 0}>
            <Show when={heroList().length > 0}>
              <div class="hero-grid">
                {heroList().map((hero) => (
                  <HeroCard hero={hero} onClick={() => selectHero(hero)} />
                ))}
              </div>

              {cursor() || hasMore() ? (
                <Pagination
                  cursor={cursor()}
                  hasMore={hasMore()}
                  loading={loading()}
                  onNext={loadMore}
                  onPrevious={() =>
                    loadHeroes({ prefix: 'hero:', limit: 20 })
                  }
                />
              ) : null}
            </Show>

            <Show when={!loading() && heroList().length === 0}>
              <div class="empty-state">
                <h2>No Heroes Found</h2>
                <p>
                  Import some superheroes using the backend import script, or add a
                  new hero.
                </p>
              </div>
            </Show>
          </Show>
        </Show>

        <Show when={showForm()}>
          <div class="form-container">
            <h2>{editHero() ? 'Edit Hero' : 'Create New Hero'}</h2>
            <HeroForm
              hero={editHero()}
              publishers={ALL_PUBLISHERS}
              powers={ALL_POWERS}
              onSave={() => {
                closeForm();
                loadHeroes({ prefix: 'hero:', limit: 20 });
                setStatusMessage(editHero() ? 'Hero updated!' : 'Hero created!');
              }}
              onCancel={closeForm}
            />
          </div>
        </Show>

        <Show when={selectedHero()} onMount={() => setShowForm(false)}>
          <HeroDetail
            hero={selectedHero()!}
            onEdit={() => openForm(selectedHero()!)}
            onBack={closeDetail}
          />
        </Show>
      </main>

      <style>{`
        .status-message {
          padding: var(--space-md) var(--space-lg);
          background: var(--color-bg-input);
          border-radius: var(--radius-md);
          margin-bottom: var(--space-lg);
          color: var(--color-accent);
          text-align: center;
        }

        .form-container {
          max-width: 800px;
          margin: 0 auto;
        }

        .form-container h2 {
          text-align: center;
          margin-bottom: var(--space-lg);
        }

        .hero-count {
          color: var(--color-text-muted);
          font-size: 0.875rem;
        }
      `}</style>
    </div>
  );
};

render(() => <App />, document.getElementById('app')!);
