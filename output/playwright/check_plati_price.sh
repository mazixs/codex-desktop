#!/usr/bin/env bash
set -euo pipefail

URL="${1:-https://plati.market/itm/autodelivery-claude-pro-max-no-login-to-your-account/5421809}"
MODE="${2:---headless}"

if ! command -v npx >/dev/null 2>&1; then
  echo "npx is required to run this script." >&2
  exit 1
fi

npx -y -p playwright node - "$URL" "$MODE" <<'NODE'
const { chromium } = require('playwright');

async function extractPrice(page) {
  const buyNow = page.getByRole('button', { name: /Купить сейчас за/i }).first();
  if (await buyNow.count()) {
    const text = await buyNow.innerText();
    const match = text.match(/(\d[\d ]*)\s*₽/);
    if (match) {
      return match[1].replace(/\s+/g, '');
    }
  }

  const priceText = page.locator('main').getByText(/^\s*\d[\d ]* ₽\s*$/).first();
  if (await priceText.count()) {
    const text = await priceText.innerText();
    const match = text.match(/(\d[\d ]*)\s*₽/);
    if (match) {
      return match[1].replace(/\s+/g, '');
    }
  }

  throw new Error('Could not extract RUB price from page');
}

async function main() {
  const url = process.argv[2];
  const mode = process.argv[3];
  const headed = mode === '--headed';
  const browser = await chromium.launch({ headless: !headed });
  const page = await browser.newPage({
    locale: 'ru-RU',
    timezoneId: 'Europe/Moscow',
  });

  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 });
    await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});
    await page.getByRole('heading', { level: 1 }).waitFor({ timeout: 15000 });

    const priceRub = await extractPrice(page);
    console.log(`URL: ${url}`);
    console.log(`Price (RUB): ${priceRub}`);
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
NODE
