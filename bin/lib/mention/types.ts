/**
 * Mention-related types for canUseTool interruption
 */

export interface MentionInfo {
  id: string;
  from_squad_name: string;
  to_squad_name: string;
  content: string;
  status: 'unprocessed' | 'processed';
  created_at: string;
}

export interface MentionQueryResult {
  has_mentions: boolean;
  count: number;
  squad_name: string;
  mentions: MentionInfo[];
  error?: string;
}

export interface MentionCheckResult {
  shouldInterrupt: boolean;
  count: number;
  squadName: string;
  mentions: MentionInfo[];
}

export interface MentionCheckerConfig {
  rpcPort: number;
  squadName: string | null;
  cacheTtlMs?: number;
}
