"""Import manually verified official RU prices from a JSON array."""
import json
import sys
from datetime import date
from decimal import Decimal
from pathlib import Path
from urllib.parse import urlparse
from sqlalchemy import select
from .db import Base, SessionLocal, engine
from .models import CatalogPlan


def import_file(path: Path) -> int:
    rows = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(rows, list):
        raise ValueError('Catalog file must contain a JSON array')
    Base.metadata.create_all(engine)
    with SessionLocal() as db:
        for row in rows:
            required = ['service_name', 'plan_name', 'category', 'amount', 'currency', 'period', 'source_url', 'checked_at']
            if any(not row.get(key) for key in required):
                raise ValueError(f'Missing required field in {row}')
            parsed = urlparse(row['source_url'])
            if parsed.scheme != 'https' or not parsed.netloc:
                raise ValueError('source_url must be HTTPS')
            price = Decimal(str(row['amount']))
            if price < 0 or row['currency'] != 'RUB' or row['period'] not in ('weekly', 'monthly', 'quarterly', 'yearly'):
                raise ValueError('Invalid price, currency or period')
            checked = date.fromisoformat(row['checked_at'])
            if checked > date.today():
                raise ValueError('checked_at cannot be in the future')
            existing = db.scalar(select(CatalogPlan).where(
                CatalogPlan.service_name == row['service_name'], CatalogPlan.plan_name == row['plan_name'],
                CatalogPlan.period == row['period'], CatalogPlan.region == 'RU'))
            plan = existing or CatalogPlan(service_name=row['service_name'], plan_name=row['plan_name'], period=row['period'], region='RU')
            plan.category = row['category'].lower()
            plan.amount = price
            plan.currency = 'RUB'
            plan.source_url = row['source_url']
            plan.checked_at = checked
            plan.active = bool(row.get('active', True))
            if not existing:
                db.add(plan)
        db.commit()
    return len(rows)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python -m app.import_catalog catalog.json')
    print(f'Imported {import_file(Path(sys.argv[1]))} plans')
