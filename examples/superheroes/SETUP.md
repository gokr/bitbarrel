# BitBarrel Superheroes - Setup Guide

## Prerequisites

- Node.js 18+ (for frontend and import script)
- BitBarrel built and available

## Step 1: Build BitBarrel

From the bitbarrel project root:

```bash
nimble build
```

This creates the `bitbarrel` binary in the project root.

## Step 2: Start BitBarrel Server

Open a terminal and run:

```bash
./bitbarrel -p=9876 serve
```

Keep this terminal open! The server needs to remain running.

You should see output like:
```
BitBarrel v1.0.0
Listening on ws://0.0.0.0:9876
HTTP server on http://0.0.0.0:9876
```

### Server Options

- `-p=9876` - Port number (default: 9876)
- `-h=localhost` - Host to bind to

## Step 3: Import Superheroes Data

Open a new terminal and navigate to the import directory:

```bash
cd examples/superheroes/backend/import
```

Install dependencies:

```bash
npm install
```

Run the import script:

```bash
npm run import
```

This will:
1. Connect to BitBarrel server
2. Create a `superheroes` barrel with bmCritBit mode
3. Import 20 sample superheroes
4. Import publishers and powers
5. Create indexes for efficient queries

Expected output:
```
Connecting to BitBarrel at localhost:9876...
Connected to BitBarrel
Dropping existing superheroes barrel...
Creating superheroes barrel with bmCritBit mode...
Created and selected superheroes barrel

Importing publishers...
  - Marvel Comics
  - DC Comics
  - Image Comics
  - Dark Horse

Importing superheroes...
  - Imported 10 heroes...
  - Imported 20 heroes...

Importing powers...

=== Import Complete ===
Heroes imported: 20
Publishers: 4
Powers: 20
Total keys in barrel: 87

Disconnected from BitBarrel
```

## Step 4: Start the Frontend

Open another new terminal and navigate to the frontend directory:

```bash
cd examples/superheroes/frontend
```

Install dependencies:

```bash
npm install
```

Start the development server:

```bash
npm run dev
```

Expected output:
```
  VITE v5.x.x  ready in xxx ms

  ➜  Local:   http://localhost:3000/
  ➜  press h + enter to show help
```

## Step 5: Open the Application

Open your web browser and navigate to:

**http://localhost:3000**

You should see:
- Connection status indicator (green when connected)
- Grid of 20 sample superheroes
- Search bar and publisher filter
- "Add New Hero" button

## Testing Features

### Browse and Search
- Scroll through the hero grid
- Use pagination to load more heroes
- Search for heroes by name
- Filter by publisher Marvel Comics or DC Comics

### View Details
- Click on any hero card to see full details
- View stats, powers, biography, and teams

### Create New Hero
1. Click "Add New Hero"
2. Fill in the form (name and publisher required)
3. Select powers from the list
4. Click "Create Hero"
5. The new hero appears in the grid

### Edit Hero
1. Click on a hero card twice OR
2. Click "Edit" in the detail view
3. Modify hero properties
4. Click "Update Hero"

### Delete Hero
1. Edit a hero
2. Click "Delete" button
3. Confirm the deletion

### Real-Time Updates
1. Open http://localhost:3000 in two browser windows
2. In one window, create a new hero
3. Watch it appear instantly in the other window
4. Edit or delete a hero and see updates propagate

## Troubleshooting

### "Failed to connect to BitBarrel server"

Check that:
- BitBarrel server is running (see Step 2)
- Server is on port 9876
- No firewall blocking the connection

### "No Heroes Found"

Make sure you ran the import script (Step 3).

### npm install errors

Try:
```bash
rm -rf node_modules package-lock.json
npm install
```

### Port already in use

Change the BitBarrel port:
```bash
./bitbarrel -p=9877 serve
```

Then set environment variable for import script:
```bash
export BITBARREL_PORT=9877
npm run import
```

## Development

### Frontend Development

```bash
cd examples/superheroes/frontend
npm run dev          # Start dev server
npm run build        # Build for production
npm run preview      # Preview production build
```

### Backend Import Script

```bash
cd examples/superheroes/backend/import
npm run import       # Import data
```

### Adding New Sample Data

Edit `examples/superheroes/backend/import/superheroes.json` and re-run the import script.

### Stopping Services

1. Press `Ctrl+C` in each terminal to stop services
2. BitBarrel creates a `superheroes.db` directory in the project root
3. To start fresh, delete this directory before running the import script again

## Production Deployment

To build for production:

```bash
cd examples/superheroes/frontend
npm run build
```

The built files will be in `examples/superheroes/frontend/dist/`.

You can serve these with any static file server:
```bash
cd dist
npx serve -p 3000
```

## Data Persistence

All hero data is stored in BitBarrel's `superheroes` barrel directory. The data persists across server restarts.

To reset all data:
1. Stop BitBarrel server
2. Delete `superheroes.db` directory
3. Restart BitBarrel
4. Re-run the import script
