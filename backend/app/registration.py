import hmac
import re
from time import time

from fastapi import HTTPException
from sqlalchemy import case, delete, select
from sqlalchemy.dialects.postgresql import insert as postgres_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .config import settings
from .models import PasswordLogin, RegistrationLimit, User, uid
from .passwords import DEV_EMAIL, DEV_PHONE, hash_password, normalize_ru_phone
from .schemas import RegistrationInput

EMAIL_PATTERN = re.compile(r"[a-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@[a-z0-9-]+(?:\.[a-z0-9-]+)+")


def limit_registration(db: Session, source: str) -> None:
    key = hmac.digest(settings.jwt_secret.encode(), source.encode(), 'sha256').hex()
    window = int(time()) // 3600
    insert = sqlite_insert if db.get_bind().dialect.name == 'sqlite' else postgres_insert
    db.execute(delete(RegistrationLimit).where(RegistrationLimit.window < window - 1))
    quota = insert(RegistrationLimit).values(key=f'ip:{key}', window=window, count=1)
    result = db.execute(quota.on_conflict_do_update(
        index_elements=[RegistrationLimit.key],
        set_={'window': window, 'count': case(
            (RegistrationLimit.window == window, RegistrationLimit.count + 1), else_=1,
        )},
        where=(RegistrationLimit.window < window)
        | ((RegistrationLimit.window == window) & (RegistrationLimit.count < 15)),
    ))
    if result.rowcount != 1:
        raise HTTPException(429, 'Registration limit reached')
    db.commit()


def register_user(db: Session, body: RegistrationInput, source: str) -> User:
    identifier = body.identifier.strip().lower()
    email = phone = None
    if '@' in identifier:
        if not EMAIL_PATTERN.fullmatch(identifier):
            raise HTTPException(422, 'Invalid email')
        email = identifier
        lookup = PasswordLogin.email == email
    else:
        phone = normalize_ru_phone(identifier)
        if not phone:
            raise HTTPException(422, 'Invalid phone')
        lookup = PasswordLogin.phone == phone
    if email == DEV_EMAIL or phone == DEV_PHONE:
        raise HTTPException(409, 'Contact already registered')
    limit_registration(db, source)
    if db.scalar(select(PasswordLogin.user_id).where(lookup)):
        raise HTTPException(409, 'Contact already registered')

    password_hash = hash_password(body.password)
    user = User(id=uid(), yandex_id=f'local:{uid()}', email=email)
    db.add(user)
    try:
        db.flush()
        db.add(PasswordLogin(user_id=user.id, email=email, phone=phone, password_hash=password_hash))
        db.flush()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, 'Contact already registered') from None
    return user
