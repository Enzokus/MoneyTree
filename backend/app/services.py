import json
import re

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from .db import SessionLocal
from .models import Service


# Payment descriptors belong here only when they identify a specific service.
SERVICES = (
    ('yandex-plus', 'Яндекс Плюс', 'музыка', 'music',
     ('yandex plus', 'yandex*plus', 'yandexplus', 'яндекс музыка', 'yandex music')),
    ('sberprime', 'СберПрайм', 'другое', 'prime', ('sberprime', 'сбер прайм', 'sber prime')),
    ('vk-music', 'VK Музыка', 'музыка', 'music', ('vk music', 'vkmusic', 'вк музыка')),
    ('kinopoisk', 'Кинопоиск', 'видео', 'movie', ('kinopoisk',)),
    ('okko', 'Okko', 'видео', 'movie', ('окко',)),
    ('ivi', 'Иви', 'видео', 'movie', ('ivi', 'ivi.ru')),
    ('kion', 'KION', 'видео', 'movie', ('кион',)),
    ('wink', 'Wink', 'видео', 'movie', ('винк',)),
    ('start', 'START', 'видео', 'movie', ('start.ru',)),
    ('premier', 'PREMIER', 'видео', 'movie', ('premier.one', 'премьер')),
    ('litres', 'Литрес', 'книги', 'book', ('litres', 'litres.ru')),
    ('telegram-premium', 'Telegram Premium', 'другое', 'telegram',
     ('телеграм премиум', 'premiumbot', 'telegram premium bot')),
    ('mts-premium', 'МТС Premium', 'другое', 'prime', ('mts premium', 'мтс премиум')),
)


def seed_services():
    with SessionLocal() as db:
        existing = set(db.scalars(select(Service.id)))
        for key, name, category, icon, aliases in SERVICES:
            if key in existing:
                continue
            try:
                with db.begin_nested():
                    db.add(Service(id=key, name=name, category=category, icon=icon,
                                   aliases=json.dumps(aliases, ensure_ascii=False)))
            except IntegrityError:
                if not db.get(Service, key):
                    raise
        db.commit()


def service_payload(service: Service):
    return {'id': service.id, 'name': service.name, 'category': service.category,
            'icon': service.icon, 'aliases': json.loads(service.aliases)}


def normalized_name(value: str | None) -> str:
    return ' '.join(re.findall(r'[a-zа-я0-9]+', (value or '').casefold().replace('ё', 'е')))


def same_subscription(a, b, aliases):
    left, right = normalized_name(a.name), normalized_name(b.name)
    if not left or not right or aliases.get(left, left) != aliases.get(right, right):
        return False
    plan_a, plan_b = normalized_name(a.plan_name), normalized_name(b.plan_name)
    return (not plan_a or not plan_b or plan_a == plan_b) and a.currency == b.currency


def service_aliases(db):
    return {normalized_name(alias): s.id for s in db.scalars(select(Service))
            for alias in (s.name, *json.loads(s.aliases))}
