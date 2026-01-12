# TypeScript Tutorial: Building a Real-Time Activity Dashboard

This tutorial guides you through building a complete web application with BitBarrel, demonstrating all major features including CRUD operations, TTL, range queries, pub/sub messaging, and reference traversal.

## What You'll Build

A **Real-Time User Activity Dashboard** that:
- Logs user activities with automatic expiration
- Shows live updates in the browser
- Provides time-based analytics
- Manages user relationships

## Features Demonstrated

✅ **Core CRUD**: Create, read, update, delete operations
✅ **TTL**: Automatic expiration of old data
✅ **Range Queries**: Time-based analytics and statistics
✅ **Pub/Sub**: Real-time updates with WebSocket
✅ **Reference Traversal**: User hierarchies and relationships

## Prerequisites

- Node.js 16+ installed
- Basic TypeScript knowledge
- Basic HTML/CSS/JavaScript knowledge
- BitBarrel server running locally

## Tutorial Structure

This tutorial is **progressively built** - each phase adds new features:

1. **Phase 1**: Core CRUD operations with REST API and simple frontend
2. **Phase 2**: TTL for automatic data expiration
3. **Phase 3**: Range queries for time-based analytics
4. **Phase 4**: Pub/sub for real-time WebSocket updates
5. **Phase 5**: Reference traversal for user relationships

By the end, you'll have a complete full-stack application!

## Project Overview

**Backend**: Express.js server with TypeScript
**Frontend**: HTML/CSS/JavaScript in the browser
**Real-time**: WebSocket via Socket.IO
**Storage**: BitBarrel with multiple barrel types

```
┌─────────────────────────────────────────────┐
│  Browser (Dashboard)                        │
│  - HTML/CSS/JavaScript                     │
│  - WebSocket real-time updates             │
└──────────────┬──────────────────────────────┘
               │ HTTP / WebSocket
┌──────────────▼──────────────────────────────┐
│  Express Server (TypeScript)                │
│  - REST API                                │
│  - BitBarrel integration                   │
└──────────────┬──────────────────────────────┘
               │
┌──────────────▼──────────────────────────────┐
│  BitBarrel Storage                         │
│  - user-activities barrel (ordered)        │
│  - user-profiles barrel                    │
└─────────────────────────────────────────────┘
```

## Installation & Setup

### 1. Start BitBarrel Server

First, make sure BitBarrel is running:

```bash
cd /path/to/bitbarrel
nimble build
./bitbarrel --port 9876
```

The server will start on `ws://localhost:9876`.

### 2. Create the Project

In a new terminal:

```bash
mkdir activity-dashboard && cd activity-dashboard
npm init -y
npm install @bitbarrel/client typescript @types/node express socket.io
npx tsc --init
mkdir src public
```

### 3. Configure TypeScript

Edit `tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "commonjs",
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  }
}
```

Great! Now let's build the application phase by phase.

## Phase 1: Core CRUD Operations

In this phase, we'll create:
- Backend: REST API for logging and retrieving activities
- Frontend: Simple web page showing recent activities

### Backend Setup

**File: `src/types.ts`**

```typescript
export interface UserActivity {
  userId: string;
  action: string;
  timestamp: number;
  metadata?: Record<string, any>;
}
```

**File: `src/monitor.ts`**

```typescript
import { BitBarrelClient } from '@bitbarrel/client';
import { UserActivity } from './types';

const client = new BitBarrelClient({
  host: 'localhost',
  port: 9876,
  autoConnect: true
});

// Initialize barrel
await client.createBarrel('user-activities');
await client.useBarrel('user-activities');

// Log an activity
export async function logActivity(activity: UserActivity): Promise<void> {
  const key = `activity:${activity.userId}:${activity.timestamp}`;
  await client.set(key, JSON.stringify(activity));
}

// Get recent activities
export async function getRecentActivities(limit: number = 20): Promise<UserActivity[]> {
  const keys = await client.listKeys();
  const activityKeys = keys.filter(key => key.startsWith('activity:')).slice(0, limit);
  const activities: UserActivity[] = [];

  for (const key of activityKeys) {
    const value = await client.get(key);
    if (value) activities.push(JSON.parse(value));
  }

  return activities.sort((a, b) => b.timestamp - a.timestamp);
}
```

**File: `src/index.ts`**

```typescript
import express from 'express';
import { logActivity, getRecentActivities } from './monitor';
import { UserActivity } from './types';

const app = express();
app.use(express.json());
app.use(express.static('public'));

// API: Log new activity
app.post('/api/activity', async (req, res) => {
  try {
    const activity: UserActivity = req.body;
    await logActivity(activity);
    res.json({ success: true });
  } catch (error) {
    res.status(500).json({ error: 'Failed to log activity' });
  }
});

// API: Get recent activities
app.get('/api/activities', async (req, res) => {
  try {
    const activities = await getRecentActivities();
    res.json(activities);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch activities' });
  }
});

const PORT = 3000;
app.listen(PORT, () => {
  console.log(`🚀 Server running at http://localhost:${PORT}`);
});
```

### Frontend Setup

**File: `public/index.html`**

```html
<!DOCTYPE html>
<html>
<head>
  <title>Activity Dashboard</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <h1>🚀 Real-Time Activity Monitor</h1>
  <div id="activities">Loading...</div>
  <script src="app.js"></script>
</body>
</html>
```

**File: `public/style.css`**

```css
body {
  font-family: Arial, sans-serif;
  margin: 0;
  padding: 20px;
  background: #f5f5f5;
}

h1 {
  color: #333;
  text-align: center;
}

#activities {
  background: white;
  padding: 20px;
  margin: 20px 0;
  border-radius: 8px;
  box-shadow: 0 2px 4px rgba(0,0,0,0.1);
}

.activity {
  padding: 10px;
  margin: 5px 0;
  border-left: 4px solid #007bff;
  background: #f8f9fa;
}
```

**File: `public/app.js`**

```javascript
async function loadActivities() {
  try {
    const response = await fetch('/api/activities');
    const activities = await response.json();

    const container = document.getElementById('activities');
    container.innerHTML = activities.map(act => `
      <div class="activity">
        <strong>${act.userId}</strong> - ${act.action}
        <small>${new Date(act.timestamp).toLocaleTimeString()}</small>
      </div>
    `).join('');
  } catch (error) {
    console.error('Failed to load activities:', error);
  }
}

// Load activities on page load
loadActivities();
setInterval(loadActivities, 2000); // Refresh every 2 seconds
```

### Test Phase 1

1. **Start the server:**
```bash
npx ts-node src/index.ts
```

2. **Log an activity (in another terminal):**
```bash
curl -X POST http://localhost:3000/api/activity \
  -H "Content-Type: application/json" \
  -d '{"userId":"user1","action":"login","timestamp":'$(date +%s)000'}'
```

3. **Open browser:**
Navigate to `http://localhost:3000`

You should see the activity appear in the dashboard!

## Phase 2: Adding TTL (Time To Live)

Now we'll add automatic expiration so old activities don't accumulate forever.

### Backend Changes

**Update `src/monitor.ts`:**

```typescript
// Add TTL support
export async function logActivityWithTtl(
  activity: UserActivity,
  ttlSeconds: number = 86400 // 24 hours by default
): Promise<void> {
  const key = `activity:${activity.userId}:${activity.timestamp}`;

  // Store the activity
  await barrel.set(key, JSON.stringify(activity));

  // Set TTL for automatic expiration
  await barrel.setTtl(key, ttlSeconds);

  console.log(`✅ Logged activity with ${ttlSeconds}s TTL`);
}

// Check remaining TTL
export async function getActivityTtl(userId: string, timestamp: number): Promise<number> {
  const key = `activity:${userId}:${timestamp}`;
  return await barrel.getTtl(key); // Returns seconds remaining
}
```

**Update `src/index.ts`:**

```typescript
// Update the API to use TTL (activities expire after 1 hour)
app.post('/api/activity', async (req, res) => {
  try {
    const activity: UserActivity = req.body;
    await logActivityWithTtl(activity, 3600); // 1 hour TTL
    res.json({ success: true });
  } catch (error) {
    res.status(500).json({ error: 'Failed to log activity' });
  }
});

// Add endpoint to check TTL
app.get('/api/activity/:userId/:timestamp/ttl', async (req, res) => {
  try {
    const ttl = await getActivityTtl(req.params.userId, parseInt(req.params.timestamp));
    res.json({ ttl });
  } catch (error) {
    res.status(500).json({ error: 'Failed to get TTL' });
  }
});
```

### Frontend Changes

No frontend changes needed! The TTL works transparently - old activities automatically disappear from the dashboard.

### Test TTL

```bash
# Log an activity with 1 hour TTL
curl -X POST http://localhost:3000/api/activity \
  -H "Content-Type: application/json" \
  -d '{"userId":"user2","action":"view","timestamp":'$(date +%s)000'}'

# Check remaining TTL (replace timestamp with actual value)
curl http://localhost:3000/api/activity/user2/1700000000000/ttl
```

## Phase 3: Range Queries for Analytics

Now we'll add time-based analytics by using range queries (requires ordered barrel mode).

### Backend Changes

**Update `src/monitor.ts`:**

```typescript
// Add analytics barrel with ordered index for range queries
export const analyticsBarrel = client.useBarrel('user-activities', {
  mode: 'bmCritBit' // Enable range queries with CritBit tree
});

// Get activities in a time range
export async function getActivitiesInTimeRange(
  startTime: number,
  endTime: number,
  limit: number = 100
): Promise<UserActivity[]> {
  const startKey = `activity:${startTime}:`;
  const endKey = `activity:${endTime}:`;

  const [items] = await analyticsBarrel.itemsInRange(startKey, endKey, limit);

  return items.map(([_, value]) => JSON.parse(value));
}

// Get hourly statistics
export async function getHourlyStats(): Promise<{
  count: number;
  activities: UserActivity[];
}> {
  const oneHourAgo = Date.now() - (60 * 60 * 1000);
  const activities = await getActivitiesInTimeRange(oneHourAgo, Date.now());

  return {
    count: activities.length,
    activities
  };
}
```

**Update `src/index.ts`:**

```typescript
// Add analytics endpoint
app.get('/api/stats/hourly', async (req, res) => {
  try {
    const stats = await getHourlyStats();
    res.json(stats);
  } catch (error) {
    res.status(500).json({ error: 'Failed to get stats' });
  }
});
```

### Frontend Changes

**Update `public/app.js`:**

```javascript
// Add stats display
async function loadStats() {
  try {
    const response = await fetch('/api/stats/hourly');
    const stats = await response.json();

    let statsDiv = document.getElementById('stats');
    if (!statsDiv) {
      statsDiv = document.createElement('div');
      statsDiv.id = 'stats';
      statsDiv.className = 'stats-panel';
      document.body.insertBefore(statsDiv, document.body.firstChild);
    }

    statsDiv.innerHTML = `
      <h2>📊 Hourly Statistics</h2>
      <p>Total Activities: <strong>${stats.count}</strong></p>
    `;
  } catch (error) {
    console.error('Failed to load stats:', error);
  }
}

// Load stats periodically
setInterval(loadStats, 5000); // Every 5 seconds
loadStats(); // Initial load
```

**Update `public/style.css`:**

```css
.stats-panel {
  background: white;
  padding: 20px;
  margin: 20px 0;
  border-radius: 8px;
  box-shadow: 0 2px 4px rgba(0,0,0,0.1);
}
```

### Test Range Queries

The dashboard will now show hourly statistics above the activities list!

## Phase 4: Pub/Sub for Real-Time Updates

Now for the exciting part - real-time updates using WebSocket and pub/sub!

### Backend Changes

**Update `src/index.ts`:**

```typescript
import { Server } from 'socket.io';

// Create HTTP server and Socket.IO
const server = app.listen(PORT);
const io = new Server(server);

// Setup pub/sub for real-time updates
barrel.subscribe('activity:*', (topic: string, message: string) => {
  const activity = JSON.parse(message);
  io.emit('new-activity', activity); // Broadcast to all connected clients
});

console.log('📡 Real-time updates enabled');

// Update API to publish activities
async function logActivityLive(activity: UserActivity): Promise<void> {
  // Store with TTL
  await logActivityWithTtl(activity);

  // Publish to pub/sub for real-time updates
  await barrel.publish(`activity:${activity.userId}`, JSON.stringify(activity));
}

app.post('/api/activity', async (req, res) => {
  try {
    const activity: UserActivity = req.body;
    await logActivityLive(activity);
    res.json({ success: true });
  } catch (error) {
    res.status(500).json({ error: 'Failed to log activity' });
  }
});
```

### Frontend Changes

**Update `public/index.html`:**

```html
<!-- Add Socket.IO script -->
<script src="/socket.io/socket.io.js"></script>
<script src="app.js"></script>
```

**Update `public/app.js`:**

```javascript
// Connect to WebSocket
const socket = io();

// Listen for new activities in real-time
socket.on('new-activity', (activity) => {
  console.log('🔄 Real-time update:', activity);

  // Add to activities list immediately with animation
  const container = document.getElementById('activities');
  const div = document.createElement('div');
  div.className = 'activity new';
  div.innerHTML = `
    <strong>${activity.userId}</strong> - ${activity.action}
    <small>just now</small>
  `;
  container.insertBefore(div, container.firstChild);

  // Remove highlight after animation
  setTimeout(() => div.classList.remove('new'), 1000);
});
```

**Update `public/style.css`:**

```css
.activity.new {
  background: #e3f2fd;
  animation: fadeIn 0.5s;
}

@keyframes fadeIn {
  from {
    opacity: 0;
    transform: translateY(-10px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}
```

### Test Real-Time Updates

1. Open the dashboard in **two browser windows**
2. In one window, use curl to log an activity
3. Watch both windows update instantly!

## Phase 5: Reference Traversal - User Relationships

Finally, let's add user management with manager relationships.

### Backend Changes

**Update `src/types.ts`:**

```typescript
export interface UserProfile {
  userId: string;
  name: string;
  managerId?: string;
}
```

**Update `src/monitor.ts`:**

```typescript
// Add profiles barrel
export const profilesBarrel = client.useBarrel('user-profiles');

// Create user with manager reference
export async function createUser(profile: UserProfile): Promise<void> {
  const key = `user:profile:${profile.userId}`;
  await profilesBarrel.set(key, JSON.stringify(profile));

  // Store manager reference for traversal
  if (profile.managerId) {
    await profilesBarrel.set(`${key}:_refs:manager`, profile.managerId);
  }
}

// Get user's manager (traversal example)
export async function getUserManager(userId: string): Promise<UserProfile | null> {
  const key = `user:profile:${userId}`;
  const managerId = await profilesBarrel.get(`${key}:_refs:manager`);

  if (!managerId) return null;

  const managerData = await profilesBarrel.get(`user:profile:${managerId}`);
  return managerData ? JSON.parse(managerData) : null;
}
```

**Update `src/index.ts`:**

```typescript
import { UserProfile } from './types';

// API: Create user
app.post('/api/users', async (req, res) => {
  try {
    const profile: UserProfile = req.body;
    await createUser(profile);
    res.json({ success: true });
  } catch (error) {
    res.status(500).json({ error: 'Failed to create user' });
  }
});

// API: Get user's manager
app.get('/api/users/:userId/manager', async (req, res) => {
  try {
    const manager = await getUserManager(req.params.userId);
    res.json(manager);
  } catch (error) {
    res.status(500).json({ error: 'Failed to get manager' });
  }
});
```

### Frontend Changes

**Update `public/app.js`:**

```javascript
// Add user management UI
function addUserForm() {
  const form = document.createElement('div');
  form.className = 'user-panel';
  form.innerHTML = `
    <h2>👤 User Management</h2>
    <input type="text" id="userId" placeholder="User ID">
    <input type="text" id="userName" placeholder="Name">
    <input type="text" id="managerId" placeholder="Manager ID (optional)">
    <button onclick="createUser()">Create User</button>
    <div id="user-result"></div>
  `;
  document.body.appendChild(form);
}

async function createUser() {
  const profile = {
    userId: document.getElementById('userId').value,
    name: document.getElementById('userName').value,
    managerId: document.getElementById('managerId').value || undefined
  };

  try {
    const response = await fetch('/api/users', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(profile)
    });

    const result = await response.json();
    document.getElementById('user-result').innerHTML =
      result.success ? '✅ User created!' : '❌ Failed to create user';
  } catch (error) {
    console.error('Error creating user:', error);
  }
}

// Call on load
addUserForm();
```

**Update `public/style.css`:**

```css
.user-panel {
  background: white;
  padding: 20px;
  margin: 20px 0;
  border-radius: 8px;
  box-shadow: 0 2px 4px rgba(0,0,0,0.1);
}

input, button {
  margin: 5px;
  padding: 8px;
}

button {
  background: #007bff;
  color: white;
  border: none;
  border-radius: 4px;
  cursor: pointer;
}

button:hover {
  background: #0056b3;
}
```

### Frontend HTML Structure

**Update `public/index.html` with complete structure:**

```html
<!DOCTYPE html>
<html>
<head>
  <title>Activity Dashboard</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <div class="container">
    <h1>🚀 Real-Time Activity Dashboard</h1>

    <div class="stats-panel">
      <h2>📊 Hourly Statistics</h2>
      <div id="stats">Loading...</div>
    </div>

    <div class="activities-panel">
      <h2>📋 Recent Activities</h2>
      <div id="activities">Loading...</div>
    </div>

    <div class="user-panel">
      <h2>👤 User Management</h2>
      <div id="user-form"></div>
    </div>
  </div>

  <script src="/socket.io/socket.io.js"></script>
  <script src="app.js"></script>
</body>
</html>
```

### Test User Relationships

```bash
# Create a manager
curl -X POST http://localhost:3000/api/users \
  -H "Content-Type: application/json" \
  -d '{"userId":"manager1","name":"Alice"}'

# Create an employee with manager
curl -X POST http://localhost:3000/api/users \
  -H "Content-Type: application/json" \
  -d '{"userId":"user1","name":"Bob","managerId":"manager1"}'

# Check the manager
curl http://localhost:3000/api/users/user1/manager
```

Or use the UI in the dashboard!

## Running the Complete Application

### Package.json Setup

**File: `package.json`**

```json
{
  "name": "activity-dashboard",
  "version": "1.0.0",
  "scripts": {
    "start": "ts-node src/index.ts",
    "build": "tsc",
    "dev": "nodemon src/index.ts"
  },
  "dependencies": {
    "bitbarrel-client": "^1.0.0",
    "express": "^4.18.0",
    "socket.io": "^4.7.0",
    "typescript": "^5.0.0",
    "@types/node": "^20.0.0"
  }
}
```

### Start the Application

```bash
# Install dependencies (if not already done)
npm install

# Start the server
npm start

# Open browser to http://localhost:3000
```

You should see the complete dashboard with all three panels!

## Architecture Summary

```
┌─────────────────────────────────────────────┐
│  Browser (Dashboard)                        │
│  - HTML/CSS/JavaScript                     │
│  - WebSocket real-time updates             │
└──────────────┬──────────────────────────────┘
               │ HTTP / WebSocket
┌──────────────▼──────────────────────────────┐
│  Express Server (TypeScript)                │
│  - REST API endpoints                      │
│  - Socket.IO WebSocket server              │
│  - BitBarrel client integration            │
└──────────────┬──────────────────────────────┘
               │
┌──────────────▼──────────────────────────────┐
│  BitBarrel Storage Engine                   │
│  - user-activities barrel (bmCritBit)      │
│  - user-profiles barrel                    │
│  - TTL expiration                          │
│  - Pub/Sub messaging                       │
└─────────────────────────────────────────────┘
```

## Best Practices

### 1. Connection Management
```typescript
// Reuse the same client connection throughout your application
const client = new Client('ws://localhost:9876');
```

### 2. Error Handling
```typescript
try {
  await barrel.set(key, value);
} catch (error) {
  console.error('Operation failed:', error);
  // Handle appropriately
}
```

### 3. Key Design
```typescript
// Use clear, consistent prefixes
const key = `activity:${userId}:${timestamp}`;  // ✅ Good
const key = `${userId}_${Date.now()}`;          // ❌ Avoid
```

### 4. TTL Strategy
```typescript
// Set appropriate TTL based on use case
await barrel.setTtl(key, 3600);        // Short-lived data
await barrel.setTtl(key, 86400);       // Daily data
await barrel.setTtl(key, 604800);      // Weekly data
```

### 5. Frontend Patterns
```javascript
// Use loading states
const [isLoading, setIsLoading] = useState(false);

// Implement retry logic for failed requests
async function fetchWithRetry(url, retries = 3) {
  for (let i = 0; i < retries; i++) {
    try {
      return await fetch(url);
    } catch (error) {
      if (i === retries - 1) throw error;
      await new Promise(r => setTimeout(r, 1000 * (i + 1)));
    }
  }
}
```

### 6. Cleanup on Shutdown

```typescript
process.on('SIGINT', async () => {
  console.log('\n🛑 Shutting down...');
  await client.close(); // Close BitBarrel connection
  process.exit(0);
});
```

## Performance Optimization Tips

1. **Use batch operations** for multiple writes:
```typescript
// Instead of individual writes
for (const activity of activities) {
  await logActivity(activity);  // Slow
}

// Batch operations when possible
// (depends on your client library support)
```

2. **Limit result sizes** in queries:
```typescript
const [items] = await barrel.itemsInRange(start, end, 100); // Limit to 100
```

3. **Use appropriate sync modes**:
```typescript
const barrel = client.useBarrel('my-barrel', {
  syncMode: 'buffered'  // For better write performance
});
```

4. **Implement caching** for frequently accessed data:
```typescript
const cache = new Map<string, any>();

async function getCached(key: string) {
  if (cache.has(key)) return cache.get(key);

  const value = await barrel.get(key);
  cache.set(key, value);
  return value;
}
```

## Security Considerations

For production use:

1. **Add authentication**:
```typescript
app.use(authMiddleware); // JWT or session-based auth
```

2. **Validate input**:
```typescript
import { z } from 'zod';

const activitySchema = z.object({
  userId: z.string().min(1).max(100),
  action: z.string().min(1).max(50),
  timestamp: z.number()
});
```

3. **Use HTTPS** in production

4. **Implement rate limiting**:
```typescript
import rateLimit from 'express-rate-limit';

const limiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 100 // limit each IP to 100 requests per windowMs
});
```

## Next Steps

Congratulations! You've built a complete real-time activity dashboard. Here are some ideas to extend it:

1. **Add user authentication** with JWT tokens
2. **Implement pagination** for large activity lists
3. **Add data visualization** with charts (Chart.js, D3.js)
4. **Create activity filters** by user, action type, or date range
5. **Add activity aggregation** (actions per user, hourly breakdowns)
6. **Implement audit logging** for security
7. **Deploy to production** (Heroku, AWS, DigitalOcean)

## Additional Resources

- [BitBarrel Configuration Guide](../configuration.md) - Advanced configuration options
- [Pub/Sub Features Guide](../pubsub.md) - Deep dive into messaging
- [Performance Tuning Guide](../performance.md) - Optimization techniques
- [TypeScript Client API](../../clients/typescript/README.md) - Complete API reference
- [Bitcask Paper](https://riak.com/assets/bitcask-intro.pdf) - Understanding the storage model

## Summary

In this tutorial, you built a full-stack real-time activity dashboard that demonstrates:

✅ **Core CRUD operations** with REST API
✅ **TTL** for automatic data cleanup
✅ **Range queries** for analytics and statistics
✅ **Pub/Sub** for real-time WebSocket updates
✅ **Reference traversal** for user relationships

The application showcases BitBarrel's versatility for building modern, real-time web applications with minimal code and excellent performance.

Happy coding! 🚀
