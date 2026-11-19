import os
import re
import tempfile
from datetime import date
from decimal import Decimal
from time import time

os.environ['DATABASE_URL'] = 'sqlite:///' + tempfile.mktemp(suffix='.db')
os.environ['JWT_SECRET'] = 'test-secret-only-for-unit-tests-0123456789'
os.environ['ALLOW_DEV_AUTH'] = 'true'

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from app.billing import advance, monthly_equivalent, upcoming
from app.db import SessionLocal
from app.main import app, token_pair
from app.config import settings
from app.models import CatalogPlan, User
from app.passwords import DEV_EMAIL, DEV_PASSWORD, DEV_PHONE

client = TestClient(app)


def login():
    response = client.post('/auth/login', json={'identifier': DEV_EMAIL, 'password': DEV_PASSWORD})
    assert response.status_code == 200
    return response.json()


def headers(tokens):
    return {'Authorization': 'Bearer ' + tokens['access_token']}


def test_password_login_accepts_phone_and_email_for_the_same_account(monkeypatch):
    expected_user = client.get('/me', headers=headers(login())).json()['id']
    for identifier in (' DEV@MONEYTREE.TEST ', DEV_PHONE, '8 (987) 000-00-01', '9870000001'):
        response = client.post('/auth/login', json={'identifier': identifier, 'password': DEV_PASSWORD})
        assert response.status_code == 200
        assert client.get('/me', headers=headers(response.json())).json()['id'] == expected_user

    bad_password = client.post('/auth/login', json={'identifier': DEV_PHONE, 'password': 'bad password'})
    unknown_user = client.post('/auth/login', json={'identifier': 'unknown@moneytree.test', 'password': DEV_PASSWORD})
    assert bad_password.status_code == unknown_user.status_code == 401
    assert bad_password.json() == unknown_user.json()
    assert client.post('/auth/dev').status_code == 404

    monkeypatch.setattr(settings, 'allow_dev_auth', False)
    assert client.post('/auth/login', json={'identifier': DEV_EMAIL, 'password': DEV_PASSWORD}).status_code == 401


@pytest.mark.parametrize(('identifier', 'canonical', 'transport'), [
    (' NEW@MONEYTREE.TEST ', 'new@moneytree.test', 'email'),
    ('8 (912) 123-45-67', '+79121234567', 'sms'),
])
def test_registration_verifies_contact_and_code_only_once(monkeypatch, identifier, canonical, transport):
    delivered = []
    monkeypatch.setattr(settings, 'smtp_host', 'smtp.example.test')
    monkeypatch.setattr(settings, 'smtp_from', 'noreply@example.test')
    monkeypatch.setattr(settings, 'sms_ru_api_id', 'test-key')
    monkeypatch.setattr(f'app.delivery.send_{transport}', lambda recipient, message: delivered.append((recipient, message)))
    response = client.post('/auth/register/start', json={'identifier': identifier})
    assert response.status_code == 200
    assert set(response.json()) == {'challenge_id'}
    assert len(delivered) == 1 and delivered[0][0] == canonical
    code = re.search(r'\b[0-9]{6}\b', delivered[0][1])[0]
    assert client.post('/auth/register/start', json={'identifier': canonical}).status_code == 429

    password = 'Unique test password!'
    credentials = {'identifier': canonical, 'password': password}
    assert client.post('/auth/login', json=credentials).status_code == 401
    body = {'challenge_id': response.json()['challenge_id'], 'code': code, 'password': password}
    wrong_code = '000000' if code != '000000' else '000001'
    assert client.post('/auth/register/complete', json={**body, 'code': wrong_code}).status_code == 400
    registered = client.post('/auth/register/complete', json=body)
    assert registered.status_code == 201
    profile = client.get('/me', headers=headers(registered.json())).json()
    login_result = client.post('/auth/login', json=credentials)
    assert login_result.status_code == 200
    assert client.get('/me', headers=headers(login_result.json())).json()['id'] == profile['id']
    assert client.post('/auth/register/complete', json=body).status_code == 400
    assert client.post('/auth/register/start', json={'identifier': canonical}).status_code == 409


def test_registration_expiry_resend_and_attempt_limit(monkeypatch):
    now = int(time())
    delivered = []
    monkeypatch.setattr('app.registration.time', lambda: now)
    monkeypatch.setattr('app.registration.ensure_delivery_configured', lambda _: None)
    monkeypatch.setattr('app.registration.send_registration_code', lambda _, code: delivered.append(code))
    contact = {'identifier': 'expiry@moneytree.test'}
    first = client.post('/auth/register/start', json=contact).json()['challenge_id']
    body = {'challenge_id': first, 'code': delivered[0], 'password': 'Password of 12+ characters'}
    wrong_code = '000000' if delivered[0] != '000000' else '000001'
    for _ in range(5):
        assert client.post('/auth/register/complete', json={**body, 'code': wrong_code}).status_code == 400
    assert client.post('/auth/register/complete', json=body).json()['detail'] == 'Code expired or used'
    now += 60
    second = client.post('/auth/register/start', json=contact).json()['challenge_id']
    assert first != second
    assert client.post('/auth/register/complete', json=body).status_code == 400
    body.update(challenge_id=second, code=delivered[1])
    now += 600
    assert client.post('/auth/register/complete', json=body).status_code == 400


def test_device_timezone_and_russian_subscription():
    auth = headers(login())
    payload = {'name': 'Яндекс Плюс ё', 'amount': '299.90', 'period': 'monthly',
               'next_charge_date': '2099-11-01', 'timezone': 'Asia/Yekaterinburg'}
    created = client.post('/subscriptions', json=payload, headers=auth)
    assert created.status_code == 201
    rows = client.get('/subscriptions', params={'timezone': 'Pacific/Auckland'}, headers=auth)
    assert rows.status_code == 200
    assert any(row['name'] == 'Яндекс Плюс ё' for row in rows.json())
    assert client.get('/subscriptions', params={'timezone': 'wrong'}, headers=auth).status_code == 422
    payload['amount'] = 'слово'
    assert client.post('/subscriptions', json=payload, headers=auth).status_code == 422
    assert client.delete('/subscriptions/' + created.json()['id'], headers=auth).status_code == 200


def test_billing_dates_preserve_month_end_anchor():
    assert upcoming(date(2024, 1, 31), 'monthly', date(2024, 3, 1)) == date(2024, 3, 31)
    assert advance(date(2024, 2, 29), 'yearly') == date(2025, 2, 28)
    assert monthly_equivalent(Decimal('1200'), 'yearly') == Decimal('100.00')


def test_crud_sorting_refresh_and_revocation():
    tokens = login()
    payload = {'name': 'Поздняя', 'amount': '300', 'currency': 'RUB', 'period': 'monthly', 'next_charge_date': '2099-12-01', 'timezone': 'Asia/Yekaterinburg'}
    late = client.post('/subscriptions', json=payload, headers=headers(tokens))
    assert late.status_code == 201
    payload['name'] = 'Ранняя'
    payload['next_charge_date'] = '2099-11-01'
    early = client.post('/subscriptions', json=payload, headers=headers(tokens))
    assert early.status_code == 201
    rows = client.get('/subscriptions', headers=headers(tokens)).json()
    assert [x['name'] for x in rows[:2]] == ['Ранняя', 'Поздняя']
    refreshed = client.post('/auth/refresh', json={'refresh_token': tokens['refresh_token']})
    assert refreshed.status_code == 200
    assert client.get('/subscriptions', headers=headers(tokens)).status_code == 401
    new_tokens = refreshed.json()
    assert client.post('/auth/logout', json={'refresh_token': new_tokens['refresh_token']}, headers=headers(new_tokens)).status_code == 200
    assert client.get('/subscriptions', headers=headers(new_tokens)).status_code == 401


def test_user_isolation_and_catalog_recommendation():
    owner = login()
    payload = {'name': 'Музыка А', 'category': 'music', 'amount': '300', 'currency': 'RUB', 'period': 'monthly', 'next_charge_date': '2099-11-01', 'timezone': 'Asia/Yekaterinburg'}
    row = client.post('/subscriptions', json=payload, headers=headers(owner)).json()
    with SessionLocal() as db:
        db.add(CatalogPlan(service_name='Музыка Б', plan_name='Стандарт', category='music', amount=Decimal('150'), currency='RUB', period='monthly', region='RU', source_url='https://example.org/price', checked_at=date.today()))
        other = User(yandex_id='other-test-user')
        db.add(other)
        db.flush()
        other_tokens = token_pair(db, other)
        db.commit()
    assert client.get('/subscriptions', headers=headers(other_tokens)).json() == []
    assert client.delete('/subscriptions/' + row['id'], headers=headers(other_tokens)).status_code == 404
    recs = client.get('/recommendations', headers=headers(owner)).json()
    assert any(r['alternative']['service_name'] == 'Музыка Б' and r['monthly_saving_rub'] == '150.00' for r in recs)
    response = client.post('/assistant/ask', json={'question': 'Как сэкономить?'}, headers=headers(owner))
    assert response.status_code == 200
    assert response.json()['mode'] == 'deterministic'


def test_yandex_exchange_checks_redirect_and_identity(monkeypatch):
    monkeypatch.setattr(settings, 'yandex_client_id', 'client-for-test')
    monkeypatch.setattr(settings, 'yandex_redirect_uri', 'subscriptiontree://oauth')

    class FakeResponse:
        def __init__(self, payload): self.payload = payload
        def raise_for_status(self): pass
        def json(self): return self.payload

    class FakeClient:
        def __init__(self, **_): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *_): pass
        async def post(self, *_args, **_kwargs): return FakeResponse({'access_token': 'test-yandex-token'})
        async def get(self, *_args, **_kwargs): return FakeResponse({'id': 'yandex-user-1', 'client_id': 'client-for-test', 'login': 'ivan'})

    monkeypatch.setattr('app.main.httpx.AsyncClient', FakeClient)
    body = {'code': 'code', 'code_verifier': 'verifier', 'redirect_uri': 'wrong://oauth'}
    assert client.post('/auth/yandex/exchange', json=body).status_code == 400
    body['redirect_uri'] = 'subscriptiontree://oauth'
    response = client.post('/auth/yandex/exchange', json=body)
    assert response.status_code == 200
    assert client.get('/me', headers=headers(response.json())).json()['display_name'] == 'ivan'


def test_offline_create_retries_do_not_duplicate_subscriptions():
    from uuid import uuid4
    auth = headers(login())
    identifier = str(uuid4())
    payload = {'id': identifier, 'name': 'Offline retry', 'amount': '99',
               'period': 'monthly', 'next_charge_date': '2099-12-01'}
    first = client.post('/subscriptions', json=payload, headers=auth)
    second = client.post('/subscriptions', json=payload, headers=auth)
    assert first.status_code == second.status_code == 201
    assert first.json()['id'] == second.json()['id'] == identifier
    rows = client.get('/subscriptions', headers=auth).json()
    assert sum(row['id'] == identifier for row in rows) == 1
    client.delete('/subscriptions/' + identifier, headers=auth)
