# BitBarrel Superheroes Example

A full-featured example application demonstrating BitBarrel's capabilities with a Superheroes dataset.

## Features

- **Browse & Display**: Grid view of heroes with search and filtering
- **Full CRUD**: Create, read, update, and delete heroes
- **Range Queries**: Cursor-based pagination using bmCritBit mode
- **Real-time Updates**: Pub/Sub for live data synchronization
- **Publisher Filtering**: Filter heroes by comic publisher
- **Hero Details**: Expanded view with stats, powers, and biography

## Tech Stack

- **Backend**: BitBarrel server + TypeScript import script
- **Frontend**: SolidJS + TypeScript + Vite
- **Styling**: Custom CSS with CSS variables (no external library)

## Data Schema

The app uses BitBarrel's bmCritBit mode for ordered keys, enabling range queries:

```
hero:{id}                   -> Hero record (JSON)
hero:name:{name}            -> Name to ID mapping (lowercase)
publisher:{id}              -> Publisher record (JSON)
publisher:name:{name}       -> Publisher name to ID
publisher:heroes:{id}       -> Comma-separated hero IDs by publisher
power:{id}                  -> Power ability record (JSON)
power:name:{name}           -> Power name to ID
hero:powers:{id}            -> Comma-separated power IDs per hero
```

## Quick Start

See [SETUP.md](SETUP.md) for detailed setup instructions.

## API Features Demonstrated

### BitBarrel Client Methods Used

| Category | Method | Description |
|----------|--------|-------------|
| Barrel Management | `createBarrel()` | Create new barrel with config |
| Barrel Management | `useBarrel()` | Select active barrel |
| Barrel Management | `dropBarrel()` | Delete a barrel |
| Barrel Management | `getBarrelStats()` | Get barrel statistics |
| CRUD | `set()` | Store key-value pair |
| CRUD | `get()` | Retrieve value by key |
| CRUD | `getOrDefault()` | Get with default value |
| CRUD | `delete()` | Remove key from barrel |
| Range Queries | `prefixQuery()` | Get keys with prefix (with pagination) |
| Pub/Sub | `subscribe()` | Subscribe to topic patterns |
| Pub/Sub | `unsubscribe()` | Unsubscribe from topic |
| Pub/Sub | `publish()` | Publish message to topic |
| Pub/Sub | `on()` | Event listener for PubSub events |
| Pub/Sub | `setMessageHandler()` | Set message callback |

### Custom Hooks

- **`useBitBarrel`**: Manages WebSocket connection to BitBarrel server
- **`useHeroes`**: Handles hero data loading with cursor-based pagination
- **`usePubSub`**: Subscribe to real-time updates and handle hero change events

### Components

- **HeroCard**: Display hero in grid with stats preview
- **HeroDetail**: Expanded view with full stats, powers, and bio
- **HeroForm**: Create and edit hero form with power selection
- **Pagination**: Cursor-based navigation for large datasets
- **SearchBar**: Search by name and filter by publisher

## Project Structure

```
examples/superheroes/
├── backend/
│   ├── import/
│   │   ├── package.json          # Import script dependencies
│   │   ├── superheroes.json      # Sample data (20 heroes)
│   │   └── import.ts             # Import script
│   └── server/
│       └── README.md             # Server setup guide
├── frontend/
│   ├── package.json              # Frontend dependencies
│   ├── tsconfig.json             # TypeScript config
│   ├── vite.config.ts            # Vite dev server config
│   ├── index.html                # HTML entry point
│   └── src/
│       ├── main.tsx              # App entry
│       ├── App.tsx               # Root component
│       ├── components/           # UI components
│       ├── hooks/                # Custom SolidJS hooks
│       ├── types/                # TypeScript interfaces
│       ├── utils/                # Helper functions
│       └── styles/               # CSS styles
├── README.md                     # This file
└── SETUP.md                      # Setup guide
```

## Running the Demo

1. **Start BitBarrel server** (from project root):
   ```bash
   nimble build
   ./bitbarrel -p=9876 serve
   ```

2. **Import superheroes data**:
   ```bash
   cd examples/superheroes/backend/import
   npm install
   npm run import
   ```

3. **Start the frontend**:
   ```bash
   cd examples/superheroes/frontend
   npm install
   npm run dev
   ```

4. Open http://localhost:3000 in your browser.

## Testing Real-Time Updates

Open the application in two browser windows to see real-time synchronization:

1. Create a new hero in one window
2. Watch it appear in the other window instantly
3. Edit a hero and see updates propagate
4. Delete a hero and see it removed everywhere

This demonstrates BitBarrel's Pub/Sub capabilities.
