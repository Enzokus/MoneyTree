import calendar
from datetime import date, timedelta
from decimal import Decimal

MONTHS = {'monthly': 1, 'quarterly': 3, 'yearly': 12}


def advance(d: date, period: str, anchor_day: int | None = None) -> date:
    if period == 'daily':
        return d + timedelta(days=1)
    if period == 'weekly':
        return d + timedelta(days=7)
    months = MONTHS[period]
    year, month = divmod(d.month - 1 + months, 12)
    new_year, new_month = d.year + year, month + 1
    return date(new_year, new_month, min(anchor_day or d.day, calendar.monthrange(new_year, new_month)[1]))


def upcoming(d: date, period: str, today: date, anchor_day: int | None = None) -> date:
    if period == 'daily':
        return max(d, today)
    anchor_day = anchor_day or d.day
    while d < today:
        d = advance(d, period, anchor_day)
    return d


def monthly_equivalent(amount: Decimal, period: str) -> Decimal:
    factor = {'daily': Decimal(365) / 12, 'weekly': Decimal(52) / 12, 'monthly': Decimal(1), 'quarterly': Decimal(1) / 3, 'yearly': Decimal(1) / 12}[period]
    return (amount * factor).quantize(Decimal('0.01'))
