import hashlib
import re
import secrets

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from .db import SessionLocal
from .models import PasswordLogin, User


DEV_USER_ID = 'dev-local'
DEV_EMAIL = 'dev@moneytree.test'
DEV_PHONE = '+79870000001'
DEV_PASSWORD = 'MoneyTreeDev!2026'


def normalize_ru_phone(value: str) -> str | None:
    number = re.sub(r'[\s().-]', '', value)
    match = re.fullmatch(r'(?:\+7|7|8)?([0-9]{10})', number)
    return '+7' + match[1] if match else None


def password_digest(password: str, salt: bytes) -> str:
    return hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 600_000).hex()


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    return f'{salt.hex()}:{password_digest(password, salt)}'


def verify_password(password: str, stored_hash: str | None) -> bool:
    # Perform the same work for an unknown identifier.
    salt, expected = (stored_hash or ('00' * 16 + ':' + '00' * 32)).split(':')
    matches = secrets.compare_digest(password_digest(password, bytes.fromhex(salt)), expected)
    return stored_hash is not None and matches


def seed_dev_account() -> None:
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.yandex_id == DEV_USER_ID))
        if user and db.get(PasswordLogin, user.id):
            return
        try:
            if not user:
                user = User(yandex_id=DEV_USER_ID, display_name='Тестовый пользователь')
                db.add(user)
                db.flush()
            db.add(PasswordLogin(user_id=user.id, email=DEV_EMAIL, phone=DEV_PHONE,
                                 password_hash=hash_password(DEV_PASSWORD)))
            db.commit()
        except IntegrityError:
            db.rollback()
            user = db.scalar(select(User).where(User.yandex_id == DEV_USER_ID))
            if not user or not db.get(PasswordLogin, user.id):
                raise
