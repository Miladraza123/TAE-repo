// Nightly backup: exports every table to Excel + restorable JSON, emails
// both via Gmail SMTP (§23). Run by .github/workflows/daily-backup.yml,
// or locally with `npm run backup` (needs the env vars listed in the
// project's setup guide).
'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const crypto = require('crypto');
const { createClient } = require('@supabase/supabase-js');
const ExcelJS = require('exceljs');
const nodemailer = require('nodemailer');

// Dependency order matches the migrations (§31/§32) — also the order
// disaster-recovery restores in.
const TABLES = [
  'app_users', 'companies', 'warehouses', 'period_lock', 'party_kinds', 'parties',
  'items', 'item_units', 'services', 'item_cost_snapshot', 'party_opening_balances',
  'vouchers', 'voucher_lines', 'sales_returns', 'sales_return_lines', 'stock_adjustments',
  'quotations', 'quotation_lines', 'purchase_orders', 'po_lines',
  'service_invoices', 'service_invoice_lines', 'service_quotations', 'service_quotation_lines',
  'recurring_service_templates', 'stock_transfers', 'stock_transfer_lines', 'sheets',
  'audit_log' // exported for reference only — NEVER restored, see restore tooling
];

const PAGE_SIZE = 1000;

async function fetchAllRows(sb, table) {
  const rows = [];
  let from = 0;
  for (;;) {
    const { data, error } = await sb.from(table).select('*').range(from, from + PAGE_SIZE - 1);
    if (error) {
      // Postgres 42P01 (undefined_table) via PostgREST: table doesn't exist yet
      // in this database (e.g. a fresh project before every migration ran) —
      // not a failure, just skip it and note it.
      if (error.code === '42P01' || /does not exist/i.test(error.message || '')) {
        return { rows: null, missing: true };
      }
      throw new Error(`reading ${table}: ${error.message}`);
    }
    rows.push(...data);
    if (data.length < PAGE_SIZE) break;
    from += PAGE_SIZE;
  }
  return { rows, missing: false };
}

async function buildWorkbook(exported) {
  const wb = new ExcelJS.Workbook();
  wb.created = new Date();
  for (const table of Object.keys(exported)) {
    const rows = exported[table];
    const sheet = wb.addWorksheet(table.slice(0, 31)); // Excel sheet name limit
    if (!rows.length) continue;
    const columns = Object.keys(rows[0]);
    sheet.columns = columns.map((c) => ({ header: c, key: c, width: 20 }));
    rows.forEach((r) => {
      const flat = {};
      for (const c of columns) {
        const v = r[c];
        flat[c] = v !== null && typeof v === 'object' ? JSON.stringify(v) : v;
      }
      sheet.addRow(flat);
    });
  }
  return wb;
}

function encryptJson(buffer, passphrase) {
  const salt = crypto.randomBytes(16);
  const key = crypto.scryptSync(passphrase, salt, 32);
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const encrypted = Buffer.concat([cipher.update(buffer), cipher.final()]);
  const authTag = cipher.getAuthTag();
  // Format: salt(16) | iv(12) | authTag(16) | ciphertext
  return Buffer.concat([salt, iv, authTag, encrypted]);
}

async function main() {
  const {
    SUPABASE_URL, SUPABASE_ANON_KEY,
    BACKUP_EMAIL, BACKUP_PASSWORD,
    GMAIL_USER, GMAIL_APP_PASSWORD,
    BACKUP_TO_EMAIL, BACKUP_PASSPHRASE,
    BACKUP_SCHEMA_FILE
  } = process.env;

  const missing = ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'BACKUP_EMAIL', 'BACKUP_PASSWORD', 'GMAIL_USER', 'GMAIL_APP_PASSWORD', 'BACKUP_TO_EMAIL']
    .filter((k) => !process.env[k]);
  if (missing.length) {
    console.error('Missing required secrets:', missing.join(', '));
    process.exit(1);
  }

  const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const { error: authError } = await sb.auth.signInWithPassword({ email: BACKUP_EMAIL, password: BACKUP_PASSWORD });
  if (authError) {
    console.error('Backup account sign-in failed:', authError.message);
    process.exit(1);
  }

  const exported = {};
  const skippedTables = [];
  const failedTables = [];

  for (const table of TABLES) {
    try {
      const { rows, missing: isMissing } = await fetchAllRows(sb, table);
      if (isMissing) {
        skippedTables.push(table);
        console.log(`skip (table not present yet): ${table}`);
      } else {
        exported[table] = rows;
        console.log(`exported ${table}: ${rows.length} rows`);
      }
    } catch (e) {
      failedTables.push({ table, error: e.message });
      console.error(`FAILED reading ${table}:`, e.message);
    }
  }

  const isPartial = failedTables.length > 0;
  const stamp = new Date().toISOString().slice(0, 10);
  const outDir = path.join(__dirname, 'out');
  fs.mkdirSync(outDir, { recursive: true });

  // JSON (restorable) — one object, tables in dependency order.
  const jsonPayload = {
    exported_at: new Date().toISOString(),
    partial: isPartial,
    skipped_tables: skippedTables,
    failed_tables: failedTables,
    tables: exported
  };
  const jsonBuffer = Buffer.from(JSON.stringify(jsonPayload));
  const attachments = [];

  if (BACKUP_PASSPHRASE) {
    const encPath = path.join(outDir, `OHT-Restore-${stamp}.json.enc`);
    fs.writeFileSync(encPath, encryptJson(jsonBuffer, BACKUP_PASSPHRASE));
    attachments.push({ filename: path.basename(encPath), path: encPath });
  } else {
    const gzPath = path.join(outDir, `OHT-Restore-${stamp}.json.gz`);
    fs.writeFileSync(gzPath, zlib.gzipSync(jsonBuffer));
    attachments.push({ filename: path.basename(gzPath), path: gzPath });
  }

  // Excel (human-browsable) — built from the SAME exported data, one code path.
  const wb = await buildWorkbook(exported);
  const xlsxPath = path.join(outDir, `OHT-Backup-${stamp}.xlsx`);
  await wb.xlsx.writeFile(xlsxPath);
  attachments.push({ filename: path.basename(xlsxPath), path: xlsxPath });

  // Optional schema-only dump, produced by a separate CI step with
  // continue-on-error — attach it if present, but never fail the backup
  // over it being missing (§23).
  if (BACKUP_SCHEMA_FILE && fs.existsSync(BACKUP_SCHEMA_FILE)) {
    attachments.push({ filename: `OHT-Schema-${stamp}.sql`, path: BACKUP_SCHEMA_FILE });
  }

  const transporter = nodemailer.createTransport({
    service: 'gmail',
    auth: { user: GMAIL_USER, pass: GMAIL_APP_PASSWORD }
  });

  const toList = BACKUP_TO_EMAIL.split(',').map((s) => s.trim()).filter(Boolean);
  const subject = isPartial
    ? `OHT Accounting backup — PARTIAL (${stamp})`
    : `OHT Accounting backup — ${stamp}`;
  const bodyLines = [
    `Backup run: ${new Date().toISOString()}`,
    `Tables exported: ${Object.keys(exported).length}`,
    skippedTables.length ? `Skipped (not present yet): ${skippedTables.join(', ')}` : null,
    isPartial ? `FAILED tables (see attached run log below) — this backup is INCOMPLETE:` : null,
    isPartial ? failedTables.map((f) => `  - ${f.table}: ${f.error}`).join('\n') : null
  ].filter(Boolean);

  await transporter.sendMail({
    from: GMAIL_USER,
    to: toList.join(', '),
    subject,
    text: bodyLines.join('\n'),
    attachments
  });

  console.log(isPartial ? 'Backup email sent (PARTIAL run).' : 'Backup email sent.');

  if (isPartial) {
    // A bad table must never produce a silently-incomplete backup that
    // looks like a clean success (§23) — exit non-zero so CI shows red.
    process.exit(1);
  }
}

main().catch((e) => {
  console.error('Backup job crashed:', e);
  process.exit(1);
});
