export interface UserActivity {
  userId: string;
  action: string;
  timestamp: number;
  metadata?: Record<string, any>;
}

export interface UserProfile {
  userId: string;
  name: string;
  managerId?: string;
}
