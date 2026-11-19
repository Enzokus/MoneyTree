import hmac
import re
import secrets
from time import time

from fastapi import HTTPException
from sqlalchemy import case, delete, select, update
from sqlalchemy.dialects.postgresql import insert as postgres_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .config import settings
from .delivery import ensure_delivery_configured, send_registration_code
from .models import PasswordLogin, RegistrationCode, RegistrationLimit, User, uid
from .passwords import DEV_EMAIL, DEV_PHONE, hash_password, normalize_ru_phone
from .schemas import RegistrationComplete


CODE_LIFETIME = 600
RESEND_DELAY = 60
MAX_ATTEMPTS = 5
EMAIL_PATTERN = re.compile(r"[a-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@[a-z0-9-]+(?:\.[a-z0-9-]+)+")


def digest(value: str) -> str:
    return hmac.digest(settings.jwt_secret.encode(), value.encode(), 'sha256').hex()


def reserve_delivery(db: Session, identifier: str, source: str, now: int, *, by_email: bool) -> tuple[str, str]:
    insert = sqlite_insert if db.get_bind().dialect.name == 'sqlite' else postgres_insert
    window = now // 3600
    channel = 'email' if by_email else 'sms'
    db.execute(delete(RegistrationLimit).where(RegistrationLimit.window < window - 1))
    for key, limit in ((f'ip:{digest(source)}', 15), (f'channel:{channel}', 300 if by_email else 100)):
        quota = insert(RegistrationLimit).values(key=key, window=window, count=1)
        result = db.execute(quota.on_conflict_do_update(
            index_elements=[RegistrationLimit.key],
            set_={'window': window, 'count': case(
                (RegistrationLimit.window == window, RegistrationLimit.count + 1), else_=1,
            )},
            where=(RegistrationLimit.window < window)
            | ((RegistrationLimit.window == window) & (RegistrationLimit.count < limit)),
        ))
        if result.rowcount != 1:
            raise HTTPException(429, 'Delivery limit reached')

    challenge_id = uid()
    code = f'{secrets.randbelow(1_000_000):06d}'
    values = {
        'challenge_id': challenge_id, 'code_hash': digest(f'registration:{challenge_id}:{code}'),
        'sent_at': now, 'attempts': 0,
    }
    result = db.execute(insert(RegistrationCode).values(identifier=identifier, **values).on_conflict_do_update(
        index_elements=[RegistrationCode.identifier], set_=values,
        where=RegistrationCode.sent_at <= now - RESEND_DELAY,
    ))
    if result.rowcount != 1:
        raise HTTPException(429, 'Code requested too recently')
    db.execute(delete(RegistrationCode).where(RegistrationCode.sent_at <= now - CODE_LIFETIME))
    db.commit()
    return challenge_id, code


def start_registration(db: Session, identifier: str, source: str) -> str:
    identifier = identifier.strip().lower()
    by_email = '@' in identifier
    if by_email:
        if not EMAIL_PATTERN.fullmatch(identifier):
            raise HTTPException(422, 'Invalid email')
        lookup = PasswordLogin.email == identifier
    else:
        identifier = normalize_ru_phone(identifier)
        if not identifier:
            raise HTTPException(422, 'Invalid phone')
        lookup = PasswordLogin.phone == identifier
    if identifier in (DEV_EMAIL, DEV_PHONE) or db.scalar(select(PasswordLogin.user_id).where(lookup)):
        raise HTTPException(409, 'Contact already registered')
    ensure_delivery_configured(by_email)
    challenge_id, code = reserve_delivery(db, identifier, source, int(time()), by_email=by_email)
    try:
        send_registration_code(identifier, code)
    except HTTPException:
        # A failed delivery still counts toward the hourly limit.
        db.execute(delete(RegistrationCode).where(RegistrationCode.challenge_id == challenge_id))
        db.commit()
        raise
    return challenge_id


def complete_registration(db: Session, body: RegistrationComplete) -> User:
    if not 12 <= len(body.password) <= 256:
        raise HTTPException(422, 'Password must be 12–256 characters')
    if not re.fullmatch(r'[0-9]{6}', body.code):
        raise HTTPException(422, 'Invalid code format')
    challenge_id = str(body.challenge_id)
    active = (
        RegistrationCode.challenge_id == challenge_id,
        RegistrationCode.sent_at > int(time()) - CODE_LIFETIME,
        RegistrationCode.attempts < MAX_ATTEMPTS,
    )
    challenge = db.scalar(select(RegistrationCode).where(*active))
    if not challenge:
        raise HTTPException(400, 'Code expired or used')
    if not hmac.compare_digest(challenge.code_hash, digest(f'registration:{challenge_id}:{body.code}')):
        db.execute(update(RegistrationCode).where(*active).values(attempts=RegistrationCode.attempts + 1))
        db.commit()
        raise HTTPException(400, 'Invalid code')

    password_hash = hash_password(body.password)
    consumed = db.execute(delete(RegistrationCode).where(*active))
    if consumed.rowcount != 1:
        raise HTTPException(400, 'Code expired or used')
    email = challenge.identifier if '@' in challenge.identifier else None
    phone = challenge.identifier if email is None else None
    user = User(id=uid(), yandex_id=f'local:{challenge_id}', email=email)
    db.add(user)
    try:
        db.flush()
        db.add(PasswordLogin(user_id=user.id, email=email, phone=phone, password_hash=password_hash))
        db.flush()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, 'Contact already registered') from None
    return user
