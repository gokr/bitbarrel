import { Component } from 'solid-js';
import type { Hero } from '../types';

interface HeroCardProps {
  hero: Hero;
  onClick: () => void;
}

export const HeroCard: Component<HeroCardProps> = (props) => {
  return (
    <div class="hero-card" onClick={props.onClick} role="button" tabindex={0}>
      <div class="hero-image">
        {props.hero.image ? (
          <img
            src={props.hero.image}
            alt={props.hero.name}
            loading="lazy"
            onerror={(e) => {
              const target = e.currentTarget;
              target.style.display = 'none';
            }}
          />
        ) : (
          <div class="placeholder-image">
            <span>{props.hero.name.charAt(0)}</span>
          </div>
        )}
      </div>
      <div class="hero-info">
        <h3 class="hero-name">{props.hero.name}</h3>
        <p class="hero-publisher">{props.hero.publisher}</p>
        <div class="hero-alignment">
          <span class={`alignment-badge ${props.hero.alignment.toLowerCase()}`}>
            {props.hero.alignment}
          </span>
        </div>
        <div class="hero-stats">
          <span class="stat stat-power">PWR: {props.hero.stats.power}</span>
          <span class="stat stat-strength">STR: {props.hero.stats.strength}</span>
          <span class="stat stat-intelligence">INT: {props.hero.stats.intelligence}</span>
          <span class="stat stat-speed">SPD: {props.hero.stats.speed}</span>
        </div>
        <div class="hero-powers">
          {props.hero.powers.slice(0, 3).map((power) => (
            <span class="power-tag" key={power.id}>
              {power.name}
            </span>
          ))}
          {props.hero.powers.length > 3 && (
            <span class="power-more">+{props.hero.powers.length - 3}</span>
          )}
        </div>
      </div>
    </div>
  );
};
