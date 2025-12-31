import time

online = {}
TIMEOUT = 60  # 60 秒没心跳就算离线

def handler(request):
    now = time.time()
    users = []

    for uid, v in list(online.items()):
        if now - v["lastSeen"] <= TIMEOUT:
            users.append({
                "userId": uid,
                "name": v["name"]
            })
        else:
            online.pop(uid, None)

    return {
        "count": len(users),
        "users": users
    }
