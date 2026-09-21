import hashlib
import hmac


def signature(secret, timestamp, path, body):
    return hmac.new(secret.encode(), (timestamp + "\n" + path + "\n").encode() + body, hashlib.sha256).hexdigest()
