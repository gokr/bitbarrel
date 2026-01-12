import { BitBarrelClient } from '@bitbarrel/client';
import { UserActivity, UserProfile } from './types';

// Initialize BitBarrel client
const client = new BitBarrelClient({
  host: 'localhost',
  port: 9876,
  autoConnect: true
});

// Initialize barrels
let activityBarrel: any;
let analyticsBarrel: any;
let profilesBarrel: any;

export async function initializeBarrels(): Promise<void> {
  // Create and use activity barrel
  await client.createBarrel('user-activities');
  activityBarrel = client;
  await client.useBarrel('user-activities');

  // Create analytics barrel with ordered index for range queries
  await client.createBarrel('user-activities-analytics', JSON.stringify({
    mode: 'bmCritBit'
  }));
  analyticsBarrel = client;

  // Create profiles barrel
  await client.createBarrel('user-profiles');
  profilesBarrel = client;
}

// Log an activity
export async function logActivity(activity: UserActivity): Promise<void> {
  const key = `activity:${activity.userId}:${activity.timestamp}`;
  await activityBarrel.set(key, JSON.stringify(activity));
}

// Log activity with TTL
export async function logActivityWithTtl(
  activity: UserActivity,
  ttlSeconds: number = 3600 // 1 hour default
): Promise<void> {
  const key = `activity:${activity.userId}:${activity.timestamp}`;
  await activityBarrel.set(key, JSON.stringify(activity));
  await activityBarrel.setTtl(key, ttlSeconds);
  console.log(`✅ Logged activity with ${ttlSeconds}s TTL`);
}

// Log activity with real-time pub/sub
export async function logActivityLive(activity: UserActivity): Promise<void> {
  // Store with TTL
  await logActivityWithTtl(activity, 3600);

  // Publish to pub/sub for real-time updates
  await activityBarrel.publish(`activity:${activity.userId}`, JSON.stringify(activity));
  await activityBarrel.publish('activity:all', JSON.stringify(activity));
}

// Get recent activities
export async function getRecentActivities(limit: number = 20): Promise<UserActivity[]> {
  await client.useBarrel('user-activities');
  const keys = await client.listKeys();
  const activityKeys = keys.filter(key => key.startsWith('activity:')).slice(0, limit);
  const activities: UserActivity[] = [];

  for (const key of activityKeys) {
    try {
      const value = await client.get(key);
      if (value) activities.push(JSON.parse(value));
    } catch (error) {
      // Skip if key doesn't exist
    }
  }

  return activities.sort((a, b) => b.timestamp - a.timestamp);
}

// Get activities in a time range
export async function getActivitiesInTimeRange(
  startTime: number,
  endTime: number,
  limit: number = 100
): Promise<UserActivity[]> {
  const startKey = `activity:${startTime}:`;
  const endKey = `activity:${endTime}:`;

  await client.useBarrel('user-activities-analytics');
  const result = await client.rangeQuery(startKey, endKey, { limit });

  return result.items.map(([_, value]) => JSON.parse(value));
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

// Create user with manager reference
export async function createUser(profile: UserProfile): Promise<void> {
  await client.useBarrel('user-profiles');
  const key = `user:profile:${profile.userId}`;
  await profilesBarrel.set(key, JSON.stringify(profile));

  // Store manager reference for traversal
  if (profile.managerId) {
    await profilesBarrel.set(`${key}:_refs:manager`, profile.managerId);
  }
}

// Get user's manager
export async function getUserManager(userId: string): Promise<UserProfile | null> {
  await client.useBarrel('user-profiles');
  const key = `user:profile:${userId}`;

  try {
    const managerId = await profilesBarrel.get(`${key}:_refs:manager`);
    if (!managerId) return null;

    const managerData = await profilesBarrel.get(`user:profile:${managerId}`);
    return managerData ? JSON.parse(managerData) : null;
  } catch (error) {
    return null;
  }
}

// Setup pub/sub subscription
export async function setupPubSub(callback: (activity: UserActivity) => void): Promise<void> {
  await client.useBarrel('user-activities');

  // Set up message handler
  client.setMessageHandler((event: any) => {
    if (event.topic && event.topic.startsWith('activity:')) {
      try {
        const activity = JSON.parse(event.payload) as UserActivity;
        callback(activity);
      } catch (error) {
        console.error('Failed to parse activity:', error);
      }
    }
  });

  // Subscribe to all activity topics
  await client.subscribe('activity:*', {
    enableKvEvents: false,
    enablePresence: false,
    replayHistory: 0
  });
}

export { client };
