# BitBarrel Real-Time Activity Dashboard

A complete, production-ready example demonstrating all BitBarrel features in a full-stack web application.

## Features Demonstrated

- ✅ **Core CRUD**: Create, read, update, delete operations
- ✅ **TTL**: Automatic expiration of old data (1 hour)
- ✅ **Range Queries**: Time-based analytics and statistics
- ✅ **Pub/Sub**: Real-time WebSocket updates
- ✅ **Reference Traversal**: User hierarchies and relationships
- ✅ **Socket.IO**: Real-time communication
- ✅ **Modern UI**: Clean interface with smooth animations

## Architecture

```
┌─────────────────────────────────────────────┐
│  Browser (React-style UI)                   │
│  - HTML/CSS/JavaScript                     │
│  - WebSocket real-time updates             │
└──────────────┬──────────────────────────────┘
               │ HTTP / WebSocket
┌──────────────▼──────────────────────────────┐
│  Express Server (TypeScript)                │
│  - REST API endpoints                      │
│  - Socket.IO integration                   │
│  - BitBarrel client                        │
└──────────────┬──────────────────────────────┘
               │
┌──────────────▼──────────────────────────────┐
│  BitBarrel Storage Engine                   │
│  - user-activities barrel (ordered)        │
│  - user-profiles barrel                    │
│  - TTL expiration                          │
│  - Pub/Sub messaging                       │
└─────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

- Node.js 16+ installed
- BitBarrel server running locally on port 9876

### 1. Install Dependencies

```bash
npm install
```

### 2. Build the Project

```bash
npm run build
```

### 3. Start BitBarrel Server

In a separate terminal:
```bash
cd /path/to/bitbarrel
./bitbarrel --port 9876
```

### 4. Run the Dashboard

```bash
npm start
```

### 5. Open Your Browser

Navigate to `http://localhost:3000`

## Development Mode

For development with auto-reload:

```bash
npm run dev
```

This uses `ts-node` for TypeScript execution without compilation.

## Usage

### Dashboard Features

1. **Real-Time Activities**: Watch activities appear instantly with blue highlight
2. **Hourly Statistics**: See total activities, unique users, and most popular actions
3. **User Management**: Create users with optional manager relationships
4. **Simulation**: Start automatic activity generation or log manual activities

### Manual Testing

```bash
# Create a user
curl -X POST http://localhost:3000/api/users \
  -H "Content-Type: application/json" \
  -d '{"userId":"alice","name":"Alice Smith"}'

# Log an activity
curl -X POST http://localhost:3000/api/activity \
  -H "Content-Type: application/json" \
  -d '{"userId":"alice","action":"login","timestamp":'$(date +%s)000'}'
```

### Multiple Browser Windows

Open the dashboard in multiple browser windows to see real-time updates across all clients!

## API Endpoints

### Activities
- `POST /api/activity` - Log new activity (with real-time pub/sub)
- `GET /api/activities` - Get recent activities

### Analytics
- `GET /api/stats/hourly` - Get hourly statistics

### Users
- `POST /api/users` - Create new user
- `GET /api/users/:id/manager` - Get user's manager

## Project Structure

```
dashboard/
├── src/
│   ├── types.ts          # TypeScript interfaces
│   ├── monitor.ts        # BitBarrel integration logic
│   └── index.ts          # Express server with API routes
├── public/
│   ├── index.html        # Dashboard UI
│   ├── app.js            # Frontend JavaScript
│   └── style.css         # Styling
├── package.json
└── README.md
```

## Code Highlights

### Backend Key Features

**Real-time Pub/Sub Integration:**
```typescript
// Setup pub/sub for real-time updates
setupPubSub((activity) => {
  io.emit('new-activity', activity);
});
```

**TTL for Auto-Expiration:**
```typescript
await barrel.setTtl(key, 3600); // Auto-expire after 1 hour
```

**Range Queries for Analytics:**
```typescript
const result = await client.rangeQuery(startKey, endKey, { limit });
```

### Frontend Key Features

**Real-time WebSocket:**
```javascript
socket.on('new-activity', (activity) => {
  addActivityToUI(activity, true);
});
```

**Smooth Animations:**
```css
.activity.new {
  animation: slideIn 0.5s ease-out;
}
```

## Customization

### Change TTL Duration

Edit `src/monitor.ts`:
```typescript
export async function logActivityLive(activity: UserActivity): Promise<void> {
  await logActivityWithTtl(activity, 7200); // 2 hours
}
```

### Add New Activity Types

Edit `public/app.js`:
```javascript
const actions = ['login', 'view', 'click', 'purchase', 'logout', 'share'];
```

### Modify Statistics

Edit `public/app.js` functions:
- `getUniqueUsers()`
- `getMostActiveAction()`

## Performance

- **Writes**: ~90K ops/sec (with buffering)
- **Reads**: ~172K ops/sec (cache-friendly)
- **Real-time**: <100ms latency for pub/sub updates
- **Frontend**: Smooth 60fps animations

## Troubleshooting

### "Cannot connect to BitBarrel"
- Ensure BitBarrel server is running: `./bitbarrel --port 9876`
- Check firewall settings
- Verify port 9876 is not in use

### "Build fails"
- Ensure TypeScript is installed: `npm install -g typescript`
- Delete `node_modules` and reinstall: `rm -rf node_modules && npm install`

### "Port 3000 in use"
- Change port in `src/index.ts`: `const PORT = 3001;`

## Next Steps

1. **Add Authentication**: Implement JWT authentication for production
2. **Data Visualization**: Add Chart.js for activity graphs
3. **Pagination**: Implement cursor-based pagination for large datasets
4. **Dockerize**: Create Docker containers for easy deployment
5. **Production**: Deploy to Heroku, AWS, or DigitalOcean

## Learning More

- [BitBarrel TypeScript Tutorial](../../docs/USER_GUIDE/typescript_tutorial.md) - Step-by-step guide
- [BitBarrel Configuration Guide](../../docs/USER_GUIDE/configuration.md)
- [Pub/Sub Features Guide](../../docs/USER_GUIDE/pubsub.md)
- [API Reference](../README.md)

## License

MIT License - same as BitBarrel

## Contributing

Feel free to submit issues and enhancement requests!
