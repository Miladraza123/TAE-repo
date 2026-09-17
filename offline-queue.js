// Shared offline write queue (§14), used by billing.html/masters.html.
// daily-ledger.html has its own inline copy of this same pattern (written
// first, already tested) — this file generalizes it to insert/update/
// upsert/rpc operations for the other modules rather than duplicating
// four slightly-different versions of the same retry logic.
//
// Queued ops are processed strictly in order: one completes (success OR a
// confirmed permanent failure) before the next is attempted. A duplicate-
// key error on retry is treated as already-succeeded, not a failure — the
// previous attempt may have actually reached the server before the
// response was lost.
'use strict';

window.OfflineQueue = (function () {
  var KEY = 'oht:offlineQueue';
  var flushing = false;

  function getQueue() {
    try { return JSON.parse(localStorage.getItem(KEY) || '[]'); } catch (e) { return []; }
  }
  function setQueue(q) {
    try { localStorage.setItem(KEY, JSON.stringify(q)); } catch (e) {}
  }
  function enqueue(op) {
    var q = getQueue();
    op.id = op.id || (Date.now() + '-' + Math.random().toString(36).slice(2));
    q.push(op);
    setQueue(q);
    return op.id;
  }
  function count() { return getQueue().length; }

  function isNetworkError(err) {
    return !navigator.onLine || /network|fetch|failed to fetch/i.test((err && err.message) || '');
  }

  async function runOp(sb, op) {
    if (op.kind === 'insert') return sb.from(op.table).insert(op.payload);
    if (op.kind === 'update') return sb.from(op.table).update(op.payload).eq('id', op.recordId);
    if (op.kind === 'upsert') return sb.from(op.table).upsert(op.payload, { onConflict: op.conflictCol || 'id' });
    if (op.kind === 'rpc') return sb.rpc(op.fn, op.args);
    return { error: { message: 'unknown queued op kind: ' + op.kind } };
  }

  async function flush(sb, onDrainedOne) {
    if (flushing || !navigator.onLine) return;
    flushing = true;
    try {
      var q = getQueue();
      while (q.length) {
        var op = q[0];
        var res;
        try {
          res = await runOp(sb, op);
        } catch (e) {
          if (isNetworkError(e)) break; // still offline (or flaky) — stop, retry later
          res = { error: e };
        }
        if (res && res.error && res.error.code !== '23505') {
          if (isNetworkError(res.error)) break; // stop, retry later
          // A genuine (non-network, non-duplicate) error on a queued op is
          // permanent — drop it rather than blocking every later queued
          // op behind it forever, but keep it visible for the user to see.
          console.error('Dropping failed queued operation:', op, res.error);
        }
        q.shift();
        setQueue(q);
        if (onDrainedOne) onDrainedOne(op, res);
      }
    } finally {
      flushing = false;
    }
  }

  function startAutoFlush(sb, intervalMs) {
    window.addEventListener('online', function () { flush(sb); });
    setInterval(function () { flush(sb); }, intervalMs || 15000);
    flush(sb);
  }

  return { enqueue: enqueue, flush: flush, count: count, startAutoFlush: startAutoFlush, isNetworkError: isNetworkError };
})();
