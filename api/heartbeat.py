import time

# 注意：云函数是无状态的，这里仅用于演示
online = {}

def handler(request):
    data = request.json or {}
    user_id = str(data.get("userId", ""))
    name = data.get("username", "")
    if not user_id:
        return {"ok": False}

    online[user_id] = {
        "name": name,
        "lastSeen": time.time()
    }
    return {"ok": True}
