// Shared offline write queue (§14), used by billing.html/masters.html.
// daily-ledger.html has its own inline copy of this same pattern (written
// first, already tested) — this file generalizes it to insert/update/
// upsert/rpc/document-edit operations for the other modules rather than
// duplicating slightly-different versions of the same retry logic.
//
// Queued ops are processed strictly in order: one completes (success OR a
// confirmed permanent failure) before the next is attempted. A duplicate-
// key error on retry is treated as already-succeeded, not a failure — the
// previous attempt may have actually reached the server before the
// response was lost.
'use strict';

window.OfflineQueue = (function () {
  var KEY = 'oht:offlineQueue';
  var FAILED_KEY = 'oht:offlineQueueFailed';
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

  // Ops that fail permanently (not a network error, not a duplicate-key
  // retry) are never silently discarded — they move here so the app can
  // surface "N changes could not be synced" instead of losing them quietly.
  function getFailed() {
    try { return JSON.parse(localStorage.getItem(FAILED_KEY) || '[]'); } catch (e) { return []; }
  }
  function pushFailed(op, error) {
    try {
      var f = getFailed();
      f.push({ op: op, error: (error && error.message) || String(error), failed_at: new Date().toISOString() });
      localStorage.setItem(FAILED_KEY, JSON.stringify(f));
    } catch (e) {}
  }
  function clearFailed() {
    try { localStorage.removeItem(FAILED_KEY); } catch (e) {}
  }

  function isNetworkError(err) {
    return !navigator.onLine || /network|fetch|failed to fetch/i.test((err && err.message) || '');
  }

  // A document's header + lines are always edited together, and applying
  // the lines requires the header merge's line-merge sibling call's OWN
  // result (smart_merge_lines' output feeds apply_merged_lines) — so this
  // whole sequence has to run as one unit whenever it actually executes,
  // not as three independently-queued ops with a payload frozen at queue
  // time (§27's partial-save-prevention concern, applied to deferred sync).
  async function runDocEditMerge(sb, op) {
    if (op.headerId && op.headerOriginal) {
      var hm = await sb.rpc('smart_merge_update', {
        p_table: op.headerTable, p_id: op.headerId, p_original: op.headerOriginal,
        p_new: op.headerNew, p_ignore: op.headerIgnore
      });
      if (hm.error) return hm;
      if (hm.data.status === 'conflict') {
        var retry = await sb.rpc('smart_merge_update', {
          p_table: op.headerTable, p_id: op.headerId, p_original: hm.data.current,
          p_new: op.headerNew, p_ignore: op.headerIgnore
        });
        if (retry.error) return retry;
        if (retry.data.status === 'conflict') {
          return { error: { message: 'Deferred sync conflict on ' + op.headerTable + ': ' + retry.data.conflicts.join(', ') + ' — edit again from the current version.' } };
        }
      }
    }

    if (op.lineTable) {
      var lm = await sb.rpc('smart_merge_lines', {
        p_line_table: op.lineTable, p_fk_col: op.lineFkCol, p_fk_id: op.headerId,
        p_original_lines: op.lineOriginal, p_new_lines: op.lineNew
      });
      if (lm.error) return lm;
      if (lm.data.status === 'conflict') {
        return { error: { message: 'Deferred sync conflict on ' + op.lineTable + ' lines: ' + lm.data.conflicts.join(', ') + ' — edit again from the current version.' } };
      }
      return sb.rpc('apply_merged_lines', {
        p_line_table: op.lineTable, p_fk_col: op.lineFkCol, p_fk_id: op.headerId, p_result_lines: lm.data.lines
      });
    }

    return { error: null };
  }

  // Stock Transfers (§17) have no concurrency merge (record-of-intent only,
  // no stock/cost effect) — their edit is header update + full lines
  // replace, so it's queued as one unit the same reason doc_edit_merge is:
  // a line replace has to run after its own header update actually lands.
  async function runTransferEditReplace(sb, op) {
    var upd = await sb.from(op.table).update(op.headerPayload).eq('id', op.recordId);
    if (upd.error) return upd;
    var del = await sb.from(op.lineTable).delete().eq(op.lineFkCol, op.recordId);
    if (del.error) return del;
    return sb.from(op.lineTable).insert(op.linesPayload);
  }

  async function runOp(sb, op) {
    if (op.kind === 'insert') return sb.from(op.table).insert(op.payload);
    if (op.kind === 'update') return sb.from(op.table).update(op.payload).eq('id', op.recordId);
    if (op.kind === 'upsert') return sb.from(op.table).upsert(op.payload, { onConflict: op.conflictCol || 'id' });
    if (op.kind === 'rpc') return sb.rpc(op.fn, op.args);
    if (op.kind === 'doc_edit_merge') return runDocEditMerge(sb, op);
    if (op.kind === 'transfer_edit_replace') return runTransferEditReplace(sb, op);
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
          // A genuine (non-network, non-duplicate) error is permanent for
          // this op — never block every later queued op behind it forever,
          // but never discard it silently either.
          pushFailed(op, res.error);
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

  return {
    enqueue: enqueue, flush: flush, count: count, startAutoFlush: startAutoFlush,
    isNetworkError: isNetworkError, getFailed: getFailed, clearFailed: clearFailed
  };
})();
