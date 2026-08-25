from pwdlib import PasswordHash

_PASSWORD_HASH = PasswordHash.recommended()


def hash_password(password: str) -> str:
    return _PASSWORD_HASH.hash(password)


def verify_password(password: str, encoded: str) -> bool:
    return _PASSWORD_HASH.verify(password, encoded)
