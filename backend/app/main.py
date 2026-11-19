import hashlib
import re
import secrets
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from typing import Annotated
from zoneinfo import ZoneInfo

import httpx
import jwt
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from .billing import monthly_equivalent, upcoming
from .config import settings
from .db import Base, engine, get_db
from .models import CatalogPlan, RefreshSession, Subscription, User
from .schemas import AskInput, ReminderSettings, SubscriptionCreate, SubscriptionInput, SubscriptionOut

Base.metadata.create_all(engine)
if len(settings.jwt_secret) < 32 or settings.jwt_secret.startswith('replace_with_'):
    raise RuntimeError('JWT_SECRET must contain at least 32 characters')
app = FastAPI(title='Subscription Tree API', version='0.1.0')
Db = Annotated[Session, Depends(get_db)]


class ExchangeInput(BaseModel):
    code: str
    code_verifier: str
    redirect_uri: str


class RefreshInput(BaseModel):
    refresh_token: str


def token_pair(db: Session, user: User) -> dict:
    now = datetime.now(timezone.utc)
    raw = secrets.token_urlsafe(48)
    session = RefreshSession(user_id=user.id, token_hash=hashlib.sha256(raw.encode()).hexdigest(), expires_at=now + timedelta(days=30))
    db.add(session)
    db.flush()
    access = jwt.encode({'sub': user.id, 'sid': session.id, 'exp': now + timedelta(minutes=15), 'iat': now}, settings.jwt_secret, algorithm='HS256')
    db.commit()
    return {'access_token': access, 'refresh_token': raw, 'token_type': 'bearer'}


def current_user(db: Db, authorization: Annotated[str | None, Header()] = None) -> User:
    if not authorization or not authorization.startswith('Bearer '):
        raise HTTPException(401, 'Authentication required')
    try:
        payload = jwt.decode(authorization[7:], settings.jwt_secret, algorithms=['HS256'])
    except jwt.PyJWTError:
        raise HTTPException(401, 'Invalid access token')
    user = db.get(User, payload.get('sub'))
    session = db.get(RefreshSession, payload.get('sid'))
    if not user or not session or session.user_id != user.id or session.revoked:
        raise HTTPException(401, 'Unknown user')
    return user


CurrentUser = Annotated[User, Depends(current_user)]


@app.post('/auth/yandex/exchange')
async def yandex_exchange(body: ExchangeInput, db: Db):
    if not settings.yandex_client_id or not settings.yandex_redirect_uri:
        raise HTTPException(503, 'Yandex OAuth is not configured')
    if body.redirect_uri != settings.yandex_redirect_uri:
        raise HTTPException(400, 'Unexpected redirect URI')
    data = {'grant_type': 'authorization_code', 'code': body.code, 'client_id': settings.yandex_client_id,
            'code_verifier': body.code_verifier, 'redirect_uri': body.redirect_uri}
    if settings.yandex_client_secret:
        data['client_secret'] = settings.yandex_client_secret
    async with httpx.AsyncClient(timeout=10) as client:
        try:
            token_response = await client.post('https://oauth.yandex.ru/token', data=data)
            token_response.raise_for_status()
            yandex_token = token_response.json()['access_token']
            info_response = await client.get('https://login.yandex.ru/info', headers={'Authorization': f'OAuth {yandex_token}'})
            info_response.raise_for_status()
            info = info_response.json()
        except (httpx.HTTPError, KeyError, ValueError):
            raise HTTPException(401, 'Yandex authorization failed')
    if info.get('client_id') != settings.yandex_client_id or not info.get('id'):
        raise HTTPException(401, 'Yandex identity mismatch')
    user = db.scalar(select(User).where(User.yandex_id == str(info['id'])))
    if not user:
        user = User(yandex_id=str(info['id']))
        db.add(user)
    user.display_name = info.get('display_name') or info.get('real_name') or info.get('login') or ''
    user.email = info.get('default_email')
    db.flush()
    return token_pair(db, user)


@app.post('/auth/dev')
def dev_auth(request: Request, db: Db):
    if not settings.allow_dev_auth or request.client.host not in ('127.0.0.1', '::1', 'testclient'):
        raise HTTPException(404)
    user = db.scalar(select(User).where(User.yandex_id == 'dev-local'))
    if not user:
        user = User(yandex_id='dev-local', display_name='Тестовый пользователь')
        db.add(user)
        db.flush()
    return token_pair(db, user)


@app.post('/auth/refresh')
def refresh(body: RefreshInput, db: Db):
    record = db.scalar(select(RefreshSession).where(RefreshSession.token_hash == hashlib.sha256(body.refresh_token.encode()).hexdigest()))
    if not record or record.revoked or record.expires_at.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise HTTPException(401, 'Invalid refresh token')
    record.revoked = True
    user = db.get(User, record.user_id)
    return token_pair(db, user)


@app.post('/auth/logout')
def logout(body: RefreshInput, user: CurrentUser, db: Db):
    record = db.scalar(select(RefreshSession).where(RefreshSession.token_hash == hashlib.sha256(body.refresh_token.encode()).hexdigest(), RefreshSession.user_id == user.id))
    if record:
        record.revoked = True
        db.commit()
    return {'ok': True}


@app.post('/auth/logout-all')
def logout_all(user: CurrentUser, db: Db):
    for session in db.scalars(select(RefreshSession).where(RefreshSession.user_id == user.id, RefreshSession.revoked.is_(False))):
        session.revoked = True
    db.commit()
    return {'ok': True}


@app.get('/me')
def me(user: CurrentUser):
    return {'id': user.id, 'display_name': user.display_name, 'email': user.email,
            'reminders': {'hour': user.reminder_hour, 'minute': user.reminder_minute,
                          'days_before': [int(x) for x in user.reminder_days.split(',') if x]}}


@app.put('/me/reminders')
def reminders(body: ReminderSettings, user: CurrentUser, db: Db):
    if any(day < 0 or day > 30 for day in body.days_before):
        raise HTTPException(422, 'Reminder days must be 0-30')
    user.reminder_hour = body.hour
    user.reminder_minute = body.minute
    user.reminder_days = ','.join(map(str, sorted(set(body.days_before), reverse=True)))
    db.commit()
    return {'ok': True}


def subscription_payload(s: Subscription, device_timezone: str | None = None):
    payload = SubscriptionOut.model_validate(s).model_dump(mode='json')
    try:
        local_today = datetime.now(ZoneInfo(device_timezone or s.timezone)).date()
    except Exception:
        local_today = date.today()
    payload['next_charge_date'] = upcoming(s.next_charge_date, s.period, local_today, s.anchor_day).isoformat() if s.status == 'active' else s.next_charge_date.isoformat()
    return payload


@app.get('/subscriptions')
def list_subscriptions(user: CurrentUser, db: Db, timezone: str | None = None):
    if timezone is not None:
        try:
            ZoneInfo(timezone)
        except (KeyError, ValueError):
            raise HTTPException(422, 'Unknown timezone')
    rows = db.scalars(select(Subscription).where(Subscription.user_id == user.id)).all()
    return sorted((subscription_payload(s, timezone) for s in rows), key=lambda s: (s['status'] != 'active', s['next_charge_date'], s['name'].lower()))


@app.post('/subscriptions', status_code=201)
def create_subscription(body: SubscriptionCreate, user: CurrentUser, db: Db):
    data = body.model_dump(exclude={'id'})
    if body.id is not None:
        existing = db.get(Subscription, str(body.id))
        if existing:
            if existing.user_id != user.id:
                raise HTTPException(409, 'Subscription ID already exists')
            return subscription_payload(existing)
        data['id'] = str(body.id)
    data['anchor_day'] = body.anchor_day or body.next_charge_date.day
    s = Subscription(user_id=user.id, **data)
    db.add(s)
    db.commit()
    db.refresh(s)
    return subscription_payload(s)


def owned_subscription(db: Session, user: User, subscription_id: str) -> Subscription:
    s = db.get(Subscription, subscription_id)
    if not s or s.user_id != user.id:
        raise HTTPException(404, 'Subscription not found')
    return s


@app.put('/subscriptions/{subscription_id}')
def update_subscription(subscription_id: str, body: SubscriptionInput, user: CurrentUser, db: Db):
    s = owned_subscription(db, user, subscription_id)
    data = body.model_dump()
    data['anchor_day'] = body.anchor_day or body.next_charge_date.day
    for key, value in data.items():
        setattr(s, key, value)
    db.commit()
    return subscription_payload(s)


@app.delete('/subscriptions/{subscription_id}')
def delete_subscription(subscription_id: str, user: CurrentUser, db: Db):
    db.delete(owned_subscription(db, user, subscription_id))
    db.commit()
    return {'ok': True}


def plan_payload(plan: CatalogPlan):
    return {'id': plan.id, 'service_name': plan.service_name, 'plan_name': plan.plan_name,
            'category': plan.category, 'amount': str(plan.amount), 'currency': plan.currency,
            'period': plan.period, 'region': plan.region, 'source_url': plan.source_url,
            'checked_at': plan.checked_at.isoformat(),
            'price_is_current': (date.today() - plan.checked_at).days <= 30}


@app.get('/catalog')
def catalog(user: CurrentUser, db: Db):
    rows = db.scalars(select(CatalogPlan).where(CatalogPlan.active.is_(True), CatalogPlan.region == 'RU')).all()
    return [plan_payload(p) for p in rows]


def recommendation_rows(user: User, db: Session):
    subscriptions = db.scalars(select(Subscription).where(Subscription.user_id == user.id, Subscription.status == 'active')).all()
    plans = db.scalars(select(CatalogPlan).where(CatalogPlan.active.is_(True), CatalogPlan.region == 'RU')).all()
    result = []
    for sub in subscriptions:
        if not sub.category or sub.currency != 'RUB':
            continue
        current_monthly = monthly_equivalent(Decimal(sub.amount), sub.period)
        for plan in plans:
            if plan.category != sub.category or plan.currency != 'RUB' or plan.service_name.casefold() == sub.name.casefold():
                continue
            if (date.today() - plan.checked_at).days > 30:
                continue
            candidate_monthly = monthly_equivalent(Decimal(plan.amount), plan.period)
            if candidate_monthly >= current_monthly:
                continue
            data = plan_payload(plan)
            data['period_options'] = [plan_payload(option) for option in plans
                                      if option.service_name == plan.service_name and option.category == plan.category
                                      and option.currency == 'RUB' and (date.today() - option.checked_at).days <= 30]
            result.append({'current_subscription_id': sub.id, 'current_service': sub.name,
                           'alternative': data, 'monthly_saving_rub': str(current_monthly - candidate_monthly),
                           'price_is_current': data['price_is_current']})
    return sorted(result, key=lambda x: Decimal(x['monthly_saving_rub']), reverse=True)


@app.get('/recommendations')
def recommendations(user: CurrentUser, db: Db):
    return recommendation_rows(user, db)


@app.post('/assistant/ask')
async def ask(body: AskInput, user: CurrentUser, db: Db):
    subscriptions = db.scalars(select(Subscription).where(Subscription.user_id == user.id, Subscription.status == 'active')).all()
    total = sum((monthly_equivalent(Decimal(s.amount), s.period) for s in subscriptions if s.currency == 'RUB'), Decimal(0))
    recommendations = recommendation_rows(user, db)[:3]
    facts = {'monthly_total_rub': str(total), 'subscription_count': len(subscriptions), 'recommendations': recommendations}
    fallback = f'У вас {len(subscriptions)} активных подписок. Примерные расходы: {total} ₽ в месяц.'
    if recommendations:
        top = recommendations[0]
        fallback += f" Возможная альтернатива для {top['current_service']}: {top['alternative']['service_name']} — экономия около {top['monthly_saving_rub']} ₽ в месяц."
        if not top['price_is_current']:
            fallback += ' Цена требует повторной проверки.'
    else:
        fallback += ' Проверенных более дешёвых альтернатив в каталоге пока нет.'
    if settings.ollama_url and settings.ollama_model:
        try:
            async with httpx.AsyncClient(timeout=20) as client:
                response = await client.post(settings.ollama_url.rstrip('/') + '/api/generate', json={
                    'model': settings.ollama_model, 'stream': False,
                    'prompt': f'Отвечай по-русски кратко. Используй только факты ниже, не придумывай цены и сервисы. Если данных недостаточно, скажи об этом. Вопрос: {body.question}\nФакты: {facts}'})
                response.raise_for_status()
                answer = response.json().get('response', '').strip()
                permitted_numbers = set(re.findall(r'\d+(?:[.,]\d+)?', str(facts)))
                answer_numbers = set(re.findall(r'\d+(?:[.,]\d+)?', answer))
                if answer and answer_numbers.issubset(permitted_numbers):
                    return {'answer': answer, 'facts': facts, 'mode': 'local_model'}
        except (httpx.HTTPError, ValueError):
            pass
    return {'answer': fallback, 'facts': facts, 'mode': 'deterministic'}


@app.get('/integrations')
def integrations(user: CurrentUser):
    return {'available': [], 'message': 'Подключения появятся после подтверждения официального API сервиса. Пока используйте ручное добавление.'}


@app.get('/health')
def health():
    return {'ok': True}
