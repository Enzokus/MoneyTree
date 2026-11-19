import uuid
from datetime import date, datetime, timezone
from sqlalchemy import Boolean, Date, DateTime, ForeignKey, Integer, Numeric, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship
from .db import Base


def uid():
    return str(uuid.uuid4())


def utcnow():
    return datetime.now(timezone.utc)


class User(Base):
    __tablename__ = 'users'
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    yandex_id: Mapped[str] = mapped_column(String(128), unique=True, nullable=False)
    display_name: Mapped[str] = mapped_column(String(255), default='')
    email: Mapped[str | None] = mapped_column(String(255))
    reminder_hour: Mapped[int] = mapped_column(Integer, default=10)
    reminder_minute: Mapped[int] = mapped_column(Integer, default=0)
    reminder_days: Mapped[str] = mapped_column(String(32), default='3,1')
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    subscriptions: Mapped[list['Subscription']] = relationship(back_populates='user', cascade='all, delete-orphan')


class RefreshSession(Base):
    __tablename__ = 'refresh_sessions'
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    user_id: Mapped[str] = mapped_column(ForeignKey('users.id'), nullable=False, index=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked: Mapped[bool] = mapped_column(Boolean, default=False)


class Subscription(Base):
    __tablename__ = 'subscriptions'
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    user_id: Mapped[str] = mapped_column(ForeignKey('users.id'), nullable=False, index=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    plan_name: Mapped[str | None] = mapped_column(String(120))
    category: Mapped[str | None] = mapped_column(String(80))
    amount: Mapped[float] = mapped_column(Numeric(12, 2), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), default='RUB')
    period: Mapped[str] = mapped_column(String(16), nullable=False)
    next_charge_date: Mapped[date] = mapped_column(Date, nullable=False)
    anchor_day: Mapped[int] = mapped_column(Integer, nullable=False)
    timezone: Mapped[str] = mapped_column(String(64), default='Europe/Moscow')
    status: Mapped[str] = mapped_column(String(16), default='active')
    source: Mapped[str] = mapped_column(String(24), default='manual')
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
    user: Mapped[User] = relationship(back_populates='subscriptions')


class CatalogPlan(Base):
    __tablename__ = 'catalog_plans'
    __table_args__ = (UniqueConstraint('service_name', 'plan_name', 'period', 'region'),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    service_name: Mapped[str] = mapped_column(String(120), nullable=False)
    plan_name: Mapped[str] = mapped_column(String(120), nullable=False)
    category: Mapped[str] = mapped_column(String(80), nullable=False)
    amount: Mapped[float] = mapped_column(Numeric(12, 2), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), default='RUB')
    period: Mapped[str] = mapped_column(String(16), nullable=False)
    region: Mapped[str] = mapped_column(String(2), default='RU')
    source_url: Mapped[str] = mapped_column(Text, nullable=False)
    checked_at: Mapped[date] = mapped_column(Date, nullable=False)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
