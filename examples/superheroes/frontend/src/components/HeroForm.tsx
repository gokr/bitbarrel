import { Component, createSignal, For, Show } from 'solid-js';
import type { Hero } from '../types';
import { bitbarrelClient } from '../hooks/useBitBarrel';

interface HeroFormProps {
  hero?: Hero;
  publishers: string[];
  powers: string[];
  onSave: () => void;
  onCancel: () => void;
}

export const HeroForm: Component<HeroFormProps> = (props) => {
  const [values, setValues] = createSignal({
    name: props.hero?.name || '',
    realName: props.hero?.realName || '',
    publisher: props.hero?.publisher || '',
    alignment: props.hero?.alignment || 'Good',
    bio: props.hero?.bio || '',
    image: props.hero?.image || '',
    power: props.hero?.powers.map((p) => p.name).join(', ') || ''
  });

  const [selectedPowers, setSelectedPowers] = createSignal<string[]>(
    props.hero?.powers.map((p) => p.name) || []
  );
  const [tempPower, setTempPower] = createSignal('');

  const togglePower = (powerName: string) => {
    const current = selectedPowers();
    if (current.includes(powerName)) {
      setSelectedPowers(current.filter((p) => p !== powerName));
    } else {
      setSelectedPowers([...current, powerName]);
    }
  };

  const addCustomPower = () => {
    const power = tempPower().trim();
    if (power && !selectedPowers().includes(power)) {
      setSelectedPowers([...selectedPowers(), power]);
      setTempPower('');
    }
  };

  const handleSave = async () => {
    const client = bitbarrelClient();
    if (!client) {
      alert('Not connected to BitBarrel');
      return;
    }

    const powerObjects = selectedPowers().map((name, index) => ({
      id: index + 1,
      name
    }));

    if (props.hero) {
      const updated: Hero = {
        ...props.hero,
        ...values(),
        powers: powerObjects
      };
      await client.set(`hero:${props.hero.id}`, JSON.stringify(updated));
    } else {
      const id = Date.now();
      const newHero: Hero = {
        id,
        ...values(),
        publisherId: props.publishers.indexOf(values().publisher) + 1,
        firstAppearance: new Date().toISOString().split('T')[0],
        powers: powerObjects,
        teams: [],
        stats: { strength: 5, speed: 5, intelligence: 5, power: 5 },
        bio: values().bio,
        image: values().image
      };
      await client.set(`hero:${id}`, JSON.stringify(newHero));
      await client.set(`hero:name:${values().name.toLowerCase()}`, String(id));
    }
    props.onSave();
  };

  const handleDelete = async () => {
    if (!props.hero || !confirm('Delete this hero?')) return;
    const client = bitbarrelClient();
    if (!client) {
      alert('Not connected to BitBarrel');
      return;
    }

    await client.delete(`hero:${props.hero.id}`);
    await client.delete(`hero:name:${props.hero.name.toLowerCase()}`);
    props.onSave();
  };

  const updateValue = (field: string, value: string) => {
    setValues((prev) => ({ ...prev, [field]: value }));
  };

  return (
    <form class="hero-form" onSubmit={(e) => { e.preventDefault(); handleSave(); }}>
      <div class="form-row">
        <div class="form-group">
          <label for="hero-name">Hero Name *</label>
          <input
            id="hero-name"
            name="name"
            type="text"
            placeholder="e.g. Superman"
            value={values().name}
            required
            onInput={(e) => updateValue('name', e.currentTarget.value)}
          />
        </div>
        <div class="form-group">
          <label for="hero-realName">Real Name</label>
          <input
            id="hero-realName"
            name="realName"
            type="text"
            placeholder="e.g. Clark Kent"
            value={values().realName}
            onInput={(e) => updateValue('realName', e.currentTarget.value)}
          />
        </div>
      </div>

      <div class="form-row">
        <div class="form-group">
          <label for="hero-publisher">Publisher *</label>
          <select
            id="hero-publisher"
            name="publisher"
            value={values().publisher}
            required
            onChange={(e) => updateValue('publisher', e.currentTarget.value)}
          >
            <option value="">Select publisher</option>
            <For each={props.publishers}>{(pub) => (
              <option value={pub}>{pub}</option>
            )}</For>
          </select>
        </div>
        <div class="form-group">
          <label for="hero-alignment">Alignment</label>
          <select
            id="hero-alignment"
            name="alignment"
            value={values().alignment}
            onChange={(e) => updateValue('alignment', e.currentTarget.value)}
          >
            <option value="Good">Good</option>
            <option value="Bad">Bad</option>
            <option value="Neutral">Neutral</option>
          </select>
        </div>
      </div>

      <div class="form-group">
        <label for="hero-image">Image URL</label>
        <input
          id="hero-image"
          name="image"
          type="url"
          placeholder="https://..."
          value={values().image}
          onInput={(e) => updateValue('image', e.currentTarget.value)}
        />
      </div>

      <div class="form-group">
        <label>Bio</label>
        <textarea
          name="bio"
          rows={4}
          placeholder="Hero biography..."
          value={values().bio}
          onInput={(e) => updateValue('bio', e.currentTarget.value)}
        />
      </div>

      <div class="form-group">
        <label>Powers</label>
        <div class="powers-grid">
          <For each={props.powers}>{(power) => (
            <button
              type="button"
              class={`power-toggle ${selectedPowers().includes(power) ? 'active' : ''}`}
              onClick={() => togglePower(power)}
            >
              {power}
            </button>
          )}</For>
        </div>
        <div class="custom-power">
          <input
            type="text"
            placeholder="Add custom power..."
            value={tempPower()}
            onInput={(e) => setTempPower(e.currentTarget.value)}
            onKeyPress={(e) => {
              if (e.key === 'Enter') {
                e.preventDefault();
                addCustomPower();
              }
            }}
          />
          <button type="button" class="btn btn-small" onClick={addCustomPower}>
            Add
          </button>
        </div>
      </div>

      <div class="selected-powers">
        <h4>Selected Powers:</h4>
        <Show when={selectedPowers().length === 0}>
          <p class="no-powers">No powers selected</p>
        </Show>
        <div class="power-tags">
          <For each={selectedPowers()}>{(power) => (
            <span class="power-tag" onClick={() => togglePower(power)}>
              {power} <span class="remove">×</span>
            </span>
          )}</For>
        </div>
      </div>

      <div class="form-actions">
        <button type="button" class="btn" onClick={props.onCancel}>Cancel</button>
        <Show when={props.hero}>
          <button type="button" class="btn btn-danger" onClick={handleDelete}>Delete</button>
        </Show>
        <button type="submit" class="btn btn-primary">
          {props.hero ? 'Update Hero' : 'Create Hero'}
        </button>
      </div>
    </form>
  );
};
