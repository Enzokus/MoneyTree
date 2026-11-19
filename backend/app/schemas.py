from uuid import UUID
from datetime import date
from decimal import Decimal
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field


Period = Literal['weekly', 'monthly', 'quarterly', 'yearly']
Status = Literal['active', 'paused', 'cancelled']


class SubscriptionInput(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    plan_name: str | None = Field(default=None, max_length=120)
    category: str | None = Field(default=None, max_length=80)
    amount: Decimal = Field(ge=0, max_digits=12, decimal_places=2)
    currency: str = Field(default='RUB', pattern=r'^[A-Z]{3}$')
    period: Period
    next_charge_date: date
    anchor_day: int | None = Field(default=None, ge=1, le=31)
    timezone: str = 'Europe/Moscow'
    status: Status = 'active'


class SubscriptionCreate(SubscriptionInput):
    id: UUID | None = None


class SubscriptionOut(SubscriptionInput):
    model_config = ConfigDict(from_attributes=True)
    id: str
    source: str


class CatalogOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    service_name: str
    plan_name: str
    category: str
    amount: Decimal
    currency: str
    period: Period
    region: str
    source_url: str
    checked_at: date
    price_is_current: bool


class ReminderSettings(BaseModel):
    hour: int = Field(ge=0, le=23)
    minute: int = Field(ge=0, le=59)
    days_before: list[int] = Field(min_length=1, max_length=3)


class AskInput(BaseModel):
    question: str = Field(min_length=1, max_length=500)
