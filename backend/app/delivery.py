import smtplib
import ssl
from email.message import EmailMessage

import httpx
from fastapi import HTTPException

from .config import settings


def ensure_delivery_configured(by_email: bool) -> None:
    configured = settings.smtp_host and settings.smtp_from if by_email else settings.sms_ru_api_id
    if not configured:
        raise HTTPException(503, 'Email delivery disabled' if by_email else 'SMS delivery disabled')


def send_registration_code(identifier: str, code: str) -> None:
    message = f'Код регистрации в MoneyTree: {code}. Действует 10 минут.'
    try:
        if '@' in identifier:
            send_email(identifier, message)
        else:
            send_sms(identifier, message)
    except (OSError, httpx.HTTPError, ValueError, KeyError, TypeError, AttributeError):
        raise HTTPException(502, 'Code delivery failed') from None


def send_email(identifier: str, message: str) -> None:
    email = EmailMessage()
    email['Subject'] = 'Код регистрации MoneyTree'
    email['From'] = settings.smtp_from
    email['To'] = identifier
    email.set_content(message)
    context = ssl.create_default_context()
    if settings.smtp_starttls:
        connection = smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=6)
    else:
        connection = smtplib.SMTP_SSL(settings.smtp_host, settings.smtp_port, timeout=6, context=context)
    with connection as smtp:
        if settings.smtp_starttls:
            smtp.starttls(context=context)
        if settings.smtp_username:
            smtp.login(settings.smtp_username, settings.smtp_password)
        smtp.send_message(email)


def send_sms(identifier: str, message: str) -> None:
    phone = identifier.removeprefix('+')
    response = httpx.post('https://sms.ru/sms/send', data={
        'api_id': settings.sms_ru_api_id, 'to': phone, 'msg': message, 'json': 1,
    }, timeout=6)
    response.raise_for_status()
    payload = response.json()
    if payload['status_code'] != 100 or payload['sms'][phone]['status_code'] != 100:
        raise ValueError('SMS rejected by provider')
