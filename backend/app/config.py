from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file='.env', extra='ignore')
    database_url: str = 'sqlite:///./subscription_tree.db'
    jwt_secret: str = ''
    yandex_client_id: str = ''
    yandex_client_secret: str = ''
    yandex_redirect_uri: str = ''
    allow_dev_auth: bool = False
    smtp_host: str = ''
    smtp_port: int = 465
    smtp_starttls: bool = False
    smtp_username: str = ''
    smtp_password: str = ''
    smtp_from: str = ''
    sms_ru_api_id: str = ''
    ollama_url: str = ''
    ollama_model: str = ''


settings = Settings()
