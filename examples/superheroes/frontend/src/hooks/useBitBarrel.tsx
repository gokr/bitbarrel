import { createSignal, onCleanup } from 'solid-js';
import { BitBarrelClient } from '@bitbarrel/client';

export function useBitBarrel() {
  const [client, setClient] = createSignal<BitBarrelClient | null>(null);
  const [connected, setConnected] = createSignal(false);

  const connect = async (host: string = 'localhost', port: number = 9876) => {
    const bc = new BitBarrelClient({ host, port });
    await bc.connect();
    await bc.useBarrel('superheroes');
    setClient(bc);
    setConnected(true);
  };

  const disconnect = async () => {
    const c = client();
    if (c) {
      await c.close();
      setClient(null);
      setConnected(false);
    }
  };

  onCleanup(disconnect);

  return { client, connected, connect, disconnect };
}

let globalClient: BitBarrelClient | null = null;

export function bitbarrelClient() {
  return globalClient;
}

export function setBitbarrelClient(client: BitBarrelClient) {
  globalClient = client;
}
