import os
import tempfile
from datetime import date
from decimal import Decimal

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
from app.models import CatalogPlan, PasswordLogin, RefreshSession, Subscription, SubscriptionDetails, User
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


@pytest.mark.parametrize(('identifier', 'canonical'), [
    (' NEW@MONEYTREE.TEST ', 'new@moneytree.test'),
    ('8 (912) 123-45-67', '+79121234567'),
])
def test_registration_creates_account_without_a_code(identifier, canonical):
    password = 'Unique test password!'
    registered = client.post('/auth/register', json={'identifier': identifier, 'password': password})
    assert registered.status_code == 201
    profile = client.get('/me', headers=headers(registered.json())).json()
    credentials = {'identifier': canonical, 'password': password}
    signed_in = client.post('/auth/login', json=credentials)
    assert signed_in.status_code == 200
    assert client.get('/me', headers=headers(signed_in.json())).json()['id'] == profile['id']
    assert client.post('/auth/register', json=credentials).status_code == 409
    with SessionLocal() as db:
        assert db.get(PasswordLogin, profile['id']).password_hash != password


def test_registration_rejects_invalid_contact_and_short_password():
    assert client.post('/auth/register', json={'identifier': 'abc@', 'password': 'Valid password'}).status_code == 422
    assert client.post('/auth/register', json={'identifier': '123', 'password': 'Valid password'}).status_code == 422
    assert client.post('/auth/register', json={'identifier': 'valid@moneytree.test', 'password': 'short'}).status_code == 422


def test_logout_preserves_data_and_account_deletion_removes_it():
    credentials = {'identifier': 'delete@moneytree.test', 'password': 'Unique test password!'}
    tokens = client.post('/auth/register', json=credentials).json()
    first_session = headers(tokens)
    owner_id = client.get('/me', headers=first_session).json()['id']
    payload = {
        'name': 'Account deletion test', 'amount': '100', 'period': 'monthly',
        'next_charge_date': '2099-12-01', 'bank_name': 'Test Bank',
    }
    created = client.post('/subscriptions', json=payload, headers=first_session)
    assert created.status_code == 201
    subscription_id = created.json()['id']
    assert client.post('/auth/logout', json={'refresh_token': tokens['refresh_token']},
                       headers=first_session).status_code == 200

    second_tokens = client.post('/auth/login', json=credentials).json()
    other_tokens = client.post('/auth/login', json=credentials).json()
    second_session = headers(second_tokens)
    assert client.get('/subscriptions', headers=second_session).json()[0]['id'] == subscription_id
    assert client.delete('/me').status_code == 401
    assert client.delete('/me', headers=second_session).status_code == 200

    with SessionLocal() as db:
        assert db.get(User, owner_id) is None
        assert db.get(PasswordLogin, owner_id) is None
        assert db.get(Subscription, subscription_id) is None
        assert db.get(SubscriptionDetails, subscription_id) is None
        assert db.scalar(select(RefreshSession).where(RefreshSession.user_id == owner_id)) is None
    assert client.get('/me', headers=headers(other_tokens)).status_code == 401
    assert client.post('/auth/refresh', json={'refresh_token': other_tokens['refresh_token']}).status_code == 401
    assert client.post('/auth/login', json=credentials).status_code == 401

    registered_again = client.post('/auth/register', json=credentials)
    assert registered_again.status_code == 201
    assert client.get('/subscriptions', headers=headers(registered_again.json())).json() == []
    assert client.get('/me', headers=headers(login())).status_code == 200


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


def test_subscription_intake_keeps_selected_metadata_and_reuses_duplicates():
    auth = headers(login())
    services = client.get('/me', headers=auth).json()['services']
    assert any(s['name'] == 'Яндекс Плюс' and s['icon'] == 'music' for s in services)
    payload = {'name': 'Yandex Plus', 'plan_name': 'intake test', 'amount': '99',
               'period': 'daily', 'next_charge_date': '2099-03-29', 'source': 'statement',
               'bank_name': 'ВТБ', 'bank_merchant': 'YANDEX*PLUS', 'last_payment_date': '2099-03-28'}
    first = client.post('/subscriptions', json=payload, headers=auth)
    assert first.status_code == 201
    row = first.json()
    try:
        assert row['source'] == 'statement'
        assert row['bank_name'] == 'ВТБ'
        assert row['bank_merchant'] == 'YANDEX*PLUS'
        assert row['last_payment_date'] == '2099-03-28'
        assert row['period'] == 'daily'
        duplicate = client.post('/subscriptions', headers=auth,
                                json={**payload, 'name': 'Яндекс Плюс', 'source': 'manual'})
        assert duplicate.json()['id'] == row['id']
        edit = {k: v for k, v in payload.items() if k not in ('bank_name', 'last_payment_date', 'bank_merchant')}
        edited = client.put('/subscriptions/' + row['id'], headers=auth,
                            json={**edit, 'name': 'Моя подписка'})
        assert edited.json()['last_payment_date'] == '2099-03-28'
        assert edited.json()['source'] == 'statement'
        assert edited.json()['bank_merchant'] == 'YANDEX*PLUS'
    finally:
        client.delete('/subscriptions/' + row['id'], headers=auth)


def test_bank_merchant_migration_preserves_existing_details():
    from sqlalchemy import create_engine
    from app.db import upgrade_subscription_details

    database = create_engine('sqlite://')
    with database.begin() as conn:
        conn.exec_driver_sql('CREATE TABLE subscription_details (subscription_id VARCHAR PRIMARY KEY, bank_name VARCHAR)')
        conn.exec_driver_sql("INSERT INTO subscription_details VALUES ('old', 'ВТБ')")
    upgrade_subscription_details(database)
    upgrade_subscription_details(database)
    with database.connect() as conn:
        assert conn.exec_driver_sql('SELECT bank_name, bank_merchant FROM subscription_details').one() == ('ВТБ', None)
