#!/usr/bin/env tsx
import { BitBarrelClient } from '../../../../clients/typescript/dist/index.js';
import superheroes from './superheroes.json' with { type: 'json' };
import type { Hero, Publisher, Power } from '../../frontend/src/types';
import * as fs from 'fs';
import * as path from 'path';

const HOST = process.env.BITBARREL_HOST || 'localhost';
const PORT = parseInt(process.env.BITBARREL_PORT || '9876', 10);

async function importData(): Promise<void> {
  console.log(`Connecting to BitBarrel at ${HOST}:${PORT}...`);

  const client = new BitBarrelClient({ host: HOST, port: PORT });

  try {
    await client.connect();
    console.log('Connected to BitBarrel');

    const barrels = await client.listBarrels();

    if (barrels.includes('superheroes')) {
      console.log('Dropping existing superheroes barrel...');
      await client.dropBarrel('superheroes');
    }

    console.log('Creating superheroes barrel with critbit mode...');
    await client.createBarrel(
      'superheroes',
      JSON.stringify({
        mode: 'critbit',
        syncMode: 'sync'
      })
    );
    await client.useBarrel('superheroes');
    console.log('Created and selected superheroes barrel');

    const publishers = new Map<string, number>();

    console.log('\nImporting publishers...');
    for (const pub of superheroes.publishers) {
      publishers.set(pub.name.toLowerCase(), pub.id);
      await client.set(`publisher:${pub.id}`, JSON.stringify(pub));
      await client.set(`publisher:name:${pub.name.toLowerCase()}`, String(pub.id));
      console.log(`  - ${pub.name}`);
    }

    console.log('\nImporting superheroes...');
    let heroCount = 0;
    for (const hero of superheroes.items) {
      const heroData = hero as unknown as Hero;
      await client.set(`hero:${hero.id}`, JSON.stringify(heroData));
      await client.set(`hero:name:${hero.name.toLowerCase()}`, String(hero.id));

      const pubId = publishers.get(hero.publisher.toLowerCase());
      if (pubId) {
        const existing = await client.getOrDefault(`publisher:heroes:${pubId}`, '');
        const heroIds = existing ? existing.split(',').filter(Boolean) : [];
        if (!heroIds.includes(String(hero.id))) {
          heroIds.push(String(hero.id));
        }
        await client.set(`publisher:heroes:${pubId}`, heroIds.join(','));
      }

      if (heroData.powers && heroData.powers.length > 0) {
        await client.set(
          `hero:powers:${hero.id}`,
          heroData.powers.map((p) => p.id).join(',')
        );
      }

      heroCount++;
      if (heroCount % 10 === 0) {
        console.log(`  - Imported ${heroCount} heroes...`);
      }
    }

    console.log(`\nImporting powers...`);
    for (const power of superheroes.powers) {
      await client.set(`power:${power.id}`, JSON.stringify(power));
      await client.set(`power:name:${power.name.toLowerCase()}`, String(power.id));
    }

    const stats = await client.getBarrelStats('superheroes');
    console.log(`\n=== Import Complete ===`);
    console.log(`Heroes imported: ${heroCount}`);
    console.log(`Publishers: ${publishers.size}`);
    console.log(`Powers: ${superheroes.powers.length}`);
    console.log(`Total keys in barrel: ${stats.totalKeys}`);
  } catch (error) {
    console.error('Import failed:', error);
    throw error;
  } finally {
    await client.close();
    console.log('\nDisconnected from BitBarrel');
  }
}

importData().catch((error) => {
  console.error(error);
  process.exit(1);
});
