import express from 'express';
import { Server } from 'socket.io';
import { createServer } from 'http';
import {
  initializeBarrels,
  logActivity,
  logActivityWithTtl,
  logActivityLive,
  getRecentActivities,
  getHourlyStats,
  createUser,
  getUserManager,
  setupPubSub,
  client
} from './monitor';
import { UserActivity, UserProfile } from './types';

const app = express();
const server = createServer(app);
const io = new Server(server);

app.use(express.json());
app.use(express.static('public'));

const PORT = 3000;

// Initialize barrels on startup
initializeBarrels().then(() => {
  console.log('✅ Barrels initialized');

  // Setup pub/sub for real-time updates
  setupPubSub((activity) => {
    io.emit('new-activity', activity);
  }).then(() => {
    console.log('📡 Pub/sub setup complete');
  });
}).catch(console.error);

// API Routes

// Log new activity
app.post('/api/activity', async (req, res) => {
  try {
    const activity: UserActivity = req.body;
    await logActivityLive(activity);
    res.json({ success: true });
  } catch (error) {
    console.error('Failed to log activity:', error);
    res.status(500).json({ error: 'Failed to log activity' });
  }
});

// Get recent activities
app.get('/api/activities', async (req, res) => {
  try {
    const activities = await getRecentActivities();
    res.json(activities);
  } catch (error) {
    console.error('Failed to fetch activities:', error);
    res.status(500).json({ error: 'Failed to fetch activities' });
  }
});

// Get hourly statistics
app.get('/api/stats/hourly', async (req, res) => {
  try {
    const stats = await getHourlyStats();
    res.json(stats);
  } catch (error) {
    console.error('Failed to get stats:', error);
    res.status(500).json({ error: 'Failed to get stats' });
  }
});

// Create user
app.post('/api/users', async (req, res) => {
  try {
    const profile: UserProfile = req.body;
    await createUser(profile);
    res.json({ success: true });
  } catch (error) {
    console.error('Failed to create user:', error);
    res.status(500).json({ error: 'Failed to create user' });
  }
});

// Get user's manager
app.get('/api/users/:userId/manager', async (req, res) => {
  try {
    const manager = await getUserManager(req.params.userId);
    res.json(manager);
  } catch (error) {
    console.error('Failed to get manager:', error);
    res.status(500).json({ error: 'Failed to get manager' });
  }
});

// Socket.IO connection
io.on('connection', (socket) => {
  console.log('👤 Client connected:', socket.id);

  socket.on('disconnect', () => {
    console.log('👤 Client disconnected:', socket.id);
  });
});

// Graceful shutdown
process.on('SIGINT', async () => {
  console.log('\n🛑 Shutting down...');
  await client.close();
  server.close(() => {
    process.exit(0);
  });
});

server.listen(PORT, () => {
  console.log(`🚀 Server running at http://localhost:${PORT}`);
  console.log('📡 WebSocket server ready');
});
