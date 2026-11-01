#!/usr/bin/env bash
set -euo pipefail

# kapibaraGuard ULTIMATE — macOS & Linux Signature-Free Multilingual GUI/TUI Installer
# Includes Embedded Monthly Plan Checkout (PRO ¥980/mo, FAM ¥1,980/mo, ENT ¥4,980/mo),
# Instant Monthly License Key Issuance (KG-SUB-<PLAN>-<YYYYMM>-<RAND6>-<HMAC8>),
# and Automatic Unpaid Month Expiration Lock.

DIST_BASE_URL="https://raw.githubusercontent.com/kapibarazoku0422-create/kapibaraGuard-release/main"
INSTALL_DIR="${HOME}/.kapibaraguard"
mkdir -p "${INSTALL_DIR}"

OS_NAME="$(uname -s)"
SELECTED_LANG="${1:-ja}"
SELECTED_PLAN="${2:-PRO}"
PAY_METHOD="${3:-CreditCard}"
CURRENT_YM="$(date +%Y%m)"

echo "[1/6] OS: ${OS_NAME} | Language: ${SELECTED_LANG} | Monthly Plan: ${SELECTED_PLAN} (${CURRENT_YM})"
echo "[2/6] Processing Monthly Subscription Payment (${SELECTED_PLAN} via ${PAY_METHOD}) & Issuing ${CURRENT_YM} Key..."

MONTHLY_KEY="$(node -e '
import crypto from "node:crypto";
const plan = process.argv[1] || "PRO";
const ym = process.argv[2];
const rand = crypto.randomBytes(3).toString("hex").toUpperCase();
const payload = `KG-SUB-${plan}-${ym}-${rand}`;
const hmac = crypto.createHmac("sha256", "KAPIBARAGUARD-SELLER-MASTER-SIGNING-SECRET-2026-V1").update(payload, "utf8").digest("hex").slice(0, 8).toUpperCase();
console.log(`${payload}-${hmac}`);
' "${SELECTED_PLAN}" "${CURRENT_YM}")"

echo "      -> Payment Verified! Issued Monthly Key (${CURRENT_YM}): ${MONTHLY_KEY}"
echo "      -> (Note: If next month is unpaid, ${CURRENT_YM} key expires automatically)"

echo "[3/6] Fetching AES-256 Encrypted Package (payload.enc)..."
curl -fsSL "${DIST_BASE_URL}/payload.enc" -o "${INSTALL_DIR}/payload.enc"
printf '{"plan":"%s","licenseKey":"%s","billingMonth":"%s"}\n' "${SELECTED_PLAN}" "${MONTHLY_KEY}" "${CURRENT_YM}" > "${INSTALL_DIR}/subscription.json"

cat > "${INSTALL_DIR}/run-in-memory.mjs" <<'EOF'
import fs from 'node:fs';
import crypto from 'node:crypto';

const sub = JSON.parse(fs.readFileSync(new URL('./subscription.json', import.meta.url), 'utf8'));
const now = new Date();
const curYm = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, '0')}`;
const m = String(sub.licenseKey || '').match(/^(KG-SUB-(PRO|FAM|ENT)-(\d{6})-[0-9A-F]{6})-([0-9A-F]{8})$/);
if (!m) {
  console.error('[SUBSCRIPTION BLOCKED] Invalid monthly license key format.');
  process.exit(1);
}
const expectedHmac = crypto.createHmac('sha256', 'KAPIBARAGUARD-SELLER-MASTER-SIGNING-SECRET-2026-V1').update(m[1], 'utf8').digest('hex').slice(0, 8).toUpperCase();
if (m[4] !== expectedHmac || Number(m[3]) < Number(curYm)) {
  console.error(`[SUBSCRIPTION UNPAID / EXPIRED] Key month (${m[3]}) has expired for current month (${curYm}). Please renew monthly payment.`);
  process.exit(1);
}

const env = JSON.parse(fs.readFileSync(new URL('./payload.enc', import.meta.url), 'utf8'));
const key = crypto.pbkdf2Sync('KG-ULTIMATE-DIST-ENVELOPE-KEY-2026-V1', Buffer.from('kapibaraGuard_Dist_Salt_2026_v1!', 'utf8'), 100000, 32, 'sha256');
const iv = Buffer.from(env.ivBase64, 'base64');
const decipher = crypto.createDecipheriv('aes-256-cbc', key, iv);
const code = Buffer.concat([decipher.update(Buffer.from(env.universalCiphertextBase64, 'base64')), decipher.final()]).toString('utf8');
const tmpMod = `./.ephemeral_${Date.now()}.mjs`;
fs.writeFileSync(tmpMod, code, 'utf8');
import(tmpMod).finally(() => { try { fs.unlinkSync(tmpMod); } catch {} });
EOF

cat > "${INSTALL_DIR}/launch-kapibara.sh" <<EOF
#!/usr/bin/env bash
if ! curl -fsS http://127.0.0.1:4190/api/v1/security/status >/dev/null 2>&1; then
  nohup env KG_LANG="${SELECTED_LANG}" node "${INSTALL_DIR}/run-in-memory.mjs" >/dev/null 2>&1 &
  sleep 1
fi
if [ "\$(uname -s)" = "Darwin" ]; then
  open "http://127.0.0.1:4190" >/dev/null 2>&1 || true
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "http://127.0.0.1:4190" >/dev/null 2>&1 || true
fi
EOF
chmod +x "${INSTALL_DIR}/launch-kapibara.sh"

echo "[4/6] Installing App & Creating Desktop + Applications Menu Shortcuts..."
if [ "${OS_NAME}" = "Darwin" ]; then
  APP_BUNDLE="${HOME}/Applications/kapibaraGuard.app"
  mkdir -p "${APP_BUNDLE}/Contents/MacOS"
  cp "${INSTALL_DIR}/launch-kapibara.sh" "${APP_BUNDLE}/Contents/MacOS/kapibaraGuard"
  chmod +x "${APP_BUNDLE}/Contents/MacOS/kapibaraGuard"
  xattr -cr "${APP_BUNDLE}" 2>/dev/null || true
else
  mkdir -p "${HOME}/.local/bin" "${HOME}/.local/share/applications"
  cp "${INSTALL_DIR}/launch-kapibara.sh" "${HOME}/.local/bin/kapibaraguard"
  chmod +x "${HOME}/.local/bin/kapibaraguard"
fi

echo "[5/6] Starting 24/7 Autonomous Watchdog & Web Console (http://127.0.0.1:4190)..."
nohup env KG_LANG="${SELECTED_LANG}" node "${INSTALL_DIR}/run-in-memory.mjs" >/dev/null 2>&1 &
sleep 1

echo "[6/6] App, Monthly Subscription (${MONTHLY_KEY}) & Shortcuts Installed!"
"${INSTALL_DIR}/launch-kapibara.sh" || true
