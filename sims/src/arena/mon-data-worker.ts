/**
 * Worker entry for the parallel arena. Receives a shard of (strategy, seed) work units, runs them, and
 * posts back the partial {@link ShardResult}. Each worker has its own module graph (own engine
 * container, event stream, fork counter) so shards are fully isolated — no cross-worker shared state.
 */
import { runItems, type ShardResult, type WorkItem } from './mon-data-core';

declare var self: Worker;

self.onmessage = (e: MessageEvent) => {
  const { items, maxTurns } = e.data as { items: WorkItem[]; maxTurns: number };
  const res: ShardResult = runItems(items, maxTurns);
  postMessage(res);
};
