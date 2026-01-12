import { Component, For, Show } from 'solid-js';
import type { Hero } from '../types';

interface HeroDetailProps {
  hero: Hero;
  onEdit: () => void;
  onBack: () => void;
}

export const HeroDetail: Component<HeroDetailProps> = (props) => {
  return (
    <div class="hero-detail">
      <div class="detail-header">
        <button class="btn" onClick={props.onBack}>← Back</button>
        <button class="btn btn-primary" onClick={props.onEdit}>Edit</button>
      </div>

      <div class="detail-content">
        <div class="detail-image-section">
          {props.hero.image ? (
            <img
              src={props.hero.image}
              alt={props.hero.name}
              class="detail-image"
              onerror={(e) => {
                const target = e.currentTarget;
                target.style.display = 'none';
              }}
            />
          ) : (
            <div class="detail-placeholder">
              <span>{props.hero.name.charAt(0)}</span>
            </div>
          )}
        </div>

        <div class="detail-info">
          <div class="detail-title">
            <h1>{props.hero.name}</h1>
            <span class={`alignment-large ${props.hero.alignment.toLowerCase()}`}>
              {props.hero.alignment}
            </span>
          </div>

          <div class="detail-meta">
            <span class="meta-item">
              <strong>Real Name:</strong> {props.hero.realName || 'N/A'}
            </span>
            <span class="meta-item">
              <strong>Publisher:</strong> {props.hero.publisher}
            </span>
            <span class="meta-item">
              <strong>First Appearance:</strong> {props.hero.firstAppearance}
            </span>
          </div>

          <div class="section">
            <h2>Bio</h2>
            <p>{props.hero.bio || 'No biography available.'}</p>
          </div>

          <div class="section">
            <h2>Stats</h2>
            <div class="stats-grid">
              <div class="stat-box">
                <span class="stat-label">Strength</span>
                <span class="stat-value stat-strength">{props.hero.stats.strength}/10</span>
              </div>
              <div class="stat-box">
                <span class="stat-label">Power</span>
                <span class="stat-value stat-power">{props.hero.stats.power}/10</span>
              </div>
              <div class="stat-box">
                <span class="stat-label">Intelligence</span>
                <span class="stat-value stat-intelligence">
                  {props.hero.stats.intelligence}/10
                </span>
              </div>
              <div class="stat-box">
                <span class="stat-label">Speed</span>
                <span class="stat-value stat-speed">{props.hero.stats.speed}/10</span>
              </div>
            </div>
          </div>

          <Show when={props.hero.powers.length > 0}>
            <div class="section">
              <h2>Powers</h2>
              <div class="power-tags">
                <For each={props.hero.powers}>{(power) => (
                  <span class="power-tag">{power.name}</span>
                )}</For>
              </div>
            </div>
          </Show>

          <Show when={props.hero.teams.length > 0}>
            <div class="section">
              <h2>Teams</h2>
              <div class="team-list">
                <For each={props.hero.teams}>{(team) => (
                  <span class="team-tag">{team}</span>
                )}</For>
              </div>
            </div>
          </Show>
        </div>
      </div>
    </div>
  );
};
