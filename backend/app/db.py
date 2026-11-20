from sqlalchemy import create_engine, inspect
from sqlalchemy.orm import DeclarativeBase, sessionmaker
from .config import settings


class Base(DeclarativeBase):
    pass


engine = create_engine(
    settings.database_url,
    connect_args={'check_same_thread': False} if settings.database_url.startswith('sqlite') else {},
    pool_pre_ping=True,
)
SessionLocal = sessionmaker(engine, expire_on_commit=False)


def upgrade_subscription_details(database=engine):
    with database.begin() as conn:
        if conn.dialect.name == 'sqlite':
            conn.exec_driver_sql('BEGIN IMMEDIATE')
        if any(column['name'] == 'bank_merchant'
               for column in inspect(conn).get_columns('subscription_details')):
            return
        guard = 'IF NOT EXISTS ' if conn.dialect.name == 'postgresql' else ''
        conn.exec_driver_sql(
            f'ALTER TABLE subscription_details ADD COLUMN {guard}bank_merchant VARCHAR(300)'
        )


def get_db():
    with SessionLocal() as db:
        yield db
